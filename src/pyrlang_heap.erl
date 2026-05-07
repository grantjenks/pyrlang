-module(pyrlang_heap).

-include("pyrlang.hrl").

-define(FUNCTION_ID_KEY, '$py_function_id').

-export([
    init/0,
    ensure/0,
    snapshot/0,
    allocate/2,
    placeholder/1,
    set_data/2,
    object/1,
    type/1,
    data/1,
    list/1,
    list_instance/2,
    list_items/1,
    list_append/2,
    list_insert/3,
    list_get/2,
    list_set/3,
    dict/1,
    dict_instance/2,
    dict_items/1,
    dict_find/2,
    dict_get/2,
    dict_contains/2,
    dict_put/3,
    dict_del/2,
    set/1,
    set_items/1,
    set_add/2,
    set_remove/2,
    set_contains/2,
    value_key/1,
    object_instance/1,
    object_attrs/1,
    object_get/2,
    object_set/3
]).

-spec init() -> map().
init() ->
    Heap = #{next => 1, objects => #{}},
    erlang:put(?PY_HEAP_KEY, Heap),
    erlang:erase(pyrlang_module_cache),
    erlang:erase(pyrlang_module_path),
    erlang:erase(pyrlang_sys_modules_ref),
    erlang:erase(pyrlang_os_environ),
    erlang:erase(pyrlang_sys_argv),
    erlang:erase(pyrlang_function_attrs),
    erlang:erase(pyrlang_inspect_parameter_constants),
    erlang:erase(pyrlang_random_base_type),
    erlang:erase(pyrlang_stat_result_type),
    erlang:erase(pyrlang_terminal_size_type),
    erlang:erase(pyrlang_subclasses),
    erase_builtin_type_class_cache(),
    Heap.

erase_builtin_type_class_cache() ->
    Names = [
        <<"async_generator">>,
        <<"bool">>,
        <<"bytes">>,
        <<"bytearray">>,
        <<"coroutine">>,
        <<"dict">>,
        <<"ellipsis">>,
        <<"float">>,
        <<"frozenset">>,
        <<"GenericAlias">>,
        <<"generator">>,
        <<"int">>,
        <<"iterator">>,
        <<"list">>,
        <<"memoryview">>,
        <<"NoneType">>,
        <<"object">>,
        <<"property">>,
        <<"range">>,
        <<"set">>,
        <<"str">>,
        <<"staticmethod">>,
        <<"classmethod">>,
        <<"type">>,
        <<"tuple">>
    ],
    [erlang:erase({pyrlang_builtin_type_class, Name}) || Name <- Names],
    ok.

-spec ensure() -> map().
ensure() ->
    case erlang:get(?PY_HEAP_KEY) of
        undefined ->
            SavedState = saved_process_state(),
            Heap = init(),
            restore_process_state(SavedState),
            Heap;
        Heap when is_map(Heap) -> Heap
    end.

saved_process_state() ->
    [
        {Key, Value}
        || Key <- [pyrlang_module_path, pyrlang_os_environ, pyrlang_sys_argv],
           (Value = erlang:get(Key)) =/= undefined
    ].

restore_process_state(SavedState) ->
    lists:foreach(fun({Key, Value}) -> erlang:put(Key, Value) end, SavedState).

-spec snapshot() -> map().
snapshot() ->
    ensure().

-spec allocate(atom(), term()) -> py_ref().
allocate(Type, Data) ->
    Heap = ensure(),
    Id = maps:get(next, Heap),
    Objects = maps:get(objects, Heap),
    Cell = #{type => Type, data => Data},
    erlang:put(?PY_HEAP_KEY, Heap#{next := Id + 1, objects := Objects#{Id => Cell}}),
    {?PY_REF, Id}.

-spec placeholder(atom()) -> py_ref().
placeholder(Type) ->
    allocate(Type, undefined).

-spec set_data(py_ref(), term()) -> ok.
set_data({?PY_REF, Id}, Data) ->
    Heap = ensure(),
    Objects = maps:get(objects, Heap),
    Cell = maps:get(Id, Objects),
    OldData = maps:get(data, Cell),
    NewData =
        case {maps:get(type, Cell), OldData, Data} of
            {list, #{items := _}, Items} when is_list(Items) ->
                OldData#{items := Items};
            {dict, #{items := _}, NewDictData} ->
                preserve_dict_instance_data(OldData, NewDictData);
            _ ->
                Data
        end,
    erlang:put(?PY_HEAP_KEY, Heap#{objects := Objects#{Id := Cell#{data := NewData}}}),
    ok.

-spec object(py_ref()) -> py_heap_cell().
object({?PY_REF, Id}) ->
    Heap = ensure(),
    maps:get(Id, maps:get(objects, Heap)).

-spec type(py_ref()) -> atom().
type(Ref) ->
    maps:get(type, object(Ref)).

-spec data(py_ref()) -> term().
data(Ref) ->
    maps:get(data, object(Ref)).

-spec list([term()]) -> py_ref().
list(Items) when is_list(Items) ->
    allocate(list, Items).

-spec list_instance(term(), [term()]) -> py_ref().
list_instance(Class, Items) when is_list(Items) ->
    allocate(list, #{class => Class, attrs => #{}, items => Items}).

-spec list_items(py_ref()) -> [term()].
list_items(Ref) ->
    list = type(Ref),
    list_data_items(data(Ref)).

list_data_items(#{items := Items}) ->
    Items;
list_data_items(Items) when is_list(Items) ->
    Items.

-spec list_append(py_ref(), term()) -> ok.
list_append(Ref, Value) ->
    Items = list_items(Ref),
    set_data(Ref, Items ++ [Value]).

-spec list_insert(py_ref(), integer(), term()) -> ok.
list_insert(Ref, Index, Value) ->
    Items = list_items(Ref),
    ZeroIndex = normalize_insert_index(Index, length(Items)),
    {Prefix, Suffix} = lists:split(ZeroIndex, Items),
    set_data(Ref, Prefix ++ [Value | Suffix]).

-spec list_get(py_ref(), integer()) -> term().
list_get(Ref, Index) ->
    Items = list_items(Ref),
    lists:nth(normalize_index(Index, length(Items)) + 1, Items).

-spec list_set(py_ref(), integer(), term()) -> ok.
list_set(Ref, Index, Value) ->
    Items = list_items(Ref),
    ZeroIndex = normalize_index(Index, length(Items)),
    set_data(Ref, replace_nth(ZeroIndex + 1, Value, Items)).

-spec dict([{term(), term()}] | map()) -> py_ref().
dict(Pairs) when is_list(Pairs) ->
    allocate(dict, normalize_dict_pairs(Pairs));
dict(Map) when is_map(Map) ->
    allocate(dict, maps:to_list(Map)).

-spec dict_instance(term(), [{term(), term()}] | map()) -> py_ref().
dict_instance(Class, Pairs) when is_list(Pairs) ->
    allocate(dict, #{class => Class, attrs => #{}, items => normalize_dict_pairs(Pairs)});
dict_instance(Class, Map) when is_map(Map) ->
    dict_instance(Class, maps:to_list(Map)).

-spec dict_items(py_ref()) -> [{term(), term()}].
dict_items(Ref) ->
    dict = type(Ref),
    dict_data_items(data(Ref)).

-spec dict_get(py_ref(), term()) -> term().
dict_get(Ref, Key) ->
    dict = type(Ref),
    case dict_find(Ref, Key) of
        {ok, Value} -> Value;
        error -> erlang:error({badkey, Key})
    end.

-spec dict_find(py_ref(), term()) -> {ok, term()} | error.
dict_find(Ref, Key) ->
    dict = type(Ref),
    dict_pairs_find(Key, dict_data_items(data(Ref))).

-spec dict_contains(py_ref(), term()) -> boolean().
dict_contains(Ref, Key) ->
    dict = type(Ref),
    dict_pairs_find(Key, dict_data_items(data(Ref))) =/= error.

-spec dict_put(py_ref(), term(), term()) -> ok.
dict_put(Ref, Key, Value) ->
    dict = type(Ref),
    set_data(Ref, dict_data_put(Key, Value, data(Ref))).

-spec dict_del(py_ref(), term()) -> ok.
dict_del(Ref, Key) ->
    dict = type(Ref),
    set_data(Ref, dict_data_del(Key, data(Ref))).

dict_data_items(#{items := Items}) ->
    dict_data_items(Items);
dict_data_items(Pairs) when is_list(Pairs) ->
    Pairs;
dict_data_items(Map) when is_map(Map) ->
    maps:to_list(Map).

preserve_dict_instance_data(OldData, NewData) when is_map(NewData) ->
    case maps:is_key(items, NewData) andalso maps:is_key(attrs, NewData) of
        true -> NewData;
        false -> OldData#{items := dict_data_items(NewData)}
    end;
preserve_dict_instance_data(OldData, NewData) ->
    OldData#{items := dict_data_items(NewData)}.

dict_data_put(Key, Value, #{items := Items} = Data) ->
    Data#{items := dict_pairs_put(Key, Value, dict_data_items(Items), [])};
dict_data_put(Key, Value, Data) ->
    dict_pairs_put(Key, Value, dict_data_items(Data), []).

dict_data_del(Key, #{items := Items} = Data) ->
    Data#{items := dict_pairs_del(Key, dict_data_items(Items), [])};
dict_data_del(Key, Data) ->
    dict_pairs_del(Key, dict_data_items(Data), []).

dict_pairs_put(Key, Value, [], Acc) ->
    lists:reverse([{Key, Value} | Acc]);
dict_pairs_put(Key, Value, [{ExistingKey, _OldValue} | Rest], Acc) ->
    case value_key(ExistingKey) =:= value_key(Key) of
        true -> lists:reverse(Acc) ++ [{Key, Value} | Rest];
        false -> dict_pairs_put(Key, Value, Rest, [{ExistingKey, _OldValue} | Acc])
    end;
dict_pairs_put(Key, Value, [Pair | Rest], Acc) ->
    dict_pairs_put(Key, Value, Rest, [Pair | Acc]).

dict_pairs_find(_Key, []) ->
    error;
dict_pairs_find(Key, [{ExistingKey, Value} | Rest]) ->
    case value_key(ExistingKey) =:= value_key(Key) of
        true -> {ok, Value};
        false ->
            case values_equal(Key, ExistingKey) of
                true -> {ok, Value};
                false -> dict_pairs_find(Key, Rest)
            end
    end.

dict_pairs_del(_Key, [], Acc) ->
    lists:reverse(Acc);
dict_pairs_del(Key, [{ExistingKey, _OldValue} | Rest], Acc) ->
    case value_key(ExistingKey) =:= value_key(Key) of
        true -> lists:reverse(Acc) ++ Rest;
        false -> dict_pairs_del(Key, Rest, [{ExistingKey, _OldValue} | Acc])
    end;
dict_pairs_del(Key, [Pair | Rest], Acc) ->
    dict_pairs_del(Key, Rest, [Pair | Acc]).

normalize_dict_pairs(Pairs) ->
    lists:foldl(
        fun({Key, Value}, Acc) -> dict_pairs_put(Key, Value, Acc, []) end,
        [],
        Pairs
    ).

-spec set([term()]) -> py_ref().
set(Items) when is_list(Items) ->
    allocate(set, maps:from_list([{value_key(Item), Item} || Item <- Items])).

-spec set_items(py_ref()) -> [term()].
set_items(Ref) ->
    set = type(Ref),
    maps:values(data(Ref)).

-spec set_add(py_ref(), term()) -> ok.
set_add(Ref, Value) ->
    set = type(Ref),
    trace_heap_flow(set_add_start, Value),
    Key = value_key(Value),
    trace_heap_flow(set_add_key, Key),
    Result = set_data(Ref, maps:put(Key, Value, data(Ref))),
    trace_heap_flow(set_add_done, Value),
    Result.

-spec set_remove(py_ref(), term()) -> ok.
set_remove(Ref, Value) ->
    set = type(Ref),
    set_data(Ref, maps:remove(value_key(Value), data(Ref))).

-spec set_contains(py_ref(), term()) -> boolean().
set_contains(Ref, Value) ->
    set = type(Ref),
    Data = data(Ref),
    maps:is_key(value_key(Value), Data) orelse lists:any(fun(Existing) -> values_equal(Value, Existing) end, maps:values(Data)).

values_equal(Left, Right) ->
    try pyrlang_eval:eval_compare(eq, Left, Right) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

value_key({py_ref, Id}) ->
    {py_ref, Id};
value_key({py_function, Params, Body, Env}) ->
    function_value_key(Params, Body, Env, false, undefined);
value_key({py_function, Params, Body, Env, Mode}) ->
    function_value_key(Params, Body, Env, Mode, undefined);
value_key({py_function, Params, Body, Env, Mode, Owner}) ->
    function_value_key(Params, Body, Env, Mode, Owner);
value_key({py_bound_method, Callable, Self}) ->
    {py_bound_method, value_key(Callable), value_key(Self)};
value_key({Key, Value}) ->
    {value_key(Key), value_key(Value)};
value_key(List) when is_list(List) ->
    [value_key(Value) || Value <- List];
value_key(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([value_key(Value) || Value <- tuple_to_list(Tuple)]);
value_key(Map) when is_map(Map) ->
    maps:from_list([{value_key(Key), value_key(Value)} || {Key, Value} <- maps:to_list(Map)]);
value_key(Value) ->
    Value.

function_value_key(Params, Body, Env, Mode, Owner) ->
    case maps:get(?FUNCTION_ID_KEY, Env, undefined) of
        undefined -> {py_function, erlang:phash2({Params, Body, Mode, Owner})};
        Id -> {py_function_id, Id}
    end.

trace_heap_flow(Stage, Value) ->
    case os:getenv("PYRLANG_TRACE_NATIVE_FLOW") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_HEAP ~p ~p~n", [Stage, trace_heap_value(Value)])
    end.

trace_heap_value({py_ref, _} = Ref) ->
    try type(Ref) of
        Type -> {py_ref, Type}
    catch
        _:_ -> Ref
    end;
trace_heap_value({py_function, _Params, _Body, Env}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_heap_value({py_function, _Params, _Body, Env, _Mode}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_heap_value({py_function, _Params, _Body, Env, _Mode, _Owner}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_heap_value({py_bound_method, Callable, _Self}) ->
    {py_bound_method, trace_heap_value(Callable)};
trace_heap_value(Value) ->
    Value.

-spec object_instance([{term(), term()}] | map()) -> py_ref().
object_instance(Attrs) when is_list(Attrs) ->
    allocate(object, maps:from_list(Attrs));
object_instance(Attrs) when is_map(Attrs) ->
    allocate(object, Attrs).

-spec object_attrs(py_ref()) -> [{term(), term()}].
object_attrs(Ref) ->
    object = type(Ref),
    maps:to_list(data(Ref)).

-spec object_get(py_ref(), term()) -> term().
object_get(Ref, Name) ->
    object = type(Ref),
    maps:get(Name, data(Ref)).

-spec object_set(py_ref(), term(), term()) -> ok.
object_set(Ref, Name, Value) ->
    object = type(Ref),
    set_data(Ref, maps:put(Name, Value, data(Ref))).

normalize_index(Index, Length) when Index < 0 ->
    Normalized = Length + Index,
    case Normalized >= 0 of
        true -> Normalized;
        false -> erlang:error({index_error, Index})
    end;
normalize_index(Index, Length) when Index >= 0, Index < Length ->
    Index;
normalize_index(Index, _Length) ->
    erlang:error({index_error, Index}).

normalize_insert_index(Index, Length) when Index < 0 ->
    max(0, Length + Index);
normalize_insert_index(Index, Length) when Index > Length ->
    Length;
normalize_insert_index(Index, _Length) ->
    Index.

replace_nth(1, Value, [_Old | Rest]) ->
    [Value | Rest];
replace_nth(N, Value, [Item | Rest]) when N > 1 ->
    [Item | replace_nth(N - 1, Value, Rest)].
