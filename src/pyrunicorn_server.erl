-module(pyrunicorn_server).

-export([start/1, start/2, stop/1, workers/1]).

-spec start(term()) -> {ok, pid(), inet:port_number()} | {error, term()}.
start(App) ->
    start(App, #{}).

-spec start(term(), map()) -> {ok, pid(), inet:port_number()} | {error, term()}.
start(App, Options) when is_map(Options) ->
    Parent = erlang:self(),
    ModulePath = pyrlang_module:path(),
    Pid = erlang:spawn(fun() -> init(Parent, App, Options, ModulePath) end),
    receive
        {pyrunicorn_started, Pid, Port} -> {ok, Pid, Port};
        {pyrunicorn_start_error, Pid, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    Pid ! stop,
    ok.

-spec workers(pid()) -> [pid()].
workers(Pid) ->
    Ref = erlang:make_ref(),
    Pid ! {pyrunicorn_server_call, erlang:self(), Ref, workers},
    receive
        {pyrunicorn_server_reply, Ref, Workers} -> Workers
    after 5000 ->
        erlang:error(timeout)
    end.

init(Parent, App, Options, ModulePath) ->
    ok = pyrlang_module:set_path(ModulePath),
    Port = maps:get(port, Options, 0),
    Ip = maps:get(ip, Options, {127, 0, 0, 1}),
    ListenOptions = [
        binary,
        {active, false},
        {packet, raw},
        {reuseaddr, true},
        {ip, Ip}
    ],
    case ensure_port_available(Ip, Port) of
        ok ->
            listen(Parent, App, Options, ModulePath, Port, Ip, ListenOptions);
        {error, Reason} ->
            Parent ! {pyrunicorn_start_error, erlang:self(), Reason}
    end.

listen(Parent, App, Options, _ModulePath, Port, Ip, ListenOptions) ->
    case gen_tcp:listen(Port, ListenOptions) of
        {ok, Listen} ->
            {ok, ActualPort} = inet:port(Listen),
            WorkerOptions = server_worker_options(Options, Ip, ActualPort),
            Workers = start_workers(App, maps:get(workers, Options, 1), WorkerOptions),
            Parent ! {pyrunicorn_started, erlang:self(), ActualPort},
            accept_loop(#{
                listen => Listen,
                app => App,
                options => WorkerOptions,
                workers => Workers,
                next => 1
            });
        {error, Reason} ->
            Parent ! {pyrunicorn_start_error, erlang:self(), Reason}
    end.

ensure_port_available(_Ip, 0) ->
    ok;
ensure_port_available(Ip, Port) ->
    ProbeIp = probe_ip(Ip),
    case gen_tcp:connect(ProbeIp, Port, [binary, {active, false}], 100) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            {error, eaddrinuse};
        {error, _Reason} ->
            ok
    end.

probe_ip({0, 0, 0, 0}) ->
    {127, 0, 0, 1};
probe_ip(Ip) ->
    Ip.

start_workers(App, Count, Options) when is_integer(Count), Count > 0 ->
    [start_worker(App, Options) || _ <- lists:seq(1, Count)];
start_workers(_App, Count, _Options) ->
    erlang:error({bad_worker_count, Count}).

start_worker(App, Options) ->
    Pid = pyrunicorn_worker:start(App, Options),
    Ref = erlang:monitor(process, Pid),
    #{pid => Pid, ref => Ref}.

accept_loop(State = #{listen := Listen, workers := Workers, next := NextWorker}) ->
    receive
        stop ->
            stop_workers(Workers),
            gen_tcp:close(Listen);
        {pyrunicorn_server_call, From, Ref, workers} ->
            From ! {pyrunicorn_server_reply, Ref, worker_pids(Workers)},
            accept_loop(State);
        {'DOWN', MonitorRef, process, Pid, _Reason} ->
            accept_loop(restart_worker(MonitorRef, Pid, State))
    after 0 ->
        case gen_tcp:accept(Listen, 100) of
            {ok, Socket} ->
                Worker = maps:get(pid, lists:nth(NextWorker, Workers)),
                _ = erlang:spawn(fun() -> handle_socket(Socket, Worker, maps:get(options, State)) end),
                accept_loop(State#{next := next_worker(NextWorker, length(Workers))});
            {error, timeout} ->
                accept_loop(State);
            {error, closed} ->
                ok;
            {error, _Reason} ->
                accept_loop(State)
        end
    end.

worker_pids(Workers) ->
    [maps:get(pid, Worker) || Worker <- Workers].

stop_workers(Workers) ->
    lists:foreach(
        fun(#{pid := Pid, ref := Ref}) ->
            erlang:demonitor(Ref, [flush]),
            ok = pyrlang_actor:send(Pid, stop)
        end,
        Workers
    ).

restart_worker(MonitorRef, Pid, State = #{app := App, options := Options, workers := Workers}) ->
    case replace_worker(Workers, MonitorRef, Pid, App, Options) of
        {ok, NewWorkers} -> State#{workers := NewWorkers};
        not_found -> State
    end.

replace_worker([], _MonitorRef, _Pid, _App, _Options) ->
    not_found;
replace_worker([#{pid := Pid, ref := MonitorRef} | Rest], MonitorRef, Pid, App, Options) ->
    {ok, [start_worker(App, Options) | Rest]};
replace_worker([Worker | Rest], MonitorRef, Pid, App, Options) ->
    case replace_worker(Rest, MonitorRef, Pid, App, Options) of
        {ok, NewRest} -> {ok, [Worker | NewRest]};
        not_found -> not_found
    end.

next_worker(Current, Count) when Current >= Count ->
    1;
next_worker(Current, _Count) ->
    Current + 1.

handle_socket(Socket, Worker, Options) ->
    RequestOptions = socket_request_options(Socket),
    case read_request(Socket) of
        {ok, Request} ->
            Response =
                case pyrunicorn_http:parse_request(Request) of
                    {ok, Method, Target, Headers, Body} ->
                        pyrunicorn_http:format_response(response_for_request(Worker, Method, Target, Headers, Body, RequestOptions, Options));
                    {error, Reason} ->
                        pyrunicorn_http:format_response({<<"400 Bad Request">>, [{<<"content-type">>, <<"text/plain">>}], [format_error(Reason)]})
                end,
            ok = gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket);
        {error, _Reason} ->
            gen_tcp:close(Socket)
    end.

read_request(Socket) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} -> read_request(Socket, Data);
        {error, Reason} -> {error, Reason}
    end.

read_request(Socket, Data) ->
    case request_complete(Data) of
        true ->
            {ok, Data};
        false ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, More} -> read_request(Socket, <<Data/binary, More/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

request_complete(Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [Head, Body] ->
            byte_size(Body) >= content_length(Head);
        [_HeadOnly] ->
            false
    end.

content_length(Head) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    case [
        parse_content_length(Value)
        || Line <- Lines,
           [Name, Value] <- [binary:split(Line, <<":">>)],
           string:lowercase(Name) =:= <<"content-length">>
    ] of
        [{ok, Length} | _] -> Length;
        [error | _] -> 0;
        [] -> 0
    end.

parse_content_length(Value) ->
    try binary_to_integer(string:trim(Value)) of
        Length when Length >= 0 -> {ok, Length};
        _Negative -> error
    catch
        error:badarg -> error
    end.

server_worker_options(Options, Ip, ActualPort) ->
    Options1 = put_new_option(server_name, ip_to_binary(Ip), Options),
    Options1#{
        server_port => integer_to_binary(ActualPort),
        multiprocess => maps:get(workers, Options, 1) > 1,
        static_roots => maps:get(static_roots, Options, default_static_roots())
    }.

put_new_option(Key, Value, Options) ->
    case maps:is_key(Key, Options) of
        true -> Options;
        false -> maps:put(Key, Value, Options)
    end.

socket_request_options(Socket) ->
    case inet:peername(Socket) of
        {ok, {Address, _Port}} -> #{remote_addr => ip_to_binary(Address)};
        {error, _Reason} -> #{}
    end.

ip_to_binary(Address) ->
    unicode:characters_to_binary(inet:ntoa(Address)).

format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("bad request: ~p", [Reason])).

response_for_request(Worker, Method, Target, Headers, Body, RequestOptions, Options) ->
    case static_response(Target, Options) of
        not_static ->
            worker_response(Worker, Method, Target, Headers, Body, RequestOptions);
        Response ->
            Response
    end.

worker_response(Worker, Method, Target, Headers, Body, RequestOptions) ->
    try pyrunicorn_worker:request(Worker, Method, Target, Headers, Body, RequestOptions) of
        Response ->
            Response
    catch
        Class:Reason:Stacktrace ->
            trace_worker_error(Class, Reason, Stacktrace),
            {<<"500 Internal Server Error">>, [{<<"content-type">>, <<"text/plain">>}], [<<"internal server error">>]}
    end.

static_response(Target, Options) ->
    StaticUrl = maps:get(static_url, Options, <<"/static/">>),
    Path = request_path(Target),
    case static_relative_path(Path, StaticUrl) of
        not_static ->
            not_static;
        unsafe ->
            {<<"403 Forbidden">>, [{<<"content-type">>, <<"text/plain">>}], [<<"forbidden">>]};
        {ok, RelativeSegments} ->
            case find_static_file(RelativeSegments, maps:get(static_roots, Options, [])) of
                {ok, FilePath, Content} ->
                    {<<"200 OK">>, [{<<"content-type">>, content_type(FilePath)}], [Content]};
                not_found ->
                    {<<"404 Not Found">>, [{<<"content-type">>, <<"text/plain">>}], [<<"not found">>]}
            end
    end.

request_path(Target) ->
    case binary:split(Target, <<"?">>) of
        [Path, _Query] -> Path;
        [Path] -> Path
    end.

static_relative_path(Path, StaticUrl) ->
    case binary:match(Path, StaticUrl) of
        {0, Length} ->
            Relative = binary:part(Path, Length, byte_size(Path) - Length),
            safe_relative_segments(Relative);
        _ ->
            not_static
    end.

safe_relative_segments(Relative) ->
    Segments = binary:split(Relative, <<"/">>, [global]),
    case Segments =/= [] andalso lists:all(fun safe_static_segment/1, Segments) of
        true -> {ok, [binary_to_list(Segment) || Segment <- Segments]};
        false -> unsafe
    end.

safe_static_segment(<<>>) ->
    false;
safe_static_segment(<<".">>) ->
    false;
safe_static_segment(<<"..">>) ->
    false;
safe_static_segment(Segment) ->
    binary:match(Segment, <<"\\">>) =:= nomatch.

find_static_file(_RelativeSegments, []) ->
    not_found;
find_static_file(RelativeSegments, [Root | Rest]) ->
    Path = filename:join([path_string(Root) | RelativeSegments]),
    case file:read_file(Path) of
        {ok, Content} ->
            {ok, Path, Content};
        {error, eisdir} ->
            not_found;
        {error, _Reason} ->
            find_static_file(RelativeSegments, Rest)
    end.

default_static_roots() ->
    {ok, Cwd} = file:get_cwd(),
    Roots =
        [filename:join(Cwd, "static")] ++
        filelib:wildcard(filename:join(Cwd, "*/static")) ++
        lists:flatmap(fun module_static_roots/1, pyrlang_module:path()),
    lists:usort([Root || Root <- Roots, filelib:is_dir(Root)]).

module_static_roots(Base0) ->
    Base = path_string(Base0),
    [
        filename:join(Base, "static"),
        filename:join([Base, "django", "contrib", "admin", "static"])
    ].

content_type(Path) ->
    case string:lowercase(filename:extension(Path)) of
        ".css" -> <<"text/css; charset=utf-8">>;
        ".js" -> <<"application/javascript; charset=utf-8">>;
        ".mjs" -> <<"application/javascript; charset=utf-8">>;
        ".json" -> <<"application/json; charset=utf-8">>;
        ".html" -> <<"text/html; charset=utf-8">>;
        ".txt" -> <<"text/plain; charset=utf-8">>;
        ".svg" -> <<"image/svg+xml">>;
        ".png" -> <<"image/png">>;
        ".jpg" -> <<"image/jpeg">>;
        ".jpeg" -> <<"image/jpeg">>;
        ".gif" -> <<"image/gif">>;
        ".ico" -> <<"image/x-icon">>;
        ".woff" -> <<"font/woff">>;
        ".woff2" -> <<"font/woff2">>;
        _ -> <<"application/octet-stream">>
    end.

path_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
path_string(Value) when is_list(Value) ->
    Value.

trace_worker_error(Class, Reason, Stacktrace) ->
    case os:getenv("PYRUNICORN_TRACE_ERRORS") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRUNICORN_WORKER_ERROR ~p~n", [{Class, Reason, Stacktrace}])
    end.
