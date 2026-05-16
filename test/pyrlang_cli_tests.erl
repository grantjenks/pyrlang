-module(pyrlang_cli_tests).

-include_lib("eunit/include/eunit.hrl").

pyrlang_cli_runs_source_file_without_cpython_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir("pyrlang_cli"),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "main.pyr"),
    ok = file:write_file(Path, <<"value = 41\nvalue + 1\n">>),
    ?assertEqual({ok, 42}, pyrlang_cli:run(["--path", Dir, Path])),
    cleanup_tree(Dir).

pyrlang_cli_runs_source_file_with_script_args_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir("pyrlang_cli_args"),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "main.py"),
    ok = file:write_file(Path, <<
        "import sys\n",
        "if __name__ == \"__main__\":\n",
        "    str(sys.argv[0].endswith('main.py')) + ':' + sys.argv[1] + ':' + sys.argv[2]\n"
    >>),
    ?assertEqual(
        {ok, <<"True:migrate:--noinput">>},
        pyrlang_cli:run(["--path", Dir, Path, "migrate", "--noinput"])
    ),
    cleanup_tree(Dir).

pyrlang_cli_runs_command_string_with_command_args_test() ->
    pyrlang_heap:init(),
    ?assertEqual(
        {ok, <<"-c:first:second">>},
        pyrlang_cli:run([
            "-c",
            "import sys\nsys.argv[0] + ':' + sys.argv[1] + ':' + sys.argv[2]\n",
            "first",
            "second"
        ])
    ).

pyrlang_cli_runs_command_string_with_extra_import_path_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir("pyrlang_cli_command_path"),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "helper.py"), <<"value = 42\n">>),
    ?assertEqual(
        {ok, 42},
        pyrlang_cli:run(["--path", Dir, "-c", "import helper\nhelper.value\n"])
    ),
    cleanup_tree(Dir).

pyrlang_cli_runs_module_main_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir("pyrlang_cli_module"),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "tool.py"),
    ok = file:write_file(Path, <<
        "import sys\n",
        "if __name__ == \"__main__\":\n",
        "    sys.argv[1] + ':' + sys.argv[2]\n"
    >>),
    ?assertEqual(
        {ok, <<"startproject:testproj">>},
        pyrlang_cli:run(["--path", Dir, "-m", "tool", "startproject", "testproj"])
    ),
    cleanup_tree(Dir).

pyrlang_cli_runs_package_dunder_main_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir("pyrlang_cli_package"),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "django"),
    CoreDir = filename:join(PackageDir, "core"),
    ok = file:make_dir(PackageDir),
    ok = file:make_dir(CoreDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<"">>),
    ok = file:write_file(filename:join(PackageDir, "__main__.py"), <<
        "\"\"\"\n",
        "Invokes django-admin when the django module is run as a script.\n",
        "\"\"\"\n",
        "from django.core import management\n",
        "if __name__ == \"__main__\":\n",
        "    management.execute_from_command_line()\n"
    >>),
    ok = file:write_file(filename:join(CoreDir, "__init__.py"), <<"">>),
    ok = file:write_file(filename:join(CoreDir, "management.py"), <<
        "import sys\n",
        "def execute_from_command_line():\n",
        "    return sys.argv[1] + ':' + sys.argv[2]\n"
    >>),
    ?assertEqual(
        {ok, <<"startproject:testproj">>},
        pyrlang_cli:run(["--path", Dir, "-m", "django", "startproject", "testproj"])
    ),
    cleanup_tree(Dir).

pyrlang_escript_finds_ebin_from_other_working_directory_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir("pyrlang_escript_cwd"),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "main.py"),
    ok = file:write_file(Path, <<"value = 41\nvalue + 1\n">>),
    Root = filename:absname("."),
    Script = filename:join([Root, "bin", "pyrlang"]),
    Command = "cd /tmp && escript " ++ quote(Script) ++ " " ++ quote(Path),
    ?assertEqual("42\n", os:cmd(Command)),
    cleanup_tree(Dir).

pyrlang_escript_runs_command_string_test() ->
    pyrlang_heap:init(),
    Root = filename:absname("."),
    Script = filename:join([Root, "bin", "pyrlang"]),
    Command = "escript " ++ quote(Script) ++ " -c " ++ quote("print('hello')"),
    ?assertEqual("hello\n", os:cmd(Command)).

pyrlang_escript_repl_keeps_state_and_prints_expression_repr_test() ->
    pyrlang_heap:init(),
    Root = filename:absname("."),
    Script = filename:join([Root, "bin", "pyrlang"]),
    Input = "answer = 40\nanswer + 2\nname = 'Guido'\nname\n",
    Command = "printf " ++ quote(Input) ++ " | escript " ++ quote(Script),
    ?assertEqual("pyr> pyr> 42\npyr> pyr> 'Guido'\npyr> ", os:cmd(Command)).

pyrlang_escript_repl_runs_multiline_block_test() ->
    pyrlang_heap:init(),
    Root = filename:absname("."),
    Script = filename:join([Root, "bin", "pyrlang"]),
    Input = "def inc(value):\n    return value + 1\ninc(41)\n",
    Command = "printf " ++ quote(Input) ++ " | escript " ++ quote(Script),
    ?assertEqual("pyr> ...> pyr> 42\npyr> ", os:cmd(Command)).

pyrlang_escript_repl_import_this_does_not_echo_module_ref_test() ->
    pyrlang_heap:init(),
    Root = filename:absname("."),
    Script = filename:join([Root, "bin", "pyrlang"]),
    Command = "printf " ++ quote("import this\n") ++ " | escript " ++ quote(Script),
    Output = os:cmd(Command),
    ?assertNotEqual(nomatch, string:find(Output, "The Zen of Python")),
    ?assertEqual(nomatch, string:find(Output, "py_ref")).

pyrlang_and_pyrunicorn_escript_wrappers_exist_test() ->
    ?assertMatch({ok, _Info}, file:read_file_info(filename:join(["bin", "pyrlang"]))),
    ?assertMatch({ok, _Info}, file:read_file_info(filename:join(["bin", "pyrunicorn"]))).

pyrunicorn_cli_parses_documented_options_test() ->
    {ok, Config} = pyrunicorn_cli:parse_args([
        "mysite.wsgi:application",
        "--bind",
        "0.0.0.0:8000",
        "--workers",
        "4",
        "--django-settings-module",
        "mysite.settings",
        "-I",
        "apps"
    ]),
    #{app := <<"mysite.wsgi:application">>, path := ["apps"], options := Options} = Config,
    ?assertEqual({0, 0, 0, 0}, maps:get(ip, Options)),
    ?assertEqual(8000, maps:get(port, Options)),
    ?assertEqual(4, maps:get(workers, Options)),
    ?assertEqual(
        <<"mysite.settings">>, maps:get(<<"DJANGO_SETTINGS_MODULE">>, maps:get(os_environ, Options))
    ).

pyrunicorn_cli_starts_beam_server_with_actor_local_django_settings_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir("pyrunicorn_cli"),
    ok = file:make_dir(Dir),
    Module = "cli_wsgi",
    AppSpec = Module ++ ":application",
    Path = filename:join(Dir, Module ++ ".pyr"),
    ok = file:write_file(Path, <<
        "import os\n",
        "def application(environ, start_response):\n",
        "    start_response(\"200 OK\", [[\"content-type\", \"text/plain\"]])\n",
        "    return [os.environ[\"DJANGO_SETTINGS_MODULE\"]]\n"
    >>),
    {ok, Server, Port, _Config} = pyrunicorn_cli:start_from_args([
        AppSpec,
        "--bind",
        "127.0.0.1:0",
        "--workers",
        "1",
        "--django-settings-module",
        "mysite.settings",
        "--path",
        Dir
    ]),
    Response = http_get(Port, <<"/">>),
    ok = pyrunicorn_server:stop(Server),
    cleanup_tree(Dir),
    ?assertMatch(<<"HTTP/1.1 200 OK\r\n", _/binary>>, Response),
    ?assert(binary:match(Response, <<"mysite.settings">>) =/= nomatch).

http_get(Port, Path) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Socket, <<"GET ", Path/binary, " HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    ok = gen_tcp:close(Socket),
    Response.

temp_dir(Prefix) ->
    filename:join(
        "/tmp",
        lists:flatten(
            io_lib:format("~s_~p_~p", [
                Prefix, erlang:unique_integer([positive]), erlang:system_time(millisecond)
            ])
        )
    ).

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

quote(Text) ->
    "'" ++ lists:flatten([quote_char(Char) || Char <- Text]) ++ "'".

quote_char($') ->
    "'\\''";
quote_char(Char) ->
    [Char].
