-module(pyrunicorn_cli).

-export([main/1, start_from_args/1, parse_args/1]).

-spec main([string()]) -> no_return().
main(Args) ->
    case start_from_args(Args) of
        {ok, _Server, Port, _Config} ->
            io:format("pyrunicorn listening on port ~B~n", [Port]),
            wait_forever();
        {error, Reason} ->
            io:format(standard_error, "pyrunicorn: ~s~n", [format_value(Reason)]),
            halt(1)
    end.

-spec start_from_args([string() | binary()]) ->
    {ok, pid(), inet:port_number(), map()} | {error, term()}.
start_from_args(Args) ->
    case parse_args(Args) of
        {ok, #{app := App, path := ExtraPath, options := Options} = Config} ->
            ok = pyrlang:set_path(ExtraPath ++ pyrlang_module:path()),
            case pyrunicorn_server:start(App, Options) of
                {ok, Server, Port} -> {ok, Server, Port, Config};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec parse_args([string() | binary()]) -> {ok, map()} | {error, term()}.
parse_args(Args) ->
    Defaults = #{
        path => [],
        options => #{
            ip => {127, 0, 0, 1},
            port => 8000,
            workers => 1,
            os_environ => #{}
        }
    },
    parse_args([to_list(Arg) || Arg <- Args], Defaults, undefined).

parse_args([], _Config, undefined) ->
    {error, usage};
parse_args([], Config, App) ->
    {ok, Config#{app => unicode:characters_to_binary(App)}};
parse_args(["--bind", Bind | Rest], Config, App) ->
    case parse_bind(Bind) of
        {ok, Ip, Port} -> parse_args(Rest, put_option(port, Port, put_option(ip, Ip, Config)), App);
        {error, Reason} -> {error, Reason}
    end;
parse_args(["--workers", Count | Rest], Config, App) ->
    parse_worker_count(Count, Rest, Config, App);
parse_args(["--django-settings-module", Module | Rest], Config, App) ->
    parse_args(
        Rest,
        put_env(<<"DJANGO_SETTINGS_MODULE">>, unicode:characters_to_binary(Module), Config),
        App
    );
parse_args(["-I", Path | Rest], Config, App) ->
    parse_args(Rest, add_path(Path, Config), App);
parse_args(["--path", Path | Rest], Config, App) ->
    parse_args(Rest, add_path(Path, Config), App);
parse_args([Arg | Rest], Config, App) ->
    case parse_long_option(Arg, Config) of
        {ok, UpdatedConfig} ->
            parse_args(Rest, UpdatedConfig, App);
        {error, Reason} ->
            {error, Reason};
        error ->
            case {is_option(Arg), App} of
                {true, _} -> {error, {unknown_option, Arg}};
                {false, undefined} -> parse_args(Rest, Config, Arg);
                {false, _} -> {error, {multiple_apps, App, Arg}}
            end
    end.

parse_long_option(Arg, Config) ->
    case split_option(Arg, "--bind=") of
        {ok, Bind} ->
            case parse_bind(Bind) of
                {ok, Ip, Port} -> {ok, put_option(port, Port, put_option(ip, Ip, Config))};
                {error, _Reason} = Error -> Error
            end;
        error ->
            parse_non_bind_long_option(Arg, Config)
    end.

parse_non_bind_long_option(Arg, Config) ->
    case split_option(Arg, "--workers=") of
        {ok, Count} ->
            case parse_positive_integer(Count) of
                {ok, Workers} -> {ok, put_option(workers, Workers, Config)};
                error -> {error, {bad_workers, Count}}
            end;
        error ->
            parse_path_or_env_option(Arg, Config)
    end.

parse_path_or_env_option(Arg, Config) ->
    case split_option(Arg, "--django-settings-module=") of
        {ok, Module} ->
            {ok,
                put_env(<<"DJANGO_SETTINGS_MODULE">>, unicode:characters_to_binary(Module), Config)};
        error ->
            case split_option(Arg, "--path=") of
                {ok, Path} -> {ok, add_path(Path, Config)};
                error -> error
            end
    end.

parse_worker_count(Count, Rest, Config, App) ->
    case parse_positive_integer(Count) of
        {ok, Workers} -> parse_args(Rest, put_option(workers, Workers, Config), App);
        error -> {error, {bad_workers, Count}}
    end.

parse_bind(Bind) ->
    case string:split(Bind, ":", trailing) of
        [Host, PortText] ->
            case {parse_ip(Host), parse_port(PortText)} of
                {{ok, Ip}, {ok, Port}} -> {ok, Ip, Port};
                {error, _} -> {error, {bad_bind_host, Host}};
                {_, error} -> {error, {bad_bind_port, PortText}}
            end;
        _ ->
            {error, {bad_bind, Bind}}
    end.

parse_ip("localhost") ->
    {ok, {127, 0, 0, 1}};
parse_ip(Host) ->
    case inet:parse_address(Host) of
        {ok, Ip} -> {ok, Ip};
        {error, _Reason} -> error
    end.

parse_port(Text) ->
    case parse_nonnegative_integer(Text) of
        {ok, Port} when Port =< 65535 -> {ok, Port};
        _ -> error
    end.

parse_positive_integer(Text) ->
    case parse_nonnegative_integer(Text) of
        {ok, Value} when Value > 0 -> {ok, Value};
        _ -> error
    end.

parse_nonnegative_integer(Text) ->
    try
        Value = list_to_integer(Text),
        case Value >= 0 of
            true -> {ok, Value};
            false -> error
        end
    catch
        error:badarg -> error
    end.

put_option(Key, Value, Config) ->
    Options = maps:get(options, Config),
    Config#{options := Options#{Key => Value}}.

put_env(Key, Value, Config) ->
    Options = maps:get(options, Config),
    Env = maps:get(os_environ, Options, #{}),
    Config#{options := Options#{os_environ := Env#{Key => Value}}}.

add_path(Path, Config) ->
    Config#{path := maps:get(path, Config, []) ++ [Path]}.

split_option(Arg, Prefix) ->
    case lists:prefix(Prefix, Arg) of
        true -> {ok, lists:nthtail(length(Prefix), Arg)};
        false -> error
    end.

is_option([$- | _]) ->
    true;
is_option(_Arg) ->
    false.

wait_forever() ->
    receive
        stop -> halt(0)
    end.

format_value(Value) when is_binary(Value) ->
    Value;
format_value(Value) when is_integer(Value) ->
    integer_to_binary(Value);
format_value(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
format_value(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_list(Value) when is_list(Value) ->
    Value.
