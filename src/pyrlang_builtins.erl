-module(pyrlang_builtins).

-define(CLASS_ATTR_ORDER_KEY, <<"__pyrlang_class_attr_order__">>).

-export([
    env/0,
    lookup/1,
    generic_alias/2,
    generic_alias_type/0,
    type_union/2,
    union_type/0,
    object_class/1,
    int_subclass_value/1,
    none_type/0,
    ellipsis_type/0,
    not_implemented_type/0,
    function_type/0,
    builtin_function_type/0,
    method_type/0,
    module_type/0,
    code_type/0,
    simple_namespace_type/0,
    cell_type/0,
    generator_type/0,
    coroutine_type/0,
    async_generator_type/0,
    traceback_type/0,
    frame_type/0,
    wrapper_descriptor_type/0,
    method_wrapper_type/0,
    method_descriptor_type/0,
    classmethod_descriptor_type/0,
    getset_descriptor_type/0,
    member_descriptor_type/0,
    builtin_repr/1,
    open/1
]).

-spec env() -> map().
env() ->
    #{
        <<"Ellipsis">> => ellipsis,
        <<"NotImplemented">> => not_implemented,
        <<"BaseException">> => pyrlang_exception:type(<<"BaseException">>),
        <<"Exception">> => pyrlang_exception:type(<<"Exception">>),
        <<"ArithmeticError">> => pyrlang_exception:type(<<"ArithmeticError">>),
        <<"AssertionError">> => pyrlang_exception:type(<<"AssertionError">>),
        <<"BlockingIOError">> => pyrlang_exception:type(<<"BlockingIOError">>),
        <<"BrokenPipeError">> => pyrlang_exception:type(<<"BrokenPipeError">>),
        <<"BufferError">> => pyrlang_exception:type(<<"BufferError">>),
        <<"ChildProcessError">> => pyrlang_exception:type(<<"ChildProcessError">>),
        <<"ConnectionAbortedError">> => pyrlang_exception:type(<<"ConnectionAbortedError">>),
        <<"ConnectionError">> => pyrlang_exception:type(<<"ConnectionError">>),
        <<"ConnectionRefusedError">> => pyrlang_exception:type(<<"ConnectionRefusedError">>),
        <<"ConnectionResetError">> => pyrlang_exception:type(<<"ConnectionResetError">>),
        <<"EOFError">> => pyrlang_exception:type(<<"EOFError">>),
        <<"EnvironmentError">> => pyrlang_exception:type(<<"OSError">>),
        <<"IOError">> => pyrlang_exception:type(<<"OSError">>),
        <<"FileExistsError">> => pyrlang_exception:type(<<"FileExistsError">>),
        <<"FileNotFoundError">> => pyrlang_exception:type(<<"FileNotFoundError">>),
        <<"FloatingPointError">> => pyrlang_exception:type(<<"FloatingPointError">>),
        <<"GeneratorExit">> => pyrlang_exception:type(<<"GeneratorExit">>),
        <<"InterruptedError">> => pyrlang_exception:type(<<"InterruptedError">>),
        <<"ImportError">> => pyrlang_exception:type(<<"ImportError">>),
        <<"IndentationError">> => pyrlang_exception:type(<<"IndentationError">>),
        <<"IsADirectoryError">> => pyrlang_exception:type(<<"IsADirectoryError">>),
        <<"KeyboardInterrupt">> => pyrlang_exception:type(<<"KeyboardInterrupt">>),
        <<"LookupError">> => pyrlang_exception:type(<<"LookupError">>),
        <<"MemoryError">> => pyrlang_exception:type(<<"MemoryError">>),
        <<"ModuleNotFoundError">> => pyrlang_exception:type(<<"ModuleNotFoundError">>),
        <<"NameError">> => pyrlang_exception:type(<<"NameError">>),
        <<"NotADirectoryError">> => pyrlang_exception:type(<<"NotADirectoryError">>),
        <<"NotImplementedError">> => pyrlang_exception:type(<<"NotImplementedError">>),
        <<"Warning">> => pyrlang_exception:type(<<"Warning">>),
        <<"UserWarning">> => pyrlang_exception:type(<<"UserWarning">>),
        <<"DeprecationWarning">> => pyrlang_exception:type(<<"DeprecationWarning">>),
        <<"PendingDeprecationWarning">> => pyrlang_exception:type(<<"PendingDeprecationWarning">>),
        <<"SyntaxWarning">> => pyrlang_exception:type(<<"SyntaxWarning">>),
        <<"RuntimeWarning">> => pyrlang_exception:type(<<"RuntimeWarning">>),
        <<"FutureWarning">> => pyrlang_exception:type(<<"FutureWarning">>),
        <<"ImportWarning">> => pyrlang_exception:type(<<"ImportWarning">>),
        <<"UnicodeWarning">> => pyrlang_exception:type(<<"UnicodeWarning">>),
        <<"BytesWarning">> => pyrlang_exception:type(<<"BytesWarning">>),
        <<"ResourceWarning">> => pyrlang_exception:type(<<"ResourceWarning">>),
        <<"AttributeError">> => pyrlang_exception:type(<<"AttributeError">>),
        <<"IndexError">> => pyrlang_exception:type(<<"IndexError">>),
        <<"KeyError">> => pyrlang_exception:type(<<"KeyError">>),
        <<"OSError">> => pyrlang_exception:type(<<"OSError">>),
        <<"OverflowError">> => pyrlang_exception:type(<<"OverflowError">>),
        <<"PermissionError">> => pyrlang_exception:type(<<"PermissionError">>),
        <<"ProcessLookupError">> => pyrlang_exception:type(<<"ProcessLookupError">>),
        <<"RecursionError">> => pyrlang_exception:type(<<"RecursionError">>),
        <<"ReferenceError">> => pyrlang_exception:type(<<"ReferenceError">>),
        <<"RuntimeError">> => pyrlang_exception:type(<<"RuntimeError">>),
        <<"SystemError">> => pyrlang_exception:type(<<"SystemError">>),
        <<"SystemExit">> => pyrlang_exception:type(<<"SystemExit">>),
        <<"TabError">> => pyrlang_exception:type(<<"TabError">>),
        <<"StopIteration">> => pyrlang_exception:type(<<"StopIteration">>),
        <<"SyntaxError">> => pyrlang_exception:type(<<"SyntaxError">>),
        <<"TimeoutError">> => pyrlang_exception:type(<<"TimeoutError">>),
        <<"TypeError">> => pyrlang_exception:type(<<"TypeError">>),
        <<"UnboundLocalError">> => pyrlang_exception:type(<<"UnboundLocalError">>),
        <<"UnicodeError">> => pyrlang_exception:type(<<"UnicodeError">>),
        <<"UnicodeDecodeError">> => pyrlang_exception:type(<<"UnicodeDecodeError">>),
        <<"UnicodeEncodeError">> => pyrlang_exception:type(<<"UnicodeEncodeError">>),
        <<"UnicodeTranslateError">> => pyrlang_exception:type(<<"UnicodeTranslateError">>),
        <<"ValueError">> => pyrlang_exception:type(<<"ValueError">>),
        <<"ZeroDivisionError">> => pyrlang_exception:type(<<"ZeroDivisionError">>),
        <<"__import__">> => {py_native_call, fun builtin_import/2},
        <<"abs">> => fun builtin_abs/1,
        <<"all">> => {py_native_varargs, fun builtin_all/1},
        <<"any">> => {py_native_varargs, fun builtin_any/1},
        <<"bool">> => builtin_type_class(<<"bool">>, {py_native_varargs, fun builtin_bool/1}),
        <<"bytes">> => builtin_type_class(<<"bytes">>, {py_native_varargs, fun builtin_bytes/1}),
        <<"bytearray">> => builtin_type_class(
            <<"bytearray">>, {py_native_varargs, fun builtin_bytes/1}
        ),
        <<"callable">> => fun builtin_callable/1,
        <<"chr">> => fun builtin_chr/1,
        <<"delattr">> => fun builtin_delattr/2,
        <<"dict">> => builtin_type_class(<<"dict">>, {py_native_call, fun builtin_dict_call/2}),
        <<"divmod">> => fun builtin_divmod/2,
        <<"enumerate">> => {py_native_call, fun builtin_enumerate/2},
        <<"eval">> => {py_native_varargs, fun builtin_eval/1},
        <<"filter">> => {py_native_varargs, fun builtin_filter/1},
        <<"float">> => builtin_type_class(<<"float">>, {py_native_varargs, fun builtin_float/1}),
        <<"format">> => {py_native_varargs, fun builtin_format/1},
        <<"frozenset">> => builtin_type_class(
            <<"frozenset">>, {py_native_varargs, fun builtin_set/1}
        ),
        <<"getattr">> => {py_native_varargs, fun builtin_getattr/1},
        <<"hasattr">> => fun builtin_hasattr/2,
        <<"hash">> => fun builtin_hash/1,
        <<"id">> => fun builtin_id/1,
        <<"input">> => {py_native_varargs, fun builtin_input/1},
        <<"int">> => builtin_type_class(<<"int">>, {py_native_varargs, fun builtin_int/1}),
        <<"iter">> => {py_native_varargs, fun builtin_iter/1},
        <<"isinstance">> => fun builtin_isinstance/2,
        <<"issubclass">> => fun builtin_issubclass/2,
        <<"len">> => fun builtin_len/1,
        <<"list">> => builtin_type_class(<<"list">>, {py_native_varargs, fun builtin_list/1}),
        <<"map">> => {py_native_varargs, fun builtin_map/1},
        <<"max">> => {py_native_call, fun builtin_max/2},
        <<"memoryview">> => builtin_type_class(
            <<"memoryview">>, {py_native_varargs, fun builtin_object/1}
        ),
        <<"min">> => {py_native_call, fun builtin_min/2},
        <<"next">> => {py_native_varargs, fun builtin_next/1},
        <<"object">> => builtin_type_class(<<"object">>, {py_native_varargs, fun builtin_object/1}),
        <<"open">> => {py_native_call, fun builtin_open_call/2},
        <<"ord">> => fun builtin_ord/1,
        <<"print">> => {py_native_call, fun builtin_print/2},
        <<"property">> => builtin_type_class(
            <<"property">>, {py_native_call, fun builtin_property/2}
        ),
        <<"range">> => builtin_type_class(<<"range">>, {py_native_varargs, fun builtin_range/1}),
        <<"repr">> => fun builtin_repr/1,
        <<"reversed">> => {py_native_varargs, fun builtin_reversed/1},
        <<"round">> => {py_native_varargs, fun builtin_round/1},
        <<"dir">> => fun builtin_dir/1,
        <<"set">> => builtin_type_class(<<"set">>, {py_native_varargs, fun builtin_set/1}),
        <<"setattr">> => fun builtin_setattr/3,
        <<"slice">> => builtin_type_class(<<"slice">>, {py_native_varargs, fun builtin_slice/1}),
        <<"sorted">> => {py_native_call, fun builtin_sorted/2},
        <<"str">> => builtin_type_class(<<"str">>, str_type_constructor()),
        <<"staticmethod">> => builtin_type_class(
            <<"staticmethod">>, {py_native_varargs, fun builtin_staticmethod/1}
        ),
        <<"classmethod">> => builtin_type_class(
            <<"classmethod">>, {py_native_varargs, fun builtin_classmethod/1}
        ),
        <<"complex">> => builtin_type_class(
            <<"complex">>, {py_native_varargs, fun builtin_complex/1}
        ),
        <<"sum">> => {py_native_call, fun builtin_sum/2},
        <<"tuple">> => builtin_type_class(<<"tuple">>, {py_native_varargs, fun builtin_tuple/1}),
        <<"type">> => builtin_type_class(<<"type">>, {py_native_call, fun builtin_type/2}),
        <<"super">> => {py_native_varargs, fun pyrlang_object:super/1},
        <<"vars">> => {py_native_varargs, fun builtin_vars/1},
        <<"zip">> => {py_native_call, fun builtin_zip_call/2}
    }.

builtin_type_class(Name, Constructor) ->
    Key = {pyrlang_builtin_type_class, Name},
    case erlang:get(Key) of
        undefined ->
            create_builtin_type_class(Key, Name, Constructor);
        Class ->
            try pyrlang_heap:type(Class) of
                class -> Class;
                _Other -> create_builtin_type_class(Key, Name, Constructor)
            catch
                _:_ -> create_builtin_type_class(Key, Name, Constructor)
            end
    end.

create_builtin_type_class(Key, Name, Constructor) ->
    BaseAttrs =
        case Name of
            <<"object">> -> #{};
            _ -> #{<<"__pyrlang_builtin_constructor__">> => Constructor}
        end,
    Attrs = maps:merge(
        BaseAttrs,
        builtin_type_methods(Name)
    ),
    Bases =
        case Name of
            <<"object">> -> [];
            _ -> [builtin_type_class(<<"object">>, {py_native_varargs, fun builtin_object/1})]
        end,
    Class = pyrlang_object:new_class(Name, Bases, Attrs),
    erlang:put(Key, Class),
    Class.

str_type_constructor() ->
    {py_native_call, fun builtin_str_call/2}.

builtin_type_methods(<<"dict">>) ->
    #{
        <<"__new__">> => {py_native_call, fun dict_dunder_new/2},
        <<"__init__">> => {py_native_call, fun dict_dunder_init/2},
        <<"__getitem__">> => fun dict_dunder_getitem/2,
        <<"__setitem__">> => fun dict_dunder_setitem/3,
        <<"__delitem__">> => fun dict_dunder_delitem/2,
        <<"__contains__">> => fun dict_dunder_contains/2,
        <<"fromkeys">> => {py_native_varargs, fun dict_fromkeys/1},
        <<"get">> => {py_native_varargs, fun dict_dunder_get/1},
        <<"clear">> => fun dict_dunder_clear/1,
        <<"copy">> => fun dict_dunder_copy/1,
        <<"items">> => fun dict_dunder_items/1,
        <<"keys">> => fun dict_dunder_keys/1,
        <<"pop">> => {py_native_varargs, fun dict_dunder_pop/1},
        <<"setdefault">> => {py_native_varargs, fun dict_dunder_setdefault/1},
        <<"update">> => {py_native_call, fun dict_dunder_update/2},
        <<"values">> => fun dict_dunder_values/1
    };
builtin_type_methods(<<"list">>) ->
    #{
        <<"__new__">> => {py_native_call, fun list_dunder_new/2},
        <<"__getitem__">> => fun list_dunder_getitem/2,
        <<"__setitem__">> => fun list_dunder_setitem/3,
        <<"__contains__">> => fun list_dunder_contains/2,
        <<"append">> => fun list_dunder_append/2,
        <<"extend">> => fun list_dunder_extend/2,
        <<"insert">> => fun list_dunder_insert/3
    };
builtin_type_methods(<<"int">>) ->
    #{
        <<"__new__">> => {py_native_varargs, fun int_dunder_new/1},
        <<"__add__">> => fun int_dunder_add/2,
        <<"from_bytes">> => {py_native_call, fun int_from_bytes/2}
    };
builtin_type_methods(<<"float">>) ->
    #{
        <<"__repr__">> => fun float_dunder_repr/1,
        <<"__str__">> => fun float_dunder_repr/1
    };
builtin_type_methods(<<"str">>) ->
    #{
        <<"__new__">> => {py_native_call, fun str_dunder_new/2},
        <<"__iter__">> => fun str_dunder_iter/1,
        <<"__getitem__">> => fun str_dunder_getitem/2,
        <<"maketrans">> => {py_native_varargs, fun str_maketrans/1}
    };
builtin_type_methods(<<"bytes">>) ->
    #{
        <<"maketrans">> => {py_native_varargs, fun bytes_maketrans/1},
        <<"fromhex">> => {py_native_varargs, fun bytes_fromhex/1}
    };
builtin_type_methods(<<"bytearray">>) ->
    #{
        <<"maketrans">> => {py_native_varargs, fun bytes_maketrans/1},
        <<"fromhex">> => {py_native_varargs, fun bytes_fromhex/1}
    };
builtin_type_methods(<<"tuple">>) ->
    #{
        <<"__new__">> => {py_native_varargs, fun tuple_dunder_new/1}
    };
builtin_type_methods(<<"type">>) ->
    #{
        <<"__new__">> => {py_native_call, fun type_dunder_new/2},
        <<"__init__">> => {py_native_call, fun type_dunder_init/2},
        <<"__instancecheck__">> => fun type_dunder_instancecheck/2,
        <<"__subclasscheck__">> => fun type_dunder_subclasscheck/2,
        <<"__bases__">> => type_descriptor(<<"__bases__">>),
        <<"__dict__">> => type_descriptor(<<"__dict__">>),
        <<"__mro__">> => type_descriptor(<<"__mro__">>)
    };
builtin_type_methods(<<"object">>) ->
    #{
        <<"__new__">> => {py_native_varargs, fun object_dunder_new/1},
        <<"__init__">> => {py_native_call, fun object_dunder_init/2},
        <<"__init_subclass__">> => {py_native_varargs, fun object_dunder_init_subclass/1},
        <<"__setattr__">> => {py_native_varargs, fun object_dunder_setattr/1},
        <<"__delattr__">> => {py_native_varargs, fun object_dunder_delattr/1},
        <<"__eq__">> => fun object_dunder_eq/2,
        <<"__ne__">> => fun object_dunder_ne/2,
        <<"__repr__">> => fun object_dunder_repr/1,
        <<"__str__">> => fun object_dunder_repr/1,
        <<"__format__">> => fun object_dunder_format/2,
        <<"__reduce_ex__">> => fun object_dunder_reduce_ex/2
    };
builtin_type_methods(_Name) ->
    #{}.

generic_alias(Origin, Args) ->
    {py_generic_alias, Origin, Args}.

generic_alias_type() ->
    builtin_type_class(<<"GenericAlias">>, {py_native_varargs, fun builtin_generic_alias/1}).

type_union(Left, Right) ->
    case {type_union_operand(Left), type_union_operand(Right)} of
        {true, true} ->
            {ok,
                {py_union_type,
                    dedupe_type_union_options(
                        type_union_options(Left) ++ type_union_options(Right)
                    )}};
        _ ->
            error
    end.

union_type() ->
    builtin_type_class(<<"UnionType">>, {py_native_varargs, fun builtin_object/1}).

none_type() ->
    builtin_type_class(<<"NoneType">>, {py_native_varargs, fun builtin_object/1}).

ellipsis_type() ->
    builtin_type_class(<<"EllipsisType">>, {py_native_varargs, fun builtin_object/1}).

not_implemented_type() ->
    builtin_type_class(<<"NotImplementedType">>, {py_native_varargs, fun builtin_object/1}).

function_type() ->
    builtin_type_class(<<"function">>, {py_native_varargs, fun builtin_object/1}).

builtin_function_type() ->
    builtin_type_class(<<"builtin_function_or_method">>, {py_native_varargs, fun builtin_object/1}).

method_type() ->
    builtin_type_class(<<"method">>, {py_native_varargs, fun builtin_object/1}).

module_type() ->
    builtin_type_class(<<"module">>, {py_native_varargs, fun builtin_object/1}).

code_type() ->
    builtin_type_class(<<"code">>, {py_native_varargs, fun builtin_object/1}).

simple_namespace_type() ->
    builtin_type_class(<<"SimpleNamespace">>, {py_native_varargs, fun builtin_object/1}).

cell_type() ->
    builtin_type_class(<<"cell">>, {py_native_varargs, fun builtin_object/1}).

generator_type() ->
    builtin_type_class(<<"generator">>, {py_native_varargs, fun builtin_object/1}).

coroutine_type() ->
    builtin_type_class(<<"coroutine">>, {py_native_varargs, fun builtin_object/1}).

async_generator_type() ->
    builtin_type_class(<<"async_generator">>, {py_native_varargs, fun builtin_object/1}).

traceback_type() ->
    builtin_type_class(<<"traceback">>, {py_native_varargs, fun builtin_object/1}).

frame_type() ->
    builtin_type_class(<<"frame">>, {py_native_varargs, fun builtin_object/1}).

wrapper_descriptor_type() ->
    builtin_type_class(<<"wrapper_descriptor">>, {py_native_varargs, fun builtin_object/1}).

method_wrapper_type() ->
    builtin_type_class(<<"method-wrapper">>, {py_native_varargs, fun builtin_object/1}).

method_descriptor_type() ->
    builtin_type_class(<<"method_descriptor">>, {py_native_varargs, fun builtin_object/1}).

classmethod_descriptor_type() ->
    builtin_type_class(<<"classmethod_descriptor">>, {py_native_varargs, fun builtin_object/1}).

getset_descriptor_type() ->
    builtin_type_class(<<"getset_descriptor">>, {py_native_varargs, fun builtin_object/1}).

member_descriptor_type() ->
    builtin_type_class(<<"member_descriptor">>, {py_native_varargs, fun builtin_object/1}).

-spec lookup(binary()) -> {ok, term()} | error.
lookup(Name) ->
    maps:find(Name, env()).

open(Args) ->
    builtin_open(Args).

builtin_open_call(Args, KwArgs) ->
    Allowed = [
        <<"mode">>,
        <<"buffering">>,
        <<"encoding">>,
        <<"errors">>,
        <<"newline">>,
        <<"closefd">>,
        <<"opener">>
    ],
    Unknown = maps:keys(maps:without(Allowed, KwArgs)),
    case Unknown of
        [] -> ok;
        _ -> erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end,
    case Args of
        [Path] ->
            builtin_open([Path, maps:get(<<"mode">>, KwArgs, <<"r">>)]);
        [Path, Mode] ->
            case maps:is_key(<<"mode">>, KwArgs) of
                true -> erlang:error({type_error, {multiple_values_for_argument, <<"mode">>}});
                false -> builtin_open([Path, Mode])
            end;
        _ ->
            erlang:error({arity_error, {open, length(Args)}})
    end.

builtin_len({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list ->
            length(pyrlang_heap:list_items(Ref));
        dict ->
            length(pyrlang_heap:dict_items(Ref));
        set ->
            length(pyrlang_heap:set_items(Ref));
        instance ->
            case tuple_subclass_items(Ref) of
                {ok, Items} ->
                    length(Items);
                error ->
                    case string_subclass_value(Ref) of
                        {ok, Value} ->
                            string_length(Value);
                        error ->
                            try pyrlang_object:get_attr(Ref, <<"__len__">>) of
                                Len ->
                                    pyrlang_eval:call(Len, [])
                            catch
                                error:{attribute_error, _Name} ->
                                    erlang:error({type_error, {len, instance}})
                            end
                    end
            end;
        object ->
            length(pyrlang_heap:object_attrs(Ref));
        Type ->
            erlang:error({type_error, {len, Type}})
    end;
builtin_len(Binary) when is_binary(Binary) ->
    string_length(Binary);
builtin_len(Tuple) when is_tuple(Tuple) ->
    tuple_size(Tuple);
builtin_len(List) when is_list(List) ->
    length(List).

string_length(Binary) ->
    case unicode:characters_to_list(Binary) of
        Chars when is_list(Chars) -> length(Chars);
        _Other -> byte_size(Binary)
    end.

builtin_bool([]) ->
    false;
builtin_bool([Value]) ->
    truthy(Value);
builtin_bool(Args) ->
    erlang:error({arity_error, {bool, length(Args)}}).

builtin_all([Iterable]) ->
    lists:all(fun truthy/1, pyrlang_iter:values(Iterable));
builtin_all(Args) ->
    erlang:error({arity_error, {all, length(Args)}}).

builtin_any([Iterable]) ->
    trace_builtin_flow(any_start, Iterable),
    Values = pyrlang_iter:values(Iterable),
    trace_builtin_flow({any_values, length(Values)}, Values),
    Result = lists:any(fun truthy/1, Values),
    trace_builtin_flow(any_done, Result),
    Result;
builtin_any(Args) ->
    erlang:error({arity_error, {any, length(Args)}}).

builtin_callable({py_function, _Params, _Body, _Env}) ->
    true;
builtin_callable({py_function, _Params, _Body, _Env, _IsGenerator}) ->
    true;
builtin_callable({py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass}) ->
    true;
builtin_callable({py_bound_method, _Callable, _Self}) ->
    true;
builtin_callable({py_exception_type, _Type}) ->
    true;
builtin_callable({py_native_varargs, _Fun}) ->
    true;
builtin_callable({py_native_varargs, _Fun, _Bind}) ->
    true;
builtin_callable({py_native_call, _Fun}) ->
    true;
builtin_callable({py_native_call, _Fun, _Bind}) ->
    true;
builtin_callable({py_native_callable, _Fun}) ->
    true;
builtin_callable({py_native_callable, _Fun, _Bind}) ->
    true;
builtin_callable(Fun) when is_function(Fun) ->
    true;
builtin_callable({py_ref, _} = Ref) ->
    case is_class_ref(Ref) of
        true ->
            true;
        false ->
            try pyrlang_object:get_attr(Ref, <<"__call__">>) of
                _Call -> true
            catch
                error:{attribute_error, _Name} ->
                    false;
                throw:{py_exception, Exception} ->
                    case pyrlang_exception:exception_type(Exception) of
                        <<"AttributeError">> -> false;
                        _ -> pyrlang_exception:raise(Exception)
                    end
            end
    end;
builtin_callable(_Value) ->
    false.

builtin_next([Iterator]) ->
    pyrlang_iter:next(Iterator);
builtin_next([Iterator, Default]) ->
    try pyrlang_iter:next(Iterator) of
        Value -> Value
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"StopIteration">> -> Default;
                _ -> pyrlang_exception:raise(Exception)
            end
    end;
builtin_next(Args) ->
    erlang:error({arity_error, {next, length(Args)}}).

builtin_iter([Iterable]) ->
    pyrlang_iter:iter(Iterable);
builtin_iter([Callable, Sentinel]) ->
    case builtin_callable(Callable) of
        true ->
            pyrlang_iter:callable_sentinel(Callable, Sentinel);
        false ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"TypeError">>), <<"iter(v, w): v must be callable">>
                )
            )
    end;
builtin_iter(Args) ->
    erlang:error({arity_error, {iter, length(Args)}}).

builtin_abs({py_complex, Real, Imag}) ->
    math:sqrt(Real * Real + Imag * Imag);
builtin_abs(Value) ->
    case numeric_value(Value) of
        {ok, Number} ->
            abs(Number);
        error ->
            case call_binary_special(Value, <<"__abs__">>, []) of
                {ok, Result} -> Result;
                error -> erlang:error({type_error, {abs, Value}})
            end
    end.

builtin_divmod(Left, Right) ->
    case {numeric_value(Left), numeric_value(Right)} of
        {{ok, _LeftNum}, {ok, 0}} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ZeroDivisionError">>),
                    <<"integer division or modulo by zero">>
                )
            );
        {{ok, LeftNum}, {ok, RightNum}} ->
            Quotient = floor(LeftNum / RightNum),
            {Quotient, LeftNum - Quotient * RightNum};
        _ ->
            case call_binary_special(Left, <<"__divmod__">>, [Right]) of
                {ok, Value} ->
                    Value;
                error ->
                    case call_binary_special(Right, <<"__rdivmod__">>, [Left]) of
                        {ok, Value} -> Value;
                        error -> erlang:error({type_error, {divmod, Left, Right}})
                    end
            end
    end.

builtin_round([Number]) ->
    round_numeric_argument(Number, none);
builtin_round([Number, none]) ->
    round_numeric_argument(Number, none);
builtin_round([Number, NDigits]) ->
    case integer_argument(NDigits) of
        {ok, Places} ->
            round_numeric_argument(Number, Places);
        error ->
            erlang:error({type_error, {round, ndigits, NDigits}})
    end;
builtin_round(Args) ->
    erlang:error({arity_error, {round, length(Args)}}).

round_numeric_argument(Number, NDigits) ->
    case numeric_value(Number) of
        {ok, Value} -> round_numeric(Value, NDigits);
        error -> erlang:error({type_error, {round, Number}})
    end.

round_numeric(Value, none) ->
    round_half_even_to_int(Value);
round_numeric(Value, Places) when is_integer(Value), Places >= 0 ->
    Value;
round_numeric(Value, Places) when is_integer(Value) ->
    Scale = pow10_int(-Places),
    round_half_even_to_int(Value / Scale) * Scale;
round_numeric(Value, Places) when is_float(Value), Places >= 0 ->
    Scale = pow10_float(Places),
    round_half_even_to_int(Value * Scale) / Scale;
round_numeric(Value, Places) when is_float(Value) ->
    Scale = pow10_float(-Places),
    round_half_even_to_int(Value / Scale) * Scale.

round_half_even_to_int(Value) when is_integer(Value) ->
    Value;
round_half_even_to_int(Value) when is_float(Value) ->
    Floor = erlang:floor(Value),
    Fraction = Value - Floor,
    case Fraction of
        _ when Fraction < 0.5 ->
            Floor;
        _ when Fraction > 0.5 ->
            Floor + 1;
        _Half ->
            case Floor rem 2 of
                0 -> Floor;
                _ -> Floor + 1
            end
    end.

pow10_int(Places) when Places >= 0 ->
    pow10_int(Places, 1).

pow10_int(0, Acc) ->
    Acc;
pow10_int(Places, Acc) ->
    pow10_int(Places - 1, Acc * 10).

pow10_float(Places) ->
    pow10_int(Places) * 1.0.

integer_argument(true) ->
    {ok, 1};
integer_argument(false) ->
    {ok, 0};
integer_argument(Value) when is_integer(Value) ->
    {ok, Value};
integer_argument({py_ref, _} = Value) ->
    int_subclass_value(Value);
integer_argument(_Value) ->
    error.

numeric_value(true) ->
    {ok, 1};
numeric_value(false) ->
    {ok, 0};
numeric_value(Value) when is_integer(Value); is_float(Value) ->
    {ok, Value};
numeric_value({py_ref, _} = Value) ->
    int_subclass_value(Value);
numeric_value(_Value) ->
    error.

call_binary_special({py_ref, _} = Object, Method, Args) ->
    try pyrlang_object:get_attr(Object, Method) of
        Callable ->
            case pyrlang_eval:call(Callable, Args) of
                not_implemented -> error;
                Value -> {ok, Value}
            end
    catch
        error:{attribute_error, _Attr} -> error
    end;
call_binary_special(_Object, _Method, _Args) ->
    error.

builtin_int([]) ->
    0;
builtin_int([Value]) when is_integer(Value) ->
    Value;
builtin_int([Value]) when is_float(Value) ->
    trunc(Value);
builtin_int([true]) ->
    1;
builtin_int([false]) ->
    0;
builtin_int([Value]) when is_binary(Value) ->
    try
        binary_to_integer(Value)
    catch
        error:badarg ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Value)
            )
    end;
builtin_int([Value]) when is_list(Value) ->
    builtin_int([unicode:characters_to_binary(Value)]);
builtin_int([Value, Base]) when is_binary(Value), is_integer(Base) ->
    parse_int_binary(Value, Base);
builtin_int([Value, Base]) when is_list(Value), is_integer(Base) ->
    parse_int_binary(unicode:characters_to_binary(Value), Base);
builtin_int([{py_ref, _} = Value]) ->
    case int_subclass_value(Value) of
        {ok, IntValue} ->
            IntValue;
        error ->
            try pyrlang_object:get_attr(Value, <<"__int__">>) of
                Callable -> pyrlang_eval:call(Callable, [])
            catch
                throw:{py_exception, Exception} ->
                    case pyrlang_exception:exception_type(Exception) of
                        <<"AttributeError">> -> erlang:error({type_error, {int, Value}});
                        _ -> pyrlang_exception:raise(Exception)
                    end
            end
    end;
builtin_int(Args) ->
    erlang:error({arity_error, {int, length(Args)}}).

int_dunder_new([Class | Args]) ->
    Value = builtin_int(Args),
    case int_subclass_constructor(Class) of
        true ->
            Instance = pyrlang_object:instantiate(Class),
            ok = pyrlang_object:set_attr(Instance, <<"__pyrlang_value__">>, Value),
            ok = pyrlang_object:set_attr(Instance, <<"__pyrlang_int_value__">>, Value),
            Instance;
        false ->
            Value
    end;
int_dunder_new(Args) ->
    erlang:error({arity_error, {'int.__new__', length(Args)}}).

int_dunder_add(Left, Right) when is_integer(Left), is_integer(Right) ->
    Left + Right;
int_dunder_add(Left, Right) when is_integer(Left), is_float(Right) ->
    Left + Right;
int_dunder_add(Left, Right) when is_integer(Left), is_boolean(Right) ->
    Left + numeric_bool(Right);
int_dunder_add(_Left, _Right) ->
    not_implemented.

numeric_bool(true) -> 1;
numeric_bool(false) -> 0.

int_subclass_constructor(Class) ->
    IntClass = builtin_type_class(<<"int">>, {py_native_varargs, fun builtin_int/1}),
    is_class_ref(Class) andalso Class =/= IntClass andalso
        lists:member(IntClass, pyrlang_object:mro(Class)).

int_subclass_value({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
            case maps:find(<<"__pyrlang_int_value__">>, Attrs) of
                {ok, Value} when is_integer(Value) -> {ok, Value};
                _ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end;
int_subclass_value(_Other) ->
    error.

parse_int_binary(Value, Base0) ->
    Clean0 = binary:replace(trim_binary(Value), <<"_">>, <<>>, [global]),
    {Sign, Clean1} = int_sign(Clean0),
    {Base, Digits} = int_digits_for_base(Clean1, Base0),
    try
        Sign * binary_to_integer(Digits, Base)
    catch
        error:badarg ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Value)
            )
    end.

int_sign(<<$-, Rest/binary>>) ->
    {-1, Rest};
int_sign(<<$+, Rest/binary>>) ->
    {1, Rest};
int_sign(Value) ->
    {1, Value}.

int_digits_for_base(<<"0x", Rest/binary>>, 0) ->
    {16, Rest};
int_digits_for_base(<<"0X", Rest/binary>>, 0) ->
    {16, Rest};
int_digits_for_base(<<"0o", Rest/binary>>, 0) ->
    {8, Rest};
int_digits_for_base(<<"0O", Rest/binary>>, 0) ->
    {8, Rest};
int_digits_for_base(<<"0b", Rest/binary>>, 0) ->
    {2, Rest};
int_digits_for_base(<<"0B", Rest/binary>>, 0) ->
    {2, Rest};
int_digits_for_base(Digits, 0) ->
    {10, Digits};
int_digits_for_base(Digits, Base) when Base >= 2, Base =< 36 ->
    {Base, Digits};
int_digits_for_base(_Digits, Base) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), {invalid_base, Base})
    ).

trim_binary(Binary) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Binary))).

builtin_float([]) ->
    0.0;
builtin_float([Value]) when is_float(Value) ->
    Value;
builtin_float([{py_float_special, _Kind} = Value]) ->
    Value;
builtin_float([Value]) when is_integer(Value) ->
    Value * 1.0;
builtin_float([true]) ->
    1.0;
builtin_float([false]) ->
    0.0;
builtin_float([Value]) when is_binary(Value) ->
    case special_float(Value) of
        {ok, Special} ->
            Special;
        error ->
            try
                binary_to_float(Value)
            catch
                error:badarg ->
                    try
                        binary_to_integer(Value) * 1.0
                    catch
                        error:badarg ->
                            pyrlang_exception:raise(
                                pyrlang_exception:make(
                                    pyrlang_exception:type(<<"ValueError">>), Value
                                )
                            )
                    end
            end
    end;
builtin_float([Value]) when is_list(Value) ->
    builtin_float([unicode:characters_to_binary(Value)]);
builtin_float(Args) ->
    erlang:error({arity_error, {float, length(Args)}}).

special_float(Value) ->
    Lower = list_to_binary(string:lowercase(binary_to_list(Value))),
    case Lower of
        <<"nan">> -> {ok, {py_float_special, nan}};
        <<"+nan">> -> {ok, {py_float_special, nan}};
        <<"inf">> -> {ok, {py_float_special, inf}};
        <<"+inf">> -> {ok, {py_float_special, inf}};
        <<"infinity">> -> {ok, {py_float_special, inf}};
        <<"+infinity">> -> {ok, {py_float_special, inf}};
        <<"-inf">> -> {ok, {py_float_special, neg_inf}};
        <<"-infinity">> -> {ok, {py_float_special, neg_inf}};
        _ -> error
    end.

builtin_complex([]) ->
    {py_complex, 0.0, 0.0};
builtin_complex([Real]) when is_integer(Real) ->
    {py_complex, Real * 1.0, 0.0};
builtin_complex([Real]) when is_float(Real) ->
    {py_complex, Real, 0.0};
builtin_complex([{py_complex, _Real, _Imag} = Value]) ->
    Value;
builtin_complex([Real, Imag]) when is_integer(Real), is_integer(Imag) ->
    {py_complex, Real * 1.0, Imag * 1.0};
builtin_complex([Real, Imag]) when is_integer(Real), is_float(Imag) ->
    {py_complex, Real * 1.0, Imag};
builtin_complex([Real, Imag]) when is_float(Real), is_integer(Imag) ->
    {py_complex, Real, Imag * 1.0};
builtin_complex([Real, Imag]) when is_float(Real), is_float(Imag) ->
    {py_complex, Real, Imag};
builtin_complex(Args) ->
    erlang:error({arity_error, {complex, length(Args)}}).

builtin_object([]) ->
    pyrlang_object:instantiate(pyrlang_object:new_class(<<"object">>, [], #{}));
builtin_object(Args) ->
    erlang:error({arity_error, {object, length(Args)}}).

builtin_input([]) ->
    read_input_line();
builtin_input([Prompt]) ->
    io:put_chars(standard_io, normalize_name(Prompt)),
    read_input_line();
builtin_input(Args) ->
    erlang:error({arity_error, {input, length(Args)}}).

read_input_line() ->
    case io:get_line(standard_io, "") of
        eof ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"EOFError">>), <<"EOF when reading a line">>
                )
            );
        Line ->
            strip_line_ending(unicode:characters_to_binary(Line))
    end.

strip_line_ending(Line) ->
    Size = byte_size(Line),
    case Size of
        N when N >= 2 ->
            case binary:part(Line, N - 2, 2) of
                <<"\r\n">> -> binary:part(Line, 0, N - 2);
                _ -> strip_single_newline(Line)
            end;
        _ ->
            strip_single_newline(Line)
    end.

strip_single_newline(Line) ->
    Size = byte_size(Line),
    case Size of
        N when N >= 1 ->
            case binary:part(Line, N - 1, 1) of
                <<"\n">> -> binary:part(Line, 0, N - 1);
                _ -> Line
            end;
        _ ->
            Line
    end.

object_dunder_new([Class | _Args]) ->
    pyrlang_object:instantiate(Class);
object_dunder_new(Args) ->
    erlang:error({arity_error, {'object.__new__', length(Args)}}).

object_dunder_init([_Self | _Args], _KwArgs) ->
    none;
object_dunder_init(Args, _KwArgs) ->
    erlang:error({arity_error, {'object.__init__', length(Args)}}).

object_dunder_init_subclass([_Class | _Args]) ->
    none;
object_dunder_init_subclass(Args) ->
    erlang:error({arity_error, {'object.__init_subclass__', length(Args)}}).

object_dunder_setattr([Self, Name, Value]) ->
    ok = pyrlang_object:set_attr(Self, normalize_name(Name), Value),
    none;
object_dunder_setattr(Args) ->
    erlang:error({arity_error, {'object.__setattr__', length(Args)}}).

object_dunder_delattr([Self, Name]) ->
    ok = pyrlang_object:del_attr(Self, normalize_name(Name)),
    none;
object_dunder_delattr(Args) ->
    erlang:error({arity_error, {'object.__delattr__', length(Args)}}).

builtin_hash({py_function, _Params, _Body, _Env} = Value) ->
    builtin_id(Value);
builtin_hash({py_function, _Params, _Body, _Env, _IsGenerator} = Value) ->
    builtin_id(Value);
builtin_hash({py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass} = Value) ->
    builtin_id(Value);
builtin_hash({py_bound_method, _Callable, _Self} = Value) ->
    builtin_id(Value);
builtin_hash(Fun) when is_function(Fun) ->
    builtin_id(Fun);
builtin_hash(Value) ->
    erlang:phash2(Value).

builtin_id({py_ref, Id}) ->
    Id;
builtin_id({py_function, Params, Body, _Env}) ->
    erlang:phash2({pyrlang_function, Params, Body});
builtin_id({py_function, Params, Body, _Env, Mode}) ->
    erlang:phash2({pyrlang_function, Params, Body, Mode});
builtin_id({py_function, Params, Body, _Env, Mode, OwnerClass}) ->
    erlang:phash2({pyrlang_function, Params, Body, Mode, OwnerClass});
builtin_id({py_bound_method, Callable, Self}) ->
    erlang:phash2({pyrlang_bound_method, builtin_id(Callable), builtin_id(Self)});
builtin_id(Fun) when is_function(Fun) ->
    {module, Module} = erlang:fun_info(Fun, module),
    {name, Name} = erlang:fun_info(Fun, name),
    {arity, Arity} = erlang:fun_info(Fun, arity),
    erlang:phash2({pyrlang_native_function, Module, Name, Arity});
builtin_id(Value) ->
    erlang:phash2({pyrlang_id, Value}).

builtin_dir({py_ref, _} = Ref) ->
    Names =
        case pyrlang_heap:type(Ref) of
            module ->
                maps:keys(pyrlang_module:env(Ref));
            instance ->
                instance_dir_names(Ref);
            class ->
                class_dir_names(Ref);
            dict ->
                [
                    <<"clear">>,
                    <<"copy">>,
                    <<"get">>,
                    <<"items">>,
                    <<"keys">>,
                    <<"setdefault">>,
                    <<"values">>
                ];
            list ->
                [<<"append">>, <<"copy">>, <<"extend">>, <<"insert">>, <<"pop">>];
            set ->
                [<<"add">>, <<"discard">>];
            _Type ->
                []
        end,
    pyrlang_heap:list(lists:sort(Names));
builtin_dir(_Value) ->
    pyrlang_heap:list([]).

instance_dir_names(Ref) ->
    Data = pyrlang_heap:data(Ref),
    Attrs = maps:keys(maps:get(attrs, Data)),
    ClassAttrs =
        case maps:find(class, Data) of
            {ok, Class} -> class_dir_names(Class);
            error -> []
        end,
    lists:usort(Attrs ++ ClassAttrs).

class_dir_names(Class) ->
    lists:usort(
        lists:flatmap(
            fun
                ({py_ref, _} = MroClass) ->
                    maps:keys(maps:get(attrs, pyrlang_heap:data(MroClass)));
                (_Other) ->
                    []
            end,
            pyrlang_object:mro(Class)
        )
    ).

builtin_vars([]) ->
    erlang:error({type_error, {vars, no_eval_context}});
builtin_vars([Object]) ->
    case Object of
        {py_ref, _} ->
            case pyrlang_heap:type(Object) of
                instance ->
                    Data = pyrlang_heap:data(Object),
                    pyrlang_heap:dict(maps:to_list(maps:get(attrs, Data)));
                class ->
                    pyrlang_object:get_attr(Object, <<"__dict__">>);
                module ->
                    pyrlang_heap:dict(maps:to_list(pyrlang_module:env(Object)));
                _Type ->
                    builtin_vars_from_attr(Object)
            end;
        _ ->
            builtin_vars_from_attr(Object)
    end;
builtin_vars(Args) ->
    erlang:error({arity_error, {vars, length(Args)}}).

builtin_vars_from_attr(Object) ->
    try pyrlang_object:get_attr(Object, <<"__dict__">>) of
        Dict -> Dict
    catch
        error:{attribute_error, _Name} ->
            erlang:error({type_error, {vars, Object}})
    end.

builtin_format([Value]) ->
    builtin_str(Value);
builtin_format([Value, _Spec]) ->
    builtin_str(Value);
builtin_format(Args) ->
    erlang:error({arity_error, {format, length(Args)}}).

builtin_print(Args, KwArgs) ->
    ensure_allowed_kwargs(KwArgs, [<<"sep">>, <<"end">>, <<"file">>, <<"flush">>], print),
    Sep = print_text_arg(maps:get(<<"sep">>, KwArgs, <<" ">>), <<" ">>),
    End = print_text_arg(maps:get(<<"end">>, KwArgs, <<"\n">>), <<"\n">>),
    Text = print_join([builtin_str(Arg) || Arg <- Args], Sep),
    ok = print_write(<<Text/binary, End/binary>>, maps:get(<<"file">>, KwArgs, none)),
    none.

print_text_arg(none, Default) ->
    Default;
print_text_arg(Value, _Default) when is_binary(Value) ->
    Value;
print_text_arg(Value, _Default) when is_list(Value) ->
    unicode:characters_to_binary(Value);
print_text_arg({py_ref, _} = Value, _Default) ->
    case string_subclass_value(Value) of
        {ok, Text} -> Text;
        error -> erlang:error({type_error, {print_expected_string_or_none, Value}})
    end;
print_text_arg(Value, _Default) ->
    erlang:error({type_error, {print_expected_string_or_none, Value}}).

print_join([], _Sep) ->
    <<>>;
print_join([Part], _Sep) ->
    Part;
print_join([Part | Rest], Sep) ->
    lists:foldl(fun(Next, Acc) -> <<Acc/binary, Sep/binary, Next/binary>> end, Part, Rest).

print_write(Output, none) ->
    io:put_chars(Output);
print_write(Output, {py_ref, _} = File) ->
    try pyrlang_object:get_attr(File, <<"write">>) of
        Write ->
            _ = pyrlang_eval:call(Write, [Output]),
            ok
    catch
        error:{attribute_error, _Name} ->
            erlang:error({type_error, {print_file_without_write, File}})
    end;
print_write(_Output, File) ->
    erlang:error({type_error, {print_file_without_write, File}}).

builtin_bytes([]) ->
    <<>>;
builtin_bytes([Value]) when is_binary(Value) ->
    Value;
builtin_bytes([Value]) when is_list(Value) ->
    unicode:characters_to_binary(Value);
builtin_bytes([Value]) ->
    iolist_to_binary([byte_value(Item) || Item <- pyrlang_iter:values(Value)]);
builtin_bytes(Args) ->
    erlang:error({arity_error, {bytes, length(Args)}}).

byte_value(Value) when is_integer(Value), Value >= 0, Value =< 255 ->
    Value;
byte_value(Value) ->
    erlang:error({value_error, {byte, Value}}).

builtin_ord(Value) ->
    case unicode_chars(normalize_name(Value)) of
        [Char] -> Char;
        Chars -> erlang:error({type_error, {ord_expected_character, length(Chars)}})
    end.

builtin_chr(Code) when is_integer(Code), Code >= 0, Code =< 16#10FFFF ->
    try <<Code/utf8>> of
        Char -> Char
    catch
        error:badarg -> erlang:error({value_error, {chr, Code}})
    end;
builtin_chr(<<Code:8>>) ->
    <<Code:8>>;
builtin_chr(Code) ->
    erlang:error({type_error, {chr, Code}}).

int_from_bytes(Args, KwArgs0) ->
    case maps:keys(maps:without([<<"byteorder">>, <<"signed">>], KwArgs0)) of
        [] ->
            ok;
        Unknown ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end,
    case Args of
        [] ->
            erlang:error({arity_error, {from_bytes, 0, maps:size(KwArgs0)}});
        [_Bytes, _Byteorder, _Signed | _Rest] ->
            erlang:error({arity_error, {from_bytes, length(Args), maps:size(KwArgs0)}});
        _ ->
            ok
    end,
    check_int_from_bytes_duplicate_args(Args, KwArgs0),
    [Bytes | _] = Args,
    Byteorder = int_byteorder(int_from_bytes_arg(2, <<"byteorder">>, Args, KwArgs0, <<"big">>)),
    Signed = truthy(maps:get(<<"signed">>, KwArgs0, false)),
    ByteValues = int_from_bytes_values(Bytes),
    Unsigned = int_from_bytes_unsigned(ByteValues, Byteorder),
    int_from_bytes_signed(Unsigned, length(ByteValues), Signed).

check_int_from_bytes_duplicate_args(Args, KwArgs) ->
    PositionalKeys = lists:sublist([bytes, <<"byteorder">>], length(Args)),
    case [Key || Key <- PositionalKeys, maps:is_key(Key, KwArgs)] of
        [] -> ok;
        [Key | _] -> erlang:error({type_error, {multiple_values_for_argument, Key}})
    end.

int_from_bytes_arg(Position, Key, Args, KwArgs, Default) ->
    case length(Args) >= Position of
        true -> lists:nth(Position, Args);
        false -> maps:get(Key, KwArgs, Default)
    end.

int_byteorder(Value) when is_binary(Value) ->
    int_byteorder_binary(Value);
int_byteorder(Value) when is_atom(Value) ->
    int_byteorder_binary(atom_to_binary(Value, utf8));
int_byteorder(Value) when is_list(Value) ->
    int_byteorder_binary(unicode:characters_to_binary(Value));
int_byteorder(Value) ->
    erlang:error({type_error, {byteorder, Value}}).

int_byteorder_binary(<<"big">>) ->
    big;
int_byteorder_binary(<<"little">>) ->
    little;
int_byteorder_binary(Value) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), {invalid_byteorder, Value})
    ).

int_from_bytes_values(Bytes) when is_binary(Bytes) ->
    binary_to_list(Bytes);
int_from_bytes_values(Bytes) ->
    [byte_value(Value) || Value <- pyrlang_iter:values(Bytes)].

int_from_bytes_unsigned(ByteValues, little) ->
    int_from_bytes_unsigned(lists:reverse(ByteValues), big);
int_from_bytes_unsigned(ByteValues, big) ->
    lists:foldl(fun(Byte, Acc) -> Acc * 256 + Byte end, 0, ByteValues).

int_from_bytes_signed(Unsigned, 0, _Signed) ->
    Unsigned;
int_from_bytes_signed(Unsigned, Length, true) ->
    Bits = Length * 8,
    SignBit = 1 bsl (Bits - 1),
    case Unsigned >= SignBit of
        true -> Unsigned - (1 bsl Bits);
        false -> Unsigned
    end;
int_from_bytes_signed(Unsigned, _Length, false) ->
    Unsigned.

builtin_str(Value) when is_binary(Value) ->
    Value;
builtin_str(true) ->
    <<"True">>;
builtin_str(false) ->
    <<"False">>;
builtin_str(none) ->
    <<"None">>;
builtin_str(Value) when is_integer(Value) ->
    integer_to_binary(Value);
builtin_str(Value) when is_float(Value) ->
    unicode:characters_to_binary(float_to_list(Value));
builtin_str({py_float_special, nan}) ->
    <<"nan">>;
builtin_str({py_float_special, inf}) ->
    <<"inf">>;
builtin_str({py_float_special, neg_inf}) ->
    <<"-inf">>;
builtin_str(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
builtin_str({py_ref, _} = Ref) ->
    case pyrlang_exception:is_exception(Ref) of
        true ->
            pyrlang_exception:message(Ref);
        false ->
            case pyrlang_heap:type(Ref) of
                instance ->
                    Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
                    case maps:find(<<"__pyrlang_value__">>, Attrs) of
                        {ok, Value} ->
                            case string_subclass_has_custom_str(Ref) of
                                true -> builtin_ref_str(Ref);
                                false -> builtin_str(Value)
                            end;
                        error ->
                            builtin_ref_str(Ref)
                    end;
                _ ->
                    builtin_ref_str(Ref)
            end
    end;
builtin_str(#{py_exception := true} = Exception) ->
    pyrlang_exception:message(Exception);
builtin_str(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

builtin_repr(Value) when is_binary(Value) ->
    Escaped = repr_escape(Value, <<>>),
    <<"'", Escaped/binary, "'">>;
builtin_repr(Value) ->
    builtin_str(Value).

repr_escape(<<>>, Acc) ->
    Acc;
repr_escape(<<"\\", Rest/binary>>, Acc) ->
    repr_escape(Rest, <<Acc/binary, "\\\\">>);
repr_escape(<<"'", Rest/binary>>, Acc) ->
    repr_escape(Rest, <<Acc/binary, "\\'">>);
repr_escape(<<"\n", Rest/binary>>, Acc) ->
    repr_escape(Rest, <<Acc/binary, "\\n">>);
repr_escape(<<"\r", Rest/binary>>, Acc) ->
    repr_escape(Rest, <<Acc/binary, "\\r">>);
repr_escape(<<"\t", Rest/binary>>, Acc) ->
    repr_escape(Rest, <<Acc/binary, "\\t">>);
repr_escape(<<Char/utf8, Rest/binary>>, Acc) ->
    repr_escape(Rest, <<Acc/binary, Char/utf8>>);
repr_escape(<<Byte, Rest/binary>>, Acc) ->
    repr_escape(
        Rest,
        <<Acc/binary, "\\x", (hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>
    ).

hex_digit(Value) when Value < 10 ->
    $0 + Value;
hex_digit(Value) ->
    $a + (Value - 10).

builtin_ref_str(Ref) ->
    try pyrlang_object:get_attr(Ref, <<"__str__">>) of
        Str ->
            case pyrlang_eval:call(Str, []) of
                Value when is_binary(Value) ->
                    Value;
                {py_ref, _} = Returned ->
                    case string_subclass_value(Returned) of
                        {ok, _StringValue} ->
                            Returned;
                        error when Returned =:= Ref ->
                            unicode:characters_to_binary(io_lib:format("~p", [Ref]));
                        error ->
                            builtin_str(Returned)
                    end;
                Other ->
                    builtin_str(Other)
            end
    catch
        _:_ ->
            unicode:characters_to_binary(io_lib:format("~p", [Ref]))
    end.

string_subclass_has_custom_str(Ref) ->
    try string_subclass_has_custom_str_mro(pyrlang_object:mro(object_class(Ref))) of
        Result -> Result
    catch
        _:_ -> false
    end.

string_subclass_has_custom_str_mro([]) ->
    false;
string_subclass_has_custom_str_mro([Class | Rest]) ->
    case class_named(Class, <<"str">>) of
        true ->
            false;
        false ->
            Attrs = maps:get(attrs, pyrlang_heap:data(Class), #{}),
            case maps:is_key(<<"__str__">>, Attrs) of
                true -> true;
                false -> string_subclass_has_custom_str_mro(Rest)
            end
    end.

builtin_str_call(Args, KwArgs) ->
    ensure_allowed_kwargs(KwArgs, [<<"encoding">>, <<"errors">>], str),
    case Args of
        [] when map_size(KwArgs) =:= 0 ->
            <<>>;
        [] ->
            erlang:error({arity_error, {str, 0, maps:size(KwArgs)}});
        [Value] when map_size(KwArgs) =:= 0 ->
            builtin_str(Value);
        [Value] ->
            str_decode(
                Value,
                maps:get(<<"encoding">>, KwArgs, <<"utf-8">>),
                maps:get(<<"errors">>, KwArgs, <<"strict">>)
            );
        [Value, Encoding] ->
            ensure_no_kwarg(KwArgs, <<"encoding">>, str),
            str_decode(Value, Encoding, maps:get(<<"errors">>, KwArgs, <<"strict">>));
        [Value, Encoding, Errors] ->
            ensure_no_kwarg(KwArgs, <<"encoding">>, str),
            ensure_no_kwarg(KwArgs, <<"errors">>, str),
            str_decode(Value, Encoding, Errors);
        _ ->
            erlang:error({arity_error, {str, length(Args), maps:size(KwArgs)}})
    end.

str_decode(Value, Encoding, Errors) when is_binary(Value) ->
    DecodeErrors = normalize_name(Errors),
    case str_input_encoding(Encoding) of
        ascii ->
            str_decode_ascii(Value, DecodeErrors);
        latin1 ->
            unicode:characters_to_binary(Value, latin1, utf8);
        utf8 ->
            str_decode_utf8(Value, DecodeErrors)
    end;
str_decode(Value, _Encoding, _Errors) ->
    erlang:error({type_error, {decoding_str_is_not_supported, Value}}).

str_decode_utf8(Value, Errors) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Decoded when is_binary(Decoded) ->
            Decoded;
        _Invalid when Errors =:= <<"ignore">> ->
            <<>>;
        _Invalid when Errors =:= <<"replace">> ->
            <<"?">>;
        _Invalid ->
            raise_unicode_decode_error(Value, <<"utf-8">>)
    end.

str_decode_ascii(Value, Errors) ->
    case [Byte || <<Byte:8>> <= Value, Byte > 127] of
        [] ->
            Value;
        _ when Errors =:= <<"ignore">> ->
            <<<<Byte>> || <<Byte:8>> <= Value, Byte =< 127>>;
        _ when Errors =:= <<"replace">> ->
            <<
                <<
                    (case Byte =< 127 of
                        true -> Byte;
                        false -> $?
                    end)
                >>
             || <<Byte:8>> <= Value
            >>;
        _ ->
            raise_unicode_decode_error(Value, <<"ascii">>)
    end.

str_input_encoding(Encoding0) ->
    Encoding = string:lowercase(binary_to_list(normalize_name(Encoding0))),
    case Encoding of
        "utf-8" ->
            utf8;
        "utf8" ->
            utf8;
        "u8" ->
            utf8;
        "ascii" ->
            ascii;
        "us-ascii" ->
            ascii;
        "latin-1" ->
            latin1;
        "latin1" ->
            latin1;
        "iso-8859-1" ->
            latin1;
        _ ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"LookupError">>),
                    <<"unknown encoding: ", (normalize_name(Encoding0))/binary>>
                )
            )
    end.

raise_unicode_decode_error(Value, Encoding) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"UnicodeDecodeError">>),
            <<"'", Encoding/binary, "' codec can't decode bytes of length ",
                (integer_to_binary(byte_size(Value)))/binary>>
        )
    ).

ensure_allowed_kwargs(KwArgs, Allowed, Function) ->
    case [Key || Key <- maps:keys(KwArgs), not lists:member(Key, Allowed)] of
        [] ->
            ok;
        Unexpected ->
            erlang:error({type_error, {unexpected_keyword_argument, Function, Unexpected}})
    end.

ensure_no_kwarg(KwArgs, Key, Function) ->
    case maps:is_key(Key, KwArgs) of
        false -> ok;
        true -> erlang:error({type_error, {multiple_values_for_argument, Function, Key}})
    end.

builtin_list([]) ->
    pyrlang_heap:list([]);
builtin_list([Iterable]) ->
    pyrlang_heap:list(pyrlang_iter:values(Iterable));
builtin_list(Args) ->
    erlang:error({arity_error, {list, length(Args)}}).

builtin_tuple([]) ->
    {};
builtin_tuple([Iterable]) ->
    list_to_tuple(pyrlang_iter:values(Iterable));
builtin_tuple(Args) ->
    erlang:error({arity_error, {tuple, length(Args)}}).

builtin_slice([Stop]) ->
    slice_instance(none, Stop, none);
builtin_slice([Start, Stop]) ->
    slice_instance(Start, Stop, none);
builtin_slice([Start, Stop, Step]) ->
    slice_instance(Start, Stop, Step);
builtin_slice(Args) ->
    erlang:error({arity_error, {slice, length(Args)}}).

slice_instance(Start, Stop, Step) ->
    Class = builtin_type_class(<<"slice">>, {py_native_varargs, fun builtin_slice/1}),
    Instance = pyrlang_object:instantiate(Class),
    ok = pyrlang_object:set_attr(Instance, <<"start">>, Start),
    ok = pyrlang_object:set_attr(Instance, <<"stop">>, Stop),
    ok = pyrlang_object:set_attr(Instance, <<"step">>, Step),
    Instance.

builtin_set([]) ->
    pyrlang_heap:set([]);
builtin_set([Iterable]) ->
    pyrlang_heap:set(pyrlang_iter:values(Iterable));
builtin_set(Args) ->
    erlang:error({arity_error, {set, length(Args)}}).

builtin_dict([]) ->
    pyrlang_heap:dict([]);
builtin_dict([Iterable]) ->
    pyrlang_heap:dict(dict_items_from(Iterable));
builtin_dict(Args) ->
    erlang:error({arity_error, {dict, length(Args)}}).

builtin_dict_call(Args, KwArgs) ->
    Dict = builtin_dict(Args),
    maps:foreach(fun(Key, Value) -> ok = pyrlang_heap:dict_put(Dict, Key, Value) end, KwArgs),
    Dict.

dict_dunder_getitem(Ref, Key) ->
    try
        pyrlang_heap:dict_get(Ref, Key)
    catch
        error:{badkey, Missing} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Missing)
            )
    end.

dict_dunder_new([Class | _Args], _KwArgs) ->
    case dict_subclass_constructor(Class) of
        true -> pyrlang_heap:dict_instance(Class, []);
        false -> pyrlang_heap:dict([])
    end;
dict_dunder_new(Args, _KwArgs) ->
    erlang:error({arity_error, {'dict.__new__', length(Args)}}).

dict_dunder_init([Ref | Args], KwArgs) ->
    dict_update_existing(Ref, Args, KwArgs),
    none;
dict_dunder_init(Args, _KwArgs) ->
    erlang:error({arity_error, {'dict.__init__', length(Args)}}).

dict_update_existing(Ref, Args, KwArgs) ->
    case Args of
        [] ->
            maps:foreach(
                fun(Key, Value) -> ok = pyrlang_heap:dict_put(Ref, Key, Value) end, KwArgs
            );
        [Other] ->
            lists:foreach(
                fun({Key, Value}) -> ok = pyrlang_heap:dict_put(Ref, Key, Value) end,
                dict_items_from(Other)
            ),
            dict_update_existing(Ref, [], KwArgs);
        _ ->
            erlang:error({arity_error, {'dict.__init__', length(Args) + 1}})
    end.

dict_subclass_constructor(Class) ->
    DictClass = builtin_type_class(<<"dict">>, {py_native_call, fun builtin_dict_call/2}),
    is_class_ref(Class) andalso Class =/= DictClass andalso
        lists:member(DictClass, pyrlang_object:mro(Class)).

dict_fromkeys([Iterable]) ->
    dict_fromkeys([Iterable, none]);
dict_fromkeys([Iterable, Value]) ->
    pyrlang_heap:dict([{Key, Value} || Key <- pyrlang_iter:values(Iterable)]);
dict_fromkeys(Args) ->
    erlang:error({arity_error, {dict_fromkeys, length(Args)}}).

dict_dunder_setitem(Ref, Key, Value) ->
    ok = pyrlang_heap:dict_put(Ref, Key, Value),
    none.

dict_dunder_delitem(Ref, Key) ->
    ok = pyrlang_heap:dict_del(Ref, Key),
    none.

dict_dunder_contains(Ref, Key) ->
    pyrlang_heap:dict_contains(Ref, Key).

dict_dunder_get([Ref, Key]) ->
    dict_lookup_default(Ref, Key, none);
dict_dunder_get([Ref, Key, Default]) ->
    dict_lookup_default(Ref, Key, Default);
dict_dunder_get(Args) ->
    erlang:error({arity_error, {dict_get, length(Args)}}).

dict_dunder_clear(Ref) ->
    ok = pyrlang_heap:set_data(Ref, #{}),
    none.

dict_dunder_copy(Ref) ->
    pyrlang_heap:dict(pyrlang_heap:dict_items(Ref)).

dict_dunder_items(Ref) ->
    pyrlang_heap:list([{Key, Value} || {Key, Value} <- pyrlang_heap:dict_items(Ref)]).

dict_dunder_keys(Ref) ->
    pyrlang_heap:list([Key || {Key, _Value} <- pyrlang_heap:dict_items(Ref)]).

dict_dunder_values(Ref) ->
    pyrlang_heap:list([Value || {_Key, Value} <- pyrlang_heap:dict_items(Ref)]).

dict_dunder_pop([Ref, Key]) ->
    dict_pop_value(Ref, Key, no_default);
dict_dunder_pop([Ref, Key, Default]) ->
    dict_pop_value(Ref, Key, {default, Default});
dict_dunder_pop(Args) ->
    erlang:error({arity_error, {dict_pop, length(Args)}}).

dict_dunder_setdefault([Ref, Key]) ->
    dict_dunder_setdefault([Ref, Key, none]);
dict_dunder_setdefault([Ref, Key, Default]) ->
    case pyrlang_heap:dict_find(Ref, Key) of
        {ok, Value} ->
            Value;
        error ->
            ok = pyrlang_heap:dict_put(Ref, Key, Default),
            Default
    end;
dict_dunder_setdefault(Args) ->
    erlang:error({arity_error, {dict_setdefault, length(Args)}}).

dict_dunder_update([Ref | Args], KwArgs) ->
    dict_update_existing(Ref, Args, KwArgs),
    none;
dict_dunder_update(Args, _KwArgs) ->
    erlang:error({arity_error, {dict_update, length(Args)}}).

dict_lookup_default(Ref, Key, Default) ->
    case pyrlang_heap:dict_find(Ref, Key) of
        {ok, Value} -> Value;
        error -> Default
    end.

dict_pop_value(Ref, Key, Default) ->
    case pyrlang_heap:dict_find(Ref, Key) of
        {ok, Value} ->
            ok = pyrlang_heap:dict_del(Ref, Key),
            Value;
        error ->
            case Default of
                {default, Value} ->
                    Value;
                no_default ->
                    pyrlang_exception:raise(
                        pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Key)
                    )
            end
    end.

list_dunder_getitem(Ref, Index) ->
    pyrlang_heap:list_get(Ref, Index).

list_dunder_new(Args, _KwArgs) ->
    list_dunder_new(Args).

list_dunder_new([Class | Args]) ->
    case list_subclass_constructor(Class) of
        true ->
            Items =
                case Args of
                    [] -> [];
                    [Iterable] -> pyrlang_iter:values(Iterable);
                    _ -> []
                end,
            pyrlang_heap:list_instance(Class, Items);
        false ->
            Items =
                case Args of
                    [] -> [];
                    [Iterable] -> pyrlang_iter:values(Iterable);
                    _ -> erlang:error({arity_error, {'list.__new__', length(Args) + 1}})
                end,
            pyrlang_heap:list(Items)
    end;
list_dunder_new(Args) ->
    erlang:error({arity_error, {'list.__new__', length(Args)}}).

list_subclass_constructor(Class) ->
    ListClass = builtin_type_class(<<"list">>, {py_native_varargs, fun builtin_list/1}),
    is_class_ref(Class) andalso Class =/= ListClass andalso
        lists:member(ListClass, pyrlang_object:mro(Class)).

list_dunder_setitem(Ref, Index, Value) ->
    ok = pyrlang_heap:list_set(Ref, Index, Value),
    none.

list_dunder_contains(Ref, Value) ->
    builtin_value_member(Value, pyrlang_heap:list_items(Ref)).

builtin_value_member(Value, Items) ->
    Key = pyrlang_heap:value_key(Value),
    lists:any(fun(Item) -> pyrlang_heap:value_key(Item) =:= Key end, Items).

list_dunder_append(Ref, Value) ->
    ok = pyrlang_heap:list_append(Ref, Value),
    none.

list_dunder_extend(Ref, Other) ->
    lists:foreach(
        fun(Value) -> ok = pyrlang_heap:list_append(Ref, Value) end, pyrlang_iter:values(Other)
    ),
    none.

list_dunder_insert(Ref, Index, Value) ->
    ok = pyrlang_heap:list_insert(Ref, Index, Value),
    none.

str_maketrans([Mapping]) ->
    pyrlang_heap:dict([
        {translation_ord(Key), translation_value(Value)}
     || {Key, Value} <- mapping_items(Mapping)
    ]);
str_maketrans([From, To]) ->
    FromChars = unicode_chars(normalize_name(From)),
    ToChars = unicode_chars(normalize_name(To)),
    case length(FromChars) =:= length(ToChars) of
        true ->
            pyrlang_heap:dict(lists:zip(FromChars, ToChars));
        false ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>),
                    <<"the first two maketrans arguments must have equal length">>
                )
            )
    end;
str_maketrans([From, To, Delete]) ->
    Base = pyrlang_heap:dict_items(str_maketrans([From, To])),
    DeleteItems = [{Char, none} || Char <- unicode_chars(normalize_name(Delete))],
    pyrlang_heap:dict(Base ++ DeleteItems);
str_maketrans(Args) ->
    erlang:error({arity_error, {maketrans, length(Args)}}).

bytes_maketrans([From, To]) ->
    FromBytes = normalize_name(From),
    ToBytes = normalize_name(To),
    case byte_size(FromBytes) =:= byte_size(ToBytes) of
        true ->
            pyrlang_heap:dict(bytes_translation_pairs(FromBytes, ToBytes));
        false ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>),
                    <<"maketrans arguments must have same length">>
                )
            )
    end;
bytes_maketrans(Args) ->
    erlang:error({arity_error, {maketrans, length(Args)}}).

bytes_translation_pairs(<<>>, <<>>) ->
    [];
bytes_translation_pairs(<<FromByte:8, FromRest/binary>>, <<ToByte:8, ToRest/binary>>) ->
    [{FromByte, ToByte} | bytes_translation_pairs(FromRest, ToRest)].

bytes_fromhex([Value]) ->
    case bytes_fromhex_binary(normalize_name(Value), need_high, <<>>) of
        {ok, Result} ->
            Result;
        {error, Message} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Message)
            )
    end;
bytes_fromhex(Args) ->
    erlang:error({arity_error, {fromhex, length(Args)}}).

bytes_fromhex_binary(<<>>, need_high, Acc) ->
    {ok, Acc};
bytes_fromhex_binary(<<>>, {need_low, _High}, _Acc) ->
    {error, <<"non-hexadecimal number found in fromhex() arg">>};
bytes_fromhex_binary(<<Byte:8, Rest/binary>>, need_high, Acc) when
    Byte =:= $\s; Byte =:= $\t; Byte =:= $\n; Byte =:= $\r; Byte =:= $\v; Byte =:= $\f
->
    bytes_fromhex_binary(Rest, need_high, Acc);
bytes_fromhex_binary(<<Byte:8, Rest/binary>>, need_high, Acc) ->
    case hex_value(Byte) of
        {ok, High} -> bytes_fromhex_binary(Rest, {need_low, High}, Acc);
        error -> {error, <<"non-hexadecimal number found in fromhex() arg">>}
    end;
bytes_fromhex_binary(<<Byte:8, Rest/binary>>, {need_low, High}, Acc) ->
    case hex_value(Byte) of
        {ok, Low} ->
            Value = (High bsl 4) bor Low,
            bytes_fromhex_binary(Rest, need_high, <<Acc/binary, Value:8>>);
        error ->
            {error, <<"non-hexadecimal number found in fromhex() arg">>}
    end.

hex_value(Byte) when Byte >= $0, Byte =< $9 ->
    {ok, Byte - $0};
hex_value(Byte) when Byte >= $a, Byte =< $f ->
    {ok, Byte - $a + 10};
hex_value(Byte) when Byte >= $A, Byte =< $F ->
    {ok, Byte - $A + 10};
hex_value(_Byte) ->
    error.

mapping_items({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> pyrlang_heap:dict_items(Ref);
        _Type -> [dict_pair(Item) || Item <- pyrlang_iter:values(Ref)]
    end;
mapping_items(Items) ->
    [dict_pair(Item) || Item <- pyrlang_iter:values(Items)].

translation_ord(Value) when is_integer(Value) ->
    Value;
translation_ord(Value) ->
    case unicode_chars(normalize_name(Value)) of
        [Char] -> Char;
        _ -> erlang:error({value_error, {translation_key, Value}})
    end.

translation_value(none) ->
    none;
translation_value(Value) when is_integer(Value) ->
    Value;
translation_value(Value) ->
    normalize_name(Value).

unicode_chars(Binary) ->
    [Char || <<Char/utf8>> <= Binary].

object_dunder_eq(Left, Right) ->
    pyrlang_heap:value_key(Left) =:= pyrlang_heap:value_key(Right).

object_dunder_ne(Left, Right) ->
    pyrlang_heap:value_key(Left) =/= pyrlang_heap:value_key(Right).

object_dunder_repr(Self) ->
    unicode:characters_to_binary(io_lib:format("~p", [Self])).

object_dunder_format(Self, _FormatSpec) ->
    object_dunder_repr(Self).

object_dunder_reduce_ex(_Self, _Proto) ->
    none.

float_dunder_repr(Self) ->
    builtin_str(Self).

str_dunder_new([Class | Args], KwArgs) ->
    Value = builtin_str_call(Args, KwArgs),
    case string_subclass_constructor(Class) of
        true ->
            Instance = pyrlang_object:instantiate(Class),
            ok = pyrlang_object:set_attr(Instance, <<"__pyrlang_value__">>, Value),
            Instance;
        false ->
            Value
    end;
str_dunder_new(Args, KwArgs) ->
    erlang:error({arity_error, {'str.__new__', length(Args), maps:size(KwArgs)}}).

str_dunder_iter(Self) ->
    pyrlang_iter:iter(normalize_name(Self)).

str_dunder_getitem(Self, Index0) ->
    Units = [<<Char/utf8>> || Char <- unicode_chars(normalize_name(Self))],
    Index = str_index(Index0),
    lists:nth(normalize_str_index(Index, length(Units)) + 1, Units).

str_index(true) ->
    1;
str_index(false) ->
    0;
str_index(Index) when is_integer(Index) ->
    Index;
str_index({py_ref, _} = Index) ->
    case int_subclass_value(Index) of
        {ok, Value} -> Value;
        error -> erlang:error({type_error, {str_index, Index}})
    end;
str_index(Index) ->
    erlang:error({type_error, {str_index, Index}}).

normalize_str_index(Index, Length) when Index < 0 ->
    Normalized = Length + Index,
    case Normalized >= 0 of
        true -> Normalized;
        false -> erlang:error({index_error, Index})
    end;
normalize_str_index(Index, Length) when Index >= 0, Index < Length ->
    Index;
normalize_str_index(Index, _Length) ->
    erlang:error({index_error, Index}).

string_subclass_constructor(Class) ->
    StrClass = builtin_type_class(<<"str">>, str_type_constructor()),
    is_class_ref(Class) andalso Class =/= StrClass andalso
        lists:member(StrClass, pyrlang_object:mro(Class)).

tuple_dunder_new([_Class]) ->
    tuple_new_result(_Class, {});
tuple_dunder_new([Class, Iterable]) ->
    tuple_new_result(Class, list_to_tuple(pyrlang_iter:values(Iterable)));
tuple_dunder_new(Args) ->
    erlang:error({arity_error, {'tuple.__new__', length(Args)}}).

tuple_new_result(Class, Tuple) ->
    TupleClass = builtin_type_class(<<"tuple">>, {py_native_varargs, fun builtin_tuple/1}),
    case
        is_class_ref(Class) andalso Class =/= TupleClass andalso
            lists:member(TupleClass, pyrlang_object:mro(Class))
    of
        true ->
            Instance = pyrlang_object:instantiate(Class),
            ok = pyrlang_object:set_attr(Instance, <<"__pyrlang_tuple_items__">>, Tuple),
            Instance;
        false ->
            Tuple
    end.

type_dunder_new([Metaclass, Name, BasesRef, AttrsRef | _Rest], _KwArgs) ->
    Bases = implicit_object_base(pyrlang_iter:values(BasesRef)),
    Attrs = maps:from_list(pyrlang_heap:dict_items(AttrsRef)),
    pyrlang_object:new_class(Name, Bases, Attrs, Metaclass);
type_dunder_new(Args, _KwArgs) ->
    erlang:error({arity_error, {'type.__new__', length(Args)}}).

type_dunder_init([_Class, _Name, _BasesRef, _AttrsRef | _Rest], _KwArgs) ->
    none;
type_dunder_init(Args, _KwArgs) ->
    erlang:error({arity_error, {'type.__init__', length(Args)}}).

type_dunder_instancecheck(Class, Object) ->
    case is_class_ref(Class) of
        true ->
            case direct_classinfo_matches(object_class(Object), Class) of
                true ->
                    true;
                false ->
                    case proxied_object_class(Object, object_class(Object)) of
                        {ok, ProxyClass} -> direct_classinfo_matches(ProxyClass, Class);
                        error -> false
                    end
            end;
        false ->
            false
    end.

type_dunder_subclasscheck(Class, Subclass) ->
    direct_classinfo_matches(Subclass, Class).

direct_classinfo_matches(undefined, _ClassInfo) ->
    false;
direct_classinfo_matches(Class, {py_ref, _} = ClassInfo) ->
    is_class_ref(Class) andalso is_class_ref(ClassInfo) andalso
        lists:member(ClassInfo, pyrlang_object:mro(Class));
direct_classinfo_matches({py_ref, _} = Class, {py_exception_type, Expected}) ->
    pyrlang_object:exception_class_matches(Class, Expected);
direct_classinfo_matches({py_exception_type, Type}, {py_exception_type, Expected}) ->
    pyrlang_exception:type_matches(Type, Expected);
direct_classinfo_matches(Class, {py_union_type, Options}) ->
    lists:any(fun(Info) -> direct_classinfo_matches(Class, Info) end, Options);
direct_classinfo_matches(Class, ClassInfo) when is_tuple(ClassInfo) ->
    lists:any(fun(Info) -> direct_classinfo_matches(Class, Info) end, tuple_to_list(ClassInfo));
direct_classinfo_matches(_Class, _ClassInfo) ->
    false.

type_descriptor(Name) ->
    pyrlang_object:descriptor(
        fun(Obj, _Class) -> type_descriptor_value(Name, Obj) end,
        undefined,
        #{kind => getset}
    ).

type_descriptor_value(_Name, undefined) ->
    erlang:error({attribute_error, type_descriptor});
type_descriptor_value(<<"__bases__">>, Class) ->
    list_to_tuple(pyrlang_object:bases(Class));
type_descriptor_value(<<"__dict__">>, Class) ->
    pyrlang_object:get_attr(Class, <<"__dict__">>);
type_descriptor_value(<<"__mro__">>, Class) ->
    list_to_tuple(pyrlang_object:mro(Class)).

builtin_getattr([Object, Name]) ->
    Attr = normalize_name(Name),
    try
        builtin_get_attr(Object, Attr)
    catch
        error:{attribute_error, _} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"AttributeError">>), Attr)
            );
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> ->
                    pyrlang_exception:raise(
                        pyrlang_exception:make(pyrlang_exception:type(<<"AttributeError">>), Attr)
                    );
                _ ->
                    pyrlang_exception:raise(Exception)
            end
    end;
builtin_getattr([Object, Name, Default]) ->
    Attr = normalize_name(Name),
    try
        builtin_get_attr(Object, Attr)
    catch
        error:{attribute_error, _} ->
            Default;
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> ->
                    Default;
                _ ->
                    pyrlang_exception:raise(Exception)
            end
    end;
builtin_getattr(Args) ->
    erlang:error({arity_error, {getattr, length(Args)}}).

builtin_setattr(Object, Name, Value) ->
    ok = pyrlang_object:set_attr(Object, normalize_name(Name), Value),
    none.

builtin_delattr(Object, Name) ->
    ok = pyrlang_object:del_attr(Object, normalize_name(Name)),
    none.

builtin_hasattr(Object, Name) ->
    try builtin_get_attr(Object, normalize_name(Name)) of
        _Value -> true
    catch
        error:{attribute_error, _} ->
            false;
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> ->
                    false;
                _ ->
                    pyrlang_exception:raise(Exception)
            end
    end.

builtin_get_attr(Object, Attr) ->
    case pyrlang_eval:builtin_attribute(Object, Attr) of
        {ok, Value} -> Value;
        error -> pyrlang_object:get_attr(Object, Attr)
    end.

builtin_isinstance(Object, ClassInfo) ->
    Trace = trace_typecheck_start(isinstance, Object, ClassInfo),
    Class = object_class(Object),
    Result =
        case classinfo_matches(Class, ClassInfo) of
            true ->
                true;
            false ->
                case proxied_classinfo_matches(Object, Class, ClassInfo) of
                    true -> true;
                    false -> instancecheck_matches(Object, ClassInfo)
                end
        end,
    trace_typecheck_result(Trace, Result),
    Result.

builtin_issubclass(Class, ClassInfo) ->
    Trace = trace_typecheck_start(issubclass, Class, ClassInfo),
    Result =
        case is_class_ref(Class) of
            true ->
                classinfo_matches(Class, ClassInfo);
            false ->
                case Class of
                    {py_exception_type, _Type} -> classinfo_matches(Class, ClassInfo);
                    _ -> false
                end
        end,
    trace_typecheck_result(Trace, Result),
    Result.

trace_typecheck_start(Kind, Object, ClassInfo) ->
    case os:getenv("PYRLANG_TRACE_TYPECHECKS") of
        false ->
            false;
        Value ->
            Step = trace_step(Value),
            Count = erlang:get(pyrlang_trace_typecheck_count),
            Next =
                case Count of
                    undefined -> 1;
                    N when is_integer(N) -> N + 1;
                    _ -> 1
                end,
            erlang:put(pyrlang_trace_typecheck_count, Next),
            ShouldTrace = Next rem Step =:= 0,
            case ShouldTrace of
                true ->
                    io:format(
                        standard_error,
                        "PYRLANG_TYPECHECK_START ~B ~p object=~s classinfo=~s~n",
                        [
                            Next,
                            Kind,
                            describe_typecheck_value(Object),
                            describe_typecheck_value(ClassInfo)
                        ]
                    ),
                    {Kind, Next};
                false ->
                    false
            end
    end.

trace_typecheck_result(false, _Result) ->
    ok;
trace_typecheck_result({Kind, Count}, Result) ->
    io:format(standard_error, "PYRLANG_TYPECHECK_DONE ~B ~p result=~p~n", [Count, Kind, Result]).

trace_step(Value) ->
    try list_to_integer(Value) of
        N when N > 0 -> N;
        _ -> 1
    catch
        _:_ -> 1
    end.

describe_typecheck_value({py_ref, _} = Ref) ->
    try
        Type = pyrlang_heap:type(Ref),
        case Type of
            class ->
                <<"class:", (pyrlang_object:class_name(Ref))/binary>>;
            instance ->
                Class = maps:get(class, pyrlang_heap:data(Ref)),
                <<"instance:", (pyrlang_object:class_name(Class))/binary>>;
            Other ->
                unicode:characters_to_binary(io_lib:format("ref:~p", [Other]))
        end
    catch
        _:_ -> <<"ref:?">>
    end;
describe_typecheck_value({py_exception_type, Type}) ->
    <<"exception_type:", Type/binary>>;
describe_typecheck_value(Value) when is_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("str:~p", [Value]));
describe_typecheck_value(Value) when is_tuple(Value) ->
    unicode:characters_to_binary(io_lib:format("tuple:~p", [tuple_size(Value)]));
describe_typecheck_value(Value) when is_integer(Value) ->
    unicode:characters_to_binary(io_lib:format("int:~p", [Value]));
describe_typecheck_value(Value) when is_float(Value) ->
    unicode:characters_to_binary(io_lib:format("float:~p", [Value]));
describe_typecheck_value(Value) when is_boolean(Value) ->
    unicode:characters_to_binary(io_lib:format("bool:~p", [Value]));
describe_typecheck_value(none) ->
    <<"none">>;
describe_typecheck_value(_Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [object_class(_Value)])).

object_class({py_ref, _} = Object) ->
    case pyrlang_heap:type(Object) of
        class ->
            case pyrlang_object:metaclass(Object) of
                undefined -> builtin_type_class(<<"type">>, {py_native_call, fun builtin_type/2});
                Metaclass -> Metaclass
            end;
        module ->
            module_type();
        instance ->
            maps:get(class, pyrlang_heap:data(Object));
        list ->
            case pyrlang_heap:data(Object) of
                #{class := Class} -> Class;
                _ -> builtin_type_class(<<"list">>, {py_native_varargs, fun builtin_list/1})
            end;
        dict ->
            case pyrlang_heap:data(Object) of
                #{class := Class} -> Class;
                _ -> builtin_type_class(<<"dict">>, {py_native_call, fun builtin_dict_call/2})
            end;
        set ->
            builtin_type_class(<<"set">>, {py_native_varargs, fun builtin_set/1});
        iterator ->
            builtin_type_class(<<"iterator">>, {py_native_varargs, fun builtin_object/1});
        generator ->
            generator_type();
        _Type ->
            undefined
    end;
object_class(none) ->
    none_type();
object_class(not_implemented) ->
    not_implemented_type();
object_class(ellipsis) ->
    ellipsis_type();
object_class(true) ->
    builtin_type_class(<<"bool">>, {py_native_varargs, fun builtin_bool/1});
object_class(false) ->
    builtin_type_class(<<"bool">>, {py_native_varargs, fun builtin_bool/1});
object_class(_Value) when is_integer(_Value) ->
    builtin_type_class(<<"int">>, {py_native_varargs, fun builtin_int/1});
object_class(_Value) when is_float(_Value) ->
    builtin_type_class(<<"float">>, {py_native_varargs, fun builtin_float/1});
object_class({py_float_special, _Kind}) ->
    builtin_type_class(<<"float">>, {py_native_varargs, fun builtin_float/1});
object_class({py_complex, _Real, _Imag}) ->
    builtin_type_class(<<"complex">>, {py_native_varargs, fun builtin_complex/1});
object_class(_Value) when is_binary(_Value) ->
    builtin_type_class(<<"str">>, str_type_constructor());
object_class({py_generic_alias, _Origin, _Args}) ->
    generic_alias_type();
object_class({py_union_type, _Options}) ->
    union_type();
object_class({py_coroutine, _Body, _Env, _OwnerClass, _PosArgs}) ->
    coroutine_type();
object_class({py_async_generator, _Body, _Env, _OwnerClass, _PosArgs}) ->
    async_generator_type();
object_class({py_range, _Start, _Stop, _Step}) ->
    builtin_type_class(<<"range">>, {py_native_varargs, fun builtin_range/1});
object_class({py_slice, _Start, _Stop, _Step}) ->
    builtin_type_class(<<"slice">>, {py_native_varargs, fun builtin_slice/1});
object_class({slice, _Start, _Stop}) ->
    builtin_type_class(<<"slice">>, {py_native_varargs, fun builtin_slice/1});
object_class({slice, _Start, _Stop, _Step}) ->
    builtin_type_class(<<"slice">>, {py_native_varargs, fun builtin_slice/1});
object_class(#{py_exception := true, type := Type}) ->
    pyrlang_exception:type(Type);
object_class({py_function, _Params, _Body, _Env}) ->
    function_type();
object_class({py_function, _Params, _Body, _Env, _IsGenerator}) ->
    function_type();
object_class({py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass}) ->
    function_type();
object_class({py_bound_method, _Callable, _Self}) ->
    method_type();
object_class({py_weakref, _Target}) ->
    pyrlang_module:weakref_reference_type();
object_class({py_native_varargs, _Fun}) ->
    builtin_function_type();
object_class({py_native_varargs, _Fun, _Bind}) ->
    builtin_function_type();
object_class({py_native_call, _Fun}) ->
    builtin_function_type();
object_class({py_native_call, _Fun, _Bind}) ->
    builtin_function_type();
object_class({py_native_callable, _Fun}) ->
    builtin_function_type();
object_class({py_native_callable, _Fun, _Bind}) ->
    builtin_function_type();
object_class(_Value) when is_tuple(_Value) ->
    builtin_type_class(<<"tuple">>, {py_native_varargs, fun builtin_tuple/1});
object_class(#{py_descriptor := true, kind := property}) ->
    builtin_type_class(<<"property">>, {py_native_call, fun builtin_property/2});
object_class(#{py_descriptor := true, kind := staticmethod}) ->
    builtin_type_class(<<"staticmethod">>, {py_native_varargs, fun builtin_staticmethod/1});
object_class(#{py_descriptor := true, kind := classmethod}) ->
    builtin_type_class(<<"classmethod">>, {py_native_varargs, fun builtin_classmethod/1});
object_class(_Fun) when is_function(_Fun) ->
    builtin_function_type();
object_class(_Object) ->
    undefined.

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
            case is_string_subclass_instance(Ref) of
                true ->
                    Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
                    case maps:find(<<"__pyrlang_value__">>, Attrs) of
                        {ok, Value} when is_binary(Value) -> {ok, Value};
                        _ -> error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end;
string_subclass_value(_Other) ->
    error.

is_string_subclass_instance({py_ref, _} = Ref) ->
    Class = object_class(Ref),
    lists:any(
        fun(MroClass) -> class_named(MroClass, <<"str">>) end,
        pyrlang_object:mro(Class)
    ).

class_named({py_ref, _} = Class, Name) ->
    try
        pyrlang_heap:type(Class) =:= class andalso pyrlang_object:class_name(Class) =:= Name
    catch
        _:_ -> false
    end;
class_named(_Class, _Name) ->
    false.

classinfo_matches(undefined, _ClassInfo) ->
    false;
classinfo_matches(Class, {py_ref, _} = ClassInfo) ->
    case is_class_ref(ClassInfo) of
        true ->
            case is_collections_abc_iterable(ClassInfo) of
                true ->
                    class_is_iterable(Class);
                false ->
                    lists:member(ClassInfo, pyrlang_object:mro(Class)) orelse
                        subclasscheck_matches(Class, ClassInfo)
            end;
        false ->
            false
    end;
classinfo_matches({py_ref, _} = Class, {py_exception_type, Expected}) ->
    pyrlang_object:exception_class_matches(Class, Expected);
classinfo_matches({py_exception_type, Type}, {py_exception_type, Expected}) ->
    pyrlang_exception:type_matches(Type, Expected);
classinfo_matches(Class, {py_union_type, Options}) ->
    lists:any(fun(Info) -> classinfo_matches(Class, Info) end, Options);
classinfo_matches(Class, ClassInfo) when is_tuple(ClassInfo) ->
    lists:any(fun(Info) -> classinfo_matches(Class, Info) end, tuple_to_list(ClassInfo));
classinfo_matches(_Class, _ClassInfo) ->
    false.

proxied_classinfo_matches(Object, ActualClass, ClassInfo) ->
    case proxied_object_class(Object, ActualClass) of
        {ok, Class} -> classinfo_matches(Class, ClassInfo);
        error -> false
    end.

proxied_object_class({py_ref, _} = Object, ActualClass) ->
    try pyrlang_object:get_attr(Object, <<"__class__">>) of
        {py_ref, _} = Class ->
            case is_class_ref(Class) andalso Class =/= ActualClass of
                true -> {ok, Class};
                false -> error
            end;
        _Other ->
            error
    catch
        _:_ ->
            error
    end;
proxied_object_class(_Object, _ActualClass) ->
    error.

subclasscheck_matches({py_ref, _} = Class, {py_ref, _} = ClassInfo) ->
    case pyrlang_object:metaclass(ClassInfo) of
        undefined ->
            false;
        _Metaclass ->
            try pyrlang_object:get_attr(ClassInfo, <<"__subclasscheck__">>) of
                Check -> truthy(pyrlang_eval:call(Check, [Class]))
            catch
                error:{attribute_error, _} -> false;
                throw:{py_exception, Exception} -> pyrlang_exception:raise(Exception);
                _:_ -> false
            end
    end;
subclasscheck_matches(_Class, _ClassInfo) ->
    false.

instancecheck_matches(Object, {py_ref, _} = ClassInfo) ->
    case is_class_ref(ClassInfo) of
        true ->
            case pyrlang_object:metaclass(ClassInfo) of
                undefined ->
                    false;
                _Metaclass ->
                    try pyrlang_object:get_attr(ClassInfo, <<"__instancecheck__">>) of
                        Check -> truthy(pyrlang_eval:call(Check, [Object]))
                    catch
                        error:{attribute_error, _} -> false;
                        throw:{py_exception, Exception} -> pyrlang_exception:raise(Exception);
                        _:_ -> false
                    end
            end;
        false ->
            false
    end;
instancecheck_matches(Object, ClassInfo) when is_tuple(ClassInfo) ->
    lists:any(fun(Info) -> builtin_isinstance(Object, Info) end, tuple_to_list(ClassInfo));
instancecheck_matches(_Object, _ClassInfo) ->
    false.

is_collections_abc_iterable(ClassInfo) ->
    case class_named(ClassInfo, <<"Iterable">>) of
        false ->
            false;
        true ->
            try pyrlang_object:get_attr(ClassInfo, <<"__module__">>) of
                Module -> Module =:= <<"collections.abc">> orelse Module =:= <<"_collections_abc">>
            catch
                _:_ -> true
            end
    end.

class_is_iterable({py_ref, _} = Class) ->
    IterableNames = [
        <<"list">>,
        <<"tuple">>,
        <<"dict">>,
        <<"set">>,
        <<"str">>,
        <<"range">>,
        <<"iterator">>,
        <<"generator">>
    ],
    Mro = pyrlang_object:mro(Class),
    lists:any(
        fun(MroClass) ->
            lists:any(fun(Name) -> class_named(MroClass, Name) end, IterableNames)
        end,
        Mro
    ) orelse class_has_attr(Class, <<"__iter__">>) orelse class_has_attr(Class, <<"__getitem__">>);
class_is_iterable(_Class) ->
    false.

class_has_attr({py_ref, _} = Class, Attr) ->
    try pyrlang_object:class_attr(Class, Attr) of
        {ok, _Value} -> true;
        error -> false
    catch
        _:_ -> false
    end;
class_has_attr(_Class, _Attr) ->
    false.

is_class_ref({py_ref, _} = Ref) ->
    try
        pyrlang_heap:type(Ref) =:= class
    catch
        _:_ -> false
    end;
is_class_ref(_Other) ->
    false.

type_union_operand({py_ref, _} = Ref) ->
    is_class_ref(Ref);
type_union_operand({py_exception_type, _Type}) ->
    true;
type_union_operand({py_generic_alias, _Origin, _Args}) ->
    true;
type_union_operand({py_union_type, _Options}) ->
    true;
type_union_operand(none) ->
    true;
type_union_operand(_Other) ->
    false.

type_union_options({py_union_type, Options}) ->
    Options;
type_union_options(none) ->
    [none_type()];
type_union_options(Value) ->
    [Value].

dedupe_type_union_options(Options) ->
    lists:reverse(
        lists:foldl(
            fun(Option, Acc) ->
                case lists:member(Option, Acc) of
                    true -> Acc;
                    false -> [Option | Acc]
                end
            end,
            [],
            Options
        )
    ).

dict_items_from({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> pyrlang_heap:dict_items(Ref);
        _Type -> [dict_pair(Item) || Item <- pyrlang_iter:values(Ref)]
    end;
dict_items_from({py_instance_dict, Instance}) ->
    Data = pyrlang_heap:data(Instance),
    maps:to_list(maps:get(attrs, Data, #{}));
dict_items_from({py_module_dict, ModuleRef}) ->
    maps:to_list(pyrlang_module:env(ModuleRef));
dict_items_from(Map) when is_map(Map) ->
    maps:to_list(Map);
dict_items_from(Iterable) ->
    [dict_pair(Item) || Item <- pyrlang_iter:values(Iterable)].

dict_pair({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list ->
            case pyrlang_heap:list_items(Ref) of
                [Key, Value] -> {Key, Value};
                Items -> erlang:error({type_error, {bad_dict_pair, Items}})
            end;
        _Type ->
            erlang:error({type_error, {bad_dict_pair, Ref}})
    end;
dict_pair({Key, Value}) ->
    {Key, Value};
dict_pair([Key, Value]) ->
    {Key, Value};
dict_pair(Tuple) when is_tuple(Tuple), tuple_size(Tuple) =:= 2 ->
    {element(1, Tuple), element(2, Tuple)};
dict_pair(Other) ->
    erlang:error({type_error, {bad_dict_pair, Other}}).

builtin_range([Stop]) ->
    range_list(0, Stop, 1);
builtin_range([Start, Stop]) ->
    range_list(Start, Stop, 1);
builtin_range([Start, Stop, Step]) ->
    range_list(Start, Stop, Step);
builtin_range(Args) ->
    erlang:error({arity_error, {range, length(Args)}}).

builtin_reversed([Value]) ->
    pyrlang_iter:from_values(lists:reverse(pyrlang_iter:values(Value)));
builtin_reversed(Args) ->
    erlang:error({arity_error, {reversed, length(Args)}}).

builtin_sorted([Iterable], KwArgs) ->
    Key = maps:get(<<"key">>, KwArgs, none),
    Reverse = truthy(maps:get(<<"reverse">>, KwArgs, false)),
    Unknown = maps:keys(maps:without([<<"key">>, <<"reverse">>], KwArgs)),
    case Unknown of
        [] ->
            Items = pyrlang_iter:values(Iterable),
            Indexed = lists:zip(lists:seq(1, length(Items)), Items),
            Decorated = [{sort_key(Key, Value), Index, Value} || {Index, Value} <- Indexed],
            Sorted = lists:sort(fun sorted_entry_less/2, Decorated),
            Values = [Value || {_KeyValue, _Index, Value} <- Sorted],
            pyrlang_heap:list(
                case Reverse of
                    true -> lists:reverse(Values);
                    false -> Values
                end
            );
        _ ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end;
builtin_sorted(Args, _KwArgs) ->
    erlang:error({arity_error, {sorted, length(Args)}}).

sort_key(none, Value) ->
    Value;
sort_key(Callable, Value) ->
    pyrlang_eval:call(Callable, [Value]).

sorted_entry_less({KeyA, IndexA, _ValueA}, {KeyB, IndexB, _ValueB}) ->
    case KeyA =:= KeyB of
        true -> IndexA =< IndexB;
        false -> KeyA < KeyB
    end.

builtin_max(Args, KwArgs) ->
    builtin_extreme(max, Args, KwArgs).

builtin_min(Args, KwArgs) ->
    builtin_extreme(min, Args, KwArgs).

builtin_extreme(Mode, [], _KwArgs) ->
    erlang:error({arity_error, {Mode, 0}});
builtin_extreme(Mode, [Iterable], KwArgs) ->
    Key = maps:get(<<"key">>, KwArgs, none),
    Default = maps:get(<<"default">>, KwArgs, no_default),
    Unknown = maps:keys(maps:without([<<"key">>, <<"default">>], KwArgs)),
    case Unknown of
        [] -> extreme_values(Mode, pyrlang_iter:values(Iterable), Key, Default);
        _ -> erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end;
builtin_extreme(Mode, Args, KwArgs) ->
    Key = maps:get(<<"key">>, KwArgs, none),
    Unknown = maps:keys(maps:without([<<"key">>], KwArgs)),
    case Unknown of
        [] -> extreme_values(Mode, Args, Key, no_default);
        _ -> erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end.

extreme_values(_Mode, [], _Key, no_default) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), <<"empty sequence">>)
    );
extreme_values(_Mode, [], _Key, Default) ->
    Default;
extreme_values(Mode, [First | Rest], Key, _Default) ->
    {_BestKey, BestValue} = lists:foldl(
        fun(Value, {BestKey, BestValue}) ->
            ValueKey = sort_key(Key, Value),
            case extreme_better(Mode, ValueKey, BestKey) of
                true -> {ValueKey, Value};
                false -> {BestKey, BestValue}
            end
        end,
        {sort_key(Key, First), First},
        Rest
    ),
    BestValue.

extreme_better(_Mode, Key, Key) ->
    false;
extreme_better(max, Key, BestKey) ->
    Key > BestKey;
extreme_better(min, Key, BestKey) ->
    Key < BestKey.

builtin_sum([Iterable], KwArgs) ->
    builtin_sum([Iterable, maps:get(<<"start">>, KwArgs, 0)], maps:without([<<"start">>], KwArgs));
builtin_sum([Iterable, Start], KwArgs) when map_size(KwArgs) =:= 0 ->
    lists:foldl(fun sum_add/2, Start, pyrlang_iter:values(Iterable));
builtin_sum(Args, KwArgs) when map_size(KwArgs) =:= 0 ->
    erlang:error({arity_error, {sum, length(Args)}});
builtin_sum(_Args, KwArgs) ->
    erlang:error({type_error, {unexpected_keyword_argument, maps:keys(KwArgs)}}).

sum_add(Value, Acc) when is_integer(Value), is_integer(Acc) ->
    Acc + Value;
sum_add(Value, Acc) when is_float(Value), is_float(Acc) ->
    Acc + Value;
sum_add(Value, Acc) when is_integer(Value), is_float(Acc) ->
    Acc + Value;
sum_add(Value, Acc) when is_float(Value), is_integer(Acc) ->
    Acc + Value;
sum_add(true, Acc) when is_number(Acc) ->
    Acc + 1;
sum_add(false, Acc) when is_number(Acc) ->
    Acc;
sum_add(Value, true) when is_number(Value) ->
    1 + Value;
sum_add(Value, false) when is_number(Value) ->
    Value;
sum_add({py_ref, _} = Value, {py_ref, _} = Acc) ->
    case {safe_heap_type(Value), safe_heap_type(Acc)} of
        {list, list} ->
            pyrlang_heap:list(pyrlang_heap:list_items(Acc) ++ pyrlang_heap:list_items(Value));
        _ ->
            sum_add_special(Value, Acc)
    end;
sum_add(Value, Acc) ->
    erlang:error({type_error, {unsupported_sum, Acc, Value}}).

sum_add_special(Value, Acc) ->
    try pyrlang_object:get_attr(Acc, <<"__add__">>) of
        Add ->
            case pyrlang_eval:call(Add, [Value]) of
                not_implemented -> sum_radd_special(Value, Acc);
                Result -> Result
            end
    catch
        error:{attribute_error, _Name} ->
            sum_radd_special(Value, Acc)
    end.

sum_radd_special(Value, Acc) ->
    try pyrlang_object:get_attr(Value, <<"__radd__">>) of
        RAdd ->
            case pyrlang_eval:call(RAdd, [Acc]) of
                not_implemented -> erlang:error({type_error, {unsupported_sum, Acc, Value}});
                Result -> Result
            end
    catch
        error:{attribute_error, _Name} ->
            erlang:error({type_error, {unsupported_sum, Acc, Value}})
    end.

safe_heap_type({py_ref, _} = Ref) ->
    try
        pyrlang_heap:type(Ref)
    catch
        _:_ -> undefined
    end.

builtin_enumerate([Iterable], KwArgs) ->
    ensure_allowed_kwargs(KwArgs, [<<"start">>], enumerate),
    builtin_enumerate_values(Iterable, maps:get(<<"start">>, KwArgs, 0));
builtin_enumerate([Iterable, Start], KwArgs) ->
    ensure_allowed_kwargs(KwArgs, [<<"start">>], enumerate),
    ensure_no_kwarg(KwArgs, <<"start">>, enumerate),
    builtin_enumerate_values(Iterable, Start);
builtin_enumerate(Args, _KwArgs) ->
    erlang:error({arity_error, {enumerate, length(Args)}}).

builtin_enumerate_values(Iterable, Start0) ->
    Start = enumerate_start(Start0),
    Values = pyrlang_iter:values(Iterable),
    pyrlang_iter:from_values(enumerated_values(Values, Start)).

enumerate_start(true) ->
    1;
enumerate_start(false) ->
    0;
enumerate_start(Start) when is_integer(Start) ->
    Start;
enumerate_start({py_ref, _} = Start) ->
    case int_subclass_value(Start) of
        {ok, Value} -> Value;
        error -> erlang:error({type_error, {enumerate_start, Start}})
    end;
enumerate_start(Start) ->
    erlang:error({type_error, {enumerate_start, Start}}).

builtin_eval([Source]) ->
    builtin_eval([Source, pyrlang_heap:dict([]), pyrlang_heap:dict([])]);
builtin_eval([Source, Globals]) ->
    builtin_eval([Source, Globals, pyrlang_heap:dict([])]);
builtin_eval([Source, Globals, Locals]) ->
    SourceText = binary_to_list(normalize_name(Source)),
    GlobalsMap = maps:from_list(mapping_items(Globals)),
    LocalsMap = maps:from_list(mapping_items(Locals)),
    EvalEnv = maps:merge(maps:merge(env(), GlobalsMap), LocalsMap),
    case pyrlang_parser:parse_expr(SourceText) of
        {ok, Expr} ->
            {Value, _Env1} = pyrlang_eval:eval_expr(Expr, EvalEnv),
            Value;
        {error, Reason} ->
            erlang:error({syntax_error, Reason})
    end;
builtin_eval(Args) ->
    erlang:error({arity_error, {eval, length(Args)}}).

builtin_map([_Function]) ->
    erlang:error({arity_error, {map, 1}});
builtin_map([Function | Iterables]) ->
    Values = [pyrlang_iter:values(Iterable) || Iterable <- Iterables],
    pyrlang_iter:from_values(map_values(Function, Values, []));
builtin_map(Args) ->
    erlang:error({arity_error, {map, length(Args)}}).

builtin_filter([Function, Iterable]) ->
    Values = pyrlang_iter:values(Iterable),
    pyrlang_iter:from_values(filter_values(Function, Values));
builtin_filter(Args) ->
    erlang:error({arity_error, {filter, length(Args)}}).

builtin_zip([]) ->
    pyrlang_iter:from_values([]);
builtin_zip(Iterables) ->
    Iterators = [pyrlang_iter:iter(Iterable) || Iterable <- Iterables],
    pyrlang_iter:from_values(zip_iterators(Iterators, [])).

builtin_zip_call(Iterables, KwArgs) ->
    ensure_allowed_kwargs(KwArgs, [<<"strict">>], zip),
    builtin_zip(Iterables).

map_values(Function, Values, Acc) ->
    case lists:any(fun(List) -> List =:= [] end, Values) of
        true ->
            lists:reverse(Acc);
        false ->
            Heads = [hd(List) || List <- Values],
            Tails = [tl(List) || List <- Values],
            map_values(Function, Tails, [pyrlang_eval:call(Function, Heads) | Acc])
    end.

filter_values(none, Values) ->
    [Value || Value <- Values, truthy(Value)];
filter_values(Function, Values) ->
    [Value || Value <- Values, truthy(pyrlang_eval:call(Function, [Value]))].

zip_iterators(Iterators, Acc) ->
    case zip_next_row(Iterators, []) of
        stop -> lists:reverse(Acc);
        {ok, Row} -> zip_iterators(Iterators, [list_to_tuple(Row) | Acc])
    end.

zip_next_row([], Acc) ->
    {ok, lists:reverse(Acc)};
zip_next_row([Iterator | Rest], Acc) ->
    try pyrlang_iter:next(Iterator) of
        Value -> zip_next_row(Rest, [Value | Acc])
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"StopIteration">> -> stop;
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

enumerated_values(Values, Start) ->
    enumerated_values(Values, Start, []).

enumerated_values([], _Index, Acc) ->
    lists:reverse(Acc);
enumerated_values([Value | Rest], Index, Acc) ->
    enumerated_values(Rest, Index + 1, [{Index, Value} | Acc]).

builtin_open([Path]) ->
    builtin_open([Path, <<"r">>]);
builtin_open([Path, Mode]) ->
    open_file_instance(normalize_name(Path), normalize_name(Mode));
builtin_open(Args) ->
    erlang:error({arity_error, {open, length(Args)}}).

open_file_instance(Path, Mode) ->
    {Options, Capabilities} = file_open_options(Mode),
    case file:open(binary_to_list(Path), Options) of
        {ok, Device} ->
            Key = {pyrlang_open_file, erlang:make_ref()},
            erlang:put(Key, Capabilities#{device => Device, closed => false}),
            Class = pyrlang_object:new_class(<<"File">>, [], #{}),
            Instance = pyrlang_object:instantiate(Class),
            ok = pyrlang_object:set_attr(Instance, <<"__pyrlang_unsendable__">>, open_file),
            ok = pyrlang_object:set_attr(
                Instance, <<"read">>, {py_native_varargs, fun(Args) -> file_read(Key, Args) end}
            ),
            ok = pyrlang_object:set_attr(Instance, <<"write">>, fun(Content) ->
                file_write(Key, Content)
            end),
            ok = pyrlang_object:set_attr(
                Instance, <<"seek">>, {py_native_varargs, fun(Args) -> file_seek(Key, Args) end}
            ),
            ok = pyrlang_object:set_attr(Instance, <<"tell">>, fun() -> file_tell(Key) end),
            ok = pyrlang_object:set_attr(Instance, <<"close">>, fun() -> file_close(Key) end),
            ok = pyrlang_object:set_attr(Instance, <<"__enter__">>, fun() -> Instance end),
            ok = pyrlang_object:set_attr(Instance, <<"__exit__">>, fun(_Type, _Value, _Traceback) ->
                _ = file_close(Key),
                false
            end),
            Instance;
        {error, Reason} ->
            raise_os_error(Reason)
    end.

file_open_options(<<"r">>) ->
    {[read, binary], #{readable => true, writable => false}};
file_open_options(<<"rb">>) ->
    file_open_options(<<"r">>);
file_open_options(<<"w">>) ->
    {[write, binary], #{readable => false, writable => true}};
file_open_options(<<"wb">>) ->
    file_open_options(<<"w">>);
file_open_options(<<"a">>) ->
    {[append, binary], #{readable => false, writable => true}};
file_open_options(<<"ab">>) ->
    file_open_options(<<"a">>);
file_open_options(Mode) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"ValueError">>), <<"unsupported file mode: ", Mode/binary>>
        )
    ).

file_read(Key, []) ->
    State = readable_file_state(Key),
    file_read_all(maps:get(device, State), []);
file_read(Key, [Size]) when is_integer(Size), Size >= 0 ->
    State = readable_file_state(Key),
    case file:read(maps:get(device, State), Size) of
        {ok, Data} -> Data;
        eof -> <<>>;
        {error, Reason} -> raise_os_error(Reason)
    end;
file_read(Key, [Size]) when is_integer(Size), Size < 0 ->
    file_read(Key, []);
file_read(_Key, Args) ->
    erlang:error({arity_error, {file_read, length(Args)}}).

file_read_all(Device, Acc) ->
    case file:read(Device, 8192) of
        {ok, Data} -> file_read_all(Device, [Data | Acc]);
        eof -> iolist_to_binary(lists:reverse(Acc));
        {error, Reason} -> raise_os_error(Reason)
    end.

file_write(Key, Content) ->
    State = writable_file_state(Key),
    Data = normalize_name(Content),
    case file:write(maps:get(device, State), Data) of
        ok -> byte_size(Data);
        {error, Reason} -> raise_os_error(Reason)
    end.

file_seek(Key, [Offset]) ->
    file_seek(Key, [Offset, 0]);
file_seek(Key, [Offset, Whence]) when is_integer(Offset), is_integer(Whence) ->
    State = file_state(Key, any),
    Position =
        case Whence of
            0 ->
                {bof, Offset};
            1 ->
                {cur, Offset};
            2 ->
                {eof, Offset};
            _ ->
                pyrlang_exception:raise(
                    pyrlang_exception:make(
                        pyrlang_exception:type(<<"ValueError">>), <<"invalid whence">>
                    )
                )
        end,
    case file:position(maps:get(device, State), Position) of
        {ok, NewPosition} -> NewPosition;
        {error, Reason} -> raise_os_error(Reason)
    end;
file_seek(_Key, Args) ->
    erlang:error({arity_error, {file_seek, length(Args)}}).

file_tell(Key) ->
    State = file_state(Key, any),
    case file:position(maps:get(device, State), cur) of
        {ok, Position} -> Position;
        {error, Reason} -> raise_os_error(Reason)
    end.

file_close(Key) ->
    case erlang:get(Key) of
        undefined ->
            none;
        #{closed := true} ->
            none;
        State ->
            _ = file:close(maps:get(device, State)),
            erlang:put(Key, State#{closed := true}),
            none
    end.

readable_file_state(Key) ->
    file_state(Key, readable).

writable_file_state(Key) ->
    file_state(Key, writable).

file_state(Key, Capability) ->
    case erlang:get(Key) of
        undefined ->
            raise_os_error(closed);
        #{closed := true} ->
            raise_os_error(closed);
        State ->
            case Capability of
                any ->
                    State;
                _ ->
                    case maps:get(Capability, State, false) of
                        true -> State;
                        false -> raise_os_error({not_open_for, Capability})
                    end
            end
    end.

raise_os_error(enoent) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"FileNotFoundError">>), enoent)
    );
raise_os_error(eacces) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"PermissionError">>), eacces)
    );
raise_os_error(eisdir) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"IsADirectoryError">>), eisdir)
    );
raise_os_error(enotdir) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"NotADirectoryError">>), enotdir)
    );
raise_os_error(Reason) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"OSError">>), Reason)).

range_list(_Start, _Stop, 0) ->
    erlang:error({value_error, {range_step, 0}});
range_list(Start, Stop, Step) when is_integer(Start), is_integer(Stop), is_integer(Step) ->
    {py_range, Start, Stop, Step}.

builtin_property(Args, KwArgs) ->
    ensure_allowed_kwargs(KwArgs, [<<"fget">>, <<"fset">>, <<"fdel">>, <<"doc">>], property),
    case length(Args) =< 4 of
        true -> ok;
        false -> erlang:error({arity_error, {property, length(Args), maps:size(KwArgs)}})
    end,
    ParamNames = [<<"fget">>, <<"fset">>, <<"fdel">>, <<"doc">>],
    case
        [
            Name
         || {Name, _Value} <- lists:zip(lists:sublist(ParamNames, length(Args)), Args),
            maps:is_key(Name, KwArgs)
        ]
    of
        [] ->
            builtin_property_bound(
                property_arg(1, <<"fget">>, Args, KwArgs, none),
                property_arg(2, <<"fset">>, Args, KwArgs, none),
                property_arg(3, <<"fdel">>, Args, KwArgs, none),
                property_arg(4, <<"doc">>, Args, KwArgs, none)
            );
        [Duplicate | _] ->
            erlang:error({type_error, {multiple_values_for_argument, property, Duplicate}})
    end.

property_arg(Position, Key, Args, KwArgs, Default) ->
    case length(Args) >= Position of
        true -> lists:nth(Position, Args);
        false -> maps:get(Key, KwArgs, Default)
    end.

builtin_property_bound(Getter, Setter, Deleter, Doc) ->
    Get =
        case Getter of
            none -> fun(_Obj, _Class) -> none end;
            _ -> fun(Obj, _Class) -> pyrlang_eval:call(Getter, [Obj]) end
        end,
    Set =
        case Setter of
            none ->
                undefined;
            _ ->
                fun(Obj, Value) ->
                    _ = pyrlang_eval:call(Setter, [Obj, Value]),
                    ok
                end
        end,
    Del =
        case Deleter of
            none ->
                undefined;
            _ ->
                fun(Obj) ->
                    _ = pyrlang_eval:call(Deleter, [Obj]),
                    ok
                end
        end,
    pyrlang_object:descriptor(
        Get,
        Set,
        #{
            kind => property,
            del => Del,
            fget => Getter,
            fset => Setter,
            fdel => Deleter,
            doc => Doc
        }
    ).

builtin_staticmethod([Callable]) ->
    pyrlang_object:descriptor(
        fun(_Obj, _Class) -> Callable end,
        undefined,
        #{kind => staticmethod, callable => Callable}
    );
builtin_staticmethod(Args) ->
    erlang:error({arity_error, {staticmethod, length(Args)}}).

builtin_classmethod([Callable]) ->
    pyrlang_object:descriptor(
        fun(_Obj, Class) -> {py_bound_method, Callable, Class} end,
        undefined,
        #{kind => classmethod, callable => Callable}
    );
builtin_classmethod(Args) ->
    erlang:error({arity_error, {classmethod, length(Args)}}).

builtin_generic_alias([Origin, Args]) ->
    generic_alias(Origin, Args);
builtin_generic_alias(Args) ->
    erlang:error({arity_error, {generic_alias, length(Args)}}).

builtin_type([ellipsis], KwArgs) when map_size(KwArgs) =:= 0 ->
    builtin_type_class(<<"ellipsis">>, {py_native_varargs, fun builtin_ellipsis/1});
builtin_type([Object], KwArgs) when map_size(KwArgs) =:= 0 ->
    case object_class(Object) of
        undefined -> erlang:error({type_error, {type, Object}});
        Class -> Class
    end;
builtin_type([Name, BasesRef, AttrsRef], KwArgs) ->
    ExplicitBases = pyrlang_iter:values(BasesRef),
    Bases = implicit_object_base(ExplicitBases),
    Attrs = class_attrs_from_pairs(pyrlang_heap:dict_items(AttrsRef)),
    case select_metaclass(Bases) of
        undefined ->
            pyrlang_object:new_class(Name, Bases, Attrs);
        Metaclass ->
            call_metaclass(Metaclass, Name, ExplicitBases, Attrs, KwArgs)
    end;
builtin_type(Args, KwArgs) when map_size(KwArgs) =:= 0 ->
    erlang:error({arity_error, {type, length(Args)}});
builtin_type(Args, KwArgs) ->
    erlang:error(
        {type_error, {unexpected_keyword_argument, {type, length(Args), maps:keys(KwArgs)}}}
    ).

select_metaclass(Bases) ->
    select_metaclass(Bases, undefined).

select_metaclass([], Selected) ->
    Selected;
select_metaclass([Base | Rest], undefined) ->
    select_metaclass(Rest, pyrlang_object:metaclass(Base));
select_metaclass([Base | Rest], Selected) ->
    case pyrlang_object:metaclass(Base) of
        undefined ->
            select_metaclass(Rest, Selected);
        Selected ->
            select_metaclass(Rest, Selected);
        Other ->
            erlang:error({type_error, {metaclass_conflict, Selected, Other}})
    end.

call_metaclass(Metaclass, Name, Bases, Attrs0, KwArgs) ->
    Attrs = prepare_classdict_attrs(Metaclass, Attrs0),
    AttrsRef = pyrlang_heap:dict(Attrs),
    BasesRef = pyrlang_heap:list(Bases),
    pyrlang_eval:call(Metaclass, {call_args, [Name, BasesRef, AttrsRef], KwArgs}).

prepare_classdict_attrs(Metaclass, Attrs) ->
    Prepared =
        case
            is_class_ref(Metaclass) andalso pyrlang_object:class_name(Metaclass) =:= <<"EnumType">>
        of
            true ->
                maps:put(
                    <<"_member_names">>,
                    pyrlang_heap:dict([{Name, none} || Name <- enum_member_names(Attrs)]),
                    Attrs
                );
            false ->
                Attrs
        end,
    class_attrs_public(Prepared).

enum_member_names(Attrs) ->
    [Name || Name <- class_attr_order(Attrs), enum_member_name(Name, maps:get(Name, Attrs))].

class_attrs_from_pairs(Pairs) ->
    lists:foldl(
        fun({Key, Value}, Acc) -> put_class_attr(normalize_name(Key), Value, Acc) end,
        #{?CLASS_ATTR_ORDER_KEY => []},
        Pairs
    ).

class_attrs_public(Attrs) ->
    maps:remove(?CLASS_ATTR_ORDER_KEY, Attrs).

put_class_attr(Name, Value, Attrs) ->
    Attrs1 =
        case maps:is_key(Name, Attrs) orelse is_class_internal_attr(Name) of
            true ->
                Attrs;
            false ->
                Order = maps:get(?CLASS_ATTR_ORDER_KEY, Attrs, []),
                Attrs#{?CLASS_ATTR_ORDER_KEY => Order ++ [Name]}
        end,
    Attrs1#{Name => Value}.

class_attr_order(Attrs) ->
    Ordered = [
        Name
     || Name <- maps:get(?CLASS_ATTR_ORDER_KEY, Attrs, []), maps:is_key(Name, Attrs)
    ],
    Ordered ++
        [
            Name
         || Name <- maps:keys(Attrs),
            Name =/= ?CLASS_ATTR_ORDER_KEY,
            not lists:member(Name, Ordered)
        ].

is_class_internal_attr(<<"__pyrlang_", _Rest/binary>>) ->
    true;
is_class_internal_attr(_Name) ->
    false.

enum_member_name(<<"_", _/binary>>, _Value) ->
    false;
enum_member_name(_Name, {py_function, _Params, _Body, _Env}) ->
    false;
enum_member_name(_Name, {py_function, _Params, _Body, _Env, _IsGenerator}) ->
    false;
enum_member_name(_Name, {py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass}) ->
    false;
enum_member_name(_Name, #{py_descriptor := true}) ->
    false;
enum_member_name(_Name, Value) when is_function(Value) ->
    false;
enum_member_name(_Name, Value) ->
    not is_class_ref(Value).

implicit_object_base([]) ->
    [builtin_type_class(<<"object">>, {py_native_varargs, fun builtin_object/1})];
implicit_object_base(Bases) ->
    Bases.

builtin_ellipsis([]) ->
    ellipsis;
builtin_ellipsis(Args) ->
    erlang:error({arity_error, {ellipsis, length(Args)}}).

builtin_import(Args, KwArgs) ->
    case bind_import_args(Args, KwArgs) of
        {ok, Name, _Globals, _Locals, FromList, _Level} ->
            builtin_import_bound(Name, FromList);
        {error, arity} ->
            erlang:error({arity_error, {'__import__', length(Args)}});
        {error, multiple, Name} ->
            erlang:error({type_error, {multiple_values_for_argument, Name}});
        {error, unknown, Name} ->
            erlang:error({type_error, {unexpected_keyword_argument, Name}})
    end.

builtin_import_bound(Name, FromList) ->
    Module = pyrlang_module:load(Name),
    case truthy_fromlist(FromList) of
        true ->
            Module;
        false ->
            case binary:split(normalize_name(Name), <<".">>) of
                [Top, _Rest] -> pyrlang_module:load(Top);
                [_Single] -> Module
            end
    end.

bind_import_args(Args, KwArgs) when length(Args) =< 5 ->
    ParamNames = [<<"name">>, <<"globals">>, <<"locals">>, <<"fromlist">>, <<"level">>],
    Defaults = #{
        <<"name">> => undefined,
        <<"globals">> => none,
        <<"locals">> => none,
        <<"fromlist">> => {},
        <<"level">> => 0
    },
    case bind_import_positional(Args, ParamNames, []) of
        {ok, Bound0} -> bind_import_keywords(KwArgs, ParamNames, Defaults, Bound0);
        Error -> Error
    end;
bind_import_args(_Args, _KwArgs) ->
    {error, arity}.

bind_import_positional([Value | Rest], [Name | Names], Acc) ->
    bind_import_positional(Rest, Names, [{Name, Value} | Acc]);
bind_import_positional([], _Names, Acc) ->
    {ok, maps:from_list(lists:reverse(Acc))};
bind_import_positional(_Args, [], _Acc) ->
    {error, arity}.

bind_import_keywords(KwArgs, ParamNames, Defaults, Bound0) ->
    BoundResult = maps:fold(
        fun
            (_Key, _Value, {error, _Reason} = Error) ->
                Error;
            (_Key, _Value, {error, _Reason, _Name} = Error) ->
                Error;
            (Key, Value, {ok, Bound}) ->
                Name = normalize_name(Key),
                case lists:member(Name, ParamNames) of
                    true ->
                        case maps:is_key(Name, Bound) of
                            false -> {ok, Bound#{Name => Value}};
                            true -> {error, multiple, Name}
                        end;
                    false ->
                        {error, unknown, Name}
                end
        end,
        {ok, Bound0},
        KwArgs
    ),
    case BoundResult of
        {ok, Bound} -> import_bound_tuple({ok, maps:merge(Defaults, Bound)});
        Error -> Error
    end.

import_bound_tuple({ok, #{<<"name">> := undefined}}) ->
    {error, arity};
import_bound_tuple({ok, Bound}) ->
    {ok, maps:get(<<"name">>, Bound), maps:get(<<"globals">>, Bound), maps:get(<<"locals">>, Bound),
        maps:get(<<"fromlist">>, Bound), maps:get(<<"level">>, Bound)};
import_bound_tuple(Error) ->
    Error.

truthy_fromlist(none) ->
    false;
truthy_fromlist({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> pyrlang_heap:list_items(Ref) =/= [];
        tuple -> true;
        _ -> true
    end;
truthy_fromlist(Tuple) when is_tuple(Tuple) ->
    tuple_size(Tuple) =/= 0;
truthy_fromlist(List) when is_list(List) ->
    List =/= [];
truthy_fromlist(_) ->
    true.

truthy(none) ->
    false;
truthy(false) ->
    false;
truthy(0) ->
    false;
truthy(Value) when is_float(Value), Value == 0.0 ->
    false;
truthy({py_float_special, _Kind}) ->
    true;
truthy({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> pyrlang_heap:list_items(Ref) =/= [];
        dict -> pyrlang_heap:dict_items(Ref) =/= [];
        set -> pyrlang_heap:set_items(Ref) =/= [];
        instance -> instance_truthy(Ref);
        _Type -> true
    end;
truthy(Binary) when is_binary(Binary) ->
    byte_size(Binary) =/= 0;
truthy(Tuple) when is_tuple(Tuple) ->
    tuple_size(Tuple) =/= 0;
truthy(List) when is_list(List) ->
    List =/= [];
truthy(_Value) ->
    true.

instance_truthy(Ref) ->
    case call_truthy_special(Ref, <<"__bool__">>) of
        {ok, Value} ->
            truthy(Value);
        error ->
            case call_truthy_special(Ref, <<"__len__">>) of
                {ok, Len} when is_integer(Len); is_float(Len) ->
                    Len =/= 0;
                {ok, true} ->
                    true;
                {ok, false} ->
                    false;
                {ok, _Other} ->
                    true;
                error ->
                    case tuple_subclass_items(Ref) of
                        {ok, Items} ->
                            Items =/= [];
                        error ->
                            case string_subclass_value(Ref) of
                                {ok, Value} -> Value =/= <<>>;
                                error -> true
                            end
                    end
            end
    end.

call_truthy_special(Ref, Method) ->
    try pyrlang_object:get_attr(Ref, Method) of
        Callable -> {ok, pyrlang_eval:call(Callable, [])}
    catch
        _:_ -> error
    end.

trace_builtin_flow(Stage, Value) ->
    case os:getenv("PYRLANG_TRACE_NATIVE_FLOW") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_NATIVE ~p ~p~n", [Stage, trace_builtin_value(Value)])
    end.

trace_builtin_value({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        Type -> {py_ref, Type}
    catch
        _:_ -> Ref
    end;
trace_builtin_value({py_function, _Params, _Body, Env}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined)};
trace_builtin_value({py_function, _Params, _Body, Env, _Mode}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined)};
trace_builtin_value({py_function, _Params, _Body, Env, _Mode, _Owner}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined)};
trace_builtin_value({py_bound_method, Callable, _Self}) ->
    {py_bound_method, trace_builtin_value(Callable)};
trace_builtin_value(List) when is_list(List) ->
    {list, length(List)};
trace_builtin_value(Tuple) when is_tuple(Tuple) ->
    {tuple, tuple_size(Tuple)};
trace_builtin_value(Value) ->
    Value.

normalize_name(Name) when is_binary(Name) ->
    Name;
normalize_name(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
normalize_name(Name) when is_list(Name) ->
    unicode:characters_to_binary(Name);
normalize_name({py_ref, _} = Name) ->
    case string_subclass_value(Name) of
        {ok, Value} ->
            Value;
        error ->
            case pathlike_name(Name) of
                {ok, Value} -> Value;
                error -> erlang:error({type_error, {expected_string, Name}})
            end
    end.

pathlike_name({py_ref, _} = Name) ->
    try pyrlang_object:get_attr(Name, <<"__fspath__">>) of
        Fspath ->
            Value = pyrlang_eval:call(Fspath, []),
            case Value of
                Bin when is_binary(Bin) -> {ok, Bin};
                List when is_list(List) -> {ok, unicode:characters_to_binary(List)};
                _ -> error
            end
    catch
        _:_ -> error
    end.
