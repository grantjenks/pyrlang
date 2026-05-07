-module(pyrunicorn_wsgi_tests).

-include_lib("eunit/include/eunit.hrl").

environ_contains_wsgi_and_cgi_keys_test() ->
    Env = pyrunicorn_wsgi:environ(<<"get">>, <<"/todos/?page=1">>, [{<<"host">>, <<"example.test">>}], <<"">>, #{}),
    ?assertEqual(<<"GET">>, maps:get(<<"REQUEST_METHOD">>, Env)),
    ?assertEqual(<<"/todos/">>, maps:get(<<"PATH_INFO">>, Env)),
    ?assertEqual(<<"page=1">>, maps:get(<<"QUERY_STRING">>, Env)),
    ?assertEqual({1, 0}, maps:get(<<"wsgi.version">>, Env)),
    ?assertEqual(<<"example.test">>, maps:get(<<"HTTP_HOST">>, Env)).

wsgi_input_and_errors_are_stream_objects_test() ->
    pyrlang_heap:init(),
    Env = pyrunicorn_wsgi:environ(<<"post">>, <<"/submit">>, [], <<"payload">>, #{errors => self()}),
    InputRead = pyrlang_object:get_attr(maps:get(<<"wsgi.input">>, Env), <<"read">>),
    ?assertEqual(<<"payload">>, pyrlang_eval:call(InputRead, [])),
    ErrorsWrite = pyrlang_object:get_attr(maps:get(<<"wsgi.errors">>, Env), <<"write">>),
    ?assertEqual(none, pyrlang_eval:call(ErrorsWrite, [<<"problem">>])),
    receive
        {wsgi_error, <<"problem">>} -> ok
    after 1000 ->
        error(wsgi_error_not_written)
    end.

wsgi_input_supports_sized_and_line_reads_from_pyrlang_source_test() ->
    pyrlang_heap:init(),
    Source = <<
        "def application(environ, start_response):\n",
        "    input = environ[\"wsgi.input\"]\n",
        "    data = input.read(4) + \"|\" + input.readline() + \"|\" + input.read()\n",
        "    start_response(\"200 OK\", [])\n",
        "    return [data]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"200 OK">>, [], [<<"payl|oad\n|next">>]},
        pyrunicorn_wsgi:call_app(AppSpec, <<"POST">>, <<"/">>, [], <<"payload\nnext">>)
    ),
    cleanup_wsgi_app(Dir, Module).

wsgi_environ_uses_runtime_options_from_pyrlang_source_test() ->
    pyrlang_heap:init(),
    Source = <<
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [])\n",
        "    return [environ[\"SERVER_NAME\"] + \":\" + environ[\"SERVER_PORT\"] + \":\" + environ[\"REMOTE_ADDR\"] + \":\" + environ[\"wsgi.url_scheme\"]]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"200 OK">>, [], [<<"bound.test:9090:10.0.0.1:https">>]},
        pyrunicorn_wsgi:call_app(
            AppSpec,
            <<"GET">>,
            <<"/">>,
            [],
            <<"">>,
            #{
                server_name => <<"bound.test">>,
                server_port => <<"9090">>,
                remote_addr => <<"10.0.0.1">>,
                scheme => <<"https">>
            }
        )
    ),
    cleanup_wsgi_app(Dir, Module).

worker_runs_trivial_wsgi_app_in_beam_actor_test() ->
    pyrlang_heap:init(),
    App = fun(_Env, StartResponse) ->
        ok = StartResponse(<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}]),
        [<<"hello">>, <<" beam">>]
    end,
    Worker = pyrunicorn_worker:start(App),
    ?assertEqual(
        {<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], [<<"hello">>, <<" beam">>]},
        pyrunicorn_worker:request(Worker, <<"GET">>, <<"/">>, [], <<"">>)
    ).

pyrunicorn_loads_pyrlang_module_callable_test() ->
    pyrlang_heap:init(),
    {Dir, Module, AppSpec} = write_wsgi_app(),
    ok = pyrlang:set_path([Dir]),
    App = pyrunicorn_wsgi:load_app(AppSpec),
    ?assertEqual(
        {<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], [<<"path=">>, <<"/pyrlang">>]},
        pyrunicorn_wsgi:call_app(App, <<"GET">>, <<"/pyrlang">>, [], <<"">>)
    ),
    cleanup_wsgi_app(Dir, Module).

worker_loads_pyrlang_wsgi_app_inside_actor_test() ->
    pyrlang_heap:init(),
    {Dir, Module, AppSpec} = write_wsgi_app(),
    ok = pyrlang:set_path([Dir]),
    Worker = pyrunicorn_worker:start(AppSpec),
    ?assertEqual(
        {<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], [<<"path=">>, <<"/actor">>]},
        pyrunicorn_worker:request(Worker, <<"GET">>, <<"/actor">>, [], <<"">>)
    ),
    cleanup_wsgi_app(Dir, Module).

worker_module_globals_are_actor_local_test() ->
    pyrlang_heap:init(),
    Source = <<
        "state = []\n",
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [])\n",
        "    state.append(\"x\")\n",
        "    return [str(len(state))]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    Worker1 = pyrunicorn_worker:start(AppSpec),
    Worker2 = pyrunicorn_worker:start(AppSpec),
    ?assertEqual({<<"200 OK">>, [], [<<"1">>]}, pyrunicorn_worker:request(Worker1, <<"GET">>, <<"/">>, [], <<"">>)),
    ?assertEqual({<<"200 OK">>, [], [<<"2">>]}, pyrunicorn_worker:request(Worker1, <<"GET">>, <<"/">>, [], <<"">>)),
    ?assertEqual({<<"200 OK">>, [], [<<"1">>]}, pyrunicorn_worker:request(Worker2, <<"GET">>, <<"/">>, [], <<"">>)),
    cleanup_wsgi_app(Dir, Module).

application_error_becomes_500_response_test() ->
    pyrlang_heap:init(),
    App = fun(_Env, _StartResponse) ->
        erlang:error(app_failed)
    end,
    ?assertEqual(
        {<<"500 Internal Server Error">>, [{<<"content-type">>, <<"text/plain">>}], [<<"internal server error">>]},
        pyrunicorn_wsgi:call_app(App, <<"GET">>, <<"/">>, [], <<"">>)
    ).

pyrlang_application_error_becomes_500_response_test() ->
    pyrlang_heap:init(),
    Source = <<
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [])\n",
        "    raise ValueError(\"boom\")\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"500 Internal Server Error">>, [{<<"content-type">>, <<"text/plain">>}], [<<"internal server error">>]},
        pyrunicorn_wsgi:call_app(AppSpec, <<"GET">>, <<"/">>, [], <<"">>)
    ),
    cleanup_wsgi_app(Dir, Module).

wsgi_response_iterable_close_is_called_when_present_test() ->
    pyrlang_heap:init(),
    Parent = self(),
    Class = pyrlang_object:new_class(<<"ClosingBody">>, [], #{}),
    Body = pyrlang_object:instantiate(Class),
    ok = pyrlang_object:set_attr(Body, <<"close">>, fun() ->
        Parent ! body_closed,
        none
    end),
    ok = pyrlang_object:set_attr(Body, <<"__iter__">>, fun() ->
        pyrlang_iter:iter(pyrlang_heap:list([<<"closed-body">>]))
    end),
    App = fun(_Env, StartResponse) ->
        ok = StartResponse(<<"200 OK">>, []),
        Body
    end,
    {Status, _Headers, BodyChunks} = pyrunicorn_wsgi:call_app(App, <<"GET">>, <<"/">>, [], <<"">>),
    ?assertEqual(<<"200 OK">>, Status),
    ?assertEqual([<<"closed-body">>], BodyChunks),
    receive
        body_closed -> ok
    after 1000 ->
        error(response_body_not_closed)
    end.

pyrlang_wsgi_response_body_uses_iterator_protocol_test() ->
    pyrlang_heap:init(),
    Source = <<
        "class Body:\n",
        "    def __init__(self):\n",
        "        self.items = [\"a\", \"b\"]\n",
        "        self.index = 0\n",
        "    def __iter__(self):\n",
        "        return self\n",
        "    def __next__(self):\n",
        "        if self.index == len(self.items):\n",
        "            raise StopIteration()\n",
        "        value = self.items[self.index]\n",
        "        self.index = self.index + 1\n",
        "        return value\n",
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [])\n",
        "    return Body()\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"200 OK">>, [], [<<"a">>, <<"b">>]},
        pyrunicorn_wsgi:call_app(AppSpec, <<"GET">>, <<"/iter">>, [], <<"">>)
    ),
    cleanup_wsgi_app(Dir, Module).

pyrlang_wsgi_start_response_write_callable_buffers_body_test() ->
    pyrlang_heap:init(),
    Source = <<
        "def application(environ, start_response):\n",
        "    write = start_response(\"200 OK\", [])\n",
        "    write(\"prefix\")\n",
        "    return [\"suffix\"]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"200 OK">>, [], [<<"prefix">>, <<"suffix">>]},
        pyrunicorn_wsgi:call_app(AppSpec, <<"GET">>, <<"/write">>, [], <<"">>)
    ),
    cleanup_wsgi_app(Dir, Module).

pyrlang_wsgi_start_response_exc_info_replaces_unsent_headers_test() ->
    pyrlang_heap:init(),
    Source = <<
        "def application(environ, start_response):\n",
        "    try:\n",
        "        start_response(\"200 OK\", [[\"x-old\", \"yes\"]])\n",
        "        raise ValueError(\"boom\")\n",
        "    except ValueError as err:\n",
        "        start_response(\"500 Internal Server Error\", [[\"content-type\", \"text/plain\"]], err)\n",
        "        return [\"handled\"]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"500 Internal Server Error">>, [{<<"content-type">>, <<"text/plain">>}], [<<"handled">>]},
        pyrunicorn_wsgi:call_app(AppSpec, <<"GET">>, <<"/exc-info">>, [], <<"">>)
    ),
    cleanup_wsgi_app(Dir, Module).

pyrlang_wsgi_start_response_exc_info_after_write_keeps_sent_response_test() ->
    pyrlang_heap:init(),
    Source = <<
        "def application(environ, start_response):\n",
        "    try:\n",
        "        write = start_response(\"200 OK\", [[\"x-old\", \"yes\"]])\n",
        "        write(\"prefix\")\n",
        "        raise ValueError(\"boom\")\n",
        "    except ValueError as err:\n",
        "        start_response(\"500 Internal Server Error\", [[\"content-type\", \"text/plain\"]], err)\n",
        "        return [\"handled\"]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"200 OK">>, [{<<"x-old">>, <<"yes">>}], [<<"prefix">>]},
        pyrunicorn_wsgi:call_app(AppSpec, <<"GET">>, <<"/exc-info-sent">>, [], <<"">>)
    ),
    cleanup_wsgi_app(Dir, Module).

http_parse_and_format_response_test() ->
    Raw = <<"GET /healthz?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
    ?assertEqual({ok, <<"GET">>, <<"/healthz?x=1">>, [{<<"host">>, <<"localhost">>}], <<"">>}, pyrunicorn_http:parse_request(Raw)),
    Response = pyrunicorn_http:format_response({<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], [<<"ok">>]}),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Response).

http_format_response_recomputes_content_length_test() ->
    Response = pyrunicorn_http:format_response(
        {<<"200 OK">>, [{<<"content-length">>, <<"1">>}], [<<"abc">>]}
    ),
    ?assert(binary:match(Response, <<"content-length: 3\r\n">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Response, <<"content-length: 1\r\n">>)).

http_parse_rejects_malformed_headers_test() ->
    ?assertEqual(
        {error, {bad_header, <<"Broken">>}},
        pyrunicorn_http:parse_request(<<"GET / HTTP/1.1\r\nBroken\r\n\r\n">>)
    ),
    ?assertEqual(
        {error, bad_content_length},
        pyrunicorn_http:parse_request(<<"POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n">>)
    ),
    ?assertEqual(
        {error, bad_content_length},
        pyrunicorn_http:parse_request(<<"POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n">>)
    ).

tcp_server_serves_trivial_wsgi_app_test() ->
    App = fun(Env, StartResponse) ->
        ok = StartResponse(<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}]),
        [<<"path=">>, maps:get(<<"PATH_INFO">>, Env)]
    end,
    {ok, Server, Port} = pyrunicorn_server:start(App),
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Socket, <<"GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    ok = gen_tcp:close(Socket),
    ok = pyrunicorn_server:stop(Server),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Response),
    ?assert(binary:match(Response, <<"path=/hello">>) =/= nomatch).

tcp_server_serves_pyrlang_wsgi_app_spec_test() ->
    pyrlang_heap:init(),
    {Dir, Module, AppSpec} = write_wsgi_app(),
    ok = pyrlang:set_path([Dir]),
    {ok, Server, Port} = pyrunicorn_server:start(AppSpec),
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Socket, <<"GET /pyrlang HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    ok = gen_tcp:close(Socket),
    ok = pyrunicorn_server:stop(Server),
    cleanup_wsgi_app(Dir, Module),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Response),
    ?assert(binary:match(Response, <<"path=/pyrlang">>) =/= nomatch).

tcp_server_serves_django_style_static_files_test() ->
    OldPath = pyrlang_module:path(),
    Unique = integer_to_binary(erlang:system_time(nanosecond)),
    Dir = filename:join("/tmp", "pyrlang_static_" ++ binary_to_list(Unique)),
    CssDir = filename:join([Dir, "django", "contrib", "admin", "static", "admin", "css"]),
    ok = file:make_dir(Dir),
    ok = make_dir(filename:join(Dir, "django")),
    ok = make_dir(filename:join([Dir, "django", "contrib"])),
    ok = make_dir(filename:join([Dir, "django", "contrib", "admin"])),
    ok = make_dir(filename:join([Dir, "django", "contrib", "admin", "static"])),
    ok = make_dir(filename:join([Dir, "django", "contrib", "admin", "static", "admin"])),
    ok = make_dir(CssDir),
    ok = write_file(filename:join(CssDir, "base.css"), <<"body{color:red}">>),
    ok = pyrlang:set_path([Dir | OldPath]),
    App = fun(Env, StartResponse) ->
        ok = StartResponse(<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}]),
        [<<"fallback=">>, maps:get(<<"PATH_INFO">>, Env)]
    end,
    {ok, Server, Port} = pyrunicorn_server:start(App),
    Response = http_get(Port, <<"/static/admin/css/base.css?v=1">>),
    Missing = http_get(Port, <<"/static/admin/css/missing.css">>),
    Unsafe = http_get(Port, <<"/static/../secret.txt">>),
    ok = pyrunicorn_server:stop(Server),
    ok = pyrlang:set_path(OldPath),
    cleanup_tree(Dir),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Response),
    ?assert(binary:match(Response, <<"content-type: text/css; charset=utf-8\r\n">>) =/= nomatch),
    ?assert(binary:match(Response, <<"body{color:red}">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Response, <<"fallback=">>)),
    ?assertMatch(<<"HTTP/1.1 404 Not Found\r\n", _/binary>>, Missing),
    ?assertMatch(<<"HTTP/1.1 403 Forbidden\r\n", _/binary>>, Unsafe).

tcp_server_passes_bound_port_and_remote_addr_to_pyrlang_wsgi_environ_test() ->
    pyrlang_heap:init(),
    Source = <<
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [])\n",
        "    return [environ[\"SERVER_PORT\"] + \":\" + environ[\"REMOTE_ADDR\"]]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    {ok, Server, Port} = pyrunicorn_server:start(AppSpec),
    Response = http_get(Port, <<"/env">>),
    ok = pyrunicorn_server:stop(Server),
    cleanup_wsgi_app(Dir, Module),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Response),
    ?assert(binary:match(Response, <<(integer_to_binary(Port))/binary, ":127.0.0.1">>) =/= nomatch).

tcp_server_reads_content_length_body_across_packets_test() ->
    App = fun(Env, StartResponse) ->
        ok = StartResponse(<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}]),
        Input = pyrlang_object:get_attr(maps:get(<<"wsgi.input">>, Env), <<"read">>),
        [pyrlang_eval:call(Input, [])]
    end,
    {ok, Server, Port} = pyrunicorn_server:start(App),
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Socket, <<"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello">>),
    timer:sleep(20),
    ok = gen_tcp:send(Socket, <<" world">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    ok = gen_tcp:close(Socket),
    ok = pyrunicorn_server:stop(Server),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Response),
    ?assert(binary:match(Response, <<"hello world">>) =/= nomatch).

tcp_server_returns_400_for_malformed_request_test() ->
    App = fun(_Env, StartResponse) ->
        ok = StartResponse(<<"200 OK">>, []),
        [<<"ok">>]
    end,
    {ok, Server, Port} = pyrunicorn_server:start(App),
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Socket, <<"POST /bad HTTP/1.1\r\nContent-Length: nope\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    ok = gen_tcp:close(Socket),
    ok = pyrunicorn_server:stop(Server),
    ?assertMatch(<<"HTTP/1.1 400 Bad Request\r\n", _/binary>>, Response),
    ?assert(binary:match(Response, <<"bad_content_length">>) =/= nomatch).

tcp_server_rejects_port_already_in_use_test() ->
    App = fun(_Env, StartResponse) ->
        ok = StartResponse(<<"200 OK">>, []),
        [<<"ok">>]
    end,
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, raw}, {ip, {0, 0, 0, 0}}]),
    {ok, Port} = inet:port(Listen),
    try
        ?assertEqual(
            {error, eaddrinuse},
            pyrunicorn_server:start(App, #{port => Port, ip => {127, 0, 0, 1}})
        )
    after
        gen_tcp:close(Listen)
    end.

tcp_server_round_robins_across_worker_actors_test() ->
    pyrlang_heap:init(),
    Source = <<
        "state = []\n",
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [[\"content-type\", \"text/plain\"]])\n",
        "    state.append(\"x\")\n",
        "    return [str(len(state))]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    {ok, Server, Port} = pyrunicorn_server:start(AppSpec, #{workers => 2}),
    Response1 = http_get(Port, <<"/one">>),
    Response2 = http_get(Port, <<"/two">>),
    ok = pyrunicorn_server:stop(Server),
    cleanup_wsgi_app(Dir, Module),
    ?assert(binary:match(Response1, <<"\r\n\r\n1">>) =/= nomatch),
    ?assert(binary:match(Response2, <<"\r\n\r\n1">>) =/= nomatch).

server_restarts_crashed_worker_actor_test() ->
    pyrlang_heap:init(),
    Source = <<
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [[\"content-type\", \"text/plain\"]])\n",
        "    return [\"restart:\", environ[\"PATH_INFO\"]]\n"
    >>,
    {Dir, Module, AppSpec} = write_wsgi_app(Source),
    ok = pyrlang:set_path([Dir]),
    {ok, Server, Port} = pyrunicorn_server:start(AppSpec, #{workers => 1}),
    try
        [Worker1] = pyrunicorn_server:workers(Server),
        erlang:exit(Worker1, kill),
        Worker2 = wait_for_restarted_worker(Server, Worker1, 50),
        ?assert(erlang:is_process_alive(Worker2)),
        Response = http_get(Port, <<"/restart">>),
        ?assert(binary:match(Response, <<"restart:/restart">>) =/= nomatch)
    after
        ok = pyrunicorn_server:stop(Server),
        cleanup_wsgi_app(Dir, Module)
    end.

request_worker_crash_becomes_http_500_test() ->
    App = fun(_Env, _StartResponse) ->
        erlang:exit(erlang:self(), kill)
    end,
    {ok, Server, Port} = pyrunicorn_server:start(App, #{workers => 1}),
    try
        Response = http_get(Port, <<"/crash">>),
        ?assertMatch(<<"HTTP/1.1 500 Internal Server Error\r\n", _/binary>>, Response)
    after
        ok = pyrunicorn_server:stop(Server)
    end.

minimal_django_style_wsgi_boot_test() ->
    pyrlang_heap:init(),
    Dir = write_minimal_django_project(),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], [<<"django:/todo">>]},
        pyrunicorn_wsgi:call_app(<<"mysite.wsgi:application">>, <<"GET">>, <<"/todo">>, [], <<"">>)
    ),
    cleanup_tree(Dir).

loaded_py_ref_wsgi_app_can_be_called_repeatedly_test() ->
    pyrlang_heap:init(),
    Dir = write_minimal_django_project(),
    ok = pyrlang:set_path([Dir]),
    App = pyrunicorn_wsgi:load_app(<<"mysite.wsgi:application">>),
    ?assertEqual(
        {<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], [<<"django:/one">>]},
        pyrunicorn_wsgi:call_app(App, <<"GET">>, <<"/one">>, [], <<"">>)
    ),
    ?assertEqual(
        {<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], [<<"django:/two">>]},
        pyrunicorn_wsgi:call_app(App, <<"GET">>, <<"/two">>, [], <<"">>)
    ),
    cleanup_tree(Dir).

minimal_django_style_middleware_chain_test() ->
    pyrlang_heap:init(),
    Dir = write_minimal_django_middleware_project(),
    ok = pyrlang:set_path([Dir]),
    ?assertEqual(
        {<<"200 OK">>, [{<<"content-type">>, <<"text/plain">>}], [<<"mw:view:/todo">>]},
        pyrunicorn_wsgi:call_app(<<"mysite.wsgi:application">>, <<"GET">>, <<"/todo">>, [], <<"">>)
    ),
    cleanup_tree(Dir).

write_wsgi_app() ->
    Source = <<
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [[\"content-type\", \"text/plain\"]], None)\n",
        "    return [\"path=\", environ[\"PATH_INFO\"]]\n"
    >>,
    write_wsgi_app(Source).

write_wsgi_app(Source) ->
    Unique = integer_to_binary(erlang:system_time(nanosecond)),
    Module = <<"wsgi_app_", Unique/binary>>,
    Dir = filename:join("/tmp", "pyrlang_wsgi_" ++ binary_to_list(Unique)),
    _ = cleanup_wsgi_app(Dir, Module),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, binary_to_list(Module) ++ ".pyr"),
    ok = file:write_file(Path, Source),
    {Dir, Module, <<Module/binary, ":application">>}.

cleanup_wsgi_app(Dir, Module) ->
    _ = file:delete(filename:join(Dir, binary_to_list(Module) ++ ".pyr")),
    _ = file:del_dir(Dir),
    ok.

http_get(Port, Path) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Socket, <<"GET ", Path/binary, " HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    ok = gen_tcp:close(Socket),
    Response.

wait_for_restarted_worker(_Server, OldPid, 0) ->
    erlang:error({worker_not_restarted, OldPid});
wait_for_restarted_worker(Server, OldPid, Attempts) ->
    case [
        Pid
        || Pid <- pyrunicorn_server:workers(Server),
           Pid =/= OldPid,
           erlang:is_process_alive(Pid)
    ] of
        [Pid | _] ->
            Pid;
        [] ->
            timer:sleep(50),
            wait_for_restarted_worker(Server, OldPid, Attempts - 1)
    end.

write_minimal_django_project() ->
    Unique = integer_to_binary(erlang:system_time(nanosecond)),
    Dir = filename:join("/tmp", "pyrlang_django_" ++ binary_to_list(Unique)),
    ok = file:make_dir(Dir),
    ok = make_dir(filename:join(Dir, "django")),
    ok = make_dir(filename:join([Dir, "django", "core"])),
    ok = make_dir(filename:join([Dir, "django", "http"])),
    ok = make_dir(filename:join(Dir, "mysite")),
    ok = write_file(filename:join([Dir, "django", "__init__.pyr"]), <<"">>),
    ok = write_file(filename:join([Dir, "django", "core", "__init__.pyr"]), <<"">>),
    ok = write_file(filename:join([Dir, "django", "http", "__init__.pyr"]), <<
        "class HttpResponse:\n",
        "    def __init__(self, content, status=200):\n",
        "        self.content = content\n",
        "        self.status_code = status\n",
        "        self.headers = [[\"content-type\", \"text/plain\"]]\n"
    >>),
    ok = write_file(filename:join([Dir, "django", "core", "wsgi.pyr"]), <<
        "from django.http import HttpResponse\n",
        "def get_wsgi_application():\n",
        "    def application(environ, start_response):\n",
        "        response = HttpResponse(\"django:\" + environ[\"PATH_INFO\"])\n",
        "        start_response(str(response.status_code) + \" OK\", response.headers)\n",
        "        return [response.content]\n",
        "    return application\n"
    >>),
    ok = write_file(filename:join([Dir, "mysite", "__init__.pyr"]), <<"">>),
    ok = write_file(filename:join([Dir, "mysite", "settings.pyr"]), <<"SECRET_KEY = \"test\"\n">>),
    ok = write_file(filename:join([Dir, "mysite", "wsgi.pyr"]), <<
        "import os\n",
        "from django.core.wsgi import get_wsgi_application\n",
        "os.environ.setdefault(\"DJANGO_SETTINGS_MODULE\", \"mysite.settings\")\n",
        "application = get_wsgi_application()\n"
    >>),
    Dir.

write_minimal_django_middleware_project() ->
    Unique = integer_to_binary(erlang:system_time(nanosecond)),
    Dir = filename:join("/tmp", "pyrlang_django_mw_" ++ binary_to_list(Unique)),
    ok = file:make_dir(Dir),
    ok = make_dir(filename:join(Dir, "django")),
    ok = make_dir(filename:join([Dir, "django", "core"])),
    ok = make_dir(filename:join(Dir, "mysite")),
    ok = write_file(filename:join([Dir, "django", "__init__.pyr"]), <<"">>),
    ok = write_file(filename:join([Dir, "django", "core", "__init__.pyr"]), <<"">>),
    ok = write_file(filename:join([Dir, "django", "core", "wsgi.pyr"]), <<
        "import os\n",
        "import importlib\n",
        "def get_wsgi_application():\n",
        "    settings = importlib.import_module(os.environ[\"DJANGO_SETTINGS_MODULE\"])\n",
        "    def view(environ, start_response):\n",
        "        start_response(\"200 OK\", [[\"content-type\", \"text/plain\"]])\n",
        "        return [\"view:\" + environ[\"PATH_INFO\"]]\n",
        "    app = view\n",
        "    for middleware in settings.MIDDLEWARE:\n",
        "        app = middleware(app)\n",
        "    return app\n"
    >>),
    ok = write_file(filename:join([Dir, "mysite", "__init__.pyr"]), <<"">>),
    ok = write_file(filename:join([Dir, "mysite", "middleware.pyr"]), <<
        "class TagMiddleware:\n",
        "    def __init__(self, app):\n",
        "        self.app = app\n",
        "    def __call__(self, environ, start_response):\n",
        "        body = self.app(environ, start_response)\n",
        "        return [\"mw:\" + body[0]]\n"
    >>),
    ok = write_file(filename:join([Dir, "mysite", "settings.pyr"]), <<
        "from mysite.middleware import TagMiddleware\n",
        "SECRET_KEY = \"test\"\n",
        "MIDDLEWARE = [TagMiddleware]\n"
    >>),
    ok = write_file(filename:join([Dir, "mysite", "wsgi.pyr"]), <<
        "import os\n",
        "from django.core.wsgi import get_wsgi_application\n",
        "os.environ.setdefault(\"DJANGO_SETTINGS_MODULE\", \"mysite.settings\")\n",
        "application = get_wsgi_application()\n"
    >>),
    Dir.

make_dir(Dir) ->
    case file:make_dir(Dir) of
        ok -> ok;
        {error, eexist} -> ok
    end.

write_file(Path, Source) ->
    file:write_file(Path, Source).

cleanup_tree(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foreach(fun(File) -> cleanup_tree(filename:join(Dir, File)) end, Files),
            _ = file:del_dir(Dir),
            ok;
        {error, enotdir} ->
            _ = file:delete(Dir),
            ok;
        {error, enoent} ->
            ok
    end.
