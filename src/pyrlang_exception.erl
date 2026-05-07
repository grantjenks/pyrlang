-module(pyrlang_exception).

-export([
    type/1,
    make/1,
    make/2,
    make_args/2,
    make_args/3,
    is_exception/1,
    exception_type/1,
    message/1,
    args/1,
    get_attr/2,
    set_attr/3,
    type_matches/2,
    matches/2,
    raise/1
]).

-spec type(binary() | string() | atom()) -> {py_exception_type, binary()}.
type(Name) when is_binary(Name) ->
    {py_exception_type, Name};
type(Name) when is_atom(Name) ->
    {py_exception_type, atom_to_binary(Name, utf8)};
type(Name) when is_list(Name) ->
    {py_exception_type, unicode:characters_to_binary(Name)}.

-spec make(term()) -> map().
make({py_exception_type, Type}) ->
    make_args({py_exception_type, Type}, []);
make(Message) ->
    make(type(<<"Exception">>), Message).

-spec make(term(), term()) -> map().
make({py_exception_type, Type}, Message) ->
    make_args({py_exception_type, Type}, [Message]);
make(Type, Message) ->
    make_args(Type, [Message]).

-spec make_args(term(), [term()]) -> map().
make_args(Type, Args) ->
    make_args(Type, Args, #{}).

-spec make_args(term(), [term()], map()) -> map().
make_args({py_exception_type, Type}, Args, KwArgs) ->
    #{
        py_exception => true,
        type => Type,
        args => list_to_tuple(Args),
        kwargs => KwArgs,
        attrs_key => make_ref(),
        message => args_message(Args),
        trace => []
    };
make_args(Type, Args, KwArgs) ->
    make_args(type(Type), Args, KwArgs).

-spec is_exception(term()) -> boolean().
is_exception(Value) when is_map(Value) ->
    maps:get(py_exception, Value, false) =:= true;
is_exception({py_ref, _} = Value) ->
    pyrlang_object:is_exception_instance(Value);
is_exception(_Value) ->
    false.

-spec exception_type(map()) -> binary().
exception_type({py_ref, _} = Exception) ->
    Data = pyrlang_heap:data(Exception),
    Class = maps:get(class, Data),
    pyrlang_object:class_name(Class);
exception_type(Exception) ->
    maps:get(type, Exception).

-spec message(map()) -> binary().
message({py_ref, _} = Exception) ->
    args_message(tuple_to_list(args(Exception)));
message(Exception) ->
    maps:get(message, Exception).

-spec args(map()) -> tuple().
args({py_ref, _} = Exception) ->
    Data = pyrlang_heap:data(Exception),
    Attrs = maps:get(attrs, Data),
    maps:get(<<"args">>, Attrs, {});
args(Exception) ->
    maps:get(args, Exception, {}).

-spec get_attr(map(), term()) -> {ok, term()} | error.
get_attr(#{py_exception := true, attrs_key := Key}, Name) ->
    Attrs = exception_attrs(Key),
    maps:find(Name, Attrs);
get_attr(#{py_exception := true}, _Name) ->
    error.

-spec set_attr(map(), term(), term()) -> ok.
set_attr(#{py_exception := true, attrs_key := Key}, Name, Value) ->
    Attrs = exception_attrs(Key),
    erlang:put({py_exception_attrs, Key}, maps:put(Name, Value, Attrs)),
    ok;
set_attr(#{py_exception := true}, _Name, _Value) ->
    ok.

exception_attrs(Key) ->
    case erlang:get({py_exception_attrs, Key}) of
        undefined -> #{};
        Attrs when is_map(Attrs) -> Attrs
    end.

-spec type_matches(binary(), binary()) -> boolean().
type_matches(Type, Expected) ->
    exception_type_matches(Type, Expected).

-spec matches(term(), map()) -> boolean().
matches(any, Exception) ->
    is_exception(Exception);
matches({py_exception_type, <<"BaseException">>}, Exception) ->
    is_exception(Exception);
matches({py_exception_type, <<"Exception">>}, Exception) ->
    is_exception(Exception);
matches({py_exception_type, Type}, {py_ref, _} = Exception) ->
    is_exception(Exception) andalso
        pyrlang_object:exception_class_matches(maps:get(class, pyrlang_heap:data(Exception)), Type);
matches({py_exception_type, Type}, Exception) ->
    is_exception(Exception) andalso exception_type_matches(exception_type(Exception), Type);
matches({py_ref, _} = Class, {py_ref, _} = Exception) ->
    is_exception(Exception) andalso
        pyrlang_heap:type(Class) =:= class andalso
        lists:member(Class, pyrlang_object:mro(maps:get(class, pyrlang_heap:data(Exception))));
matches(Types, Exception) when is_tuple(Types) ->
    lists:any(fun(Type) -> matches(Type, Exception) end, tuple_to_list(Types));
matches(Type, Exception) when is_binary(Type); is_atom(Type); is_list(Type) ->
    matches(type(Type), Exception);
matches(_Type, _Exception) ->
    false.

-spec raise(term()) -> no_return().
raise(Exception) when is_map(Exception) ->
    trace_raise(Exception, exception_map),
    throw({py_exception, Exception});
raise({py_ref, _} = Exception) ->
    case is_exception(Exception) of
        true ->
            trace_raise(Exception, exception_ref),
            throw({py_exception, Exception});
        false ->
            case pyrlang_object:is_exception_class(Exception) of
                true ->
                    raise(pyrlang_eval:call(Exception, []));
                false ->
                    trace_raise(Exception, non_exception_ref),
                    raise(make(type(<<"TypeError">>), <<"exceptions must derive from BaseException">>))
            end
    end;
raise({py_exception_type, _Type} = Type) ->
    raise(make(Type));
raise(Message) ->
    raise(make(Message)).

trace_raise(Exception, Kind) ->
    case os:getenv("PYRLANG_TRACE_RAISE_ALL") =/= false orelse (Kind =:= non_exception_ref andalso os:getenv("PYRLANG_TRACE_RAISE") =/= false) of
        true ->
            io:format(
                standard_error,
                "PYRLANG_RAISE kind=~p type=~p message=~p exception=~p stack=~p~n",
                [Kind, safe_exception_type(Exception), safe_message(Exception), Exception, pyrlang_eval:trace_function_stack()]
            );
        false ->
            ok
    end.

safe_exception_type(Exception) ->
    try exception_type(Exception)
    catch _:_ -> undefined
    end.

safe_message(Exception) ->
    try message(Exception)
    catch _:_ -> undefined
    end.

normalize_message(Value) when is_binary(Value) ->
    Value;
normalize_message(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
normalize_message(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
normalize_message(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

args_message([]) ->
    <<>>;
args_message([_Errno, Strerror | _Rest]) when is_binary(Strerror) ->
    Strerror;
args_message([Message | _Rest]) ->
    normalize_message(Message).

exception_type_matches(Type, Type) ->
    true;
exception_type_matches(_Type, <<"BaseException">>) ->
    true;
exception_type_matches(_Type, <<"Exception">>) ->
    true;
exception_type_matches(Type, Expected) ->
    lists:member(Expected, exception_type_bases(Type)).

exception_type_bases(<<"BlockingIOError">>) -> [<<"OSError">>];
exception_type_bases(<<"ChildProcessError">>) -> [<<"OSError">>];
exception_type_bases(<<"ConnectionAbortedError">>) -> [<<"ConnectionError">>, <<"OSError">>];
exception_type_bases(<<"ConnectionRefusedError">>) -> [<<"ConnectionError">>, <<"OSError">>];
exception_type_bases(<<"ConnectionResetError">>) -> [<<"ConnectionError">>, <<"OSError">>];
exception_type_bases(<<"ConnectionError">>) -> [<<"OSError">>];
exception_type_bases(<<"FileExistsError">>) -> [<<"OSError">>];
exception_type_bases(<<"FileNotFoundError">>) -> [<<"OSError">>];
exception_type_bases(<<"InterruptedError">>) -> [<<"OSError">>];
exception_type_bases(<<"IsADirectoryError">>) -> [<<"OSError">>];
exception_type_bases(<<"NotADirectoryError">>) -> [<<"OSError">>];
exception_type_bases(<<"PermissionError">>) -> [<<"OSError">>];
exception_type_bases(<<"TimeoutError">>) -> [<<"OSError">>];
exception_type_bases(<<"ModuleNotFoundError">>) -> [<<"ImportError">>];
exception_type_bases(<<"IndexError">>) -> [<<"LookupError">>];
exception_type_bases(<<"KeyError">>) -> [<<"LookupError">>];
exception_type_bases(<<"FloatingPointError">>) -> [<<"ArithmeticError">>];
exception_type_bases(<<"OverflowError">>) -> [<<"ArithmeticError">>];
exception_type_bases(<<"ZeroDivisionError">>) -> [<<"ArithmeticError">>];
exception_type_bases(<<"DecimalException">>) -> [<<"ArithmeticError">>];
exception_type_bases(<<"InvalidOperation">>) -> [<<"DecimalException">>, <<"ArithmeticError">>];
exception_type_bases(<<"Rounded">>) -> [<<"DecimalException">>, <<"ArithmeticError">>];
exception_type_bases(<<"RecursionError">>) -> [<<"RuntimeError">>];
exception_type_bases(<<"UnicodeDecodeError">>) -> [<<"UnicodeError">>];
exception_type_bases(<<"UnicodeEncodeError">>) -> [<<"UnicodeError">>];
exception_type_bases(<<"UnicodeTranslateError">>) -> [<<"UnicodeError">>];
exception_type_bases(<<"DatabaseError">>) -> [<<"Error">>];
exception_type_bases(<<"DataError">>) -> [<<"DatabaseError">>, <<"Error">>];
exception_type_bases(<<"OperationalError">>) -> [<<"DatabaseError">>, <<"Error">>];
exception_type_bases(<<"IntegrityError">>) -> [<<"DatabaseError">>, <<"Error">>];
exception_type_bases(<<"InternalError">>) -> [<<"DatabaseError">>, <<"Error">>];
exception_type_bases(<<"ProgrammingError">>) -> [<<"DatabaseError">>, <<"Error">>];
exception_type_bases(<<"NotSupportedError">>) -> [<<"DatabaseError">>, <<"Error">>];
exception_type_bases(<<"InterfaceError">>) -> [<<"Error">>];
exception_type_bases(<<"DuplicateDatabase">>) -> [<<"ProgrammingError">>, <<"DatabaseError">>, <<"Error">>];
exception_type_bases(<<"BytesWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"DeprecationWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"FutureWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"ImportWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"PendingDeprecationWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"ResourceWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"RuntimeWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"SyntaxWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"UnicodeWarning">>) -> [<<"Warning">>];
exception_type_bases(<<"UserWarning">>) -> [<<"Warning">>];
exception_type_bases(_Type) -> [].
