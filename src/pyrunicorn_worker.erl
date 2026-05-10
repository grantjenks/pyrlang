-module(pyrunicorn_worker).

-export([start/1, start/2, request/5, request/6]).

-define(DEFAULT_REQUEST_TIMEOUT_MS, 60000).

-spec start(term()) -> pid().
start(App) ->
    start(App, #{}).

-spec start(term(), map()) -> pid().
start(App, Options) when is_map(Options) ->
    pyrlang_actor:spawn(fun boot/3, [App, pyrlang_module:path(), Options]).

-spec request(
    pid(),
    binary() | string(),
    binary() | string(),
    [{binary() | string(), binary() | string()}],
    binary()
) ->
    {binary(), [{binary(), binary()}], [binary()]}.
request(Pid, Method, Target, Headers, Body) ->
    request(Pid, Method, Target, Headers, Body, #{}).

-spec request(
    pid(),
    binary() | string(),
    binary() | string(),
    [{binary() | string(), binary() | string()}],
    binary(),
    map()
) ->
    {binary(), [{binary(), binary()}], [binary()]}.
request(Pid, Method, Target, Headers, Body, RequestOptions) ->
    Timeout = request_timeout(RequestOptions),
    pyrlang_actor:call_monitored(
        Pid, {wsgi_request, Method, Target, Headers, Body, RequestOptions}, Timeout
    ).

request_timeout(RequestOptions) when is_map(RequestOptions) ->
    maps:get(
        request_timeout,
        RequestOptions,
        maps:get(request_timeout_ms, RequestOptions, ?DEFAULT_REQUEST_TIMEOUT_MS)
    );
request_timeout(_RequestOptions) ->
    ?DEFAULT_REQUEST_TIMEOUT_MS.

boot(AppSpec, ModulePath, Options) ->
    ok = pyrlang_module:set_path(ModulePath),
    ok = pyrlang_module:set_os_environ(maps:get(os_environ, Options, #{})),
    App = pyrunicorn_wsgi:load_app(AppSpec),
    loop(App, Options).

loop(App, Options) ->
    case pyrlang_actor:recv() of
        {From, Ref, {wsgi_request, Method, Target, Headers, Body, RequestOptions}} ->
            Response = pyrunicorn_wsgi:call_app(
                App, Method, Target, Headers, Body, maps:merge(Options, RequestOptions)
            ),
            pyrlang_actor:reply({From, Ref}, Response),
            loop(App, Options);
        {From, Ref, {wsgi_request, Method, Target, Headers, Body}} ->
            Response = pyrunicorn_wsgi:call_app(App, Method, Target, Headers, Body, Options),
            pyrlang_actor:reply({From, Ref}, Response),
            loop(App, Options);
        stop ->
            ok;
        _Other ->
            loop(App, Options)
    end.
