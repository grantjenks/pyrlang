-module(pyrlang_postgres).

-export([connect/1, execute/3, close/1, mogrify/2]).

-define(FS, 31).
-define(NULL, 29).

-spec connect(map()) -> pid().
connect(Params) ->
    pyrlang_actor:spawn(fun connection_loop/1, [normalize_params(Params)]).

-spec execute(pid(), binary() | string(), [term()]) -> {[[term()]], integer(), binary()}.
execute(Pid, Sql, Params) ->
    BoundSql = mogrify(Sql, Params),
    case call_connection(Pid, {execute, BoundSql}) of
        {error, Reason} -> raise_dbapi(Reason);
        Result -> Result
    end.

-spec close(pid()) -> ok.
close(Pid) ->
    pyrlang_actor:send(Pid, close).

-spec mogrify(binary() | string(), [term()]) -> binary().
mogrify(Sql, Params) ->
    unicode:characters_to_binary(bind_params(to_list(Sql), Params)).

call_connection(Pid, Request) ->
    try
        pyrlang_actor:call_monitored(Pid, Request, 30000)
    catch
        error:{actor_down, _Pid, Reason} ->
            {error, {dbapi_operational_error, {connection_down, Reason}}};
        error:timeout ->
            {error, {dbapi_operational_error, connection_timeout}}
    end.

connection_loop(Params) ->
    case pyrlang_actor:recv() of
        {From, Ref, {execute, Sql}} ->
            Reply =
                try
                    run_sql(Params, Sql)
                catch
                    error:Reason -> {error, Reason}
                end,
            pyrlang_actor:reply({From, Ref}, Reply),
            connection_loop(Params);
        close ->
            ok;
        _Other ->
            connection_loop(Params)
    end.

normalize_params(Params0) ->
    Params = maps:map(fun(_Key, Value) -> normalize_param(Value) end, Params0),
    DbName = first_present([<<"dbname">>, <<"database">>], Params, <<"postgres">>),
    Params#{<<"dbname">> => DbName}.

normalize_param(none) ->
    none;
normalize_param(undefined) ->
    none;
normalize_param(Value) when is_binary(Value) ->
    Value;
normalize_param(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
normalize_param(Value) when is_integer(Value) ->
    integer_to_binary(Value);
normalize_param(Value) ->
    Value.

first_present([], _Params, Default) ->
    Default;
first_present([Key | Rest], Params, Default) ->
    case maps:get(Key, Params, none) of
        none -> first_present(Rest, Params, Default);
        <<>> -> first_present(Rest, Params, Default);
        Value -> Value
    end.

run_sql(Params, Sql) ->
    trace_sql(Sql),
    case noop_transaction_sql(Sql) of
        true ->
            {[], -1, <<>>};
        false ->
            Psql = find_psql(),
            Args = psql_args(Params, Sql),
            Env = psql_env(Params),
            PortOptions0 = [binary, exit_status, stderr_to_stdout, {args, Args}],
            PortOptions =
                case Env of
                    [] -> PortOptions0;
                    _ -> [{env, Env} | PortOptions0]
                end,
            Port = open_port({spawn_executable, Psql}, PortOptions),
            Output = collect_port(Port, []),
            parse_output(Sql, Output)
    end.

noop_transaction_sql(Sql) ->
    Lower = string:lowercase(string:trim(binary_to_list(Sql))),
    Stripped = strip_trailing_semicolons(Lower),
    lists:any(
        fun(Prefix) -> lists:prefix(Prefix, Stripped) end,
        ["savepoint ", "release savepoint ", "rollback to savepoint "]
    ) orelse
        lists:member(Stripped, ["begin", "commit", "rollback"]).

psql_args(Params, Sql) ->
    Base = [
        "-X",
        "-v",
        "ON_ERROR_STOP=1",
        "-A",
        "-t",
        "-F",
        [31],
        "-P",
        "null=" ++ [29],
        "-d",
        binary_to_list(maps:get(<<"dbname">>, Params, <<"postgres">>))
    ],
    WithUser = option_arg(<<"user">>, "-U", Params, Base),
    WithHost = option_arg(<<"host">>, "-h", Params, WithUser),
    WithPort = option_arg(<<"port">>, "-p", Params, WithHost),
    WithPort ++ ["-c", binary_to_list(Sql)].

option_arg(Key, Flag, Params, Args) ->
    case maps:get(Key, Params, none) of
        none -> Args;
        <<>> -> Args;
        Value -> Args ++ [Flag, binary_to_list(Value)]
    end.

psql_env(Params) ->
    case maps:get(<<"password">>, Params, none) of
        none -> [];
        <<>> -> [];
        Password -> [{"PGPASSWORD", binary_to_list(Password)}]
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            iolist_to_binary(lists:reverse(Acc));
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            trace_sql_error(Status, Output),
            pyrlang_dbapi:operational_error({postgres_exit_status, Status, Output})
    after 30000 ->
        erlang:port_close(Port),
        pyrlang_dbapi:operational_error(postgres_timeout)
    end.

parse_output(Sql, Output) ->
    Lines = [
        Line
     || Line <- binary:split(trim_trailing_newline(Output), <<"\n">>, [global]), Line =/= <<>>
    ],
    {RowLines, RowCount} = split_command_tags(Lines),
    ParseBooleans = parse_boolean_cells(Sql),
    Rows = [parse_row(Line, ParseBooleans) || Line <- RowLines],
    EffectiveRowCount =
        case RowCount of
            undefined when Rows =/= [] -> length(Rows);
            undefined -> -1;
            _ -> RowCount
        end,
    {Rows, EffectiveRowCount, Output}.

split_command_tags(Lines) ->
    split_command_tags(Lines, [], undefined).

split_command_tags([], Rows, RowCount) ->
    {lists:reverse(Rows), RowCount};
split_command_tags([Line | Rest], Rows, _RowCount) ->
    case command_tag_rowcount(Line) of
        {tag, Count} -> split_command_tags(Rest, Rows, Count);
        row -> split_command_tags(Rest, [Line | Rows], undefined)
    end.

command_tag_rowcount(<<"INSERT 0 ", Count/binary>>) ->
    {tag, binary_to_integer(Count)};
command_tag_rowcount(<<"UPDATE ", Count/binary>>) ->
    {tag, binary_to_integer(Count)};
command_tag_rowcount(<<"DELETE ", Count/binary>>) ->
    {tag, binary_to_integer(Count)};
command_tag_rowcount(<<"SELECT ", Count/binary>>) ->
    {tag, binary_to_integer(Count)};
command_tag_rowcount(<<"CREATE ", _Rest/binary>>) ->
    {tag, -1};
command_tag_rowcount(<<"ALTER ", _Rest/binary>>) ->
    {tag, -1};
command_tag_rowcount(<<"DROP ", _Rest/binary>>) ->
    {tag, -1};
command_tag_rowcount(<<"SET", _Rest/binary>>) ->
    {tag, -1};
command_tag_rowcount(<<"BEGIN">>) ->
    {tag, -1};
command_tag_rowcount(<<"COMMIT">>) ->
    {tag, -1};
command_tag_rowcount(<<"ROLLBACK">>) ->
    {tag, -1};
command_tag_rowcount(_Line) ->
    row.

parse_boolean_cells(Sql) ->
    Lower = string:lowercase(binary_to_list(Sql)),
    string:str(Lower, "case") =:= 0 orelse string:str(Lower, "pg_catalog.pg_class") =:= 0.

parse_row(Line, ParseBooleans) ->
    [parse_value(Field, ParseBooleans) || Field <- binary:split(Line, <<?FS>>, [global])].

parse_value(<<?NULL>>, _ParseBooleans) ->
    none;
parse_value(<<"t">>, true) ->
    true;
parse_value(<<"f">>, true) ->
    false;
parse_value(Value, _ParseBooleans) ->
    case parse_integer(Value) of
        {ok, Int} -> Int;
        error -> Value
    end.

parse_integer(Value) ->
    try
        {ok, binary_to_integer(Value)}
    catch
        error:badarg -> error
    end.

bind_params(Sql, []) ->
    Sql;
bind_params(Sql, Params) when is_tuple(Params) ->
    bind_params(Sql, tuple_to_list(Params));
bind_params(Sql, {py_ref, _} = Params) ->
    bind_params(Sql, pyrlang_iter:values(Params));
bind_params(Sql, Params) when is_list(Params) ->
    bind_params_chars(Sql, Params, []).

bind_params_chars([], [], Acc) ->
    lists:reverse(Acc);
bind_params_chars([], [_ | _], _Acc) ->
    pyrlang_dbapi:programming_error(too_many_parameters);
bind_params_chars([$%, $% | Rest], Params, Acc) ->
    bind_params_chars(Rest, Params, [$%, $% | Acc]);
bind_params_chars([$%, $s | Rest], [Param | Params], Acc) ->
    Literal = sql_literal(Param),
    bind_params_chars(Rest, Params, lists:reverse(Literal, Acc));
bind_params_chars([$%, $s | _Rest], [], _Acc) ->
    pyrlang_dbapi:programming_error(not_enough_parameters);
bind_params_chars([Ch | Rest], Params, Acc) ->
    bind_params_chars(Rest, Params, [Ch | Acc]).

sql_literal(Value) when is_integer(Value) ->
    integer_to_list(Value);
sql_literal(Value) when is_float(Value) ->
    float_to_list(Value);
sql_literal(true) ->
    "TRUE";
sql_literal(false) ->
    "FALSE";
sql_literal(none) ->
    "NULL";
sql_literal(undefined) ->
    "NULL";
sql_literal(Value) when is_binary(Value) ->
    quote_sql(binary_to_list(Value));
sql_literal(Value) when is_list(Value) ->
    quote_sql(Value);
sql_literal({py_ref, _} = Ref) ->
    case safe_heap_type(Ref) of
        list ->
            postgres_array_literal(pyrlang_heap:list_items(Ref));
        _ ->
            quote_sql(binary_to_list(object_text(Ref)))
    end;
sql_literal(Value) ->
    quote_sql(io_lib:format("~p", [Value])).

postgres_array_literal(Items) ->
    "ARRAY[" ++ join_sql_literals(Items) ++ "]".

join_sql_literals([]) ->
    "";
join_sql_literals([Item]) ->
    sql_literal(Item);
join_sql_literals([Item | Rest]) ->
    sql_literal(Item) ++ "," ++ join_sql_literals(Rest).

safe_heap_type({py_ref, _} = Ref) ->
    try
        pyrlang_heap:type(Ref)
    catch
        _:_ -> undefined
    end.

object_text(Ref) ->
    try pyrlang_object:get_attr(Ref, <<"isoformat">>) of
        Isoformat ->
            normalize_text(pyrlang_eval:call(Isoformat, []))
    catch
        _:_ ->
            try pyrlang_object:get_attr(Ref, <<"__str__">>) of
                Str -> normalize_text(pyrlang_eval:call(Str, []))
            catch
                _:_ ->
                    try pyrlang_object:get_attr(Ref, <<"value">>) of
                        Value -> normalize_text(Value)
                    catch
                        _:_ -> unicode:characters_to_binary(io_lib:format("~p", [Ref]))
                    end
            end
    end.

normalize_text(Value) when is_binary(Value) ->
    Value;
normalize_text(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
normalize_text(Value) when is_integer(Value) ->
    integer_to_binary(Value);
normalize_text(Value) when is_float(Value) ->
    float_to_binary(Value);
normalize_text(true) ->
    <<"True">>;
normalize_text(false) ->
    <<"False">>;
normalize_text(none) ->
    <<"None">>;
normalize_text(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

quote_sql(Value) ->
    [$' | escape_sql(Value)] ++ [$'].

escape_sql([]) ->
    [];
escape_sql([$' | Rest]) ->
    [$', $' | escape_sql(Rest)];
escape_sql([$\\ | Rest]) ->
    [$\\, $\\ | escape_sql(Rest)];
escape_sql([Ch | Rest]) ->
    [Ch | escape_sql(Rest)].

trim_trailing_newline(<<>>) ->
    <<>>;
trim_trailing_newline(Binary) ->
    case binary:last(Binary) of
        $\n -> trim_trailing_newline(binary:part(Binary, 0, byte_size(Binary) - 1));
        $\r -> trim_trailing_newline(binary:part(Binary, 0, byte_size(Binary) - 1));
        _ -> Binary
    end.

strip_trailing_semicolons([]) ->
    [];
strip_trailing_semicolons(Sql) ->
    lists:reverse(drop_trailing_semicolons(lists:reverse(Sql))).

drop_trailing_semicolons([$; | Rest]) ->
    drop_trailing_semicolons(Rest);
drop_trailing_semicolons(Rest) ->
    Rest.

find_psql() ->
    case os:find_executable("psql") of
        false ->
            case
                filelib:is_regular("/Applications/Postgres.app/Contents/Versions/latest/bin/psql")
            of
                true -> "/Applications/Postgres.app/Contents/Versions/latest/bin/psql";
                false -> pyrlang_dbapi:operational_error(psql_not_found)
            end;
        Path ->
            Path
    end.

raise_dbapi({dbapi_operational_error, Reason}) ->
    pyrlang_dbapi:operational_error(Reason);
raise_dbapi({dbapi_programming_error, Reason}) ->
    pyrlang_dbapi:programming_error(Reason);
raise_dbapi({dbapi_error, Reason}) ->
    pyrlang_dbapi:error(Reason);
raise_dbapi(Reason) ->
    erlang:error(Reason).

to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_list(Value) when is_list(Value) ->
    Value.

trace_sql(Sql) ->
    case os:getenv("PYRLANG_TRACE_POSTGRES") of
        false -> ok;
        _ -> io:format(standard_error, "PYRLANG_POSTGRES_SQL ~s~n", [Sql])
    end.

trace_sql_error(Status, Output) ->
    case os:getenv("PYRLANG_TRACE_POSTGRES") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_POSTGRES_ERROR status=~p output=~p~n", [
                Status, Output
            ])
    end.
