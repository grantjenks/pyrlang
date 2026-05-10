-module(pyrunicorn_wsgi).

-export([environ/5, load_app/1, normalize_response/1, call_app/5, call_app/6]).

-spec environ(
    binary() | string(),
    binary() | string(),
    [{binary() | string(), binary() | string()}],
    binary(),
    map()
) -> map().
environ(Method, Target, Headers, Body, Options) ->
    pyrlang_heap:ensure(),
    {Path, Query} = split_target(to_binary(Target)),
    Scheme = option_binary(scheme, Options, <<"http">>),
    ServerName = option_binary(server_name, Options, <<"localhost">>),
    ServerPort = option_binary(server_port, Options, <<"80">>),
    RemoteAddr = option_binary(remote_addr, Options, <<"">>),
    Errors = maps:get(errors, Options, standard_error),
    HeaderMap = headers_to_environ(Headers),
    Base = #{
        <<"REQUEST_METHOD">> => upper_binary(to_binary(Method)),
        <<"SCRIPT_NAME">> => <<"">>,
        <<"PATH_INFO">> => Path,
        <<"QUERY_STRING">> => Query,
        <<"CONTENT_TYPE">> => header_value(<<"content-type">>, Headers, <<"">>),
        <<"CONTENT_LENGTH">> => header_value(
            <<"content-length">>, Headers, integer_to_binary(byte_size(Body))
        ),
        <<"SERVER_NAME">> => ServerName,
        <<"SERVER_PORT">> => ServerPort,
        <<"SERVER_PROTOCOL">> => maps:get(server_protocol, Options, <<"HTTP/1.1">>),
        <<"REMOTE_ADDR">> => RemoteAddr,
        <<"wsgi.version">> => {1, 0},
        <<"wsgi.url_scheme">> => Scheme,
        <<"wsgi.input">> => input_stream(Body),
        <<"wsgi.errors">> => errors_stream(Errors),
        <<"wsgi.multithread">> => false,
        <<"wsgi.multiprocess">> => maps:get(multiprocess, Options, true),
        <<"wsgi.run_once">> => false
    },
    maps:merge(Base, HeaderMap).

-spec load_app(term()) -> term().
load_app(App) when is_function(App, 2) ->
    App;
load_app({py_function, _Params, _Body, _ClosureEnv} = App) ->
    App;
load_app({py_function, _Params, _Body, _ClosureEnv, _IsGenerator} = App) ->
    App;
load_app({py_function, _Params, _Body, _ClosureEnv, _IsGenerator, _OwnerClass} = App) ->
    App;
load_app({py_ref, _} = App) ->
    App;
load_app(Spec) when is_binary(Spec); is_list(Spec) ->
    pyrlang:start(),
    {ModuleName, CallableName} = parse_app_spec(Spec),
    Module = pyrlang_module:load(ModuleName),
    pyrlang_module:get_attr(Module, CallableName).

-spec call_app(
    term(),
    binary() | string(),
    binary() | string(),
    [{binary() | string(), binary() | string()}],
    binary()
) ->
    {binary(), [{binary(), binary()}], [binary()]}.
call_app(App0, Method, Target, Headers, Body) ->
    call_app(App0, Method, Target, Headers, Body, #{}).

-spec call_app(
    term(),
    binary() | string(),
    binary() | string(),
    [{binary() | string(), binary() | string()}],
    binary(),
    map()
) ->
    {binary(), [{binary(), binary()}], [binary()]}.
call_app(App0, Method, Target, Headers, Body, Options) ->
    App = load_app(App0),
    Env = environ(Method, Target, Headers, Body, Options),
    StateKey = {pyrunicorn_response, erlang:make_ref()},
    erlang:put(StateKey, empty_response_state()),
    StartResponse = {py_native_varargs, fun(Args) -> start_response(StateKey, Args) end},
    Result =
        try call_application(App, Env, StateKey, StartResponse) of
            AppResult ->
                response_from_state(StateKey, AppResult)
        catch
            throw:{py_exception_with_env, Exception, _ExceptionEnv} ->
                error_response(StateKey, Exception);
            throw:{py_exception, Exception} ->
                error_response(StateKey, Exception);
            Class:Reason:Stacktrace ->
                error_response(StateKey, {Class, Reason, Stacktrace})
        end,
    erlang:erase(StateKey),
    Result.

-spec normalize_response(term()) -> {binary(), [{binary(), binary()}], [binary()]}.
normalize_response({Status, Headers, Body}) ->
    {to_binary(Status), normalize_headers(Headers), normalize_body_closing(Body)};
normalize_response(Body) ->
    {<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], normalize_body_closing(Body)}.

error_response(_Reason) ->
    trace_error(_Reason),
    {<<"500 Internal Server Error">>, [{<<"content-type">>, <<"text/plain">>}], [
        <<"internal server error">>
    ]}.

error_response(StateKey, Reason) ->
    State = response_state(StateKey),
    case maps:get(headers_sent, State) of
        true -> response_from_started_state(State);
        false -> error_response(Reason)
    end.

trace_error(Reason) ->
    case os:getenv("PYRUNICORN_TRACE_ERRORS") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRUNICORN_ERROR ~p~n", [Reason])
    end.

call_application(App, Env, StateKey, _StartResponse) when is_function(App, 2) ->
    ErlangStartResponse = fun(Status, ResponseHeaders) ->
        _Write = start_response(StateKey, [Status, ResponseHeaders]),
        ok
    end,
    App(Env, ErlangStartResponse);
call_application(App, Env, _StateKey, StartResponse) ->
    EnvRef = pyrlang_heap:dict(maps:to_list(Env)),
    pyrlang_eval:call(App, [EnvRef, StartResponse]).

empty_response_state() ->
    #{
        started => false,
        headers_sent => false,
        status => undefined,
        headers => [],
        writes => []
    }.

response_state(StateKey) ->
    case erlang:get(StateKey) of
        undefined -> empty_response_state();
        State -> State
    end.

response_from_state(StateKey, AppResult) ->
    State = response_state(StateKey),
    case maps:get(started, State) of
        true ->
            response_from_started_state(State, normalize_body_closing(AppResult));
        false ->
            normalize_response(AppResult)
    end.

response_from_started_state(State) ->
    response_from_started_state(State, []).

response_from_started_state(State, BodyChunks) ->
    {
        maps:get(status, State),
        maps:get(headers, State),
        lists:reverse(maps:get(writes, State)) ++ BodyChunks
    }.

start_response(StateKey, [Status, ResponseHeaders]) ->
    begin_response(StateKey, to_binary(Status), normalize_headers(ResponseHeaders), none),
    write_callable(StateKey);
start_response(StateKey, [Status, ResponseHeaders, ExcInfo]) ->
    begin_response(StateKey, to_binary(Status), normalize_headers(ResponseHeaders), ExcInfo),
    write_callable(StateKey);
start_response(_StateKey, Args) ->
    erlang:error({wsgi_start_response_arity, length(Args)}).

begin_response(StateKey, Status, Headers, ExcInfo) ->
    State = response_state(StateKey),
    case {maps:get(started, State), maps:get(headers_sent, State), ExcInfo} of
        {false, _Sent, _AnyExcInfo} ->
            erlang:put(StateKey, State#{started := true, status := Status, headers := Headers});
        {true, false, none} ->
            erlang:error(wsgi_headers_already_set);
        {true, false, _ReplacingExcInfo} ->
            erlang:put(StateKey, State#{status := Status, headers := Headers, writes := []});
        {true, true, _ReplacingExcInfo} ->
            reraise_wsgi_exc_info(ExcInfo)
    end.

reraise_wsgi_exc_info(Exception) when is_map(Exception) ->
    pyrlang_exception:raise(Exception);
reraise_wsgi_exc_info(none) ->
    erlang:error(wsgi_headers_already_sent);
reraise_wsgi_exc_info(ExcInfo) ->
    erlang:error({wsgi_headers_already_sent, ExcInfo}).

write_callable(StateKey) ->
    fun(Chunk) ->
        State = response_state(StateKey),
        Writes = maps:get(writes, State),
        erlang:put(StateKey, State#{headers_sent := true, writes := [to_binary(Chunk) | Writes]}),
        none
    end.

normalize_body(Body) when is_binary(Body) ->
    [Body];
normalize_body({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> [to_binary(Item) || Item <- pyrlang_heap:list_items(Ref)];
        _Type -> [to_binary(Item) || Item <- pyrlang_iter:values(Ref)]
    end;
normalize_body(Body) when is_list(Body) ->
    case all_binaries(Body) of
        true -> Body;
        false -> [unicode:characters_to_binary(Body)]
    end;
normalize_body(Body) ->
    [unicode:characters_to_binary(io_lib:format("~p", [Body]))].

normalize_body_closing(Body) ->
    try
        normalize_body(Body)
    after
        close_body_if_present(Body)
    end.

close_body_if_present({py_ref, _} = Ref) ->
    try pyrlang_object:get_attr(Ref, <<"close">>) of
        Close ->
            _ = pyrlang_eval:call(Close, []),
            ok
    catch
        error:{attribute_error, _Name} ->
            ok
    end;
close_body_if_present(_Body) ->
    ok.

normalize_headers({py_ref, _} = Ref) ->
    list = pyrlang_heap:type(Ref),
    [normalize_header(Header) || Header <- pyrlang_heap:list_items(Ref)];
normalize_headers(Headers) ->
    [normalize_header(Header) || Header <- Headers].

normalize_header({py_ref, _} = Ref) ->
    list = pyrlang_heap:type(Ref),
    case pyrlang_heap:list_items(Ref) of
        [Name, Value] -> {lower_binary(to_binary(Name)), to_binary(Value)};
        Items -> erlang:error({bad_wsgi_header, Items})
    end;
normalize_header({Name, Value}) ->
    {lower_binary(to_binary(Name)), to_binary(Value)};
normalize_header([Name, Value]) ->
    {lower_binary(to_binary(Name)), to_binary(Value)}.

headers_to_environ(Headers) ->
    maps:from_list([
        {<<"HTTP_", (header_env_name(Name))/binary>>, to_binary(Value)}
     || {Name, Value} <- Headers,
        lower_binary(to_binary(Name)) =/= <<"content-type">>,
        lower_binary(to_binary(Name)) =/= <<"content-length">>
    ]).

header_env_name(Name) ->
    Upper = upper_binary(to_binary(Name)),
    binary:replace(Upper, <<"-">>, <<"_">>, [global]).

header_value(Name, Headers, Default) ->
    LowerName = lower_binary(Name),
    case
        [to_binary(Value) || {Key, Value} <- Headers, lower_binary(to_binary(Key)) =:= LowerName]
    of
        [Value | _] -> Value;
        [] -> Default
    end.

split_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [Path, Query] -> {Path, Query};
        [Path] -> {Path, <<"">>}
    end.

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
to_binary(Value) when is_integer(Value) ->
    integer_to_binary(Value);
to_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
to_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

upper_binary(Binary) ->
    string:uppercase(Binary).

lower_binary(Binary) ->
    string:lowercase(Binary).

all_binaries(Items) ->
    lists:all(fun erlang:is_binary/1, Items).

option_binary(Key, Options, Default) ->
    to_binary(maps:get(Key, Options, Default)).

input_stream(Body0) ->
    Body = to_binary(Body0),
    Key = {wsgi_input, erlang:make_ref()},
    erlang:put(Key, #{body => Body, pos => 0}),
    native_instance(<<"WsgiInput">>, #{
        <<"read">> => {py_native_varargs, fun(Args) -> input_read(Key, Args) end},
        <<"readline">> => {py_native_varargs, fun(Args) -> input_readline(Key, Args) end},
        <<"readlines">> => fun() -> pyrlang_heap:list(input_readlines(Key, [])) end,
        <<"close">> => fun() ->
            erlang:erase(Key),
            none
        end
    }).

input_read(Key, []) ->
    input_consume(Key, remaining_input_size(Key));
input_read(Key, [Size]) when is_integer(Size) ->
    input_consume(Key, Size);
input_read(_Key, Args) ->
    erlang:error({wsgi_input_read_arity, length(Args)}).

input_readline(Key, []) ->
    input_consume(Key, next_line_size(Key));
input_readline(Key, [Size]) when is_integer(Size) ->
    input_consume(Key, min_nonnegative(Size, next_line_size(Key)));
input_readline(_Key, Args) ->
    erlang:error({wsgi_input_readline_arity, length(Args)}).

input_readlines(Key, Acc) ->
    case input_readline(Key, []) of
        <<>> -> lists:reverse(Acc);
        Line -> input_readlines(Key, [Line | Acc])
    end.

input_consume(Key, Size0) ->
    State = erlang:get(Key),
    Body = maps:get(body, State),
    Pos = maps:get(pos, State),
    Remaining = byte_size(Body) - Pos,
    Size = min_nonnegative(Size0, Remaining),
    Chunk = binary:part(Body, Pos, Size),
    erlang:put(Key, State#{pos := Pos + Size}),
    Chunk.

remaining_input_size(Key) ->
    State = erlang:get(Key),
    byte_size(maps:get(body, State)) - maps:get(pos, State).

next_line_size(Key) ->
    State = erlang:get(Key),
    Body = maps:get(body, State),
    Pos = maps:get(pos, State),
    Remaining = byte_size(Body) - Pos,
    Rest = binary:part(Body, Pos, Remaining),
    case binary:match(Rest, <<"\n">>) of
        {Index, 1} -> Index + 1;
        nomatch -> Remaining
    end.

min_nonnegative(Size, Limit) when Size < 0 ->
    Limit;
min_nonnegative(Size, Limit) when Size =< Limit ->
    Size;
min_nonnegative(_Size, Limit) ->
    Limit.

errors_stream(Target) ->
    native_instance(<<"WsgiErrors">>, #{
        <<"write">> => fun(Message) ->
            write_error(Target, Message),
            none
        end,
        <<"flush">> => fun() -> none end
    }).

native_instance(Name, Attrs0) ->
    Attrs = put_new_attr(<<"__pyrlang_unsendable__">>, {native_instance, Name}, Attrs0),
    Class = pyrlang_object:new_class(Name, [], #{}),
    Instance = pyrlang_object:instantiate(Class),
    maps:foreach(
        fun(Attr, Value) -> ok = pyrlang_object:set_attr(Instance, Attr, Value) end, Attrs
    ),
    Instance.

put_new_attr(Key, Value, Map) ->
    case maps:is_key(Key, Map) of
        true -> Map;
        false -> maps:put(Key, Value, Map)
    end.

write_error(standard_error, Message) ->
    io:format(standard_error, "~s", [to_binary(Message)]);
write_error(Pid, Message) when is_pid(Pid) ->
    Pid ! {wsgi_error, to_binary(Message)},
    ok;
write_error(_Target, _Message) ->
    ok.

parse_app_spec(Spec0) ->
    Spec = to_binary(Spec0),
    case binary:split(Spec, <<":">>) of
        [ModuleName, CallableName] when ModuleName =/= <<>>, CallableName =/= <<>> ->
            {ModuleName, CallableName};
        _ ->
            erlang:error({bad_wsgi_app_spec, Spec})
    end.
