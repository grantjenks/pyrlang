-module(pyrlang_iter).

-export([iter/1, next/1, values/1, from_values/1, callable_sentinel/2]).

-spec iter(term()) -> term().
iter({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        generator -> Ref;
        iterator -> Ref;
        list -> iterator_from_values(pyrlang_heap:list_items(Ref));
        dict -> iterator_from_values([Key || {Key, _Value} <- pyrlang_heap:dict_items(Ref)]);
        set -> iterator_from_values(pyrlang_heap:set_items(Ref));
        instance ->
            case tuple_subclass_items(Ref) of
                {ok, Items} -> iterator_from_values(Items);
                error ->
                    case string_subclass_value(Ref) of
                        {ok, Value} -> iterator_from_values([<<Char/utf8>> || <<Char/utf8>> <= Value]);
                        error -> object_iterator(Ref)
                    end
            end;
        _Type ->
            object_iterator(Ref)
    end;
iter({py_instance_dict, Instance}) ->
    iterator_from_values(maps:keys(instance_dict_attrs(Instance)));
iter({py_module_dict, ModuleRef}) ->
    iterator_from_values(maps:keys(pyrlang_module:env(ModuleRef)));
iter({py_range, Start, Stop, Step}) ->
    range_iterator(Start, Stop, Step);
iter(Binary) when is_binary(Binary) ->
    iterator_from_values([<<Char/utf8>> || <<Char/utf8>> <= Binary]);
iter(Tuple) when is_tuple(Tuple) ->
    iterator_from_values(tuple_to_list(Tuple));
iter(List) when is_list(List) ->
    iterator_from_values(List);
iter(Other) ->
    trace_not_iterable(Other),
    raise_not_iterable(Other).

-spec next(term()) -> term().
next({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        generator ->
            pyrlang_generator:next(Ref);
        iterator ->
            next_iterator(Ref);
        _Type ->
            call_next_method(Ref)
    end;
next(Other) ->
    erlang:error({type_error, {not_iterator, Other}}).

-spec values(term()) -> [term()].
values({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> pyrlang_heap:list_items(Ref);
        dict -> [Key || {Key, _Value} <- pyrlang_heap:dict_items(Ref)];
        set -> pyrlang_heap:set_items(Ref);
        generator -> pyrlang_generator:values(Ref);
        iterator -> collect_iterator(Ref, []);
        instance ->
            case tuple_subclass_items(Ref) of
                {ok, Items} -> Items;
                error ->
                    case string_subclass_value(Ref) of
                        {ok, Value} -> [<<Char/utf8>> || <<Char/utf8>> <= Value];
                        error -> collect_iterator(object_iterator(Ref), [])
                    end
            end;
        _Type ->
            collect_iterator(object_iterator(Ref), [])
    end;
values({py_instance_dict, Instance}) ->
    maps:keys(instance_dict_attrs(Instance));
values({py_module_dict, ModuleRef}) ->
    maps:keys(pyrlang_module:env(ModuleRef));
values({py_range, Start, Stop, Step}) ->
    range_values(Start, Stop, Step, []);
values(Binary) when is_binary(Binary) ->
    [<<Char/utf8>> || <<Char/utf8>> <= Binary];
values(Tuple) when is_tuple(Tuple) ->
    tuple_to_list(Tuple);
values(List) when is_list(List) ->
    List;
values(Other) ->
    trace_not_iterable(Other),
    raise_not_iterable(Other).

object_iterator(Ref) ->
    case pyrlang_heap:type(Ref) of
        class -> class_iterator(Ref);
        _ -> object_iterator_attr(Ref)
    end.

object_iterator_attr(Ref) ->
    try pyrlang_object:get_attr(Ref, <<"__iter__">>) of
        Iter ->
            Result = pyrlang_eval:call(Iter, []),
            trace_iter_result(Ref, Result),
            Result
    catch
        error:{attribute_error, _Name} -> sequence_iterator_or_ref(Ref)
    end.

sequence_iterator_or_ref(Ref) ->
    try pyrlang_object:get_attr(Ref, <<"__getitem__">>) of
        GetItem -> pyrlang_heap:allocate(iterator, #{kind => sequence, getitem => GetItem, index => 0})
    catch
        error:{attribute_error, _Name} -> Ref
    end.

class_iterator(Class) ->
    case pyrlang_object:metaclass(Class) of
        undefined ->
            object_iterator_attr(Class);
        Metaclass ->
            case pyrlang_object:class_attr(Metaclass, <<"__iter__">>) of
                {ok, Iter} ->
                    pyrlang_eval:call(pyrlang_object:bind_attr(Iter, Class, Metaclass), []);
                error ->
                    object_iterator_attr(Class)
            end
    end.

iterator_from_values(Values) ->
    pyrlang_heap:allocate(iterator, #{values => Values, index => 1}).

from_values(Values) ->
    iterator_from_values(Values).

range_iterator(Start, Stop, Step) ->
    pyrlang_heap:allocate(iterator, #{kind => range, current => Start, stop => Stop, step => Step}).

callable_sentinel(Callable, Sentinel) ->
    pyrlang_heap:allocate(iterator, #{kind => callable_sentinel, callable => Callable, sentinel => Sentinel}).

next_iterator(Ref) ->
    Data = pyrlang_heap:data(Ref),
    case maps:get(kind, Data, values) of
        range ->
            next_range_iterator(Ref, Data);
        callable_sentinel ->
            next_callable_sentinel_iterator(Data);
        sequence ->
            next_sequence_iterator(Ref, Data);
        values ->
            Values = maps:get(values, Data),
            Index = maps:get(index, Data),
            case Index =< length(Values) of
                true ->
                    Value = lists:nth(Index, Values),
                    ok = pyrlang_heap:set_data(Ref, Data#{index := Index + 1}),
                    Value;
                false ->
                    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"StopIteration">>)))
            end
    end.

next_callable_sentinel_iterator(Data) ->
    Value = pyrlang_eval:call(maps:get(callable, Data), []),
    case same_value(Value, maps:get(sentinel, Data)) of
        true ->
            pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"StopIteration">>)));
        false ->
            Value
    end.

next_sequence_iterator(Ref, Data) ->
    Index = maps:get(index, Data),
    GetItem = maps:get(getitem, Data),
    try pyrlang_eval:call(GetItem, [Index]) of
        Value ->
            ok = pyrlang_heap:set_data(Ref, Data#{index := Index + 1}),
            Value
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"IndexError">> ->
                    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"StopIteration">>)));
                _ ->
                    pyrlang_exception:raise(Exception)
            end
    end.

same_value(Left, Right) when is_number(Left), is_number(Right) ->
    Left == Right;
same_value(Left, Right) ->
    pyrlang_eval:eval_compare(eq, Left, Right).

next_range_iterator(Ref, Data) ->
    Current = maps:get(current, Data),
    Stop = maps:get(stop, Data),
    Step = maps:get(step, Data),
    case range_continue(Current, Stop, Step) of
        true ->
            ok = pyrlang_heap:set_data(Ref, Data#{current := Current + Step}),
            Current;
        false ->
            pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"StopIteration">>)))
    end.

range_values(Current, Stop, Step, Acc) ->
    case range_continue(Current, Stop, Step) of
        true -> range_values(Current + Step, Stop, Step, [Current | Acc]);
        false -> lists:reverse(Acc)
    end.

range_continue(Current, Stop, Step) when Step > 0 ->
    Current < Stop;
range_continue(Current, Stop, Step) when Step < 0 ->
    Current > Stop.

collect_iterator(Iterator, Acc) ->
    try next(Iterator) of
        Value -> collect_iterator(Iterator, [Value | Acc])
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"StopIteration">> -> lists:reverse(Acc);
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

call_next_method(Ref) ->
    try pyrlang_object:get_attr(Ref, <<"__next__">>) of
        Next -> pyrlang_eval:call(Next, [])
    catch
        error:{attribute_error, _Name} ->
            trace_not_iterator(Ref),
            erlang:error({type_error, {not_iterator, Ref}})
    end.

trace_not_iterator(Ref) ->
    case os:getenv("PYRLANG_TRACE_ITER") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_NOT_ITERATOR object=~s stack=~p~n",
                [describe_value(Ref), pyrlang_eval:trace_function_stack()]
            )
    end.

trace_iter_result(Ref, Result) ->
    case os:getenv("PYRLANG_TRACE_ITER") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_ITER_RESULT object=~s result=~s stack=~p~n",
                [describe_value(Ref), describe_value(Result), pyrlang_eval:trace_function_stack()]
            )
    end.

trace_not_iterable(Other) ->
    case os:getenv("PYRLANG_TRACE_ITER") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_NOT_ITERABLE object=~s stack=~p~n",
                [describe_value(Other), pyrlang_eval:trace_function_stack()]
            )
    end.

raise_not_iterable(Other) ->
    Message = <<"object is not iterable: ", (describe_value(Other))/binary>>,
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"TypeError">>), Message)).

describe_value({py_ref, _} = Ref) ->
    try
        case pyrlang_heap:type(Ref) of
            instance ->
                Class = maps:get(class, pyrlang_heap:data(Ref)),
                <<"instance:", (pyrlang_object:class_name(Class))/binary>>;
            class ->
                <<"class:", (pyrlang_object:class_name(Ref))/binary>>;
            Type ->
                unicode:characters_to_binary(io_lib:format("~p", [Type]))
        end
    catch
        _:_ -> <<"ref">>
    end;
describe_value(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

instance_dict_attrs(Instance) ->
    Data = pyrlang_heap:data(Instance),
    maps:get(attrs, Data, #{}).

tuple_subclass_items({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
            case maps:find(<<"__pyrlang_tuple_items__">>, Attrs) of
                {ok, Tuple} when is_tuple(Tuple) -> {ok, tuple_to_list(Tuple)};
                _ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.

string_subclass_value({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
            case maps:find(<<"__pyrlang_value__">>, Attrs) of
                {ok, Value} when is_binary(Value) -> {ok, Value};
                _ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end;
string_subclass_value(_Other) ->
    error.
