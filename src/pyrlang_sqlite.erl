-module(pyrlang_sqlite).

-export([
    connect/1,
    execute/2, execute/3,
    execute_rowcount/2, execute_rowcount/3,
    query/2, query/3,
    close/1
]).

-define(SQLITE_NULL_VALUE, <<"__PYL_NULL__">>).

-spec connect(binary() | string()) -> pid().
connect(Path) ->
    pyrlang_actor:spawn(fun connection_loop/1, [to_list(Path)]).

-spec execute(pid(), binary() | string()) -> ok.
execute(Pid, Sql) ->
    execute(Pid, Sql, []).

-spec execute(pid(), binary() | string(), [term()]) -> ok.
execute(Pid, Sql, Params) ->
    case call_connection(Pid, {execute, to_list(Sql), Params}) of
        ok -> ok;
        {ok, _RowCount} -> ok;
        {error, Reason} -> raise_dbapi(Reason)
    end.

-spec execute_rowcount(pid(), binary() | string()) -> integer().
execute_rowcount(Pid, Sql) ->
    execute_rowcount(Pid, Sql, []).

-spec execute_rowcount(pid(), binary() | string(), [term()]) -> integer().
execute_rowcount(Pid, Sql, Params) ->
    case call_connection(Pid, {execute, to_list(Sql), Params}) of
        ok -> -1;
        {ok, RowCount} -> RowCount;
        {error, Reason} -> raise_dbapi(Reason)
    end.

-spec query(pid(), binary() | string()) -> [[binary()]].
query(Pid, Sql) ->
    query(Pid, Sql, []).

-spec query(pid(), binary() | string(), [term()]) -> [[binary()]].
query(Pid, Sql, Params) ->
    case call_connection(Pid, {query, to_list(Sql), Params}) of
        {error, Reason} -> raise_dbapi(Reason);
        Rows -> Rows
    end.

-spec close(pid()) -> ok.
close(Pid) ->
    pyrlang_actor:send(Pid, close).

call_connection(Pid, Request) ->
    try
        pyrlang_actor:call_monitored(Pid, Request, 10000)
    catch
        error:{actor_down, _Pid, Reason} ->
            {error, {dbapi_operational_error, {connection_down, Reason}}};
        error:timeout ->
            {error, {dbapi_operational_error, connection_timeout}}
    end.

connection_loop(Path) ->
    connection_loop(Path, #{transaction => false, pending => [], ddl_immediate => false}).

connection_loop(Path, State) ->
    case pyrlang_actor:recv() of
        {From, Ref, {execute, Sql, Params}} ->
            {Reply, NextState} =
                try
                    execute_sql(Path, bind_params(Sql, Params), State)
                catch
                    error:Reason -> {{error, Reason}, State}
                end,
            pyrlang_actor:reply({From, Ref}, Reply),
            connection_loop(Path, NextState);
        {From, Ref, {query, Sql, Params}} ->
            {Reply, NextState} =
                try
                    {Output, QueryState} = query_sql(Path, bind_params(Sql, Params), State),
                    {parse_csv(Output), QueryState}
                catch
                    error:Reason -> {{error, Reason}, State}
                end,
            pyrlang_actor:reply({From, Ref}, Reply),
            connection_loop(Path, NextState);
        close ->
            ok;
        _Other ->
            connection_loop(Path, State)
    end.

execute_sql(Path, Sql, State = #{transaction := false}) ->
    case transaction_command(Sql) of
        begin_tx ->
            {{ok, -1}, State#{transaction := true, pending := []}};
        commit_tx ->
            {{ok, -1}, State};
        rollback_tx ->
            {{ok, -1}, State};
        normal ->
            RowCount = run_execute_sql(Path, Sql),
            {{ok, RowCount}, State}
    end;
execute_sql(Path, Sql, State = #{transaction := true, pending := Pending}) ->
    case transaction_command(Sql) of
        begin_tx ->
            pyrlang_dbapi:programming_error(transaction_already_active);
        commit_tx ->
            _ = run_sql(Path, transaction_sql(Pending ++ [commit_tx])),
            {{ok, -1}, State#{transaction := false, pending := [], ddl_immediate := false}};
        rollback_tx ->
            {{ok, -1}, State#{transaction := false, pending := [], ddl_immediate := false}};
        normal ->
            case maps:get(ddl_immediate, State, false) orelse ddl_statement(Sql) of
                true ->
                    RowCount = run_execute_sql(Path, Sql),
                    {{ok, RowCount}, State#{ddl_immediate := true}};
                false ->
                    NextPending = Pending ++ [pending_statement(Sql)],
                    RowCount = run_transaction_check(Path, Pending, Sql),
                    {{ok, RowCount}, State#{pending := NextPending}}
            end
    end.

run_execute_sql(Path, Sql) ->
    case dml_statement(Sql) of
        true ->
            parse_changes_output(run_sql(Path, changes_sql(Sql)));
        false ->
            _ = run_sql(Path, Sql),
            -1
    end.

run_transaction_check(Path, Pending, Sql) ->
    case dml_statement(Sql) of
        true ->
            parse_changes_output(
                run_sql(Path, transaction_sql(Pending ++ [Sql, "SELECT changes()", rollback_tx]))
            );
        false ->
            _ = run_sql(Path, transaction_sql(Pending ++ [Sql, rollback_tx])),
            -1
    end.

query_sql(Path, Sql, State = #{transaction := false}) ->
    {run_sql(Path, Sql), State};
query_sql(Path, Sql, #{transaction := true, pending := Pending} = State) ->
    case maps:get(ddl_immediate, State, false) of
        true ->
            {run_sql(Path, Sql), State};
        false ->
            Output = run_sql(Path, transaction_sql(Pending ++ [Sql, rollback_tx])),
            NextState =
                case dml_statement(Sql) of
                    true -> State#{pending := Pending ++ [pending_statement(Sql)]};
                    false -> State
                end,
            {Output, NextState}
    end.

transaction_sql(Statements) ->
    string:join(["BEGIN" | [transaction_statement(Statement) || Statement <- Statements]], ";\n").

transaction_statement(commit_tx) ->
    "COMMIT";
transaction_statement(rollback_tx) ->
    "ROLLBACK";
transaction_statement(Sql) ->
    strip_trailing_semicolons(string:trim(Sql)).

pending_statement(Sql) ->
    case string:str(string:lowercase(Sql), " returning ") of
        0 -> Sql;
        Pos -> string:trim(string:substr(Sql, 1, Pos - 1))
    end.

changes_sql(Sql) ->
    strip_trailing_semicolons(string:trim(Sql)) ++ ";\nSELECT changes()".

transaction_command(Sql) ->
    case string:lowercase(strip_trailing_semicolons(string:trim(Sql))) of
        "begin" -> begin_tx;
        "begin transaction" -> begin_tx;
        "commit" -> commit_tx;
        "rollback" -> rollback_tx;
        _Other -> normal
    end.

ddl_statement(Sql) ->
    Lower = string:lowercase(string:trim(Sql)),
    lists:any(
        fun(Prefix) -> lists:prefix(Prefix, Lower) end,
        ["create ", "alter ", "drop "]
    ).

dml_statement(Sql) ->
    Lower = string:lowercase(string:trim(Sql)),
    lists:any(
        fun(Prefix) -> lists:prefix(Prefix, Lower) end,
        ["insert ", "update ", "delete ", "replace "]
    ).

parse_changes_output(Output) ->
    case parse_csv(Output) of
        [[Count]] when is_integer(Count) -> Count;
        [[CountBinary]] when is_binary(CountBinary) -> binary_to_integer(CountBinary);
        Rows -> pyrlang_dbapi:error({bad_changes_output, Rows})
    end.

raise_dbapi({dbapi_operational_error, Reason}) ->
    pyrlang_dbapi:operational_error(Reason);
raise_dbapi({dbapi_programming_error, Reason}) ->
    pyrlang_dbapi:programming_error(Reason);
raise_dbapi({dbapi_error, Reason}) ->
    pyrlang_dbapi:error(Reason);
raise_dbapi(Reason) ->
    erlang:error(Reason).

run_sql(Path, Sql) ->
    trace_sql(Sql),
    Sqlite = find_sqlite(),
    Port = open_port({spawn_executable, Sqlite}, [
        binary,
        exit_status,
        stderr_to_stdout,
        {args, ["-batch", "-csv", "-nullvalue", binary_to_list(?SQLITE_NULL_VALUE), Path, Sql]}
    ]),
    collect_port(Port, []).

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            iolist_to_binary(lists:reverse(Acc));
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            trace_sql_error(Status, Output),
            pyrlang_dbapi:operational_error({sqlite_exit_status, Status, Output})
    after 10000 ->
        erlang:port_close(Port),
        pyrlang_dbapi:operational_error(sqlite_timeout)
    end.

find_sqlite() ->
    case os:find_executable("sqlite3") of
        false -> pyrlang_dbapi:operational_error(sqlite3_not_found);
        Path -> Path
    end.

bind_params(Sql, []) ->
    Sql;
bind_params(Sql, Params) ->
    bind_params(Sql, Params, []).

bind_params([], [], Acc) ->
    lists:reverse(Acc);
bind_params([], [_ | _], _Acc) ->
    pyrlang_dbapi:programming_error(too_many_parameters);
bind_params([$? | Rest], [Param | Params], Acc) ->
    Literal = sql_literal(Param),
    bind_params(Rest, Params, lists:reverse(Literal, Acc));
bind_params([$? | _Rest], [], _Acc) ->
    pyrlang_dbapi:programming_error(not_enough_parameters);
bind_params([Ch | Rest], Params, Acc) ->
    bind_params(Rest, Params, [Ch | Acc]).

sql_literal(Value) when is_integer(Value) ->
    integer_to_list(Value);
sql_literal(Value) when is_float(Value) ->
    float_to_list(Value);
sql_literal(Value) when is_binary(Value) ->
    quote_sql(binary_to_list(Value));
sql_literal(Value) when is_list(Value) ->
    quote_sql(Value);
sql_literal(true) ->
    "1";
sql_literal(false) ->
    "0";
sql_literal(none) ->
    "NULL";
sql_literal(undefined) ->
    "NULL".

quote_sql(Value) ->
    [$' | escape_sql(Value)] ++ [$'].

strip_trailing_semicolons([]) ->
    [];
strip_trailing_semicolons(Sql) ->
    lists:reverse(drop_trailing_semicolons(lists:reverse(Sql))).

drop_trailing_semicolons([$; | Rest]) ->
    drop_trailing_semicolons(Rest);
drop_trailing_semicolons(Rest) ->
    Rest.

escape_sql([]) ->
    [];
escape_sql([$' | Rest]) ->
    [$', $' | escape_sql(Rest)];
escape_sql([Ch | Rest]) ->
    [Ch | escape_sql(Rest)].

parse_csv(Output) ->
    Lines = [
        Line
     || Line <- binary:split(trim_trailing_newline(Output), <<"\n">>, [global]), Line =/= <<>>
    ],
    [parse_csv_line(Line) || Line <- Lines].

parse_csv_line(Line) ->
    [parse_csv_value(Field) || Field <- parse_csv_fields(Line)].

parse_csv_fields(Line) ->
    parse_csv_fields(Line, [], [], unquoted).

parse_csv_fields(<<>>, FieldAcc, Fields, _Mode) ->
    lists:reverse([csv_field(FieldAcc) | Fields]);
parse_csv_fields(<<$", Rest/binary>>, [], Fields, unquoted) ->
    parse_csv_fields(Rest, [], Fields, quoted);
parse_csv_fields(<<$,, Rest/binary>>, FieldAcc, Fields, unquoted) ->
    parse_csv_fields(Rest, [], [csv_field(FieldAcc) | Fields], unquoted);
parse_csv_fields(<<Char/utf8, Rest/binary>>, FieldAcc, Fields, unquoted) ->
    parse_csv_fields(Rest, [Char | FieldAcc], Fields, unquoted);
parse_csv_fields(<<$", $", Rest/binary>>, FieldAcc, Fields, quoted) ->
    parse_csv_fields(Rest, [$" | FieldAcc], Fields, quoted);
parse_csv_fields(<<$", Rest/binary>>, FieldAcc, Fields, quoted) ->
    parse_csv_fields(Rest, FieldAcc, Fields, after_quote);
parse_csv_fields(<<Char/utf8, Rest/binary>>, FieldAcc, Fields, quoted) ->
    parse_csv_fields(Rest, [Char | FieldAcc], Fields, quoted);
parse_csv_fields(<<$,, Rest/binary>>, FieldAcc, Fields, after_quote) ->
    parse_csv_fields(Rest, [], [csv_field(FieldAcc) | Fields], unquoted);
parse_csv_fields(<<Char/utf8, Rest/binary>>, FieldAcc, Fields, after_quote) ->
    parse_csv_fields(Rest, [Char | FieldAcc], Fields, after_quote).

csv_field(Chars) ->
    unicode:characters_to_binary(lists:reverse(Chars)).

parse_csv_value(Field) ->
    case Field of
        ?SQLITE_NULL_VALUE ->
            none;
        _ ->
            case parse_integer(Field) of
                {ok, Integer} ->
                    Integer;
                error ->
                    case parse_float(Field) of
                        {ok, Float} -> Float;
                        error -> Field
                    end
            end
    end.

parse_integer(<<>>) ->
    error;
parse_integer(Field) ->
    try binary_to_integer(Field) of
        Integer -> {ok, Integer}
    catch
        error:badarg -> error
    end.

parse_float(<<>>) ->
    error;
parse_float(Field) ->
    try binary_to_float(Field) of
        Float -> {ok, Float}
    catch
        error:badarg -> error
    end.

trim_trailing_newline(<<>>) ->
    <<>>;
trim_trailing_newline(Output) ->
    case binary:last(Output) of
        $\n -> binary:part(Output, 0, byte_size(Output) - 1);
        _ -> Output
    end.

to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_list(Value) when is_list(Value) ->
    Value.

trace_sql(Sql) ->
    case os:getenv("PYRLANG_TRACE_SQLITE") of
        false -> ok;
        _ -> io:format(standard_error, "PYRLANG_SQLITE ~s~n", [Sql])
    end.

trace_sql_error(Status, Output) ->
    case os:getenv("PYRLANG_TRACE_SQLITE") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_SQLITE_ERROR status=~p output=~p~n", [Status, Output])
    end.
