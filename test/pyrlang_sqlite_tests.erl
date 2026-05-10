-module(pyrlang_sqlite_tests).

-include_lib("eunit/include/eunit.hrl").

actor_backed_sqlite_execute_and_query_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Conn = pyrlang_sqlite:connect(Path),
    ok = pyrlang_sqlite:execute(Conn, "create table todo(id integer primary key, title text)"),
    ok = pyrlang_sqlite:execute(Conn, "insert into todo(title) values (?)", [<<"write tests">>]),
    ok = pyrlang_sqlite:execute(Conn, "insert into todo(title) values (?)", [<<"has, comma">>]),
    ?assertEqual(
        [[1, <<"write tests">>], [2, <<"has, comma">>]],
        pyrlang_sqlite:query(Conn, "select id, title from todo")
    ),
    ok = pyrlang_sqlite:close(Conn),
    file:delete(Path).

actor_backed_sqlite_preserves_null_distinct_from_empty_text_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Conn = pyrlang_sqlite:connect(Path),
    ok = pyrlang_sqlite:execute(Conn, "create table values_table(empty_text text, null_text text)"),
    ok = pyrlang_sqlite:execute(
        Conn, "insert into values_table(empty_text, null_text) values (?, ?)", [<<"">>, none]
    ),
    ?assertEqual(
        [[<<>>, none]], pyrlang_sqlite:query(Conn, "select empty_text, null_text from values_table")
    ),
    ok = pyrlang_sqlite:close(Conn),
    file:delete(Path).

actor_backed_sqlite_errors_do_not_kill_connection_actor_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Conn = pyrlang_sqlite:connect(Path),
    ?assertError(
        {dbapi_programming_error, too_many_parameters},
        pyrlang_sqlite:query(Conn, "select ?", [1, 2])
    ),
    ?assertEqual([[7]], pyrlang_sqlite:query(Conn, "select 7")),
    ok = pyrlang_sqlite:close(Conn),
    file:delete(Path).

actor_backed_sqlite_transactions_are_scoped_to_connection_actor_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Conn1 = pyrlang_sqlite:connect(Path),
    Conn2 = pyrlang_sqlite:connect(Path),
    ok = pyrlang_sqlite:execute(Conn1, "create table todo(id integer primary key, title text)"),
    ok = pyrlang_sqlite:execute(Conn1, "begin"),
    ok = pyrlang_sqlite:execute(Conn1, "insert into todo(title) values (?)", [<<"draft">>]),
    ?assertEqual([[1]], pyrlang_sqlite:query(Conn1, "select count(*) from todo")),
    ?assertEqual([[0]], pyrlang_sqlite:query(Conn2, "select count(*) from todo")),
    ok = pyrlang_sqlite:execute(Conn1, "commit"),
    ?assertEqual([[1]], pyrlang_sqlite:query(Conn2, "select count(*) from todo")),
    ok = pyrlang_sqlite:close(Conn1),
    ok = pyrlang_sqlite:close(Conn2),
    file:delete(Path).

actor_backed_sqlite_connection_crash_maps_to_operational_error_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Conn = pyrlang_sqlite:connect(Path),
    erlang:exit(Conn, kill),
    ?assertError(
        {dbapi_operational_error, {connection_down, _Reason}},
        pyrlang_sqlite:query(Conn, "select 1")
    ),
    file:delete(Path).

dbapi_module_globals_test() ->
    ?assertEqual(<<"2.0">>, pyrlang_dbapi:apilevel()),
    ?assertEqual(1, pyrlang_dbapi:threadsafety()),
    ?assertEqual(qmark, pyrlang_dbapi:paramstyle()).

sqlite3_builtin_module_exposes_actor_safe_dbapi_objects_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "conn = sqlite3.connect('",
        Path,
        "')\n",
        "conn.execute('create table todo(id integer primary key, title text, done_at text)')\n",
        "conn.execute('insert into todo(title, done_at) values (?, ?)', ['write dbapi', None])\n",
        "cursor = conn.execute('select id, title, done_at from todo')\n",
        "rows = cursor.fetchall()\n",
        "conn.close()\n",
        "sqlite3.apilevel + ':' + sqlite3.paramstyle + ':' + str(rows[0][0]) + ':' + rows[0][1] + ':' + str(rows[0][2] is None)\n"
    ]),
    ?assertMatch({ok, <<"2.0:qmark:1:write dbapi:True">>, _Env}, pyrlang:run_string(Source)),
    file:delete(Path).

sqlite3_builtin_insert_returning_populates_cursor_rows_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "conn = sqlite3.connect('",
        Path,
        "')\n",
        "conn.execute('create table todo(id integer primary key, title text)')\n",
        "row = conn.execute('insert into todo(title) values (?) returning id', ['write dbapi']).fetchone()\n",
        "conn.close()\n",
        "str(row[0]) + ':' + str(isinstance(row, tuple))\n"
    ]),
    ?assertMatch({ok, <<"1:True">>, _Env}, pyrlang:run_string(Source)),
    file:delete(Path).

sqlite3_builtin_insert_returning_inside_transaction_commits_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "conn1 = sqlite3.connect('",
        Path,
        "')\n",
        "conn2 = sqlite3.connect('",
        Path,
        "')\n",
        "conn1.execute('create table todo(id integer primary key, title text)')\n",
        "conn1.execute('begin')\n",
        "row = conn1.execute('insert into todo(title) values (?) returning id', ['draft']).fetchone()\n",
        "inside = conn1.execute('select count(*) from todo').fetchone()[0]\n",
        "inside_title = conn1.execute('select title from todo').fetchone()[0]\n",
        "outside_before = conn2.execute('select count(*) from todo').fetchone()[0]\n",
        "conn1.commit()\n",
        "outside_after = conn2.execute('select count(*) from todo').fetchone()[0]\n",
        "conn1.close()\n",
        "conn2.close()\n",
        "str(row[0]) + ':' + str(inside) + ':' + inside_title + ':' + str(outside_before) + ':' + str(outside_after)\n"
    ]),
    ?assertMatch({ok, <<"1:1:draft:0:1">>, _Env}, pyrlang:run_string(Source)),
    file:delete(Path).

sqlite3_builtin_cursor_fetchmany_consumes_rows_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "conn = sqlite3.connect('",
        Path,
        "')\n",
        "conn.execute('create table todo(id integer primary key, title text)')\n",
        "conn.execute('insert into todo(title) values (?)', ['a'])\n",
        "conn.execute('insert into todo(title) values (?)', ['b'])\n",
        "cursor = conn.execute('select id, title from todo order by id')\n",
        "first = cursor.fetchmany(1)\n",
        "second = cursor.fetchmany()\n",
        "empty = cursor.fetchmany()\n",
        "conn.close()\n",
        "str(first[0][0]) + ':' + second[0][1] + ':' + str(len(empty))\n"
    ]),
    ?assertMatch({ok, <<"1:b:0">>, _Env}, pyrlang:run_string(Source)),
    file:delete(Path).

sqlite3_builtin_cursor_rowcount_tracks_dml_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "conn = sqlite3.connect('",
        Path,
        "')\n",
        "conn.execute('create table todo(id integer primary key, done integer)')\n",
        "inserted = conn.execute('insert into todo(done) values (?)', [0]).rowcount\n",
        "updated = conn.execute('update todo set done = ? where id = ?', [1, 1]).rowcount\n",
        "missing = conn.execute('update todo set done = ? where id = ?', [1, 99]).rowcount\n",
        "selected = conn.execute('select id from todo').rowcount\n",
        "conn.close()\n",
        "str(inserted) + ':' + str(updated) + ':' + str(missing) + ':' + str(selected)\n"
    ]),
    ?assertMatch({ok, <<"1:1:0:-1">>, _Env}, pyrlang:run_string(Source)),
    file:delete(Path).

sqlite3_builtin_connection_commit_scopes_actor_transaction_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "conn1 = sqlite3.connect('",
        Path,
        "')\n",
        "conn2 = sqlite3.connect('",
        Path,
        "')\n",
        "conn1.execute('create table todo(id integer primary key, title text)')\n",
        "conn1.execute('begin')\n",
        "conn1.execute('insert into todo(title) values (?)', ['draft'])\n",
        "inside = conn1.execute('select count(*) from todo').fetchall()[0][0]\n",
        "outside_before = conn2.execute('select count(*) from todo').fetchall()[0][0]\n",
        "conn1.commit()\n",
        "outside_after = conn2.execute('select count(*) from todo').fetchall()[0][0]\n",
        "conn1.close()\n",
        "conn2.close()\n",
        "str(inside) + ':' + str(outside_before) + ':' + str(outside_after)\n"
    ]),
    ?assertMatch({ok, <<"1:0:1">>, _Env}, pyrlang:run_string(Source)),
    file:delete(Path).

sqlite3_builtin_connections_are_actor_local_resources_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "from erlang import self, send\n",
        "conn = sqlite3.connect('",
        Path,
        "')\n",
        "try:\n",
        "    send(self(), conn)\n",
        "    result = 'sent'\n",
        "except TypeError:\n",
        "    result = 'unsendable'\n",
        "conn.close()\n",
        "result\n"
    ]),
    ?assertMatch({ok, <<"unsendable">>, _Env}, pyrlang:run_string(Source)),
    file:delete(Path).

sqlite3_builtin_module_maps_dbapi_errors_to_pyrlang_exceptions_test() ->
    pyrlang_heap:init(),
    Path = temp_db_path(),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "conn = sqlite3.connect('",
        Path,
        "')\n",
        "try:\n",
        "    conn.execute('select ?', [1, 2])\n",
        "except sqlite3.ProgrammingError:\n",
        "    result = 'mapped'\n",
        "conn.close()\n",
        "result\n"
    ]),
    ?assertMatch({ok, <<"mapped">>, _Env}, pyrlang:run_string(Source)),
    file:delete(Path).

temp_db_path() ->
    filename:join(
        "/tmp",
        lists:flatten(
            io_lib:format("pyrlang_sqlite_~p_~p.db", [
                erlang:unique_integer([positive]), erlang:system_time(millisecond)
            ])
        )
    ).
