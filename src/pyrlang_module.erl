-module(pyrlang_module).

-include("pyrlang.hrl").

-export([
    set_path/1,
    path/0,
    set_os_environ/1,
    set_argv/1,
    argv/0,
    load/1,
    resolve_import_name/2,
    run_as_main/2,
    get_attr/2,
    set_attr/3,
    env/1,
    name/1,
    weakref_reference_type/0
]).

-define(PY_MODULE_PATH_KEY, pyrlang_module_path).
-define(PY_MODULE_CACHE_KEY, pyrlang_module_cache).
-define(PY_OS_ENV_KEY, pyrlang_os_environ).
-define(PY_SYS_ARGV_KEY, pyrlang_sys_argv).
-define(PY_STDLIB_VERSION, "3.13").
-define(FUNCTION_ID_KEY, '$py_function_id').

-spec set_path([binary() | string()]) -> ok.
set_path(Paths) ->
    erlang:put(?PY_MODULE_PATH_KEY, [to_list(Path) || Path <- Paths]),
    ok.

-spec path() -> [string()].
path() ->
    case erlang:get(?PY_MODULE_PATH_KEY) of
        undefined -> default_path();
        Paths when is_list(Paths) -> Paths
    end.

default_path() ->
    unique_paths(
        ["."] ++
            env_paths("PYRLANGPATH") ++
            env_paths("PYTHONPATH") ++
            stdlib_paths() ++
            site_package_paths()
    ).

env_paths(Name) ->
    case os:getenv(Name) of
        false ->
            [];
        Value ->
            [Path || Path <- string:split(Value, ":", all), Path =/= ""]
    end.

site_package_paths() ->
    Preferred = [
        ".venv/lib/python" ++ ?PY_STDLIB_VERSION ++ "/site-packages",
        "venv/lib/python" ++ ?PY_STDLIB_VERSION ++ "/site-packages",
        "/Library/Frameworks/Python.framework/Versions/" ++ ?PY_STDLIB_VERSION ++ "/lib/python" ++
            ?PY_STDLIB_VERSION ++ "/site-packages",
        "/Library/Frameworks/Python.framework/Versions/Current/lib/python" ++ ?PY_STDLIB_VERSION ++
            "/site-packages",
        "/usr/local/lib/python" ++ ?PY_STDLIB_VERSION ++ "/site-packages",
        "/usr/lib/python" ++ ?PY_STDLIB_VERSION ++ "/site-packages"
    ],
    unique_paths([Path || Path <- Preferred ++ user_site_paths(), filelib:is_dir(Path)]).

stdlib_paths() ->
    Preferred = [
        ".venv/lib/python" ++ ?PY_STDLIB_VERSION,
        "venv/lib/python" ++ ?PY_STDLIB_VERSION,
        "/Library/Frameworks/Python.framework/Versions/" ++ ?PY_STDLIB_VERSION ++ "/lib/python" ++
            ?PY_STDLIB_VERSION,
        "/Library/Frameworks/Python.framework/Versions/Current/lib/python" ++ ?PY_STDLIB_VERSION,
        "/usr/local/lib/python" ++ ?PY_STDLIB_VERSION,
        "/usr/lib/python" ++ ?PY_STDLIB_VERSION
    ],
    unique_paths([Path || Path <- Preferred, filelib:is_dir(Path)]).

user_site_paths() ->
    case os:getenv("HOME") of
        false ->
            [];
        Home ->
            [
                filename:join([
                    Home, "Library", "Python", ?PY_STDLIB_VERSION, "lib", "python", "site-packages"
                ]),
                filename:join([
                    Home, ".local", "lib", "python" ++ ?PY_STDLIB_VERSION, "site-packages"
                ])
            ]
    end.

unique_paths(Paths) ->
    lists:reverse(
        element(
            2,
            lists:foldl(
                fun(Path, {Seen, Acc}) ->
                    case maps:is_key(Path, Seen) of
                        true -> {Seen, Acc};
                        false -> {Seen#{Path => true}, [Path | Acc]}
                    end
                end,
                {#{}, []},
                Paths
            )
        )
    ).

-spec set_os_environ(map() | [{term(), term()}]) -> ok.
set_os_environ(Values) ->
    erlang:put(?PY_OS_ENV_KEY, normalize_env(Values)),
    ok.

-spec set_argv([binary() | string()]) -> ok.
set_argv(Args) ->
    erlang:put(?PY_SYS_ARGV_KEY, [normalize_name(Arg) || Arg <- Args]),
    ok.

-spec argv() -> [binary()].
argv() ->
    case erlang:get(?PY_SYS_ARGV_KEY) of
        undefined -> [];
        Args when is_list(Args) -> Args
    end.

sys_getframemodulename([]) ->
    <<"__main__">>;
sys_getframemodulename([_Depth]) ->
    <<"__main__">>;
sys_getframemodulename(Args) ->
    erlang:error({arity_error, {'_getframemodulename', length(Args)}}).

sys_exit([]) ->
    sys_exit([none]);
sys_exit([Code]) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"SystemExit">>), Code));
sys_exit(Args) ->
    erlang:error({arity_error, {exit, length(Args)}}).

sys_stream(Name, Device) ->
    native_instance(<<"TextIO">>, #{
        <<"name">> => Name,
        <<"encoding">> => <<"utf-8">>,
        <<"errors">> => <<"strict">>,
        <<"write">> => fun(Data) ->
            Text = normalize_name(Data),
            io:put_chars(Device, Text),
            byte_size(Text)
        end,
        <<"flush">> => fun() -> none end,
        <<"isatty">> => fun() -> stream_isatty(Device) end,
        <<"read">> => {py_native_varargs, fun(Args) -> stream_read(Device, Args) end},
        <<"readline">> => {py_native_varargs, fun(Args) -> stream_readline(Device, Args) end}
    }).

stream_isatty(Device) ->
    case io:getopts(Device) of
        Options when is_list(Options) -> proplists:get_value(terminal, Options, false) =:= true;
        _Other -> false
    end.

stream_read(Device, []) ->
    case stream_isatty(Device) of
        true -> stream_readline(Device, []);
        false -> stream_read_all(Device, [])
    end;
stream_read(Device, [Size]) when is_integer(Size), Size >= 0 ->
    stream_chars(Device, Size);
stream_read(Device, [_Size]) ->
    stream_read(Device, []);
stream_read(_Device, Args) ->
    erlang:error({arity_error, {read, length(Args)}}).

stream_read_all(Device, Acc) ->
    case io:get_line(Device, "") of
        eof -> unicode:characters_to_binary(lists:reverse(Acc));
        Line -> stream_read_all(Device, [unicode:characters_to_binary(Line) | Acc])
    end.

stream_readline(Device, []) ->
    stream_line(Device, all);
stream_readline(Device, [Size]) when is_integer(Size), Size >= 0 ->
    stream_line(Device, Size);
stream_readline(Device, [_Size]) ->
    stream_line(Device, all);
stream_readline(_Device, Args) ->
    erlang:error({arity_error, {readline, length(Args)}}).

stream_line(Device, all) ->
    case io:get_line(Device, "") of
        eof -> <<>>;
        Line -> unicode:characters_to_binary(Line)
    end;
stream_line(_Device, 0) ->
    <<>>;
stream_line(Device, Size) ->
    Line = stream_line(Device, all),
    case byte_size(Line) =< Size of
        true -> Line;
        false -> binary:part(Line, 0, Size)
    end.

stream_chars(_Device, 0) ->
    <<>>;
stream_chars(Device, Size) ->
    case io:get_chars(Device, "", Size) of
        eof -> <<>>;
        Chars -> unicode:characters_to_binary(Chars)
    end.

getpass_getpass([]) ->
    getpass_getpass([<<"Password: ">>]);
getpass_getpass([Prompt]) ->
    io:put_chars(standard_error, normalize_name(Prompt)),
    case read_password_silent() of
        {ok, Password} ->
            io:put_chars(standard_error, "\n"),
            unicode:characters_to_binary(Password);
        unsupported ->
            read_password_echoed()
    end;
getpass_getpass([Prompt, _Stream]) ->
    getpass_getpass([Prompt]);
getpass_getpass(Args) ->
    erlang:error({arity_error, {getpass, length(Args)}}).

read_password_silent() ->
    TermState = prepare_password_term(),
    try
        case catch shell:start_interactive({noshell, raw}) of
            ok ->
                try io:get_password() of
                    Password when is_list(Password); is_binary(Password) ->
                        trace_getpass({ok, tty_state()}),
                        {ok, Password};
                    Other ->
                        trace_getpass({unsupported_password, Other}),
                        unsupported
                after
                    catch shell:start_interactive({noshell, cooked})
                end;
            Other ->
                trace_getpass({unsupported_shell, Other, tty_state()}),
                unsupported
        end
    after
        restore_password_term(TermState)
    end.

prepare_password_term() ->
    case os:getenv("TERM") of
        false ->
            os:putenv("TERM", "xterm-256color"),
            {restore_unset, false};
        "dumb" ->
            os:putenv("TERM", "xterm-256color"),
            {restore, "dumb"};
        _Term ->
            unchanged
    end.

restore_password_term(unchanged) ->
    ok;
restore_password_term({restore_unset, false}) ->
    os:unsetenv("TERM");
restore_password_term({restore, Term}) ->
    os:putenv("TERM", Term).

trace_getpass(Event) ->
    case os:getenv("PYRLANG_TRACE_GETPASS") of
        false -> ok;
        _ -> io:format(standard_error, "PYRLANG_GETPASS ~p~n", [Event])
    end.

tty_state() ->
    catch begin
        ok = prim_tty:load(),
        #{
            stdin => prim_tty:isatty(stdin),
            stdout => prim_tty:isatty(stdout),
            term => os:getenv("TERM")
        }
    end.

read_password_echoed() ->
    case io:get_line(standard_io, "") of
        eof ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"EOFError">>), <<"EOF when reading a line">>
                )
            );
        Line ->
            strip_line_ending(unicode:characters_to_binary(Line))
    end.

getpass_getuser([]) ->
    Env = os_environ(),
    First = fun(Name, Default) -> env_value(Name, Env, Default) end,
    First(<<"LOGNAME">>, First(<<"USER">>, First(<<"LNAME">>, First(<<"USERNAME">>, <<>>))));
getpass_getuser(Args) ->
    erlang:error({arity_error, {getuser, length(Args)}}).

env_value(Name, Env, Default) ->
    case maps:find(Name, Env) of
        {ok, Value} ->
            Value;
        error ->
            case os:getenv(binary_to_list(Name)) of
                false -> Default;
                Value -> unicode:characters_to_binary(Value)
            end
    end.

strip_line_ending(Line) ->
    Size = byte_size(Line),
    case Size of
        N when N >= 2 ->
            case binary:part(Line, N - 2, 2) of
                <<"\r\n">> -> binary:part(Line, 0, N - 2);
                _ -> strip_single_newline(Line)
            end;
        _ ->
            strip_single_newline(Line)
    end.

strip_single_newline(Line) ->
    Size = byte_size(Line),
    case Size of
        N when N >= 1 ->
            case binary:part(Line, N - 1, 1) of
                <<"\n">> -> binary:part(Line, 0, N - 1);
                _ -> Line
            end;
        _ ->
            Line
    end.

sys_getframe([]) ->
    sys_getframe([0]);
sys_getframe([_Depth]) ->
    Globals = pyrlang_heap:dict([{<<"__name__">>, <<"__main__">>}]),
    Locals = pyrlang_heap:dict([]),
    Code = native_instance(<<"Code">>, #{
        <<"co_filename">> => <<"">>,
        <<"co_name">> => <<"<module>">>,
        <<"co_firstlineno">> => 1,
        <<"co_flags">> => 0
    }),
    native_instance(<<"Frame">>, #{
        <<"f_globals">> => Globals,
        <<"f_locals">> => Locals,
        <<"f_code">> => Code,
        <<"f_back">> => none,
        <<"f_lineno">> => 1
    });
sys_getframe(Args) ->
    erlang:error({arity_error, {'_getframe', length(Args)}}).

sys_audit(_Args) ->
    none.

sys_intern([Value]) when is_binary(Value) ->
    Value;
sys_intern([Value]) when is_list(Value) ->
    unicode:characters_to_binary(Value);
sys_intern(Args) ->
    erlang:error({arity_error, {intern, length(Args)}}).

sys_getfilesystemencoding([]) ->
    <<"utf-8">>;
sys_getfilesystemencoding(Args) ->
    erlang:error({arity_error, {getfilesystemencoding, length(Args)}}).

sys_getfilesystemencodeerrors([]) ->
    <<"surrogateescape">>;
sys_getfilesystemencodeerrors(Args) ->
    erlang:error({arity_error, {getfilesystemencodeerrors, length(Args)}}).

sys_getrecursionlimit([]) ->
    case erlang:get(pyrlang_sys_recursionlimit) of
        undefined -> 1000;
        Limit when is_integer(Limit) -> Limit
    end;
sys_getrecursionlimit(Args) ->
    erlang:error({arity_error, {getrecursionlimit, length(Args)}}).

sys_setrecursionlimit([Limit]) when is_integer(Limit), Limit > 0 ->
    erlang:put(pyrlang_sys_recursionlimit, Limit),
    none;
sys_setrecursionlimit([Limit]) when is_integer(Limit) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"ValueError">>), <<"recursion limit must be positive">>
        )
    );
sys_setrecursionlimit(Args) ->
    erlang:error({arity_error, {setrecursionlimit, length(Args)}}).

default_stdlib_dir() ->
    case stdlib_paths() of
        [Path | _] -> unicode:characters_to_binary(Path);
        [] -> <<>>
    end.

builtin_module_names() ->
    list_to_tuple([
        <<"_abc">>,
        <<"_ast">>,
        <<"_bisect">>,
        <<"_codecs">>,
        <<"_collections">>,
        <<"_csv">>,
        <<"_datetime">>,
        <<"_functools">>,
        <<"_imp">>,
        <<"_io">>,
        <<"_locale">>,
        <<"_operator">>,
        <<"_opcode">>,
        <<"_osx_support">>,
        <<"_random">>,
        <<"_signal">>,
        <<"_socket">>,
        <<"_sre">>,
        <<"_stat">>,
        <<"_string">>,
        <<"_struct">>,
        <<"_thread">>,
        <<"_tokenize">>,
        <<"_tracemalloc">>,
        <<"_typing">>,
        <<"_warnings">>,
        <<"_weakref">>,
        <<"array">>,
        <<"atexit">>,
        <<"builtins">>,
        <<"errno">>,
        <<"fcntl">>,
        <<"gc">>,
        <<"getpass">>,
        <<"gzip">>,
        <<"grp">>,
        <<"itertools">>,
        <<"marshal">>,
        <<"math">>,
        <<"operator">>,
        <<"posix">>,
        <<"pwd">>,
        <<"select">>,
        <<"sys">>,
        <<"sysconfig">>,
        <<"time">>,
        <<"zlib">>
    ]).

sysconfig_env() ->
    #{
        <<"__name__">> => <<"sysconfig">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"get_config_var">> => {py_native_varargs, fun sysconfig_get_config_var/1},
        <<"get_config_vars">> => {py_native_varargs, fun sysconfig_get_config_vars/1},
        <<"get_default_scheme">> => {py_native_varargs, fun sysconfig_get_default_scheme/1},
        <<"get_path">> => {py_native_call, fun sysconfig_get_path/2},
        <<"get_paths">> => {py_native_call, fun sysconfig_get_paths/2}
    }.

sysconfig_get_config_var([Name]) ->
    maps:get(normalize_name(Name), sysconfig_vars(), none);
sysconfig_get_config_var(Args) ->
    erlang:error({arity_error, {get_config_var, length(Args)}}).

sysconfig_get_config_vars([]) ->
    pyrlang_heap:dict(sysconfig_vars());
sysconfig_get_config_vars(Names) ->
    Vars = sysconfig_vars(),
    pyrlang_heap:list([maps:get(normalize_name(Name), Vars, none) || Name <- Names]).

sysconfig_get_default_scheme([]) ->
    <<"posix_prefix">>;
sysconfig_get_default_scheme(Args) ->
    erlang:error({arity_error, {get_default_scheme, length(Args)}}).

sysconfig_get_path([Name], _KwArgs) ->
    maps:get(normalize_name(Name), sysconfig_paths(), none);
sysconfig_get_path([Name, _Scheme], _KwArgs) ->
    maps:get(normalize_name(Name), sysconfig_paths(), none);
sysconfig_get_path(Args, _KwArgs) ->
    erlang:error({arity_error, {get_path, length(Args)}}).

sysconfig_get_paths([], _KwArgs) ->
    pyrlang_heap:dict(sysconfig_paths());
sysconfig_get_paths([_Scheme], _KwArgs) ->
    pyrlang_heap:dict(sysconfig_paths());
sysconfig_get_paths(Args, _KwArgs) ->
    erlang:error({arity_error, {get_paths, length(Args)}}).

sysconfig_vars() ->
    #{
        <<"ABIFLAGS">> => <<>>,
        <<"EXT_SUFFIX">> => <<".so">>,
        <<"LIBDIR">> => <<"/usr/local/lib">>,
        <<"LIBDEST">> => <<"/usr/local/lib/python3.13">>,
        <<"BINLIBDEST">> => <<"/usr/local/lib/python3.13">>,
        <<"INCLUDEPY">> => <<"/usr/local/include/python3.13">>,
        <<"MULTIARCH">> => <<>>,
        <<"SOABI">> => <<"cpython-313-darwin">>,
        <<"TZPATH">> => <<"/usr/share/zoneinfo:/usr/share/lib/zoneinfo:/usr/lib/locale/TZ">>,
        <<"abi_thread">> => <<>>,
        <<"abiflags">> => <<>>,
        <<"base">> => <<"/usr/local">>,
        <<"exec_prefix">> => <<"/usr/local">>,
        <<"installed_base">> => <<"/usr/local">>,
        <<"installed_platbase">> => <<"/usr/local">>,
        <<"platbase">> => <<"/usr/local">>,
        <<"platlibdir">> => <<"lib">>,
        <<"prefix">> => <<"/usr/local">>,
        <<"py_version">> => <<"3.13.0">>,
        <<"py_version_short">> => <<"3.13">>,
        <<"py_version_nodot">> => <<"313">>
    }.

sysconfig_paths() ->
    #{
        <<"stdlib">> => <<"/usr/local/lib/python3.13">>,
        <<"platstdlib">> => <<"/usr/local/lib/python3.13">>,
        <<"purelib">> => <<"/usr/local/lib/python3.13/site-packages">>,
        <<"platlib">> => <<"/usr/local/lib/python3.13/site-packages">>,
        <<"include">> => <<"/usr/local/include/python3.13">>,
        <<"platinclude">> => <<"/usr/local/include/python3.13">>,
        <<"scripts">> => <<"/usr/local/bin">>,
        <<"data">> => <<"/usr/local">>
    }.

io_open_code([Path]) ->
    pyrlang_builtins:open([Path, <<"rb">>]);
io_open_code(Args) ->
    erlang:error({arity_error, {open_code, length(Args)}}).

io_text_encoding([none]) ->
    <<"utf-8">>;
io_text_encoding([Encoding]) ->
    Encoding;
io_text_encoding([none, _StackLevel]) ->
    <<"utf-8">>;
io_text_encoding([Encoding, _StackLevel]) ->
    Encoding;
io_text_encoding(Args) ->
    erlang:error({arity_error, {text_encoding, length(Args)}}).

io_class(Name) ->
    pyrlang_object:new_class(
        Name, [maps:get(<<"object">>, pyrlang_builtins:env())], io_class_attrs(Name)
    ).

io_class_attrs(<<"BytesIO">>) ->
    (io_class_attrs_base())#{
        <<"__new__">> => {py_native_call, fun io_memory_dunder_new/2},
        <<"__init__">> => {py_native_call, fun io_bytesio_init/2},
        <<"read">> => {py_native_varargs, fun io_memory_read/1},
        <<"readline">> => {py_native_varargs, fun io_memory_readline/1},
        <<"write">> => fun io_bytesio_write/2,
        <<"seek">> => {py_native_varargs, fun io_memory_seek/1},
        <<"tell">> => fun io_memory_tell/1,
        <<"getvalue">> => fun io_memory_getvalue/1,
        <<"readable">> => fun(_Self) -> true end,
        <<"seekable">> => fun(_Self) -> true end,
        <<"writable">> => fun(_Self) -> true end
    };
io_class_attrs(<<"StringIO">>) ->
    (io_class_attrs_base())#{
        <<"__new__">> => {py_native_call, fun io_memory_dunder_new/2},
        <<"__init__">> => {py_native_call, fun io_stringio_init/2},
        <<"read">> => {py_native_varargs, fun io_memory_read/1},
        <<"readline">> => {py_native_varargs, fun io_memory_readline/1},
        <<"write">> => fun io_stringio_write/2,
        <<"seek">> => {py_native_varargs, fun io_memory_seek/1},
        <<"tell">> => fun io_memory_tell/1,
        <<"getvalue">> => fun io_memory_getvalue/1,
        <<"readable">> => fun(_Self) -> true end,
        <<"seekable">> => fun(_Self) -> true end,
        <<"writable">> => fun(_Self) -> true end
    };
io_class_attrs(_Name) ->
    io_class_attrs_base().

io_class_attrs_base() ->
    #{
        <<"__doc__">> => <<>>,
        <<"close">> => fun(_Self) -> none end,
        <<"flush">> => fun(_Self) -> none end,
        <<"readable">> => fun(_Self) -> false end,
        <<"seekable">> => fun(_Self) -> false end,
        <<"writable">> => fun(_Self) -> false end
    }.

io_memory_dunder_new([Class | _Args], _KwArgs) ->
    pyrlang_object:instantiate(Class);
io_memory_dunder_new(Args, _KwArgs) ->
    erlang:error({arity_error, {'io memory __new__', length(Args)}}).

io_bytesio_init([Self], KwArgs) ->
    io_bytesio_init(
        [Self, maps:get(<<"initial_bytes">>, KwArgs, <<>>)],
        maps:without([<<"initial_bytes">>], KwArgs)
    );
io_bytesio_init([Self, InitialBytes], KwArgs) when map_size(KwArgs) =:= 0 ->
    io_memory_init(Self, io_bytes_value(InitialBytes));
io_bytesio_init(Args, KwArgs) ->
    erlang:error({arity_error, {'io.BytesIO.__init__', length(Args), maps:size(KwArgs)}}).

io_stringio_init([Self], KwArgs) ->
    io_stringio_init(
        [Self, maps:get(<<"initial_value">>, KwArgs, <<>>)],
        maps:without([<<"initial_value">>], KwArgs)
    );
io_stringio_init([Self, InitialValue], KwArgs) when map_size(KwArgs) =:= 0 ->
    io_memory_init(Self, io_text_value(InitialValue));
io_stringio_init(Args, KwArgs) ->
    erlang:error({arity_error, {'io.StringIO.__init__', length(Args), maps:size(KwArgs)}}).

io_memory_init(Self, Buffer) ->
    ok = pyrlang_object:set_attr(Self, <<"__pyrlang_io_buffer">>, Buffer),
    ok = pyrlang_object:set_attr(Self, <<"__pyrlang_io_pos">>, 0),
    none.

io_bytesio_write(Self, Data) ->
    io_memory_write(Self, io_bytes_value(Data)).

io_stringio_write(Self, Data) ->
    io_memory_write(Self, io_text_value(Data)).

io_memory_write(Self, Data) ->
    Buffer = io_memory_buffer(Self),
    Pos = io_memory_pos(Self),
    Size = byte_size(Buffer),
    DataSize = byte_size(Data),
    PrefixSize = min(Pos, Size),
    Prefix = binary:part(Buffer, 0, PrefixSize),
    Padding =
        case Pos > Size of
            true -> binary:copy(<<0>>, Pos - Size);
            false -> <<>>
        end,
    SuffixStart = min(Pos + DataSize, Size),
    Suffix =
        case SuffixStart < Size of
            true -> binary:part(Buffer, SuffixStart, Size - SuffixStart);
            false -> <<>>
        end,
    ok = pyrlang_object:set_attr(
        Self,
        <<"__pyrlang_io_buffer">>,
        <<Prefix/binary, Padding/binary, Data/binary, Suffix/binary>>
    ),
    ok = pyrlang_object:set_attr(Self, <<"__pyrlang_io_pos">>, Pos + DataSize),
    DataSize.

io_memory_read([Self]) ->
    io_memory_read([Self, -1]);
io_memory_read([Self, none]) ->
    io_memory_read([Self, -1]);
io_memory_read([Self, Size]) when is_integer(Size) ->
    Buffer = io_memory_buffer(Self),
    Pos = io_memory_pos(Self),
    Available = max(byte_size(Buffer) - Pos, 0),
    Count =
        case Size < 0 of
            true -> Available;
            false -> min(Size, Available)
        end,
    Data = binary:part(Buffer, Pos, Count),
    ok = pyrlang_object:set_attr(Self, <<"__pyrlang_io_pos">>, Pos + Count),
    Data;
io_memory_read(Args) ->
    erlang:error({arity_error, {'io memory read', length(Args)}}).

io_memory_readline([Self]) ->
    io_memory_readline([Self, -1]);
io_memory_readline([Self, none]) ->
    io_memory_readline([Self, -1]);
io_memory_readline([Self, Size]) when is_integer(Size) ->
    Buffer = io_memory_buffer(Self),
    Pos = io_memory_pos(Self),
    Available = max(byte_size(Buffer) - Pos, 0),
    Limit =
        case Size < 0 of
            true -> Available;
            false -> min(Size, Available)
        end,
    Slice = binary:part(Buffer, Pos, Limit),
    Count =
        case binary:match(Slice, <<"\n">>) of
            {NewlinePos, 1} -> NewlinePos + 1;
            nomatch -> Limit
        end,
    Data = binary:part(Buffer, Pos, Count),
    ok = pyrlang_object:set_attr(Self, <<"__pyrlang_io_pos">>, Pos + Count),
    Data;
io_memory_readline(Args) ->
    erlang:error({arity_error, {'io memory readline', length(Args)}}).

io_memory_seek([Self, Offset]) ->
    io_memory_seek([Self, Offset, 0]);
io_memory_seek([Self, Offset, Whence]) when is_integer(Offset), is_integer(Whence) ->
    Buffer = io_memory_buffer(Self),
    Current = io_memory_pos(Self),
    Base =
        case Whence of
            0 -> 0;
            1 -> Current;
            2 -> byte_size(Buffer);
            _ -> erlang:error({value_error, {invalid_whence, Whence}})
        end,
    NewPos = max(Base + Offset, 0),
    ok = pyrlang_object:set_attr(Self, <<"__pyrlang_io_pos">>, NewPos),
    NewPos;
io_memory_seek(Args) ->
    erlang:error({arity_error, {'io memory seek', length(Args)}}).

io_memory_tell(Self) ->
    io_memory_pos(Self).

io_memory_getvalue(Self) ->
    io_memory_buffer(Self).

io_memory_buffer(Self) ->
    try
        pyrlang_object:get_attr(Self, <<"__pyrlang_io_buffer">>)
    catch
        _:_ -> <<>>
    end.

io_memory_pos(Self) ->
    try pyrlang_object:get_attr(Self, <<"__pyrlang_io_pos">>) of
        Pos when is_integer(Pos) -> Pos;
        _ -> 0
    catch
        _:_ -> 0
    end.

io_bytes_value(Value) when is_binary(Value) ->
    Value;
io_bytes_value(Value) when is_list(Value) ->
    iolist_to_binary(Value);
io_bytes_value({py_ref, _} = Ref) ->
    iolist_to_binary([io_byte_value(Item) || Item <- pyrlang_iter:values(Ref)]);
io_bytes_value(none) ->
    <<>>;
io_bytes_value(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

io_byte_value(Value) when is_integer(Value), Value >= 0, Value =< 255 ->
    Value;
io_byte_value(Value) ->
    erlang:error({value_error, {byte_out_of_range, Value}}).

io_text_value(Value) when is_binary(Value) ->
    Value;
io_text_value(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
io_text_value(none) ->
    <<>>;
io_text_value(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

opcode_stack_effect([_Opcode]) ->
    0;
opcode_stack_effect([_Opcode, _Oparg]) ->
    0;
opcode_stack_effect([_Opcode, _Oparg, _Jump]) ->
    0;
opcode_stack_effect(Args) ->
    erlang:error({arity_error, {stack_effect, length(Args)}}).

opcode_predicate([Opcode]) when is_integer(Opcode), Opcode >= 0 ->
    true;
opcode_predicate([_Opcode]) ->
    false;
opcode_predicate(Args) ->
    erlang:error({arity_error, {opcode_predicate, length(Args)}}).

opcode_false_predicate([_Opcode]) ->
    false;
opcode_false_predicate(Args) ->
    erlang:error({arity_error, {opcode_predicate, length(Args)}}).

opcode_intrinsic1_descs([]) ->
    pyrlang_heap:list([<<"INTRINSIC_1_INVALID">>]);
opcode_intrinsic1_descs(Args) ->
    erlang:error({arity_error, {get_intrinsic1_descs, length(Args)}}).

opcode_intrinsic2_descs([]) ->
    pyrlang_heap:list([<<"INTRINSIC_2_INVALID">>]);
opcode_intrinsic2_descs(Args) ->
    erlang:error({arity_error, {get_intrinsic2_descs, length(Args)}}).

opcode_nb_ops([]) ->
    pyrlang_heap:list([
        {<<"NB_ADD">>, <<"+">>},
        {<<"NB_SUBTRACT">>, <<"-">>},
        {<<"NB_MULTIPLY">>, <<"*">>},
        {<<"NB_TRUE_DIVIDE">>, <<"/">>}
    ]);
opcode_nb_ops(Args) ->
    erlang:error({arity_error, {get_nb_ops, length(Args)}}).

opcode_none([]) ->
    none;
opcode_none(Args) ->
    erlang:error({arity_error, {opcode_none, length(Args)}}).

imp_missing_frozen(Name) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"ImportError">>),
            <<"No frozen module named ", (normalize_name(Name))/binary>>
        )
    ).

imp_source_hash(_Magic, SourceBytes) ->
    Hash = crypto:hash(sha256, normalize_name(SourceBytes)),
    binary:part(Hash, 0, 8).

warnings_noop(_Args) ->
    none.

marshal_dumps([_Value]) ->
    <<>>;
marshal_dumps([_Value, _Version]) ->
    <<>>;
marshal_dumps(Args) ->
    erlang:error({arity_error, {marshal_dumps, length(Args)}}).

marshal_loads([_Bytes]) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), <<"bad marshal data">>)
    );
marshal_loads(Args) ->
    erlang:error({arity_error, {marshal_loads, length(Args)}}).

marshal_dump([Value, File]) ->
    Data = marshal_dumps([Value]),
    Write = pyrlang_object:get_attr(File, <<"write">>),
    _ = pyrlang_eval:call(Write, [Data]),
    none;
marshal_dump([Value, File, Version]) ->
    Data = marshal_dumps([Value, Version]),
    Write = pyrlang_object:get_attr(File, <<"write">>),
    _ = pyrlang_eval:call(Write, [Data]),
    none;
marshal_dump(Args) ->
    erlang:error({arity_error, {marshal_dump, length(Args)}}).

marshal_load([File]) ->
    Read = pyrlang_object:get_attr(File, <<"read">>),
    _ = pyrlang_eval:call(Read, []),
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), <<"bad marshal data">>)
    );
marshal_load(Args) ->
    erlang:error({arity_error, {marshal_load, length(Args)}}).

struct_env() ->
    #{
        <<"__name__">> => <<"_struct">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"__doc__">> => <<"BEAM-native subset of CPython _struct">>,
        <<"error">> => pyrlang_exception:type(<<"StructError">>),
        <<"calcsize">> => {py_native_varargs, fun struct_calcsize/1},
        <<"pack">> => {py_native_varargs, fun struct_pack/1},
        <<"pack_into">> => {py_native_varargs, fun struct_pack_into/1},
        <<"unpack">> => {py_native_varargs, fun struct_unpack/1},
        <<"unpack_from">> => {py_native_varargs, fun struct_unpack_from/1},
        <<"iter_unpack">> => {py_native_varargs, fun struct_iter_unpack/1},
        <<"Struct">> => {py_native_call, fun struct_struct_new/2},
        <<"_clearcache">> => {py_native_varargs, fun struct_clearcache/1}
    }.

struct_clearcache([]) ->
    none;
struct_clearcache(Args) ->
    erlang:error({arity_error, {'_struct._clearcache', length(Args)}}).

struct_calcsize([Format]) ->
    struct_calcsize_tokens(struct_parse_format(Format));
struct_calcsize(Args) ->
    erlang:error({arity_error, {'_struct.calcsize', length(Args)}}).

struct_pack([Format | Values]) ->
    Tokens = struct_parse_format(Format),
    case struct_pack_tokens(Tokens, Values, []) of
        {Packed, []} ->
            Packed;
        {_Packed, Extra} ->
            raise_struct_error(
                <<"pack expected fewer items than provided: ",
                    (integer_to_binary(length(Extra)))/binary>>
            )
    end;
struct_pack(Args) ->
    erlang:error({arity_error, {'_struct.pack', length(Args)}}).

struct_pack_into([Format, _Buffer, _Offset | Values]) ->
    _Packed = struct_pack([Format | Values]),
    none;
struct_pack_into(Args) ->
    erlang:error({arity_error, {'_struct.pack_into', length(Args)}}).

struct_unpack([Format, Data]) ->
    Tokens = struct_parse_format(Format),
    Binary = struct_binary(Data),
    Size = struct_calcsize_tokens(Tokens),
    case byte_size(Binary) of
        Size ->
            list_to_tuple(struct_unpack_tokens(Tokens, Binary, []));
        Actual ->
            raise_struct_error(
                <<"unpack requires a buffer of ", (integer_to_binary(Size))/binary, " bytes; got ",
                    (integer_to_binary(Actual))/binary>>
            )
    end;
struct_unpack(Args) ->
    erlang:error({arity_error, {'_struct.unpack', length(Args)}}).

struct_unpack_from([Format, Data]) ->
    struct_unpack_from([Format, Data, 0]);
struct_unpack_from([Format, Data, Offset0]) when is_integer(Offset0) ->
    Tokens = struct_parse_format(Format),
    Binary = struct_binary(Data),
    Size = struct_calcsize_tokens(Tokens),
    Offset = normalize_buffer_offset(Offset0, byte_size(Binary)),
    case Offset + Size =< byte_size(Binary) of
        true ->
            Chunk = binary:part(Binary, Offset, Size),
            list_to_tuple(struct_unpack_tokens(Tokens, Chunk, []));
        false ->
            raise_struct_error(
                <<"unpack_from requires a buffer of at least ",
                    (integer_to_binary(Offset + Size))/binary, " bytes">>
            )
    end;
struct_unpack_from(Args) ->
    erlang:error({arity_error, {'_struct.unpack_from', length(Args)}}).

struct_iter_unpack([Format, Data]) ->
    Tokens = struct_parse_format(Format),
    Size = struct_calcsize_tokens(Tokens),
    case Size of
        0 ->
            raise_struct_error(<<"cannot iteratively unpack with a struct of length 0">>);
        _ ->
            Binary = struct_binary(Data),
            case byte_size(Binary) rem Size of
                0 ->
                    pyrlang_heap:list(struct_iter_unpack_chunks(Tokens, Binary, Size, []));
                _ ->
                    raise_struct_error(
                        <<"iterative unpacking requires a buffer with a whole number of records">>
                    )
            end
    end;
struct_iter_unpack(Args) ->
    erlang:error({arity_error, {'_struct.iter_unpack', length(Args)}}).

struct_struct_new([Format], KwArgs) when map_size(KwArgs) =:= 0 ->
    Tokens = struct_parse_format(Format),
    Size = struct_calcsize_tokens(Tokens),
    FormatBin = normalize_name(Format),
    native_instance(<<"Struct">>, #{
        <<"format">> => FormatBin,
        <<"size">> => Size,
        <<"pack">> => {py_native_varargs, fun(Values) -> struct_pack([FormatBin | Values]) end},
        <<"pack_into">> =>
            {py_native_varargs, fun([Buffer, Offset | Values]) ->
                struct_pack_into([FormatBin, Buffer, Offset | Values])
            end},
        <<"unpack">> => {py_native_varargs, fun([Data]) -> struct_unpack([FormatBin, Data]) end},
        <<"unpack_from">> =>
            {py_native_varargs, fun
                ([Data]) -> struct_unpack_from([FormatBin, Data]);
                ([Data, Offset]) -> struct_unpack_from([FormatBin, Data, Offset]);
                (Args) -> erlang:error({arity_error, {'_struct.Struct.unpack_from', length(Args)}})
            end},
        <<"iter_unpack">> =>
            {py_native_varargs, fun([Data]) -> struct_iter_unpack([FormatBin, Data]) end}
    });
struct_struct_new(_Args, KwArgs) when map_size(KwArgs) =/= 0 ->
    erlang:error({type_error, {unexpected_keyword_argument, maps:keys(KwArgs)}});
struct_struct_new(Args, _KwArgs) ->
    erlang:error({arity_error, {'_struct.Struct', length(Args)}}).

struct_parse_format(Format0) ->
    Format = binary_to_list(normalize_name(Format0)),
    {Endian, Rest} = struct_format_endian(Format),
    struct_parse_format_chars(Rest, Endian, []).

struct_format_endian([$< | Rest]) -> {little, Rest};
struct_format_endian([$> | Rest]) -> {big, Rest};
struct_format_endian([$! | Rest]) -> {big, Rest};
struct_format_endian([$@ | Rest]) -> {little, Rest};
struct_format_endian([$= | Rest]) -> {little, Rest};
struct_format_endian(Rest) -> {little, Rest}.

struct_parse_format_chars([], _Endian, Acc) ->
    lists:reverse(Acc);
struct_parse_format_chars([Char | Rest], Endian, Acc) when
    Char =:= $\s; Char =:= $\n; Char =:= $\t; Char =:= $\r
->
    struct_parse_format_chars(Rest, Endian, Acc);
struct_parse_format_chars(Chars, Endian, Acc) ->
    {Count, [Code | Rest]} = struct_take_count(Chars),
    Token = struct_token(Code, Count, Endian),
    struct_parse_format_chars(Rest, Endian, [Token | Acc]).

struct_take_count(Chars) ->
    {Digits, Rest} = struct_take_digits(Chars, []),
    Count =
        case Digits of
            [] -> 1;
            _ -> list_to_integer(lists:reverse(Digits))
        end,
    case Rest of
        [] -> raise_struct_error(<<"repeat count given without format specifier">>);
        _ -> {Count, Rest}
    end.

struct_take_digits([Char | Rest], Acc) when Char >= $0, Char =< $9 ->
    struct_take_digits(Rest, [Char | Acc]);
struct_take_digits(Rest, Acc) ->
    {Acc, Rest}.

struct_token($x, Count, _Endian) -> {pad, Count};
struct_token($c, Count, _Endian) -> {char, Count};
struct_token($s, Count, _Endian) -> {bytes, Count};
struct_token($p, Count, _Endian) -> {pascal, Count};
struct_token($b, Count, _Endian) -> {int, Count, 1, signed, little};
struct_token($B, Count, _Endian) -> {int, Count, 1, unsigned, little};
struct_token($h, Count, Endian) -> {int, Count, 2, signed, Endian};
struct_token($H, Count, Endian) -> {int, Count, 2, unsigned, Endian};
struct_token($i, Count, Endian) -> {int, Count, 4, signed, Endian};
struct_token($I, Count, Endian) -> {int, Count, 4, unsigned, Endian};
struct_token($l, Count, Endian) -> {int, Count, 4, signed, Endian};
struct_token($L, Count, Endian) -> {int, Count, 4, unsigned, Endian};
struct_token($q, Count, Endian) -> {int, Count, 8, signed, Endian};
struct_token($Q, Count, Endian) -> {int, Count, 8, unsigned, Endian};
struct_token($n, Count, Endian) -> {int, Count, 8, signed, Endian};
struct_token($N, Count, Endian) -> {int, Count, 8, unsigned, Endian};
struct_token($f, Count, Endian) -> {float, Count, 4, Endian};
struct_token($d, Count, Endian) -> {float, Count, 8, Endian};
struct_token(Code, _Count, _Endian) -> raise_struct_error(<<"bad char in struct format: ", Code>>).

struct_calcsize_tokens(Tokens) ->
    lists:sum([struct_token_size(Token) || Token <- Tokens]).

struct_token_size({pad, Count}) -> Count;
struct_token_size({char, Count}) -> Count;
struct_token_size({bytes, Count}) -> Count;
struct_token_size({pascal, Count}) -> Count;
struct_token_size({int, Count, Size, _Signed, _Endian}) -> Count * Size;
struct_token_size({float, Count, Size, _Endian}) -> Count * Size.

struct_pack_tokens([], Values, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Values};
struct_pack_tokens([Token | Rest], Values0, Acc0) ->
    {Chunk, Values1} = struct_pack_token(Token, Values0),
    struct_pack_tokens(Rest, Values1, [Chunk | Acc0]).

struct_pack_token({pad, Count}, Values) ->
    {binary:copy(<<0>>, Count), Values};
struct_pack_token({char, Count}, Values) ->
    struct_pack_repeat(Count, Values, fun struct_pack_char/1, []);
struct_pack_token({bytes, Count}, [Value | Rest]) ->
    {struct_fit_binary(struct_binary(Value), Count), Rest};
struct_pack_token({bytes, _Count}, []) ->
    raise_struct_error(<<"pack expected an item for 's' format">>);
struct_pack_token({pascal, Count}, [Value | Rest]) ->
    Binary = struct_binary(Value),
    DataLen = min(byte_size(Binary), max(Count - 1, 0)),
    Prefix =
        case Count of
            0 -> <<>>;
            _ -> <<DataLen:8/unsigned-integer>>
        end,
    Data = binary:part(Binary, 0, DataLen),
    {struct_fit_binary(<<Prefix/binary, Data/binary>>, Count), Rest};
struct_pack_token({pascal, _Count}, []) ->
    raise_struct_error(<<"pack expected an item for 'p' format">>);
struct_pack_token({int, Count, Size, Signed, Endian}, Values) ->
    struct_pack_repeat(
        Count, Values, fun(Value) -> struct_pack_int(Endian, Signed, Size, Value) end, []
    );
struct_pack_token({float, Count, Size, Endian}, Values) ->
    struct_pack_repeat(Count, Values, fun(Value) -> struct_pack_float(Endian, Size, Value) end, []).

struct_pack_repeat(0, Values, PackFun, Acc) when is_function(PackFun, 1) ->
    {iolist_to_binary(lists:reverse(Acc)), Values};
struct_pack_repeat(_Count, [], _PackFun, _Acc) ->
    raise_struct_error(<<"pack expected more items than provided">>);
struct_pack_repeat(Count, [Value | Rest], PackFun, Acc) ->
    struct_pack_repeat(Count - 1, Rest, PackFun, [PackFun(Value) | Acc]).

struct_pack_char(Value) ->
    case struct_binary(Value) of
        <<Byte>> ->
            <<Byte>>;
        Other ->
            raise_struct_error(
                <<"char format requires a bytes object of length 1; got ",
                    (integer_to_binary(byte_size(Other)))/binary>>
            )
    end.

struct_pack_int(little, signed, 1, Value) when is_integer(Value) -> <<Value:8/signed-integer>>;
struct_pack_int(little, unsigned, 1, Value) when is_integer(Value) -> <<Value:8/unsigned-integer>>;
struct_pack_int(big, signed, 1, Value) when is_integer(Value) -> <<Value:8/signed-integer>>;
struct_pack_int(big, unsigned, 1, Value) when is_integer(Value) -> <<Value:8/unsigned-integer>>;
struct_pack_int(little, signed, 2, Value) when is_integer(Value) ->
    <<Value:16/little-signed-integer>>;
struct_pack_int(little, unsigned, 2, Value) when is_integer(Value) ->
    <<Value:16/little-unsigned-integer>>;
struct_pack_int(big, signed, 2, Value) when is_integer(Value) -> <<Value:16/big-signed-integer>>;
struct_pack_int(big, unsigned, 2, Value) when is_integer(Value) ->
    <<Value:16/big-unsigned-integer>>;
struct_pack_int(little, signed, 4, Value) when is_integer(Value) ->
    <<Value:32/little-signed-integer>>;
struct_pack_int(little, unsigned, 4, Value) when is_integer(Value) ->
    <<Value:32/little-unsigned-integer>>;
struct_pack_int(big, signed, 4, Value) when is_integer(Value) -> <<Value:32/big-signed-integer>>;
struct_pack_int(big, unsigned, 4, Value) when is_integer(Value) ->
    <<Value:32/big-unsigned-integer>>;
struct_pack_int(little, signed, 8, Value) when is_integer(Value) ->
    <<Value:64/little-signed-integer>>;
struct_pack_int(little, unsigned, 8, Value) when is_integer(Value) ->
    <<Value:64/little-unsigned-integer>>;
struct_pack_int(big, signed, 8, Value) when is_integer(Value) -> <<Value:64/big-signed-integer>>;
struct_pack_int(big, unsigned, 8, Value) when is_integer(Value) ->
    <<Value:64/big-unsigned-integer>>;
struct_pack_int(_Endian, _Signed, _Size, Value) ->
    raise_struct_error(
        <<"required argument is not an integer: ",
            (unicode:characters_to_binary(io_lib:format("~p", [Value])))/binary>>
    ).

struct_pack_float(little, 4, Value) when is_integer(Value) -> <<(Value * 1.0):32/little-float>>;
struct_pack_float(little, 4, Value) when is_float(Value) -> <<Value:32/little-float>>;
struct_pack_float(big, 4, Value) when is_integer(Value) -> <<(Value * 1.0):32/big-float>>;
struct_pack_float(big, 4, Value) when is_float(Value) -> <<Value:32/big-float>>;
struct_pack_float(little, 8, Value) when is_integer(Value) -> <<(Value * 1.0):64/little-float>>;
struct_pack_float(little, 8, Value) when is_float(Value) -> <<Value:64/little-float>>;
struct_pack_float(big, 8, Value) when is_integer(Value) -> <<(Value * 1.0):64/big-float>>;
struct_pack_float(big, 8, Value) when is_float(Value) -> <<Value:64/big-float>>;
struct_pack_float(_Endian, _Size, Value) ->
    raise_struct_error(
        <<"required argument is not a float: ",
            (unicode:characters_to_binary(io_lib:format("~p", [Value])))/binary>>
    ).

struct_unpack_tokens([], <<>>, Acc) ->
    lists:reverse(Acc);
struct_unpack_tokens([Token | Rest], Binary0, Acc0) ->
    {Values, Binary1} = struct_unpack_token(Token, Binary0),
    struct_unpack_tokens(Rest, Binary1, lists:reverse(Values) ++ Acc0).

struct_unpack_token({pad, Count}, Binary) ->
    <<_Pad:Count/binary, Rest/binary>> = Binary,
    {[], Rest};
struct_unpack_token({char, Count}, Binary) ->
    struct_unpack_repeat(Count, Binary, fun struct_unpack_char/1, []);
struct_unpack_token({bytes, Count}, Binary) ->
    <<Value:Count/binary, Rest/binary>> = Binary,
    {[Value], Rest};
struct_unpack_token({pascal, Count}, Binary) ->
    <<Raw:Count/binary, Rest/binary>> = Binary,
    Value =
        case Raw of
            <<>> ->
                <<>>;
            <<Len:8/unsigned-integer, Data/binary>> ->
                binary:part(Data, 0, min(Len, byte_size(Data)))
        end,
    {[Value], Rest};
struct_unpack_token({int, Count, Size, Signed, Endian}, Binary) ->
    struct_unpack_repeat(
        Count, Binary, fun(Bin) -> struct_unpack_int(Endian, Signed, Size, Bin) end, []
    );
struct_unpack_token({float, Count, Size, Endian}, Binary) ->
    struct_unpack_repeat(Count, Binary, fun(Bin) -> struct_unpack_float(Endian, Size, Bin) end, []).

struct_unpack_repeat(0, Binary, UnpackFun, Acc) when is_function(UnpackFun, 1) ->
    {lists:reverse(Acc), Binary};
struct_unpack_repeat(Count, Binary0, UnpackFun, Acc) ->
    {Value, Binary1} = UnpackFun(Binary0),
    struct_unpack_repeat(Count - 1, Binary1, UnpackFun, [Value | Acc]).

struct_unpack_char(<<Byte, Rest/binary>>) ->
    {<<Byte>>, Rest}.

struct_unpack_int(little, signed, 1, <<Value:8/signed-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(little, unsigned, 1, <<Value:8/unsigned-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(big, signed, 1, <<Value:8/signed-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(big, unsigned, 1, <<Value:8/unsigned-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(little, signed, 2, <<Value:16/little-signed-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(little, unsigned, 2, <<Value:16/little-unsigned-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(big, signed, 2, <<Value:16/big-signed-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(big, unsigned, 2, <<Value:16/big-unsigned-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(little, signed, 4, <<Value:32/little-signed-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(little, unsigned, 4, <<Value:32/little-unsigned-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(big, signed, 4, <<Value:32/big-signed-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(big, unsigned, 4, <<Value:32/big-unsigned-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(little, signed, 8, <<Value:64/little-signed-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(little, unsigned, 8, <<Value:64/little-unsigned-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(big, signed, 8, <<Value:64/big-signed-integer, Rest/binary>>) ->
    {Value, Rest};
struct_unpack_int(big, unsigned, 8, <<Value:64/big-unsigned-integer, Rest/binary>>) ->
    {Value, Rest}.

struct_unpack_float(little, 4, <<Value:32/little-float, Rest/binary>>) -> {Value, Rest};
struct_unpack_float(big, 4, <<Value:32/big-float, Rest/binary>>) -> {Value, Rest};
struct_unpack_float(little, 8, <<Value:64/little-float, Rest/binary>>) -> {Value, Rest};
struct_unpack_float(big, 8, <<Value:64/big-float, Rest/binary>>) -> {Value, Rest}.

struct_iter_unpack_chunks(_Tokens, <<>>, _Size, Acc) ->
    lists:reverse(Acc);
struct_iter_unpack_chunks(Tokens, Binary, Size, Acc) ->
    <<Chunk:Size/binary, Rest/binary>> = Binary,
    Tuple = list_to_tuple(struct_unpack_tokens(Tokens, Chunk, [])),
    struct_iter_unpack_chunks(Tokens, Rest, Size, [Tuple | Acc]).

struct_fit_binary(Binary, Size) when byte_size(Binary) >= Size ->
    binary:part(Binary, 0, Size);
struct_fit_binary(Binary, Size) ->
    Padding = binary:copy(<<0>>, Size - byte_size(Binary)),
    <<Binary/binary, Padding/binary>>.

struct_binary(Value) when is_binary(Value) ->
    Value;
struct_binary(Value) ->
    iolist_to_binary([struct_byte_value(Item) || Item <- pyrlang_iter:values(Value)]).

struct_byte_value(Value) when is_integer(Value), Value >= 0, Value =< 255 ->
    Value;
struct_byte_value(Value) ->
    raise_struct_error(
        <<"bytes-like object item is outside 0..255: ",
            (unicode:characters_to_binary(io_lib:format("~p", [Value])))/binary>>
    ).

normalize_buffer_offset(Offset, Size) when Offset < 0 ->
    Normalized = Size + Offset,
    case Normalized >= 0 of
        true -> Normalized;
        false -> raise_struct_error(<<"offset out of range">>)
    end;
normalize_buffer_offset(Offset, _Size) ->
    Offset.

raise_struct_error(Message) when is_binary(Message) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"StructError">>), Message)
    ).

codecs_lookup(Encoding) ->
    Canonical = codecs_canonical_name(Encoding),
    codec_info(Canonical).

codecs_register(_SearchFunction) ->
    none.

codecs_unregister(_SearchFunction) ->
    none.

codecs_lookup_error(_Name) ->
    fun(Exception) -> pyrlang_exception:raise(Exception) end.

codecs_register_error(_Name, _Handler) ->
    none.

codecs_encode(Args, KwArgs) ->
    Encoding = maps:get(<<"encoding">>, KwArgs, default_encoding_arg(Args, 2, <<"utf-8">>)),
    Errors = maps:get(<<"errors">>, KwArgs, default_encoding_arg(Args, 3, <<"strict">>)),
    Unknown = maps:keys(maps:without([<<"encoding">>, <<"errors">>], KwArgs)),
    case {Args, Unknown} of
        {[], _} ->
            erlang:error({arity_error, {codecs_encode, 0}});
        {[_Input], []} ->
            codecs_encode_value(hd(Args), Encoding, Errors);
        {[_Input, _Encoding], []} ->
            codecs_encode_value(hd(Args), Encoding, Errors);
        {[_Input, _Encoding, _Errors], []} ->
            codecs_encode_value(hd(Args), Encoding, Errors);
        {_, []} ->
            erlang:error({arity_error, {codecs_encode, length(Args)}});
        {_, _} ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end.

codecs_decode(Args, KwArgs) ->
    Encoding = maps:get(<<"encoding">>, KwArgs, default_encoding_arg(Args, 2, <<"utf-8">>)),
    Errors = maps:get(<<"errors">>, KwArgs, default_encoding_arg(Args, 3, <<"strict">>)),
    Unknown = maps:keys(maps:without([<<"encoding">>, <<"errors">>], KwArgs)),
    case {Args, Unknown} of
        {[], _} ->
            erlang:error({arity_error, {codecs_decode, 0}});
        {[_Input], []} ->
            codecs_decode_value(hd(Args), Encoding, Errors);
        {[_Input, _Encoding], []} ->
            codecs_decode_value(hd(Args), Encoding, Errors);
        {[_Input, _Encoding, _Errors], []} ->
            codecs_decode_value(hd(Args), Encoding, Errors);
        {_, []} ->
            erlang:error({arity_error, {codecs_decode, length(Args)}});
        {_, _} ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end.

default_encoding_arg(Args, Index, Default) ->
    case length(Args) >= Index of
        true -> lists:nth(Index, Args);
        false -> Default
    end.

codec_info(Canonical) ->
    native_instance(<<"CodecInfo">>, #{
        <<"name">> => Canonical,
        <<"encode">> => {py_native_varargs, fun(Args) -> codecs_encode_tuple(Canonical, Args) end},
        <<"decode">> => {py_native_varargs, fun(Args) -> codecs_decode_tuple(Canonical, Args) end},
        <<"incrementalencoder">> => none,
        <<"incrementaldecoder">> => none,
        <<"streamreader">> => none,
        <<"streamwriter">> => none
    }).

codecs_encode_tuple(Canonical, [Input]) ->
    codecs_encode_tuple(Canonical, [Input, <<"strict">>]);
codecs_encode_tuple(Canonical, [Input, Errors]) ->
    Output = codecs_encode_value(Input, Canonical, Errors),
    {Output, byte_size(normalize_name(Input))};
codecs_encode_tuple(_Canonical, Args) ->
    erlang:error({arity_error, {codecs_encode_tuple, length(Args)}}).

codecs_decode_tuple(Canonical, [Input]) ->
    codecs_decode_tuple(Canonical, [Input, <<"strict">>]);
codecs_decode_tuple(Canonical, [Input, Errors]) ->
    InputBin = normalize_name(Input),
    Output = codecs_decode_value(InputBin, Canonical, Errors),
    {Output, byte_size(InputBin)};
codecs_decode_tuple(Canonical, [Input, Errors, _Final]) ->
    codecs_decode_tuple(Canonical, [Input, Errors]);
codecs_decode_tuple(_Canonical, Args) ->
    erlang:error({arity_error, {codecs_decode_tuple, length(Args)}}).

codecs_utf8_decode([Input]) ->
    codecs_decode_tuple(<<"utf-8">>, [Input]);
codecs_utf8_decode([Input, Errors]) ->
    codecs_decode_tuple(<<"utf-8">>, [Input, Errors]);
codecs_utf8_decode([Input, Errors, Final]) ->
    codecs_decode_tuple(<<"utf-8">>, [Input, Errors, Final]);
codecs_utf8_decode(Args) ->
    erlang:error({arity_error, {utf_8_decode, length(Args)}}).

codecs_utf8_encode([Input]) ->
    codecs_encode_tuple(<<"utf-8">>, [Input]);
codecs_utf8_encode([Input, Errors]) ->
    codecs_encode_tuple(<<"utf-8">>, [Input, Errors]);
codecs_utf8_encode(Args) ->
    erlang:error({arity_error, {utf_8_encode, length(Args)}}).

codecs_latin1_decode([Input]) ->
    codecs_decode_tuple(<<"latin-1">>, [Input]);
codecs_latin1_decode([Input, Errors]) ->
    codecs_decode_tuple(<<"latin-1">>, [Input, Errors]);
codecs_latin1_decode([Input, Errors, Final]) ->
    codecs_decode_tuple(<<"latin-1">>, [Input, Errors, Final]);
codecs_latin1_decode(Args) ->
    erlang:error({arity_error, {latin_1_decode, length(Args)}}).

codecs_latin1_encode([Input]) ->
    codecs_encode_tuple(<<"latin-1">>, [Input]);
codecs_latin1_encode([Input, Errors]) ->
    codecs_encode_tuple(<<"latin-1">>, [Input, Errors]);
codecs_latin1_encode(Args) ->
    erlang:error({arity_error, {latin_1_encode, length(Args)}}).

codecs_ascii_decode(Args) ->
    codecs_utf8_decode(Args).

codecs_ascii_encode(Args) ->
    codecs_utf8_encode(Args).

codecs_passthrough_tuple([Input]) ->
    InputBin = normalize_name(Input),
    {InputBin, byte_size(InputBin)};
codecs_passthrough_tuple([Input, _Errors]) ->
    InputBin = normalize_name(Input),
    {InputBin, byte_size(InputBin)};
codecs_passthrough_tuple(Args) ->
    erlang:error({arity_error, {codecs_passthrough, length(Args)}}).

codecs_readbuffer_encode(Args) ->
    codecs_passthrough_tuple(Args).

codecs_charmap_build(_Map) ->
    pyrlang_heap:dict([]).

codecs_encode_value(Input, Encoding0, _Errors) ->
    Encoding = codecs_canonical_name(Encoding0),
    InputBin = normalize_name(Input),
    case Encoding of
        <<"utf-8">> -> InputBin;
        <<"utf-8-sig">> -> <<16#EF, 16#BB, 16#BF, InputBin/binary>>;
        <<"ascii">> -> InputBin;
        <<"latin-1">> -> unicode:characters_to_binary(InputBin, utf8, latin1)
    end.

codecs_decode_value(Input, Encoding0, _Errors) ->
    Encoding = codecs_canonical_name(Encoding0),
    InputBin = normalize_name(Input),
    case Encoding of
        <<"utf-8">> -> InputBin;
        <<"utf-8-sig">> -> strip_utf8_bom(InputBin);
        <<"ascii">> -> InputBin;
        <<"latin-1">> -> unicode:characters_to_binary(InputBin, latin1, utf8)
    end.

strip_utf8_bom(<<16#EF, 16#BB, 16#BF, Rest/binary>>) ->
    Rest;
strip_utf8_bom(Binary) ->
    Binary.

codecs_canonical_name(Name0) ->
    Name = normalize_encoding_text(Name0),
    case Name of
        <<"utf8">> ->
            <<"utf-8">>;
        <<"utf-8">> ->
            <<"utf-8">>;
        <<"utf-8-sig">> ->
            <<"utf-8-sig">>;
        <<"utf-8sig">> ->
            <<"utf-8-sig">>;
        <<"ascii">> ->
            <<"ascii">>;
        <<"us-ascii">> ->
            <<"ascii">>;
        <<"latin1">> ->
            <<"latin-1">>;
        <<"latin-1">> ->
            <<"latin-1">>;
        <<"iso-8859-1">> ->
            <<"latin-1">>;
        <<"iso8859-1">> ->
            <<"latin-1">>;
        <<"iso88591">> ->
            <<"latin-1">>;
        _ ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"LookupError">>), <<"unknown encoding: ", Name/binary>>
                )
            )
    end.

normalize_encoding_text(Name0) ->
    Name = string:lowercase(binary_to_list(normalize_name(Name0))),
    unicode:characters_to_binary([normalize_encoding_char(Char) || Char <- Name, Char =/= $\s]).

normalize_encoding_char($_) ->
    $-;
normalize_encoding_char(Char) ->
    Char.

tokenizer_iter_new(_Args, _KwArgs) ->
    pyrlang_heap:list([]).

-spec load(binary() | string() | atom()) -> term().
load(Name0) ->
    Name = normalize_name(Name0),
    Cache = cache(),
    case maps:find(Name, Cache) of
        {ok, ModuleRef} ->
            ModuleRef;
        error ->
            ensure_parent_package_loaded(Name),
            case maps:find(Name, cache()) of
                {ok, ModuleRef} -> ModuleRef;
                error -> load_uncached(Name)
            end
    end.

-spec run_as_main(binary() | string() | atom(), [binary() | string()]) -> {term(), map()}.
run_as_main(Name0, Args0) ->
    Name = normalize_name(Name0),
    TargetName = main_target_name(Name),
    case find_module(TargetName) of
        {ok, Path, IsPackage} ->
            ok = set_argv([Path | Args0]),
            {ok, Source} = file:read_file(Path),
            case pyrlang_parser:parse_module(Source) of
                {ok, Ast} ->
                    Env0 = (pyrlang_builtins:env())#{
                        <<"__name__">> => <<"__main__">>,
                        <<"__file__">> => unicode:characters_to_binary(Path),
                        <<"__package__">> => package_name(TargetName, IsPackage),
                        <<"__path__">> => package_path(Path, IsPackage)
                    },
                    pyrlang_eval:eval_module(Ast, Env0);
                {error, Reason} ->
                    pyrlang_exception:raise(
                        pyrlang_exception:make(
                            pyrlang_exception:type(<<"ImportError">>),
                            {parse_error, TargetName, Reason}
                        )
                    )
            end;
        error ->
            raise_module_not_found(TargetName)
    end.

-spec get_attr(term(), binary() | string() | atom()) -> term().
get_attr(ModuleRef, Attr0) ->
    module = pyrlang_heap:type(ModuleRef),
    Attr = normalize_attr(Attr0),
    case Attr of
        <<"__dict__">> ->
            {py_module_dict, ModuleRef};
        _ ->
            Env = maps:get(env, pyrlang_heap:data(ModuleRef)),
            case maps:find(Attr, Env) of
                {ok, Value} ->
                    Value;
                error ->
                    case maps:find(<<"__getattr__">>, Env) of
                        {ok, Getter} ->
                            pyrlang_eval:call(Getter, [Attr]);
                        error ->
                            pyrlang_exception:raise(
                                pyrlang_exception:make(
                                    pyrlang_exception:type(<<"AttributeError">>), Attr
                                )
                            )
                    end
            end
    end.

-spec set_attr(term(), binary() | string() | atom(), term()) -> ok.
set_attr(ModuleRef, Attr0, Value) ->
    module = pyrlang_heap:type(ModuleRef),
    Attr = normalize_attr(Attr0),
    Data = pyrlang_heap:data(ModuleRef),
    Env = maps:get(env, Data),
    pyrlang_heap:set_data(ModuleRef, Data#{env := Env#{Attr => Value}}).

-spec env(term()) -> map().
env(ModuleRef) ->
    module = pyrlang_heap:type(ModuleRef),
    maps:get(env, pyrlang_heap:data(ModuleRef)).

-spec name(term()) -> binary().
name(ModuleRef) ->
    module = pyrlang_heap:type(ModuleRef),
    maps:get(name, pyrlang_heap:data(ModuleRef)).

load_uncached(Name) ->
    case builtin_module(Name) of
        {ok, Env0} ->
            Env = ensure_builtin_module_runtime_attrs(Name, Env0),
            ModuleRef = pyrlang_heap:allocate(module, #{
                name => Name,
                path => builtin,
                package => false,
                env => Env,
                last => none
            }),
            put_cache(Name, ModuleRef),
            attach_to_parent(Name, ModuleRef),
            ModuleRef;
        error ->
            load_file_uncached(Name)
    end.

load_file_uncached(Name) ->
    case find_module(Name) of
        {ok, Path, IsPackage} ->
            trace_module_load(load, Name, Path),
            PrevLoadingStack =
                case erlang:get(pyrlang_loading_stack) of
                    undefined -> [];
                    ExistingLoadingStack -> ExistingLoadingStack
                end,
            LoadingStack = [{Name, Path} | PrevLoadingStack],
            erlang:put(pyrlang_loading_stack, LoadingStack),
            {ok, Source} = file:read_file(Path),
            case pyrlang_parser:parse_module(Source) of
                {ok, Ast} ->
                    Env0 = module_initial_env(Name, Path, IsPackage),
                    Placeholder = pyrlang_heap:placeholder(module),
                    ok = pyrlang_heap:set_data(Placeholder, #{
                        name => Name,
                        path => Path,
                        package => IsPackage,
                        env => Env0,
                        last => none
                    }),
                    put_cache(Name, Placeholder),
                    PrevLoadingModule = erlang:get(pyrlang_current_loading_module),
                    erlang:put(pyrlang_current_loading_module, Placeholder),
                    {Last, Env} =
                        try
                            pyrlang_eval:eval_module(Ast, Env0)
                        catch
                            Class:Reason:Stack ->
                                remove_cache(Name),
                                case erlang:get(pyrlang_failed_loading_stack) of
                                    undefined ->
                                        erlang:put(pyrlang_failed_loading_stack, LoadingStack);
                                    _ExistingFailedStack ->
                                        ok
                                end,
                                erlang:raise(Class, Reason, Stack)
                        after
                            restore_process_value(
                                pyrlang_current_loading_module, PrevLoadingModule
                            ),
                            erlang:put(pyrlang_loading_stack, PrevLoadingStack)
                        end,
                    DataAfterLoad = pyrlang_heap:data(Placeholder),
                    AttachedEnv = maps:get(env, DataAfterLoad, #{}),
                    FinalEnv = pyrlang_eval:bind_module_globals(
                        patch_loaded_module_env(Name, maps:merge(Env, AttachedEnv))
                    ),
                    ok = pyrlang_heap:set_data(Placeholder, DataAfterLoad#{
                        env := FinalEnv, last := Last
                    }),
                    attach_to_parent(Name, Placeholder),
                    trace_module_load(done, Name, Path),
                    Placeholder;
                {error, Reason} ->
                    pyrlang_exception:raise(
                        pyrlang_exception:make(
                            pyrlang_exception:type(<<"ImportError">>), {parse_error, Name, Reason}
                        )
                    )
            end;
        error ->
            trace_module_load(miss, Name, builtin),
            raise_module_not_found(Name)
    end.

raise_module_not_found(Name) ->
    pyrlang_exception:raise(
        pyrlang_exception:make_args(
            pyrlang_exception:type(<<"ModuleNotFoundError">>),
            [<<"No module named ", Name/binary>>],
            #{<<"name">> => Name, <<"path">> => none}
        )
    ).

trace_module_load(Stage, Name, Path) ->
    case os:getenv("PYRLANG_TRACE_IMPORTS") of
        false ->
            ok;
        _ ->
            case Stage of
                load -> io:format(standard_error, "PYRLANG_LOAD ~s ~s~n", [Name, Path]);
                done -> io:format(standard_error, "PYRLANG_DONE ~s~n", [Name]);
                miss -> io:format(standard_error, "PYRLANG_MISS ~s~n", [Name]);
                import_module -> io:format(standard_error, "PYRLANG_IMPORT_MODULE ~s~n", [Name])
            end
    end.

restore_process_value(Key, undefined) ->
    erlang:erase(Key);
restore_process_value(Key, Value) ->
    erlang:put(Key, Value).

patch_loaded_module_env(<<"inspect">>, Env) ->
    Env#{
        <<"signature">> => {py_native_call, fun inspect_signature_call/2},
        <<"isclass">> => {py_native_call, fun inspect_isclass_call/2},
        <<"ismodule">> => {py_native_call, fun inspect_ismodule_call/2},
        <<"ismethod">> => {py_native_call, fun inspect_ismethod_call/2},
        <<"isfunction">> => {py_native_call, fun inspect_isfunction_call/2},
        <<"isbuiltin">> => {py_native_call, fun inspect_isbuiltin_call/2},
        <<"isroutine">> => {py_native_call, fun inspect_isroutine_call/2},
        <<"iscoroutinefunction">> => {py_native_call, fun inspect_iscoroutinefunction_call/2},
        <<"isgeneratorfunction">> => {py_native_call, fun inspect_isgeneratorfunction_call/2},
        <<"isasyncgenfunction">> => {py_native_call, fun inspect_isasyncgenfunction_call/2},
        <<"markcoroutinefunction">> => {py_native_call, fun inspect_markcoroutinefunction_call/2}
    };
patch_loaded_module_env(<<"importlib._bootstrap">>, Env) ->
    (maps:merge(Env, importlib_bootstrap_env()))#{
        <<"_blocking_on">> => pyrlang_heap:dict([])
    };
patch_loaded_module_env(<<"importlib.util">>, Env) ->
    Env#{
        <<"find_spec">> => {py_native_call, fun importlib_util_find_spec/2}
    };
patch_loaded_module_env(<<"http.client">>, Env) ->
    try
        Http = load(<<"http">>),
        Status = get_attr(Http, <<"HTTPStatus">>),
        Members = pyrlang_object:get_attr(Status, <<"__members__">>),
        ResponseItems =
            [{Code, Phrase} || {_Name, Code, Phrase} <- http_status_specs()] ++
                [
                    {StatusValue, pyrlang_object:get_attr(StatusValue, <<"phrase">>)}
                 || {_Name, StatusValue} <- pyrlang_heap:dict_items(Members)
                ],
        Responses = pyrlang_heap:dict(ResponseItems),
        (maps:merge(maps:from_list(pyrlang_heap:dict_items(Members)), Env))#{
            <<"responses">> => Responses
        }
    catch
        _:_ -> Env
    end;
patch_loaded_module_env(<<"collections">>, Env) ->
    Env#{<<"Counter">> => {py_native_call, fun collections_counter_new/2}};
patch_loaded_module_env(<<"contextlib">>, Env) ->
    Env#{<<"contextmanager">> => {py_native_call, fun contextlib_contextmanager/2}};
patch_loaded_module_env(_Name, Env) ->
    Env.

ensure_parent_package_loaded(Name) ->
    Parts = binary:split(Name, <<".">>, [global]),
    case lists:droplast(Parts) of
        [] ->
            ok;
        ParentParts ->
            _ = load(join_binary(ParentParts, <<".">>)),
            ok
    end.

module_initial_env(Name, Path, IsPackage) ->
    PathBin = unicode:characters_to_binary(Path),
    Spec = importlib_module_spec(Name, PathBin, IsPackage),
    Base = (pyrlang_builtins:env())#{
        <<"__name__">> => Name,
        <<"__file__">> => PathBin,
        <<"__package__">> => package_name(Name, IsPackage),
        <<"__path__">> => package_path(Path, IsPackage),
        <<"__spec__">> => Spec,
        <<"__loader__">> => pyrlang_object:get_attr(Spec, <<"loader">>)
    },
    case Name of
        <<"inspect">> ->
            maps:merge(Base, inspect_compiler_flag_env());
        <<"typing">> ->
            TypingEnv = typing_env(),
            Base#{<<"Protocol">> => maps:get(<<"Generic">>, TypingEnv)};
        <<"importlib._bootstrap">> ->
            maps:merge(Base, importlib_bootstrap_env());
        _ ->
            Base
    end.

ensure_builtin_module_runtime_attrs(Name, Env0) ->
    Origin = builtin_module_origin(Env0),
    IsPackage = maps:get(<<"__path__">>, Env0, none) =/= none,
    Spec = maps:get(<<"__spec__">>, Env0, importlib_module_spec(Name, Origin, IsPackage)),
    Loader =
        case maps:find(<<"__loader__">>, Env0) of
            {ok, ExistingLoader} ->
                ExistingLoader;
            error ->
                pyrlang_object:get_attr(Spec, <<"loader">>)
        end,
    Env0#{
        <<"__spec__">> => Spec,
        <<"__loader__">> => Loader
    }.

builtin_module_origin(Env) ->
    case maps:get(<<"__file__">>, Env, builtin) of
        builtin -> <<"built-in">>;
        Path when is_binary(Path) -> Path;
        Path when is_list(Path) -> unicode:characters_to_binary(Path);
        _Other -> <<"built-in">>
    end.

importlib_bootstrap_env() ->
    #{
        <<"sys">> => load(<<"sys">>),
        <<"_imp">> => load(<<"_imp">>),
        <<"_thread">> => load(<<"_thread">>),
        <<"_warnings">> => load(<<"_warnings">>),
        <<"_weakref">> => load(<<"_weakref">>)
    }.

inspect_compiler_flag_env() ->
    #{
        <<"CO_OPTIMIZED">> => 1,
        <<"CO_NEWLOCALS">> => 2,
        <<"CO_VARARGS">> => 4,
        <<"CO_VARKEYWORDS">> => 8,
        <<"CO_NESTED">> => 16,
        <<"CO_GENERATOR">> => 32,
        <<"CO_NOFREE">> => 64,
        <<"CO_COROUTINE">> => 128,
        <<"CO_ITERABLE_COROUTINE">> => 256,
        <<"CO_ASYNC_GENERATOR">> => 512
    }.

inspect_signature_call([Function], _KwArgs) ->
    trace_inspect(signature_start, Function),
    Result = inspect_signature(Function),
    trace_inspect(signature_done, Result),
    Result;
inspect_signature_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_signature, length(Args)}}).

inspect_isclass_call([Object], _KwArgs) ->
    is_class_like(Object);
inspect_isclass_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_isclass, length(Args)}}).

inspect_ismodule_call([Object], _KwArgs) ->
    case Object of
        {py_ref, _} = Ref ->
            try
                pyrlang_heap:type(Ref) =:= module
            catch
                _:_ -> false
            end;
        _ ->
            false
    end;
inspect_ismodule_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_ismodule, length(Args)}}).

inspect_ismethod_call([Object], _KwArgs) ->
    case Object of
        {py_bound_method, _Callable, _Self} -> true;
        _ -> false
    end;
inspect_ismethod_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_ismethod, length(Args)}}).

inspect_isfunction_call([Object], _KwArgs) ->
    case inspect_unwrap_method(Object) of
        {py_function, _Params, _Body, _Env} -> true;
        {py_function, _Params, _Body, _Env, _Mode} -> true;
        {py_function, _Params, _Body, _Env, _Mode, _Owner} -> true;
        _ -> false
    end;
inspect_isfunction_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_isfunction, length(Args)}}).

inspect_isbuiltin_call([Object], _KwArgs) ->
    case Object of
        {py_native_varargs, _Fun} -> true;
        {py_native_call, _Fun} -> true;
        {py_native_callable, _Fun} -> true;
        Fun when is_function(Fun) -> true;
        _ -> false
    end;
inspect_isbuiltin_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_isbuiltin, length(Args)}}).

inspect_isroutine_call([Object], _KwArgs) ->
    inspect_isclass_routine(Object);
inspect_isroutine_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_isroutine, length(Args)}}).

inspect_isclass_routine(Object) ->
    case
        {
            inspect_isfunction_call([Object], #{}),
            inspect_ismethod_call([Object], #{}),
            inspect_isbuiltin_call([Object], #{})
        }
    of
        {false, false, false} -> false;
        _ -> true
    end.

is_class_like({py_ref, _} = Ref) ->
    try
        pyrlang_heap:type(Ref) =:= class
    catch
        _:_ -> false
    end;
is_class_like({py_exception_type, _Type}) ->
    true;
is_class_like(_Object) ->
    false.

inspect_iscoroutinefunction_call([Function], _KwArgs) ->
    inspect_function_mode(Function, async) orelse inspect_has_coroutine_mark(Function);
inspect_iscoroutinefunction_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_iscoroutinefunction, length(Args)}}).

inspect_isgeneratorfunction_call([Function], _KwArgs) ->
    inspect_function_mode(Function, true);
inspect_isgeneratorfunction_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_isgeneratorfunction, length(Args)}}).

inspect_isasyncgenfunction_call([Function], _KwArgs) ->
    inspect_function_mode(Function, async_generator);
inspect_isasyncgenfunction_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_isasyncgenfunction, length(Args)}}).

inspect_markcoroutinefunction_call([Function], _KwArgs) ->
    Target = inspect_unwrap_method(Function),
    Mark =
        try get_attr(load(<<"inspect">>), <<"_is_coroutine_mark">>) of
            Value -> Value
        catch
            _:_ -> true
        end,
    ok = pyrlang_object:set_attr(Target, <<"_is_coroutine_marker">>, Mark),
    Target;
inspect_markcoroutinefunction_call(Args, _KwArgs) ->
    erlang:error({arity_error, {inspect_markcoroutinefunction, length(Args)}}).

inspect_unwrap_method({py_bound_method, Function, _Self}) ->
    Function;
inspect_unwrap_method(Function) ->
    Function.

inspect_function_mode({py_bound_method, Function, _Self}, Mode) ->
    inspect_function_mode(Function, Mode);
inspect_function_mode({py_function, _Params, _Body, _Env}, false) ->
    true;
inspect_function_mode({py_function, _Params, _Body, _Env}, _Mode) ->
    false;
inspect_function_mode({py_function, _Params, _Body, _Env, Mode}, Mode) ->
    true;
inspect_function_mode({py_function, _Params, _Body, _Env, _OtherMode}, _Mode) ->
    false;
inspect_function_mode({py_function, _Params, _Body, _Env, Mode, _Owner}, Mode) ->
    true;
inspect_function_mode({py_function, _Params, _Body, _Env, _OtherMode, _Owner}, _Mode) ->
    false;
inspect_function_mode(_Function, _Mode) ->
    false.

inspect_has_coroutine_mark(Function0) ->
    Function = inspect_unwrap_method(Function0),
    try pyrlang_object:get_attr(Function, <<"_is_coroutine_marker">>) of
        none -> false;
        _Value -> true
    catch
        _:_ -> false
    end.

inspect_signature({py_bound_method, Function, _Self}) ->
    inspect_signature_bound_method(Function);
inspect_signature({py_function, Params, _Body, _Env}) ->
    inspect_signature_from_params(Params);
inspect_signature({py_function, Params, _Body, _Env, _Mode}) ->
    inspect_signature_from_params(Params);
inspect_signature({py_function, Params, _Body, _Env, _Mode, _Owner}) ->
    inspect_signature_from_params(Params);
inspect_signature(_Callable) ->
    inspect_signature_instance([]).

inspect_signature_bound_method({py_function, Params, _Body, _Env}) ->
    inspect_signature_from_params(drop_bound_method_param(Params));
inspect_signature_bound_method({py_function, Params, _Body, _Env, _Mode}) ->
    inspect_signature_from_params(drop_bound_method_param(Params));
inspect_signature_bound_method({py_function, Params, _Body, _Env, _Mode, _Owner}) ->
    inspect_signature_from_params(drop_bound_method_param(Params));
inspect_signature_bound_method(_Callable) ->
    inspect_signature_instance([]).

drop_bound_method_param([]) ->
    [];
drop_bound_method_param([{param, _Name, _Default, _Annotation} | Rest]) ->
    Rest;
drop_bound_method_param([{param, _Name, _Default} | Rest]) ->
    Rest;
drop_bound_method_param([{vararg, _Name, _Annotation} | Rest]) ->
    Rest;
drop_bound_method_param([{vararg, _Name} | Rest]) ->
    Rest;
drop_bound_method_param([Marker | Rest]) ->
    [Marker | drop_bound_method_param(Rest)].

inspect_signature_from_params(Params) ->
    trace_inspect({signature_params, length(Params)}, Params),
    ParameterConstants = inspect_parameter_constants(),
    {_Section, Items} =
        lists:foldl(
            fun(Param, {Section, Acc}) ->
                case inspect_parameter_from_param(Param, Section, ParameterConstants) of
                    {next_section, NextSection} -> {NextSection, Acc};
                    {Name, Parameter} -> {Section, [{Name, Parameter} | Acc]}
                end
            end,
            {poskw, []},
            Params
        ),
    inspect_signature_instance(lists:reverse(Items)).

inspect_signature_instance(Items) ->
    trace_inspect({signature_instance, length(Items)}, Items),
    native_instance(<<"Signature">>, #{
        <<"parameters">> => pyrlang_heap:dict(Items),
        <<"bind">> =>
            {py_native_call, fun(Args, KwArgs) -> inspect_signature_bind(Items, Args, KwArgs) end}
    }).

inspect_signature_bind(Items, Args, KwArgs) ->
    Constants = inspect_parameter_constants(),
    Infos = [inspect_parameter_info(Parameter, Constants) || {_Name, Parameter} <- Items],
    PositionalOrKeywordInfos = [
        Info
     || Info <- Infos, maps:get(kind, Info) =:= maps:get(positional_or_keyword, Constants)
    ],
    RequiredPositional = length([
        Info
     || Info <- PositionalOrKeywordInfos,
        inspect_parameter_required(Info),
        not maps:is_key(maps:get(name, Info), KwArgs)
    ]),
    HasVarArgs = lists:any(
        fun(Info) -> maps:get(kind, Info) =:= maps:get(var_positional, Constants) end, Infos
    ),
    MaxPositional = length(PositionalOrKeywordInfos),
    MissingKwOnly = [
        maps:get(name, Info)
     || Info <- Infos,
        maps:get(kind, Info) =:= maps:get(keyword_only, Constants),
        inspect_parameter_required(Info),
        not maps:is_key(maps:get(name, Info), KwArgs)
    ],
    HasKwArgs = lists:any(
        fun(Info) -> maps:get(kind, Info) =:= maps:get(var_keyword, Constants) end, Infos
    ),
    KnownNames = [Name || {Name, _Parameter} <- Items],
    UnknownKw = [Key || Key <- maps:keys(KwArgs), not lists:member(Key, KnownNames)],
    case
        {
            length(Args) < RequiredPositional,
            (not HasVarArgs) andalso length(Args) > MaxPositional,
            MissingKwOnly,
            (not HasKwArgs) andalso UnknownKw =/= []
        }
    of
        {true, _, _, _} ->
            signature_bind_type_error(<<"missing a required argument">>);
        {_, true, _, _} ->
            signature_bind_type_error(<<"too many positional arguments">>);
        {_, _, [_ | _], _} ->
            signature_bind_type_error(<<"missing a required keyword-only argument">>);
        {_, _, _, true} ->
            signature_bind_type_error(<<"got an unexpected keyword argument">>);
        _ ->
            native_instance(<<"BoundArguments">>, #{<<"arguments">> => pyrlang_heap:dict([])})
    end.

signature_bind_type_error(Message) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"TypeError">>), Message)
    ).

inspect_parameter_info(Parameter, Constants) ->
    #{
        name => pyrlang_object:get_attr(Parameter, <<"name">>),
        kind => pyrlang_object:get_attr(Parameter, <<"kind">>),
        default => pyrlang_object:get_attr(Parameter, <<"default">>),
        empty => maps:get(empty, Constants)
    }.

inspect_parameter_required(Info) ->
    maps:get(default, Info) =:= maps:get(empty, Info).

inspect_parameter_from_param(posonly_marker, _Section, _Constants) ->
    {next_section, poskw};
inspect_parameter_from_param(kwonly_marker, _Section, _Constants) ->
    {next_section, kwonly};
inspect_parameter_from_param({param, Name, Default, _Annotation}, Section, Constants) ->
    Kind =
        case Section of
            kwonly -> maps:get(keyword_only, Constants);
            _ -> maps:get(positional_or_keyword, Constants)
        end,
    {Name, inspect_parameter(Name, Kind, inspect_default(Default, Constants), Constants)};
inspect_parameter_from_param({param, Name, Default}, Section, Constants) ->
    Kind =
        case Section of
            kwonly -> maps:get(keyword_only, Constants);
            _ -> maps:get(positional_or_keyword, Constants)
        end,
    {Name, inspect_parameter(Name, Kind, inspect_default(Default, Constants), Constants)};
inspect_parameter_from_param({vararg, Name, _Annotation}, _Section, Constants) ->
    {Name,
        inspect_parameter(
            Name, maps:get(var_positional, Constants), maps:get(empty, Constants), Constants
        )};
inspect_parameter_from_param({vararg, Name}, _Section, Constants) ->
    {Name,
        inspect_parameter(
            Name, maps:get(var_positional, Constants), maps:get(empty, Constants), Constants
        )};
inspect_parameter_from_param({kwarg_rest, Name, _Annotation}, _Section, Constants) ->
    {Name,
        inspect_parameter(
            Name, maps:get(var_keyword, Constants), maps:get(empty, Constants), Constants
        )};
inspect_parameter_from_param({kwarg_rest, Name}, _Section, Constants) ->
    {Name,
        inspect_parameter(
            Name, maps:get(var_keyword, Constants), maps:get(empty, Constants), Constants
        )}.

inspect_parameter(Name, Kind, Default, Constants) ->
    native_instance(<<"Parameter">>, #{
        <<"name">> => Name,
        <<"kind">> => Kind,
        <<"default">> => Default,
        <<"VAR_POSITIONAL">> => maps:get(var_positional, Constants),
        <<"VAR_KEYWORD">> => maps:get(var_keyword, Constants)
    }).

inspect_default(undefined, Constants) ->
    maps:get(empty, Constants);
inspect_default({default, Value}, _Constants) ->
    Value.

inspect_parameter_constants() ->
    case erlang:get(pyrlang_inspect_parameter_constants) of
        Constants when is_map(Constants) ->
            Constants;
        _ ->
            trace_inspect(parameter_constants_start, none),
            Inspect = load(<<"inspect">>),
            Parameter = get_attr(Inspect, <<"Parameter">>),
            Constants = #{
                positional_or_keyword => pyrlang_object:get_attr(
                    Parameter, <<"POSITIONAL_OR_KEYWORD">>
                ),
                keyword_only => pyrlang_object:get_attr(Parameter, <<"KEYWORD_ONLY">>),
                var_positional => pyrlang_object:get_attr(Parameter, <<"VAR_POSITIONAL">>),
                var_keyword => pyrlang_object:get_attr(Parameter, <<"VAR_KEYWORD">>),
                empty => pyrlang_object:get_attr(Parameter, <<"empty">>)
            },
            erlang:put(pyrlang_inspect_parameter_constants, Constants),
            trace_inspect(parameter_constants_done, Constants),
            Constants
    end.

trace_inspect(Stage, Value) ->
    case os:getenv("PYRLANG_TRACE_INSPECT") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_INSPECT ~p ~p~n", [Stage, trace_inspect_value(Value)])
    end.

trace_inspect_value({py_function, _Params, _Body, _Env} = Function) ->
    trace_function_name(Function);
trace_inspect_value({py_function, _Params, _Body, _Env, _Mode} = Function) ->
    trace_function_name(Function);
trace_inspect_value({py_function, _Params, _Body, _Env, _Mode, _Owner} = Function) ->
    trace_function_name(Function);
trace_inspect_value({py_bound_method, Function, _Self}) ->
    {bound, trace_inspect_value(Function)};
trace_inspect_value(List) when is_list(List) ->
    {list, length(List)};
trace_inspect_value(Map) when is_map(Map) ->
    {map, maps:keys(Map)};
trace_inspect_value({py_ref, _} = Ref) ->
    try
        {py_ref, pyrlang_heap:type(Ref)}
    catch
        _:_ -> py_ref
    end;
trace_inspect_value(Value) ->
    Value.

trace_function_name(Function) ->
    try
        {
            pyrlang_object:get_attr(Function, <<"__module__">>),
            pyrlang_object:get_attr(Function, <<"__qualname__">>)
        }
    catch
        _:_ -> py_function
    end.

builtin_module(<<"builtins">>) ->
    {ok, (pyrlang_builtins:env())#{
        <<"__name__">> => <<"builtins">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none
    }};
builtin_module(<<"erlang">>) ->
    {ok, #{
        <<"__name__">> => <<"erlang">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"self">> => fun pyrlang_actor:self/0,
        <<"spawn">> => fun builtin_spawn/1,
        <<"spawn_link">> => fun builtin_spawn_link/1,
        <<"send">> => fun builtin_send/2,
        <<"receive">> => {py_native_varargs, fun builtin_receive/1},
        <<"receive_match">> => {py_native_varargs, fun builtin_receive_match/1},
        <<"receive_match_bindings">> => {py_native_varargs, fun builtin_receive_match_bindings/1},
        <<"make_ref">> => fun pyrlang_actor:make_ref/0,
        <<"link">> => fun pyrlang_actor:link/1,
        <<"monitor">> => fun pyrlang_actor:monitor/1,
        <<"demonitor">> => fun pyrlang_actor:demonitor/1,
        <<"trap_exit">> => fun pyrlang_actor:trap_exit/1,
        <<"exit">> => fun pyrlang_actor:exit/2,
        <<"sleep">> => fun builtin_sleep/1,
        <<"yield_now">> => fun builtin_yield_now/0,
        <<"any">> => fun pyrlang_pattern:any/0,
        <<"var">> => fun pyrlang_pattern:var/1,
        <<"atom">> => fun builtin_atom/1,
        <<"apply">> => {py_native_call, fun builtin_apply/2},
        <<"register">> => fun builtin_register/2,
        <<"whereis">> => fun builtin_whereis/1
    }};
builtin_module(<<"os">>) ->
    {ok,
        maps:merge(os_open_flag_env(), #{
            <<"__name__">> => <<"os">>,
            <<"__file__">> => builtin,
            <<"__package__">> => <<"">>,
            <<"__path__">> => none,
            <<"environ">> => pyrlang_heap:dict(os_environ()),
            <<"path">> => load(<<"posixpath">>),
            <<"PathLike">> => os_pathlike_class(),
            <<"fspath">> => fun posix_fspath/1,
            <<"fsencode">> => fun posix_fspath/1,
            <<"fsdecode">> => fun posix_fspath/1,
            <<"DirEntry">> => dir_entry_type(),
            <<"stat_result">> => stat_result_type(),
            <<"terminal_size">> => terminal_size_type(),
            <<"access">> => {py_native_call, fun posix_access_call/2},
            <<"get_terminal_size">> => {py_native_varargs, fun os_get_terminal_size/1},
            <<"getcwd">> => {py_native_varargs, fun os_getcwd/1},
            <<"_get_exports_list">> => {py_native_varargs, fun os_get_exports_list/1},
            <<"listdir">> => {py_native_varargs, fun posix_listdir/1},
            <<"mkdir">> => {py_native_varargs, fun posix_mkdir/1},
            <<"makedirs">> => {py_native_call, fun posix_makedirs_call/2},
            <<"walk">> => {py_native_call, fun posix_walk_call/2},
            <<"rmdir">> => {py_native_call, fun posix_rmdir_call/2},
            <<"open">> => {py_native_call, fun posix_open_call/2},
            <<"close">> => {py_native_varargs, fun posix_close/1},
            <<"fstat">> => {py_native_call, fun posix_fstat_call/2},
            <<"chmod">> => {py_native_call, fun posix_chmod_call/2},
            <<"umask">> => {py_native_varargs, fun posix_umask/1},
            <<"urandom">> => fun os_urandom/1,
            <<"replace">> => fun posix_replace/2,
            <<"rename">> => fun posix_replace/2,
            <<"stat">> => {py_native_call, fun posix_stat_call/2},
            <<"lstat">> => {py_native_call, fun posix_stat_call/2},
            <<"scandir">> => {py_native_call, fun posix_scandir_call/2},
            <<"unlink">> => {py_native_call, fun posix_unlink_call/2},
            <<"remove">> => {py_native_call, fun posix_unlink_call/2},
            <<"supports_dir_fd">> => pyrlang_heap:set([]),
            <<"supports_fd">> => pyrlang_heap:set([]),
            <<"supports_follow_symlinks">> => pyrlang_heap:set([]),
            <<"_walk_symlinks_as_files">> => false,
            <<"sep">> => <<"/">>,
            <<"altsep">> => none,
            <<"extsep">> => <<".">>,
            <<"pathsep">> => <<":">>,
            <<"linesep">> => <<"\n">>,
            <<"defpath">> => <<"/bin:/usr/bin">>,
            <<"devnull">> => <<"/dev/null">>,
            <<"curdir">> => <<".">>,
            <<"pardir">> => <<"..">>,
            <<"name">> => <<"posix">>
        })};
builtin_module(<<"_sysconfigdata__darwin_">>) ->
    {ok, #{
        <<"__name__">> => <<"_sysconfigdata__darwin_">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"build_time_vars">> => #{
            <<"ABIFLAGS">> => <<>>,
            <<"EXT_SUFFIX">> => <<".so">>,
            <<"LIBDIR">> => <<"/usr/local/lib">>,
            <<"LIBDEST">> => <<"/usr/local/lib/python3.13">>,
            <<"BINLIBDEST">> => <<"/usr/local/lib/python3.13">>,
            <<"INCLUDEPY">> => <<"/usr/local/include/python3.13">>,
            <<"MULTIARCH">> => <<>>,
            <<"SOABI">> => <<"cpython-313-darwin">>,
            <<"TZPATH">> => <<"/usr/share/zoneinfo:/usr/share/lib/zoneinfo:/usr/lib/locale/TZ">>,
            <<"abi_thread">> => <<>>
        }
    }};
builtin_module(<<"errno">>) ->
    {ok, errno_env()};
builtin_module(<<"math">>) ->
    {ok, math_env()};
builtin_module(<<"_random">>) ->
    {ok, random_env()};
builtin_module(<<"select">>) ->
    {ok, select_env()};
builtin_module(<<"_socket">>) ->
    {ok, socket_env()};
builtin_module(<<"_signal">>) ->
    {ok, signal_env()};
builtin_module(<<"_typing">>) ->
    {ok, typing_env()};
builtin_module(<<"posix">>) ->
    {ok, posix_env()};
builtin_module(<<"posixpath">>) ->
    {ok, posixpath_env(<<"posixpath">>)};
builtin_module(<<"os.path">>) ->
    {ok, posixpath_env(<<"os.path">>)};
builtin_module(<<"_opcode">>) ->
    {ok, #{
        <<"__name__">> => <<"_opcode">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"ENABLE_SPECIALIZATION">> => false,
        <<"stack_effect">> => {py_native_varargs, fun opcode_stack_effect/1},
        <<"is_valid">> => {py_native_varargs, fun opcode_predicate/1},
        <<"has_arg">> => {py_native_varargs, fun opcode_predicate/1},
        <<"has_const">> => {py_native_varargs, fun opcode_false_predicate/1},
        <<"has_name">> => {py_native_varargs, fun opcode_false_predicate/1},
        <<"has_jump">> => {py_native_varargs, fun opcode_false_predicate/1},
        <<"has_free">> => {py_native_varargs, fun opcode_false_predicate/1},
        <<"has_local">> => {py_native_varargs, fun opcode_false_predicate/1},
        <<"has_exc">> => {py_native_varargs, fun opcode_false_predicate/1},
        <<"get_intrinsic1_descs">> => {py_native_varargs, fun opcode_intrinsic1_descs/1},
        <<"get_intrinsic2_descs">> => {py_native_varargs, fun opcode_intrinsic2_descs/1},
        <<"get_nb_ops">> => {py_native_varargs, fun opcode_nb_ops/1},
        <<"get_specialization_stats">> => {py_native_varargs, fun opcode_none/1},
        <<"get_executor">> => {py_native_varargs, fun opcode_none/1}
    }};
builtin_module(<<"_imp">>) ->
    {ok, #{
        <<"__name__">> => <<"_imp">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"check_hash_based_pycs">> => <<"default">>,
        <<"acquire_lock">> => fun() -> none end,
        <<"release_lock">> => fun() -> none end,
        <<"lock_held">> => fun() -> false end,
        <<"is_builtin">> => fun(_Name) -> false end,
        <<"is_frozen">> => fun(_Name) -> false end,
        <<"is_frozen_package">> => fun(_Name) -> false end,
        <<"find_frozen">> => fun(_Name) -> none end,
        <<"get_frozen_object">> => fun imp_missing_frozen/1,
        <<"create_builtin">> => fun(_Spec) -> none end,
        <<"exec_builtin">> => fun(_Module) -> none end,
        <<"create_dynamic">> => fun(_Spec) -> none end,
        <<"exec_dynamic">> => fun(_Module) -> none end,
        <<"extension_suffixes">> => fun() -> pyrlang_heap:list([]) end,
        <<"source_hash">> => fun imp_source_hash/2,
        <<"_fix_co_filename">> => fun(_Code, _Filename) -> none end,
        <<"_override_multi_interp_extensions_check">> => fun(_Override) -> false end
    }};
builtin_module(<<"_warnings">>) ->
    {ok, #{
        <<"__name__">> => <<"_warnings">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"filters">> => pyrlang_heap:list([]),
        <<"_defaultaction">> => <<"default">>,
        <<"_onceregistry">> => pyrlang_heap:dict([]),
        <<"warn">> => {py_native_varargs, fun warnings_noop/1},
        <<"warn_explicit">> => {py_native_varargs, fun warnings_noop/1},
        <<"_filters_mutated">> => fun() -> none end
    }};
builtin_module(<<"marshal">>) ->
    {ok, #{
        <<"__name__">> => <<"marshal">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"version">> => 5,
        <<"dumps">> => {py_native_varargs, fun marshal_dumps/1},
        <<"loads">> => {py_native_varargs, fun marshal_loads/1},
        <<"dump">> => {py_native_varargs, fun marshal_dump/1},
        <<"load">> => {py_native_varargs, fun marshal_load/1}
    }};
builtin_module(<<"_struct">>) ->
    {ok, struct_env()};
builtin_module(<<"binascii">>) ->
    {ok, binascii_env()};
builtin_module(<<"_string">>) ->
    {ok, #{
        <<"__name__">> => <<"_string">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"formatter_parser">> => {py_native_varargs, fun string_formatter_parser/1},
        <<"formatter_field_name_split">> =>
            {py_native_varargs, fun string_formatter_field_name_split/1}
    }};
builtin_module(<<"_codecs">>) ->
    {ok, #{
        <<"__name__">> => <<"_codecs">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"lookup">> => fun codecs_lookup/1,
        <<"register">> => fun codecs_register/1,
        <<"unregister">> => fun codecs_unregister/1,
        <<"lookup_error">> => fun codecs_lookup_error/1,
        <<"register_error">> => fun codecs_register_error/2,
        <<"encode">> => {py_native_call, fun codecs_encode/2},
        <<"decode">> => {py_native_call, fun codecs_decode/2},
        <<"utf_8_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"utf_8_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_7_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"utf_7_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_16_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"utf_16_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_16_ex_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_16_le_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"utf_16_le_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_16_be_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"utf_16_be_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_32_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"utf_32_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_32_ex_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_32_le_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"utf_32_le_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"utf_32_be_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"utf_32_be_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"latin_1_encode">> => {py_native_varargs, fun codecs_latin1_encode/1},
        <<"latin_1_decode">> => {py_native_varargs, fun codecs_latin1_decode/1},
        <<"ascii_encode">> => {py_native_varargs, fun codecs_ascii_encode/1},
        <<"ascii_decode">> => {py_native_varargs, fun codecs_ascii_decode/1},
        <<"unicode_escape_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"unicode_escape_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"raw_unicode_escape_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"raw_unicode_escape_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"escape_encode">> => {py_native_varargs, fun codecs_passthrough_tuple/1},
        <<"escape_decode">> => {py_native_varargs, fun codecs_passthrough_tuple/1},
        <<"charmap_encode">> => {py_native_varargs, fun codecs_utf8_encode/1},
        <<"charmap_decode">> => {py_native_varargs, fun codecs_utf8_decode/1},
        <<"charmap_build">> => fun codecs_charmap_build/1,
        <<"readbuffer_encode">> => {py_native_varargs, fun codecs_readbuffer_encode/1}
    }};
builtin_module(<<"_tokenize">>) ->
    {ok, #{
        <<"__name__">> => <<"_tokenize">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"TokenizerIter">> => {py_native_call, fun tokenizer_iter_new/2}
    }};
builtin_module(<<"_io">>) ->
    IOBase = io_class(<<"_IOBase">>),
    RawIOBase = io_class(<<"_RawIOBase">>),
    BufferedIOBase = io_class(<<"_BufferedIOBase">>),
    TextIOBase = io_class(<<"_TextIOBase">>),
    FileIO = io_class(<<"FileIO">>),
    BytesIO = io_class(<<"BytesIO">>),
    StringIO = io_class(<<"StringIO">>),
    BufferedReader = io_class(<<"BufferedReader">>),
    BufferedWriter = io_class(<<"BufferedWriter">>),
    BufferedRWPair = io_class(<<"BufferedRWPair">>),
    BufferedRandom = io_class(<<"BufferedRandom">>),
    IncrementalNewlineDecoder = io_class(<<"IncrementalNewlineDecoder">>),
    TextIOWrapper = io_class(<<"TextIOWrapper">>),
    {ok, #{
        <<"__name__">> => <<"_io">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"DEFAULT_BUFFER_SIZE">> => 8192,
        <<"SEEK_SET">> => 0,
        <<"SEEK_CUR">> => 1,
        <<"SEEK_END">> => 2,
        <<"BlockingIOError">> => pyrlang_exception:type(<<"BlockingIOError">>),
        <<"UnsupportedOperation">> => pyrlang_exception:type(<<"UnsupportedOperation">>),
        <<"open">> => {py_native_varargs, fun pyrlang_builtins:open/1},
        <<"open_code">> => {py_native_varargs, fun io_open_code/1},
        <<"text_encoding">> => {py_native_varargs, fun io_text_encoding/1},
        <<"_IOBase">> => IOBase,
        <<"_RawIOBase">> => RawIOBase,
        <<"_BufferedIOBase">> => BufferedIOBase,
        <<"_TextIOBase">> => TextIOBase,
        <<"FileIO">> => FileIO,
        <<"BytesIO">> => BytesIO,
        <<"StringIO">> => StringIO,
        <<"BufferedReader">> => BufferedReader,
        <<"BufferedWriter">> => BufferedWriter,
        <<"BufferedRWPair">> => BufferedRWPair,
        <<"BufferedRandom">> => BufferedRandom,
        <<"IncrementalNewlineDecoder">> => IncrementalNewlineDecoder,
        <<"TextIOWrapper">> => TextIOWrapper
    }};
builtin_module(<<"sys">>) ->
    Stdout = sys_stream(<<"stdout">>, standard_io),
    Stderr = sys_stream(<<"stderr">>, standard_error),
    Stdin = sys_stream(<<"stdin">>, standard_io),
    {ok, #{
        <<"__name__">> => <<"sys">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"argv">> => pyrlang_heap:list(argv()),
        <<"stdout">> => Stdout,
        <<"stderr">> => Stderr,
        <<"stdin">> => Stdin,
        <<"__stdout__">> => Stdout,
        <<"__stderr__">> => Stderr,
        <<"__stdin__">> => Stdin,
        <<"warnoptions">> => pyrlang_heap:list([]),
        <<"modules">> => sys_modules(),
        <<"path">> => pyrlang_heap:list([unicode:characters_to_binary(Path) || Path <- path()]),
        <<"meta_path">> => pyrlang_heap:list([]),
        <<"path_hooks">> => pyrlang_heap:list([]),
        <<"path_importer_cache">> => pyrlang_heap:dict([]),
        <<"implementation">> => native_instance(<<"Implementation">>, #{
            <<"name">> => <<"pyrlang">>,
            <<"cache_tag">> => <<"pyrlang-313">>
        }),
        <<"flags">> => native_instance(<<"flags">>, #{
            <<"verbose">> => 0,
            <<"ignore_environment">> => false,
            <<"optimize">> => 0
        }),
        <<"maxsize">> => 9223372036854775807,
        <<"byteorder">> => <<"little">>,
        <<"platform">> => <<"darwin">>,
        <<"version">> => <<"3.13.0 (#pyrlang, Jan  1 2026, 00:00:00) [Pyrlang]">>,
        <<"version_info">> => {3, 13, 0, <<"final">>, 0},
        <<"builtin_module_names">> => builtin_module_names(),
        <<"pycache_prefix">> => none,
        <<"dont_write_bytecode">> => true,
        <<"_stdlib_dir">> => default_stdlib_dir(),
        <<"abiflags">> => <<>>,
        <<"platlibdir">> => <<"lib">>,
        <<"_framework">> => false,
        <<"float_info">> => native_instance(<<"float_info">>, #{
            <<"max">> => 1.7976931348623157e308,
            <<"max_exp">> => 1024,
            <<"max_10_exp">> => 308,
            <<"min">> => 2.2250738585072014e-308,
            <<"min_exp">> => -1021,
            <<"min_10_exp">> => -307,
            <<"dig">> => 15,
            <<"mant_dig">> => 53,
            <<"epsilon">> => 2.220446049250313e-16,
            <<"radix">> => 2,
            <<"rounds">> => 1
        }),
        <<"hash_info">> => native_instance(<<"hash_info">>, #{
            <<"width">> => 64,
            <<"modulus">> => 2305843009213693951,
            <<"inf">> => 314159,
            <<"nan">> => 0,
            <<"imag">> => 1000003,
            <<"algorithm">> => <<"siphash13">>,
            <<"hash_bits">> => 64,
            <<"seed_bits">> => 128,
            <<"cutoff">> => 0
        }),
        <<"prefix">> => <<"/usr/local">>,
        <<"base_prefix">> => <<"/usr/local">>,
        <<"exec_prefix">> => <<"/usr/local">>,
        <<"base_exec_prefix">> => <<"/usr/local">>,
        <<"executable">> => <<"pyrlang">>,
        <<"_base_executable">> => <<"pyrlang">>,
        <<"_home">> => none,
        <<"audit">> => {py_native_varargs, fun sys_audit/1},
        <<"exit">> => {py_native_varargs, fun sys_exit/1},
        <<"intern">> => {py_native_varargs, fun sys_intern/1},
        <<"getfilesystemencoding">> => {py_native_varargs, fun sys_getfilesystemencoding/1},
        <<"getfilesystemencodeerrors">> => {py_native_varargs, fun sys_getfilesystemencodeerrors/1},
        <<"getrecursionlimit">> => {py_native_varargs, fun sys_getrecursionlimit/1},
        <<"setrecursionlimit">> => {py_native_varargs, fun sys_setrecursionlimit/1},
        <<"_getframe">> => {py_native_varargs, fun sys_getframe/1},
        <<"_getframemodulename">> => {py_native_varargs, fun sys_getframemodulename/1},
        <<"exc_info">> => fun() -> pyrlang_eval:current_exception_info() end
    }};
builtin_module(<<"getpass">>) ->
    {ok, #{
        <<"__name__">> => <<"getpass">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"getpass">> => {py_native_varargs, fun getpass_getpass/1},
        <<"getuser">> => {py_native_varargs, fun getpass_getuser/1},
        <<"GetPassWarning">> => pyrlang_exception:type(<<"GetPassWarning">>)
    }};
builtin_module(<<"sysconfig">>) ->
    {ok, sysconfig_env()};
builtin_module(<<"pkgutil">>) ->
    {ok, #{
        <<"__name__">> => <<"pkgutil">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"iter_modules">> => {py_native_varargs, fun pkgutil_iter_modules/1},
        <<"walk_packages">> => {py_native_varargs, fun pkgutil_walk_packages/1}
    }};
builtin_module(<<"functools">>) ->
    {ok, #{
        <<"__name__">> => <<"functools">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"__all__">> =>
            {<<"update_wrapper">>, <<"wraps">>, <<"WRAPPER_ASSIGNMENTS">>, <<"WRAPPER_UPDATES">>,
                <<"total_ordering">>, <<"cache">>, <<"lru_cache">>, <<"reduce">>, <<"partial">>,
                <<"partialmethod">>, <<"cached_property">>, <<"singledispatch">>},
        <<"WRAPPER_ASSIGNMENTS">> => functools_wrapper_assignments(),
        <<"WRAPPER_UPDATES">> => {<<"__dict__">>},
        <<"cache">> => fun functools_cache/1,
        <<"cached_property">> => fun functools_cached_property/1,
        <<"lru_cache">> => {py_native_call, fun functools_lru_cache/2},
        <<"_lru_cache_wrapper">> => {py_native_varargs, fun functools_lru_cache_wrapper/1},
        <<"partial">> => {py_native_call, fun functools_partial/2},
        <<"partialmethod">> => {py_native_call, fun functools_partialmethod/2},
        <<"reduce">> => {py_native_varargs, fun functools_reduce/1},
        <<"singledispatch">> => {py_native_call, fun functools_singledispatch/2},
        <<"_unwrap_partial">> => fun functools_unwrap_partial/1,
        <<"_unwrap_partialmethod">> => fun functools_unwrap_partialmethod/1,
        <<"total_ordering">> => fun functools_total_ordering/1,
        <<"update_wrapper">> => {py_native_call, fun functools_update_wrapper/2},
        <<"wraps">> => {py_native_call, fun functools_wraps/2}
    }};
builtin_module(<<"subprocess">>) ->
    {ok, #{
        <<"__name__">> => <<"subprocess">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"PIPE">> => -1,
        <<"STDOUT">> => -2,
        <<"DEVNULL">> => -3,
        <<"SubprocessError">> => pyrlang_exception:type(<<"SubprocessError">>),
        <<"CalledProcessError">> => pyrlang_exception:type(<<"CalledProcessError">>),
        <<"TimeoutExpired">> => pyrlang_exception:type(<<"TimeoutExpired">>),
        <<"CompletedProcess">> => {py_native_call, fun subprocess_completed_process_new/2},
        <<"run">> => {py_native_call, fun subprocess_run/2}
    }};
builtin_module(<<"copy">>) ->
    {ok, #{
        <<"__name__">> => <<"copy">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"copy">> => fun copy_copy/1,
        <<"deepcopy">> => {py_native_varargs, fun copy_deepcopy/1}
    }};
builtin_module(<<"itertools">>) ->
    {ok, #{
        <<"__name__">> => <<"itertools">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"chain">> => itertools_chain_callable(),
        <<"accumulate">> => {py_native_varargs, fun itertools_accumulate/1},
        <<"count">> => {py_native_varargs, fun itertools_count/1},
        <<"cycle">> => {py_native_varargs, fun itertools_cycle/1},
        <<"groupby">> => {py_native_varargs, fun itertools_groupby/1},
        <<"islice">> => {py_native_varargs, fun itertools_islice/1},
        <<"permutations">> => {py_native_varargs, fun itertools_permutations/1},
        <<"product">> => {py_native_varargs, fun itertools_product/1},
        <<"repeat">> => {py_native_varargs, fun itertools_repeat/1},
        <<"starmap">> => fun itertools_starmap/2,
        <<"takewhile">> => fun itertools_takewhile/2,
        <<"tee">> => {py_native_varargs, fun itertools_tee/1},
        <<"zip_longest">> => {py_native_call, fun itertools_zip_longest/2}
    }};
builtin_module(<<"_collections">>) ->
    {ok, #{
        <<"__name__">> => <<"_collections">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"_tuplegetter">> => {py_native_varargs, fun collections_tuplegetter/1},
        <<"OrderedDict">> => maps:get(<<"dict">>, pyrlang_builtins:env()),
        <<"defaultdict">> => {py_native_call, fun collections_defaultdict_new/2},
        <<"deque">> => {py_native_call, fun collections_deque_new/2}
    }};
builtin_module(<<"collections.abc">>) ->
    Module = load(<<"_collections_abc">>),
    {ok, (env(Module))#{
        <<"__name__">> => <<"collections.abc">>,
        <<"__package__">> => <<"collections">>
    }};
builtin_module(<<"operator">>) ->
    {ok, #{
        <<"__name__">> => <<"operator">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"attrgetter">> => {py_native_varargs, fun operator_attrgetter/1},
        <<"itemgetter">> => {py_native_varargs, fun operator_itemgetter/1},
        <<"methodcaller">> => {py_native_call, fun operator_methodcaller/2},
        <<"eq">> => fun operator_eq/2,
        <<"ne">> => fun operator_ne/2,
        <<"lt">> => fun operator_lt/2,
        <<"le">> => fun operator_le/2,
        <<"gt">> => fun operator_gt/2,
        <<"ge">> => fun operator_ge/2,
        <<"add">> => fun operator_add/2,
        <<"sub">> => fun operator_sub/2,
        <<"mul">> => fun operator_mul/2,
        <<"truediv">> => fun operator_truediv/2,
        <<"floordiv">> => fun operator_floordiv/2,
        <<"mod">> => fun operator_mod/2,
        <<"pow">> => fun operator_pow/2,
        <<"neg">> => fun operator_neg/1,
        <<"pos">> => fun operator_pos/1,
        <<"abs">> => fun operator_abs/1,
        <<"and_">> => fun operator_and/2,
        <<"or_">> => fun operator_or/2,
        <<"xor">> => fun operator_xor/2,
        <<"invert">> => fun operator_invert/1,
        <<"lshift">> => fun operator_lshift/2,
        <<"rshift">> => fun operator_rshift/2,
        <<"index">> => fun operator_index/1,
        <<"getitem">> => fun operator_getitem/2,
        <<"setitem">> => fun operator_setitem/3,
        <<"delitem">> => fun operator_delitem/2,
        <<"contains">> => fun operator_contains/2
    }};
builtin_module(<<"bisect">>) ->
    {ok, #{
        <<"__name__">> => <<"bisect">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"bisect">> => {py_native_varargs, fun bisect_right/1},
        <<"bisect_right">> => {py_native_varargs, fun bisect_right/1},
        <<"bisect_left">> => {py_native_varargs, fun bisect_left/1},
        <<"insort">> => {py_native_varargs, fun insort_right/1},
        <<"insort_right">> => {py_native_varargs, fun insort_right/1},
        <<"insort_left">> => {py_native_varargs, fun insort_left/1}
    }};
builtin_module(<<"re">>) ->
    {ok, #{
        <<"__name__">> => <<"re">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"match">> => {py_native_varargs, fun re_match_args/1},
        <<"search">> => {py_native_varargs, fun re_search_args/1},
        <<"fullmatch">> => {py_native_varargs, fun re_fullmatch_args/1},
        <<"findall">> => {py_native_varargs, fun re_findall_args/1},
        <<"finditer">> => {py_native_varargs, fun re_finditer_args/1},
        <<"split">> => {py_native_varargs, fun re_split_args/1},
        <<"sub">> => {py_native_varargs, fun re_sub_args/1},
        <<"escape">> => fun re_escape/1,
        <<"compile">> => {py_native_varargs, fun re_compile_args/1},
        <<"ASCII">> => 256,
        <<"A">> => 256,
        <<"VERBOSE">> => 64,
        <<"X">> => 64,
        <<"DOTALL">> => 16,
        <<"S">> => 16,
        <<"IGNORECASE">> => 2,
        <<"I">> => 2,
        <<"MULTILINE">> => 8,
        <<"M">> => 8,
        <<"NOFLAG">> => 0
    }};
builtin_module(<<"gc">>) ->
    {ok, #{
        <<"__name__">> => <<"gc">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"collect">> => {py_native_varargs, fun(_Args) -> 0 end},
        <<"enable">> => fun() -> none end,
        <<"disable">> => fun() -> none end,
        <<"isenabled">> => fun() -> true end,
        <<"get_count">> => fun() -> {0, 0, 0} end
    }};
builtin_module(<<"hashlib">>) ->
    {ok, #{
        <<"__name__">> => <<"hashlib">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"sha1">> =>
            {py_native_call, fun(Args, KwArgs) -> hash_new(sha, Args, KwArgs) end, no_bind},
        <<"sha224">> =>
            {py_native_call, fun(Args, KwArgs) -> hash_new(sha224, Args, KwArgs) end, no_bind},
        <<"sha256">> =>
            {py_native_call, fun(Args, KwArgs) -> hash_new(sha256, Args, KwArgs) end, no_bind},
        <<"sha384">> =>
            {py_native_call, fun(Args, KwArgs) -> hash_new(sha384, Args, KwArgs) end, no_bind},
        <<"sha512">> =>
            {py_native_call, fun(Args, KwArgs) -> hash_new(sha512, Args, KwArgs) end, no_bind},
        <<"md5">> =>
            {py_native_call, fun(Args, KwArgs) -> hash_new(md5, Args, KwArgs) end, no_bind},
        <<"pbkdf2_hmac">> => {py_native_call, fun hash_pbkdf2_hmac/2, no_bind}
    }};
builtin_module(<<"hmac">>) ->
    {ok, #{
        <<"__name__">> => <<"hmac">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"new">> => {py_native_call, fun hmac_new/2},
        <<"compare_digest">> => fun compare_digest/2
    }};
builtin_module(<<"zlib">>) ->
    {ok, zlib_env()};
builtin_module(<<"gzip">>) ->
    {ok, gzip_env()};
builtin_module(<<"secrets">>) ->
    {ok, #{
        <<"__name__">> => <<"secrets">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"compare_digest">> => fun compare_digest/2,
        <<"choice">> => fun secrets_choice/1,
        <<"token_bytes">> => fun secrets_token_bytes/1,
        <<"token_hex">> => fun secrets_token_hex/1
    }};
builtin_module(<<"contextvars">>) ->
    {ok, #{
        <<"__name__">> => <<"contextvars">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"ContextVar">> => {py_native_call, fun contextvar_new/2}
    }};
builtin_module(<<"array">>) ->
    {ok, #{
        <<"__name__">> => <<"array">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"array">> => {py_native_call, fun array_new/2}
    }};
builtin_module(<<"types">>) ->
    {ok, #{
        <<"__name__">> => <<"types">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"MethodType">> => {py_native_varargs, fun types_method_type/1},
        <<"FunctionType">> => pyrlang_builtins:function_type(),
        <<"LambdaType">> => pyrlang_builtins:function_type(),
        <<"BuiltinFunctionType">> => pyrlang_builtins:builtin_function_type(),
        <<"BuiltinMethodType">> => pyrlang_builtins:builtin_function_type(),
        <<"CodeType">> => pyrlang_builtins:code_type(),
        <<"ModuleType">> => pyrlang_builtins:module_type(),
        <<"SimpleNamespace">> => pyrlang_builtins:simple_namespace_type(),
        <<"CellType">> => pyrlang_builtins:cell_type(),
        <<"GeneratorType">> => pyrlang_builtins:generator_type(),
        <<"CoroutineType">> => pyrlang_builtins:coroutine_type(),
        <<"AsyncGeneratorType">> => pyrlang_builtins:async_generator_type(),
        <<"TracebackType">> => pyrlang_builtins:traceback_type(),
        <<"FrameType">> => pyrlang_builtins:frame_type(),
        <<"WrapperDescriptorType">> => pyrlang_builtins:wrapper_descriptor_type(),
        <<"MethodWrapperType">> => pyrlang_builtins:method_wrapper_type(),
        <<"MethodDescriptorType">> => pyrlang_builtins:method_descriptor_type(),
        <<"ClassMethodDescriptorType">> => pyrlang_builtins:classmethod_descriptor_type(),
        <<"GetSetDescriptorType">> => pyrlang_builtins:getset_descriptor_type(),
        <<"MemberDescriptorType">> => pyrlang_builtins:member_descriptor_type(),
        <<"MappingProxyType">> => types_mapping_proxy_type(),
        <<"DynamicClassAttribute">> => maps:get(<<"property">>, pyrlang_builtins:env()),
        <<"GenericAlias">> => pyrlang_builtins:generic_alias_type(),
        <<"UnionType">> => pyrlang_builtins:union_type(),
        <<"NoneType">> => pyrlang_builtins:none_type(),
        <<"EllipsisType">> => pyrlang_builtins:ellipsis_type(),
        <<"NotImplementedType">> => pyrlang_builtins:not_implemented_type(),
        <<"coroutine">> => fun types_coroutine/1
    }};
builtin_module(<<"_abc">>) ->
    {ok, #{
        <<"__name__">> => <<"_abc">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"get_cache_token">> => fun abc_get_cache_token/0,
        <<"_abc_init">> => fun abc_init/1,
        <<"_abc_register">> => fun abc_register/2,
        <<"_abc_instancecheck">> => fun abc_instancecheck/2,
        <<"_abc_subclasscheck">> => fun abc_subclasscheck/2,
        <<"_get_dump">> => fun abc_get_dump/1,
        <<"_reset_registry">> => fun abc_reset_registry/1,
        <<"_reset_caches">> => fun abc_reset_caches/1
    }};
builtin_module(<<"_ast">>) ->
    {ok, ast_env()};
builtin_module(<<"_weakref">>) ->
    ReferenceType = weakref_reference_type(),
    ProxyType = pyrlang_object:new_class(<<"ProxyType">>, [], #{}),
    CallableProxyType = pyrlang_object:new_class(<<"CallableProxyType">>, [], #{}),
    {ok, #{
        <<"__name__">> => <<"_weakref">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"getweakrefcount">> => fun weakref_getweakrefcount/1,
        <<"getweakrefs">> => fun weakref_getweakrefs/1,
        <<"ref">> => ReferenceType,
        <<"proxy">> => {py_native_call, fun weakref_proxy_new/2},
        <<"finalize">> => {py_native_call, fun weakref_finalize_new/2},
        <<"ReferenceType">> => ReferenceType,
        <<"ProxyType">> => ProxyType,
        <<"CallableProxyType">> => CallableProxyType,
        <<"_remove_dead_weakref">> => fun weakref_remove_dead/2
    }};
builtin_module(<<"weakref">>) ->
    ReferenceType = weakref_reference_type(),
    ProxyType = pyrlang_object:new_class(<<"ProxyType">>, [], #{}),
    CallableProxyType = pyrlang_object:new_class(<<"CallableProxyType">>, [], #{}),
    {ok, #{
        <<"__name__">> => <<"weakref">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"getweakrefcount">> => fun weakref_getweakrefcount/1,
        <<"getweakrefs">> => fun weakref_getweakrefs/1,
        <<"ref">> => ReferenceType,
        <<"proxy">> => {py_native_call, fun weakref_proxy_new/2},
        <<"finalize">> => {py_native_call, fun weakref_finalize_new/2},
        <<"WeakMethod">> => {py_native_call, fun weakref_ref_new/2},
        <<"ReferenceType">> => ReferenceType,
        <<"ProxyType">> => ProxyType,
        <<"CallableProxyType">> => CallableProxyType,
        <<"ProxyTypes">> => {ProxyType, CallableProxyType},
        <<"_remove_dead_weakref">> => fun weakref_remove_dead/2,
        <<"WeakKeyDictionary">> => {py_native_call, fun weak_dict_new/2},
        <<"WeakValueDictionary">> => {py_native_call, fun weak_dict_new/2},
        <<"WeakSet">> => {py_native_call, fun weak_set_new/2}
    }};
builtin_module(<<"threading">>) ->
    ThreadClass = threading_thread_type(),
    {ok, #{
        <<"__name__">> => <<"threading">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"local">> => threading_local_type(<<"threading">>),
        <<"Thread">> => ThreadClass,
        <<"get_ident">> => fun threading_get_ident/0,
        <<"current_thread">> => fun() -> threading_current_thread(ThreadClass) end,
        <<"_register_atexit">> => {py_native_varargs, fun threading_register_atexit/1},
        <<"Lock">> => {py_native_call, fun threading_lock_new/2},
        <<"RLock">> => {py_native_call, fun threading_lock_new/2},
        <<"Semaphore">> => {py_native_call, fun threading_semaphore_new/2},
        <<"BoundedSemaphore">> => {py_native_call, fun threading_semaphore_new/2},
        <<"Event">> => {py_native_call, fun threading_event_new/2}
    }};
builtin_module(<<"_thread">>) ->
    {ok, #{
        <<"__name__">> => <<"_thread">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"allocate_lock">> => fun threading_lock_instance/0,
        <<"LockType">> => {py_native_call, fun threading_lock_new/2},
        <<"RLock">> => {py_native_call, fun threading_lock_new/2},
        <<"get_ident">> => fun threading_get_ident/0,
        <<"get_native_id">> => fun threading_get_ident/0,
        <<"_get_main_thread_ident">> => fun threading_get_ident/0,
        <<"_is_main_interpreter">> => fun() -> true end,
        <<"daemon_threads_allowed">> => fun() -> true end,
        <<"_shutdown">> => fun() -> none end,
        <<"_make_thread_handle">> => fun thread_handle_instance/0,
        <<"_ThreadHandle">> => {py_native_call, fun thread_handle_new/2},
        <<"start_new_thread">> => {py_native_varargs, fun thread_start_new_thread/1},
        <<"start_joinable_thread">> => {py_native_varargs, fun thread_start_joinable_thread/1},
        <<"stack_size">> => {py_native_varargs, fun thread_stack_size/1},
        <<"_local">> => threading_local_type(<<"_thread">>),
        <<"TIMEOUT_MAX">> => 4294967,
        <<"error">> => pyrlang_exception:type(<<"ThreadError">>)
    }};
builtin_module(<<"time">>) ->
    {ok, #{
        <<"__name__">> => <<"time">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"time">> => fun time_time/0,
        <<"monotonic">> => fun time_monotonic/0,
        <<"perf_counter">> => fun time_monotonic/0,
        <<"process_time">> => fun time_monotonic/0,
        <<"sleep">> => {py_native_varargs, fun time_sleep/1},
        <<"gmtime">> => {py_native_varargs, fun time_gmtime/1},
        <<"localtime">> => {py_native_varargs, fun time_localtime/1},
        <<"mktime">> => fun time_mktime/1,
        <<"strftime">> => {py_native_varargs, fun time_strftime/1},
        <<"tzset">> => fun() -> none end,
        <<"timezone">> => 0,
        <<"altzone">> => 0,
        <<"daylight">> => 0,
        <<"tzname">> => {<<"UTC">>, <<"UTC">>}
    }};
builtin_module(<<"_frozen_importlib">>) ->
    {ok, frozen_importlib_alias_env(<<"_frozen_importlib">>, <<"importlib._bootstrap">>)};
builtin_module(<<"_frozen_importlib_external">>) ->
    {ok,
        frozen_importlib_alias_env(
            <<"_frozen_importlib_external">>, <<"importlib._bootstrap_external">>
        )};
builtin_module(<<"importlib">>) ->
    {ok, #{
        <<"__name__">> => <<"importlib">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => builtin,
        <<"import_module">> => {py_native_call, fun importlib_import_module/2},
        <<"reload">> => {py_native_varargs, fun importlib_reload/1}
    }};
builtin_module(<<"datetime">>) ->
    Timedelta = timedelta_type(),
    TzInfo = tzinfo_type(),
    Timezone = timezone_type(TzInfo, Timedelta),
    Utc = timezone_value(Timezone, timedelta_value(Timedelta, 0), <<"UTC">>),
    ok = pyrlang_object:set_class_attr(Timezone, <<"utc">>, Utc),
    {ok, #{
        <<"__name__">> => <<"datetime">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"datetime">> => datetime_type(),
        <<"date">> => date_type(),
        <<"time">> => time_type(),
        <<"timedelta">> => Timedelta,
        <<"timezone">> => Timezone,
        <<"tzinfo">> => TzInfo
    }};
builtin_module(<<"decimal">>) ->
    {ok, #{
        <<"__name__">> => <<"decimal">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"ROUND_CEILING">> => <<"ROUND_CEILING">>,
        <<"ROUND_DOWN">> => <<"ROUND_DOWN">>,
        <<"ROUND_FLOOR">> => <<"ROUND_FLOOR">>,
        <<"ROUND_HALF_DOWN">> => <<"ROUND_HALF_DOWN">>,
        <<"ROUND_HALF_EVEN">> => <<"ROUND_HALF_EVEN">>,
        <<"ROUND_HALF_UP">> => <<"ROUND_HALF_UP">>,
        <<"ROUND_UP">> => <<"ROUND_UP">>,
        <<"DecimalException">> => pyrlang_exception:type(<<"DecimalException">>),
        <<"InvalidOperation">> => pyrlang_exception:type(<<"InvalidOperation">>),
        <<"Rounded">> => pyrlang_exception:type(<<"Rounded">>),
        <<"Context">> => {py_native_call, fun decimal_context_new/2},
        <<"Decimal">> => {py_native_call, fun decimal_new/2},
        <<"getcontext">> => {py_native_varargs, fun decimal_getcontext/1}
    }};
builtin_module(<<"psycopg2">>) ->
    {ok, psycopg2_env(<<"psycopg2">>)};
builtin_module(<<"psycopg2.extensions">>) ->
    {ok, psycopg2_extensions_env()};
builtin_module(<<"psycopg2.extras">>) ->
    {ok, psycopg2_extras_env()};
builtin_module(<<"psycopg2.errors">>) ->
    {ok, psycopg2_errors_env()};
builtin_module(<<"psycopg2.sql">>) ->
    {ok, psycopg2_sql_env()};
builtin_module(<<"sqlite3">>) ->
    {ok, sqlite3_env(<<"sqlite3">>)};
builtin_module(<<"sqlite3.dbapi2">>) ->
    {ok, sqlite3_env(<<"sqlite3.dbapi2">>)};
builtin_module(<<"_sqlite3">>) ->
    {ok, sqlite3_env(<<"_sqlite3">>)};
builtin_module(<<"logging">>) ->
    {ok, logging_env()};
builtin_module(<<"logging.config">>) ->
    {ok, #{
        <<"__name__">> => <<"logging.config">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"logging">>,
        <<"__path__">> => none,
        <<"DEFAULT_LOGGING_CONFIG_PORT">> => 9030,
        <<"dictConfig">> => {py_native_varargs, fun logging_config_noop/1},
        <<"fileConfig">> => {py_native_varargs, fun logging_config_noop/1},
        <<"listen">> => {py_native_varargs, fun logging_config_listen/1},
        <<"stopListening">> => {py_native_varargs, fun logging_config_noop/1}
    }};
builtin_module(<<"logging.handlers">>) ->
    {ok, logging_handlers_env()};
builtin_module(<<"pathlib">>) ->
    PurePath = pathlib_purepath_class(),
    Path = pathlib_path_class(),
    {ok, #{
        <<"__name__">> => <<"pathlib">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"PurePath">> => PurePath,
        <<"PurePosixPath">> => PurePath,
        <<"PureWindowsPath">> => PurePath,
        <<"Path">> => Path,
        <<"PosixPath">> => Path,
        <<"WindowsPath">> => Path
    }};
builtin_module(<<"http">>) ->
    {ok, #{
        <<"__name__">> => <<"http">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => builtin,
        <<"__all__">> => pyrlang_heap:list([<<"HTTPStatus">>, <<"HTTPMethod">>]),
        <<"HTTPStatus">> => http_status_class(),
        <<"HTTPMethod">> => http_method_class()
    }};
builtin_module(<<"http.cookies">>) ->
    {ok, #{
        <<"__name__">> => <<"http.cookies">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"http">>,
        <<"__path__">> => none,
        <<"_unquote">> => fun cookie_unquote/1,
        <<"SimpleCookie">> => {py_native_call, fun simple_cookie_new/2}
    }};
builtin_module(<<"urllib">>) ->
    {ok, #{
        <<"__name__">> => <<"urllib">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => builtin
    }};
builtin_module(<<"urllib.parse">>) ->
    {ok, #{
        <<"__name__">> => <<"urllib.parse">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"urllib">>,
        <<"__path__">> => none,
        <<"quote">> => {py_native_call, fun url_quote/2},
        <<"quote_plus">> => {py_native_call, fun url_quote_plus/2},
        <<"unquote">> => {py_native_call, fun url_unquote/2},
        <<"unquote_plus">> => {py_native_call, fun url_unquote_plus/2},
        <<"urlencode">> => {py_native_call, fun url_urlencode/2},
        <<"parse_qs">> => {py_native_call, fun url_parse_qs/2},
        <<"parse_qsl">> => {py_native_call, fun url_parse_qsl/2},
        <<"urlsplit">> => {py_native_call, fun url_urlsplit/2},
        <<"urlparse">> => {py_native_call, fun url_urlparse/2},
        <<"urljoin">> => {py_native_call, fun url_urljoin/2},
        <<"urldefrag">> => {py_native_call, fun url_urldefrag/2},
        <<"urlunparse">> => {py_native_call, fun url_urlunparse/2},
        <<"urlunsplit">> => {py_native_call, fun url_urlunsplit/2},
        <<"unwrap">> => fun url_unwrap/1,
        <<"_splittype">> => fun url_splittype/1,
        <<"_splithost">> => fun url_splithost/1,
        <<"_splitport">> => fun url_splitport/1,
        <<"_splituser">> => fun url_splituser/1,
        <<"_splitpasswd">> => fun url_splitpasswd/1,
        <<"_splitattr">> => fun url_splitattr/1,
        <<"_splitquery">> => fun url_splitquery/1,
        <<"_splitvalue">> => fun url_splitvalue/1,
        <<"_splittag">> => fun url_splittag/1,
        <<"_to_bytes">> => fun normalize_name/1,
        <<"unquote_to_bytes">> => {py_native_call, fun url_unquote_to_bytes/2}
    }};
builtin_module(<<"_scproxy">>) ->
    {ok, #{
        <<"__name__">> => <<"_scproxy">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"_get_proxy_settings">> => fun() ->
            pyrlang_heap:dict([{<<"exclude_simple">>, false}, {<<"exceptions">>, {}}])
        end,
        <<"_get_proxies">> => fun() -> pyrlang_heap:dict([]) end
    }};
builtin_module(<<"unicodedata">>) ->
    {ok, #{
        <<"__name__">> => <<"unicodedata">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"unidata_version">> => <<"15.1.0">>,
        <<"normalize">> => fun(_Form, Value) -> normalize_name(Value) end,
        <<"combining">> => fun(_Char) -> 0 end,
        <<"category">> => fun unicode_category/1,
        <<"bidirectional">> => fun(_Char) -> <<>> end,
        <<"east_asian_width">> => fun(_Char) -> <<"N">> end
    }};
builtin_module(<<"email">>) ->
    {ok, #{
        <<"__name__">> => <<"email">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => builtin,
        <<"message_from_bytes">> => {py_native_call, fun email_message_from_bytes/2},
        <<"message_from_string">> => {py_native_call, fun email_message_from_string/2},
        <<"message_from_file">> => {py_native_call, fun email_message_from_file/2},
        <<"message_from_binary_file">> => {py_native_call, fun email_message_from_file/2}
    }};
builtin_module(<<"email.utils">>) ->
    {ok, #{
        <<"__name__">> => <<"email.utils">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"email">>,
        <<"__path__">> => none,
        <<"formatdate">> => {py_native_call, fun email_formatdate_call/2},
        <<"format_datetime">> => {py_native_call, fun email_format_datetime_call/2},
        <<"formataddr">> => {py_native_varargs, fun email_formataddr/1},
        <<"getaddresses">> => {py_native_varargs, fun email_getaddresses/1},
        <<"parseaddr">> => {py_native_varargs, fun email_parseaddr/1},
        <<"make_msgid">> => {py_native_call, fun email_make_msgid/2},
        <<"collapse_rfc2231_value">> => {py_native_varargs, fun email_collapse_rfc2231_value/1},
        <<"_has_surrogates">> => fun(_Value) -> false end
    }};
builtin_module(_Name) ->
    error.

builtin_spawn(Callable) ->
    pyrlang_actor:spawn(fun spawned_py_callable/1, [Callable]).

builtin_spawn_link(Callable) ->
    pyrlang_actor:spawn_link(fun spawned_py_callable/1, [Callable]).

spawned_py_callable(Callable) ->
    pyrlang_eval:call(Callable, []).

builtin_send(Pid, Message) ->
    try
        pyrlang_actor:send(Pid, Message)
    catch
        error:{unsendable, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"TypeError">>), {unsendable, Reason}
                )
            )
    end.

pkgutil_iter_modules([]) ->
    pkgutil_iter_modules([pyrlang_heap:list([unicode:characters_to_binary(Path) || Path <- path()])]);
pkgutil_iter_modules([Paths]) ->
    pkgutil_iter_modules([Paths, <<"">>]);
pkgutil_iter_modules([Paths, Prefix]) ->
    PrefixBin = normalize_name(Prefix),
    pyrlang_heap:list(pkgutil_module_infos(pkgutil_paths(Paths), PrefixBin));
pkgutil_iter_modules(Args) ->
    erlang:error({arity_error, {pkgutil_iter_modules, length(Args)}}).

pkgutil_walk_packages([]) ->
    pkgutil_walk_packages([none, <<"">>, none]);
pkgutil_walk_packages([Paths]) ->
    pkgutil_walk_packages([Paths, <<"">>, none]);
pkgutil_walk_packages([Paths, Prefix]) ->
    pkgutil_walk_packages([Paths, Prefix, none]);
pkgutil_walk_packages([Paths, Prefix, _OnError]) ->
    PrefixBin = normalize_name(Prefix),
    pyrlang_heap:list(pkgutil_walk_module_infos(pkgutil_paths(Paths), PrefixBin, #{}));
pkgutil_walk_packages(Args) ->
    erlang:error({arity_error, {pkgutil_walk_packages, length(Args)}}).

pkgutil_paths(none) ->
    [unicode:characters_to_binary(Path) || Path <- path()];
pkgutil_paths(Paths) ->
    pyrlang_iter:values(Paths).

pkgutil_module_infos(Paths, Prefix) ->
    [Info || {_Name, Info, _PackagePath} <- pkgutil_module_entries(Paths, Prefix)].

pkgutil_walk_module_infos(Paths, Prefix, SeenPaths) ->
    lists:append([
        case {Info, PackagePath} of
            {{_Finder, Name, true}, PackagePathBin} when is_binary(PackagePathBin) ->
                case maps:is_key(PackagePathBin, SeenPaths) of
                    true ->
                        [Info];
                    false ->
                        ChildPrefix = <<Name/binary, ".">>,
                        ChildInfos = pkgutil_walk_module_infos(
                            [PackagePathBin], ChildPrefix, SeenPaths#{PackagePathBin => true}
                        ),
                        [Info | ChildInfos]
                end;
            _ ->
                [Info]
        end
     || {_Name, Info, PackagePath} <- pkgutil_module_entries(Paths, Prefix)
    ]).

pkgutil_module_entries(Paths, Prefix) ->
    {Infos, _Seen} = lists:foldl(
        fun(Path0, {Acc, Seen}) ->
            Path = binary_to_list(normalize_name(Path0)),
            case file:list_dir(Path) of
                {ok, Entries} ->
                    lists:foldl(
                        fun(Entry, {EntryAcc, EntrySeen}) ->
                            case pkgutil_entry_info(Path, Entry, Prefix) of
                                none ->
                                    {EntryAcc, EntrySeen};
                                {Name, Info, PackagePath} ->
                                    case maps:is_key(Name, EntrySeen) of
                                        true ->
                                            {EntryAcc, EntrySeen};
                                        false ->
                                            {[{Name, Info, PackagePath} | EntryAcc], EntrySeen#{
                                                Name => true
                                            }}
                                    end
                            end
                        end,
                        {Acc, Seen},
                        Entries
                    );
                _ ->
                    {Acc, Seen}
            end
        end,
        {[], #{}},
        Paths
    ),
    lists:reverse(Infos).

pkgutil_entry_info(Dir, Entry, Prefix) ->
    Path = filename:join(Dir, Entry),
    case filelib:is_dir(Path) of
        true ->
            case
                filelib:is_regular(filename:join(Path, "__init__.py")) orelse
                    filelib:is_regular(filename:join(Path, "__init__.pyr"))
            of
                true ->
                    Name = <<Prefix/binary, (unicode:characters_to_binary(Entry))/binary>>,
                    {Name, {none, Name, true}, unicode:characters_to_binary(Path)};
                false ->
                    none
            end;
        false ->
            case pkgutil_module_file_name(Entry) of
                none ->
                    none;
                <<"__init__">> ->
                    none;
                ModuleName ->
                    Name = <<Prefix/binary, ModuleName/binary>>,
                    {Name, {none, Name, false}, none}
            end
    end.

pkgutil_module_file_name(Entry) ->
    case filename:extension(Entry) of
        ".py" -> unicode:characters_to_binary(filename:rootname(Entry));
        ".pyr" -> unicode:characters_to_binary(filename:rootname(Entry));
        _ -> none
    end.

builtin_receive([]) ->
    pyrlang_actor:recv();
builtin_receive([Timeout]) ->
    pyrlang_actor:recv(Timeout);
builtin_receive([Timeout, Default]) ->
    pyrlang_actor:recv(Timeout, Default);
builtin_receive(Args) ->
    erlang:error({arity_error, {'receive', length(Args)}}).

builtin_receive_match([Pattern]) ->
    pyrlang_actor:recv_match(Pattern);
builtin_receive_match([Pattern, Timeout]) ->
    pyrlang_actor:recv_match(Pattern, Timeout, timeout);
builtin_receive_match([Pattern, Timeout, Default]) ->
    pyrlang_actor:recv_match(Pattern, Timeout, Default);
builtin_receive_match(Args) ->
    erlang:error({arity_error, {receive_match, length(Args)}}).

builtin_receive_match_bindings([Pattern]) ->
    receive_match_bindings(Pattern, infinity, timeout);
builtin_receive_match_bindings([Pattern, Timeout]) ->
    receive_match_bindings(Pattern, Timeout, timeout);
builtin_receive_match_bindings([Pattern, Timeout, Default]) ->
    receive_match_bindings(Pattern, Timeout, Default);
builtin_receive_match_bindings(Args) ->
    erlang:error({arity_error, {receive_match_bindings, length(Args)}}).

receive_match_bindings(Pattern, Timeout, Default) ->
    case pyrlang_actor:recv_match_bindings(Pattern, Timeout, Default) of
        {ok, Value, Bindings} ->
            {Value, pyrlang_heap:dict(maps:to_list(Bindings))};
        Default ->
            Default
    end.

builtin_sleep(Millis) when is_integer(Millis), Millis >= 0 ->
    timer:sleep(Millis),
    none.

builtin_yield_now() ->
    erlang:yield(),
    none.

time_time() ->
    erlang:system_time(microsecond) / 1000000.0.

time_monotonic() ->
    erlang:monotonic_time(microsecond) / 1000000.0.

time_sleep([]) ->
    none;
time_sleep([Seconds]) ->
    timer:sleep(time_seconds_to_millis(Seconds)),
    none;
time_sleep(Args) ->
    erlang:error({arity_error, {time_sleep, length(Args)}}).

time_seconds_to_millis(Seconds) when is_integer(Seconds), Seconds >= 0 ->
    Seconds * 1000;
time_seconds_to_millis(Seconds) when is_float(Seconds), Seconds >= 0 ->
    trunc(Seconds * 1000);
time_seconds_to_millis(Seconds) ->
    erlang:error({type_error, {time_sleep, Seconds}}).

time_gmtime([]) ->
    time_struct_tuple(calendar:universal_time(), false);
time_gmtime([Seconds]) ->
    time_struct_tuple(time_datetime_from_epoch(Seconds), false);
time_gmtime(Args) ->
    erlang:error({arity_error, {gmtime, length(Args)}}).

time_localtime([]) ->
    time_struct_tuple(calendar:local_time(), true);
time_localtime([Seconds]) ->
    Utc = time_datetime_from_epoch(Seconds),
    time_struct_tuple(calendar:universal_time_to_local_time(Utc), true);
time_localtime(Args) ->
    erlang:error({arity_error, {localtime, length(Args)}}).

time_mktime(TimeTuple) ->
    Seconds = time_tuple_to_seconds(TimeTuple),
    Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    Seconds - Epoch.

time_strftime([Format]) ->
    time_strftime([Format, time_localtime([])]);
time_strftime([Format, TimeTuple]) ->
    time_format(normalize_name(Format), TimeTuple);
time_strftime(Args) ->
    erlang:error({arity_error, {strftime, length(Args)}}).

time_datetime_from_epoch(Seconds0) ->
    Seconds =
        case Seconds0 of
            Int when is_integer(Int) -> Int;
            Float when is_float(Float) -> trunc(Float);
            Other -> erlang:error({type_error, {epoch_seconds, Other}})
        end,
    Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    calendar:gregorian_seconds_to_datetime(Epoch + Seconds).

time_struct_tuple({Date = {Year, Month, Day}, {Hour, Minute, Second}}, IsLocal) ->
    Weekday = calendar:day_of_the_week(Date) - 1,
    Yday =
        calendar:date_to_gregorian_days(Date) - calendar:date_to_gregorian_days({Year, 1, 1}) + 1,
    IsDst =
        case IsLocal of
            true -> -1;
            false -> 0
        end,
    {Year, Month, Day, Hour, Minute, Second, Weekday, Yday, IsDst}.

time_tuple_to_seconds(TimeTuple) ->
    [Year, Month, Day, Hour, Minute, Second | _Rest] = tuple_to_list(TimeTuple),
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, Minute, Second}}).

time_format(Format, TimeTuple) ->
    [Year, Month, Day, Hour, Minute, Second, Weekday, Yday | _Rest] = tuple_to_list(TimeTuple),
    format_time_chars(
        binary_to_list(Format),
        #{
            $A => weekday_name(Weekday),
            $a => weekday_abbr(Weekday),
            $B => month_name(Month),
            $b => month_abbr(Month),
            $Y => integer_to_binary(Year),
            $m => two_digit(Month),
            $d => two_digit(Day),
            $H => two_digit(Hour),
            $M => two_digit(Minute),
            $S => two_digit(Second),
            $w => integer_to_binary((Weekday + 1) rem 7),
            $j => three_digit(Yday),
            $z => <<>>,
            $Z => <<"UTC">>,
            $% => <<"%">>
        },
        []
    ).

format_time_chars([], _Values, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
format_time_chars([$%, Code | Rest], Values, Acc) ->
    format_time_chars(Rest, Values, [maps:get(Code, Values, <<$%, Code>>) | Acc]);
format_time_chars([Char | Rest], Values, Acc) ->
    format_time_chars(Rest, Values, [Char | Acc]).

weekday_name(Index) ->
    lists:nth(Index + 1, [
        <<"Monday">>,
        <<"Tuesday">>,
        <<"Wednesday">>,
        <<"Thursday">>,
        <<"Friday">>,
        <<"Saturday">>,
        <<"Sunday">>
    ]).

weekday_abbr(Index) ->
    lists:nth(Index + 1, [
        <<"Mon">>, <<"Tue">>, <<"Wed">>, <<"Thu">>, <<"Fri">>, <<"Sat">>, <<"Sun">>
    ]).

month_name(Index) ->
    lists:nth(Index, [
        <<"January">>,
        <<"February">>,
        <<"March">>,
        <<"April">>,
        <<"May">>,
        <<"June">>,
        <<"July">>,
        <<"August">>,
        <<"September">>,
        <<"October">>,
        <<"November">>,
        <<"December">>
    ]).

month_abbr(Index) ->
    lists:nth(Index, [
        <<"Jan">>,
        <<"Feb">>,
        <<"Mar">>,
        <<"Apr">>,
        <<"May">>,
        <<"Jun">>,
        <<"Jul">>,
        <<"Aug">>,
        <<"Sep">>,
        <<"Oct">>,
        <<"Nov">>,
        <<"Dec">>
    ]).

two_digit(Value) when Value < 10 ->
    <<$0, (integer_to_binary(Value))/binary>>;
two_digit(Value) ->
    integer_to_binary(Value).

three_digit(Value) when Value < 10 ->
    <<$0, $0, (integer_to_binary(Value))/binary>>;
three_digit(Value) when Value < 100 ->
    <<$0, (integer_to_binary(Value))/binary>>;
three_digit(Value) ->
    integer_to_binary(Value).

functools_wrapper_assignments() ->
    {<<"__module__">>, <<"__name__">>, <<"__qualname__">>, <<"__doc__">>, <<"__annotations__">>,
        <<"__type_params__">>}.

functools_update_wrapper(Args, KwArgs0) ->
    Known = [<<"wrapper">>, <<"wrapped">>, <<"assigned">>, <<"updated">>],
    case maps:keys(maps:without(Known, KwArgs0)) of
        [] -> ok;
        [Unexpected | _] -> erlang:error({type_error, {unexpected_keyword_argument, Unexpected}})
    end,
    {Wrapper, Wrapped, Rest} =
        case Args of
            [Wrapper0, Wrapped0 | Rest0] ->
                {Wrapper0, Wrapped0, Rest0};
            [Wrapper0] ->
                case maps:find(<<"wrapped">>, KwArgs0) of
                    {ok, Wrapped0} ->
                        {Wrapper0, Wrapped0, []};
                    error ->
                        erlang:error(
                            {arity_error,
                                {update_wrapper, missing_required_argument, <<"wrapped">>}}
                        )
                end;
            [] ->
                case {maps:find(<<"wrapper">>, KwArgs0), maps:find(<<"wrapped">>, KwArgs0)} of
                    {{ok, Wrapper0}, {ok, Wrapped0}} -> {Wrapper0, Wrapped0, []};
                    _ -> erlang:error({arity_error, {update_wrapper, missing_required_argument}})
                end
        end,
    Assigned = functools_arg_or_kw(
        Rest, 1, <<"assigned">>, KwArgs0, functools_wrapper_assignments()
    ),
    Updated = functools_arg_or_kw(Rest, 2, <<"updated">>, KwArgs0, {<<"__dict__">>}),
    case length(Rest) > 2 of
        true -> erlang:error({arity_error, {update_wrapper, length(Args)}});
        false -> ok
    end,
    lists:foreach(
        fun(Attr) -> functools_assign_wrapper_attr(Wrapper, Wrapped, normalize_name(Attr)) end,
        pyrlang_iter:values(Assigned)
    ),
    lists:foreach(
        fun(Attr) -> functools_update_wrapper_attr(Wrapper, Wrapped, normalize_name(Attr)) end,
        pyrlang_iter:values(Updated)
    ),
    ok = pyrlang_object:set_attr(Wrapper, <<"__wrapped__">>, Wrapped),
    Wrapper.

functools_arg_or_kw(Rest, Index, Name, KwArgs, Default) ->
    case length(Rest) >= Index of
        true -> lists:nth(Index, Rest);
        false -> maps:get(Name, KwArgs, Default)
    end.

functools_assign_wrapper_attr(Wrapper, Wrapped, Attr) ->
    try pyrlang_object:get_attr(Wrapped, Attr) of
        Value ->
            ok = pyrlang_object:set_attr(Wrapper, Attr, Value)
    catch
        error:{attribute_error, _} ->
            ok;
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> -> ok;
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

functools_update_wrapper_attr(Wrapper, Wrapped, Attr) ->
    try pyrlang_object:get_attr(Wrapper, Attr) of
        Target ->
            Source = functools_wrapped_attr_default(Wrapped, Attr, pyrlang_heap:dict([])),
            try pyrlang_object:get_attr(Target, <<"update">>) of
                Update ->
                    _ = pyrlang_eval:call(Update, [Source]),
                    ok
            catch
                _:_ -> ok
            end
    catch
        _:_ -> ok
    end.

functools_wrapped_attr_default(Wrapped, Attr, Default) ->
    try
        pyrlang_object:get_attr(Wrapped, Attr)
    catch
        error:{attribute_error, _} ->
            Default;
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> -> Default;
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

functools_wraps(Args, KwArgs) ->
    Wrapped =
        case Args of
            [Wrapped0 | _Rest] ->
                Wrapped0;
            [] ->
                case maps:find(<<"wrapped">>, KwArgs) of
                    {ok, Wrapped0} ->
                        Wrapped0;
                    error ->
                        erlang:error(
                            {arity_error, {wraps, missing_required_argument, <<"wrapped">>}}
                        )
                end
        end,
    Rest =
        case Args of
            [_Wrapped0 | Rest0] -> Rest0;
            [] -> []
        end,
    fun(Wrapper) ->
        functools_update_wrapper([Wrapper, Wrapped | Rest], maps:without([<<"wrapped">>], KwArgs))
    end.

functools_cache(Callable) ->
    functools_cached_callable(Callable).

functools_lru_cache([], _KwArgs) ->
    fun functools_cached_callable/1;
functools_lru_cache([Callable], KwArgs) when map_size(KwArgs) =:= 0 ->
    case functools_is_direct_callable(Callable) of
        true -> functools_cached_callable(Callable);
        false -> fun functools_cached_callable/1
    end;
functools_lru_cache(_Args, _KwArgs) ->
    fun functools_cached_callable/1.

functools_lru_cache_wrapper([Callable | _Rest]) ->
    functools_cached_callable(Callable);
functools_lru_cache_wrapper(Args) ->
    erlang:error({arity_error, {'_lru_cache_wrapper', length(Args)}}).

functools_cached_callable(Callable) ->
    CacheKey = {pyrlang_functools_cache, make_ref()},
    StatsKey = {pyrlang_functools_cache_stats, CacheKey},
    erlang:put(CacheKey, #{}),
    erlang:put(StatsKey, #{hits => 0, misses => 0}),
    Attrs = #{
        <<"__wrapped__">> => Callable,
        <<"__module__">> => functools_attr_default(Callable, <<"__module__">>, <<"functools">>),
        <<"__name__">> => functools_attr_default(
            Callable, <<"__name__">>, <<"_lru_cache_wrapper">>
        ),
        <<"__qualname__">> => functools_attr_default(
            Callable, <<"__qualname__">>, <<"_lru_cache_wrapper">>
        ),
        <<"__doc__">> => functools_attr_default(Callable, <<"__doc__">>, none),
        <<"__annotations__">> => functools_attr_default(
            Callable, <<"__annotations__">>, pyrlang_heap:dict([])
        ),
        <<"__call__">> =>
            {py_native_call, fun(Args, KwArgs) ->
                trace_functools_cache(call_start, Callable),
                Key = {functools_cache_key(Args), functools_cache_key(maps:to_list(KwArgs))},
                trace_functools_cache(key_ready, Key),
                Cache = functools_cache_map(CacheKey),
                case maps:find(Key, Cache) of
                    {ok, Value} ->
                        functools_cache_stat(StatsKey, hits),
                        trace_functools_cache(cache_hit, Callable),
                        Value;
                    error ->
                        functools_cache_stat(StatsKey, misses),
                        trace_functools_cache(cache_miss, Callable),
                        Value = pyrlang_eval:call(Callable, {call_args, Args, KwArgs}),
                        trace_functools_cache(call_done, Callable),
                        erlang:put(CacheKey, maps:put(Key, Value, Cache)),
                        trace_functools_cache(store_done, Callable),
                        Value
                end
            end},
        <<"cache_clear">> => fun() ->
            erlang:put(CacheKey, #{}),
            erlang:put(StatsKey, #{hits => 0, misses => 0}),
            none
        end,
        <<"cache_info">> => fun() ->
            Stats = functools_cache_stats(StatsKey),
            native_instance(<<"CacheInfo">>, #{
                <<"hits">> => maps:get(hits, Stats, 0),
                <<"misses">> => maps:get(misses, Stats, 0),
                <<"maxsize">> => none,
                <<"currsize">> => maps:size(functools_cache_map(CacheKey))
            })
        end
    },
    native_instance(functools_lru_cache_wrapper_class(), <<"_lru_cache_wrapper">>, Attrs).

functools_lru_cache_wrapper_class() ->
    Class = native_instance_class(<<"_lru_cache_wrapper">>),
    ok = pyrlang_object:set_attr(Class, <<"__get__">>, fun functools_lru_cache_wrapper_get/3),
    Class.

functools_lru_cache_wrapper_get(Self, none, _Class) ->
    Self;
functools_lru_cache_wrapper_get(Self, Instance, _Class) ->
    {py_bound_method, Self, Instance}.

functools_is_direct_callable({py_function, _Params, _Body, _Env}) ->
    true;
functools_is_direct_callable({py_function, _Params, _Body, _Env, _Mode}) ->
    true;
functools_is_direct_callable({py_function, _Params, _Body, _Env, _Mode, _Owner}) ->
    true;
functools_is_direct_callable({py_bound_method, _Callable, _Self}) ->
    true;
functools_is_direct_callable({py_native_varargs, _Fun}) ->
    true;
functools_is_direct_callable({py_native_call, _Fun}) ->
    true;
functools_is_direct_callable({py_native_callable, _Fun}) ->
    true;
functools_is_direct_callable(Fun) when is_function(Fun) -> true;
functools_is_direct_callable({py_ref, _} = Ref) ->
    try pyrlang_object:get_attr(Ref, <<"__call__">>) of
        _Call -> true
    catch
        _:_ -> false
    end;
functools_is_direct_callable(_Value) ->
    false.

functools_attr_default(Callable, Attr, Default) ->
    try pyrlang_object:get_attr(Callable, Attr) of
        Value -> Value
    catch
        _:_ -> Default
    end.

functools_singledispatch([Func], KwArgs) when map_size(KwArgs) =:= 0 ->
    functools_singledispatch_wrapper(Func);
functools_singledispatch(Args, _KwArgs) ->
    erlang:error({arity_error, {singledispatch, length(Args)}}).

functools_singledispatch_wrapper(Func) ->
    RegistryKey = {pyrlang_functools_singledispatch, make_ref()},
    ObjectClass = maps:get(<<"object">>, pyrlang_builtins:env()),
    erlang:put(RegistryKey, #{ObjectClass => Func}),
    Attrs = #{
        <<"__wrapped__">> => Func,
        <<"__module__">> => functools_attr_default(Func, <<"__module__">>, <<"functools">>),
        <<"__name__">> => functools_attr_default(Func, <<"__name__">>, <<"wrapper">>),
        <<"__qualname__">> => functools_attr_default(Func, <<"__qualname__">>, <<"wrapper">>),
        <<"__doc__">> => functools_attr_default(Func, <<"__doc__">>, none),
        <<"__annotations__">> => functools_attr_default(
            Func, <<"__annotations__">>, pyrlang_heap:dict([])
        ),
        <<"__call__">> =>
            {py_native_call, fun(Args, KwArgs) ->
                functools_singledispatch_call(RegistryKey, Args, KwArgs)
            end},
        <<"dispatch">> => fun(Class) -> functools_singledispatch_dispatch(RegistryKey, Class) end,
        <<"register">> =>
            {py_native_call, fun(Args, KwArgs) ->
                functools_singledispatch_register(RegistryKey, Args, KwArgs)
            end},
        <<"registry">> => pyrlang_heap:dict(maps:to_list(erlang:get(RegistryKey))),
        <<"_clear_cache">> => fun() -> none end
    },
    native_instance(<<"singledispatch">>, Attrs).

functools_singledispatch_call(_RegistryKey, [], _KwArgs) ->
    erlang:error({type_error, {singledispatch, missing_argument}});
functools_singledispatch_call(RegistryKey, [First | _Rest] = Args, KwArgs) ->
    Impl = functools_singledispatch_dispatch(RegistryKey, pyrlang_builtins:object_class(First)),
    pyrlang_eval:call(Impl, {call_args, Args, KwArgs}).

functools_singledispatch_register(RegistryKey, [Class], KwArgs) when map_size(KwArgs) =:= 0 ->
    case is_class_like(Class) of
        true ->
            fun(Func) -> functools_singledispatch_put(RegistryKey, Class, Func) end;
        false ->
            case functools_infer_dispatch_class(Class) of
                {ok, DispatchClass} ->
                    functools_singledispatch_put(RegistryKey, DispatchClass, Class);
                error ->
                    Class
            end
    end;
functools_singledispatch_register(RegistryKey, [Class, Func], KwArgs) when map_size(KwArgs) =:= 0 ->
    case is_class_like(Class) of
        true -> functools_singledispatch_put(RegistryKey, Class, Func);
        false -> erlang:error({type_error, {singledispatch_register, Class}})
    end;
functools_singledispatch_register(_RegistryKey, Args, _KwArgs) ->
    erlang:error({arity_error, {singledispatch_register, length(Args)}}).

functools_singledispatch_put(RegistryKey, Class, Func) ->
    Registry = functools_singledispatch_registry(RegistryKey),
    erlang:put(RegistryKey, maps:put(Class, Func, Registry)),
    Func.

functools_singledispatch_dispatch(RegistryKey, Class) ->
    Registry = functools_singledispatch_registry(RegistryKey),
    Candidates = functools_dispatch_candidates(Class),
    case [Impl || Candidate <- Candidates, {ok, Impl} <- [maps:find(Candidate, Registry)]] of
        [Impl | _] -> Impl;
        [] -> maps:get(maps:get(<<"object">>, pyrlang_builtins:env()), Registry)
    end.

functools_singledispatch_registry(RegistryKey) ->
    case erlang:get(RegistryKey) of
        Registry when is_map(Registry) -> Registry;
        _ -> #{}
    end.

functools_infer_dispatch_class(Func) ->
    try
        ParamName = functools_first_param_name(Func),
        Annotations = pyrlang_object:get_attr(Func, <<"__annotations__">>),
        case lists:keyfind(ParamName, 1, pyrlang_heap:dict_items(Annotations)) of
            {ParamName, none} ->
                {ok, pyrlang_builtins:none_type()};
            {ParamName, Annotation} ->
                case is_class_like(Annotation) of
                    true -> {ok, Annotation};
                    false -> error
                end;
            false ->
                error
        end
    catch
        _:_ -> error
    end.

functools_first_param_name({py_function, Params, _Body, _Env}) ->
    functools_first_param_name(Params);
functools_first_param_name({py_function, Params, _Body, _Env, _Mode}) ->
    functools_first_param_name(Params);
functools_first_param_name({py_function, Params, _Body, _Env, _Mode, _Owner}) ->
    functools_first_param_name(Params);
functools_first_param_name([{param, Name, _Default, _Annotation} | _Rest]) ->
    Name;
functools_first_param_name([{param, Name, _Default} | _Rest]) ->
    Name;
functools_first_param_name([_Other | Rest]) ->
    functools_first_param_name(Rest);
functools_first_param_name([]) ->
    erlang:error(no_function_params);
functools_first_param_name(_Func) ->
    erlang:error(no_function_params).

functools_dispatch_candidates({py_ref, _} = Class) ->
    try
        pyrlang_object:mro(Class)
    catch
        _:_ -> [Class, maps:get(<<"object">>, pyrlang_builtins:env())]
    end;
functools_dispatch_candidates({py_exception_type, _Type} = Class) ->
    [Class, maps:get(<<"object">>, pyrlang_builtins:env())];
functools_dispatch_candidates(undefined) ->
    [maps:get(<<"object">>, pyrlang_builtins:env())];
functools_dispatch_candidates(Class) ->
    [Class, maps:get(<<"object">>, pyrlang_builtins:env())].

functools_cache_map(CacheKey) ->
    case erlang:get(CacheKey) of
        Cache when is_map(Cache) -> Cache;
        _ -> #{}
    end.

functools_cache_stats(StatsKey) ->
    case erlang:get(StatsKey) of
        Stats when is_map(Stats) -> Stats;
        _ -> #{hits => 0, misses => 0}
    end.

functools_cache_stat(StatsKey, Name) ->
    Stats = functools_cache_stats(StatsKey),
    erlang:put(StatsKey, Stats#{Name => maps:get(Name, Stats, 0) + 1}),
    ok.

functools_cache_key({py_ref, Id}) ->
    {py_ref, Id};
functools_cache_key({py_function, Params, Body, Env}) ->
    function_cache_key(Params, Body, Env, false, undefined);
functools_cache_key({py_function, Params, Body, Env, Mode}) ->
    function_cache_key(Params, Body, Env, Mode, undefined);
functools_cache_key({py_function, Params, Body, Env, Mode, Owner}) ->
    function_cache_key(Params, Body, Env, Mode, Owner);
functools_cache_key({py_bound_method, Callable, Self}) ->
    {py_bound_method, functools_cache_key(Callable), functools_cache_key(Self)};
functools_cache_key({Key, Value}) ->
    {functools_cache_key(Key), functools_cache_key(Value)};
functools_cache_key(List) when is_list(List) ->
    [functools_cache_key(Value) || Value <- List];
functools_cache_key(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([functools_cache_key(Value) || Value <- tuple_to_list(Tuple)]);
functools_cache_key(Map) when is_map(Map) ->
    maps:from_list([
        {functools_cache_key(Key), functools_cache_key(Value)}
     || {Key, Value} <- maps:to_list(Map)
    ]);
functools_cache_key(Value) ->
    Value.

function_cache_key(Params, Body, Env, Mode, Owner) ->
    case maps:get(?FUNCTION_ID_KEY, Env, undefined) of
        undefined -> {py_function, erlang:phash2({Params, Body, Mode, Owner})};
        Id -> {py_function_id, Id}
    end.

trace_functools_cache(Stage, Value) ->
    case os:getenv("PYRLANG_TRACE_CACHE") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_CACHE ~p ~p~n", [Stage, trace_inspect_value(Value)])
    end.

functools_cached_property(Func) ->
    pyrlang_object:descriptor(
        fun
            (undefined, _Class) -> Func;
            (Instance, _Class) -> pyrlang_eval:call(Func, [Instance])
        end,
        undefined,
        #{kind => cached_property, callable => Func}
    ).

functools_total_ordering(Class) ->
    Root = total_ordering_root(Class),
    lists:foreach(
        fun(Method) ->
            case Method =:= Root orelse total_ordering_has_method(Class, Method) of
                true ->
                    ok;
                false ->
                    ok = pyrlang_object:set_attr(Class, Method, total_ordering_method(Root, Method))
            end
        end,
        [<<"__lt__">>, <<"__le__">>, <<"__gt__">>, <<"__ge__">>]
    ),
    Class.

total_ordering_root(Class) ->
    Methods = [<<"__lt__">>, <<"__le__">>, <<"__gt__">>, <<"__ge__">>],
    case [Method || Method <- Methods, total_ordering_has_method(Class, Method)] of
        [Root | _] ->
            Root;
        [] ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>),
                    <<"must define at least one ordering operation">>
                )
            )
    end.

total_ordering_has_method(Class, Method) ->
    case pyrlang_object:class_attr(Class, Method) of
        {ok, _Value} -> true;
        error -> false
    end.

total_ordering_method(<<"__lt__">>, <<"__le__">>) ->
    fun(Self, Other) ->
        total_ordering_call(Self, <<"__lt__">>, Other) orelse
            total_ordering_call(Self, <<"__eq__">>, Other)
    end;
total_ordering_method(<<"__lt__">>, <<"__gt__">>) ->
    fun(Self, Other) ->
        not (total_ordering_call(Self, <<"__lt__">>, Other) orelse
            total_ordering_call(Self, <<"__eq__">>, Other))
    end;
total_ordering_method(<<"__lt__">>, <<"__ge__">>) ->
    fun(Self, Other) ->
        not total_ordering_call(Self, <<"__lt__">>, Other)
    end;
total_ordering_method(<<"__le__">>, <<"__lt__">>) ->
    fun(Self, Other) ->
        total_ordering_call(Self, <<"__le__">>, Other) andalso
            not total_ordering_call(Self, <<"__eq__">>, Other)
    end;
total_ordering_method(<<"__le__">>, <<"__gt__">>) ->
    fun(Self, Other) ->
        not total_ordering_call(Self, <<"__le__">>, Other)
    end;
total_ordering_method(<<"__le__">>, <<"__ge__">>) ->
    fun(Self, Other) ->
        not (total_ordering_call(Self, <<"__le__">>, Other) andalso
            not total_ordering_call(Self, <<"__eq__">>, Other))
    end;
total_ordering_method(<<"__gt__">>, <<"__lt__">>) ->
    fun(Self, Other) ->
        not (total_ordering_call(Self, <<"__gt__">>, Other) orelse
            total_ordering_call(Self, <<"__eq__">>, Other))
    end;
total_ordering_method(<<"__gt__">>, <<"__le__">>) ->
    fun(Self, Other) ->
        not total_ordering_call(Self, <<"__gt__">>, Other)
    end;
total_ordering_method(<<"__gt__">>, <<"__ge__">>) ->
    fun(Self, Other) ->
        total_ordering_call(Self, <<"__gt__">>, Other) orelse
            total_ordering_call(Self, <<"__eq__">>, Other)
    end;
total_ordering_method(<<"__ge__">>, <<"__lt__">>) ->
    fun(Self, Other) ->
        not total_ordering_call(Self, <<"__ge__">>, Other)
    end;
total_ordering_method(<<"__ge__">>, <<"__le__">>) ->
    fun(Self, Other) ->
        not (total_ordering_call(Self, <<"__ge__">>, Other) andalso
            not total_ordering_call(Self, <<"__eq__">>, Other))
    end;
total_ordering_method(<<"__ge__">>, <<"__gt__">>) ->
    fun(Self, Other) ->
        total_ordering_call(Self, <<"__ge__">>, Other) andalso
            not total_ordering_call(Self, <<"__eq__">>, Other)
    end.

total_ordering_call(Self, Method, Other) ->
    py_truthy(pyrlang_eval:call(pyrlang_object:get_attr(Self, Method), [Other])).

functools_reduce([Func, Iterable]) ->
    case pyrlang_iter:values(Iterable) of
        [] ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"TypeError">>),
                    <<"reduce() of empty iterable with no initial value">>
                )
            );
        [First | Rest] ->
            functools_reduce_values(Func, Rest, First)
    end;
functools_reduce([Func, Iterable, Initial]) ->
    functools_reduce_values(Func, pyrlang_iter:values(Iterable), Initial);
functools_reduce(Args) ->
    erlang:error({arity_error, {reduce, length(Args)}}).

functools_reduce_values(_Func, [], Acc) ->
    Acc;
functools_reduce_values(Func, [Value | Rest], Acc) ->
    functools_reduce_values(Func, Rest, pyrlang_eval:call(Func, [Acc, Value])).

functools_partial([Callable | BoundArgs], BoundKwArgs) ->
    native_instance(<<"partial">>, #{
        <<"func">> => Callable,
        <<"args">> => list_to_tuple(BoundArgs),
        <<"keywords">> => pyrlang_heap:dict(maps:to_list(BoundKwArgs)),
        <<"__call__">> =>
            {py_native_call, fun(CallArgs, CallKwArgs) ->
                pyrlang_eval:call(
                    Callable,
                    {call_args, BoundArgs ++ CallArgs, maps:merge(BoundKwArgs, CallKwArgs)}
                )
            end}
    });
functools_partial(Args, _KwArgs) ->
    erlang:error({arity_error, {partial, length(Args)}}).

functools_partialmethod([Callable | BoundArgs0], BoundKwArgs0) ->
    {Func, BoundArgs, BoundKwArgs} = flatten_partialmethod(Callable, BoundArgs0, BoundKwArgs0),
    pyrlang_object:descriptor(
        fun(Instance, Class) ->
            partialmethod_get(Func, BoundArgs, BoundKwArgs, Instance, Class)
        end,
        undefined,
        #{
            kind => partialmethod,
            func => Func,
            args => list_to_tuple(BoundArgs),
            keywords => pyrlang_heap:dict(maps:to_list(BoundKwArgs)),
            kw_map => BoundKwArgs
        }
    );
functools_partialmethod(Args, _KwArgs) ->
    erlang:error({arity_error, {partialmethod, length(Args)}}).

flatten_partialmethod(
    #{kind := partialmethod, func := Func, args := ExistingArgs} = PartialMethod, Args, KwArgs
) ->
    ExistingKwArgs = maps:get(
        kw_map,
        PartialMethod,
        maps:from_list(pyrlang_heap:dict_items(maps:get(keywords, PartialMethod)))
    ),
    {Func, tuple_to_list(ExistingArgs) ++ Args, maps:merge(ExistingKwArgs, KwArgs)};
flatten_partialmethod(Func, Args, KwArgs) ->
    {Func, Args, KwArgs}.

partialmethod_get(Func, BoundArgs, BoundKwArgs, undefined, Class) ->
    case partialmethod_descriptor_target(Func, undefined, Class) of
        {bound, BoundFunc} ->
            partialmethod_callable(BoundFunc, BoundArgs, BoundKwArgs);
        unbound ->
            {py_native_call, fun
                ([Self | CallArgs], CallKwArgs) ->
                    pyrlang_eval:call(
                        Func,
                        {call_args, [Self | BoundArgs ++ CallArgs],
                            maps:merge(BoundKwArgs, CallKwArgs)}
                    );
                ([], _CallKwArgs) ->
                    erlang:error({arity_error, {partialmethod, missing_self}})
            end}
    end;
partialmethod_get(Func, BoundArgs, BoundKwArgs, Instance, Class) ->
    case partialmethod_descriptor_target(Func, Instance, Class) of
        {bound, BoundFunc} ->
            partialmethod_callable(BoundFunc, BoundArgs, BoundKwArgs);
        unbound ->
            {py_native_call, fun(CallArgs, CallKwArgs) ->
                pyrlang_eval:call(
                    Func,
                    {call_args, [Instance | BoundArgs ++ CallArgs],
                        maps:merge(BoundKwArgs, CallKwArgs)}
                )
            end}
    end.

partialmethod_callable(Func, BoundArgs, BoundKwArgs) ->
    {py_native_call, fun(CallArgs, CallKwArgs) ->
        pyrlang_eval:call(
            Func, {call_args, BoundArgs ++ CallArgs, maps:merge(BoundKwArgs, CallKwArgs)}
        )
    end}.

partialmethod_descriptor_target(Func, Instance, Class) ->
    try pyrlang_object:get_attr(Func, <<"__get__">>) of
        Get ->
            Bound = pyrlang_eval:call(Get, [descriptor_instance_arg(Instance), Class]),
            case Bound =/= Func of
                true -> {bound, Bound};
                false -> unbound
            end
    catch
        _:_ -> unbound
    end.

descriptor_instance_arg(undefined) ->
    none;
descriptor_instance_arg(Instance) ->
    Instance.

functools_unwrap_partial(Func) ->
    case partial_func(Func) of
        {ok, Inner} -> functools_unwrap_partial(Inner);
        error -> Func
    end.

functools_unwrap_partialmethod(Func) ->
    functools_unwrap_partialmethod(Func, none).

functools_unwrap_partialmethod(Func, Func) ->
    Func;
functools_unwrap_partialmethod(Func, _Previous) ->
    Next = functools_unwrap_partial(partialmethod_func(Func)),
    functools_unwrap_partialmethod(Next, Func).

partialmethod_func(Func) ->
    case partialmethod_attr(Func) of
        {ok, PartialMethod} ->
            partialmethod_func(PartialMethod);
        error ->
            case Func of
                #{kind := partialmethod, func := Inner} ->
                    Inner;
                _ ->
                    case native_instance_attr(Func, <<"partialmethod">>, <<"func">>) of
                        {ok, Inner} -> Inner;
                        error -> Func
                    end
            end
    end.

partialmethod_attr(Func) ->
    try pyrlang_object:get_attr(Func, <<"__partialmethod__">>) of
        PartialMethod ->
            case native_instance_attr(PartialMethod, <<"partialmethod">>, <<"func">>) of
                {ok, _Inner} -> {ok, PartialMethod};
                error -> error
            end
    catch
        _:_ -> error
    end.

partial_func(Func) ->
    native_instance_attr(Func, <<"partial">>, <<"func">>).

native_instance_attr({py_ref, _} = Ref, ClassName, AttrName) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            Data = pyrlang_heap:data(Ref),
            Class = maps:get(class, Data),
            case pyrlang_object:class_name(Class) of
                ClassName ->
                    Attrs = maps:get(attrs, Data),
                    maps:find(AttrName, Attrs);
                _Other ->
                    error
            end;
        _Other ->
            error
    catch
        _:_ -> error
    end;
native_instance_attr(_Other, _ClassName, _AttrName) ->
    error.

subprocess_completed_process_new([Args, ReturnCode], KwArgs) ->
    Stdout = maps:get(<<"stdout">>, KwArgs, none),
    Stderr = maps:get(<<"stderr">>, KwArgs, none),
    subprocess_completed_process(Args, ReturnCode, Stdout, Stderr);
subprocess_completed_process_new([Args, ReturnCode, Stdout], KwArgs) ->
    Stderr = maps:get(<<"stderr">>, KwArgs, none),
    subprocess_completed_process(Args, ReturnCode, Stdout, Stderr);
subprocess_completed_process_new([Args, ReturnCode, Stdout, Stderr], KwArgs) when
    map_size(KwArgs) =:= 0
->
    subprocess_completed_process(Args, ReturnCode, Stdout, Stderr);
subprocess_completed_process_new(Args, _KwArgs) ->
    erlang:error({arity_error, {completed_process, length(Args)}}).

subprocess_run([Command], KwArgs) ->
    Shell = kw_bool(<<"shell">>, KwArgs, false),
    Check = kw_bool(<<"check">>, KwArgs, false),
    CaptureOutput = kw_bool(<<"capture_output">>, KwArgs, false),
    Cwd = kw_path(<<"cwd">>, KwArgs),
    {ReturnCode, Stdout0} =
        case Shell of
            true -> run_shell_command(command_text(Command), Cwd);
            false -> run_exec_command(Command, Cwd)
        end,
    Stdout =
        case CaptureOutput orelse maps:is_key(<<"stdout">>, KwArgs) of
            true -> Stdout0;
            false -> none
        end,
    Stderr =
        case CaptureOutput orelse maps:is_key(<<"stderr">>, KwArgs) of
            true -> <<>>;
            false -> none
        end,
    case Check andalso ReturnCode =/= 0 of
        true ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"CalledProcessError">>), ReturnCode)
            );
        false ->
            subprocess_completed_process(Command, ReturnCode, Stdout, Stderr)
    end;
subprocess_run(Args, _KwArgs) ->
    erlang:error({arity_error, {subprocess_run, length(Args)}}).

subprocess_completed_process(Args, ReturnCode, Stdout, Stderr) ->
    native_instance(<<"CompletedProcess">>, #{
        <<"args">> => Args,
        <<"returncode">> => ReturnCode,
        <<"stdout">> => Stdout,
        <<"stderr">> => Stderr
    }).

run_shell_command(Command, Cwd) ->
    Shell = shell_executable(),
    run_port(Shell, ["-c", binary_to_list(Command)], Cwd).

run_exec_command(Command, Cwd) ->
    case command_argv(Command) of
        [Program | Args] ->
            run_port(Program, Args, Cwd);
        [] ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>), <<"empty subprocess command">>
                )
            )
    end.

run_port(Program, Args, undefined) ->
    Port = open_port({spawn_executable, Program}, [
        binary, exit_status, stderr_to_stdout, {args, Args}
    ]),
    collect_port(Port, []);
run_port(Program, Args, Cwd) ->
    Port = open_port({spawn_executable, Program}, [
        binary, exit_status, stderr_to_stdout, {args, Args}, {cd, Cwd}
    ]),
    collect_port(Port, []).

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    end.

shell_executable() ->
    case os:find_executable("sh") of
        false -> "/bin/sh";
        Path -> Path
    end.

command_text(Command) when is_binary(Command) ->
    Command;
command_text(Command) ->
    join_binary([normalize_name(Part) || Part <- command_values(Command)], <<" ">>).

command_argv(Command) when is_binary(Command) ->
    [binary_to_list(Command)];
command_argv(Command) ->
    [binary_to_list(normalize_name(Part)) || Part <- command_values(Command)].

command_values({py_ref, _} = Ref) ->
    pyrlang_iter:values(Ref);
command_values(Value) ->
    [Value].

kw_bool(Key, KwArgs, Default) ->
    case maps:get(Key, KwArgs, Default) of
        true -> true;
        false -> false;
        none -> false;
        0 -> false;
        _ -> true
    end.

kw_path(Key, KwArgs) ->
    case maps:get(Key, KwArgs, none) of
        none -> undefined;
        Value -> binary_to_list(normalize_name(Value))
    end.

copy_copy({py_ref, _} = Value) ->
    try pyrlang_object:get_attr(Value, <<"__copy__">>) of
        Callable -> pyrlang_eval:call(Callable, [])
    catch
        error:{attribute_error, _Name} -> shallow_copy(Value);
        throw:{py_exception, _Exception} -> shallow_copy(Value)
    end;
copy_copy(Value) ->
    shallow_copy(Value).

copy_deepcopy([Value]) ->
    copy_deepcopy_value(Value, pyrlang_heap:dict([]));
copy_deepcopy([Value, Memo]) ->
    copy_deepcopy_value(Value, Memo);
copy_deepcopy(Args) ->
    erlang:error({arity_error, {deepcopy, length(Args)}}).

copy_deepcopy_value({py_ref, _} = Value, Memo) ->
    case pyrlang_heap:type(Value) of
        list ->
            pyrlang_heap:list([
                copy_deepcopy_value(Item, Memo)
             || Item <- pyrlang_heap:list_items(Value)
            ]);
        dict ->
            pyrlang_heap:dict([
                {copy_deepcopy_value(Key, Memo), copy_deepcopy_value(ItemValue, Memo)}
             || {Key, ItemValue} <- pyrlang_heap:dict_items(Value)
            ]);
        set ->
            pyrlang_heap:set([
                copy_deepcopy_value(Item, Memo)
             || Item <- pyrlang_heap:set_items(Value)
            ]);
        class ->
            Value;
        module ->
            Value;
        _ ->
            try pyrlang_object:get_attr(Value, <<"__deepcopy__">>) of
                Callable -> pyrlang_eval:call(Callable, [Memo])
            catch
                error:{attribute_error, _Name} -> pyrlang_send:copy(Value);
                throw:{py_exception, _Exception} -> pyrlang_send:copy(Value)
            end
    end;
copy_deepcopy_value({py_function, _Params, _Body, _Env} = Value, _Memo) ->
    Value;
copy_deepcopy_value({py_function, _Params, _Body, _Env, _Mode} = Value, _Memo) ->
    Value;
copy_deepcopy_value({py_function, _Params, _Body, _Env, _Mode, _Owner} = Value, _Memo) ->
    Value;
copy_deepcopy_value(Tuple, Memo) when is_tuple(Tuple) ->
    list_to_tuple([copy_deepcopy_value(Item, Memo) || Item <- tuple_to_list(Tuple)]);
copy_deepcopy_value(Value, _Memo) ->
    pyrlang_send:copy(Value).

shallow_copy({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> pyrlang_heap:list(pyrlang_heap:list_items(Ref));
        dict -> pyrlang_heap:dict(pyrlang_heap:dict_items(Ref));
        set -> pyrlang_heap:set(pyrlang_heap:set_items(Ref));
        instance -> shallow_copy_instance(Ref);
        class -> Ref;
        module -> Ref;
        _Type -> pyrlang_send:copy(Ref)
    end;
shallow_copy(Value) ->
    Value.

shallow_copy_instance(Ref) ->
    Data = pyrlang_heap:data(Ref),
    Class = maps:get(class, Data),
    Copy = pyrlang_object:instantiate(Class),
    maps:foreach(
        fun(Attr, Value) -> ok = pyrlang_object:set_attr(Copy, Attr, Value) end,
        maps:get(attrs, Data)
    ),
    Copy.

itertools_chain_callable() ->
    native_instance(<<"chain">>, #{
        <<"__call__">> => {py_native_varargs, fun itertools_chain/1},
        <<"from_iterable">> => fun itertools_chain_from_iterable/1
    }).

itertools_chain(Iterables) ->
    pyrlang_iter:from_values(
        lists:append([pyrlang_iter:values(Iterable) || Iterable <- Iterables])
    ).

itertools_chain_from_iterable(Iterable) ->
    itertools_chain(pyrlang_iter:values(Iterable)).

itertools_accumulate([Iterable]) ->
    pyrlang_heap:list(accumulate_values(pyrlang_iter:values(Iterable), none, []));
itertools_accumulate([Iterable, Function]) ->
    pyrlang_heap:list(accumulate_values(pyrlang_iter:values(Iterable), Function, []));
itertools_accumulate(Args) ->
    erlang:error({arity_error, {itertools_accumulate, length(Args)}}).

accumulate_values([], _Function, Acc) ->
    lists:reverse(Acc);
accumulate_values([Value | Rest], Function, []) ->
    accumulate_values(Rest, Function, [Value]);
accumulate_values([Value | Rest], none, [Current | _] = Acc) ->
    accumulate_values(Rest, none, [Current + Value | Acc]);
accumulate_values([Value | Rest], Function, [Current | _] = Acc) ->
    accumulate_values(Rest, Function, [pyrlang_eval:call(Function, [Current, Value]) | Acc]).

itertools_islice([Iterable, Stop]) ->
    itertools_islice_values(Iterable, 0, Stop, 1);
itertools_islice([Iterable, Start, Stop]) ->
    itertools_islice_values(Iterable, Start, Stop, 1);
itertools_islice([Iterable, Start, Stop, Step]) ->
    itertools_islice_values(Iterable, Start, Stop, Step);
itertools_islice(Args) ->
    erlang:error({arity_error, {itertools_islice, length(Args)}}).

itertools_tee([Iterable]) ->
    itertools_tee([Iterable, 2]);
itertools_tee([Iterable, Count]) when is_integer(Count), Count >= 0 ->
    Values = pyrlang_iter:values(Iterable),
    list_to_tuple(repeated_iterable_lists(Values, Count, []));
itertools_tee(Args) ->
    erlang:error({arity_error, {itertools_tee, length(Args)}}).

repeated_iterable_lists(_Values, 0, Acc) ->
    lists:reverse(Acc);
repeated_iterable_lists(Values, Count, Acc) ->
    repeated_iterable_lists(Values, Count - 1, [pyrlang_heap:list(Values) | Acc]).

itertools_zip_longest(Iterables, KwArgs) ->
    case maps:keys(maps:without([<<"fillvalue">>], KwArgs)) of
        [] ->
            FillValue = maps:get(<<"fillvalue">>, KwArgs, none),
            ValueLists = [pyrlang_iter:values(Iterable) || Iterable <- Iterables],
            pyrlang_heap:list(zip_longest_values(ValueLists, FillValue));
        Extra ->
            erlang:error({type_error, {unexpected_keyword_argument, Extra}})
    end.

zip_longest_values([], _FillValue) ->
    [];
zip_longest_values(ValueLists, FillValue) ->
    MaxLength = lists:max([length(Values) || Values <- ValueLists]),
    zip_longest_rows(ValueLists, FillValue, MaxLength).

zip_longest_rows(_ValueLists, _FillValue, 0) ->
    [];
zip_longest_rows(ValueLists, FillValue, MaxLength) ->
    [
        list_to_tuple([nth_or_fill(Values, Index, FillValue) || Values <- ValueLists])
     || Index <- lists:seq(1, MaxLength)
    ].

nth_or_fill(Values, Index, _FillValue) when Index =< length(Values) ->
    lists:nth(Index, Values);
nth_or_fill(_Values, _Index, FillValue) ->
    FillValue.

itertools_islice_values(Iterable, Start0, Stop0, Step0) ->
    Values = pyrlang_iter:values(Iterable),
    Length = length(Values),
    Start = normalize_islice_bound(Start0, 0),
    Stop = normalize_islice_bound(Stop0, Length),
    Step = normalize_islice_step(Step0),
    pyrlang_heap:list(islice_values(Values, Start, min(Stop, Length), Step, 0, [])).

normalize_islice_bound(none, Default) ->
    Default;
normalize_islice_bound(Value, _Default) when is_integer(Value), Value >= 0 ->
    Value;
normalize_islice_bound(Value, _Default) ->
    erlang:error({value_error, {invalid_islice_bound, Value}}).

normalize_islice_step(Value) when is_integer(Value), Value > 0 ->
    Value;
normalize_islice_step(Value) ->
    erlang:error({value_error, {invalid_islice_step, Value}}).

islice_values([], _Start, _Stop, _Step, _Pos, Acc) ->
    lists:reverse(Acc);
islice_values(_Values, _Start, Stop, _Step, Pos, Acc) when Pos >= Stop ->
    lists:reverse(Acc);
islice_values([Value | Rest], Start, Stop, Step, Pos, Acc) when
    Pos >= Start, ((Pos - Start) rem Step) =:= 0
->
    islice_values(Rest, Start, Stop, Step, Pos + 1, [Value | Acc]);
islice_values([_Value | Rest], Start, Stop, Step, Pos, Acc) ->
    islice_values(Rest, Start, Stop, Step, Pos + 1, Acc).

itertools_permutations([Iterable]) ->
    Values = pyrlang_iter:values(Iterable),
    pyrlang_heap:list([list_to_tuple(Value) || Value <- permutations(Values, length(Values))]);
itertools_permutations([Iterable, R]) when is_integer(R), R >= 0 ->
    Values = pyrlang_iter:values(Iterable),
    pyrlang_heap:list([list_to_tuple(Value) || Value <- permutations(Values, R)]);
itertools_permutations(Args) ->
    erlang:error({arity_error, {itertools_permutations, length(Args)}}).

permutations(_Values, 0) ->
    [[]];
permutations([], _R) ->
    [];
permutations(Values, R) ->
    [
        [Value | Rest]
     || {Value, Remaining} <- pick_each(Values),
        Rest <- permutations(Remaining, R - 1)
    ].

pick_each(Values) ->
    pick_each(Values, []).

pick_each([], _Left) ->
    [];
pick_each([Value | Right], Left) ->
    [{Value, lists:reverse(Left) ++ Right} | pick_each(Right, [Value | Left])].

itertools_product([]) ->
    pyrlang_heap:list([{}]);
itertools_product(Iterables) ->
    Pools = [pyrlang_iter:values(Iterable) || Iterable <- Iterables],
    pyrlang_heap:list([list_to_tuple(Value) || Value <- product_values(Pools)]).

product_values([]) ->
    [[]];
product_values([Pool | RestPools]) ->
    RestValues = product_values(RestPools),
    [[Value | Rest] || Value <- Pool, Rest <- RestValues].

itertools_repeat([Value]) ->
    pyrlang_heap:list([Value]);
itertools_repeat([Value, Count]) when is_integer(Count), Count >= 0 ->
    pyrlang_heap:list(lists:duplicate(Count, Value));
itertools_repeat(Args) ->
    erlang:error({arity_error, {itertools_repeat, length(Args)}}).

itertools_count([]) ->
    itertools_count([0, 1]);
itertools_count([Start]) when is_number(Start) ->
    itertools_count([Start, 1]);
itertools_count([Start, Step]) when is_number(Start), is_number(Step) ->
    Class = pyrlang_object:new_class(<<"count">>, [], #{}),
    Instance = pyrlang_object:instantiate(Class),
    ok = pyrlang_object:set_attr(Instance, <<"current">>, Start),
    ok = pyrlang_object:set_attr(Instance, <<"step">>, Step),
    ok = pyrlang_object:set_attr(
        Instance,
        <<"__iter__">>,
        {py_native_callable, fun
            ([]) ->
                Instance;
            (CallArgs) ->
                erlang:error({arity_error, {'itertools.count.__iter__', length(CallArgs)}})
        end}
    ),
    ok = pyrlang_object:set_attr(
        Instance,
        <<"__next__">>,
        {py_native_callable, fun
            ([]) ->
                Current = pyrlang_object:get_attr(Instance, <<"current">>),
                CountStep = pyrlang_object:get_attr(Instance, <<"step">>),
                ok = pyrlang_object:set_attr(Instance, <<"current">>, Current + CountStep),
                Current;
            (CallArgs) ->
                erlang:error({arity_error, {'itertools.count.__next__', length(CallArgs)}})
        end}
    ),
    Instance;
itertools_count(Args) ->
    erlang:error({arity_error, {itertools_count, length(Args)}}).

itertools_cycle([Iterable]) ->
    Values = pyrlang_iter:values(Iterable),
    Class = pyrlang_object:new_class(<<"cycle">>, [], #{}),
    Instance = pyrlang_object:instantiate(Class),
    ok = pyrlang_object:set_attr(Instance, <<"values">>, Values),
    ok = pyrlang_object:set_attr(Instance, <<"index">>, 1),
    ok = pyrlang_object:set_attr(
        Instance,
        <<"__iter__">>,
        {py_native_callable, fun
            ([]) ->
                Instance;
            (CallArgs) ->
                erlang:error({arity_error, {'itertools.cycle.__iter__', length(CallArgs)}})
        end}
    ),
    ok = pyrlang_object:set_attr(
        Instance,
        <<"__next__">>,
        {py_native_callable, fun
            ([]) ->
                CycleValues = pyrlang_object:get_attr(Instance, <<"values">>),
                case CycleValues of
                    [] ->
                        pyrlang_exception:raise(
                            pyrlang_exception:make(pyrlang_exception:type(<<"StopIteration">>))
                        );
                    _ ->
                        Index = pyrlang_object:get_attr(Instance, <<"index">>),
                        Value = lists:nth(Index, CycleValues),
                        NextIndex =
                            case Index >= length(CycleValues) of
                                true -> 1;
                                false -> Index + 1
                            end,
                        ok = pyrlang_object:set_attr(Instance, <<"index">>, NextIndex),
                        Value
                end;
            (CallArgs) ->
                erlang:error({arity_error, {'itertools.cycle.__next__', length(CallArgs)}})
        end}
    ),
    Instance;
itertools_cycle(Args) ->
    erlang:error({arity_error, {itertools_cycle, length(Args)}}).

itertools_groupby([Iterable]) ->
    itertools_groupby([Iterable, none]);
itertools_groupby([Iterable, KeyFun]) ->
    Values = pyrlang_iter:values(Iterable),
    pyrlang_heap:list(itertools_groupby_values(Values, KeyFun, []));
itertools_groupby(Args) ->
    erlang:error({arity_error, {itertools_groupby, length(Args)}}).

itertools_groupby_values([], _KeyFun, Acc) ->
    lists:reverse(Acc);
itertools_groupby_values([Value | Rest], KeyFun, Acc) ->
    Key = itertools_groupby_key(Value, KeyFun),
    {Group, Remaining} = itertools_take_group(Rest, KeyFun, Key, [Value]),
    itertools_groupby_values(Remaining, KeyFun, [
        {Key, pyrlang_heap:list(lists:reverse(Group))} | Acc
    ]).

itertools_take_group([], _KeyFun, _Key, Acc) ->
    {Acc, []};
itertools_take_group([Value | Rest], KeyFun, Key, Acc) ->
    case itertools_groupby_key(Value, KeyFun) of
        Key -> itertools_take_group(Rest, KeyFun, Key, [Value | Acc]);
        _Other -> {Acc, [Value | Rest]}
    end.

itertools_groupby_key(Value, none) ->
    Value;
itertools_groupby_key(Value, KeyFun) ->
    pyrlang_eval:call(KeyFun, [Value]).

itertools_starmap(Function, Iterable) ->
    Values = [
        pyrlang_eval:call(Function, pyrlang_iter:values(Args))
     || Args <- pyrlang_iter:values(Iterable)
    ],
    pyrlang_heap:list(Values).

itertools_takewhile(Predicate, Iterable) ->
    pyrlang_heap:list(takewhile_values(Predicate, pyrlang_iter:values(Iterable), [])).

takewhile_values(_Predicate, [], Acc) ->
    lists:reverse(Acc);
takewhile_values(Predicate, [Value | Rest], Acc) ->
    case py_truthy(pyrlang_eval:call(Predicate, [Value])) of
        true -> takewhile_values(Predicate, Rest, [Value | Acc]);
        false -> lists:reverse(Acc)
    end.

py_truthy(none) ->
    false;
py_truthy(false) ->
    false;
py_truthy(0) ->
    false;
py_truthy(Value) when is_binary(Value) ->
    byte_size(Value) =/= 0;
py_truthy({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> pyrlang_heap:list_items(Ref) =/= [];
        dict -> pyrlang_heap:dict_items(Ref) =/= [];
        set -> pyrlang_heap:set_items(Ref) =/= [];
        instance -> py_instance_truthy(Ref);
        _ -> true
    end;
py_truthy(_Value) ->
    true.

py_instance_truthy(Ref) ->
    case py_call_truthy_special(Ref, <<"__bool__">>) of
        {ok, Value} ->
            py_truthy(Value);
        error ->
            case py_call_truthy_special(Ref, <<"__len__">>) of
                {ok, Len} when is_integer(Len); is_float(Len) ->
                    Len =/= 0;
                {ok, true} ->
                    true;
                {ok, false} ->
                    false;
                {ok, _Other} ->
                    true;
                error ->
                    case string_subclass_value(Ref) of
                        {ok, Value} -> Value =/= <<>>;
                        error -> true
                    end
            end
    end.

py_call_truthy_special(Ref, Method) ->
    try pyrlang_object:get_attr(Ref, Method) of
        Callable -> {ok, pyrlang_eval:call(Callable, [])}
    catch
        _:_ -> error
    end.

collections_deque_new([], KwArgs) ->
    collections_deque_from_values([], KwArgs);
collections_deque_new([Iterable], KwArgs) ->
    collections_deque_from_values(pyrlang_iter:values(Iterable), KwArgs);
collections_deque_new(Args, _KwArgs) ->
    erlang:error({arity_error, {deque, length(Args)}}).

collections_deque_from_values(Values, KwArgs0) ->
    case maps:take(<<"maxlen">>, KwArgs0) of
        {0, Rest} when map_size(Rest) =:= 0 ->
            pyrlang_heap:list([]);
        {MaxLen, Rest} when is_integer(MaxLen), MaxLen > 0, map_size(Rest) =:= 0 ->
            pyrlang_heap:list(drop_left_to_length(Values, MaxLen));
        {none, Rest} when map_size(Rest) =:= 0 ->
            pyrlang_heap:list(Values);
        error when map_size(KwArgs0) =:= 0 ->
            pyrlang_heap:list(Values);
        {_MaxLen, Rest} when map_size(Rest) =:= 0 ->
            pyrlang_heap:list(Values);
        {_MaxLen, Rest} ->
            erlang:error({type_error, {unexpected_keyword_argument, maps:keys(Rest)}})
    end.

drop_left_to_length(Values, MaxLen) when length(Values) =< MaxLen ->
    Values;
drop_left_to_length(Values, MaxLen) ->
    lists:nthtail(length(Values) - MaxLen, Values).

collections_defaultdict_new([], KwArgs) ->
    collections_defaultdict_new([none], KwArgs);
collections_defaultdict_new([Factory], KwArgs) ->
    collections_defaultdict_from_items(Factory, [], KwArgs);
collections_defaultdict_new([Factory, Iterable], KwArgs) ->
    collections_defaultdict_from_items(Factory, pyrlang_iter:values(Iterable), KwArgs);
collections_defaultdict_new(Args, _KwArgs) ->
    erlang:error({arity_error, {defaultdict, length(Args)}}).

collections_defaultdict_from_items(Factory, Items, KwArgs) ->
    Store = pyrlang_heap:dict([]),
    lists:foreach(
        fun(Item) ->
            {Key, Value} = pair_value(Item),
            ok = pyrlang_heap:dict_put(Store, Key, Value)
        end,
        Items
    ),
    maps:foreach(fun(Key, Value) -> ok = pyrlang_heap:dict_put(Store, Key, Value) end, KwArgs),
    collections_defaultdict_instance(Factory, Store).

collections_defaultdict_instance(Factory, Store) ->
    native_instance(<<"defaultdict">>, #{
        <<"default_factory">> => Factory,
        <<"__copy__">> => fun() -> defaultdict_copy(Factory, Store) end,
        <<"__deepcopy__">> => fun(Memo) -> defaultdict_deepcopy(Factory, Store, Memo) end,
        <<"__getitem__">> => fun(Key) -> defaultdict_getitem(Store, Factory, Key) end,
        <<"__setitem__">> => fun(Key, Value) ->
            ok = pyrlang_heap:dict_put(Store, Key, Value),
            none
        end,
        <<"__delitem__">> => fun(Key) ->
            ok = pyrlang_heap:dict_del(Store, Key),
            none
        end,
        <<"__contains__">> => fun(Key) -> pyrlang_heap:dict_contains(Store, Key) end,
        <<"__len__">> => fun() -> length(pyrlang_heap:dict_items(Store)) end,
        <<"__iter__">> => fun() ->
            pyrlang_iter:iter(
                pyrlang_heap:list([Key || {Key, _Value} <- pyrlang_heap:dict_items(Store)])
            )
        end,
        <<"get">> => {py_native_varargs, fun(Args) -> defaultdict_get(Store, Args) end},
        <<"setdefault">> =>
            {py_native_varargs, fun(Args) -> defaultdict_setdefault(Store, Args) end},
        <<"pop">> => {py_native_varargs, fun(Args) -> defaultdict_pop(Store, Args) end},
        <<"items">> => fun() -> pyrlang_heap:list(pyrlang_heap:dict_items(Store)) end,
        <<"keys">> => fun() ->
            pyrlang_heap:list([Key || {Key, _Value} <- pyrlang_heap:dict_items(Store)])
        end,
        <<"values">> => fun() ->
            pyrlang_heap:list([Value || {_Key, Value} <- pyrlang_heap:dict_items(Store)])
        end,
        <<"copy">> => fun() -> defaultdict_copy(Factory, Store) end
    }).

defaultdict_copy(Factory, Store) ->
    collections_defaultdict_instance(Factory, pyrlang_heap:dict(pyrlang_heap:dict_items(Store))).

defaultdict_deepcopy(Factory, Store, Memo) ->
    collections_defaultdict_instance(
        Factory,
        pyrlang_heap:dict([
            {copy_deepcopy_value(Key, Memo), copy_deepcopy_value(Value, Memo)}
         || {Key, Value} <- pyrlang_heap:dict_items(Store)
        ])
    ).

defaultdict_getitem(Store, Factory, Key) ->
    case pyrlang_heap:dict_find(Store, Key) of
        {ok, Value} ->
            Value;
        error ->
            defaultdict_missing(Store, Factory, Key)
    end.

defaultdict_missing(_Store, none, Key) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Key));
defaultdict_missing(Store, Factory, Key) ->
    Value = pyrlang_eval:call(Factory, []),
    ok = pyrlang_heap:dict_put(Store, Key, Value),
    Value.

defaultdict_get(Store, [Key]) ->
    defaultdict_lookup(Store, Key, none);
defaultdict_get(Store, [Key, Default]) ->
    defaultdict_lookup(Store, Key, Default);
defaultdict_get(_Store, Args) ->
    erlang:error({arity_error, {defaultdict_get, length(Args)}}).

defaultdict_lookup(Store, Key, Default) ->
    case pyrlang_heap:dict_find(Store, Key) of
        {ok, Value} -> Value;
        error -> Default
    end.

defaultdict_setdefault(Store, [Key]) ->
    defaultdict_setdefault(Store, [Key, none]);
defaultdict_setdefault(Store, [Key, Default]) ->
    case pyrlang_heap:dict_find(Store, Key) of
        {ok, Value} ->
            Value;
        error ->
            ok = pyrlang_heap:dict_put(Store, Key, Default),
            Default
    end;
defaultdict_setdefault(_Store, Args) ->
    erlang:error({arity_error, {defaultdict_setdefault, length(Args)}}).

defaultdict_pop(Store, [Key]) ->
    defaultdict_pop(Store, [Key, no_default]);
defaultdict_pop(Store, [Key, Default]) ->
    case pyrlang_heap:dict_find(Store, Key) of
        {ok, Value} ->
            ok = pyrlang_heap:dict_del(Store, Key),
            Value;
        error ->
            case Default of
                no_default ->
                    pyrlang_exception:raise(
                        pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Key)
                    );
                _ ->
                    Default
            end
    end;
defaultdict_pop(_Store, Args) ->
    erlang:error({arity_error, {defaultdict_pop, length(Args)}}).

collections_counter_new([], KwArgs) ->
    collections_counter_from_counts(#{}, KwArgs);
collections_counter_new([Iterable], KwArgs) ->
    collections_counter_from_counts(collections_counter_counts(Iterable), KwArgs);
collections_counter_new(Args, _KwArgs) ->
    erlang:error({arity_error, {counter, length(Args)}}).

collections_counter_from_counts(Counts0, KwArgs) ->
    Counts = collections_counter_merge_counts(Counts0, KwArgs),
    Store = pyrlang_heap:dict(maps:to_list(Counts)),
    collections_counter_instance(Store).

collections_counter_counts(none) ->
    #{};
collections_counter_counts(Iterable) ->
    case collections_counter_mapping_items(Iterable) of
        {ok, Items} -> maps:from_list(Items);
        error -> collections_counter_count_values(pyrlang_iter:values(Iterable), #{})
    end.

collections_counter_mapping_items({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict ->
            {ok, pyrlang_heap:dict_items(Ref)};
        instance ->
            try pyrlang_object:get_attr(Ref, <<"items">>) of
                ItemsMethod ->
                    {ok, [
                        pair_value(Item)
                     || Item <- pyrlang_iter:values(pyrlang_eval:call(ItemsMethod, []))
                    ]}
            catch
                error:{attribute_error, _Name} -> error
            end;
        _Type ->
            error
    end;
collections_counter_mapping_items(Map) when is_map(Map) ->
    {ok, maps:to_list(Map)};
collections_counter_mapping_items(_Other) ->
    error.

collections_counter_count_values([], Counts) ->
    Counts;
collections_counter_count_values([Value | Rest], Counts) ->
    Current = maps:get(Value, Counts, 0),
    collections_counter_count_values(Rest, maps:put(Value, Current + 1, Counts)).

collections_counter_merge_counts(Counts, KwArgs) ->
    maps:fold(
        fun(Key, Value, Acc) -> maps:put(Key, maps:get(Key, Acc, 0) + Value, Acc) end,
        Counts,
        KwArgs
    ).

collections_counter_instance(Store) ->
    native_instance(<<"Counter">>, #{
        <<"__getitem__">> => fun(Key) -> counter_lookup(Store, Key, 0) end,
        <<"__setitem__">> => fun(Key, Value) ->
            ok = pyrlang_heap:dict_put(Store, Key, Value),
            none
        end,
        <<"__delitem__">> => fun(Key) ->
            ok = pyrlang_heap:dict_del(Store, Key),
            none
        end,
        <<"__contains__">> => fun(Key) -> pyrlang_heap:dict_contains(Store, Key) end,
        <<"__len__">> => fun() -> length(pyrlang_heap:dict_items(Store)) end,
        <<"__iter__">> => fun() ->
            pyrlang_iter:iter(
                pyrlang_heap:list([Key || {Key, _Value} <- pyrlang_heap:dict_items(Store)])
            )
        end,
        <<"get">> => {py_native_varargs, fun(Args) -> counter_get(Store, Args) end},
        <<"items">> => fun() -> pyrlang_heap:list(pyrlang_heap:dict_items(Store)) end,
        <<"keys">> => fun() ->
            pyrlang_heap:list([Key || {Key, _Value} <- pyrlang_heap:dict_items(Store)])
        end,
        <<"values">> => fun() ->
            pyrlang_heap:list([Value || {_Key, Value} <- pyrlang_heap:dict_items(Store)])
        end,
        <<"update">> =>
            {py_native_call, fun(Args, KwArgs) -> counter_update(Store, Args, KwArgs) end},
        <<"most_common">> => {py_native_varargs, fun(Args) -> counter_most_common(Store, Args) end}
    }).

counter_get(Store, [Key]) ->
    counter_lookup(Store, Key, 0);
counter_get(Store, [Key, Default]) ->
    counter_lookup(Store, Key, Default);
counter_get(_Store, Args) ->
    erlang:error({arity_error, {counter_get, length(Args)}}).

counter_lookup(Store, Key, Default) ->
    case pyrlang_heap:dict_find(Store, Key) of
        {ok, Value} -> Value;
        error -> Default
    end.

counter_update(Store, Args, KwArgs) ->
    lists:foreach(fun(Arg) -> counter_add_counts(Store, collections_counter_counts(Arg)) end, Args),
    counter_add_counts(Store, KwArgs),
    none.

counter_add_counts(Store, Counts) ->
    maps:foreach(
        fun(Key, Value) ->
            ok = pyrlang_heap:dict_put(Store, Key, counter_lookup(Store, Key, 0) + Value)
        end,
        Counts
    ).

counter_most_common(Store, []) ->
    counter_most_common(Store, [none]);
counter_most_common(Store, [none]) ->
    pyrlang_heap:list(counter_sorted_items(Store));
counter_most_common(Store, [N]) when is_integer(N), N >= 0 ->
    Items = counter_sorted_items(Store),
    {Prefix, _Rest} = lists:split(min(N, length(Items)), Items),
    pyrlang_heap:list(Prefix);
counter_most_common(_Store, [N]) when is_integer(N), N < 0 ->
    pyrlang_heap:list([]);
counter_most_common(_Store, Args) ->
    erlang:error({arity_error, {most_common, length(Args)}}).

counter_sorted_items(Store) ->
    lists:sort(
        fun({_KeyA, CountA}, {_KeyB, CountB}) -> CountA >= CountB end,
        pyrlang_heap:dict_items(Store)
    ).

pair_value(Value) when is_tuple(Value), tuple_size(Value) =:= 2 ->
    {element(1, Value), element(2, Value)};
pair_value(Value) ->
    case pyrlang_iter:values(Value) of
        [Key, ItemValue] -> {Key, ItemValue};
        Other -> erlang:error({value_error, {dict_pair, Other}})
    end.

collections_tuplegetter([Index, _Doc]) when is_integer(Index) ->
    pyrlang_object:descriptor(
        fun(Obj, _Class) -> operator_getitem(Obj, Index) end,
        undefined,
        #{kind => property}
    );
collections_tuplegetter(Args) ->
    erlang:error({arity_error, {'_tuplegetter', length(Args)}}).

operator_attrgetter([]) ->
    erlang:error({arity_error, {attrgetter, 0}});
operator_attrgetter(Names) ->
    Normalized = [normalize_name(Name) || Name <- Names],
    fun(Object) ->
        Values = [operator_get_dotted_attr(Object, Name) || Name <- Normalized],
        case Values of
            [Value] -> Value;
            _ -> list_to_tuple(Values)
        end
    end.

operator_get_dotted_attr(Object, Name) ->
    lists:foldl(
        fun(Part, Current) -> operator_get_attr(Current, Part) end,
        Object,
        binary:split(Name, <<".">>, [global])
    ).

operator_get_attr({py_ref, _} = Object, <<"__class__">>) ->
    try pyrlang_object:get_attr(Object, <<"__class__">>) of
        Class -> Class
    catch
        error:{attribute_error, _} ->
            case pyrlang_builtins:object_class(Object) of
                undefined -> erlang:error({attribute_error, <<"__class__">>});
                Class -> Class
            end
    end;
operator_get_attr(Object, Name) ->
    pyrlang_object:get_attr(Object, Name).

operator_itemgetter([]) ->
    erlang:error({arity_error, {itemgetter, 0}});
operator_itemgetter(Items) ->
    fun(Object) ->
        Values = [operator_getitem(Object, Item) || Item <- Items],
        case Values of
            [Value] -> Value;
            _ -> list_to_tuple(Values)
        end
    end.

operator_methodcaller([], _KwArgs) ->
    erlang:error({arity_error, {methodcaller, 0}});
operator_methodcaller([Name | BoundArgs], BoundKwArgs) ->
    MethodName = normalize_name(Name),
    {py_native_call, fun
        ([Object | CallArgs], CallKwArgs) ->
            Method = operator_get_attr(Object, MethodName),
            pyrlang_eval:call(
                Method, {call_args, BoundArgs ++ CallArgs, maps:merge(BoundKwArgs, CallKwArgs)}
            );
        (Args, _CallKwArgs) ->
            erlang:error({arity_error, {methodcaller_call, length(Args)}})
    end}.

operator_eq(Left, Right) -> Left =:= Right.
operator_ne(Left, Right) -> Left =/= Right.
operator_lt(Left, Right) -> Left < Right.
operator_le(Left, Right) -> Left =< Right.
operator_gt(Left, Right) -> Left > Right.
operator_ge(Left, Right) -> Left >= Right.

operator_add(Left, Right) when is_number(Left), is_number(Right) ->
    Left + Right;
operator_add(Left, Right) when is_binary(Left), is_binary(Right) ->
    <<Left/binary, Right/binary>>;
operator_add({py_ref, _} = Left, {py_ref, _} = Right) ->
    case {pyrlang_heap:type(Left), pyrlang_heap:type(Right)} of
        {list, list} ->
            pyrlang_heap:list(pyrlang_heap:list_items(Left) ++ pyrlang_heap:list_items(Right));
        _ ->
            operator_binary_special(Left, Right, <<"__add__">>, <<"__radd__">>, operator_add)
    end;
operator_add(Left, Right) ->
    operator_binary_special(Left, Right, <<"__add__">>, <<"__radd__">>, operator_add).

operator_sub(Left, Right) ->
    case operator_numeric_values(Left, Right) of
        {ok, LNum, RNum} -> LNum - RNum;
        error -> operator_binary_special(Left, Right, <<"__sub__">>, <<"__rsub__">>, operator_sub)
    end.

operator_mul(Left, Right) when is_binary(Left), (is_integer(Right) orelse is_boolean(Right)) ->
    binary:copy(Left, operator_repeat_count(operator_int(Right)));
operator_mul(Left, Right) when (is_integer(Left) orelse is_boolean(Left)), is_binary(Right) ->
    binary:copy(Right, operator_repeat_count(operator_int(Left)));
operator_mul(Left, Right) when is_tuple(Left), (is_integer(Right) orelse is_boolean(Right)) ->
    list_to_tuple(
        lists:append(
            lists:duplicate(operator_repeat_count(operator_int(Right)), tuple_to_list(Left))
        )
    );
operator_mul(Left, Right) when (is_integer(Left) orelse is_boolean(Left)), is_tuple(Right) ->
    list_to_tuple(
        lists:append(
            lists:duplicate(operator_repeat_count(operator_int(Left)), tuple_to_list(Right))
        )
    );
operator_mul(Left, Right) ->
    case operator_numeric_values(Left, Right) of
        {ok, LNum, RNum} -> LNum * RNum;
        error -> operator_binary_special(Left, Right, <<"__mul__">>, <<"__rmul__">>, operator_mul)
    end.

operator_truediv(Left, Right) ->
    case operator_numeric_values(Left, Right) of
        {ok, _LNum, 0} ->
            operator_raise(<<"ZeroDivisionError">>, <<"division by zero">>);
        {ok, LNum, RNum} ->
            LNum / RNum;
        error ->
            operator_binary_special(
                Left, Right, <<"__truediv__">>, <<"__rtruediv__">>, operator_truediv
            )
    end.

operator_floordiv(Left, Right) ->
    case operator_numeric_values(Left, Right) of
        {ok, _LNum, 0} ->
            operator_raise(<<"ZeroDivisionError">>, <<"integer division or modulo by zero">>);
        {ok, LNum, RNum} ->
            floor(LNum / RNum);
        error ->
            operator_binary_special(
                Left, Right, <<"__floordiv__">>, <<"__rfloordiv__">>, operator_floordiv
            )
    end.

operator_mod(Left, Right) ->
    case operator_numeric_values(Left, Right) of
        {ok, _LNum, 0} -> operator_raise(<<"ZeroDivisionError">>, <<"integer modulo by zero">>);
        {ok, LNum, RNum} -> LNum - floor(LNum / RNum) * RNum;
        error -> operator_binary_special(Left, Right, <<"__mod__">>, <<"__rmod__">>, operator_mod)
    end.

operator_pow(Left, Right) ->
    case operator_numeric_values(Left, Right) of
        {ok, LNum, RNum} when is_integer(LNum), is_integer(RNum), RNum >= 0 ->
            operator_integer_pow(LNum, RNum, 1);
        {ok, LNum, RNum} ->
            math:pow(LNum, RNum);
        error ->
            operator_binary_special(Left, Right, <<"__pow__">>, <<"__rpow__">>, operator_pow)
    end.

operator_neg(Value) ->
    case operator_numeric_value(Value) of
        {ok, Num} -> -Num;
        error -> operator_unary_special(Value, <<"__neg__">>, operator_neg)
    end.

operator_pos(Value) ->
    case operator_numeric_value(Value) of
        {ok, Num} -> Num;
        error -> operator_unary_special(Value, <<"__pos__">>, operator_pos)
    end.

operator_abs(Value) ->
    case operator_numeric_value(Value) of
        {ok, Num} -> erlang:abs(Num);
        error -> operator_unary_special(Value, <<"__abs__">>, operator_abs)
    end.

operator_and(Left, Right) ->
    case operator_integer_values(Left, Right) of
        {ok, LNum, RNum} -> LNum band RNum;
        error -> operator_binary_special(Left, Right, <<"__and__">>, <<"__rand__">>, operator_and)
    end.

operator_or(Left, Right) when
    (is_integer(Left) orelse is_boolean(Left)), (is_integer(Right) orelse is_boolean(Right))
->
    operator_int(Left) bor operator_int(Right);
operator_or({py_ref, _} = Left, Right) ->
    case pyrlang_heap:type(Left) of
        set ->
            pyrlang_heap:set(pyrlang_heap:set_items(Left) ++ pyrlang_iter:values(Right));
        dict ->
            pyrlang_heap:dict(pyrlang_heap:dict_items(Left) ++ operator_mapping_items(Right));
        _ ->
            operator_or_special(Left, Right)
    end;
operator_or(Left, Right) ->
    operator_or_special(Left, Right).

operator_xor(Left, Right) ->
    case operator_integer_values(Left, Right) of
        {ok, LNum, RNum} -> LNum bxor RNum;
        error -> operator_binary_special(Left, Right, <<"__xor__">>, <<"__rxor__">>, operator_xor)
    end.

operator_invert(Value) ->
    case operator_integer_value(Value) of
        {ok, Num} -> bnot Num;
        error -> operator_unary_special(Value, <<"__invert__">>, operator_invert)
    end.

operator_lshift(Left, Right) ->
    case operator_integer_values(Left, Right) of
        {ok, _LNum, RNum} when RNum < 0 ->
            operator_raise(<<"ValueError">>, <<"negative shift count">>);
        {ok, LNum, RNum} ->
            LNum bsl RNum;
        error ->
            operator_binary_special(
                Left, Right, <<"__lshift__">>, <<"__rlshift__">>, operator_lshift
            )
    end.

operator_rshift(Left, Right) ->
    case operator_integer_values(Left, Right) of
        {ok, _LNum, RNum} when RNum < 0 ->
            operator_raise(<<"ValueError">>, <<"negative shift count">>);
        {ok, LNum, RNum} ->
            LNum bsr RNum;
        error ->
            operator_binary_special(
                Left, Right, <<"__rshift__">>, <<"__rrshift__">>, operator_rshift
            )
    end.

operator_or_special(Left, Right) ->
    case pyrlang_builtins:type_union(Left, Right) of
        {ok, Union} ->
            Union;
        error ->
            case operator_call_special(Left, <<"__or__">>, [Right]) of
                {ok, Value} ->
                    Value;
                error ->
                    case operator_call_special(Right, <<"__ror__">>, [Left]) of
                        {ok, Value} -> Value;
                        error -> erlang:error({type_error, {operator_or, Left, Right}})
                    end
            end
    end.

operator_call_special({py_ref, _} = Object, Method, Args) ->
    try pyrlang_object:get_attr(Object, Method) of
        Callable ->
            case pyrlang_eval:call(Callable, Args) of
                not_implemented -> error;
                Value -> {ok, Value}
            end
    catch
        error:{attribute_error, _Attr} -> error
    end;
operator_call_special(_Object, _Method, _Args) ->
    error.

operator_binary_special(Left, Right, Method, ReflectedMethod, ErrorName) ->
    case operator_call_special(Left, Method, [Right]) of
        {ok, Value} ->
            Value;
        error ->
            case operator_call_special(Right, ReflectedMethod, [Left]) of
                {ok, Value} -> Value;
                error -> erlang:error({type_error, {ErrorName, Left, Right}})
            end
    end.

operator_unary_special(Value, Method, ErrorName) ->
    case operator_call_special(Value, Method, []) of
        {ok, Result} -> Result;
        error -> erlang:error({type_error, {ErrorName, Value}})
    end.

operator_numeric_values(Left, Right) ->
    case {operator_numeric_value(Left), operator_numeric_value(Right)} of
        {{ok, LNum}, {ok, RNum}} -> {ok, LNum, RNum};
        _ -> error
    end.

operator_numeric_value(true) ->
    {ok, 1};
operator_numeric_value(false) ->
    {ok, 0};
operator_numeric_value(Value) when is_integer(Value); is_float(Value) ->
    {ok, Value};
operator_numeric_value({py_ref, _} = Value) ->
    pyrlang_builtins:int_subclass_value(Value);
operator_numeric_value(_Value) ->
    error.

operator_integer_values(Left, Right) ->
    case {operator_integer_value(Left), operator_integer_value(Right)} of
        {{ok, LNum}, {ok, RNum}} -> {ok, LNum, RNum};
        _ -> error
    end.

operator_integer_value(true) ->
    {ok, 1};
operator_integer_value(false) ->
    {ok, 0};
operator_integer_value(Value) when is_integer(Value) ->
    {ok, Value};
operator_integer_value({py_ref, _} = Value) ->
    pyrlang_builtins:int_subclass_value(Value);
operator_integer_value(_Value) ->
    error.

operator_int(true) -> 1;
operator_int(false) -> 0;
operator_int(Value) -> Value.

operator_repeat_count(Count) when Count < 0 ->
    0;
operator_repeat_count(Count) ->
    Count.

operator_integer_pow(_Base, 0, Acc) ->
    Acc;
operator_integer_pow(Base, Exp, Acc) when Exp rem 2 =:= 1 ->
    operator_integer_pow(Base * Base, Exp div 2, Acc * Base);
operator_integer_pow(Base, Exp, Acc) ->
    operator_integer_pow(Base * Base, Exp div 2, Acc).

operator_raise(Type, Message) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(Type), Message)).

operator_mapping_items({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> pyrlang_heap:dict_items(Ref);
        Type -> erlang:error({type_error, {operator_mapping, Type}})
    end;
operator_mapping_items(Map) when is_map(Map) ->
    maps:to_list(Map);
operator_mapping_items(Other) ->
    erlang:error({type_error, {operator_mapping, Other}}).

operator_index(Value) when is_integer(Value) ->
    Value;
operator_index(true) ->
    1;
operator_index(false) ->
    0;
operator_index({py_ref, _} = Object) ->
    Method = pyrlang_object:get_attr(Object, <<"__index__">>),
    pyrlang_eval:call(Method, []);
operator_index(Value) ->
    erlang:error({type_error, {operator_index, Value}}).

operator_getitem({py_ref, _} = Ref, Index) ->
    try
        case pyrlang_heap:type(Ref) of
            list when is_integer(Index) -> pyrlang_heap:list_get(Ref, Index);
            dict ->
                pyrlang_heap:dict_get(Ref, Index);
            instance ->
                case operator_tuple_subclass_items(Ref) of
                    {ok, Items} when is_integer(Index) ->
                        lists:nth(operator_normalize_index(Index, length(Items)) + 1, Items);
                    _ ->
                        GetItem = pyrlang_object:get_attr(Ref, <<"__getitem__">>),
                        pyrlang_eval:call(GetItem, [Index])
                end;
            Type ->
                erlang:error({type_error, {getitem, Type}})
        end
    catch
        error:{badkey, Missing} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Missing)
            );
        error:{attribute_error, _Name} ->
            operator_raise(<<"TypeError">>, <<"object is not subscriptable">>);
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> ->
                    operator_raise(<<"TypeError">>, <<"object is not subscriptable">>);
                _ ->
                    pyrlang_exception:raise(Exception)
            end
    end;
operator_getitem(Binary, Index) when is_binary(Binary), is_integer(Index) ->
    Chars = [<<Char/utf8>> || <<Char/utf8>> <= Binary],
    lists:nth(operator_normalize_index(Index, length(Chars)) + 1, Chars);
operator_getitem(Tuple, Index) when is_tuple(Tuple), is_integer(Index) ->
    element(operator_normalize_index(Index, tuple_size(Tuple)) + 1, Tuple).

operator_setitem({py_ref, _} = Ref, Index, Value) ->
    case pyrlang_heap:type(Ref) of
        list when is_integer(Index) -> pyrlang_heap:list_set(Ref, Index, Value);
        dict -> pyrlang_heap:dict_put(Ref, Index, Value);
        Type -> erlang:error({type_error, {setitem, Type}})
    end,
    none.

operator_delitem(_Object, _Index) ->
    none.

operator_contains(Container, Item) ->
    Key = pyrlang_heap:value_key(Item),
    lists:any(
        fun(Value) -> pyrlang_heap:value_key(Value) =:= Key end, pyrlang_iter:values(Container)
    ).

operator_normalize_index(Index, Length) when Index < 0 ->
    Normalized = Length + Index,
    case Normalized >= 0 of
        true -> Normalized;
        false -> erlang:error({index_error, Index})
    end;
operator_normalize_index(Index, Length) when Index >= 0, Index < Length ->
    Index;
operator_normalize_index(Index, _Length) ->
    erlang:error({index_error, Index}).

operator_tuple_subclass_items({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
            case maps:find(<<"__pyrlang_tuple_items__">>, Attrs) of
                {ok, Tuple} when is_tuple(Tuple) -> {ok, tuple_to_list(Tuple)};
                _ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.

bisect_right([A, X]) ->
    bisect_right([A, X, 0, none]);
bisect_right([A, X, Lo]) ->
    bisect_right([A, X, Lo, none]);
bisect_right([A, X, Lo0, Hi0]) when is_integer(Lo0) ->
    Values = pyrlang_iter:values(A),
    Hi =
        case Hi0 of
            none -> length(Values);
            Int when is_integer(Int) -> Int
        end,
    bisect_right_values(Values, X, Lo0, Hi, 0);
bisect_right(Args) ->
    erlang:error({arity_error, {bisect_right, length(Args)}}).

bisect_right_values([], _X, _Lo, Hi, _Index) ->
    Hi;
bisect_right_values([_Value | Rest], X, Lo, Hi, Index) when Index < Lo ->
    bisect_right_values(Rest, X, Lo, Hi, Index + 1);
bisect_right_values(_Values, _X, _Lo, Hi, Index) when Index >= Hi ->
    Hi;
bisect_right_values([Value | Rest], X, Lo, Hi, Index) ->
    case X < Value of
        true -> Index;
        false -> bisect_right_values(Rest, X, Lo, Hi, Index + 1)
    end.

bisect_left([A, X]) ->
    bisect_left([A, X, 0, none]);
bisect_left([A, X, Lo]) ->
    bisect_left([A, X, Lo, none]);
bisect_left([A, X, Lo0, Hi0]) when is_integer(Lo0) ->
    Values = pyrlang_iter:values(A),
    Hi =
        case Hi0 of
            none -> length(Values);
            Int when is_integer(Int) -> Int
        end,
    bisect_left_values(Values, X, Lo0, Hi, 0);
bisect_left(Args) ->
    erlang:error({arity_error, {bisect_left, length(Args)}}).

bisect_left_values([], _X, _Lo, Hi, _Index) ->
    Hi;
bisect_left_values([_Value | Rest], X, Lo, Hi, Index) when Index < Lo ->
    bisect_left_values(Rest, X, Lo, Hi, Index + 1);
bisect_left_values(_Values, _X, _Lo, Hi, Index) when Index >= Hi ->
    Hi;
bisect_left_values([Value | Rest], X, Lo, Hi, Index) ->
    case Value < X of
        true -> bisect_left_values(Rest, X, Lo, Hi, Index + 1);
        false -> Index
    end.

insort_right([A, X] = Args) ->
    bisect_insert(A, bisect_right(Args), X),
    none;
insort_right([A, X, _Lo] = Args) ->
    bisect_insert(A, bisect_right(Args), X),
    none;
insort_right([A, X, Lo, Hi] = Args) ->
    _ = Lo,
    _ = Hi,
    bisect_insert(A, bisect_right(Args), X),
    none;
insort_right(Args) ->
    erlang:error({arity_error, {insort_right, length(Args)}}).

insort_left([A, X] = Args) ->
    bisect_insert(A, bisect_left(Args), X),
    none;
insort_left([A, X, _Lo] = Args) ->
    bisect_insert(A, bisect_left(Args), X),
    none;
insort_left([A, X, Lo, Hi] = Args) ->
    _ = Lo,
    _ = Hi,
    bisect_insert(A, bisect_left(Args), X),
    none;
insort_left(Args) ->
    erlang:error({arity_error, {insort_left, length(Args)}}).

bisect_insert({py_ref, _} = A, Index, X) ->
    case pyrlang_heap:type(A) of
        list ->
            ok = pyrlang_heap:list_insert(A, Index, X);
        _ ->
            _ = pyrlang_eval:call(pyrlang_object:get_attr(A, <<"insert">>), [Index, X]),
            ok
    end.

builtin_atom(Value) ->
    Name = normalize_name(Value),
    try
        binary_to_existing_atom(Name, utf8)
    catch
        error:badarg ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>), <<"unknown atom: ", Name/binary>>
                )
            )
    end.

builtin_apply([Module, Function, ArgsValue], KwArgs) when map_size(KwArgs) =:= 0 ->
    ModuleAtom = existing_atom_or_raise(Module),
    FunctionAtom = existing_atom_or_raise(Function),
    Args = [to_erl_value(Arg) || Arg <- pyrlang_iter:values(ArgsValue)],
    from_erl_value(erlang:apply(ModuleAtom, FunctionAtom, Args));
builtin_apply(Args, _KwArgs) ->
    erlang:error({arity_error, {erlang_apply, length(Args)}}).

builtin_register(Name, Pid) ->
    pyrlang_actor:register(existing_atom_or_raise(Name), Pid).

builtin_whereis(Name) ->
    case existing_atom(Name) of
        {ok, Atom} ->
            case pyrlang_actor:whereis(Atom) of
                undefined -> none;
                Pid -> Pid
            end;
        error ->
            none
    end.

existing_atom_or_raise(Value) ->
    Name = normalize_name(Value),
    case existing_atom(Name) of
        {ok, Atom} ->
            Atom;
        error ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>), <<"unknown atom: ", Name/binary>>
                )
            )
    end.

existing_atom(Value) ->
    Name = normalize_name(Value),
    try
        {ok, binary_to_existing_atom(Name, utf8)}
    catch
        error:badarg -> error
    end.

to_erl_value(none) ->
    undefined;
to_erl_value({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list ->
            [to_erl_value(Item) || Item <- pyrlang_heap:list_items(Ref)];
        dict ->
            maps:from_list([
                {to_erl_value(Key), to_erl_value(Value)}
             || {Key, Value} <- pyrlang_heap:dict_items(Ref)
            ]);
        set ->
            [to_erl_value(Item) || Item <- pyrlang_heap:set_items(Ref)];
        Type ->
            erlang:error({type_error, {cannot_convert_to_erlang, Type}})
    end;
to_erl_value(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([to_erl_value(Item) || Item <- tuple_to_list(Tuple)]);
to_erl_value(List) when is_list(List) ->
    [to_erl_value(Item) || Item <- List];
to_erl_value(Value) ->
    Value.

from_erl_value(undefined) ->
    none;
from_erl_value(List) when is_list(List) ->
    pyrlang_heap:list([from_erl_value(Item) || Item <- List]);
from_erl_value(Map) when is_map(Map) ->
    pyrlang_heap:dict([
        {from_erl_value(Key), from_erl_value(Value)}
     || {Key, Value} <- maps:to_list(Map)
    ]);
from_erl_value(Tuple) when is_tuple(Tuple), tuple_size(Tuple) > 0, element(1, Tuple) =:= py_ref ->
    Tuple;
from_erl_value(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([from_erl_value(Item) || Item <- tuple_to_list(Tuple)]);
from_erl_value(Value) ->
    Value.

re_compile_args([Pattern]) ->
    re_compile(Pattern, 0);
re_compile_args([Pattern, Flags]) ->
    re_compile(Pattern, Flags);
re_compile_args(Args) ->
    erlang:error({arity_error, {re_compile, length(Args)}}).

re_compile(Pattern, Flags) ->
    PatternSpec = re_prepare(Pattern, Flags),
    {PatternBin, _Options} = PatternSpec,
    native_instance(<<"RegexPattern">>, #{
        <<"pattern">> => PatternBin,
        <<"match">> => {py_native_varargs, fun(Args) -> re_pattern_match(PatternSpec, Args) end},
        <<"search">> => {py_native_varargs, fun(Args) -> re_pattern_search(PatternSpec, Args) end},
        <<"fullmatch">> =>
            {py_native_varargs, fun(Args) -> re_pattern_fullmatch(PatternSpec, Args) end},
        <<"findall">> =>
            {py_native_varargs, fun(Args) -> re_pattern_findall(PatternSpec, Args) end},
        <<"finditer">> =>
            {py_native_varargs, fun(Args) -> re_pattern_finditer(PatternSpec, Args) end},
        <<"split">> => {py_native_varargs, fun(Args) -> re_pattern_split(PatternSpec, Args) end},
        <<"sub">> => {py_native_varargs, fun(Args) -> re_pattern_sub(PatternSpec, Args) end}
    }).

re_pattern_match(Pattern, [Text]) ->
    run_re(Pattern, Text, [anchored]);
re_pattern_match(Pattern, [Text, Pos]) ->
    run_re(Pattern, Text, [anchored, {offset, re_offset(Pos)}]);
re_pattern_match(Pattern, [Text, Pos, _EndPos]) ->
    run_re(Pattern, Text, [anchored, {offset, re_offset(Pos)}]);
re_pattern_match(_Pattern, Args) ->
    erlang:error({arity_error, {re_pattern_match, length(Args)}}).

re_pattern_search(Pattern, [Text]) ->
    run_re(Pattern, Text, []);
re_pattern_search(Pattern, [Text, Pos]) ->
    run_re(Pattern, Text, [{offset, re_offset(Pos)}]);
re_pattern_search(Pattern, [Text, Pos, _EndPos]) ->
    run_re(Pattern, Text, [{offset, re_offset(Pos)}]);
re_pattern_search(_Pattern, Args) ->
    erlang:error({arity_error, {re_pattern_search, length(Args)}}).

re_pattern_fullmatch(Pattern, [Text]) ->
    re_fullmatch_spec(Pattern, Text);
re_pattern_fullmatch(Pattern, [Text, Pos]) ->
    re_fullmatch_spec(Pattern, Text, re_offset(Pos));
re_pattern_fullmatch(Pattern, [Text, Pos, _EndPos]) ->
    re_fullmatch_spec(Pattern, Text, re_offset(Pos));
re_pattern_fullmatch(_Pattern, Args) ->
    erlang:error({arity_error, {re_pattern_fullmatch, length(Args)}}).

re_match_args([Pattern, Text]) ->
    run_re(re_prepare(Pattern, 0), Text, [anchored]);
re_match_args([Pattern, Text, Flags]) ->
    run_re(re_prepare(Pattern, Flags), Text, [anchored]);
re_match_args(Args) ->
    erlang:error({arity_error, {re_match, length(Args)}}).

re_search_args([Pattern, Text]) ->
    run_re(re_prepare(Pattern, 0), Text, []);
re_search_args([Pattern, Text, Flags]) ->
    run_re(re_prepare(Pattern, Flags), Text, []);
re_search_args(Args) ->
    erlang:error({arity_error, {re_search, length(Args)}}).

re_fullmatch_args([Pattern, Text]) ->
    re_fullmatch_spec(re_prepare(Pattern, 0), Text);
re_fullmatch_args([Pattern, Text, Flags]) ->
    re_fullmatch_spec(re_prepare(Pattern, Flags), Text);
re_fullmatch_args(Args) ->
    erlang:error({arity_error, {re_fullmatch, length(Args)}}).

re_fullmatch_spec({Pattern, Options}, Text) ->
    Wrapped = <<"^(?:", Pattern/binary, ")$">>,
    run_re({Wrapped, Options}, Text, []).

re_fullmatch_spec({Pattern, Options}, Text, Pos) ->
    Wrapped = <<"^(?:", Pattern/binary, ")$">>,
    run_re({Wrapped, Options}, Text, [{offset, Pos}]).

re_offset(Value) when is_integer(Value), Value >= 0 ->
    Value;
re_offset(false) ->
    0;
re_offset(true) ->
    1;
re_offset(_Value) ->
    0.

re_escape(Value) ->
    iolist_to_binary([re_escape_byte(Byte) || <<Byte:8>> <= normalize_name(Value)]).

re_escape_byte(Byte) ->
    case lists:member(Byte, ".^$*+?{}[]\\|()# \t\n\r\v\f-") of
        false -> <<Byte>>;
        true -> <<"\\", Byte>>
    end.

re_sub_args([Pattern, Replacement, Text]) ->
    re_sub(Pattern, Replacement, Text, 0);
re_sub_args([Pattern, Replacement, Text, Count]) ->
    re_sub(Pattern, Replacement, Text, Count);
re_sub_args([Pattern, Replacement, Text, Count, _Flags]) ->
    re_sub(Pattern, Replacement, Text, Count);
re_sub_args(Args) ->
    erlang:error({arity_error, {re_sub, length(Args)}}).

re_findall_args([Pattern, Text]) ->
    re_findall(re_prepare(Pattern, 0), Text);
re_findall_args([Pattern, Text, Flags]) ->
    re_findall(re_prepare(Pattern, Flags), Text);
re_findall_args(Args) ->
    erlang:error({arity_error, {re_findall, length(Args)}}).

re_split_args([Pattern, Text]) ->
    re_split(re_prepare(Pattern, 0), Text, 0);
re_split_args([Pattern, Text, MaxSplit]) ->
    re_split(re_prepare(Pattern, 0), Text, MaxSplit);
re_split_args([Pattern, Text, MaxSplit, Flags]) ->
    re_split(re_prepare(Pattern, Flags), Text, MaxSplit);
re_split_args(Args) ->
    erlang:error({arity_error, {re_split, length(Args)}}).

re_pattern_sub(Pattern, [Replacement, Text]) ->
    re_sub(Pattern, Replacement, Text, 0);
re_pattern_sub(Pattern, [Replacement, Text, Count]) ->
    re_sub(Pattern, Replacement, Text, Count);
re_pattern_sub(_Pattern, Args) ->
    erlang:error({arity_error, {re_pattern_sub, length(Args)}}).

re_pattern_split(Pattern, [Text]) ->
    re_split(Pattern, Text, 0);
re_pattern_split(Pattern, [Text, MaxSplit]) when is_integer(MaxSplit), MaxSplit >= 0 ->
    re_split(Pattern, Text, MaxSplit);
re_pattern_split(_Pattern, Args) ->
    erlang:error({arity_error, {re_pattern_split, length(Args)}}).

re_pattern_findall(Pattern, [Text]) ->
    re_findall(Pattern, Text);
re_pattern_findall(_Pattern, Args) ->
    erlang:error({arity_error, {re_pattern_findall, length(Args)}}).

re_finditer_args([Pattern, Text]) ->
    re_finditer(re_prepare(Pattern, 0), Text);
re_finditer_args([Pattern, Text, Flags]) ->
    re_finditer(re_prepare(Pattern, Flags), Text);
re_finditer_args(Args) ->
    erlang:error({arity_error, {re_finditer, length(Args)}}).

re_pattern_finditer(Pattern, [Text]) ->
    re_finditer(Pattern, Text);
re_pattern_finditer(_Pattern, Args) ->
    erlang:error({arity_error, {re_pattern_finditer, length(Args)}}).

re_findall(Pattern, Text) ->
    TextBin = normalize_name(Text),
    {PatternBin, Options} = re_prepare_existing(Pattern),
    Values =
        case re:run(TextBin, PatternBin, Options ++ [global, {capture, all, index}]) of
            {match, Matches} ->
                [re_findall_value(TextBin, Match) || Match <- Matches];
            nomatch ->
                [];
            {error, Reason} ->
                pyrlang_exception:raise(
                    pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Reason)
                )
        end,
    pyrlang_heap:list(Values).

re_finditer(Pattern, Text) ->
    TextBin = normalize_name(Text),
    {PatternBin, Options} = re_prepare_existing(Pattern),
    Matches =
        case re:run(TextBin, PatternBin, Options ++ [global, {capture, all, index}]) of
            {match, Found} ->
                Found;
            nomatch ->
                [];
            {error, Reason} ->
                pyrlang_exception:raise(
                    pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Reason)
                )
        end,
    pyrlang_heap:list([re_match_object(TextBin, PatternBin, Match) || Match <- Matches]).

re_findall_value(Text, [{Start, Len}]) ->
    binary:part(Text, Start, Len);
re_findall_value(Text, [_Whole, Capture]) ->
    re_split_capture(Text, Capture);
re_findall_value(Text, [_Whole | Captures]) ->
    list_to_tuple([re_split_capture(Text, Capture) || Capture <- Captures]).

re_split(Pattern, Text, MaxSplit) ->
    TextBin = normalize_name(Text),
    {PatternBin, Options} = re_prepare_existing(Pattern),
    Matches =
        case re:run(TextBin, PatternBin, Options ++ [global, {capture, all, index}]) of
            {match, Found} ->
                limit_re_splits(Found, MaxSplit);
            nomatch ->
                [];
            {error, Reason} ->
                pyrlang_exception:raise(
                    pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Reason)
                )
        end,
    pyrlang_heap:list(re_split_parts(TextBin, Matches, 0, [])).

limit_re_splits(Matches, 0) ->
    Matches;
limit_re_splits(Matches, MaxSplit) ->
    {Limited, _Rest} = lists:split(min(MaxSplit, length(Matches)), Matches),
    Limited.

re_split_parts(Text, [], Offset, Acc) ->
    Suffix = binary:part(Text, Offset, byte_size(Text) - Offset),
    lists:reverse([Suffix | Acc]);
re_split_parts(Text, [[{Start, Len} | Captures] | Rest], Offset, Acc) ->
    Prefix = binary:part(Text, Offset, Start - Offset),
    CaptureValues = [re_split_capture(Text, Capture) || Capture <- Captures],
    re_split_parts(Text, Rest, Start + Len, lists:reverse([Prefix | CaptureValues]) ++ Acc).

re_split_capture(_Text, {-1, _Len}) ->
    none;
re_split_capture(Text, Span) ->
    re_capture(Text, Span).

re_sub(Pattern, Replacement, Text, Count) when is_integer(Count), Count >= 0 ->
    {PatternBin, Options} = re_prepare_existing(Pattern),
    TextBin = normalize_name(Text),
    Limit =
        case Count of
            0 -> unlimited;
            _ -> Count
        end,
    re_sub_loop(PatternBin, Options, Replacement, TextBin, Limit, 0, 0, []);
re_sub(_Pattern, _Replacement, _Text, Count) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), {invalid_count, Count})
    ).

re_sub_loop(_Pattern, _Options, _Replacement, Text, Limit, Done, Offset, Acc) when
    Limit =/= unlimited, Done >= Limit
->
    re_sub_finish(Text, Offset, Acc);
re_sub_loop(Pattern, Options, Replacement, Text, Limit, Done, Offset, Acc) ->
    case re:run(Text, Pattern, Options ++ [{offset, Offset}, {capture, all, index}]) of
        {match, [{Start, Len} | _] = Spans} ->
            Prefix = binary:part(Text, Offset, Start - Offset),
            Match = re_match_object(Text, Pattern, Spans),
            Repl = re_replacement(Replacement, Match),
            case {Len, Start < byte_size(Text)} of
                {0, true} ->
                    Char = binary:part(Text, Start, 1),
                    re_sub_loop(Pattern, Options, Replacement, Text, Limit, Done + 1, Start + 1, [
                        Char, Repl, Prefix | Acc
                    ]);
                _ ->
                    re_sub_loop(Pattern, Options, Replacement, Text, Limit, Done + 1, Start + Len, [
                        Repl, Prefix | Acc
                    ])
            end;
        nomatch ->
            re_sub_finish(Text, Offset, Acc);
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Reason)
            )
    end.

re_sub_finish(Text, Offset, Acc) ->
    Suffix = binary:part(Text, Offset, byte_size(Text) - Offset),
    iolist_to_binary(lists:reverse([Suffix | Acc])).

re_replacement(Replacement, Match) ->
    case re_callable(Replacement) of
        true -> normalize_name(pyrlang_eval:call(Replacement, [Match]));
        false -> normalize_name(Replacement)
    end.

re_callable(Value) when is_function(Value) -> true;
re_callable({py_bound_method, _Callable, _Self}) ->
    true;
re_callable({py_function, _Params, _Body, _Env}) ->
    true;
re_callable({py_function, _Params, _Body, _Env, _IsGenerator}) ->
    true;
re_callable({py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass}) ->
    true;
re_callable({py_native_varargs, _Fun}) ->
    true;
re_callable({py_native_callable, _Fun}) ->
    true;
re_callable({py_native_call, _Fun}) ->
    true;
re_callable({py_exception_type, _Type}) ->
    true;
re_callable({py_ref, _} = Ref) ->
    try
        case pyrlang_heap:type(Ref) of
            class ->
                true;
            _ ->
                _ = pyrlang_object:get_attr(Ref, <<"__call__">>),
                true
        end
    catch
        error:{attribute_error, _Name} -> false
    end;
re_callable(_Value) ->
    false.

run_re({Pattern, RunOptions}, Text, Options) ->
    TextBin = normalize_name(Text),
    case re:run(TextBin, Pattern, Options ++ RunOptions ++ [{capture, all, index}]) of
        {match, Spans} ->
            re_match_object(TextBin, Pattern, Spans);
        nomatch ->
            none;
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Reason)
            )
    end.

re_prepare_existing({Pattern, Options}) when is_binary(Pattern), is_list(Options) ->
    {Pattern, Options};
re_prepare_existing(Pattern) ->
    re_prepare(Pattern, 0).

re_prepare(Pattern, Flags0) ->
    Flags = numeric_flag_value(Flags0),
    PatternBin0 = normalize_name(Pattern),
    PatternBin = re_apply_verbose(PatternBin0, Flags),
    {PatternBin, re_options(Flags)}.

numeric_flag_value(Flags) when is_integer(Flags) ->
    Flags;
numeric_flag_value(true) ->
    1;
numeric_flag_value(false) ->
    0;
numeric_flag_value(_Flags) ->
    0.

re_options(Flags) ->
    lists:filtermap(
        fun({Bit, Option}) ->
            case Flags band Bit of
                0 -> false;
                _ -> {true, Option}
            end
        end,
        [{2, caseless}, {8, multiline}, {16, dotall}]
    ).

re_apply_verbose(Pattern, Flags) ->
    case Flags band 64 of
        0 -> Pattern;
        _ -> re_strip_verbose(Pattern)
    end.

re_strip_verbose(Pattern) ->
    re_strip_verbose(Pattern, false, false, []).

re_strip_verbose(<<>>, _Escaped, _InClass, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
re_strip_verbose(<<$\\, Rest/binary>>, false, InClass, Acc) ->
    case Rest of
        <<Next, Tail/binary>> ->
            re_strip_verbose(Tail, false, InClass, [Next, $\\ | Acc]);
        <<>> ->
            re_strip_verbose(<<>>, false, InClass, [$\\ | Acc])
    end;
re_strip_verbose(<<$[, Rest/binary>>, false, false, Acc) ->
    re_strip_verbose(Rest, false, true, [$[ | Acc]);
re_strip_verbose(<<$], Rest/binary>>, false, true, Acc) ->
    re_strip_verbose(Rest, false, false, [$] | Acc]);
re_strip_verbose(<<$#, Rest/binary>>, false, false, Acc) ->
    re_strip_verbose(skip_re_verbose_comment(Rest), false, false, Acc);
re_strip_verbose(<<Char, Rest/binary>>, false, false, Acc) when
    Char =:= $\s; Char =:= $\t; Char =:= $\n; Char =:= $\r; Char =:= $\f; Char =:= $\v
->
    re_strip_verbose(Rest, false, false, Acc);
re_strip_verbose(<<Char, Rest/binary>>, _Escaped, InClass, Acc) ->
    re_strip_verbose(Rest, false, InClass, [Char | Acc]).

skip_re_verbose_comment(<<$\n, Rest/binary>>) ->
    Rest;
skip_re_verbose_comment(<<_Char, Rest/binary>>) ->
    skip_re_verbose_comment(Rest);
skip_re_verbose_comment(<<>>) ->
    <<>>.

re_match_object(Text, Pattern, Spans) ->
    {GroupNames, GroupCount} = re_capture_group_info(Pattern),
    PaddedSpans = re_pad_spans(Spans, GroupCount + 1),
    CharSpans = [re_byte_span_to_char_span(Text, Span) || Span <- PaddedSpans],
    Captures = [re_capture(Text, Span) || Span <- PaddedSpans],
    native_instance(<<"RegexMatch">>, #{
        <<"group">> => {py_native_varargs, fun(Args) -> re_group(Captures, GroupNames, Args) end},
        <<"groups">> =>
            {py_native_call, fun(Args, KwArgs) -> re_groups(Captures, Args, KwArgs) end},
        <<"groupdict">> =>
            {py_native_call, fun(Args, KwArgs) ->
                re_groupdict(Captures, GroupNames, Args, KwArgs)
            end},
        <<"__getitem__">> => fun(Key) -> re_group_by_key(Captures, GroupNames, Key) end,
        <<"start">> => {py_native_varargs, fun(Args) -> re_start(CharSpans, Args) end},
        <<"end">> => {py_native_varargs, fun(Args) -> re_end(CharSpans, Args) end},
        <<"span">> => {py_native_varargs, fun(Args) -> re_span(CharSpans, Args) end}
    }).

re_pad_spans(Spans, MinLength) when length(Spans) >= MinLength ->
    Spans;
re_pad_spans(Spans, MinLength) ->
    Spans ++ lists:duplicate(MinLength - length(Spans), {-1, 0}).

re_capture(_Text, {-1, _Len}) ->
    none;
re_capture(Text, {Start, Len}) ->
    binary:part(Text, Start, Len).

re_byte_span_to_char_span(_Text, {-1, _Len}) ->
    {-1, 0};
re_byte_span_to_char_span(Text, {Start, Len}) ->
    StartChar = re_byte_offset_to_char_offset(Text, Start),
    EndChar = re_byte_offset_to_char_offset(Text, Start + Len),
    {StartChar, EndChar - StartChar}.

re_byte_offset_to_char_offset(_Text, Offset) when Offset =< 0 ->
    Offset;
re_byte_offset_to_char_offset(Text, Offset) ->
    Prefix = binary:part(Text, 0, Offset),
    try length([Char || <<Char/utf8>> <= Prefix]) of
        Count -> Count
    catch
        _:_ -> Offset
    end.

re_group(Captures, []) ->
    hd(Captures);
re_group(Captures, [Index]) when is_integer(Index), Index >= 0, Index < length(Captures) ->
    lists:nth(Index + 1, Captures);
re_group(_Captures, [Index]) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"IndexError">>), Index)
    );
re_group(Captures, Args) ->
    list_to_tuple([re_group(Captures, [Index]) || Index <- Args]).

re_group(Captures, _GroupNames, []) ->
    re_group(Captures, []);
re_group(Captures, _GroupNames, [Index]) when is_integer(Index) ->
    re_group(Captures, [Index]);
re_group(Captures, GroupNames, [Key]) ->
    re_group_by_key(Captures, GroupNames, Key);
re_group(Captures, GroupNames, Args) ->
    list_to_tuple([re_group_by_key(Captures, GroupNames, Key) || Key <- Args]).

re_groups(Captures, Args, KwArgs) ->
    Default = re_default_arg(groups, Args, KwArgs),
    list_to_tuple([re_default_capture(Capture, Default) || Capture <- tl(Captures)]).

re_group_by_key(Captures, _GroupNames, Key) when is_integer(Key) ->
    re_group(Captures, [Key]);
re_group_by_key(Captures, GroupNames, Key) ->
    Name = normalize_name(Key),
    case maps:find(Name, GroupNames) of
        {ok, Index} ->
            re_group(Captures, [Index]);
        error ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"IndexError">>), Name)
            )
    end.

re_groupdict(Captures, GroupNames, Args, KwArgs) ->
    Default = re_default_arg(groupdict, Args, KwArgs),
    pyrlang_heap:dict([
        {Name, re_default_capture(re_group(Captures, [Index]), Default)}
     || {Name, Index} <- maps:to_list(GroupNames)
    ]).

re_default_arg(_Name, [], KwArgs) ->
    case maps:without([<<"default">>], KwArgs) of
        Empty when map_size(Empty) =:= 0 -> maps:get(<<"default">>, KwArgs, none);
        Extra -> erlang:error({type_error, {unexpected_keyword_argument, maps:keys(Extra)}})
    end;
re_default_arg(_Name, [Default], KwArgs) ->
    case maps:without([<<"default">>], KwArgs) of
        Empty when map_size(Empty) =:= 0 ->
            case maps:is_key(<<"default">>, KwArgs) of
                true -> erlang:error({type_error, {multiple_values_for_argument, <<"default">>}});
                false -> Default
            end;
        Extra ->
            erlang:error({type_error, {unexpected_keyword_argument, maps:keys(Extra)}})
    end;
re_default_arg(Name, Args, _KwArgs) ->
    erlang:error({arity_error, {Name, length(Args)}}).

re_default_capture(none, Default) ->
    Default;
re_default_capture(Capture, _Default) ->
    Capture.

re_capture_group_info(Pattern) ->
    re_capture_group_info(Pattern, 0, false, #{}).

re_capture_group_info(<<>>, Index, _InClass, Names) ->
    {Names, Index};
re_capture_group_info(<<$\\, _Escaped, Rest/binary>>, Index, InClass, Names) ->
    re_capture_group_info(Rest, Index, InClass, Names);
re_capture_group_info(<<$[, Rest/binary>>, Index, false, Names) ->
    re_capture_group_info(Rest, Index, true, Names);
re_capture_group_info(<<$], Rest/binary>>, Index, true, Names) ->
    re_capture_group_info(Rest, Index, false, Names);
re_capture_group_info(<<"(?P<", Rest/binary>>, Index, false, Names) ->
    {Name, AfterName} = take_re_group_name(Rest, []),
    NewIndex = Index + 1,
    re_capture_group_info(AfterName, NewIndex, false, Names#{Name => NewIndex});
re_capture_group_info(<<"(?", Rest/binary>>, Index, false, Names) ->
    re_capture_group_info(Rest, Index, false, Names);
re_capture_group_info(<<$(, Rest/binary>>, Index, false, Names) ->
    re_capture_group_info(Rest, Index + 1, false, Names);
re_capture_group_info(<<_Char, Rest/binary>>, Index, InClass, Names) ->
    re_capture_group_info(Rest, Index, InClass, Names).

take_re_group_name(<<$>, Rest/binary>>, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Rest};
take_re_group_name(<<Char, Rest/binary>>, Acc) ->
    take_re_group_name(Rest, [Char | Acc]);
take_re_group_name(<<>>, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), <<>>}.

re_start(Spans, Args) ->
    {Start, _Len} = re_span_value(Spans, Args),
    Start.

re_end(Spans, Args) ->
    {Start, Len} = re_span_value(Spans, Args),
    Start + Len.

re_span(Spans, Args) ->
    {Start, Len} = re_span_value(Spans, Args),
    {Start, Start + Len}.

re_span_value(Spans, []) ->
    hd(Spans);
re_span_value(Spans, [Index]) when is_integer(Index), Index >= 0, Index < length(Spans) ->
    lists:nth(Index + 1, Spans);
re_span_value(_Spans, [Index]) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"IndexError">>), Index)
    );
re_span_value(_Spans, Args) ->
    erlang:error({arity_error, {re_span, length(Args)}}).

native_instance(Name, Attrs0) ->
    Class = native_instance_class(Name),
    Instance = pyrlang_object:instantiate(Class),
    Attrs1 = put_new_attr(<<"__pyrlang_unsendable__">>, {native_instance, Name}, Attrs0),
    Attrs2 = put_new_attr(<<"__copy__">>, fun() -> Instance end, Attrs1),
    Attrs = put_new_attr(<<"__deepcopy__">>, fun(_Memo) -> Instance end, Attrs2),
    maps:foreach(
        fun(Attr, Value) -> ok = pyrlang_object:set_attr(Instance, Attr, Value) end, Attrs
    ),
    Instance.

native_instance_class(Name) ->
    Key = {pyrlang_native_instance_class, Name},
    case erlang:get(Key) of
        undefined ->
            create_native_instance_class(Key, Name);
        Class ->
            try
                case
                    pyrlang_heap:type(Class) =:= class andalso
                        pyrlang_object:class_name(Class) =:= Name
                of
                    true -> Class;
                    false -> create_native_instance_class(Key, Name)
                end
            catch
                _:_ -> create_native_instance_class(Key, Name)
            end
    end.

create_native_instance_class(Key, Name) ->
    Class = pyrlang_object:new_class(Name, [maps:get(<<"object">>, pyrlang_builtins:env())], #{}),
    erlang:put(Key, Class),
    Class.

native_instance(Class, Name, Attrs0) ->
    Instance = pyrlang_object:instantiate(Class),
    Attrs1 = put_new_attr(<<"__pyrlang_unsendable__">>, {native_instance, Name}, Attrs0),
    Attrs2 = put_new_attr(<<"__copy__">>, fun() -> Instance end, Attrs1),
    Attrs = put_new_attr(<<"__deepcopy__">>, fun(_Memo) -> Instance end, Attrs2),
    maps:foreach(
        fun(Attr, Value) -> ok = pyrlang_object:set_attr(Instance, Attr, Value) end, Attrs
    ),
    Instance.

contextlib_contextmanager([Func], KwArgs) when map_size(KwArgs) =:= 0 ->
    {py_native_call, fun(Args, CallKwArgs) ->
        contextlib_contextmanager_instance(Func, Args, CallKwArgs)
    end};
contextlib_contextmanager(Args, _KwArgs) ->
    erlang:error({arity_error, {contextmanager, length(Args)}}).

contextlib_contextmanager_instance(Func, Args, KwArgs) ->
    Key = {contextlib_contextmanager, make_ref()},
    erlang:put(Key, #{func => Func, args => {call_args, Args, KwArgs}, state => new}),
    native_instance(<<"_GeneratorContextManager">>, #{
        <<"__enter__">> => fun() -> contextlib_cm_enter(Key) end,
        <<"__exit__">> => fun(Type, Value, Traceback) ->
            contextlib_cm_exit(Key, Type, Value, Traceback)
        end,
        <<"_recreate_cm">> => fun() -> contextlib_contextmanager_instance(Func, Args, KwArgs) end
    }).

contextlib_cm_enter(Key) ->
    case erlang:get(Key) of
        #{state := new, func := Func, args := Args} = State ->
            case pyrlang_eval:contextmanager_start(Func, Args) of
                {yielded, Value, Frame} ->
                    erlang:put(Key, State#{state := active, frame => Frame}),
                    Value;
                {done, _Value, _Env} ->
                    contextlib_runtime_error(<<"generator didn't yield">>)
            end;
        _Other ->
            contextlib_runtime_error(<<"generator didn't yield">>)
    end.

contextlib_cm_exit(Key, none, _Value, _Traceback) ->
    contextlib_cm_exit_normal(Key);
contextlib_cm_exit(Key, _Type, Value, _Traceback) ->
    contextlib_cm_exit_exception(Key, Value).

contextlib_cm_exit_normal(Key) ->
    case erlang:get(Key) of
        #{state := active, frame := Frame} ->
            case pyrlang_eval:contextmanager_resume(Frame, normal) of
                {done, _Last, _Env} ->
                    erlang:erase(Key),
                    false;
                {yielded, _Value, _Frame} ->
                    erlang:erase(Key),
                    contextlib_runtime_error(<<"generator didn't stop">>)
            end;
        _Other ->
            false
    end.

contextlib_cm_exit_exception(Key, Value) ->
    case erlang:get(Key) of
        #{state := active, frame := Frame} ->
            case pyrlang_eval:contextmanager_resume(Frame, {throw, Value}) of
                {done, Suppressed, _Env} ->
                    erlang:erase(Key),
                    Suppressed;
                {yielded, _YieldedValue, _Frame} ->
                    erlang:erase(Key),
                    contextlib_runtime_error(<<"generator didn't stop after throw()">>)
            end;
        _Other ->
            false
    end.

contextlib_runtime_error(Message) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"RuntimeError">>), Message)
    ).

put_new_attr(Key, Value, Map) ->
    case maps:is_key(Key, Map) of
        true -> Map;
        false -> maps:put(Key, Value, Map)
    end.

hash_new(Algorithm, Args, KwArgs0) ->
    case maps:keys(maps:without([<<"usedforsecurity">>], KwArgs0)) of
        [] ->
            Data =
                case Args of
                    [] -> <<>>;
                    [Only] -> Only;
                    _ -> erlang:error({arity_error, {hashlib, length(Args)}})
                end,
            hash_object(Algorithm, Data);
        Extra ->
            erlang:error({type_error, {unexpected_keyword_argument, Extra}})
    end.

hash_object(Algorithm, Data) ->
    DataBin = normalize_bytes(Data),
    Class = native_instance_class(<<"Hash">>),
    Instance = pyrlang_object:instantiate(Class),
    Attrs = #{
        <<"__pyrlang_unsendable__">> => {native_instance, <<"Hash">>},
        <<"__pyrlang_hash_algorithm__">> => Algorithm,
        <<"__pyrlang_hash_data__">> => DataBin,
        <<"__copy__">> => fun() -> hash_copy(Instance) end,
        <<"__deepcopy__">> => fun(_Memo) -> hash_copy(Instance) end,
        <<"name">> => digest_name(Algorithm),
        <<"digest_size">> => byte_size(crypto:hash(Algorithm, <<>>)),
        <<"block_size">> => digest_block_size(Algorithm),
        <<"update">> => fun(UpdateData) -> hash_update(Instance, UpdateData) end,
        <<"digest">> => fun() -> hash_digest(Instance) end,
        <<"hexdigest">> => fun() -> hex(hash_digest(Instance)) end,
        <<"copy">> => fun() -> hash_copy(Instance) end
    },
    maps:foreach(
        fun(Attr, Value) -> ok = pyrlang_object:set_attr(Instance, Attr, Value) end, Attrs
    ),
    Instance.

hash_update(Hash, UpdateData) ->
    Current = pyrlang_object:get_attr(Hash, <<"__pyrlang_hash_data__">>),
    UpdateBin = normalize_bytes(UpdateData),
    ok = pyrlang_object:set_attr(
        Hash, <<"__pyrlang_hash_data__">>, <<Current/binary, UpdateBin/binary>>
    ),
    none.

hash_digest(Hash) ->
    Algorithm = pyrlang_object:get_attr(Hash, <<"__pyrlang_hash_algorithm__">>),
    Data = pyrlang_object:get_attr(Hash, <<"__pyrlang_hash_data__">>),
    crypto:hash(Algorithm, Data).

hash_copy(Hash) ->
    Algorithm = pyrlang_object:get_attr(Hash, <<"__pyrlang_hash_algorithm__">>),
    Data = pyrlang_object:get_attr(Hash, <<"__pyrlang_hash_data__">>),
    hash_object(Algorithm, Data).

hash_pbkdf2_hmac(Args, KwArgs0) when length(Args) =< 5 ->
    {HashName0, Password0, Salt0, Iterations0, DkLen0} =
        case Args of
            [] -> {unset, unset, unset, unset, unset};
            [A] -> {A, unset, unset, unset, unset};
            [A, B] -> {A, B, unset, unset, unset};
            [A, B, C] -> {A, B, C, unset, unset};
            [A, B, C, D] -> {A, B, C, D, unset};
            [A, B, C, D, E] -> {A, B, C, D, E}
        end,
    {HashName, KwArgs1} = take_kw_or_required(<<"hash_name">>, HashName0, KwArgs0),
    {Password, KwArgs2} = take_kw_or_required(<<"password">>, Password0, KwArgs1),
    {Salt, KwArgs3} = take_kw_or_required(<<"salt">>, Salt0, KwArgs2),
    {Iterations, KwArgs4} = take_kw_or_required(<<"iterations">>, Iterations0, KwArgs3),
    {DkLen, KwArgs} = take_kw_or_default(<<"dklen">>, DkLen0, none, KwArgs4),
    case maps:to_list(KwArgs) of
        [] ->
            Algorithm = digest_algorithm(HashName),
            Length = pbkdf2_length(Algorithm, DkLen),
            crypto:pbkdf2_hmac(
                Algorithm, normalize_bytes(Password), normalize_bytes(Salt), Iterations, Length
            );
        [{Unknown, _Value} | _] ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end;
hash_pbkdf2_hmac(Args, _KwArgs) ->
    erlang:error({arity_error, {pbkdf2_hmac, length(Args)}}).

take_kw_or_required(Name, unset, KwArgs) ->
    case maps:take(Name, KwArgs) of
        {Value, RestKwArgs} -> {Value, RestKwArgs};
        error -> erlang:error({type_error, {missing_required_argument, Name}})
    end;
take_kw_or_required(Name, PosValue, KwArgs) ->
    case maps:is_key(Name, KwArgs) of
        true -> erlang:error({type_error, {multiple_values_for_argument, Name}});
        false -> {PosValue, KwArgs}
    end.

pbkdf2_length(Algorithm, none) ->
    byte_size(crypto:hash(Algorithm, <<>>));
pbkdf2_length(_Algorithm, Length) when is_integer(Length), Length > 0 ->
    Length;
pbkdf2_length(_Algorithm, Length) ->
    erlang:error({value_error, {pbkdf2_hmac_dklen, Length}}).

hmac_new(Args, KwArgs0) when length(Args) =< 3 ->
    {Key0, Message0, DigestMod0} =
        case Args of
            [] -> {unset, unset, unset};
            [A] -> {A, unset, unset};
            [A, B] -> {A, B, unset};
            [A, B, C] -> {A, B, C}
        end,
    {Key, KwArgs1} = take_kw_or_required(<<"key">>, Key0, KwArgs0),
    {Message, KwArgs2} = take_kw_or_default(<<"msg">>, Message0, <<>>, KwArgs1),
    {DigestMod, KwArgs} = take_kw_or_required(<<"digestmod">>, DigestMod0, KwArgs2),
    case maps:to_list(KwArgs) of
        [] ->
            hmac_new_bound(Key, Message, DigestMod);
        [{Unknown, _Value} | _] ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end;
hmac_new(Args, _KwArgs) ->
    erlang:error({arity_error, {hmac_new, length(Args)}}).

hmac_new_bound(Key, Message, DigestMod) ->
    Algorithm = digest_algorithm(DigestMod),
    Digest = crypto:mac(hmac, Algorithm, normalize_bytes(Key), normalize_bytes(Message)),
    digest_object(<<"HMAC">>, Digest).

compare_digest(Left, Right) ->
    LeftBytes = normalize_bytes(Left),
    RightBytes = normalize_bytes(Right),
    byte_size(LeftBytes) =:= byte_size(RightBytes) andalso
        compare_digest_bytes(LeftBytes, RightBytes, 0) =:= 0.

compare_digest_bytes(<<>>, <<>>, Acc) ->
    Acc;
compare_digest_bytes(<<Left, LeftRest/binary>>, <<Right, RightRest/binary>>, Acc) ->
    compare_digest_bytes(LeftRest, RightRest, Acc bor (Left bxor Right)).

digest_object(Name, Digest) ->
    native_instance(Name, #{
        <<"digest">> => fun() -> Digest end,
        <<"hexdigest">> => fun() -> hex(Digest) end
    }).

digest_algorithm(<<"sha1">>) ->
    sha;
digest_algorithm(<<"sha256">>) ->
    sha256;
digest_algorithm(<<"sha512">>) ->
    sha512;
digest_algorithm(<<"md5">>) ->
    md5;
digest_algorithm(Name) when is_list(Name); is_atom(Name); is_binary(Name) ->
    digest_algorithm(normalize_name(Name));
digest_algorithm(DigestMod) ->
    try pyrlang_eval:call(DigestMod, []) of
        Hash ->
            digest_algorithm(pyrlang_object:get_attr(Hash, <<"name">>))
    catch
        _:_ -> erlang:error({value_error, {unsupported_digestmod, DigestMod}})
    end.

digest_name(sha) ->
    <<"sha1">>;
digest_name(Algorithm) when is_atom(Algorithm) ->
    atom_to_binary(Algorithm, utf8).

digest_block_size(sha) -> 64;
digest_block_size(sha224) -> 64;
digest_block_size(sha256) -> 64;
digest_block_size(sha384) -> 128;
digest_block_size(sha512) -> 128;
digest_block_size(md5) -> 64;
digest_block_size(_Algorithm) -> none.

zlib_env() ->
    #{
        <<"__name__">> => <<"zlib">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"error">> => pyrlang_exception:type(<<"ZlibError">>),
        <<"compress">> => {py_native_call, fun zlib_compress_call/2},
        <<"decompress">> => {py_native_call, fun zlib_decompress_call/2},
        <<"crc32">> => {py_native_varargs, fun zlib_crc32/1},
        <<"adler32">> => {py_native_varargs, fun zlib_adler32/1},
        <<"ZLIB_VERSION">> => <<"1.2.12">>,
        <<"ZLIB_RUNTIME_VERSION">> => <<"1.2.12">>,
        <<"Z_DEFAULT_COMPRESSION">> => -1,
        <<"Z_NO_COMPRESSION">> => 0,
        <<"Z_BEST_SPEED">> => 1,
        <<"Z_BEST_COMPRESSION">> => 9,
        <<"DEFLATED">> => 8,
        <<"MAX_WBITS">> => 15,
        <<"DEF_MEM_LEVEL">> => 8,
        <<"Z_NO_FLUSH">> => 0,
        <<"Z_SYNC_FLUSH">> => 2,
        <<"Z_FULL_FLUSH">> => 3,
        <<"Z_FINISH">> => 4
    }.

zlib_compress_call([Data], _KwArgs) ->
    zlib:compress(normalize_name(Data));
zlib_compress_call([Data, _Level], _KwArgs) ->
    zlib:compress(normalize_name(Data));
zlib_compress_call(Args, KwArgs) ->
    case Args of
        [Data] when map_size(KwArgs) > 0 -> zlib:compress(normalize_name(Data));
        _ -> erlang:error({arity_error, {zlib_compress, length(Args)}})
    end.

zlib_decompress_call([Data], _KwArgs) ->
    try
        zlib:uncompress(normalize_name(Data))
    catch
        error:_ ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ZlibError">>), <<"invalid compressed data">>
                )
            )
    end;
zlib_decompress_call([Data, _Wbits], _KwArgs) ->
    zlib_decompress_call([Data], #{});
zlib_decompress_call(Args, KwArgs) ->
    case Args of
        [Data] when map_size(KwArgs) > 0 -> zlib_decompress_call([Data], #{});
        _ -> erlang:error({arity_error, {zlib_decompress, length(Args)}})
    end.

zlib_crc32([Data]) ->
    erlang:crc32(normalize_name(Data));
zlib_crc32([Data, Value]) when is_integer(Value) ->
    erlang:crc32(Value, normalize_name(Data));
zlib_crc32(Args) ->
    erlang:error({arity_error, {zlib_crc32, length(Args)}}).

zlib_adler32([Data]) ->
    zlib_adler32([Data, 1]);
zlib_adler32([Data, Value]) when is_integer(Value) ->
    adler32(normalize_name(Data), Value);
zlib_adler32(Args) ->
    erlang:error({arity_error, {zlib_adler32, length(Args)}}).

adler32(Data, Initial) ->
    A0 = Initial band 16#ffff,
    B0 = (Initial bsr 16) band 16#ffff,
    {A, B} =
        lists:foldl(
            fun(Byte, {AccA, AccB}) ->
                NextA = (AccA + Byte) rem 65521,
                {NextA, (AccB + NextA) rem 65521}
            end,
            {A0, B0},
            binary_to_list(Data)
        ),
    (B bsl 16) bor A.

gzip_env() ->
    #{
        <<"__name__">> => <<"gzip">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"open">> => {py_native_call, fun gzip_open_call/2},
        <<"GzipFile">> => {py_native_call, fun gzip_gzipfile_call/2},
        <<"compress">> => {py_native_call, fun gzip_compress_call/2},
        <<"decompress">> => {py_native_varargs, fun gzip_decompress/1},
        <<"BadGzipFile">> => pyrlang_exception:type(<<"OSError">>),
        <<"FNAME">> => 8
    }.

gzip_open_call([Path], KwArgs) ->
    gzip_open_call([Path, <<"rb">>], KwArgs);
gzip_open_call([Path, Mode0], KwArgs0) ->
    Allowed = [<<"compresslevel">>, <<"encoding">>, <<"errors">>, <<"newline">>],
    case maps:keys(maps:without(Allowed, KwArgs0)) of
        [] ->
            Mode = normalize_name(Mode0),
            case gzip_read_mode(Mode) of
                true ->
                    gzip_file_instance(Path, Mode);
                false ->
                    pyrlang_exception:raise(
                        pyrlang_exception:make(
                            pyrlang_exception:type(<<"ValueError">>),
                            <<"unsupported gzip mode: ", Mode/binary>>
                        )
                    )
            end;
        Extra ->
            erlang:error({type_error, {unexpected_keyword_argument, Extra}})
    end;
gzip_open_call(Args, _KwArgs) ->
    erlang:error({arity_error, {gzip_open, length(Args)}}).

gzip_read_mode(Mode) ->
    binary:match(Mode, <<"w">>) =:= nomatch andalso
        binary:match(Mode, <<"a">>) =:= nomatch andalso
        binary:match(Mode, <<"x">>) =:= nomatch.

gzip_file_instance(Path0, _Mode) ->
    Path = normalize_name(Path0),
    case file:read_file(binary_to_list(Path)) of
        {ok, Compressed} ->
            case gzip_unzip(Compressed) of
                {ok, Data} ->
                    gzip_memory_file(Data);
                {error, Reason} ->
                    pyrlang_exception:raise(
                        pyrlang_exception:make(pyrlang_exception:type(<<"OSError">>), Reason)
                    )
            end;
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"OSError">>), Reason)
            )
    end.

gzip_decompress([Data]) ->
    case gzip_unzip(normalize_bytes(Data)) of
        {ok, Plain} ->
            Plain;
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"OSError">>), Reason)
            )
    end;
gzip_decompress(Args) ->
    erlang:error({arity_error, {gzip_decompress, length(Args)}}).

gzip_compress_call([Data], KwArgs0) ->
    Allowed = [<<"compresslevel">>, <<"mtime">>],
    case maps:keys(maps:without(Allowed, KwArgs0)) of
        [] -> zlib:gzip(normalize_bytes(Data));
        Extra -> erlang:error({type_error, {unexpected_keyword_argument, Extra}})
    end;
gzip_compress_call(Args, _KwArgs) ->
    erlang:error({arity_error, {gzip_compress, length(Args)}}).

gzip_gzipfile_call(Args, KwArgs0) ->
    Allowed = [<<"filename">>, <<"mode">>, <<"compresslevel">>, <<"fileobj">>, <<"mtime">>],
    Unknown = maps:keys(maps:without(Allowed, KwArgs0)),
    case Unknown of
        [] ->
            {Filename0, RestArgs} =
                case Args of
                    [] -> {maps:get(<<"filename">>, KwArgs0, none), []};
                    [Filename | Rest] -> {Filename, Rest}
                end,
            {Mode0, _RestKwArgs} =
                case RestArgs of
                    [] -> {maps:get(<<"mode">>, KwArgs0, <<"rb">>), KwArgs0};
                    [ModeArg | _] -> {ModeArg, KwArgs0}
                end,
            Mode = normalize_name(Mode0),
            FileObj = maps:get(<<"fileobj">>, KwArgs0, none),
            gzip_gzipfile_for_mode(Filename0, Mode, FileObj);
        _ ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end.

gzip_gzipfile_for_mode(Filename, Mode, _FileObj) when Filename =/= none ->
    case gzip_read_mode(Mode) of
        true -> gzip_file_instance(Filename, Mode);
        false -> gzip_writer(none)
    end;
gzip_gzipfile_for_mode(_Filename, Mode, FileObj) ->
    case gzip_read_mode(Mode) of
        true -> erlang:error({type_error, gzip_fileobj_read_not_supported});
        false -> gzip_writer(FileObj)
    end.

gzip_unzip(Data) ->
    try
        {ok, zlib:gunzip(Data)}
    catch
        error:Reason -> {error, Reason}
    end.

gzip_memory_file(Data) ->
    Key = {pyrlang_gzip_file, erlang:make_ref()},
    erlang:put(Key, #{data => Data, pos => 0, closed => false}),
    Class = native_instance_class(<<"GzipFile">>),
    Instance = pyrlang_object:instantiate(Class),
    ok = pyrlang_object:set_attr(Instance, <<"__pyrlang_unsendable__">>, gzip_file),
    ok = pyrlang_object:set_attr(
        Instance, <<"read">>, {py_native_varargs, fun(Args) -> gzip_file_read(Key, Args) end}
    ),
    ok = pyrlang_object:set_attr(Instance, <<"close">>, fun() -> gzip_file_close(Key) end),
    ok = pyrlang_object:set_attr(Instance, <<"__iter__">>, fun() ->
        pyrlang_iter:from_values(gzip_lines(Data))
    end),
    ok = pyrlang_object:set_attr(Instance, <<"__enter__">>, fun() -> Instance end),
    ok = pyrlang_object:set_attr(Instance, <<"__exit__">>, fun(_Type, _Value, _Traceback) ->
        _ = gzip_file_close(Key),
        false
    end),
    Instance.

gzip_file_read(Key, []) ->
    gzip_file_read(Key, [-1]);
gzip_file_read(Key, [Size]) when is_integer(Size), Size >= 0 ->
    State = gzip_file_state(Key),
    Data = maps:get(data, State),
    Pos = maps:get(pos, State),
    Remaining = max(byte_size(Data) - Pos, 0),
    Count = min(Size, Remaining),
    Chunk = binary:part(Data, Pos, Count),
    erlang:put(Key, State#{pos := Pos + Count}),
    Chunk;
gzip_file_read(Key, [Size]) when is_integer(Size), Size < 0 ->
    State = gzip_file_state(Key),
    Data = maps:get(data, State),
    Pos = maps:get(pos, State),
    Chunk = binary:part(Data, Pos, byte_size(Data) - Pos),
    erlang:put(Key, State#{pos := byte_size(Data)}),
    Chunk;
gzip_file_read(_Key, Args) ->
    erlang:error({arity_error, {gzip_file_read, length(Args)}}).

gzip_file_close(Key) ->
    case erlang:get(Key) of
        undefined ->
            none;
        State ->
            erlang:put(Key, State#{closed := true}),
            none
    end.

gzip_file_state(Key) ->
    case erlang:get(Key) of
        undefined ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"OSError">>), closed)
            );
        #{closed := true} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"OSError">>), closed)
            );
        State ->
            State
    end.

gzip_lines(<<>>) ->
    [];
gzip_lines(Data) ->
    gzip_lines(Data, []).

gzip_lines(<<>>, Acc) ->
    lists:reverse(Acc);
gzip_lines(Data, Acc) ->
    case binary:match(Data, <<"\n">>) of
        {Pos, 1} ->
            Size = Pos + 1,
            <<Line:Size/binary, Rest/binary>> = Data,
            gzip_lines(Rest, [Line | Acc]);
        nomatch ->
            lists:reverse([Data | Acc])
    end.

gzip_writer(FileObj) ->
    Key = {pyrlang_gzip_writer, erlang:make_ref()},
    erlang:put(Key, #{chunks => [], fileobj => FileObj, closed => false}),
    Class = native_instance_class(<<"GzipFile">>),
    Instance = pyrlang_object:instantiate(Class),
    ok = pyrlang_object:set_attr(Instance, <<"__pyrlang_unsendable__">>, gzip_writer),
    ok = pyrlang_object:set_attr(Instance, <<"write">>, fun(Data) ->
        gzip_writer_write(Key, Data)
    end),
    ok = pyrlang_object:set_attr(Instance, <<"close">>, fun() -> gzip_writer_close(Key) end),
    ok = pyrlang_object:set_attr(Instance, <<"__enter__">>, fun() -> Instance end),
    ok = pyrlang_object:set_attr(Instance, <<"__exit__">>, fun(_Type, _Value, _Traceback) ->
        _ = gzip_writer_close(Key),
        false
    end),
    Instance.

gzip_writer_write(Key, Data0) ->
    State = gzip_writer_state(Key),
    Data = normalize_bytes(Data0),
    Chunks = maps:get(chunks, State),
    erlang:put(Key, State#{chunks := [Data | Chunks]}),
    byte_size(Data).

gzip_writer_close(Key) ->
    case erlang:get(Key) of
        undefined ->
            none;
        #{closed := true} ->
            none;
        State ->
            Data = iolist_to_binary(lists:reverse(maps:get(chunks, State))),
            Compressed = zlib:gzip(Data),
            case maps:get(fileobj, State, none) of
                none ->
                    ok;
                FileObj ->
                    Write = pyrlang_object:get_attr(FileObj, <<"write">>),
                    _ = pyrlang_eval:call(Write, [Compressed]),
                    ok
            end,
            erlang:put(Key, State#{closed := true}),
            none
    end.

gzip_writer_state(Key) ->
    case erlang:get(Key) of
        undefined -> erlang:error({value_error, gzip_writer_closed});
        #{closed := true} -> erlang:error({value_error, gzip_writer_closed});
        State -> State
    end.

binascii_env() ->
    #{
        <<"__name__">> => <<"binascii">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"Error">> => pyrlang_exception:type(<<"Error">>),
        <<"Incomplete">> => pyrlang_exception:type(<<"Incomplete">>),
        <<"b2a_base64">> => {py_native_call, fun binascii_b2a_base64/2},
        <<"a2b_base64">> => {py_native_call, fun binascii_a2b_base64/2},
        <<"hexlify">> => {py_native_varargs, fun binascii_hexlify/1},
        <<"b2a_hex">> => {py_native_varargs, fun binascii_hexlify/1},
        <<"unhexlify">> => {py_native_varargs, fun binascii_unhexlify/1},
        <<"a2b_hex">> => {py_native_varargs, fun binascii_unhexlify/1}
    }.

binascii_b2a_base64([Data], KwArgs) ->
    Newline = maps:get(<<"newline">>, KwArgs, true),
    Encoded = base64:encode(normalize_name(Data)),
    case Newline of
        false -> Encoded;
        _ -> <<Encoded/binary, $\n>>
    end;
binascii_b2a_base64(Args, _KwArgs) ->
    erlang:error({arity_error, {b2a_base64, length(Args)}}).

binascii_a2b_base64([Data], KwArgs) ->
    StrictMode = maps:get(<<"strict_mode">>, KwArgs, false),
    Input =
        case StrictMode of
            true -> normalize_name(Data);
            _ -> binascii_base64_payload(normalize_name(Data))
        end,
    try
        base64:decode(Input)
    catch
        error:_ -> binascii_error(<<"Incorrect padding">>)
    end;
binascii_a2b_base64(Args, _KwArgs) ->
    erlang:error({arity_error, {a2b_base64, length(Args)}}).

binascii_hexlify([Data]) ->
    binascii_hexlify_binary(normalize_name(Data));
binascii_hexlify([Data, _Sep]) ->
    binascii_hexlify([Data]);
binascii_hexlify([Data, _Sep, _BytesPerSep]) ->
    binascii_hexlify([Data]);
binascii_hexlify(Args) ->
    erlang:error({arity_error, {hexlify, length(Args)}}).

binascii_unhexlify([Data]) ->
    case binascii_unhexlify_binary(normalize_name(Data), <<>>) of
        {ok, Result} -> Result;
        {error, Message} -> binascii_error(Message)
    end;
binascii_unhexlify(Args) ->
    erlang:error({arity_error, {unhexlify, length(Args)}}).

binascii_base64_payload(Data) ->
    <<<<Byte>> || <<Byte:8>> <= Data, binascii_base64_byte(Byte)>>.

binascii_base64_byte(Byte) when Byte >= $A, Byte =< $Z -> true;
binascii_base64_byte(Byte) when Byte >= $a, Byte =< $z -> true;
binascii_base64_byte(Byte) when Byte >= $0, Byte =< $9 -> true;
binascii_base64_byte($+) -> true;
binascii_base64_byte($/) -> true;
binascii_base64_byte($=) -> true;
binascii_base64_byte(_) -> false.

binascii_hexlify_binary(Data) ->
    iolist_to_binary([
        [binascii_hex_digit(Byte bsr 4), binascii_hex_digit(Byte band 15)]
     || <<Byte:8>> <= Data
    ]).

binascii_hex_digit(Value) when Value < 10 ->
    $0 + Value;
binascii_hex_digit(Value) ->
    $a + Value - 10.

binascii_unhexlify_binary(<<>>, Acc) ->
    {ok, Acc};
binascii_unhexlify_binary(<<_Byte:8>>, _Acc) ->
    {error, <<"Odd-length string">>};
binascii_unhexlify_binary(<<HighByte:8, LowByte:8, Rest/binary>>, Acc) ->
    case {binascii_hex_value(HighByte), binascii_hex_value(LowByte)} of
        {{ok, High}, {ok, Low}} ->
            Byte = (High bsl 4) bor Low,
            binascii_unhexlify_binary(Rest, <<Acc/binary, Byte:8>>);
        _ ->
            {error, <<"Non-hexadecimal digit found">>}
    end.

binascii_hex_value(Byte) when Byte >= $0, Byte =< $9 ->
    {ok, Byte - $0};
binascii_hex_value(Byte) when Byte >= $a, Byte =< $f ->
    {ok, Byte - $a + 10};
binascii_hex_value(Byte) when Byte >= $A, Byte =< $F ->
    {ok, Byte - $A + 10};
binascii_hex_value(_Byte) ->
    error.

binascii_error(Message) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"Error">>), Message)).

string_formatter_parser([Format]) ->
    pyrlang_heap:list(
        string_formatter_segments(binary_to_list(normalize_name(Format)), [], [], false)
    );
string_formatter_parser(Args) ->
    erlang:error({arity_error, {formatter_parser, length(Args)}}).

string_formatter_segments([], LiteralAcc, SegmentsAcc, SeenField) ->
    Literal = unicode:characters_to_binary(lists:reverse(LiteralAcc)),
    Segments =
        case {Literal, SeenField} of
            {<<>>, true} -> SegmentsAcc;
            _ -> [{Literal, none, none, none} | SegmentsAcc]
        end,
    lists:reverse(Segments);
string_formatter_segments([${, ${ | Rest], LiteralAcc, SegmentsAcc, SeenField) ->
    string_formatter_segments(Rest, [${ | LiteralAcc], SegmentsAcc, SeenField);
string_formatter_segments([$}, $} | Rest], LiteralAcc, SegmentsAcc, SeenField) ->
    string_formatter_segments(Rest, [$} | LiteralAcc], SegmentsAcc, SeenField);
string_formatter_segments([${ | Rest0], LiteralAcc, SegmentsAcc, _SeenField) ->
    case string_take_format_field(Rest0, []) of
        {ok, FieldChars, Rest} ->
            Literal = unicode:characters_to_binary(lists:reverse(LiteralAcc)),
            Segment = string_formatter_segment(
                Literal, unicode:characters_to_binary(lists:reverse(FieldChars))
            ),
            string_formatter_segments(Rest, [], [Segment | SegmentsAcc], true);
        error ->
            string_formatter_segments(Rest0, [${ | LiteralAcc], SegmentsAcc, true)
    end;
string_formatter_segments([Char | Rest], LiteralAcc, SegmentsAcc, SeenField) ->
    string_formatter_segments(Rest, [Char | LiteralAcc], SegmentsAcc, SeenField).

string_take_format_field([], _Acc) ->
    error;
string_take_format_field([$} | Rest], Acc) ->
    {ok, Acc, Rest};
string_take_format_field([Char | Rest], Acc) ->
    string_take_format_field(Rest, [Char | Acc]).

string_formatter_segment(Literal, Field) ->
    {FieldName, FormatSpec, Conversion} = string_parse_format_field(Field),
    {Literal, FieldName, FormatSpec, Conversion}.

string_parse_format_field(Field) ->
    {BeforeConversion, Conversion, AfterConversion} =
        case binary:split(Field, <<"!">>) of
            [NoConversion] -> {NoConversion, none, <<>>};
            [Name, <<Conv:8, Rest/binary>>] -> {Name, <<Conv:8>>, Rest};
            [Name, <<>>] -> {Name, <<>>, <<>>}
        end,
    FieldAndSpec =
        case AfterConversion of
            <<>> -> BeforeConversion;
            <<":", Spec/binary>> -> <<BeforeConversion/binary, ":", Spec/binary>>;
            Other -> <<BeforeConversion/binary, Other/binary>>
        end,
    case binary:split(FieldAndSpec, <<":">>) of
        [OnlyName] -> {OnlyName, <<>>, Conversion};
        [SpecName, SpecValue] -> {SpecName, SpecValue, Conversion}
    end.

string_formatter_field_name_split([FieldName]) ->
    Chars = binary_to_list(normalize_name(FieldName)),
    {FirstChars, RestChars} = string_take_field_first(Chars, []),
    First = string_field_key(unicode:characters_to_binary(lists:reverse(FirstChars))),
    {First, pyrlang_heap:list(string_field_rest(RestChars, []))};
string_formatter_field_name_split(Args) ->
    erlang:error({arity_error, {formatter_field_name_split, length(Args)}}).

string_take_field_first([], Acc) ->
    {Acc, []};
string_take_field_first([$. | _Rest] = Chars, Acc) ->
    {Acc, Chars};
string_take_field_first([$[ | _Rest] = Chars, Acc) ->
    {Acc, Chars};
string_take_field_first([Char | Rest], Acc) ->
    string_take_field_first(Rest, [Char | Acc]).

string_field_rest([], Acc) ->
    lists:reverse(Acc);
string_field_rest([$. | Rest0], Acc) ->
    {NameChars, Rest} = string_take_field_attr(Rest0, []),
    Name = unicode:characters_to_binary(lists:reverse(NameChars)),
    string_field_rest(Rest, [{true, Name} | Acc]);
string_field_rest([$[ | Rest0], Acc) ->
    {KeyChars, Rest} = string_take_field_item(Rest0, []),
    Key = string_field_key(unicode:characters_to_binary(lists:reverse(KeyChars))),
    string_field_rest(Rest, [{false, Key} | Acc]);
string_field_rest([_Char | Rest], Acc) ->
    string_field_rest(Rest, Acc).

string_take_field_attr([], Acc) ->
    {Acc, []};
string_take_field_attr([$. | _Rest] = Chars, Acc) ->
    {Acc, Chars};
string_take_field_attr([$[ | _Rest] = Chars, Acc) ->
    {Acc, Chars};
string_take_field_attr([Char | Rest], Acc) ->
    string_take_field_attr(Rest, [Char | Acc]).

string_take_field_item([], Acc) ->
    {Acc, []};
string_take_field_item([$] | Rest], Acc) ->
    {Acc, Rest};
string_take_field_item([Char | Rest], Acc) ->
    string_take_field_item(Rest, [Char | Acc]).

string_field_key(<<>>) ->
    <<>>;
string_field_key(Value) ->
    case string_all_digits(Value) of
        true -> binary_to_integer(Value);
        false -> Value
    end.

string_all_digits(<<Digit:8, Rest/binary>>) when Digit >= $0, Digit =< $9 ->
    string_all_digits(Rest);
string_all_digits(<<>>) ->
    true;
string_all_digits(_Value) ->
    false.

secrets_token_bytes(Count) when is_integer(Count), Count >= 0 ->
    crypto:strong_rand_bytes(Count).

secrets_token_hex(Count) when is_integer(Count), Count >= 0 ->
    hex(secrets_token_bytes(Count)).

secrets_choice(Sequence) ->
    case pyrlang_iter:values(Sequence) of
        [] ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"IndexError">>),
                    <<"Cannot choose from an empty sequence">>
                )
            );
        Values ->
            Index = binary:decode_unsigned(crypto:strong_rand_bytes(8)),
            lists:nth((Index rem length(Values)) + 1, Values)
    end.

hex(Binary) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte:8>> <= Binary]).

types_method_type([Callable, Self]) ->
    {py_bound_method, Callable, Self};
types_method_type(Args) ->
    erlang:error({arity_error, {method_type, length(Args)}}).

types_coroutine(Callable) ->
    Callable.

types_mapping_proxy_type() ->
    pyrlang_object:new_class(
        <<"mappingproxy">>, [maps:get(<<"object">>, pyrlang_builtins:env())], #{
            <<"__pyrlang_builtin_constructor__">> => {py_native_varargs, fun types_mapping_proxy/1}
        }
    ).

types_mapping_proxy([{py_ref, _} = Ref]) ->
    case pyrlang_heap:type(Ref) of
        dict -> pyrlang_heap:dict(pyrlang_heap:dict_items(Ref));
        Type -> erlang:error({type_error, {mappingproxy, Type}})
    end;
types_mapping_proxy([Map]) when is_map(Map) ->
    pyrlang_heap:dict(maps:to_list(Map));
types_mapping_proxy(Args) ->
    erlang:error({arity_error, {mappingproxy, length(Args)}}).

array_new([TypeCode], KwArgs) when map_size(KwArgs) =:= 0 ->
    array_instance(normalize_name(TypeCode), []);
array_new([TypeCode, Initializer], KwArgs) when map_size(KwArgs) =:= 0 ->
    array_instance(normalize_name(TypeCode), array_initializer_values(Initializer));
array_new(Args, _KwArgs) ->
    erlang:error({arity_error, {array, length(Args)}}).

array_initializer_values(Initializer) when is_binary(Initializer) ->
    binary_to_list(Initializer);
array_initializer_values(Initializer) ->
    pyrlang_iter:values(Initializer).

array_instance(TypeCode, Items) ->
    ItemsRef = pyrlang_heap:list(Items),
    native_instance(<<"array">>, #{
        <<"typecode">> => TypeCode,
        <<"append">> => fun(Value) ->
            ok = pyrlang_heap:list_append(ItemsRef, Value),
            none
        end,
        <<"extend">> => fun(Iterable) ->
            lists:foreach(
                fun(Value) -> ok = pyrlang_heap:list_append(ItemsRef, Value) end,
                pyrlang_iter:values(Iterable)
            ),
            none
        end,
        <<"frombytes">> => fun(Bytes) ->
            lists:foreach(
                fun(Value) -> ok = pyrlang_heap:list_append(ItemsRef, Value) end,
                array_values_from_bytes(TypeCode, normalize_name(Bytes))
            ),
            none
        end,
        <<"tobytes">> => fun() ->
            array_values_to_bytes(TypeCode, pyrlang_heap:list_items(ItemsRef))
        end,
        <<"tolist">> => fun() ->
            pyrlang_heap:list(pyrlang_heap:list_items(ItemsRef))
        end,
        <<"__iter__">> => fun() ->
            pyrlang_iter:iter(ItemsRef)
        end,
        <<"__len__">> => fun() ->
            length(pyrlang_heap:list_items(ItemsRef))
        end,
        <<"__getitem__">> => fun(Index) ->
            pyrlang_heap:list_get(ItemsRef, Index)
        end
    }).

array_values_to_bytes(<<"i">>, Values) ->
    <<<<(array_signed32(Value)):32/little-signed-integer>> || Value <- Values>>;
array_values_to_bytes(_TypeCode, Values) ->
    list_to_binary([Value band 16#ff || Value <- Values]).

array_values_from_bytes(<<"i">>, Bytes) ->
    [Value || <<Value:32/little-signed-integer>> <= Bytes];
array_values_from_bytes(_TypeCode, Bytes) ->
    binary_to_list(Bytes).

array_signed32(Value) when Value >= -2147483648, Value =< 2147483647 ->
    Value;
array_signed32(Value) ->
    erlang:error({overflow_error, {array_signed32, Value}}).

contextvar_new([Name], KwArgs) ->
    Default = maps:get(<<"default">>, KwArgs, none),
    contextvar_instance(normalize_name(Name), Default);
contextvar_new([Name, Default], KwArgs) when map_size(KwArgs) =:= 0 ->
    contextvar_instance(normalize_name(Name), Default);
contextvar_new(Args, _KwArgs) ->
    erlang:error({arity_error, {contextvar, length(Args)}}).

contextvar_instance(Name, Default) ->
    Ref = erlang:make_ref(),
    native_instance(<<"ContextVar">>, #{
        <<"name">> => Name,
        <<"get">> => {py_native_varargs, fun(Args) -> contextvar_get(Ref, Default, Args) end},
        <<"set">> => fun(Value) -> contextvar_set(Ref, Default, Value) end
    }).

contextvar_get(Ref, Default, []) ->
    contextvar_value(Ref, Default);
contextvar_get(Ref, _Default, [Fallback]) ->
    contextvar_value(Ref, Fallback);
contextvar_get(_Ref, _Default, Args) ->
    erlang:error({arity_error, {contextvar_get, length(Args)}}).

contextvar_value(Ref, Default) ->
    case erlang:get({pyrlang_contextvar, Ref}) of
        undefined -> Default;
        Value -> Value
    end.

contextvar_set(Ref, Default, Value) ->
    Old = erlang:get({pyrlang_contextvar, Ref}),
    erlang:put({pyrlang_contextvar, Ref}, Value),
    native_instance(<<"Token">>, #{
        <<"old_value">> =>
            case Old of
                undefined -> Default;
                _ -> Old
            end
    }).

ast_env() ->
    AST = ast_class(<<"AST">>, []),
    ClassNames = [
        <<"Add">>,
        <<"And">>,
        <<"AnnAssign">>,
        <<"Assert">>,
        <<"Assign">>,
        <<"AsyncFor">>,
        <<"AsyncFunctionDef">>,
        <<"AsyncWith">>,
        <<"Attribute">>,
        <<"AugAssign">>,
        <<"Await">>,
        <<"BinOp">>,
        <<"BitAnd">>,
        <<"BitOr">>,
        <<"BitXor">>,
        <<"BoolOp">>,
        <<"Break">>,
        <<"Bytes">>,
        <<"Call">>,
        <<"ClassDef">>,
        <<"Compare">>,
        <<"Constant">>,
        <<"Continue">>,
        <<"Del">>,
        <<"Delete">>,
        <<"Dict">>,
        <<"DictComp">>,
        <<"Div">>,
        <<"Eq">>,
        <<"ExceptHandler">>,
        <<"Ellipsis">>,
        <<"Expr">>,
        <<"Expression">>,
        <<"FloorDiv">>,
        <<"For">>,
        <<"FormattedValue">>,
        <<"FunctionDef">>,
        <<"FunctionType">>,
        <<"GeneratorExp">>,
        <<"Global">>,
        <<"Gt">>,
        <<"GtE">>,
        <<"If">>,
        <<"IfExp">>,
        <<"Import">>,
        <<"ImportFrom">>,
        <<"In">>,
        <<"Interactive">>,
        <<"Invert">>,
        <<"Is">>,
        <<"IsNot">>,
        <<"JoinedStr">>,
        <<"LShift">>,
        <<"Lambda">>,
        <<"List">>,
        <<"ListComp">>,
        <<"Load">>,
        <<"Lt">>,
        <<"LtE">>,
        <<"MatMult">>,
        <<"Match">>,
        <<"MatchAs">>,
        <<"MatchClass">>,
        <<"MatchMapping">>,
        <<"MatchOr">>,
        <<"MatchSequence">>,
        <<"MatchSingleton">>,
        <<"MatchStar">>,
        <<"MatchValue">>,
        <<"Mod">>,
        <<"Module">>,
        <<"Mult">>,
        <<"Name">>,
        <<"NamedExpr">>,
        <<"NameConstant">>,
        <<"Nonlocal">>,
        <<"Not">>,
        <<"NotEq">>,
        <<"NotIn">>,
        <<"Num">>,
        <<"Or">>,
        <<"ParamSpec">>,
        <<"Pass">>,
        <<"Pow">>,
        <<"RShift">>,
        <<"Raise">>,
        <<"Return">>,
        <<"Set">>,
        <<"SetComp">>,
        <<"Slice">>,
        <<"Starred">>,
        <<"Store">>,
        <<"Str">>,
        <<"Sub">>,
        <<"Subscript">>,
        <<"Try">>,
        <<"TryStar">>,
        <<"Tuple">>,
        <<"TypeAlias">>,
        <<"TypeIgnore">>,
        <<"TypeVar">>,
        <<"TypeVarTuple">>,
        <<"UAdd">>,
        <<"USub">>,
        <<"UnaryOp">>,
        <<"While">>,
        <<"With">>,
        <<"Yield">>,
        <<"YieldFrom">>,
        <<"alias">>,
        <<"arg">>,
        <<"arguments">>,
        <<"boolop">>,
        <<"cmpop">>,
        <<"comprehension">>,
        <<"excepthandler">>,
        <<"expr">>,
        <<"expr_context">>,
        <<"keyword">>,
        <<"match_case">>,
        <<"mod">>,
        <<"operator">>,
        <<"pattern">>,
        <<"stmt">>,
        <<"type_ignore">>,
        <<"type_param">>,
        <<"unaryop">>,
        <<"withitem">>
    ],
    Classes = maps:from_list([{Name, ast_class(Name, [AST])} || Name <- ClassNames]),
    maps:merge(
        #{
            <<"__name__">> => <<"_ast">>,
            <<"__file__">> => builtin,
            <<"__package__">> => <<"">>,
            <<"__path__">> => none,
            <<"AST">> => AST,
            <<"PyCF_ONLY_AST">> => 1024,
            <<"PyCF_TYPE_COMMENTS">> => 4096,
            <<"PyCF_ALLOW_TOP_LEVEL_AWAIT">> => 8192,
            <<"PyCF_OPTIMIZED_AST">> => 33792
        },
        Classes
    ).

ast_class(Name, Bases) ->
    pyrlang_object:new_class(Name, Bases, #{
        <<"__init__">> => {py_native_call, fun ast_node_init/2},
        <<"_fields">> => {},
        <<"_attributes">> => {}
    }).

ast_node_init([Self | PosArgs], KwArgs) ->
    lists:foreach(
        fun({Index, Value}) ->
            ok = pyrlang_object:set_attr(Self, integer_to_binary(Index - 1), Value)
        end,
        lists:zip(lists:seq(1, length(PosArgs)), PosArgs)
    ),
    maps:foreach(fun(Name, Value) -> ok = pyrlang_object:set_attr(Self, Name, Value) end, KwArgs),
    none;
ast_node_init(Args, _KwArgs) ->
    erlang:error({arity_error, {ast_node_init, length(Args)}}).

abc_get_cache_token() ->
    0.

abc_init(_Class) ->
    none.

abc_register(_Class, Subclass) ->
    Subclass.

abc_instancecheck(_Class, _Instance) ->
    false.

abc_subclasscheck(Class, Subclass) ->
    Class =:= Subclass.

abc_get_dump(_Class) ->
    {pyrlang_heap:set([]), pyrlang_heap:set([]), pyrlang_heap:set([]), 0}.

abc_reset_registry(_Class) ->
    none.

abc_reset_caches(_Class) ->
    none.

weakref_reference_type() ->
    Key = pyrlang_weakref_reference_type,
    case erlang:get(Key) of
        undefined ->
            Class = pyrlang_object:new_class(<<"ReferenceType">>, [], #{
                <<"__pyrlang_builtin_constructor__">> => {py_native_call, fun weakref_ref_new/2}
            }),
            erlang:put(Key, Class),
            Class;
        Class ->
            try pyrlang_heap:type(Class) of
                class ->
                    Class;
                _Other ->
                    erlang:erase(Key),
                    weakref_reference_type()
            catch
                _:_ ->
                    erlang:erase(Key),
                    weakref_reference_type()
            end
    end.

weakref_getweakrefcount(_Target) ->
    0.

weakref_getweakrefs(_Target) ->
    pyrlang_heap:list([]).

weakref_remove_dead({py_ref, _} = Dict, Key) ->
    case pyrlang_heap:type(Dict) of
        dict ->
            pyrlang_heap:dict_del(Dict, Key),
            none;
        _Type ->
            none
    end;
weakref_remove_dead(_Dict, _Key) ->
    none.

weakref_ref_new([Target], KwArgs) when map_size(KwArgs) =:= 0 ->
    weakref_callable(Target);
weakref_ref_new([Target, _Callback], KwArgs) when map_size(KwArgs) =:= 0 ->
    weakref_callable(Target);
weakref_ref_new(Args, _KwArgs) ->
    erlang:error({arity_error, {weakref_ref, length(Args)}}).

weakref_callable(Target) ->
    {py_weakref, Target}.

weakref_proxy_new([Target], KwArgs) when map_size(KwArgs) =:= 0 ->
    Target;
weakref_proxy_new([Target, _Callback], KwArgs) when map_size(KwArgs) =:= 0 ->
    Target;
weakref_proxy_new(Args, _KwArgs) ->
    erlang:error({arity_error, {weakref_proxy, length(Args)}}).

weakref_finalize_new([Obj, Func | Args], KwArgs) ->
    Key = make_ref(),
    erlang:put({pyrlang_weakref_finalize, Key}, #{
        obj => Obj,
        func => Func,
        args => Args,
        kwargs => KwArgs
    }),
    Instance = pyrlang_object:instantiate(weakref_finalize_type()),
    ok = pyrlang_object:set_attr(Instance, <<"__pyrlang_finalize_key__">>, Key),
    ok = pyrlang_object:set_attr(
        Instance,
        <<"__call__">>,
        {py_native_varargs, fun
            ([]) -> weakref_finalize_call(Key);
            (CallArgs) -> erlang:error({arity_error, {weakref_finalize_call, length(CallArgs)}})
        end}
    ),
    ok = pyrlang_object:set_attr(
        Instance,
        <<"detach">>,
        {py_native_varargs, fun
            ([]) -> weakref_finalize_detach(Key);
            (CallArgs) -> erlang:error({arity_error, {weakref_finalize_detach, length(CallArgs)}})
        end}
    ),
    ok = pyrlang_object:set_attr(
        Instance,
        <<"peek">>,
        {py_native_varargs, fun
            ([]) -> weakref_finalize_peek(Key);
            (CallArgs) -> erlang:error({arity_error, {weakref_finalize_peek, length(CallArgs)}})
        end}
    ),
    ok = pyrlang_object:set_attr(Instance, <<"atexit">>, true),
    Instance;
weakref_finalize_new(Args, _KwArgs) ->
    erlang:error({arity_error, {weakref_finalize, length(Args)}}).

weakref_finalize_type() ->
    Key = pyrlang_weakref_finalize_type,
    case erlang:get(Key) of
        undefined ->
            Class = pyrlang_object:new_class(<<"finalize">>, [], #{
                <<"alive">> => pyrlang_object:descriptor(fun weakref_finalize_alive/2, undefined)
            }),
            erlang:put(Key, Class),
            Class;
        Class ->
            Class
    end.

weakref_finalize_alive(Instance, _Class) ->
    case weakref_finalize_key(Instance) of
        {ok, Key} -> erlang:get({pyrlang_weakref_finalize, Key}) =/= undefined;
        error -> false
    end.

weakref_finalize_key({py_ref, _} = Instance) ->
    try pyrlang_heap:type(Instance) of
        instance ->
            Data = pyrlang_heap:data(Instance),
            Attrs = maps:get(attrs, Data),
            maps:find(<<"__pyrlang_finalize_key__">>, Attrs);
        _Other ->
            error
    catch
        _:_ -> error
    end;
weakref_finalize_key(_Other) ->
    error.

weakref_finalize_call(Key) ->
    case weakref_finalize_take(Key) of
        none -> none;
        {_Obj, Func, Args, KwArgs} -> pyrlang_eval:call(Func, {call_args, Args, KwArgs})
    end.

weakref_finalize_detach(Key) ->
    case weakref_finalize_take(Key) of
        none -> none;
        State -> weakref_finalize_info(State)
    end.

weakref_finalize_peek(Key) ->
    case weakref_finalize_state(Key) of
        none -> none;
        State -> weakref_finalize_info(State)
    end.

weakref_finalize_state(Key) ->
    case erlang:get({pyrlang_weakref_finalize, Key}) of
        undefined -> none;
        #{obj := Obj, func := Func, args := Args, kwargs := KwArgs} -> {Obj, Func, Args, KwArgs}
    end.

weakref_finalize_take(Key) ->
    State = weakref_finalize_state(Key),
    erlang:erase({pyrlang_weakref_finalize, Key}),
    State.

weakref_finalize_info({Obj, Func, Args, KwArgs}) ->
    {Obj, Func, list_to_tuple(Args), pyrlang_heap:dict(maps:to_list(KwArgs))}.

weak_dict_new([], KwArgs) when map_size(KwArgs) =:= 0 ->
    pyrlang_heap:dict([]);
weak_dict_new(Args, _KwArgs) ->
    erlang:error({arity_error, {weak_dict, length(Args)}}).

weak_set_new([], KwArgs) when map_size(KwArgs) =:= 0 ->
    pyrlang_heap:set([]);
weak_set_new(Args, _KwArgs) ->
    erlang:error({arity_error, {weak_set, length(Args)}}).

threading_local_type(Module) ->
    pyrlang_object:new_class(<<"local">>, [maps:get(<<"object">>, pyrlang_builtins:env())], #{
        <<"__module__">> => Module,
        <<"__new__">> => {py_native_varargs, fun threading_local_dunder_new/1}
    }).

threading_local_dunder_new([Class | _Args]) ->
    pyrlang_object:instantiate(Class);
threading_local_dunder_new(Args) ->
    erlang:error({arity_error, {'threading.local.__new__', length(Args)}}).

threading_thread_type() ->
    pyrlang_object:new_class(<<"Thread">>, [maps:get(<<"object">>, pyrlang_builtins:env())], #{
        <<"__module__">> => <<"threading">>,
        <<"__new__">> => {py_native_call, fun threading_thread_dunder_new/2},
        <<"__init__">> => {py_native_call, fun threading_thread_init/2},
        <<"start">> => fun threading_thread_start/1,
        <<"join">> => {py_native_varargs, fun threading_thread_join/1},
        <<"is_alive">> => fun threading_thread_is_alive/1,
        <<"run">> => fun threading_thread_run/1
    }).

threading_thread_dunder_new([Class | _Args]) ->
    pyrlang_object:instantiate(Class);
threading_thread_dunder_new(Args) ->
    erlang:error({arity_error, {'threading.Thread.__new__', length(Args)}}).

threading_thread_dunder_new(Args, _KwArgs) ->
    threading_thread_dunder_new(Args).

threading_thread_init([Self | Args], KwArgs0) ->
    ensure_allowed_thread_kwargs(KwArgs0),
    case length(Args) =< 5 of
        true ->
            ok;
        false ->
            erlang:error(
                {arity_error, {'threading.Thread.__init__', length(Args), maps:size(KwArgs0)}}
            )
    end,
    Positional = [<<"group">>, <<"target">>, <<"name">>, <<"args">>, <<"kwargs">>],
    case
        [
            Name
         || {Name, _Value} <- lists:zip(lists:sublist(Positional, length(Args)), Args),
            maps:is_key(Name, KwArgs0)
        ]
    of
        [] ->
            ok;
        [Duplicate | _] ->
            erlang:error(
                {type_error, {multiple_values_for_argument, 'threading.Thread.__init__', Duplicate}}
            )
    end,
    Group = thread_arg(1, <<"group">>, Args, KwArgs0, none),
    case Group of
        none -> ok;
        _ -> erlang:error({type_error, {thread_group_must_be_none, Group}})
    end,
    Target = thread_arg(2, <<"target">>, Args, KwArgs0, none),
    Name = thread_arg(3, <<"name">>, Args, KwArgs0, <<"Thread">>),
    ThreadArgs = thread_args_list(thread_arg(4, <<"args">>, Args, KwArgs0, {})),
    ThreadKwargs = thread_kwargs_map(
        thread_arg(5, <<"kwargs">>, Args, KwArgs0, pyrlang_heap:dict([]))
    ),
    Daemon = maps:get(<<"daemon">>, KwArgs0, false),
    ok = pyrlang_object:set_attr(Self, <<"ident">>, none),
    ok = pyrlang_object:set_attr(Self, <<"native_id">>, none),
    ok = pyrlang_object:set_attr(Self, <<"name">>, Name),
    ok = pyrlang_object:set_attr(Self, <<"daemon">>, Daemon),
    ok = pyrlang_object:set_attr(Self, <<"_target">>, Target),
    ok = pyrlang_object:set_attr(Self, <<"_args">>, ThreadArgs),
    ok = pyrlang_object:set_attr(Self, <<"_kwargs">>, ThreadKwargs),
    ok = pyrlang_object:set_attr(Self, <<"_started_pyrlang">>, false),
    none;
threading_thread_init(Args, _KwArgs) ->
    erlang:error({arity_error, {'threading.Thread.__init__', length(Args)}}).

ensure_allowed_thread_kwargs(KwArgs) ->
    Allowed = [
        <<"group">>, <<"target">>, <<"name">>, <<"args">>, <<"kwargs">>, <<"daemon">>, <<"context">>
    ],
    case [Key || Key <- maps:keys(KwArgs), not lists:member(Key, Allowed)] of
        [] -> ok;
        [Unknown | _] -> erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end.

thread_arg(Position, Key, Args, KwArgs, Default) ->
    case length(Args) >= Position of
        true -> lists:nth(Position, Args);
        false -> maps:get(Key, KwArgs, Default)
    end.

thread_args_list(Args) when is_tuple(Args) ->
    tuple_to_list(Args);
thread_args_list({py_ref, _} = Ref) ->
    pyrlang_iter:values(Ref);
thread_args_list(none) ->
    [];
thread_args_list(Other) ->
    erlang:error({type_error, {thread_args_not_iterable, Other}}).

thread_kwargs_map({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> maps:from_list(pyrlang_heap:dict_items(Ref));
        _ -> erlang:error({type_error, {thread_kwargs_not_dict, Ref}})
    end;
thread_kwargs_map(Map) when is_map(Map) ->
    Map;
thread_kwargs_map(none) ->
    #{};
thread_kwargs_map(Other) ->
    erlang:error({type_error, {thread_kwargs_not_dict, Other}}).

threading_thread_start(Self) ->
    Ident = threading_get_ident(),
    ok = pyrlang_object:set_attr(Self, <<"ident">>, Ident),
    ok = pyrlang_object:set_attr(Self, <<"native_id">>, Ident),
    ok = pyrlang_object:set_attr(Self, <<"_started_pyrlang">>, true),
    none.

threading_thread_join([_Self]) ->
    none;
threading_thread_join([_Self, _Timeout]) ->
    none;
threading_thread_join(Args) ->
    erlang:error({arity_error, {'threading.Thread.join', length(Args)}}).

threading_thread_is_alive(Self) ->
    try pyrlang_object:get_attr(Self, <<"_started_pyrlang">>) of
        Started -> Started =/= false andalso Started =/= none
    catch
        _:_ -> false
    end.

threading_thread_run(Self) ->
    Target = pyrlang_object:get_attr(Self, <<"_target">>),
    case Target of
        none ->
            none;
        _ ->
            Args = pyrlang_object:get_attr(Self, <<"_args">>),
            KwArgs = pyrlang_object:get_attr(Self, <<"_kwargs">>),
            pyrlang_eval:call(Target, {call_args, Args, KwArgs}),
            none
    end.

threading_register_atexit([Function | Args]) ->
    erlang:put(pyrlang_threading_atexits, [{Function, Args} | threading_atexits()]),
    none;
threading_register_atexit(Args) ->
    erlang:error({arity_error, {'threading._register_atexit', length(Args)}}).

threading_atexits() ->
    case erlang:get(pyrlang_threading_atexits) of
        undefined -> [];
        Atexits -> Atexits
    end.

threading_get_ident() ->
    erlang:phash2(self()).

threading_current_thread(ThreadClass) ->
    Ident = threading_get_ident(),
    Thread = pyrlang_object:instantiate(ThreadClass),
    ok = pyrlang_object:set_attr(Thread, <<"ident">>, Ident),
    ok = pyrlang_object:set_attr(Thread, <<"native_id">>, Ident),
    ok = pyrlang_object:set_attr(Thread, <<"name">>, <<"PyrlangActor">>),
    ok = pyrlang_object:set_attr(Thread, <<"daemon">>, false),
    ok = pyrlang_object:set_attr(Thread, <<"_target">>, none),
    ok = pyrlang_object:set_attr(Thread, <<"_args">>, []),
    ok = pyrlang_object:set_attr(Thread, <<"_kwargs">>, #{}),
    ok = pyrlang_object:set_attr(Thread, <<"_started_pyrlang">>, true),
    Thread.

threading_lock_new([], KwArgs) when map_size(KwArgs) =:= 0 ->
    threading_lock_instance();
threading_lock_new(Args, _KwArgs) ->
    erlang:error({arity_error, {threading_lock, length(Args)}}).

threading_lock_instance() ->
    native_instance(<<"Lock">>, #{
        <<"acquire">> => {py_native_varargs, fun(_Args) -> true end},
        <<"release">> => fun() -> none end,
        <<"__enter__">> => fun() -> true end,
        <<"__exit__">> => fun(_Type, _Value, _Traceback) -> false end
    }).

threading_semaphore_new(Args, KwArgs0) ->
    {Value, KwArgs} =
        case maps:take(<<"value">>, KwArgs0) of
            {KwValue, RestKwArgs} ->
                {KwValue, RestKwArgs};
            error ->
                case Args of
                    [] -> {1, KwArgs0};
                    [Arg] -> {Arg, KwArgs0};
                    _ -> erlang:error({arity_error, {threading_semaphore, length(Args)}})
                end
        end,
    case maps:to_list(KwArgs) of
        [] ->
            ok;
        [{Unknown, _Value} | _] ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end,
    case is_number(Value) andalso Value >= 0 of
        true ->
            threading_semaphore_instance(Value);
        false ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>),
                    <<"semaphore initial value must be >= 0">>
                )
            )
    end.

threading_semaphore_instance(Value) ->
    Key = {pyrlang_threading_semaphore, erlang:make_ref()},
    erlang:put(Key, Value),
    native_instance(<<"Semaphore">>, #{
        <<"acquire">> =>
            {py_native_call, fun(Args, KwArgs) ->
                threading_semaphore_acquire(Key, Args, KwArgs)
            end},
        <<"release">> =>
            {py_native_varargs, fun(Args) -> threading_semaphore_release(Key, Args) end},
        <<"__enter__">> => fun() ->
            _ = threading_semaphore_acquire(Key, [], #{}),
            true
        end,
        <<"__exit__">> => fun(_Type, _Value, _Traceback) ->
            _ = threading_semaphore_release(Key, []),
            false
        end
    }).

threading_semaphore_acquire(Key, Args0, KwArgs0) ->
    case parse_semaphore_acquire_options(Args0, KwArgs0) of
        {ok, Blocking0, _Timeout} ->
            Count =
                case erlang:get(Key) of
                    undefined -> 0;
                    Current -> Current
                end,
            case Count > 0 of
                true ->
                    erlang:put(Key, Count - 1),
                    true;
                false ->
                    case py_truthy(Blocking0) of
                        true -> false;
                        false -> false
                    end
            end;
        {error, Reason} ->
            erlang:error(Reason)
    end.

parse_semaphore_acquire_options(Args, KwArgs0) when length(Args) =< 2 ->
    {BlockingFromArgs, TimeoutFromArgs} =
        case Args of
            [] -> {unset, unset};
            [BlockingArg] -> {BlockingArg, unset};
            [BlockingArg, TimeoutArg] -> {BlockingArg, TimeoutArg}
        end,
    {Blocking, KwArgs1} = take_kw_or_default(<<"blocking">>, BlockingFromArgs, true, KwArgs0),
    {Timeout, KwArgs} = take_kw_or_default(<<"timeout">>, TimeoutFromArgs, none, KwArgs1),
    case maps:to_list(KwArgs) of
        [] -> {ok, Blocking, Timeout};
        [{Unknown, _Value} | _] -> {error, {type_error, {unexpected_keyword_argument, Unknown}}}
    end;
parse_semaphore_acquire_options(Args, _KwArgs) ->
    {error, {arity_error, {threading_semaphore_acquire, length(Args)}}}.

take_kw_or_default(Name, unset, Default, KwArgs) ->
    case maps:take(Name, KwArgs) of
        {Value, RestKwArgs} -> {Value, RestKwArgs};
        error -> {Default, KwArgs}
    end;
take_kw_or_default(Name, PosValue, _Default, KwArgs) ->
    case maps:is_key(Name, KwArgs) of
        true -> erlang:error({type_error, {multiple_values_for_argument, Name}});
        false -> {PosValue, KwArgs}
    end.

threading_semaphore_release(Key, []) ->
    threading_semaphore_release(Key, [1]);
threading_semaphore_release(Key, [N]) when is_number(N), N >= 1 ->
    Count =
        case erlang:get(Key) of
            undefined -> 0;
            Current -> Current
        end,
    erlang:put(Key, Count + N),
    none;
threading_semaphore_release(_Key, [N]) when is_number(N) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"ValueError">>), <<"n must be one or more">>
        )
    );
threading_semaphore_release(_Key, Args) ->
    erlang:error({arity_error, {threading_semaphore_release, length(Args)}}).

threading_event_new([], KwArgs) when map_size(KwArgs) =:= 0 ->
    threading_event_instance();
threading_event_new(Args, _KwArgs) ->
    erlang:error({arity_error, {threading_event, length(Args)}}).

threading_event_instance() ->
    Key = {pyrlang_threading_event, erlang:make_ref()},
    erlang:put(Key, false),
    native_instance(<<"Event">>, #{
        <<"is_set">> => fun() -> threading_event_is_set(Key) end,
        <<"isSet">> => fun() -> threading_event_is_set(Key) end,
        <<"set">> => fun() ->
            erlang:put(Key, true),
            none
        end,
        <<"clear">> => fun() ->
            erlang:put(Key, false),
            none
        end,
        <<"wait">> => {py_native_varargs, fun(_Args) -> threading_event_is_set(Key) end}
    }).

threading_event_is_set(Key) ->
    case erlang:get(Key) of
        true -> true;
        _ -> false
    end.

thread_handle_new([], KwArgs) when map_size(KwArgs) =:= 0 ->
    thread_handle_instance();
thread_handle_new(Args, _KwArgs) ->
    erlang:error({arity_error, {thread_handle, length(Args)}}).

thread_handle_instance() ->
    native_instance(<<"ThreadHandle">>, #{
        <<"ident">> => threading_get_ident(),
        <<"is_done">> => fun() -> true end,
        <<"join">> => {py_native_varargs, fun(_Args) -> none end},
        <<"_set_done">> => fun() -> none end
    }).

thread_start_new_thread([Function, Args]) ->
    spawn_thread(Function, Args),
    threading_get_ident();
thread_start_new_thread([Function, Args, _Kwargs]) ->
    spawn_thread(Function, Args),
    threading_get_ident();
thread_start_new_thread(Args) ->
    erlang:error({arity_error, {start_new_thread, length(Args)}}).

thread_start_joinable_thread([Function]) ->
    spawn_thread(Function, {}),
    thread_handle_instance();
thread_start_joinable_thread([Function, Args | _Rest]) ->
    spawn_thread(Function, Args),
    thread_handle_instance();
thread_start_joinable_thread(Args) ->
    erlang:error({arity_error, {start_joinable_thread, length(Args)}}).

spawn_thread(Function, Args) ->
    Values = pyrlang_iter:values(Args),
    _Pid = spawn(fun() -> catch pyrlang_eval:call(Function, Values) end),
    ok.

thread_stack_size([]) ->
    0;
thread_stack_size([_Size]) ->
    0;
thread_stack_size(Args) ->
    erlang:error({arity_error, {stack_size, length(Args)}}).

frozen_importlib_alias_env(Alias, Target) ->
    Module = load(Target),
    (env(Module))#{
        <<"__name__">> => Alias,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>
    }.

importlib_import_module([Name], KwArgs) when map_size(KwArgs) =:= 0 ->
    Resolved = resolve_import_name(normalize_name(Name), none),
    trace_module_load(import_module, Resolved, builtin),
    load(Resolved);
importlib_import_module([Name, Package], KwArgs) when map_size(KwArgs) =:= 0 ->
    Resolved = resolve_import_name(normalize_name(Name), Package),
    trace_module_load(import_module, Resolved, builtin),
    load(Resolved);
importlib_import_module(Args, _KwArgs) ->
    erlang:error({arity_error, {import_module, length(Args)}}).

importlib_reload([{py_ref, _} = Module]) ->
    try get_attr(Module, <<"__name__">>) of
        Name -> load(Name)
    catch
        _:_ -> Module
    end;
importlib_reload(Args) ->
    erlang:error({arity_error, {reload, length(Args)}}).

importlib_util_find_spec([Name], KwArgs) ->
    importlib_util_find_spec_args(
        Name, maps:get(<<"package">>, KwArgs, none), maps:without([<<"package">>], KwArgs)
    );
importlib_util_find_spec([Name, Package], KwArgs) ->
    importlib_util_find_spec_args(Name, Package, KwArgs);
importlib_util_find_spec(Args, _KwArgs) ->
    erlang:error({arity_error, {find_spec, length(Args)}}).

importlib_util_find_spec_args(Name0, Package, KwArgs) when map_size(KwArgs) =:= 0 ->
    Name = normalize_name(Name0),
    FullName =
        case Name of
            <<".", _/binary>> -> resolve_import_name(Name, Package);
            _ -> Name
        end,
    importlib_find_spec(FullName);
importlib_util_find_spec_args(_Name, _Package, KwArgs) ->
    Unknown =
        case maps:keys(KwArgs) of
            [] -> <<"">>;
            [Key | _] -> Key
        end,
    erlang:error({type_error, {unexpected_keyword, Unknown}}).

importlib_find_spec(Name) ->
    case find_module(Name) of
        {ok, Path, IsPackage} ->
            importlib_module_spec(Name, unicode:characters_to_binary(Path), IsPackage);
        error ->
            case builtin_module(Name) of
                {ok, _Env} -> importlib_module_spec(Name, <<"built-in">>, false);
                error -> none
            end
    end.

importlib_module_spec(Name, Origin, IsPackage) ->
    Loader = importlib_module_loader(Origin, IsPackage),
    importlib_module_spec(Name, Origin, IsPackage, Loader).

importlib_module_spec(Name, Origin, IsPackage, Loader) ->
    Locations =
        case IsPackage of
            true ->
                pyrlang_heap:list([
                    unicode:characters_to_binary(filename:dirname(binary_to_list(Origin)))
                ]);
            false ->
                none
        end,
    native_instance(<<"ModuleSpec">>, #{
        <<"name">> => Name,
        <<"loader">> => Loader,
        <<"origin">> => Origin,
        <<"submodule_search_locations">> => Locations,
        <<"has_location">> => Origin =/= <<"built-in">>,
        <<"_initializing">> => false
    }).

importlib_module_loader(<<"built-in">>, _IsPackage) ->
    none;
importlib_module_loader(Origin, IsPackage) ->
    ResourceRoot =
        case IsPackage of
            true -> unicode:characters_to_binary(filename:dirname(binary_to_list(Origin)));
            false -> none
        end,
    native_instance(<<"SourceFileLoader">>, #{
        <<"get_resource_reader">> => fun(_PackageName) ->
            importlib_resource_reader(ResourceRoot)
        end
    }).

importlib_resource_reader(none) ->
    none;
importlib_resource_reader(ResourceRoot) ->
    native_instance(<<"ResourceReader">>, #{
        <<"files">> => fun() -> pathlib_path_instance(pathlib_path_class(), ResourceRoot) end,
        <<"contents">> => fun() -> importlib_resource_contents(ResourceRoot) end,
        <<"is_resource">> => fun(Name) -> importlib_resource_is_resource(ResourceRoot, Name) end,
        <<"open_resource">> => fun(Name) -> importlib_resource_open(ResourceRoot, Name) end
    }).

importlib_resource_contents(ResourceRoot) ->
    case file:list_dir(binary_to_list(ResourceRoot)) of
        {ok, Names} -> pyrlang_heap:list([unicode:characters_to_binary(Name) || Name <- Names]);
        {error, _Reason} -> pyrlang_heap:list([])
    end.

importlib_resource_is_resource(ResourceRoot, Name) ->
    Path = filename:join(binary_to_list(ResourceRoot), binary_to_list(normalize_name(Name))),
    filelib:is_file(Path).

importlib_resource_open(ResourceRoot, none) ->
    pyrlang_builtins:open([ResourceRoot, <<"rb">>]);
importlib_resource_open(ResourceRoot, Name) ->
    Path = filename:join(binary_to_list(ResourceRoot), binary_to_list(normalize_name(Name))),
    pyrlang_builtins:open([unicode:characters_to_binary(Path), <<"rb">>]).

resolve_import_name(<<".", _/binary>>, none) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"ImportError">>), <<"relative import requires package">>
        )
    );
resolve_import_name(<<".", _/binary>> = Name, Package0) ->
    Package = normalize_name(Package0),
    {Level, Rest} = leading_dot_count(Name, 0),
    PackageParts = binary:split(Package, <<".">>, [global]),
    KeepCount = length(PackageParts) - (Level - 1),
    case KeepCount > 0 of
        true ->
            BaseParts = lists:sublist(PackageParts, KeepCount),
            RestParts =
                case Rest of
                    <<>> -> [];
                    _ -> binary:split(Rest, <<".">>, [global])
                end,
            join_binary(BaseParts ++ RestParts, <<".">>);
        false ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ImportError">>),
                    <<"relative import beyond top-level package">>
                )
            )
    end;
resolve_import_name(Name, _Package) ->
    Name.

timedelta_type() ->
    Class = pyrlang_object:new_class(
        <<"timedelta">>, [maps:get(<<"object">>, pyrlang_builtins:env())], #{}
    ),
    ok = pyrlang_object:set_class_attr(
        Class,
        <<"__pyrlang_builtin_constructor__">>,
        {py_native_call, fun(Args, KwArgs) -> timedelta_new(Class, Args, KwArgs) end}
    ),
    Class.

tzinfo_type() ->
    pyrlang_object:new_class(<<"tzinfo">>, [maps:get(<<"object">>, pyrlang_builtins:env())], #{
        <<"tzname">> => fun(_Self, _Dt) -> none end,
        <<"utcoffset">> => fun(_Self, _Dt) -> none end,
        <<"dst">> => fun(_Self, _Dt) -> none end
    }).

timezone_type(TzInfo, Timedelta) ->
    Class = pyrlang_object:new_class(<<"timezone">>, [TzInfo], #{}),
    ok = pyrlang_object:set_class_attr(
        Class,
        <<"__pyrlang_builtin_constructor__">>,
        {py_native_call, fun(Args, KwArgs) -> timezone_new(Class, Timedelta, Args, KwArgs) end}
    ),
    Class.

timedelta_new(Class, Args, KwArgs) ->
    PosNames = [<<"days">>, <<"seconds">>, <<"microseconds">>],
    Values0 = #{
        <<"days">> => 0,
        <<"seconds">> => 0,
        <<"microseconds">> => 0,
        <<"milliseconds">> => 0,
        <<"minutes">> => 0,
        <<"hours">> => 0,
        <<"weeks">> => 0
    },
    Values1 = bind_timedelta_posargs(Args, PosNames, Values0),
    Values = maps:merge(Values1, KwArgs),
    Unknown = maps:keys(maps:without(maps:keys(Values0), Values)),
    case Unknown of
        [] ->
            Total =
                number_value(maps:get(<<"weeks">>, Values)) * 604800 +
                    number_value(maps:get(<<"days">>, Values)) * 86400 +
                    number_value(maps:get(<<"hours">>, Values)) * 3600 +
                    number_value(maps:get(<<"minutes">>, Values)) * 60 +
                    number_value(maps:get(<<"seconds">>, Values)) +
                    number_value(maps:get(<<"milliseconds">>, Values)) / 1000 +
                    number_value(maps:get(<<"microseconds">>, Values)) / 1000000,
            timedelta_value(Class, Total);
        _ ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end.

bind_timedelta_posargs([], _Names, Values) ->
    Values;
bind_timedelta_posargs([Value | Rest], [Name | Names], Values) ->
    bind_timedelta_posargs(Rest, Names, Values#{Name := Value});
bind_timedelta_posargs(Args, [], _Values) ->
    erlang:error({arity_error, {timedelta, length(Args)}}).

timedelta_value(Class, TotalSeconds0) ->
    TotalSeconds = normalize_number(TotalSeconds0),
    Days = floor(TotalSeconds / 86400),
    Seconds = floor(TotalSeconds - Days * 86400),
    Microseconds = round((TotalSeconds - floor(TotalSeconds)) * 1000000),
    native_instance(Class, <<"timedelta">>, #{
        <<"days">> => Days,
        <<"seconds">> => Seconds,
        <<"microseconds">> => Microseconds,
        <<"__add__">> => fun(Other) -> timedelta_add(Class, TotalSeconds, Other) end,
        <<"__radd__">> => fun(Other) -> timedelta_add(Class, TotalSeconds, Other) end,
        <<"__sub__">> => fun(Other) -> timedelta_subtract(Class, TotalSeconds, Other) end,
        <<"total_seconds">> => fun() -> TotalSeconds end
    }).

timedelta_add(Class, TotalSeconds, Other) ->
    case timedelta_total_seconds(Other) of
        {ok, OtherSeconds} -> timedelta_value(Class, TotalSeconds + OtherSeconds);
        error -> not_implemented
    end.

timedelta_subtract(Class, TotalSeconds, Other) ->
    case timedelta_total_seconds(Other) of
        {ok, OtherSeconds} -> timedelta_value(Class, TotalSeconds - OtherSeconds);
        error -> not_implemented
    end.

timedelta_total_seconds({py_ref, _} = Value) ->
    try pyrlang_object:get_attr(Value, <<"total_seconds">>) of
        TotalSeconds ->
            case pyrlang_eval:call(TotalSeconds, []) of
                Seconds when is_integer(Seconds); is_float(Seconds) -> {ok, Seconds};
                true -> {ok, 1};
                false -> {ok, 0};
                _Other -> error
            end
    catch
        _:_ -> error
    end;
timedelta_total_seconds(_Value) ->
    error.

timezone_new(Class, _Timedelta, [Offset], KwArgs) when map_size(KwArgs) =:= 0 ->
    timezone_value(Class, Offset, timezone_offset_name(Offset));
timezone_new(Class, _Timedelta, [Offset, Name], KwArgs) when map_size(KwArgs) =:= 0 ->
    timezone_value(Class, Offset, normalize_name(Name));
timezone_new(Class, Timedelta, [], KwArgs) ->
    Offset = maps:get(<<"offset">>, KwArgs, timedelta_value(Timedelta, 0)),
    Name0 = maps:get(<<"name">>, KwArgs, timezone_offset_name(Offset)),
    timezone_value(Class, Offset, normalize_name(Name0));
timezone_new(_Class, _Timedelta, Args, _KwArgs) ->
    erlang:error({arity_error, {timezone, length(Args)}}).

timezone_value(Class, Offset, Name) ->
    native_instance(Class, <<"timezone">>, #{
        <<"tzname">> => fun(_Dt) -> Name end,
        <<"utcoffset">> => fun(_Dt) -> Offset end,
        <<"dst">> => fun(_Dt) -> none end
    }).

timezone_offset_name(Offset) ->
    try pyrlang_object:get_attr(Offset, <<"total_seconds">>) of
        TotalSecondsFun ->
            case TotalSecondsFun() of
                0 -> <<"UTC">>;
                _ -> <<"UTC">>
            end
    catch
        _:_ -> <<"UTC">>
    end.

number_value(true) -> 1;
number_value(false) -> 0;
number_value(Value) when is_integer(Value); is_float(Value) -> Value;
number_value(Other) -> erlang:error({type_error, {number, Other}}).

normalize_number(Value) when is_float(Value) ->
    case Value =:= trunc(Value) of
        true -> trunc(Value);
        false -> Value
    end;
normalize_number(Value) ->
    Value.

leading_dot_count(<<".", Rest/binary>>, Count) ->
    leading_dot_count(Rest, Count + 1);
leading_dot_count(Rest, Count) ->
    {Count, Rest}.

datetime_type() ->
    datetime_cached_class(
        pyrlang_datetime_class,
        <<"datetime">>,
        [date_type()],
        fun(Class) ->
            #{
                <<"__pyrlang_builtin_constructor__">> =>
                    {py_native_varargs, fun(Args) -> datetime_new(Class, Args) end},
                <<"fromisoformat">> => fun(Value) -> datetime_fromisoformat(Class, Value) end,
                <<"now">> => {py_native_call, fun datetime_now/2},
                <<"utcnow">> => fun() -> datetime_value(calendar:universal_time()) end
            }
        end
    ).

date_type() ->
    datetime_cached_class(
        pyrlang_date_class,
        <<"date">>,
        [maps:get(<<"object">>, pyrlang_builtins:env())],
        fun(Class) ->
            #{
                <<"__pyrlang_builtin_constructor__">> =>
                    {py_native_varargs, fun(Args) -> date_new(Class, Args) end},
                <<"fromisoformat">> => fun(Value) -> date_fromisoformat(Class, Value) end,
                <<"fromordinal">> => fun(Ordinal) ->
                    date_value(Class, calendar:gregorian_days_to_date(Ordinal + 365))
                end,
                <<"today">> => fun() ->
                    {Date, _Time} = calendar:universal_time(),
                    date_value(Class, Date)
                end
            }
        end
    ).

time_type() ->
    datetime_cached_class(
        pyrlang_time_class,
        <<"TimeType">>,
        [maps:get(<<"object">>, pyrlang_builtins:env())],
        fun(Class) ->
            #{
                <<"__pyrlang_builtin_constructor__">> =>
                    {py_native_varargs, fun(Args) -> time_new(Class, Args) end},
                <<"fromisoformat">> => fun(Value) -> time_fromisoformat(Class, Value) end,
                <<"__name__">> => <<"TimeType">>
            }
        end
    ).

datetime_cached_class(Key, Name, Bases, AttrsFun) ->
    case erlang:get(Key) of
        undefined ->
            Class = pyrlang_object:new_class(Name, Bases, #{}),
            maps:foreach(
                fun(Attr, Value) -> ok = pyrlang_object:set_class_attr(Class, Attr, Value) end,
                AttrsFun(Class)
            ),
            erlang:put(Key, Class),
            Class;
        Class ->
            try pyrlang_heap:type(Class) of
                class ->
                    Class;
                _Other ->
                    erlang:erase(Key),
                    datetime_cached_class(Key, Name, Bases, AttrsFun)
            catch
                _:_ ->
                    erlang:erase(Key),
                    datetime_cached_class(Key, Name, Bases, AttrsFun)
            end
    end.

datetime_new(Class, [Year, Month, Day]) ->
    datetime_value(Class, {{Year, Month, Day}, {0, 0, 0}});
datetime_new(Class, [Year, Month, Day, Hour]) ->
    datetime_value(Class, {{Year, Month, Day}, {Hour, 0, 0}});
datetime_new(Class, [Year, Month, Day, Hour, Minute]) ->
    datetime_value(Class, {{Year, Month, Day}, {Hour, Minute, 0}});
datetime_new(Class, [Year, Month, Day, Hour, Minute, Second]) ->
    datetime_value(Class, {{Year, Month, Day}, {Hour, Minute, Second}});
datetime_new(_Class, Args) ->
    erlang:error({arity_error, {datetime, length(Args)}}).

datetime_fromisoformat(Class, Value) ->
    Text = normalize_name(Value),
    {Date, Rest} = parse_iso_date(Text),
    Time =
        case Rest of
            <<>> -> {0, 0, 0};
            <<"T", TimeText/binary>> -> parse_iso_time(TimeText);
            <<" ", TimeText/binary>> -> parse_iso_time(TimeText);
            _ -> invalid_isoformat(Text)
        end,
    datetime_value(Class, {Date, Time}).

date_new(Class, [Year, Month, Day]) ->
    date_value(Class, {Year, Month, Day});
date_new(_Class, Args) ->
    erlang:error({arity_error, {date, length(Args)}}).

date_fromisoformat(Class, Value) ->
    {Date, _Rest} = parse_iso_date(normalize_name(Value)),
    date_value(Class, Date).

time_new(Class, []) ->
    time_value(Class, {0, 0, 0});
time_new(Class, [Hour]) ->
    time_value(Class, {Hour, 0, 0});
time_new(Class, [Hour, Minute]) ->
    time_value(Class, {Hour, Minute, 0});
time_new(Class, [Hour, Minute, Second]) ->
    time_value(Class, {Hour, Minute, Second});
time_new(_Class, Args) ->
    erlang:error({arity_error, {time, length(Args)}}).

time_fromisoformat(Class, Value) ->
    time_value(Class, parse_iso_time(normalize_name(Value))).

parse_iso_date(<<Year:4/binary, "-", Month:2/binary, "-", Day:2/binary, Rest/binary>>) ->
    {{binary_to_integer(Year), binary_to_integer(Month), binary_to_integer(Day)}, Rest};
parse_iso_date(Text) ->
    invalid_isoformat(Text).

parse_iso_time(<<Hour:2/binary, ":", Minute:2/binary, ":", Second:2/binary, _Rest/binary>>) ->
    {binary_to_integer(Hour), binary_to_integer(Minute), binary_to_integer(Second)};
parse_iso_time(<<Hour:2/binary, ":", Minute:2/binary, _Rest/binary>>) ->
    {binary_to_integer(Hour), binary_to_integer(Minute), 0};
parse_iso_time(Text) ->
    invalid_isoformat(Text).

invalid_isoformat(Text) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), {invalid_isoformat, Text})
    ).

datetime_now([], KwArgs) ->
    Tz = maps:get(<<"tz">>, KwArgs, none),
    datetime_value(datetime_type(), calendar:universal_time(), Tz);
datetime_now([Tz], KwArgs) when map_size(KwArgs) =:= 0 ->
    datetime_value(datetime_type(), calendar:universal_time(), Tz);
datetime_now(Args, _KwArgs) ->
    erlang:error({arity_error, {datetime_now, length(Args)}}).

datetime_value(DateTime) ->
    datetime_value(datetime_type(), DateTime).

datetime_value(Class, {{Year, Month, Day}, {Hour, Minute, Second}}) ->
    datetime_value(Class, {{Year, Month, Day}, {Hour, Minute, Second}}, none).

datetime_value(Class, {{Year, Month, Day}, {Hour, Minute, Second}}, Tz) ->
    DateTime = {{Year, Month, Day}, {Hour, Minute, Second}},
    Iso = iolist_to_binary(
        io_lib:format(
            "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B",
            [Year, Month, Day, Hour, Minute, Second]
        )
    ),
    Str = iolist_to_binary(
        io_lib:format(
            "~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
            [Year, Month, Day, Hour, Minute, Second]
        )
    ),
    Date = {Year, Month, Day},
    native_instance(Class, <<"Datetime">>, #{
        <<"year">> => Year,
        <<"month">> => Month,
        <<"day">> => Day,
        <<"hour">> => Hour,
        <<"minute">> => Minute,
        <<"second">> => Second,
        <<"tzinfo">> => Tz,
        <<"__add__">> => fun(Delta) -> datetime_add_timedelta(Class, DateTime, Tz, Delta) end,
        <<"__sub__">> => fun(Other) -> datetime_subtract(Class, DateTime, Tz, Other) end,
        <<"__str__">> => fun() -> Str end,
        <<"astimezone">> => fun(NewTz) -> datetime_value(Class, DateTime, NewTz) end,
        <<"date">> => fun() -> date_value(Date) end,
        <<"isoformat">> => fun() -> Iso end,
        <<"replace">> =>
            {py_native_call, fun(Args, KwArgs) ->
                datetime_replace(Class, DateTime, Tz, Args, KwArgs)
            end},
        <<"strftime">> => fun(Format) ->
            time_format(
                normalize_name(Format), time_struct_tuple({Date, {Hour, Minute, Second}}, false)
            )
        end,
        <<"timetuple">> => fun() -> time_struct_tuple({Date, {Hour, Minute, Second}}, false) end,
        <<"toordinal">> => fun() -> calendar:date_to_gregorian_days(Date) - 365 end,
        <<"utcoffset">> => fun() -> datetime_utcoffset(Tz) end,
        <<"weekday">> => fun() -> calendar:day_of_the_week(Date) - 1 end
    }).

datetime_add_timedelta(Class, DateTime, Tz, Delta) ->
    case timedelta_total_seconds(Delta) of
        {ok, Seconds} -> datetime_shift(Class, DateTime, Tz, Seconds);
        error -> not_implemented
    end.

datetime_subtract(Class, DateTime, Tz, Other) ->
    case timedelta_total_seconds(Other) of
        {ok, Seconds} ->
            datetime_shift(Class, DateTime, Tz, -Seconds);
        error ->
            case datetime_tuple(Other) of
                {ok, OtherDateTime} ->
                    Diff =
                        calendar:datetime_to_gregorian_seconds(DateTime) -
                            calendar:datetime_to_gregorian_seconds(OtherDateTime),
                    timedelta_value(timedelta_type(), Diff);
                error ->
                    not_implemented
            end
    end.

datetime_shift(Class, DateTime, Tz, Seconds) ->
    Base = calendar:datetime_to_gregorian_seconds(DateTime),
    datetime_value(Class, calendar:gregorian_seconds_to_datetime(Base + trunc(Seconds)), Tz).

datetime_tuple({py_ref, _} = Value) ->
    try
        Year = pyrlang_object:get_attr(Value, <<"year">>),
        Month = pyrlang_object:get_attr(Value, <<"month">>),
        Day = pyrlang_object:get_attr(Value, <<"day">>),
        Hour = pyrlang_object:get_attr(Value, <<"hour">>),
        Minute = pyrlang_object:get_attr(Value, <<"minute">>),
        Second = pyrlang_object:get_attr(Value, <<"second">>),
        {ok, {{Year, Month, Day}, {Hour, Minute, Second}}}
    catch
        _:_ -> error
    end;
datetime_tuple(_Value) ->
    error.

datetime_utcoffset(none) ->
    none;
datetime_utcoffset(Tz) ->
    try pyrlang_object:get_attr(Tz, <<"utcoffset">>) of
        Offset -> pyrlang_eval:call(Offset, [none])
    catch
        _:_ -> none
    end.

datetime_replace(Class, {{Year, Month, Day}, {Hour, Minute, Second}}, Tz, [], KwArgs) ->
    NewDate = {
        maps:get(<<"year">>, KwArgs, Year),
        maps:get(<<"month">>, KwArgs, Month),
        maps:get(<<"day">>, KwArgs, Day)
    },
    NewTime = {
        maps:get(<<"hour">>, KwArgs, Hour),
        maps:get(<<"minute">>, KwArgs, Minute),
        maps:get(<<"second">>, KwArgs, Second)
    },
    NewTz = maps:get(<<"tzinfo">>, KwArgs, Tz),
    datetime_value(Class, {NewDate, NewTime}, NewTz);
datetime_replace(_Class, _DateTime, _Tz, Args, _KwArgs) ->
    erlang:error({arity_error, {datetime_replace, length(Args)}}).

date_value(Date) ->
    date_value(date_type(), Date).

date_value(Class, {Year, Month, Day}) ->
    Iso = iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Year, Month, Day])),
    Date = {Year, Month, Day},
    native_instance(Class, <<"Date">>, #{
        <<"year">> => Year,
        <<"month">> => Month,
        <<"day">> => Day,
        <<"__str__">> => fun() -> Iso end,
        <<"isoformat">> => fun() -> Iso end,
        <<"strftime">> => fun(Format) ->
            time_format(normalize_name(Format), time_struct_tuple({Date, {0, 0, 0}}, false))
        end,
        <<"timetuple">> => fun() -> time_struct_tuple({Date, {0, 0, 0}}, false) end,
        <<"toordinal">> => fun() -> calendar:date_to_gregorian_days(Date) - 365 end,
        <<"weekday">> => fun() -> calendar:day_of_the_week(Date) - 1 end
    }).

time_value(Class, {Hour, Minute, Second}) ->
    Iso = iolist_to_binary(io_lib:format("~2..0B:~2..0B:~2..0B", [Hour, Minute, Second])),
    native_instance(Class, <<"Time">>, #{
        <<"hour">> => Hour,
        <<"minute">> => Minute,
        <<"second">> => Second,
        <<"__str__">> => fun() -> Iso end,
        <<"isoformat">> => fun() -> Iso end,
        <<"strftime">> => fun(Format) ->
            time_format(
                normalize_name(Format),
                time_struct_tuple({{1970, 1, 1}, {Hour, Minute, Second}}, false)
            )
        end
    }).

decimal_new([Value], KwArgs) when map_size(KwArgs) =:= 0 ->
    decimal_instance(decimal_number(Value));
decimal_new(Args, _KwArgs) ->
    erlang:error({arity_error, {decimal, length(Args)}}).

decimal_context_new(Args, KwArgs) ->
    case {Args, maps:keys(maps:without([<<"prec">>], KwArgs))} of
        {[], []} ->
            decimal_context_instance(maps:get(<<"prec">>, KwArgs, 28));
        {[Prec], []} when is_integer(Prec) ->
            decimal_context_instance(Prec);
        {_, Extra} when Extra =/= [] ->
            erlang:error({type_error, {unexpected_keyword_argument, Extra}});
        _ ->
            erlang:error({arity_error, {decimal_context, length(Args), maps:size(KwArgs)}})
    end.

decimal_getcontext([]) ->
    decimal_context_instance(28);
decimal_getcontext(Args) ->
    erlang:error({arity_error, {decimal_getcontext, length(Args)}}).

decimal_context_instance(Prec) ->
    native_instance(<<"Context">>, #{
        <<"prec">> => Prec,
        <<"traps">> => pyrlang_heap:dict([]),
        <<"copy">> => fun() -> decimal_context_instance(Prec) end,
        <<"create_decimal_from_float">> => fun(Value) -> decimal_instance(decimal_number(Value)) end
    }).

decimal_instance(Number) ->
    Value = decimal_format(Number),
    native_instance(<<"Decimal">>, #{
        <<"__pyrlang_value__">> => Value,
        <<"value">> => Value,
        <<"__int__">> => fun() -> trunc(Number) end,
        <<"__add__">> => fun(Other) -> decimal_instance(Number + decimal_object_number(Other)) end,
        <<"__sub__">> => fun(Other) -> decimal_instance(Number - decimal_object_number(Other)) end,
        <<"quantize">> =>
            {py_native_call, fun(Args, KwArgs) -> decimal_quantize(Number, Args, KwArgs) end},
        <<"scaleb">> => {py_native_varargs, fun(Args) -> decimal_scaleb(Number, Args) end}
    }).

decimal_object_number(Object) ->
    decimal_number(pyrlang_object:get_attr(Object, <<"value">>)).

decimal_number(Value) when is_integer(Value) ->
    Value * 1.0;
decimal_number(Value) when is_float(Value) ->
    Value;
decimal_number(Value) when is_binary(Value) ->
    binary_to_floatable(Value);
decimal_number(Value) when is_list(Value) ->
    binary_to_floatable(unicode:characters_to_binary(Value));
decimal_number({py_ref, _} = Value) ->
    decimal_object_number(Value).

decimal_quantize(Number, [Exponent], KwArgs) ->
    decimal_quantize(
        Number,
        [Exponent, maps:get(<<"rounding">>, KwArgs, <<"ROUND_HALF_EVEN">>)],
        maps:without([<<"rounding">>], KwArgs)
    );
decimal_quantize(Number, [_Exponent, Rounding], KwArgs) when map_size(KwArgs) =:= 0 ->
    decimal_instance(decimal_round(Number, Rounding));
decimal_quantize(Number, [_Exponent, Rounding, _Context], KwArgs) when map_size(KwArgs) =:= 0 ->
    decimal_instance(decimal_round(Number, Rounding));
decimal_quantize(_Number, Args, KwArgs) ->
    erlang:error({arity_error, {decimal_quantize, length(Args), maps:size(KwArgs)}}).

decimal_scaleb(Number, [Places]) when is_integer(Places) ->
    decimal_instance(Number * decimal_pow10(Places));
decimal_scaleb(_Number, Args) ->
    erlang:error({arity_error, {decimal_scaleb, length(Args)}}).

decimal_pow10(Places) when Places >= 0 ->
    decimal_pow10_positive(Places, 1.0);
decimal_pow10(Places) ->
    1.0 / decimal_pow10(-Places).

decimal_pow10_positive(0, Acc) ->
    Acc;
decimal_pow10_positive(Places, Acc) ->
    decimal_pow10_positive(Places - 1, Acc * 10.0).

decimal_round(Number, <<"ROUND_UP">>) when Number >= 0 ->
    decimal_ceil(Number);
decimal_round(Number, <<"ROUND_UP">>) ->
    decimal_floor(Number);
decimal_round(Number, <<"ROUND_CEILING">>) ->
    decimal_ceil(Number);
decimal_round(Number, <<"ROUND_FLOOR">>) ->
    decimal_floor(Number);
decimal_round(Number, <<"ROUND_DOWN">>) ->
    trunc(Number);
decimal_round(Number, _Rounding) ->
    round(Number).

decimal_ceil(Number) ->
    Truncated = trunc(Number),
    case Number > Truncated of
        true -> Truncated + 1;
        false -> Truncated
    end.

decimal_floor(Number) ->
    Truncated = trunc(Number),
    case Number < Truncated of
        true -> Truncated - 1;
        false -> Truncated
    end.

binary_to_floatable(Value) ->
    try
        binary_to_float(Value)
    catch
        error:badarg -> binary_to_integer(Value) * 1.0
    end.

decimal_format(Number) when is_integer(Number) ->
    integer_to_binary(Number);
decimal_format(Number) ->
    Formatted = float_to_binary(Number, [{decimals, 12}, compact]),
    case binary:split(Formatted, <<".">>) of
        [_Whole, Fraction] when Fraction =:= <<>> -> <<Formatted/binary, "0">>;
        _ -> Formatted
    end.

psycopg2_env(Name) ->
    (psycopg2_common_env(Name, <<"psycopg2">>))#{
        <<"__path__">> => pyrlang_heap:list([]),
        <<"__version__">> => <<"2.9.9 (pyrlang)">>,
        <<"apilevel">> => pyrlang_dbapi:apilevel(),
        <<"threadsafety">> => pyrlang_dbapi:threadsafety(),
        <<"paramstyle">> => <<"pyformat">>,
        <<"connect">> => {py_native_call, fun psycopg2_connect/2},
        <<"Connection">> => psycopg2_connection_type(),
        <<"Cursor">> => psycopg2_cursor_type()
    }.

psycopg2_extensions_env() ->
    (psycopg2_common_env(<<"psycopg2.extensions">>, <<"psycopg2">>))#{
        <<"ISOLATION_LEVEL_READ_UNCOMMITTED">> => 1,
        <<"ISOLATION_LEVEL_READ_COMMITTED">> => 1,
        <<"ISOLATION_LEVEL_REPEATABLE_READ">> => 2,
        <<"ISOLATION_LEVEL_SERIALIZABLE">> => 3,
        <<"ISOLATION_LEVEL_AUTOCOMMIT">> => 0,
        <<"UNICODE">> => <<"UNICODE">>,
        <<"cursor">> => psycopg2_cursor_type(),
        <<"register_adapter">> => {py_native_varargs, fun psycopg2_noop/1},
        <<"register_type">> => {py_native_varargs, fun psycopg2_noop/1},
        <<"new_array_type">> => {py_native_varargs, fun psycopg2_new_array_type/1},
        <<"adapt">> => fun(Value) -> psycopg2_quoted(Value) end,
        <<"QuotedString">> => psycopg2_quoted_string_type()
    }.

psycopg2_extras_env() ->
    Range = psycopg2_simple_type(<<"Range">>),
    (psycopg2_common_env(<<"psycopg2.extras">>, <<"psycopg2">>))#{
        <<"register_uuid">> => {py_native_varargs, fun psycopg2_noop/1},
        <<"register_default_jsonb">> => {py_native_call, fun(_Args, _KwArgs) -> none end},
        <<"Json">> => psycopg2_json_type(),
        <<"Range">> => Range,
        <<"DateRange">> => Range,
        <<"DateTimeRange">> => Range,
        <<"DateTimeTZRange">> => Range,
        <<"NumericRange">> => Range,
        <<"Inet">> => fun(Value) -> Value end
    }.

psycopg2_errors_env() ->
    (psycopg2_common_env(<<"psycopg2.errors">>, <<"psycopg2">>))#{
        <<"DuplicateDatabase">> => pyrlang_exception:type(<<"DuplicateDatabase">>)
    }.

psycopg2_sql_env() ->
    (psycopg2_common_env(<<"psycopg2.sql">>, <<"psycopg2">>))#{
        <<"quote">> => fun(Value, _Connection) -> postgres_quote_value(Value) end
    }.

psycopg2_common_env(Name, Package) ->
    #{
        <<"__name__">> => Name,
        <<"__file__">> => builtin,
        <<"__package__">> => Package,
        <<"__path__">> => none,
        <<"Error">> => pyrlang_exception:type(<<"Error">>),
        <<"Warning">> => pyrlang_exception:type(<<"Warning">>),
        <<"InterfaceError">> => pyrlang_exception:type(<<"InterfaceError">>),
        <<"DatabaseError">> => pyrlang_exception:type(<<"DatabaseError">>),
        <<"DataError">> => pyrlang_exception:type(<<"DataError">>),
        <<"OperationalError">> => pyrlang_exception:type(<<"OperationalError">>),
        <<"IntegrityError">> => pyrlang_exception:type(<<"IntegrityError">>),
        <<"InternalError">> => pyrlang_exception:type(<<"InternalError">>),
        <<"ProgrammingError">> => pyrlang_exception:type(<<"ProgrammingError">>),
        <<"NotSupportedError">> => pyrlang_exception:type(<<"NotSupportedError">>)
    }.

psycopg2_connection_type() ->
    psycopg2_cached_type(psycopg2_connection_type, <<"Connection">>, #{}).

psycopg2_cursor_type() ->
    psycopg2_cached_type(psycopg2_cursor_type, <<"cursor">>, #{
        <<"execute">> => {py_native_varargs, fun postgres_cursor_method_execute/1},
        <<"fetchall">> => fun(Self) -> cursor_fetchall(postgres_cursor_rows_ref(Self)) end,
        <<"fetchone">> => fun(Self) -> sqlite_cursor_fetchone(postgres_cursor_rows_ref(Self)) end,
        <<"fetchmany">> => {py_native_varargs, fun postgres_cursor_method_fetchmany/1},
        <<"mogrify">> => {py_native_varargs, fun postgres_cursor_method_mogrify/1},
        <<"close">> => fun(_Self) -> none end,
        <<"__enter__">> => fun(Self) -> Self end,
        <<"__exit__">> => fun(_Self, _ExcType, _Exc, _Tb) -> false end
    }).

psycopg2_quoted_string_type() ->
    psycopg2_cached_type(psycopg2_quoted_string_type, <<"QuotedString">>, #{
        <<"__init__">> => fun(Self, Value) ->
            ok = pyrlang_object:set_attr(Self, <<"adapted">>, Value),
            none
        end,
        <<"getquoted">> => fun(Self) ->
            Value = pyrlang_object:get_attr(Self, <<"adapted">>),
            unicode:characters_to_binary(postgres_quote_value(Value))
        end
    }).

psycopg2_json_type() ->
    psycopg2_cached_type(psycopg2_json_type, <<"Json">>, #{
        <<"__init__">> =>
            {py_native_varargs, fun
                ([Self, Value]) ->
                    ok = pyrlang_object:set_attr(Self, <<"adapted">>, Value),
                    none;
                ([Self, Value, _Dumps]) ->
                    ok = pyrlang_object:set_attr(Self, <<"adapted">>, Value),
                    none;
                (Args) ->
                    erlang:error({arity_error, {json, length(Args)}})
            end},
        <<"getquoted">> => fun(Self) ->
            Value = pyrlang_object:get_attr(Self, <<"adapted">>),
            unicode:characters_to_binary(postgres_quote_value(Value))
        end
    }).

psycopg2_simple_type(Name) ->
    psycopg2_cached_type({psycopg2_simple_type, Name}, Name, #{}).

psycopg2_cached_type(Key, Name, Attrs) ->
    case erlang:get(Key) of
        undefined ->
            Class = pyrlang_object:new_class(
                Name, [maps:get(<<"object">>, pyrlang_builtins:env())], Attrs
            ),
            erlang:put(Key, Class),
            Class;
        Class ->
            try
                case
                    pyrlang_heap:type(Class) =:= class andalso
                        pyrlang_object:class_name(Class) =:= Name
                of
                    true ->
                        Class;
                    false ->
                        erlang:erase(Key),
                        psycopg2_cached_type(Key, Name, Attrs)
                end
            catch
                _:_ ->
                    erlang:erase(Key),
                    psycopg2_cached_type(Key, Name, Attrs)
            end
    end.

psycopg2_connect(Args, KwArgs) ->
    Params0 =
        case Args of
            [] -> #{};
            [_Dsn] -> #{};
            _ -> erlang:error({arity_error, {psycopg2_connect, length(Args)}})
        end,
    Params = maps:merge(Params0, KwArgs),
    CursorFactory = maps:get(<<"cursor_factory">>, Params, psycopg2_cursor_type()),
    Pid = pyrlang_postgres:connect(Params),
    postgres_connection_instance(Pid, CursorFactory).

postgres_connection_instance(Pid, CursorFactory) ->
    native_instance(psycopg2_connection_type(), <<"Connection">>, #{
        <<"__pyrlang_unsendable__">> => psycopg2_connection,
        <<"cursor">> =>
            {py_native_call, fun(Args, KwArgs) ->
                postgres_connection_cursor(Pid, CursorFactory, Args, KwArgs)
            end},
        <<"commit">> => fun() -> none end,
        <<"rollback">> => fun() -> none end,
        <<"close">> => fun() ->
            ok = pyrlang_postgres:close(Pid),
            none
        end,
        <<"autocommit">> => true,
        <<"isolation_level">> => 1,
        <<"closed">> => false,
        <<"info">> => postgres_connection_info()
    }).

postgres_connection_info() ->
    native_instance(<<"ConnectionInfo">>, #{
        <<"server_version">> => 160000,
        <<"parameter_status">> => fun
            (<<"TimeZone">>) -> <<"UTC">>;
            (_Name) -> none
        end
    }).

postgres_connection_cursor(Pid, DefaultFactory, Args, KwArgs) ->
    case
        maps:keys(
            maps:without(
                [<<"cursor_factory">>, <<"name">>, <<"scrollable">>, <<"withhold">>], KwArgs
            )
        )
    of
        [] ->
            ok;
        Extra ->
            erlang:error({type_error, {unexpected_keyword_argument, Extra}})
    end,
    Factory = maps:get(<<"cursor_factory">>, KwArgs, DefaultFactory),
    case Args of
        [] -> postgres_cursor_instance(Pid, Factory);
        [_Name] -> postgres_cursor_instance(Pid, Factory);
        _ -> erlang:error({arity_error, {postgres_connection_cursor, length(Args)}})
    end.

postgres_cursor_instance(Pid, Class0) ->
    Class =
        try
            class = pyrlang_heap:type(Class0),
            Class0
        catch
            _:_ -> psycopg2_cursor_type()
        end,
    Cursor = pyrlang_object:instantiate(Class),
    RowsRef = pyrlang_heap:list([]),
    ok = pyrlang_object:set_attr(Cursor, <<"__pyrlang_unsendable__">>, psycopg2_cursor),
    ok = pyrlang_object:set_attr(Cursor, <<"__pyrlang_postgres_pid__">>, Pid),
    ok = pyrlang_object:set_attr(Cursor, <<"__pyrlang_postgres_rows__">>, RowsRef),
    ok = pyrlang_object:set_attr(Cursor, <<"arraysize">>, 1),
    ok = pyrlang_object:set_attr(Cursor, <<"rowcount">>, -1),
    ok = pyrlang_object:set_attr(Cursor, <<"description">>, none),
    ok = pyrlang_object:set_attr(Cursor, <<"query">>, none),
    Cursor.

postgres_cursor_method_execute([Cursor, Sql]) ->
    postgres_cursor_execute(Cursor, [Sql, []]);
postgres_cursor_method_execute([Cursor, Sql, Params]) ->
    postgres_cursor_execute(Cursor, [Sql, Params]);
postgres_cursor_method_execute(Args) ->
    erlang:error({arity_error, {postgres_cursor_execute, length(Args)}}).

postgres_cursor_execute(Cursor, [Sql, Params]) ->
    SqlText = normalize_name(Sql),
    ParamList = postgres_params(Params),
    BoundSql = pyrlang_postgres:mogrify(SqlText, ParamList),
    try
        {Rows0, RowCount, _Output} = pyrlang_postgres:execute(
            postgres_cursor_pid(Cursor), SqlText, ParamList
        ),
        Rows = [list_to_tuple(Row) || Row <- Rows0],
        ok = pyrlang_heap:set_data(postgres_cursor_rows_ref(Cursor), Rows),
        ok = pyrlang_object:set_attr(Cursor, <<"rowcount">>, RowCount),
        ok = pyrlang_object:set_attr(Cursor, <<"description">>, postgres_description(Rows)),
        ok = pyrlang_object:set_attr(Cursor, <<"query">>, BoundSql),
        Cursor
    catch
        error:{dbapi_operational_error, Reason} ->
            raise_postgres_exception(<<"OperationalError">>, Reason);
        error:{dbapi_programming_error, Reason} ->
            raise_postgres_exception(<<"ProgrammingError">>, Reason);
        error:{dbapi_error, Reason} ->
            raise_postgres_exception(<<"DatabaseError">>, Reason)
    end.

postgres_cursor_method_mogrify([_Cursor, Sql]) ->
    pyrlang_postgres:mogrify(normalize_name(Sql), []);
postgres_cursor_method_mogrify([_Cursor, Sql, Params]) ->
    pyrlang_postgres:mogrify(normalize_name(Sql), postgres_params(Params));
postgres_cursor_method_mogrify(Args) ->
    erlang:error({arity_error, {postgres_cursor_mogrify, length(Args)}}).

postgres_cursor_method_fetchmany([Cursor]) ->
    sqlite_cursor_fetchmany(
        postgres_cursor_rows_ref(Cursor), pyrlang_object:get_attr(Cursor, <<"arraysize">>)
    );
postgres_cursor_method_fetchmany([Cursor, Size]) ->
    sqlite_cursor_fetchmany(postgres_cursor_rows_ref(Cursor), Size);
postgres_cursor_method_fetchmany(Args) ->
    erlang:error({arity_error, {postgres_cursor_fetchmany, length(Args)}}).

postgres_cursor_pid(Cursor) ->
    pyrlang_object:get_attr(Cursor, <<"__pyrlang_postgres_pid__">>).

postgres_cursor_rows_ref(Cursor) ->
    pyrlang_object:get_attr(Cursor, <<"__pyrlang_postgres_rows__">>).

postgres_description([]) ->
    none;
postgres_description([Row | _]) when is_tuple(Row) ->
    pyrlang_heap:list([postgres_column_description(Index) || Index <- lists:seq(1, tuple_size(Row))]).

postgres_column_description(Index) ->
    native_instance(<<"Column">>, #{
        <<"name">> => <<"column", (integer_to_binary(Index))/binary>>,
        <<"type_code">> => 25,
        <<"display_size">> => none,
        <<"internal_size">> => none,
        <<"precision">> => none,
        <<"scale">> => none,
        <<"null_ok">> => none
    }).

postgres_params(none) ->
    [];
postgres_params(undefined) ->
    [];
postgres_params({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> pyrlang_heap:list_items(Ref);
        _ -> pyrlang_iter:values(Ref)
    end;
postgres_params(Tuple) when is_tuple(Tuple) ->
    tuple_to_list(Tuple);
postgres_params(List) when is_list(List) ->
    List.

postgres_quote_value(Value) ->
    pyrlang_postgres:mogrify(<<"%s">>, [Value]).

psycopg2_quoted(Value) ->
    native_instance(psycopg2_quoted_string_type(), <<"QuotedString">>, #{
        <<"adapted">> => Value
    }).

psycopg2_noop(_Args) ->
    none.

psycopg2_new_array_type([_Oids, Name, _Base]) ->
    Name;
psycopg2_new_array_type(Args) ->
    erlang:error({arity_error, {new_array_type, length(Args)}}).

raise_postgres_exception(Type, Reason) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(Type), Reason)).

sqlite3_env(Name) ->
    #{
        <<"__name__">> => Name,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"apilevel">> => pyrlang_dbapi:apilevel(),
        <<"threadsafety">> => pyrlang_dbapi:threadsafety(),
        <<"paramstyle">> => atom_to_binary(pyrlang_dbapi:paramstyle(), utf8),
        <<"sqlite_version">> => <<"3.44.0">>,
        <<"sqlite_version_info">> => {3, 44, 0},
        <<"version">> => <<"2.6.0">>,
        <<"_deprecated_version">> => <<"2.6.0">>,
        <<"PARSE_DECLTYPES">> => 1,
        <<"PARSE_COLNAMES">> => 2,
        <<"Error">> => pyrlang_exception:type(<<"Error">>),
        <<"Warning">> => pyrlang_exception:type(<<"Warning">>),
        <<"InterfaceError">> => pyrlang_exception:type(<<"InterfaceError">>),
        <<"DatabaseError">> => pyrlang_exception:type(<<"DatabaseError">>),
        <<"DataError">> => pyrlang_exception:type(<<"DataError">>),
        <<"OperationalError">> => pyrlang_exception:type(<<"OperationalError">>),
        <<"IntegrityError">> => pyrlang_exception:type(<<"IntegrityError">>),
        <<"InternalError">> => pyrlang_exception:type(<<"InternalError">>),
        <<"ProgrammingError">> => pyrlang_exception:type(<<"ProgrammingError">>),
        <<"NotSupportedError">> => pyrlang_exception:type(<<"NotSupportedError">>),
        <<"Connection">> => sqlite3_connection_type(),
        <<"Cursor">> => sqlite3_cursor_type(),
        <<"Row">> => sqlite3_row_type(),
        <<"connect">> => {py_native_call, fun sqlite3_connect/2},
        <<"register_adapter">> => {py_native_varargs, fun sqlite3_noop/1},
        <<"register_converter">> => {py_native_varargs, fun sqlite3_noop/1},
        <<"adapt">> => {py_native_varargs, fun sqlite3_adapt/1},
        <<"complete_statement">> => fun(_Sql) -> true end
    }.

sqlite3_connection_type() ->
    sqlite3_cached_type(sqlite3_connection_type, <<"Connection">>, #{}).

sqlite3_cursor_type() ->
    sqlite3_cached_type(sqlite3_cursor_type, <<"Cursor">>, #{
        <<"execute">> => {py_native_varargs, fun sqlite_cursor_method_execute/1},
        <<"executemany">> => {py_native_varargs, fun sqlite_cursor_method_executemany/1},
        <<"fetchall">> => fun(Self) -> cursor_fetchall(sqlite_cursor_rows_ref(Self)) end,
        <<"fetchone">> => fun(Self) -> sqlite_cursor_fetchone(sqlite_cursor_rows_ref(Self)) end,
        <<"fetchmany">> => {py_native_varargs, fun sqlite_cursor_method_fetchmany/1},
        <<"close">> => fun(_Self) -> none end,
        <<"__enter__">> => fun(Self) -> Self end,
        <<"__exit__">> => fun(Self, _Type, _Value, _Traceback) ->
            _ = pyrlang_eval:call(pyrlang_object:get_attr(Self, <<"close">>), []),
            false
        end
    }).

sqlite3_row_type() ->
    sqlite3_cached_type(sqlite3_row_type, <<"Row">>, #{}).

sqlite3_cached_type(Key, Name, Attrs) ->
    case erlang:get(Key) of
        undefined ->
            Class = pyrlang_object:new_class(
                Name, [maps:get(<<"object">>, pyrlang_builtins:env())], Attrs
            ),
            erlang:put(Key, Class),
            Class;
        Class ->
            try pyrlang_heap:type(Class) of
                class ->
                    Class;
                _Other ->
                    erlang:erase(Key),
                    sqlite3_cached_type(Key, Name, Attrs)
            catch
                _:_ ->
                    erlang:erase(Key),
                    sqlite3_cached_type(Key, Name, Attrs)
            end
    end.

sqlite3_noop(_Args) ->
    none.

sqlite3_adapt([Value]) ->
    Value;
sqlite3_adapt([Value, _Protocol]) ->
    Value;
sqlite3_adapt(Args) ->
    erlang:error({arity_error, {sqlite3_adapt, length(Args)}}).

sqlite3_connect([], KwArgs) ->
    case maps:take(<<"database">>, KwArgs) of
        {Path, Rest} -> sqlite3_connect([Path], Rest);
        error -> erlang:error({arity_error, {sqlite3_connect, 0}})
    end;
sqlite3_connect([Path], KwArgs0) ->
    Allowed = [
        <<"timeout">>,
        <<"detect_types">>,
        <<"isolation_level">>,
        <<"check_same_thread">>,
        <<"factory">>,
        <<"cached_statements">>,
        <<"uri">>,
        <<"autocommit">>
    ],
    case maps:keys(maps:without(Allowed, KwArgs0)) of
        [] -> sqlite_connection_instance(pyrlang_sqlite:connect(normalize_name(Path)));
        Extra -> erlang:error({type_error, {unexpected_keyword_argument, Extra}})
    end;
sqlite3_connect(Args, _KwArgs) ->
    erlang:error({arity_error, {sqlite3_connect, length(Args)}}).

sqlite_connection_instance(Pid) ->
    native_instance(sqlite3_connection_type(), <<"Connection">>, #{
        <<"__pyrlang_unsendable__">> => sqlite3_connection,
        <<"execute">> => {py_native_varargs, fun(Args) -> sqlite_connection_execute(Pid, Args) end},
        <<"cursor">> =>
            {py_native_call, fun(Args, KwArgs) -> sqlite_connection_cursor(Pid, Args, KwArgs) end},
        <<"create_function">> => {py_native_call, fun(_Args, _KwArgs) -> none end},
        <<"create_aggregate">> => {py_native_varargs, fun(_Args) -> none end},
        <<"commit">> => fun() ->
            ok = pyrlang_sqlite:execute(Pid, "commit"),
            none
        end,
        <<"rollback">> => fun() ->
            ok = pyrlang_sqlite:execute(Pid, "rollback"),
            none
        end,
        <<"close">> => fun() ->
            ok = pyrlang_sqlite:close(Pid),
            none
        end
    }).

sqlite_connection_cursor(Pid, [], KwArgs0) ->
    case maps:keys(maps:without([<<"factory">>], KwArgs0)) of
        [] ->
            Factory = maps:get(<<"factory">>, KwArgs0, sqlite3_cursor_type()),
            sqlite_cursor_instance(Pid, Factory);
        Extra ->
            erlang:error({type_error, {unexpected_keyword_argument, Extra}})
    end;
sqlite_connection_cursor(Pid, [Factory], KwArgs) when map_size(KwArgs) =:= 0 ->
    sqlite_cursor_instance(Pid, Factory);
sqlite_connection_cursor(_Pid, Args, _KwArgs) ->
    erlang:error({arity_error, {sqlite_connection_cursor, length(Args)}}).

sqlite_connection_execute(Pid, Args) ->
    Cursor = sqlite_cursor_instance(Pid),
    Execute = pyrlang_object:get_attr(Cursor, <<"execute">>),
    _ = pyrlang_eval:call(Execute, Args),
    Cursor.

sqlite_cursor_instance(Pid) ->
    sqlite_cursor_instance(Pid, sqlite3_cursor_type()).

sqlite_cursor_instance(Pid, Class) ->
    Cursor = pyrlang_object:instantiate(Class),
    RowsRef = pyrlang_heap:list([]),
    ok = pyrlang_object:set_attr(Cursor, <<"__pyrlang_unsendable__">>, sqlite3_cursor),
    ok = pyrlang_object:set_attr(Cursor, <<"__pyrlang_sqlite_pid__">>, Pid),
    ok = pyrlang_object:set_attr(Cursor, <<"__pyrlang_sqlite_rows__">>, RowsRef),
    ok = pyrlang_object:set_attr(Cursor, <<"arraysize">>, 1),
    ok = pyrlang_object:set_attr(Cursor, <<"rowcount">>, -1),
    Cursor.

sqlite_cursor_method_execute([Cursor, Sql]) ->
    sqlite_cursor_execute(Cursor, sqlite_cursor_pid(Cursor), sqlite_cursor_rows_ref(Cursor), [Sql]);
sqlite_cursor_method_execute([Cursor, Sql, Params]) ->
    sqlite_cursor_execute(Cursor, sqlite_cursor_pid(Cursor), sqlite_cursor_rows_ref(Cursor), [
        Sql, Params
    ]);
sqlite_cursor_method_execute(Args) ->
    erlang:error({arity_error, {sqlite_cursor_execute, length(Args)}}).

sqlite_cursor_method_executemany([Cursor, Sql, ParamList]) ->
    lists:foreach(
        fun(Params) ->
            _ = sqlite_cursor_execute(
                Cursor, sqlite_cursor_pid(Cursor), sqlite_cursor_rows_ref(Cursor), [Sql, Params]
            )
        end,
        pyrlang_iter:values(ParamList)
    ),
    Cursor;
sqlite_cursor_method_executemany(Args) ->
    erlang:error({arity_error, {sqlite_cursor_executemany, length(Args)}}).

sqlite_cursor_pid(Cursor) ->
    pyrlang_object:get_attr(Cursor, <<"__pyrlang_sqlite_pid__">>).

sqlite_cursor_rows_ref(Cursor) ->
    pyrlang_object:get_attr(Cursor, <<"__pyrlang_sqlite_rows__">>).

sqlite_cursor_execute(Cursor, Pid, RowsRef, [Sql]) ->
    sqlite_cursor_execute(Cursor, Pid, RowsRef, [Sql, []]);
sqlite_cursor_execute(Cursor, Pid, RowsRef, [Sql, Params]) ->
    SqlText = normalize_name(Sql),
    ParamList = sqlite_params(Params),
    try
        case sqlite_is_query(SqlText) of
            true ->
                Rows = [list_to_tuple(Row) || Row <- pyrlang_sqlite:query(Pid, SqlText, ParamList)],
                ok = pyrlang_heap:set_data(RowsRef, Rows),
                ok = pyrlang_object:set_attr(Cursor, <<"rowcount">>, -1),
                Cursor;
            false ->
                RowCount = pyrlang_sqlite:execute_rowcount(Pid, SqlText, ParamList),
                ok = pyrlang_heap:set_data(RowsRef, []),
                ok = pyrlang_object:set_attr(Cursor, <<"rowcount">>, RowCount),
                Cursor
        end
    catch
        error:{dbapi_operational_error, Reason} ->
            raise_sqlite_exception(<<"OperationalError">>, Reason);
        error:{dbapi_programming_error, Reason} ->
            raise_sqlite_exception(<<"ProgrammingError">>, Reason);
        error:{dbapi_error, Reason} ->
            raise_sqlite_exception(<<"Error">>, Reason)
    end;
sqlite_cursor_execute(_Cursor, _Pid, _RowsRef, Args) ->
    erlang:error({arity_error, {sqlite_cursor_execute, length(Args)}}).

raise_sqlite_exception(Type, Reason) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(Type), Reason)).

cursor_fetchall(RowsRef) ->
    Rows = pyrlang_heap:list_items(RowsRef),
    ok = pyrlang_heap:set_data(RowsRef, []),
    pyrlang_heap:list(Rows).

sqlite_cursor_fetchone(RowsRef) ->
    case pyrlang_heap:list_items(RowsRef) of
        [] ->
            none;
        [Row | Rest] ->
            ok = pyrlang_heap:set_data(RowsRef, Rest),
            Row
    end.

sqlite_cursor_method_fetchmany([Cursor]) ->
    sqlite_cursor_fetchmany(
        sqlite_cursor_rows_ref(Cursor), pyrlang_object:get_attr(Cursor, <<"arraysize">>)
    );
sqlite_cursor_method_fetchmany([Cursor, Size]) ->
    sqlite_cursor_fetchmany(sqlite_cursor_rows_ref(Cursor), Size);
sqlite_cursor_method_fetchmany(Args) ->
    erlang:error({arity_error, {sqlite_cursor_fetchmany, length(Args)}}).

sqlite_cursor_fetchmany(RowsRef, Size0) ->
    Size =
        case operator_integer_value(Size0) of
            {ok, Value} -> max(0, Value);
            error -> erlang:error({type_error, {fetchmany_size, Size0}})
        end,
    Rows = pyrlang_heap:list_items(RowsRef),
    {Batch, Rest} =
        case Size >= length(Rows) of
            true -> {Rows, []};
            false -> lists:split(Size, Rows)
        end,
    ok = pyrlang_heap:set_data(RowsRef, Rest),
    pyrlang_heap:list(Batch).

sqlite_params({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> pyrlang_heap:list_items(Ref);
        Type -> erlang:error({type_error, {sqlite_params, Type}})
    end;
sqlite_params(Tuple) when is_tuple(Tuple) ->
    tuple_to_list(Tuple);
sqlite_params(List) when is_list(List) ->
    List.

sqlite_is_query(Sql) ->
    Trimmed = string:trim(binary_to_list(Sql)),
    Lower = string:lowercase(Trimmed),
    lists:prefix("select", Lower) orelse
        lists:prefix("pragma", Lower) orelse
        lists:prefix("with", Lower) orelse
        string:str(Lower, " returning ") > 0.

logging_env() ->
    Handler = logging_class(<<"Handler">>),
    StreamHandler = logging_class(<<"StreamHandler">>),
    FileHandler = logging_class(<<"FileHandler">>),
    Filter = logging_class(<<"Filter">>),
    Formatter = logging_class(<<"Formatter">>),
    Logger = logging_class(<<"Logger">>),
    PlaceHolder = logging_class(<<"PlaceHolder">>),
    NullHandler = logging_class(<<"NullHandler">>),
    Root = logging_logger_instance(Logger, <<"root">>),
    #{
        <<"__name__">> => <<"logging">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => pyrlang_heap:list([]),
        <<"CRITICAL">> => 50,
        <<"FATAL">> => 50,
        <<"ERROR">> => 40,
        <<"WARNING">> => 30,
        <<"WARN">> => 30,
        <<"INFO">> => 20,
        <<"DEBUG">> => 10,
        <<"NOTSET">> => 0,
        <<"Handler">> => Handler,
        <<"StreamHandler">> => StreamHandler,
        <<"FileHandler">> => FileHandler,
        <<"NullHandler">> => NullHandler,
        <<"Filter">> => Filter,
        <<"Formatter">> => Formatter,
        <<"Logger">> => Logger,
        <<"PlaceHolder">> => PlaceHolder,
        <<"root">> => Root,
        <<"_handlers">> => pyrlang_heap:dict([]),
        <<"_handlerList">> => pyrlang_heap:list([]),
        <<"_lock">> => none,
        <<"raiseExceptions">> => true,
        <<"lastResort">> => none,
        <<"_checkLevel">> => {py_native_varargs, fun logging_check_level/1},
        <<"getLogger">> => {py_native_varargs, fun logging_get_logger/1},
        <<"basicConfig">> => {py_native_varargs, fun logging_config_noop/1},
        <<"shutdown">> => {py_native_varargs, fun logging_config_noop/1},
        <<"captureWarnings">> => {py_native_varargs, fun logging_config_noop/1},
        <<"getLevelName">> => {py_native_varargs, fun logging_get_level_name/1},
        <<"addLevelName">> => {py_native_varargs, fun(_Args) -> none end}
    }.

logging_handlers_env() ->
    Handler = logging_class(<<"Handler">>),
    FileHandler = logging_class(<<"FileHandler">>),
    #{
        <<"__name__">> => <<"logging.handlers">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"logging">>,
        <<"__path__">> => none,
        <<"DEFAULT_TCP_LOGGING_PORT">> => 9020,
        <<"DEFAULT_UDP_LOGGING_PORT">> => 9021,
        <<"DEFAULT_HTTP_LOGGING_PORT">> => 9022,
        <<"DEFAULT_SOAP_LOGGING_PORT">> => 9023,
        <<"SYSLOG_UDP_PORT">> => 514,
        <<"SYSLOG_TCP_PORT">> => 514,
        <<"BaseRotatingHandler">> => logging_cached_class(<<"BaseRotatingHandler">>, fun() ->
            logging_handler_subclass(<<"BaseRotatingHandler">>, FileHandler)
        end),
        <<"RotatingFileHandler">> => logging_cached_class(<<"RotatingFileHandler">>, fun() ->
            logging_handler_subclass(<<"RotatingFileHandler">>, FileHandler)
        end),
        <<"TimedRotatingFileHandler">> => logging_cached_class(
            <<"TimedRotatingFileHandler">>, fun() ->
                logging_handler_subclass(<<"TimedRotatingFileHandler">>, FileHandler)
            end
        ),
        <<"WatchedFileHandler">> => logging_cached_class(<<"WatchedFileHandler">>, fun() ->
            logging_handler_subclass(<<"WatchedFileHandler">>, FileHandler)
        end),
        <<"SocketHandler">> => logging_cached_class(<<"SocketHandler">>, fun() ->
            logging_handler_subclass(<<"SocketHandler">>, Handler)
        end),
        <<"DatagramHandler">> => logging_cached_class(<<"DatagramHandler">>, fun() ->
            logging_handler_subclass(<<"DatagramHandler">>, Handler)
        end),
        <<"SysLogHandler">> => logging_cached_class(<<"SysLogHandler">>, fun() ->
            logging_handler_subclass(<<"SysLogHandler">>, Handler)
        end),
        <<"SMTPHandler">> => logging_cached_class(<<"SMTPHandler">>, fun() ->
            logging_handler_subclass(<<"SMTPHandler">>, Handler)
        end),
        <<"NTEventLogHandler">> => logging_cached_class(<<"NTEventLogHandler">>, fun() ->
            logging_handler_subclass(<<"NTEventLogHandler">>, Handler)
        end),
        <<"HTTPHandler">> => logging_cached_class(<<"HTTPHandler">>, fun() ->
            logging_handler_subclass(<<"HTTPHandler">>, Handler)
        end),
        <<"BufferingHandler">> => logging_cached_class(<<"BufferingHandler">>, fun() ->
            logging_handler_subclass(<<"BufferingHandler">>, Handler)
        end),
        <<"MemoryHandler">> => logging_cached_class(<<"MemoryHandler">>, fun() ->
            logging_handler_subclass(<<"MemoryHandler">>, Handler)
        end),
        <<"QueueHandler">> => logging_cached_class(<<"QueueHandler">>, fun() ->
            logging_handler_subclass(<<"QueueHandler">>, Handler)
        end),
        <<"QueueListener">> => logging_cached_class(<<"QueueListener">>, fun() ->
            logging_plain_class(<<"QueueListener">>, #{
                <<"__init__">> => {py_native_call, fun logging_object_init/2}
            })
        end)
    }.

logging_class(Name) ->
    logging_cached_class(Name, fun() -> create_logging_class(Name) end).

logging_cached_class(Name, Builder) ->
    Key = {pyrlang_logging_class, Name},
    case erlang:get(Key) of
        undefined ->
            Class = Builder(),
            erlang:put(Key, Class),
            Class;
        Class ->
            try pyrlang_heap:type(Class) of
                class ->
                    Class;
                _Other ->
                    NewClass = Builder(),
                    erlang:put(Key, NewClass),
                    NewClass
            catch
                _:_ ->
                    NewClass = Builder(),
                    erlang:put(Key, NewClass),
                    NewClass
            end
    end.

create_logging_class(<<"Handler">>) ->
    logging_plain_class(<<"Handler">>, #{
        <<"__init__">> => {py_native_call, fun logging_handler_init/2},
        <<"setLevel">> => {py_native_varargs, fun logging_handler_set_level/1},
        <<"setFormatter">> => {py_native_varargs, fun logging_handler_set_formatter/1},
        <<"addFilter">> => {py_native_varargs, fun logging_handler_add_filter/1},
        <<"removeFilter">> => {py_native_varargs, fun logging_handler_remove_filter/1},
        <<"filter">> => {py_native_varargs, fun logging_handler_filter/1},
        <<"format">> => {py_native_varargs, fun logging_handler_format/1},
        <<"handle">> => {py_native_varargs, fun logging_handler_handle/1},
        <<"emit">> => {py_native_varargs, fun logging_config_noop/1},
        <<"handleError">> => {py_native_varargs, fun logging_config_noop/1},
        <<"close">> => {py_native_varargs, fun logging_config_noop/1},
        <<"createLock">> => {py_native_varargs, fun logging_config_noop/1},
        <<"acquire">> => {py_native_varargs, fun logging_config_noop/1},
        <<"release">> => {py_native_varargs, fun logging_config_noop/1}
    });
create_logging_class(<<"StreamHandler">>) ->
    logging_subclass(<<"StreamHandler">>, logging_class(<<"Handler">>), #{
        <<"__init__">> => {py_native_call, fun logging_stream_handler_init/2},
        <<"emit">> => {py_native_varargs, fun logging_config_noop/1},
        <<"flush">> => {py_native_varargs, fun logging_config_noop/1}
    });
create_logging_class(<<"FileHandler">>) ->
    logging_subclass(<<"FileHandler">>, logging_class(<<"StreamHandler">>), #{
        <<"__init__">> => {py_native_call, fun logging_file_handler_init/2},
        <<"_open">> => {py_native_varargs, fun logging_file_handler_open/1}
    });
create_logging_class(<<"NullHandler">>) ->
    logging_subclass(<<"NullHandler">>, logging_class(<<"Handler">>), #{
        <<"__init__">> => {py_native_call, fun logging_handler_init/2},
        <<"handle">> => {py_native_varargs, fun logging_config_noop/1},
        <<"emit">> => {py_native_varargs, fun logging_config_noop/1},
        <<"createLock">> => {py_native_varargs, fun logging_config_noop/1}
    });
create_logging_class(<<"Filter">>) ->
    logging_plain_class(<<"Filter">>, #{
        <<"__init__">> => {py_native_call, fun logging_filter_init/2},
        <<"filter">> => {py_native_varargs, fun logging_filter_record/1}
    });
create_logging_class(<<"Formatter">>) ->
    logging_plain_class(<<"Formatter">>, #{
        <<"__init__">> => {py_native_call, fun logging_formatter_init/2},
        <<"format">> => {py_native_varargs, fun logging_formatter_format/1},
        <<"formatTime">> => {py_native_varargs, fun logging_formatter_time/1}
    });
create_logging_class(<<"Logger">>) ->
    logging_plain_class(<<"Logger">>, #{
        <<"__init__">> => {py_native_call, fun logging_logger_init/2},
        <<"debug">> => {py_native_call, fun logging_noop/2},
        <<"info">> => {py_native_call, fun logging_noop/2},
        <<"warning">> => {py_native_call, fun logging_noop/2},
        <<"warn">> => {py_native_call, fun logging_noop/2},
        <<"error">> => {py_native_call, fun logging_noop/2},
        <<"exception">> => {py_native_call, fun logging_noop/2},
        <<"critical">> => {py_native_call, fun logging_noop/2},
        <<"log">> => {py_native_call, fun logging_noop/2},
        <<"isEnabledFor">> => {py_native_varargs, fun logging_is_enabled_for/1},
        <<"setLevel">> => {py_native_varargs, fun logging_logger_set_level/1},
        <<"addHandler">> => {py_native_varargs, fun logging_logger_add_handler/1},
        <<"removeHandler">> => {py_native_varargs, fun logging_logger_remove_handler/1},
        <<"hasHandlers">> => {py_native_varargs, fun logging_logger_has_handlers/1},
        <<"getEffectiveLevel">> => {py_native_varargs, fun logging_logger_effective_level/1}
    });
create_logging_class(<<"PlaceHolder">>) ->
    logging_plain_class(<<"PlaceHolder">>, #{
        <<"__init__">> => {py_native_call, fun logging_object_init/2}
    }).

logging_plain_class(Name, Attrs) ->
    pyrlang_object:new_class(Name, [maps:get(<<"object">>, pyrlang_builtins:env())], Attrs#{
        <<"__module__">> => <<"logging">>
    }).

logging_subclass(Name, Base, Attrs) ->
    pyrlang_object:new_class(Name, [Base], Attrs#{<<"__module__">> => <<"logging">>}).

logging_handler_subclass(Name, Base) ->
    pyrlang_object:new_class(Name, [Base], #{
        <<"__module__">> => <<"logging.handlers">>,
        <<"__init__">> => {py_native_call, fun logging_handler_init/2}
    }).

logging_get_logger([]) ->
    logging_get_logger([<<"root">>]);
logging_get_logger([Name]) ->
    logging_logger_instance(logging_class(<<"Logger">>), normalize_name(Name)).

logging_logger_instance(Class, Name) ->
    native_instance(Class, <<"Logger">>, #{
        <<"name">> => Name,
        <<"level">> => 0,
        <<"disabled">> => false,
        <<"propagate">> => true,
        <<"handlers">> => pyrlang_heap:list([]),
        <<"manager">> => native_instance(<<"Manager">>, #{<<"loggerDict">> => pyrlang_heap:dict([])})
    }).

logging_config_noop(_Args) ->
    none.

logging_config_listen(_Args) ->
    native_instance(<<"Thread">>, #{
        <<"start">> => fun() -> none end,
        <<"join">> => fun() -> none end,
        <<"stop">> => fun() -> none end
    }).

logging_object_init([_Self | _Args], _KwArgs) ->
    none;
logging_object_init([], _KwArgs) ->
    none.

logging_handler_init([Self | Args], _KwArgs) ->
    Level = logging_arg(Args, 0, 0),
    ok = logging_set_attrs(Self, #{
        <<"level">> => logging_check_level_value(Level),
        <<"formatter">> => none,
        <<"filters">> => pyrlang_heap:list([]),
        <<"lock">> => none,
        <<"name">> => none
    }),
    none;
logging_handler_init([], _KwArgs) ->
    none.

logging_stream_handler_init([Self | Args], _KwArgs) ->
    _ = logging_handler_init([Self], #{}),
    ok = pyrlang_object:set_attr(Self, <<"stream">>, logging_arg(Args, 0, none)),
    none;
logging_stream_handler_init([], _KwArgs) ->
    none.

logging_file_handler_init([Self | Args], KwArgs) ->
    Filename = logging_arg(Args, 0, <<>>),
    Mode = maps:get(<<"mode">>, KwArgs, logging_arg(Args, 1, <<"a">>)),
    Encoding = maps:get(<<"encoding">>, KwArgs, logging_arg(Args, 2, none)),
    Delay = maps:get(<<"delay">>, KwArgs, logging_arg(Args, 3, false)),
    _ = logging_stream_handler_init([Self, none], #{}),
    ok = logging_set_attrs(Self, #{
        <<"baseFilename">> => normalize_name(Filename),
        <<"mode">> => normalize_name(Mode),
        <<"encoding">> => Encoding,
        <<"delay">> => Delay,
        <<"stream">> => none
    }),
    none;
logging_file_handler_init([], _KwArgs) ->
    none.

logging_file_handler_open([_Self]) ->
    none;
logging_file_handler_open(_Args) ->
    none.

logging_filter_init([Self | Args], _KwArgs) ->
    ok = pyrlang_object:set_attr(Self, <<"name">>, logging_arg(Args, 0, <<>>)),
    none;
logging_filter_init([], _KwArgs) ->
    none.

logging_filter_record([_Self, _Record]) ->
    true;
logging_filter_record(_Args) ->
    true.

logging_formatter_init([Self | Args], KwArgs) ->
    Format = maps:get(<<"fmt">>, KwArgs, logging_arg(Args, 0, <<"%(message)s">>)),
    DateFmt = maps:get(<<"datefmt">>, KwArgs, logging_arg(Args, 1, none)),
    Style = maps:get(<<"style">>, KwArgs, logging_arg(Args, 2, <<"%">>)),
    ok = logging_set_attrs(Self, #{
        <<"_fmt">> => normalize_name(Format),
        <<"datefmt">> => DateFmt,
        <<"style">> => Style,
        <<"_style">> => none
    }),
    none;
logging_formatter_init([], _KwArgs) ->
    none.

logging_formatter_format([_Self, Record]) ->
    logging_record_message(Record);
logging_formatter_format([_Self]) ->
    <<>>;
logging_formatter_format(_Args) ->
    <<>>.

logging_formatter_time([_Self, _Record]) ->
    <<>>;
logging_formatter_time([_Self, _Record, _DateFmt]) ->
    <<>>;
logging_formatter_time(_Args) ->
    <<>>.

logging_handler_set_level([Self, Level]) ->
    ok = pyrlang_object:set_attr(Self, <<"level">>, logging_check_level_value(Level)),
    none;
logging_handler_set_level(_Args) ->
    none.

logging_handler_set_formatter([Self, Formatter]) ->
    ok = pyrlang_object:set_attr(Self, <<"formatter">>, Formatter),
    none;
logging_handler_set_formatter(_Args) ->
    none.

logging_handler_add_filter([Self, Filter]) ->
    Filters = logging_list_attr(Self, <<"filters">>),
    ok = pyrlang_object:set_attr(Self, <<"filters">>, pyrlang_heap:list(Filters ++ [Filter])),
    none;
logging_handler_add_filter(_Args) ->
    none.

logging_handler_remove_filter([Self, Filter]) ->
    Filters = [Item || Item <- logging_list_attr(Self, <<"filters">>), Item =/= Filter],
    ok = pyrlang_object:set_attr(Self, <<"filters">>, pyrlang_heap:list(Filters)),
    none;
logging_handler_remove_filter(_Args) ->
    none.

logging_handler_filter([_Self, _Record]) ->
    true;
logging_handler_filter(_Args) ->
    true.

logging_handler_format([Self, Record]) ->
    try pyrlang_object:get_attr(Self, <<"formatter">>) of
        none -> logging_record_message(Record);
        Formatter -> pyrlang_eval:call(pyrlang_object:get_attr(Formatter, <<"format">>), [Record])
    catch
        _:_ -> logging_record_message(Record)
    end;
logging_handler_format(_Args) ->
    <<>>.

logging_handler_handle([Self, Record]) ->
    try
        pyrlang_eval:call(pyrlang_object:get_attr(Self, <<"emit">>), [Record])
    catch
        _:_ -> none
    end,
    none;
logging_handler_handle(_Args) ->
    none.

logging_logger_init([Self | Args], _KwArgs) ->
    Name = logging_arg(Args, 0, <<"root">>),
    ok = logging_set_attrs(Self, #{
        <<"name">> => normalize_name(Name),
        <<"level">> => 0,
        <<"disabled">> => false,
        <<"propagate">> => true,
        <<"handlers">> => pyrlang_heap:list([]),
        <<"manager">> => native_instance(<<"Manager">>, #{<<"loggerDict">> => pyrlang_heap:dict([])})
    }),
    none;
logging_logger_init([], _KwArgs) ->
    none.

logging_noop(_Args, _KwArgs) ->
    none.

logging_is_enabled_for([_Level]) ->
    false;
logging_is_enabled_for([_Self, _Level]) ->
    false;
logging_is_enabled_for(Args) ->
    erlang:error({arity_error, {isEnabledFor, length(Args)}}).

logging_logger_set_level([Self, Level]) ->
    ok = pyrlang_object:set_attr(Self, <<"level">>, logging_check_level_value(Level)),
    none;
logging_logger_set_level(_Args) ->
    none.

logging_logger_add_handler([Self, Handler]) ->
    Handlers = logging_list_attr(Self, <<"handlers">>),
    ok = pyrlang_object:set_attr(Self, <<"handlers">>, pyrlang_heap:list(Handlers ++ [Handler])),
    none;
logging_logger_add_handler(_Args) ->
    none.

logging_logger_remove_handler([Self, Handler]) ->
    Handlers = [Item || Item <- logging_list_attr(Self, <<"handlers">>), Item =/= Handler],
    ok = pyrlang_object:set_attr(Self, <<"handlers">>, pyrlang_heap:list(Handlers)),
    none;
logging_logger_remove_handler(_Args) ->
    none.

logging_logger_has_handlers([Self]) ->
    logging_list_attr(Self, <<"handlers">>) =/= [];
logging_logger_has_handlers(_Args) ->
    false.

logging_logger_effective_level([Self]) ->
    try
        pyrlang_object:get_attr(Self, <<"level">>)
    catch
        _:_ -> 0
    end;
logging_logger_effective_level(_Args) ->
    0.

logging_check_level([Level]) ->
    logging_check_level_value(Level);
logging_check_level(Args) ->
    erlang:error({arity_error, {'_checkLevel', length(Args)}}).

logging_check_level_value(Level) when is_integer(Level) ->
    Level;
logging_check_level_value(Level) ->
    case normalize_name(Level) of
        <<"CRITICAL">> -> 50;
        <<"FATAL">> -> 50;
        <<"ERROR">> -> 40;
        <<"WARNING">> -> 30;
        <<"WARN">> -> 30;
        <<"INFO">> -> 20;
        <<"DEBUG">> -> 10;
        <<"NOTSET">> -> 0;
        _Other -> Level
    end.

logging_get_level_name([Level]) when is_integer(Level) ->
    case Level of
        50 -> <<"CRITICAL">>;
        40 -> <<"ERROR">>;
        30 -> <<"WARNING">>;
        20 -> <<"INFO">>;
        10 -> <<"DEBUG">>;
        0 -> <<"NOTSET">>;
        _ -> iolist_to_binary(io_lib:format("Level ~B", [Level]))
    end;
logging_get_level_name([Name]) ->
    normalize_name(Name);
logging_get_level_name(Args) ->
    erlang:error({arity_error, {getLevelName, length(Args)}}).

logging_set_attrs(Self, Attrs) ->
    maps:foreach(fun(Name, Value) -> ok = pyrlang_object:set_attr(Self, Name, Value) end, Attrs).

logging_arg(Args, Index, Default) ->
    case length(Args) > Index of
        true -> lists:nth(Index + 1, Args);
        false -> Default
    end.

logging_list_attr(Self, Name) ->
    try pyrlang_object:get_attr(Self, Name) of
        {py_ref, _} = Ref ->
            case pyrlang_heap:type(Ref) of
                list -> pyrlang_heap:list_items(Ref);
                _Other -> []
            end;
        _Other ->
            []
    catch
        _:_ -> []
    end.

logging_record_message(Record) ->
    try
        pyrlang_eval:call(pyrlang_object:get_attr(Record, <<"getMessage">>), [])
    catch
        _:_ ->
            try
                normalize_name(pyrlang_object:get_attr(Record, <<"msg">>))
            catch
                _:_ -> <<>>
            end
    end.

pathlib_purepath_class() ->
    pathlib_cached_class(pyrlang_pathlib_purepath_class, <<"PurePath">>, [os_pathlike_class()]).

pathlib_path_class() ->
    pathlib_cached_class(pyrlang_pathlib_path_class, <<"Path">>, [pathlib_purepath_class()]).

os_pathlike_class() ->
    pathlib_cached_class(pyrlang_os_pathlike_class, <<"PathLike">>, [
        maps:get(<<"object">>, pyrlang_builtins:env())
    ]).

pathlib_cached_class(Key, Name, Bases) ->
    case erlang:get(Key) of
        undefined ->
            Class = pyrlang_object:new_class(Name, Bases, #{}),
            ok = pyrlang_object:set_class_attr(
                Class,
                <<"__pyrlang_builtin_constructor__">>,
                {py_native_call, fun(Args, KwArgs) -> pathlib_path_new(Class, Args, KwArgs) end}
            ),
            erlang:put(Key, Class),
            Class;
        Class ->
            try pyrlang_heap:type(Class) of
                class ->
                    Class;
                _Other ->
                    erlang:erase(Key),
                    pathlib_cached_class(Key, Name, Bases)
            catch
                _:_ ->
                    erlang:erase(Key),
                    pathlib_cached_class(Key, Name, Bases)
            end
    end.

pathlib_path_new(Class, Args, KwArgs) when map_size(KwArgs) =:= 0 ->
    Path =
        case Args of
            [] ->
                <<".">>;
            _ ->
                unicode:characters_to_binary(
                    filename:join([binary_to_list(normalize_name(Part)) || Part <- Args])
                )
        end,
    pathlib_path_instance(Class, Path);
pathlib_path_new(_Class, Args, _KwArgs) ->
    erlang:error({arity_error, {pathlib_path, length(Args)}}).

pathlib_path_instance(Class, Path) ->
    pathlib_path_instance(Class, Path, 32).

pathlib_path_instance(Class, Path, ParentDepth) ->
    PathList = binary_to_list(Path),
    Parent =
        case ParentDepth > 0 of
            true ->
                pathlib_path_instance(
                    Class, unicode:characters_to_binary(filename:dirname(PathList)), ParentDepth - 1
                );
            false ->
                none
        end,
    ClassName = pyrlang_object:class_name(Class),
    native_instance(Class, ClassName, #{
        <<"path">> => Path,
        <<"name">> => unicode:characters_to_binary(filename:basename(PathList)),
        <<"parent">> => Parent,
        <<"read_text">> => fun() ->
            {ok, Content} = file:read_file(PathList),
            Content
        end,
        <<"write_text">> => fun(Content) ->
            ok = file:write_file(PathList, normalize_name(Content)),
            byte_size(normalize_name(Content))
        end,
        <<"open">> =>
            {py_native_call, fun(Args, KwArgs) -> pathlib_path_open(Path, Args, KwArgs) end},
        <<"exists">> => fun() ->
            filelib:is_file(PathList) orelse filelib:is_dir(PathList)
        end,
        <<"is_dir">> => fun() -> filelib:is_dir(PathList) end,
        <<"is_file">> => fun() -> filelib:is_file(PathList) end,
        <<"joinpath">> =>
            {py_native_varargs, fun(Parts) -> pathlib_path_join(Class, Path, Parts) end},
        <<"resolve">> =>
            {py_native_call, fun(Args, KwArgs) ->
                pathlib_path_resolve(Class, Path, Args, KwArgs)
            end},
        <<"absolute">> => fun() ->
            pathlib_path_instance(Class, unicode:characters_to_binary(filename:absname(PathList)))
        end,
        <<"as_posix">> => fun() -> Path end,
        <<"is_absolute">> => fun() -> filename:pathtype(PathList) =:= absolute end,
        <<"__fspath__">> => fun() -> Path end,
        <<"__str__">> => fun() -> Path end,
        <<"__repr__">> => fun() -> <<ClassName/binary, "('", Path/binary, "')">> end,
        <<"__truediv__">> => fun(Other) ->
            Joined = filename:join(PathList, binary_to_list(normalize_name(Other))),
            pathlib_path_instance(Class, unicode:characters_to_binary(Joined))
        end
    }).

pathlib_path_open(Path, Args, KwArgs) ->
    Allowed = [<<"mode">>, <<"buffering">>, <<"encoding">>, <<"errors">>, <<"newline">>],
    Unknown = maps:keys(maps:without(Allowed, KwArgs)),
    case Unknown of
        [] -> ok;
        _ -> erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end,
    Mode =
        case Args of
            [] ->
                maps:get(<<"mode">>, KwArgs, <<"r">>);
            [ModeArg] ->
                case maps:is_key(<<"mode">>, KwArgs) of
                    true -> erlang:error({type_error, {multiple_values_for_argument, <<"mode">>}});
                    false -> ModeArg
                end;
            _ ->
                erlang:error({arity_error, {path_open, length(Args), maps:size(KwArgs)}})
        end,
    pyrlang_builtins:open([Path, Mode]).

pathlib_path_join(Class, Path, Parts) ->
    PathList = binary_to_list(Path),
    Joined = filename:join([PathList | [binary_to_list(normalize_name(Part)) || Part <- Parts]]),
    pathlib_path_instance(Class, unicode:characters_to_binary(Joined)).

pathlib_path_resolve(Class, Path, Args, KwArgs) ->
    Allowed = [<<"strict">>],
    Unknown = maps:keys(maps:without(Allowed, KwArgs)),
    case {Args, Unknown} of
        {[], []} ->
            pathlib_path_instance(
                Class, unicode:characters_to_binary(filename:absname(binary_to_list(Path)))
            );
        {[_Strict], []} ->
            pathlib_path_instance(
                Class, unicode:characters_to_binary(filename:absname(binary_to_list(Path)))
            );
        _ ->
            erlang:error({arity_error, {path_resolve, length(Args), maps:size(KwArgs)}})
    end.

http_status_class() ->
    Members = [
        {Name, http_status_instance(Name, Code, Phrase)}
     || {Name, Code, Phrase} <- http_status_specs()
    ],
    ByCode = [
        {pyrlang_object:get_attr(Status, <<"value">>), Status}
     || {_Name, Status} <- Members
    ],
    Attrs = maps:from_list(Members),
    native_instance(<<"HTTPStatus">>, Attrs#{
        <<"__members__">> => pyrlang_heap:dict(Members),
        <<"__call__">> => {py_native_varargs, fun(Args) -> http_status_lookup(ByCode, Args) end}
    }).

http_status_instance(Name, Code, Phrase) ->
    native_instance(<<"HTTPStatus">>, #{
        <<"_name_">> => Name,
        <<"name">> => Name,
        <<"_value_">> => Code,
        <<"value">> => Code,
        <<"phrase">> => Phrase,
        <<"description">> => <<>>,
        <<"__int__">> => fun() -> Code end,
        <<"__index__">> => fun() -> Code end,
        <<"__repr__">> => fun() -> <<"HTTPStatus.", Name/binary>> end,
        <<"__str__">> => fun() -> integer_to_binary(Code) end,
        <<"__eq__">> => fun(Other) -> http_status_value(Other) =:= Code end,
        <<"__ne__">> => fun(Other) -> http_status_value(Other) =/= Code end,
        <<"__lt__">> => fun(Other) -> Code < http_status_value(Other) end,
        <<"__le__">> => fun(Other) -> Code =< http_status_value(Other) end,
        <<"__gt__">> => fun(Other) -> Code > http_status_value(Other) end,
        <<"__ge__">> => fun(Other) -> Code >= http_status_value(Other) end
    }).

http_status_lookup(ByCode, [Code]) ->
    case lists:keyfind(http_status_value(Code), 1, ByCode) of
        {_, Status} ->
            Status;
        false ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Code)
            )
    end;
http_status_lookup(_ByCode, Args) ->
    erlang:error({arity_error, {'HTTPStatus', length(Args)}}).

http_status_value(Value) when is_integer(Value) ->
    Value;
http_status_value({py_ref, _} = Ref) ->
    try pyrlang_object:get_attr(Ref, <<"value">>) of
        Code when is_integer(Code) -> Code;
        _Other -> erlang:error({type_error, {http_status, Ref}})
    catch
        error:{attribute_error, _Name} -> erlang:error({type_error, {http_status, Ref}})
    end;
http_status_value(Value) ->
    erlang:error({type_error, {http_status, Value}}).

http_status_specs() ->
    [
        {<<"CONTINUE">>, 100, <<"Continue">>},
        {<<"SWITCHING_PROTOCOLS">>, 101, <<"Switching Protocols">>},
        {<<"PROCESSING">>, 102, <<"Processing">>},
        {<<"EARLY_HINTS">>, 103, <<"Early Hints">>},
        {<<"OK">>, 200, <<"OK">>},
        {<<"CREATED">>, 201, <<"Created">>},
        {<<"ACCEPTED">>, 202, <<"Accepted">>},
        {<<"NON_AUTHORITATIVE_INFORMATION">>, 203, <<"Non-Authoritative Information">>},
        {<<"NO_CONTENT">>, 204, <<"No Content">>},
        {<<"RESET_CONTENT">>, 205, <<"Reset Content">>},
        {<<"PARTIAL_CONTENT">>, 206, <<"Partial Content">>},
        {<<"MULTI_STATUS">>, 207, <<"Multi-Status">>},
        {<<"ALREADY_REPORTED">>, 208, <<"Already Reported">>},
        {<<"IM_USED">>, 226, <<"IM Used">>},
        {<<"MULTIPLE_CHOICES">>, 300, <<"Multiple Choices">>},
        {<<"MOVED_PERMANENTLY">>, 301, <<"Moved Permanently">>},
        {<<"FOUND">>, 302, <<"Found">>},
        {<<"SEE_OTHER">>, 303, <<"See Other">>},
        {<<"NOT_MODIFIED">>, 304, <<"Not Modified">>},
        {<<"USE_PROXY">>, 305, <<"Use Proxy">>},
        {<<"TEMPORARY_REDIRECT">>, 307, <<"Temporary Redirect">>},
        {<<"PERMANENT_REDIRECT">>, 308, <<"Permanent Redirect">>},
        {<<"BAD_REQUEST">>, 400, <<"Bad Request">>},
        {<<"UNAUTHORIZED">>, 401, <<"Unauthorized">>},
        {<<"PAYMENT_REQUIRED">>, 402, <<"Payment Required">>},
        {<<"FORBIDDEN">>, 403, <<"Forbidden">>},
        {<<"NOT_FOUND">>, 404, <<"Not Found">>},
        {<<"METHOD_NOT_ALLOWED">>, 405, <<"Method Not Allowed">>},
        {<<"NOT_ACCEPTABLE">>, 406, <<"Not Acceptable">>},
        {<<"PROXY_AUTHENTICATION_REQUIRED">>, 407, <<"Proxy Authentication Required">>},
        {<<"REQUEST_TIMEOUT">>, 408, <<"Request Timeout">>},
        {<<"CONFLICT">>, 409, <<"Conflict">>},
        {<<"GONE">>, 410, <<"Gone">>},
        {<<"LENGTH_REQUIRED">>, 411, <<"Length Required">>},
        {<<"PRECONDITION_FAILED">>, 412, <<"Precondition Failed">>},
        {<<"CONTENT_TOO_LARGE">>, 413, <<"Content Too Large">>},
        {<<"REQUEST_ENTITY_TOO_LARGE">>, 413, <<"Content Too Large">>},
        {<<"URI_TOO_LONG">>, 414, <<"URI Too Long">>},
        {<<"REQUEST_URI_TOO_LONG">>, 414, <<"URI Too Long">>},
        {<<"UNSUPPORTED_MEDIA_TYPE">>, 415, <<"Unsupported Media Type">>},
        {<<"RANGE_NOT_SATISFIABLE">>, 416, <<"Range Not Satisfiable">>},
        {<<"REQUESTED_RANGE_NOT_SATISFIABLE">>, 416, <<"Range Not Satisfiable">>},
        {<<"EXPECTATION_FAILED">>, 417, <<"Expectation Failed">>},
        {<<"IM_A_TEAPOT">>, 418, <<"I'm a Teapot">>},
        {<<"MISDIRECTED_REQUEST">>, 421, <<"Misdirected Request">>},
        {<<"UNPROCESSABLE_CONTENT">>, 422, <<"Unprocessable Content">>},
        {<<"UNPROCESSABLE_ENTITY">>, 422, <<"Unprocessable Content">>},
        {<<"LOCKED">>, 423, <<"Locked">>},
        {<<"FAILED_DEPENDENCY">>, 424, <<"Failed Dependency">>},
        {<<"TOO_EARLY">>, 425, <<"Too Early">>},
        {<<"UPGRADE_REQUIRED">>, 426, <<"Upgrade Required">>},
        {<<"PRECONDITION_REQUIRED">>, 428, <<"Precondition Required">>},
        {<<"TOO_MANY_REQUESTS">>, 429, <<"Too Many Requests">>},
        {<<"REQUEST_HEADER_FIELDS_TOO_LARGE">>, 431, <<"Request Header Fields Too Large">>},
        {<<"UNAVAILABLE_FOR_LEGAL_REASONS">>, 451, <<"Unavailable For Legal Reasons">>},
        {<<"INTERNAL_SERVER_ERROR">>, 500, <<"Internal Server Error">>},
        {<<"NOT_IMPLEMENTED">>, 501, <<"Not Implemented">>},
        {<<"BAD_GATEWAY">>, 502, <<"Bad Gateway">>},
        {<<"SERVICE_UNAVAILABLE">>, 503, <<"Service Unavailable">>},
        {<<"GATEWAY_TIMEOUT">>, 504, <<"Gateway Timeout">>},
        {<<"HTTP_VERSION_NOT_SUPPORTED">>, 505, <<"HTTP Version Not Supported">>},
        {<<"VARIANT_ALSO_NEGOTIATES">>, 506, <<"Variant Also Negotiates">>},
        {<<"INSUFFICIENT_STORAGE">>, 507, <<"Insufficient Storage">>},
        {<<"LOOP_DETECTED">>, 508, <<"Loop Detected">>},
        {<<"NOT_EXTENDED">>, 510, <<"Not Extended">>},
        {<<"NETWORK_AUTHENTICATION_REQUIRED">>, 511, <<"Network Authentication Required">>}
    ].

http_method_class() ->
    Methods = [
        {<<"CONNECT">>, <<"CONNECT">>},
        {<<"DELETE">>, <<"DELETE">>},
        {<<"GET">>, <<"GET">>},
        {<<"HEAD">>, <<"HEAD">>},
        {<<"OPTIONS">>, <<"OPTIONS">>},
        {<<"PATCH">>, <<"PATCH">>},
        {<<"POST">>, <<"POST">>},
        {<<"PUT">>, <<"PUT">>},
        {<<"TRACE">>, <<"TRACE">>}
    ],
    native_instance(
        <<"HTTPMethod">>,
        maps:from_list(Methods ++ [{<<"__members__">>, pyrlang_heap:dict(Methods)}])
    ).

simple_cookie_new([], KwArgs) when map_size(KwArgs) =:= 0 ->
    simple_cookie_instance();
simple_cookie_new(Args, _KwArgs) ->
    erlang:error({arity_error, {simple_cookie, length(Args)}}).

cookie_unquote(Value0) ->
    Value = normalize_name(Value0),
    case Value of
        <<"\"", Rest/binary>> when byte_size(Rest) > 0 ->
            Last = byte_size(Rest) - 1,
            case binary:at(Rest, Last) of
                $" ->
                    Inner = binary:part(Rest, 0, Last),
                    cookie_unquote_escapes(Inner, <<>>);
                _ ->
                    Value
            end;
        _ ->
            Value
    end.

cookie_unquote_escapes(<<>>, Acc) ->
    Acc;
cookie_unquote_escapes(<<"\\", Char, Rest/binary>>, Acc) ->
    cookie_unquote_escapes(Rest, <<Acc/binary, Char>>);
cookie_unquote_escapes(<<Char, Rest/binary>>, Acc) ->
    cookie_unquote_escapes(Rest, <<Acc/binary, Char>>).

simple_cookie_instance() ->
    Store = pyrlang_heap:dict([]),
    native_instance(<<"SimpleCookie">>, #{
        <<"data">> => Store,
        <<"load">> => fun(Header) ->
            load_cookie_header(Store, normalize_name(Header)),
            none
        end,
        <<"get">> => fun(Name) ->
            cookie_get(Store, normalize_name(Name))
        end,
        <<"set">> => fun(Name, Value) ->
            ok = cookie_store_put(Store, normalize_name(Name), normalize_name(Value)),
            none
        end,
        <<"__setitem__">> => fun(Name, Value) ->
            ok = cookie_store_put(Store, normalize_name(Name), normalize_name(Value)),
            none
        end,
        <<"__getitem__">> => fun(Name) ->
            cookie_get_morsel(Store, normalize_name(Name))
        end,
        <<"values">> => fun() ->
            pyrlang_heap:list([
                simple_cookie_morsel(Store, Name, Entry)
             || {Name, Entry} <- pyrlang_heap:dict_items(Store)
            ])
        end,
        <<"output">> => fun() ->
            CookiePairs = [
                morsel_output_binary(
                    <<>>, Name, cookie_entry_value(Entry), cookie_entry_attrs(Entry)
                )
             || {Name, Entry} <- pyrlang_heap:dict_items(Store)
            ],
            join_binary(CookiePairs, <<"; ">>)
        end
    }).

simple_cookie_morsel(Store, Name, Entry) ->
    Value = cookie_entry_value(Entry),
    native_instance(<<"Morsel">>, #{
        <<"key">> => Name,
        <<"value">> => Value,
        <<"__setitem__">> => fun(Attr, AttrValue) ->
            ok = cookie_set_attr(Store, Name, normalize_name(Attr), AttrValue),
            none
        end,
        <<"__getitem__">> => fun(Attr) ->
            Current = cookie_lookup_entry(Store, Name),
            maps:get(normalize_name(Attr), cookie_entry_attrs(Current), <<>>)
        end,
        <<"output">> =>
            {py_native_call, fun(Args, KwArgs) ->
                Current = cookie_lookup_entry(Store, Name),
                morsel_output(
                    Name, cookie_entry_value(Current), cookie_entry_attrs(Current), Args, KwArgs
                )
            end}
    }).

morsel_output(Name, Value, Attrs, Args, KwArgs0) ->
    KwArgs = maps:without([<<"header">>], KwArgs0),
    case {Args, map_size(KwArgs)} of
        {[], 0} ->
            Header = maps:get(<<"header">>, KwArgs0, <<"Set-Cookie:">>),
            morsel_output_binary(Header, Name, Value, Attrs);
        {[Header], 0} ->
            case maps:is_key(<<"header">>, KwArgs0) of
                true -> erlang:error({type_error, {multiple_values_for_argument, <<"header">>}});
                false -> morsel_output_binary(normalize_name(Header), Name, Value, Attrs)
            end;
        {_, 0} ->
            erlang:error({arity_error, {morsel_output, length(Args)}});
        {_, _} ->
            erlang:error({type_error, {unexpected_keyword_argument, maps:keys(KwArgs)}})
    end.

morsel_output_binary(<<>>, Name, Value) ->
    <<Name/binary, "=", Value/binary>>;
morsel_output_binary(Header, Name, Value) ->
    <<Header/binary, " ", Name/binary, "=", Value/binary>>.

morsel_output_binary(Header, Name, Value, Attrs) ->
    Base = morsel_output_binary(Header, Name, Value),
    AttrParts = cookie_output_attrs(Attrs),
    case AttrParts of
        [] -> Base;
        _ -> <<Base/binary, "; ", (join_binary(AttrParts, <<"; ">>))/binary>>
    end.

cookie_output_attrs(Attrs) ->
    Order = [
        <<"expires">>,
        <<"max-age">>,
        <<"path">>,
        <<"domain">>,
        <<"secure">>,
        <<"httponly">>,
        <<"samesite">>
    ],
    [
        cookie_output_attr(Name, maps:get(Name, Attrs))
     || Name <- Order,
        maps:is_key(Name, Attrs),
        cookie_output_attr(Name, maps:get(Name, Attrs)) =/= skip
    ].

cookie_output_attr(_Name, <<>>) ->
    skip;
cookie_output_attr(<<"max-age">>, Value) ->
    <<"Max-Age=", (cookie_attr_binary(Value))/binary>>;
cookie_output_attr(<<"path">>, Value) ->
    <<"Path=", (cookie_attr_binary(Value))/binary>>;
cookie_output_attr(<<"domain">>, Value) ->
    <<"Domain=", (cookie_attr_binary(Value))/binary>>;
cookie_output_attr(<<"secure">>, true) ->
    <<"Secure">>;
cookie_output_attr(<<"secure">>, Value) ->
    case truthy_cookie_attr(Value) of
        true -> <<"Secure">>;
        false -> skip
    end;
cookie_output_attr(<<"httponly">>, true) ->
    <<"HttpOnly">>;
cookie_output_attr(<<"httponly">>, Value) ->
    case truthy_cookie_attr(Value) of
        true -> <<"HttpOnly">>;
        false -> skip
    end;
cookie_output_attr(<<"samesite">>, Value) ->
    <<"SameSite=", (cookie_attr_binary(Value))/binary>>;
cookie_output_attr(<<"expires">>, Value) ->
    <<"expires=", (cookie_attr_binary(Value))/binary>>;
cookie_output_attr(Name, Value) ->
    <<Name/binary, "=", (cookie_attr_binary(Value))/binary>>.

cookie_attr_binary(Value) when is_integer(Value) ->
    integer_to_binary(Value);
cookie_attr_binary(Value) when is_float(Value) ->
    float_to_binary(Value, [compact]);
cookie_attr_binary(Value) ->
    normalize_name(Value).

truthy_cookie_attr(false) -> false;
truthy_cookie_attr(none) -> false;
truthy_cookie_attr(<<>>) -> false;
truthy_cookie_attr(_) -> true.

load_cookie_header(Store, Header) ->
    Parts = binary:split(Header, <<";">>, [global]),
    lists:foreach(fun(Part) -> load_cookie_part(Store, trim_binary(Part)) end, Parts).

load_cookie_part(_Store, <<>>) ->
    ok;
load_cookie_part(Store, Part) ->
    case binary:split(Part, <<"=">>) of
        [Name, Value] when Name =/= <<>> ->
            ok = cookie_store_put(Store, trim_binary(Name), trim_binary(Value));
        _ ->
            ok
    end.

cookie_get(Store, Name) ->
    try pyrlang_heap:dict_get(Store, Name) of
        Entry -> cookie_entry_value(Entry)
    catch
        error:{badkey, _} -> none
    end.

cookie_get_morsel(Store, Name) ->
    try pyrlang_heap:dict_get(Store, Name) of
        Entry -> simple_cookie_morsel(Store, Name, Entry)
    catch
        error:{badkey, _} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Name)
            )
    end.

cookie_store_put(Store, Name, Value) ->
    Attrs =
        try
            cookie_entry_attrs(pyrlang_heap:dict_get(Store, Name))
        catch
            _:_ -> #{}
        end,
    pyrlang_heap:dict_put(Store, Name, {cookie, Value, Attrs}).

cookie_set_attr(Store, Name, Attr, AttrValue) ->
    Entry = cookie_lookup_entry(Store, Name),
    pyrlang_heap:dict_put(
        Store,
        Name,
        {cookie, cookie_entry_value(Entry), (cookie_entry_attrs(Entry))#{Attr => AttrValue}}
    ).

cookie_lookup_entry(Store, Name) ->
    try
        pyrlang_heap:dict_get(Store, Name)
    catch
        error:{badkey, _} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Name)
            )
    end.

cookie_entry_value({cookie, Value, _Attrs}) ->
    Value;
cookie_entry_value(Value) ->
    Value.

cookie_entry_attrs({cookie, _Value, Attrs}) when is_map(Attrs) ->
    Attrs;
cookie_entry_attrs(_Value) ->
    #{}.

url_quote([Value], KwArgs) ->
    Safe = maps:get(<<"safe">>, KwArgs, <<"/">>),
    quote_binary(normalize_name(Value), normalize_name(Safe), false);
url_quote([Value, Safe], KwArgs) when map_size(KwArgs) =:= 0 ->
    quote_binary(normalize_name(Value), normalize_name(Safe), false);
url_quote(Args, _KwArgs) ->
    erlang:error({arity_error, {url_quote, length(Args)}}).

url_quote_plus([Value], KwArgs) ->
    Safe = maps:get(<<"safe">>, KwArgs, <<"">>),
    quote_binary(normalize_name(Value), normalize_name(Safe), true);
url_quote_plus([Value, Safe], KwArgs) when map_size(KwArgs) =:= 0 ->
    quote_binary(normalize_name(Value), normalize_name(Safe), true);
url_quote_plus(Args, _KwArgs) ->
    erlang:error({arity_error, {url_quote_plus, length(Args)}}).

url_unquote([Value], KwArgs) when map_size(KwArgs) =:= 0 ->
    unquote_binary(normalize_name(Value), false);
url_unquote(Args, _KwArgs) ->
    erlang:error({arity_error, {url_unquote, length(Args)}}).

url_unquote_plus([Value], KwArgs) when map_size(KwArgs) =:= 0 ->
    unquote_binary(normalize_name(Value), true);
url_unquote_plus(Args, _KwArgs) ->
    erlang:error({arity_error, {url_unquote_plus, length(Args)}}).

url_urlencode(Args, KwArgs) ->
    {Query, Doseq} = urlencode_args(Args, KwArgs),
    Pairs = query_pairs(Query, py_truthy(Doseq)),
    join_binary(
        [
            <<
                (quote_binary(url_value_to_binary(Key), <<"">>, true))/binary,
                "=",
                (quote_binary(url_value_to_binary(Value), <<"">>, true))/binary
            >>
         || {Key, Value} <- Pairs
        ],
        <<"&">>
    ).

urlencode_args([Query], KwArgs) ->
    check_urlencode_kwargs(KwArgs),
    {Query, maps:get(<<"doseq">>, KwArgs, false)};
urlencode_args([Query, Doseq], KwArgs) ->
    check_urlencode_kwargs(KwArgs),
    case maps:is_key(<<"doseq">>, KwArgs) of
        true -> erlang:error({type_error, {multiple_values_for_argument, <<"doseq">>}});
        false -> {Query, Doseq}
    end;
urlencode_args(Args, _KwArgs) ->
    erlang:error({arity_error, {urlencode, length(Args)}}).

check_urlencode_kwargs(KwArgs) ->
    Unknown = maps:keys(maps:without([<<"doseq">>], KwArgs)),
    case Unknown of
        [] -> ok;
        _ -> erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end.

url_parse_qs([Query], KwArgs) when map_size(KwArgs) =:= 0 ->
    Pairs = parse_query_pairs(normalize_name(Query)),
    Grouped = lists:foldl(
        fun({Key, Value}, Acc) ->
            maps:update_with(Key, fun(Values) -> [Value | Values] end, [Value], Acc)
        end,
        #{},
        Pairs
    ),
    pyrlang_heap:dict(
        maps:map(fun(_Key, Values) -> pyrlang_heap:list(lists:reverse(Values)) end, Grouped)
    );
url_parse_qs(Args, _KwArgs) ->
    erlang:error({arity_error, {parse_qs, length(Args)}}).

url_parse_qsl([Query], KwArgs) ->
    _KeepBlankValues = maps:get(<<"keep_blank_values">>, KwArgs, false),
    pyrlang_heap:list(parse_query_pairs(normalize_name(Query)));
url_parse_qsl(Args, _KwArgs) ->
    erlang:error({arity_error, {parse_qsl, length(Args)}}).

url_urlsplit([Url], KwArgs) when map_size(KwArgs) =:= 0 ->
    url_split_result(Url, <<>>);
url_urlsplit([Url, Scheme], KwArgs) when map_size(KwArgs) =:= 0 ->
    url_split_result(Url, normalize_name(Scheme));
url_urlsplit([Url, Scheme, _AllowFragments], KwArgs) when map_size(KwArgs) =:= 0 ->
    url_split_result(Url, normalize_name(Scheme));
url_urlsplit(Args, _KwArgs) ->
    erlang:error({arity_error, {urlsplit, length(Args)}}).

url_urlparse([Url], KwArgs) when map_size(KwArgs) =:= 0 ->
    url_parse_result(Url, <<>>);
url_urlparse([Url, Scheme], KwArgs) when map_size(KwArgs) =:= 0 ->
    url_parse_result(Url, normalize_name(Scheme));
url_urlparse([Url, Scheme, _AllowFragments], KwArgs) when map_size(KwArgs) =:= 0 ->
    url_parse_result(Url, normalize_name(Scheme));
url_urlparse(Args, _KwArgs) ->
    erlang:error({arity_error, {urlparse, length(Args)}}).

url_split_result(Url, DefaultScheme) ->
    Parsed = uri_string:parse(normalize_name(Url)),
    Scheme = maps:get(scheme, Parsed, DefaultScheme),
    Path = maps:get(path, Parsed, <<"">>),
    Query = maps:get(query, Parsed, <<"">>),
    Fragment = maps:get(fragment, Parsed, <<"">>),
    Host = maps:get(host, Parsed, <<"">>),
    Netloc =
        case maps:find(port, Parsed) of
            {ok, Port} -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>;
            error -> Host
        end,
    url_result_instance(
        <<"SplitResult">>,
        [
            {<<"scheme">>, Scheme},
            {<<"netloc">>, Netloc},
            {<<"path">>, Path},
            {<<"query">>, Query},
            {<<"fragment">>, Fragment}
        ],
        normalize_name(Url)
    ).

url_parse_result(Url, DefaultScheme) ->
    Parsed = uri_string:parse(normalize_name(Url)),
    Scheme = maps:get(scheme, Parsed, DefaultScheme),
    Path = maps:get(path, Parsed, <<"">>),
    Query = maps:get(query, Parsed, <<"">>),
    Fragment = maps:get(fragment, Parsed, <<"">>),
    Host = maps:get(host, Parsed, <<"">>),
    Netloc =
        case maps:find(port, Parsed) of
            {ok, Port} -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>;
            error -> Host
        end,
    url_result_instance(
        <<"ParseResult">>,
        [
            {<<"scheme">>, Scheme},
            {<<"netloc">>, Netloc},
            {<<"path">>, Path},
            {<<"params">>, <<>>},
            {<<"query">>, Query},
            {<<"fragment">>, Fragment}
        ],
        normalize_name(Url)
    ).

url_result_instance(Name, Fields, OriginalUrl) ->
    Values = [Value || {_Field, Value} <- Fields],
    native_instance(Name, (maps:from_list(Fields))#{
        <<"geturl">> => fun() -> OriginalUrl end,
        <<"__len__">> => fun() -> length(Values) end,
        <<"__iter__">> => fun() -> pyrlang_iter:iter(pyrlang_heap:list(Values)) end,
        <<"__getitem__">> => fun(Index) ->
            lists:nth(url_result_index(Index, length(Values)) + 1, Values)
        end
    }).

url_result_index(Index, Length) when is_integer(Index), Index < 0 ->
    url_result_index(Index + Length, Length);
url_result_index(Index, Length) when is_integer(Index), Index >= 0, Index < Length ->
    Index;
url_result_index(Index, _Length) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"IndexError">>), Index)
    ).

url_urljoin([Base, Url], KwArgs) when map_size(KwArgs) =:= 0 ->
    url_join_binary(Base, Url);
url_urljoin([Base, Url, _AllowFragments], KwArgs) when map_size(KwArgs) =:= 0 ->
    url_join_binary(Base, Url);
url_urljoin(Args, _KwArgs) ->
    erlang:error({arity_error, {urljoin, length(Args)}}).

url_urldefrag([Url], KwArgs) when map_size(KwArgs) =:= 0 ->
    Text = normalize_name(Url),
    {Clean, Fragment} =
        case binary:match(Text, <<"#">>) of
            {Pos, 1} ->
                {
                    binary:part(Text, 0, Pos),
                    binary:part(Text, Pos + 1, byte_size(Text) - Pos - 1)
                };
            nomatch ->
                {Text, <<>>}
        end,
    url_result_instance(
        <<"DefragResult">>,
        [
            {<<"url">>, Clean},
            {<<"fragment">>, Fragment}
        ],
        Clean
    );
url_urldefrag(Args, _KwArgs) ->
    erlang:error({arity_error, {urldefrag, length(Args)}}).

url_join_binary(Base, Url) ->
    BaseBin = normalize_name(Base),
    UrlBin = normalize_name(Url),
    case uri_string:parse(UrlBin) of
        #{scheme := _Scheme} ->
            UrlBin;
        _ ->
            case uri_string:resolve(binary_to_list(UrlBin), binary_to_list(BaseBin)) of
                Resolved when is_list(Resolved) ->
                    unicode:characters_to_binary(Resolved);
                {error, _Reason, _Input} ->
                    url_join_relative_path(BaseBin, UrlBin)
            end
    end.

url_join_relative_path(_Base, <<"/", _/binary>> = Url) ->
    Url;
url_join_relative_path(<<>>, Url) ->
    Url;
url_join_relative_path(Base, Url) ->
    Separator =
        case binary:at(Base, byte_size(Base) - 1) of
            $/ -> <<>>;
            _ -> <<"/">>
        end,
    <<Base/binary, Separator/binary, Url/binary>>.

url_urlunparse([Parts], KwArgs) when map_size(KwArgs) =:= 0 ->
    [Scheme, Netloc, Path, Params, Query, Fragment] = url_parts(Parts, 6),
    PathAndParams =
        case Params of
            <<>> -> Path;
            _ -> <<Path/binary, ";", Params/binary>>
        end,
    Base =
        case {Scheme, Netloc} of
            {<<>>, <<>>} -> PathAndParams;
            {<<>>, _} -> <<"//", Netloc/binary, PathAndParams/binary>>;
            {_, <<>>} -> <<Scheme/binary, ":", PathAndParams/binary>>;
            {_, _} -> <<Scheme/binary, "://", Netloc/binary, PathAndParams/binary>>
        end,
    WithQuery =
        case Query of
            <<>> -> Base;
            _ -> <<Base/binary, "?", Query/binary>>
        end,
    case Fragment of
        <<>> -> WithQuery;
        _ -> <<WithQuery/binary, "#", Fragment/binary>>
    end;
url_urlunparse(Args, _KwArgs) ->
    erlang:error({arity_error, {urlunparse, length(Args)}}).

url_urlunsplit([Parts], KwArgs) when map_size(KwArgs) =:= 0 ->
    [Scheme, Netloc, Path, Query, Fragment] = url_parts(Parts, 5),
    url_urlunparse([{Scheme, Netloc, Path, <<>>, Query, Fragment}], #{});
url_urlunsplit(Args, _KwArgs) ->
    erlang:error({arity_error, {urlunsplit, length(Args)}}).

url_parts(Parts, Count) ->
    Values = [normalize_name(Value) || Value <- pyrlang_iter:values(Parts)],
    case length(Values) of
        Count ->
            Values;
        _ ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>), <<"wrong number of fields">>
                )
            )
    end.

url_unwrap(Url) ->
    Text0 = normalize_name(Url),
    Text1 =
        case Text0 of
            <<"<URL:", Rest/binary>> -> binary:part(Rest, 0, byte_size(Rest) - 1);
            <<"<", Rest/binary>> -> binary:part(Rest, 0, byte_size(Rest) - 1);
            _ -> Text0
        end,
    Text1.

url_splittype(Url) ->
    Text = normalize_name(Url),
    case binary:match(Text, <<":">>) of
        {Pos, 1} ->
            {binary:part(Text, 0, Pos), binary:part(Text, Pos + 1, byte_size(Text) - Pos - 1)};
        nomatch ->
            {none, Text}
    end.

url_splithost(Url) ->
    Text = normalize_name(Url),
    case Text of
        <<"//", Rest/binary>> ->
            case binary:match(Rest, <<"/">>) of
                {Pos, 1} ->
                    {binary:part(Rest, 0, Pos), binary:part(Rest, Pos, byte_size(Rest) - Pos)};
                nomatch ->
                    {Rest, <<>>}
            end;
        _ ->
            {none, Text}
    end.

url_splitport(Host) ->
    split_once(normalize_name(Host), <<":">>, none, right).

url_splituser(Host) ->
    Text = normalize_name(Host),
    case split_once(Text, <<"@">>, none, right) of
        {Text, none} -> {none, Text};
        Pair -> Pair
    end.

url_splitpasswd(User) ->
    split_once(normalize_name(User), <<":">>, none, left).

url_splitattr(Path) ->
    Text = normalize_name(Path),
    case binary:split(Text, <<";">>, [global]) of
        [Only] -> {Only, pyrlang_heap:list([])};
        [Head | Attrs] -> {Head, pyrlang_heap:list(Attrs)}
    end.

url_splitquery(Url) ->
    split_once(normalize_name(Url), <<"?">>, none, left).

url_splitvalue(Value) ->
    split_once(normalize_name(Value), <<"=">>, none, left).

url_splittag(Url) ->
    split_once(normalize_name(Url), <<"#">>, none, left).

split_once(Text, Sep, Default, Direction) ->
    Match =
        case Direction of
            left ->
                binary:match(Text, Sep);
            right ->
                Matches = binary:matches(Text, Sep),
                case Matches of
                    [] -> nomatch;
                    _ -> lists:last(Matches)
                end
        end,
    case Match of
        {Pos, Size} ->
            {
                binary:part(Text, 0, Pos),
                binary:part(Text, Pos + Size, byte_size(Text) - Pos - Size)
            };
        nomatch ->
            {Text, Default}
    end.

url_unquote_to_bytes([Value], KwArgs) when map_size(KwArgs) =:= 0 ->
    unquote_binary(normalize_name(Value), false);
url_unquote_to_bytes(Args, _KwArgs) ->
    erlang:error({arity_error, {unquote_to_bytes, length(Args)}}).

unicode_category(Value) ->
    case normalize_name(Value) of
        <<Char/utf8, _Rest/binary>> when Char >= $A, Char =< $Z -> <<"Lu">>;
        <<Char/utf8, _Rest/binary>> when Char >= $a, Char =< $z -> <<"Ll">>;
        <<Char/utf8, _Rest/binary>> when Char >= $0, Char =< $9 -> <<"Nd">>;
        <<Char/utf8, _Rest/binary>> when Char < 32 -> <<"Cc">>;
        <<>> -> <<"Cn">>;
        _ -> <<"Lo">>
    end.

quote_binary(Binary, Safe, SpaceAsPlus) ->
    iolist_to_binary([quote_byte(Byte, Safe, SpaceAsPlus) || <<Byte:8>> <= Binary]).

quote_byte($\s, _Safe, true) ->
    <<"+">>;
quote_byte(Byte, Safe, _SpaceAsPlus) ->
    case is_unreserved(Byte) orelse binary:match(Safe, <<Byte>>) =/= nomatch of
        true -> <<Byte>>;
        false -> <<"%", (hex_upper(Byte))/binary>>
    end.

is_unreserved(Byte) when Byte >= $A, Byte =< $Z -> true;
is_unreserved(Byte) when Byte >= $a, Byte =< $z -> true;
is_unreserved(Byte) when Byte >= $0, Byte =< $9 -> true;
is_unreserved($-) -> true;
is_unreserved($.) -> true;
is_unreserved($_) -> true;
is_unreserved($~) -> true;
is_unreserved(_Byte) -> false.

hex_upper(Byte) ->
    iolist_to_binary(io_lib:format("~2.16.0B", [Byte])).

unquote_binary(Binary, PlusAsSpace) ->
    unquote_binary(Binary, PlusAsSpace, []).

unquote_binary(<<>>, _PlusAsSpace, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
unquote_binary(<<$%, Hi, Lo, Rest/binary>>, PlusAsSpace, Acc) ->
    case {hex_digit(Hi), hex_digit(Lo)} of
        {{ok, HiValue}, {ok, LoValue}} ->
            unquote_binary(Rest, PlusAsSpace, [<<(HiValue * 16 + LoValue)>> | Acc]);
        _ ->
            unquote_binary(Rest, PlusAsSpace, [<<$%, Hi, Lo>> | Acc])
    end;
unquote_binary(<<$+, Rest/binary>>, true, Acc) ->
    unquote_binary(Rest, true, [<<" ">> | Acc]);
unquote_binary(<<Byte, Rest/binary>>, PlusAsSpace, Acc) ->
    unquote_binary(Rest, PlusAsSpace, [<<Byte>> | Acc]).

hex_digit(Byte) when Byte >= $0, Byte =< $9 -> {ok, Byte - $0};
hex_digit(Byte) when Byte >= $A, Byte =< $F -> {ok, Byte - $A + 10};
hex_digit(Byte) when Byte >= $a, Byte =< $f -> {ok, Byte - $a + 10};
hex_digit(_Byte) -> error.

query_pairs(Query, false) ->
    query_pairs(Query);
query_pairs(Query, true) ->
    lists:append([urlencode_expand_pair(Key, Value) || {Key, Value} <- query_pairs(Query)]).

query_pairs({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> pyrlang_heap:dict_items(Ref);
        list -> [query_pair(Item) || Item <- pyrlang_heap:list_items(Ref)];
        Type -> erlang:error({type_error, {urlencode_query, Type}})
    end;
query_pairs(Map) when is_map(Map) ->
    maps:to_list(Map);
query_pairs(List) when is_list(List) ->
    [query_pair(Item) || Item <- List].

query_pair({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list ->
            case pyrlang_heap:list_items(Ref) of
                [Key, Value] -> {Key, Value};
                Items -> erlang:error({bad_urlencode_pair, Items})
            end;
        Type ->
            erlang:error({bad_urlencode_pair_type, Type})
    end;
query_pair({Key, Value}) ->
    {Key, Value};
query_pair([Key, Value]) ->
    {Key, Value}.

urlencode_expand_pair(Key, Value) ->
    case urlencode_doseq_values(Value) of
        {ok, Values} -> [{Key, Item} || Item <- Values];
        error -> [{Key, Value}]
    end.

urlencode_doseq_values({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> {ok, pyrlang_heap:list_items(Ref)};
        _ -> error
    end;
urlencode_doseq_values(Tuple) when is_tuple(Tuple) ->
    {ok, tuple_to_list(Tuple)};
urlencode_doseq_values(_Value) ->
    error.

url_value_to_binary(Value) when is_binary(Value) ->
    Value;
url_value_to_binary(Value) when is_integer(Value) ->
    integer_to_binary(Value);
url_value_to_binary(Value) when is_float(Value) ->
    unicode:characters_to_binary(float_to_list(Value));
url_value_to_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
url_value_to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
url_value_to_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

parse_query_pairs(<<>>) ->
    [];
parse_query_pairs(Query) ->
    [parse_query_pair(Part) || Part <- binary:split(Query, <<"&">>, [global]), Part =/= <<>>].

parse_query_pair(Part) ->
    case binary:split(Part, <<"=">>) of
        [Key, Value] -> {unquote_binary(Key, true), unquote_binary(Value, true)};
        [Key] -> {unquote_binary(Key, true), <<"">>}
    end.

trim_binary(Binary) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Binary))).

email_formatdate([]) ->
    email_format_datetime(calendar:universal_time());
email_formatdate([Timestamp]) when is_integer(Timestamp) ->
    email_format_datetime(posix_seconds_to_datetime(Timestamp));
email_formatdate([Timestamp]) when is_float(Timestamp) ->
    email_format_datetime(posix_seconds_to_datetime(trunc(Timestamp)));
email_formatdate(Args) ->
    erlang:error({arity_error, {email_formatdate, length(Args)}}).

email_formatdate_call(Args, KwArgs) ->
    ensure_known_kwargs(KwArgs, [<<"timeval">>, <<"localtime">>, <<"usegmt">>], <<"formatdate">>),
    TimeArgs =
        case Args of
            [] ->
                case maps:find(<<"timeval">>, KwArgs) of
                    {ok, none} -> [];
                    {ok, TimeVal} -> [TimeVal];
                    error -> []
                end;
            [TimeVal] ->
                [TimeVal];
            [TimeVal, _LocalTime] ->
                [TimeVal];
            [TimeVal, _LocalTime, _UseGmt] ->
                [TimeVal];
            _ ->
                erlang:error({arity_error, {email_formatdate, length(Args)}})
        end,
    email_formatdate(TimeArgs).

email_format_datetime([Value]) ->
    email_format_datetime_object(Value);
email_format_datetime([Value, _UseGmt]) ->
    email_format_datetime_object(Value);
email_format_datetime(Args) when is_list(Args) ->
    erlang:error({arity_error, {email_format_datetime, length(Args)}});
email_format_datetime({Date, Time}) ->
    email_format_datetime_tuple({Date, Time}).

email_format_datetime_call(Args, KwArgs) ->
    ensure_known_kwargs(KwArgs, [<<"usegmt">>], <<"format_datetime">>),
    email_format_datetime(Args).

ensure_known_kwargs(KwArgs, Known, Function) ->
    case maps:keys(maps:without(Known, KwArgs)) of
        [] ->
            ok;
        [Unexpected | _] ->
            erlang:error({type_error, {unexpected_keyword_argument, Function, Unexpected}})
    end.

posix_seconds_to_datetime(Seconds) ->
    Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    calendar:gregorian_seconds_to_datetime(Epoch + Seconds).

email_format_datetime_object(Value) ->
    Year = date_attr_or_default(Value, <<"year">>, 1970),
    Month = date_attr_or_default(Value, <<"month">>, 1),
    Day = date_attr_or_default(Value, <<"day">>, 1),
    Hour = date_attr_or_default(Value, <<"hour">>, 0),
    Minute = date_attr_or_default(Value, <<"minute">>, 0),
    Second = date_attr_or_default(Value, <<"second">>, 0),
    email_format_datetime_tuple({{Year, Month, Day}, {Hour, Minute, Second}}).

date_attr_or_default(Value, Name, Default) ->
    try
        pyrlang_object:get_attr(Value, Name)
    catch
        _:_ -> Default
    end.

email_format_datetime_tuple({Date = {Year, Month, Day}, {Hour, Minute, Second}}) ->
    Weekday = lists:nth(calendar:day_of_the_week(Date), [
        <<"Mon">>, <<"Tue">>, <<"Wed">>, <<"Thu">>, <<"Fri">>, <<"Sat">>, <<"Sun">>
    ]),
    MonthName = lists:nth(Month, [
        <<"Jan">>,
        <<"Feb">>,
        <<"Mar">>,
        <<"Apr">>,
        <<"May">>,
        <<"Jun">>,
        <<"Jul">>,
        <<"Aug">>,
        <<"Sep">>,
        <<"Oct">>,
        <<"Nov">>,
        <<"Dec">>
    ]),
    iolist_to_binary(
        io_lib:format(
            "~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
            [Weekday, Day, MonthName, Year, Hour, Minute, Second]
        )
    ).

email_message_from_bytes([Bytes | _Args], _KwArgs) ->
    email_message_instance(Bytes);
email_message_from_bytes(_Args, _KwArgs) ->
    email_message_instance(<<>>).

email_message_from_string([Text | _Args], _KwArgs) ->
    email_message_instance(Text);
email_message_from_string(_Args, _KwArgs) ->
    email_message_instance(<<>>).

email_message_from_file([File | _Args], _KwArgs) ->
    Content =
        try
            pyrlang_eval:call(pyrlang_object:get_attr(File, <<"read">>), [])
        catch
            _:_ -> <<>>
        end,
    email_message_instance(Content);
email_message_from_file(_Args, _KwArgs) ->
    email_message_instance(<<>>).

email_message_instance(Content0) ->
    Content = normalize_name(Content0),
    native_instance(<<"Message">>, #{
        <<"get_content_type">> => fun() -> <<"message/rfc822">> end,
        <<"get_payload">> => fun() -> Content end,
        <<"as_bytes">> => fun() -> Content end,
        <<"as_string">> => fun() -> Content end
    }).

email_formataddr([Pair]) ->
    {Name0, Address0} = email_pair(Pair),
    Name = normalize_name(Name0),
    Address = normalize_name(Address0),
    case Name of
        <<>> -> Address;
        _ -> <<Name/binary, " <", Address/binary, ">">>
    end;
email_formataddr([Pair, _Charset]) ->
    email_formataddr([Pair]);
email_formataddr(Args) ->
    erlang:error({arity_error, {email_formataddr, length(Args)}}).

email_getaddresses([Values]) ->
    pyrlang_heap:list(
        lists:append([email_addresses_from_value(Value) || Value <- pyrlang_iter:values(Values)])
    );
email_getaddresses(Args) ->
    erlang:error({arity_error, {email_getaddresses, length(Args)}}).

email_parseaddr([Value]) ->
    email_parse_address(normalize_name(Value));
email_parseaddr([Value, _Strict]) ->
    email_parseaddr([Value]);
email_parseaddr(Args) ->
    erlang:error({arity_error, {email_parseaddr, length(Args)}}).

email_make_msgid(Args, KwArgs) ->
    Domain = normalize_name(maps:get(<<"domain">>, KwArgs, <<"localhost">>)),
    IdString =
        case Args of
            [Value | _] -> normalize_name(Value);
            [] -> normalize_name(maps:get(<<"idstring">>, KwArgs, <<"pyrlang">>))
        end,
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    <<"<", Unique/binary, ".", IdString/binary, "@", Domain/binary, ">">>.

email_collapse_rfc2231_value([Value]) ->
    Value;
email_collapse_rfc2231_value([Value, _Errors]) ->
    Value;
email_collapse_rfc2231_value([Value, _Errors, _FallbackCharset]) ->
    Value;
email_collapse_rfc2231_value(Args) ->
    erlang:error({arity_error, {email_collapse_rfc2231_value, length(Args)}}).

email_pair({py_ref, _} = Ref) ->
    case pyrlang_iter:values(Ref) of
        [Name, Address | _] -> {Name, Address};
        [Address] -> {<<>>, Address};
        [] -> {<<>>, <<>>}
    end;
email_pair({Name, Address}) ->
    {Name, Address};
email_pair({Name, Address, _Rest}) ->
    {Name, Address};
email_pair(Address) ->
    {<<>>, Address}.

email_addresses_from_value(Value) ->
    [
        email_parse_address(Part)
     || Part <- binary:split(normalize_name(Value), <<",">>, [global]), trim_binary(Part) =/= <<>>
    ].

email_parse_address(Value0) ->
    Value = trim_binary(Value0),
    case binary:split(Value, <<"<">>) of
        [Name0, Rest0] ->
            Address = trim_binary(binary:replace(Rest0, <<">">>, <<>>, [global])),
            {trim_binary(Name0), Address};
        _ ->
            {<<>>, Value}
    end.

find_module(Name) ->
    RelBase = binary_to_list(binary:replace(Name, <<".">>, <<"/">>, [global])),
    find_module_in_paths(RelBase, path()).

find_module_in_paths(_RelBase, []) ->
    error;
find_module_in_paths(RelBase, [Base | Rest]) ->
    case find_module_in_path(RelBase, Base) of
        {ok, _Path, _IsPackage} = Found -> Found;
        error -> find_module_in_paths(RelBase, Rest)
    end.

find_module_in_path(RelBase, Base) ->
    Candidates =
        [{filename:join(Base, RelBase ++ Ext), false} || Ext <- [".py", ".pyr"]] ++
            [{filename:join([Base, RelBase, "__init__" ++ Ext]), true} || Ext <- [".py", ".pyr"]],
    case [{Path, IsPackage} || {Path, IsPackage} <- Candidates, filelib:is_regular(Path)] of
        [{Path, IsPackage} | _] -> {ok, Path, IsPackage};
        [] -> error
    end.

main_target_name(Name) ->
    case find_module(Name) of
        {ok, _Path, true} -> <<Name/binary, ".__main__">>;
        {ok, _Path, false} -> Name;
        error -> Name
    end.

attach_to_parent(Name, ModuleRef) ->
    Parts = binary:split(Name, <<".">>, [global]),
    case Parts of
        [_Single] ->
            ok;
        _ ->
            ParentName = join_binary(lists:droplast(Parts), <<".">>),
            ChildName = lists:last(Parts),
            Parent = load(ParentName),
            set_attr(Parent, ChildName, ModuleRef)
    end.

package_name(Name, true) ->
    Name;
package_name(Name, false) ->
    Parts = binary:split(Name, <<".">>, [global]),
    case lists:droplast(Parts) of
        [] -> <<"">>;
        ParentParts -> join_binary(ParentParts, <<".">>)
    end.

package_path(Path, true) ->
    pyrlang_heap:list([unicode:characters_to_binary(filename:dirname(Path))]);
package_path(_Path, false) ->
    none.

join_binary([], _Sep) ->
    <<"">>;
join_binary([Part], _Sep) ->
    Part;
join_binary([Part | Rest], Sep) ->
    lists:foldl(fun(Item, Acc) -> <<Acc/binary, Sep/binary, Item/binary>> end, Part, Rest).

cache() ->
    case erlang:get(?PY_MODULE_CACHE_KEY) of
        undefined -> #{};
        Cache when is_map(Cache) -> Cache
    end.

put_cache(Name, ModuleRef) ->
    erlang:put(?PY_MODULE_CACHE_KEY, maps:put(Name, ModuleRef, cache())),
    sync_sys_modules(Name, ModuleRef).

remove_cache(Name) ->
    erlang:put(?PY_MODULE_CACHE_KEY, maps:remove(Name, cache())),
    sync_sys_modules_remove(Name).

sys_modules() ->
    case erlang:get(pyrlang_sys_modules_ref) of
        undefined ->
            Modules = pyrlang_heap:dict(maps:to_list(cache())),
            erlang:put(pyrlang_sys_modules_ref, Modules),
            Modules;
        Modules ->
            Modules
    end.

sync_sys_modules(Name, ModuleRef) ->
    case erlang:get(pyrlang_sys_modules_ref) of
        undefined ->
            ok;
        Modules ->
            pyrlang_heap:dict_put(Modules, Name, ModuleRef)
    end.

sync_sys_modules_remove(Name) ->
    case erlang:get(pyrlang_sys_modules_ref) of
        undefined ->
            ok;
        Modules ->
            pyrlang_heap:dict_del(Modules, Name)
    end.

os_environ() ->
    case erlang:get(?PY_OS_ENV_KEY) of
        undefined -> #{};
        Env when is_map(Env) -> Env
    end.

os_getcwd([]) ->
    {ok, Cwd} = file:get_cwd(),
    unicode:characters_to_binary(Cwd);
os_getcwd(Args) ->
    erlang:error({arity_error, {os_getcwd, length(Args)}}).

os_get_exports_list([{py_ref, _} = ModuleRef]) ->
    case pyrlang_heap:type(ModuleRef) of
        module ->
            pyrlang_heap:list([
                Name
             || {Name, _Value} <- maps:to_list(env(ModuleRef)),
                not is_private_export(Name)
            ]);
        Type ->
            erlang:error({type_error, {'_get_exports_list', Type}})
    end;
os_get_exports_list(Args) ->
    erlang:error({arity_error, {'_get_exports_list', length(Args)}}).

is_private_export(<<"_", _/binary>>) ->
    true;
is_private_export(_Name) ->
    false.

os_urandom(Count) when is_integer(Count), Count >= 0 ->
    crypto:strong_rand_bytes(Count);
os_urandom(Count) when is_integer(Count) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"ValueError">>), <<"negative argument not allowed">>
        )
    );
os_urandom(Count) ->
    erlang:error({type_error, {urandom, Count}}).

math_env() ->
    #{
        <<"__name__">> => <<"math">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"e">> => 2.718281828459045,
        <<"pi">> => 3.141592653589793,
        <<"tau">> => 6.283185307179586,
        <<"inf">> => 1.0e308,
        <<"nan">> => 0.0,
        <<"ceil">> => fun math_ceil/1,
        <<"floor">> => fun math_floor/1,
        <<"trunc">> => fun math_trunc/1,
        <<"log">> => {py_native_varargs, fun math_log/1},
        <<"log2">> => fun math_log2/1,
        <<"exp">> => fun math_exp/1,
        <<"sqrt">> => fun math_sqrt/1,
        <<"hypot">> => {py_native_varargs, fun math_hypot/1},
        <<"fsum">> => fun math_fsum/1,
        <<"sumprod">> => fun math_sumprod/2,
        <<"acos">> => fun math_acos/1,
        <<"asin">> => fun math_asin/1,
        <<"atan">> => fun math_atan/1,
        <<"atan2">> => fun math_atan2/2,
        <<"cos">> => fun math_cos/1,
        <<"cosh">> => fun math_cosh/1,
        <<"sin">> => fun math_sin/1,
        <<"tan">> => fun math_tan/1,
        <<"erf">> => fun math_erf/1,
        <<"fabs">> => fun math_fabs/1,
        <<"fmod">> => fun math_fmod/2,
        <<"degrees">> => fun math_degrees/1,
        <<"radians">> => fun math_radians/1,
        <<"gcd">> => {py_native_varargs, fun math_gcd/1},
        <<"isqrt">> => fun math_isqrt/1,
        <<"lgamma">> => fun math_lgamma/1,
        <<"isfinite">> => fun math_isfinite/1,
        <<"isinf">> => fun math_isinf/1,
        <<"isnan">> => fun math_isnan/1
    }.

math_ceil(Value) when is_integer(Value) ->
    Value;
math_ceil(Value) when is_float(Value) ->
    erlang:ceil(Value).

math_floor(Value) when is_integer(Value) ->
    Value;
math_floor(Value) when is_float(Value) ->
    erlang:floor(Value).

math_trunc(Value) when is_integer(Value) ->
    Value;
math_trunc(Value) when is_float(Value) ->
    erlang:trunc(Value).

math_log([Value]) ->
    math:log(Value);
math_log([Value, Base]) ->
    math:log(Value) / math:log(Base);
math_log(Args) ->
    erlang:error({arity_error, {math_log, length(Args)}}).

math_log2(Value) ->
    math:log2(Value).

math_exp(Value) ->
    math:exp(Value).

math_sqrt(Value) ->
    math:sqrt(Value).

math_hypot(Args) ->
    math:sqrt(lists:sum([Value * Value || Value <- Args])).

math_fsum(Iterable) ->
    lists:sum([Value * 1.0 || Value <- pyrlang_iter:values(Iterable)]).

math_sumprod(Left, Right) ->
    lists:sum([A * B || {A, B} <- lists:zip(pyrlang_iter:values(Left), pyrlang_iter:values(Right))]).

math_acos(Value) ->
    math:acos(Value).

math_asin(Value) ->
    math:asin(Value).

math_atan(Value) ->
    math:atan(Value).

math_atan2(Y, X) ->
    math:atan2(Y, X).

math_cos(Value) ->
    math:cos(Value).

math_cosh(Value) ->
    math:cosh(Value).

math_sin(Value) ->
    math:sin(Value).

math_tan(Value) ->
    math:tan(Value).

math_erf(Value) ->
    math:erf(Value).

math_fabs(Value) when is_integer(Value), Value < 0 ->
    -Value * 1.0;
math_fabs(Value) when is_integer(Value) ->
    Value * 1.0;
math_fabs(Value) when is_float(Value) ->
    abs(Value).

math_fmod(Left, Right) ->
    math:fmod(Left, Right).

math_degrees(Value) ->
    Value * 180.0 / 3.141592653589793.

math_radians(Value) ->
    Value * 3.141592653589793 / 180.0.

math_gcd([]) ->
    0;
math_gcd(Args) ->
    lists:foldl(fun(Value, Acc) -> gcd(abs(Value), Acc) end, 0, Args).

gcd(A, 0) ->
    A;
gcd(A, B) ->
    gcd(B, A rem B).

math_isqrt(Value) when is_integer(Value), Value >= 0 ->
    erlang:floor(math:sqrt(Value));
math_isqrt(Value) ->
    erlang:error({value_error, {isqrt, Value}}).

math_lgamma(Value) when Value > 0 ->
    (Value - 0.5) * math:log(Value) - Value + 0.9189385332046727;
math_lgamma(Value) ->
    erlang:error({value_error, {lgamma, Value}}).

math_isfinite(Value) when is_integer(Value) ->
    true;
math_isfinite(Value) when is_float(Value) ->
    Value =:= Value.

math_isinf(Value) when is_integer(Value) ->
    false;
math_isinf(Value) when is_float(Value) ->
    false.

math_isnan(Value) when is_integer(Value) ->
    false;
math_isnan(Value) when is_float(Value) ->
    Value =/= Value.

random_env() ->
    #{
        <<"__name__">> => <<"_random">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"Random">> => random_base_type()
    }.

random_base_type() ->
    Key = pyrlang_random_base_type,
    case erlang:get(Key) of
        undefined ->
            Class = pyrlang_object:new_class(<<"Random">>, [], #{
                <<"seed">> => {py_native_varargs, fun random_seed/1},
                <<"random">> => {py_native_varargs, fun random_random/1},
                <<"getstate">> => {py_native_varargs, fun random_getstate/1},
                <<"setstate">> => {py_native_varargs, fun random_setstate/1},
                <<"getrandbits">> => {py_native_varargs, fun random_getrandbits/1}
            }),
            erlang:put(Key, Class),
            Class;
        Class ->
            Class
    end.

random_seed([_Self]) ->
    none;
random_seed([_Self, _Seed]) ->
    none;
random_seed(Args) ->
    erlang:error({arity_error, {'_random.Random.seed', length(Args)}}).

random_random([_Self]) ->
    Int = binary:decode_unsigned(crypto:strong_rand_bytes(7)) bsr 3,
    Int / 9007199254740992.0;
random_random(Args) ->
    erlang:error({arity_error, {'_random.Random.random', length(Args)}}).

random_getstate([_Self]) ->
    none;
random_getstate(Args) ->
    erlang:error({arity_error, {'_random.Random.getstate', length(Args)}}).

random_setstate([_Self, _State]) ->
    none;
random_setstate(Args) ->
    erlang:error({arity_error, {'_random.Random.setstate', length(Args)}}).

random_getrandbits([_Self, K]) when is_integer(K), K >= 0 ->
    Bytes = (K + 7) div 8,
    case Bytes of
        0 ->
            0;
        _ ->
            Raw = binary:decode_unsigned(crypto:strong_rand_bytes(Bytes)),
            Raw bsr (Bytes * 8 - K)
    end;
random_getrandbits([_Self, K]) when is_integer(K) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"ValueError">>), <<"number of bits must be non-negative">>
        )
    );
random_getrandbits(Args) ->
    erlang:error({arity_error, {'_random.Random.getrandbits', length(Args)}}).

select_env() ->
    #{
        <<"__name__">> => <<"select">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"error">> => pyrlang_exception:type(<<"OSError">>),
        <<"select">> => {py_native_varargs, fun select_select/1}
    }.

select_select([Read, Write, Except]) ->
    select_select([Read, Write, Except, none]);
select_select([Read, Write, Except, _Timeout]) ->
    {
        pyrlang_heap:list(pyrlang_iter:values(Read)),
        pyrlang_heap:list(pyrlang_iter:values(Write)),
        pyrlang_heap:list(pyrlang_iter:values(Except))
    };
select_select(Args) ->
    erlang:error({arity_error, {select, length(Args)}}).

socket_env() ->
    SocketType = socket_type(),
    Base = #{
        <<"__name__">> => <<"_socket">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"socket">> => SocketType,
        <<"SocketType">> => SocketType,
        <<"error">> => pyrlang_exception:type(<<"OSError">>),
        <<"timeout">> => pyrlang_exception:type(<<"TimeoutError">>),
        <<"gaierror">> => pyrlang_exception:type(<<"OSError">>),
        <<"herror">> => pyrlang_exception:type(<<"OSError">>),
        <<"has_ipv6">> => true,
        <<"getdefaulttimeout">> => {py_native_varargs, fun socket_getdefaulttimeout/1},
        <<"setdefaulttimeout">> => {py_native_varargs, fun socket_setdefaulttimeout/1},
        <<"gethostname">> => fun socket_gethostname/0,
        <<"gethostbyname">> => fun socket_gethostbyname/1,
        <<"gethostbyaddr">> => fun socket_gethostbyaddr/1,
        <<"getservbyname">> => {py_native_varargs, fun socket_getservbyname/1},
        <<"getprotobyname">> => fun socket_getprotobyname/1,
        <<"getaddrinfo">> => {py_native_varargs, fun socket_getaddrinfo/1},
        <<"getnameinfo">> => {py_native_varargs, fun socket_getnameinfo/1},
        <<"inet_aton">> => fun socket_inet_aton/1,
        <<"inet_ntoa">> => fun socket_inet_ntoa/1,
        <<"inet_pton">> => fun socket_inet_pton/2,
        <<"inet_ntop">> => fun socket_inet_ntop/2,
        <<"ntohs">> => fun socket_identity/1,
        <<"ntohl">> => fun socket_identity/1,
        <<"htons">> => fun socket_identity/1,
        <<"htonl">> => fun socket_identity/1,
        <<"dup">> => fun socket_dup/1
    },
    maps:merge(Base, socket_constants()).

socket_constants() ->
    #{
        <<"AF_UNSPEC">> => 0,
        <<"AF_UNIX">> => 1,
        <<"AF_INET">> => 2,
        <<"AF_INET6">> => 30,
        <<"SOCK_STREAM">> => 1,
        <<"SOCK_DGRAM">> => 2,
        <<"SOCK_RAW">> => 3,
        <<"SOCK_SEQPACKET">> => 5,
        <<"SOL_SOCKET">> => 16#FFFF,
        <<"SO_REUSEADDR">> => 4,
        <<"SO_KEEPALIVE">> => 8,
        <<"SO_BROADCAST">> => 32,
        <<"SO_REUSEPORT">> => 512,
        <<"SO_ERROR">> => 4103,
        <<"TCP_NODELAY">> => 1,
        <<"IPPROTO_IP">> => 0,
        <<"IPPROTO_TCP">> => 6,
        <<"IPPROTO_UDP">> => 17,
        <<"IPPROTO_IPV6">> => 41,
        <<"IPV6_V6ONLY">> => 27,
        <<"AI_PASSIVE">> => 1,
        <<"AI_CANONNAME">> => 2,
        <<"AI_NUMERICHOST">> => 4,
        <<"AI_ADDRCONFIG">> => 1024,
        <<"AI_NUMERICSERV">> => 4096,
        <<"AI_V4MAPPED">> => 2048,
        <<"MSG_OOB">> => 1,
        <<"MSG_PEEK">> => 2,
        <<"MSG_DONTROUTE">> => 4,
        <<"MSG_EOR">> => 8,
        <<"MSG_TRUNC">> => 16,
        <<"MSG_CTRUNC">> => 32,
        <<"MSG_WAITALL">> => 64,
        <<"MSG_DONTWAIT">> => 128,
        <<"SHUT_RD">> => 0,
        <<"SHUT_WR">> => 1,
        <<"SHUT_RDWR">> => 2
    }.

socket_type() ->
    pyrlang_object:new_class(<<"socket">>, [maps:get(<<"object">>, pyrlang_builtins:env())], #{
        <<"__init__">> => {py_native_call, fun socket_init/2},
        <<"family">> => socket_hidden_descriptor(<<"_family">>, 2),
        <<"type">> => socket_hidden_descriptor(<<"_type">>, 1),
        <<"proto">> => socket_hidden_descriptor(<<"_proto">>, 0),
        <<"fileno">> => {py_native_varargs, fun socket_fileno/1},
        <<"close">> => {py_native_varargs, fun socket_close/1},
        <<"detach">> => {py_native_varargs, fun socket_detach/1},
        <<"setblocking">> => {py_native_varargs, fun socket_setblocking/1},
        <<"gettimeout">> => {py_native_varargs, fun socket_gettimeout/1},
        <<"settimeout">> => {py_native_varargs, fun socket_settimeout/1},
        <<"setsockopt">> => {py_native_varargs, fun socket_noop/1},
        <<"getsockopt">> => {py_native_varargs, fun socket_getsockopt/1},
        <<"bind">> => {py_native_varargs, fun socket_bind/1},
        <<"listen">> => {py_native_varargs, fun socket_noop/1},
        <<"connect">> => {py_native_varargs, fun socket_connect/1},
        <<"connect_ex">> => {py_native_varargs, fun socket_connect_ex/1},
        <<"shutdown">> => {py_native_varargs, fun socket_noop/1},
        <<"getsockname">> => {py_native_varargs, fun socket_getsockname/1},
        <<"getpeername">> => {py_native_varargs, fun socket_getpeername/1},
        <<"_accept">> => {py_native_varargs, fun socket_accept/1},
        <<"send">> => {py_native_varargs, fun socket_send/1},
        <<"sendall">> => {py_native_varargs, fun socket_noop/1},
        <<"recv">> => {py_native_varargs, fun socket_recv/1},
        <<"recv_into">> => {py_native_varargs, fun socket_recv_into/1}
    }).

socket_hidden_descriptor(Name, Default) ->
    pyrlang_object:descriptor(
        fun(Obj, _Class) -> socket_hidden_attr(Obj, Name, Default) end,
        undefined
    ).

socket_init([Self | PosArgs], KwArgs) ->
    Unknown = maps:keys(
        maps:without([<<"family">>, <<"type">>, <<"proto">>, <<"fileno">>], KwArgs)
    ),
    case {length(PosArgs) =< 4, Unknown} of
        {false, _} ->
            erlang:error({arity_error, {socket, length(PosArgs)}});
        {_, [_ | _]} ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}});
        {true, []} ->
            Family0 = socket_arg(PosArgs, 1, maps:get(<<"family">>, KwArgs, -1)),
            Type0 = socket_arg(PosArgs, 2, maps:get(<<"type">>, KwArgs, -1)),
            Proto0 = socket_arg(PosArgs, 3, maps:get(<<"proto">>, KwArgs, -1)),
            Fileno0 = socket_arg(PosArgs, 4, maps:get(<<"fileno">>, KwArgs, none)),
            Family1 = socket_int(Family0, -1),
            Type1 = socket_int(Type0, -1),
            Proto1 = socket_int(Proto0, -1),
            {Family, Type, Proto} =
                case Fileno0 of
                    none ->
                        {
                            socket_default(Family1, -1, 2),
                            socket_default(Type1, -1, 1),
                            socket_default(Proto1, -1, 0)
                        };
                    _ ->
                        {
                            socket_default(Family1, -1, 0),
                            socket_default(Type1, -1, 0),
                            socket_default(Proto1, -1, 0)
                        }
                end,
            Fileno =
                case Fileno0 of
                    none -> socket_next_fd();
                    _ -> socket_int(Fileno0, socket_next_fd())
                end,
            ok = pyrlang_object:set_attr(Self, <<"_family">>, Family),
            ok = pyrlang_object:set_attr(Self, <<"_type">>, Type),
            ok = pyrlang_object:set_attr(Self, <<"_proto">>, Proto),
            ok = pyrlang_object:set_attr(Self, <<"_fileno">>, Fileno),
            ok = pyrlang_object:set_attr(Self, <<"_timeout">>, socket_default_timeout()),
            ok = pyrlang_object:set_attr(Self, <<"_closed">>, false),
            ok = pyrlang_object:set_attr(Self, <<"_sockname">>, {<<"0.0.0.0">>, 0}),
            ok = pyrlang_object:set_attr(Self, <<"_peername">>, none),
            none
    end;
socket_init(Args, _KwArgs) ->
    erlang:error({arity_error, {socket, length(Args)}}).

socket_arg(Args, Index, Default) ->
    case length(Args) >= Index of
        true -> lists:nth(Index, Args);
        false -> Default
    end.

socket_default(Value, Sentinel, Default) ->
    case Value of
        Sentinel -> Default;
        _ -> Value
    end.

socket_int(Value, _Default) when is_integer(Value) ->
    Value;
socket_int(true, _Default) ->
    1;
socket_int(false, _Default) ->
    0;
socket_int({py_ref, _} = Value, Default) ->
    try pyrlang_object:get_attr(Value, <<"value">>) of
        Inner when is_integer(Inner) -> Inner;
        Inner -> socket_int(Inner, Default)
    catch
        _:_ ->
            try pyrlang_object:get_attr(Value, <<"_value_">>) of
                Inner when is_integer(Inner) -> Inner;
                Inner -> socket_int(Inner, Default)
            catch
                _:_ -> Default
            end
    end;
socket_int(_Value, Default) ->
    Default.

socket_next_fd() ->
    Next =
        case erlang:get(pyrlang_socket_next_fd) of
            undefined -> 100;
            Value when is_integer(Value) -> Value
        end,
    erlang:put(pyrlang_socket_next_fd, Next + 1),
    Next.

socket_default_timeout() ->
    case erlang:get(pyrlang_socket_default_timeout) of
        undefined -> none;
        Value -> Value
    end.

socket_hidden_attr(undefined, _Name, Default) ->
    Default;
socket_hidden_attr(Self, Name, Default) ->
    try
        pyrlang_object:get_attr(Self, Name)
    catch
        _:_ -> Default
    end.

socket_set_hidden_attr(Self, Name, Value) ->
    ok = pyrlang_object:set_attr(Self, Name, Value),
    none.

socket_getdefaulttimeout([]) ->
    socket_default_timeout();
socket_getdefaulttimeout(Args) ->
    erlang:error({arity_error, {getdefaulttimeout, length(Args)}}).

socket_setdefaulttimeout([Timeout]) ->
    erlang:put(pyrlang_socket_default_timeout, Timeout),
    none;
socket_setdefaulttimeout(Args) ->
    erlang:error({arity_error, {setdefaulttimeout, length(Args)}}).

socket_gethostname() ->
    <<"localhost">>.

socket_gethostbyname(Host) ->
    case normalize_name(Host) of
        <<"localhost">> -> <<"127.0.0.1">>;
        <<"">> -> <<"127.0.0.1">>;
        HostBin -> HostBin
    end.

socket_gethostbyaddr(Address) ->
    AddressBin = normalize_name(Address),
    {AddressBin, pyrlang_heap:list([]), pyrlang_heap:list([AddressBin])}.

socket_getservbyname([Service]) ->
    socket_service_port(Service, <<"tcp">>);
socket_getservbyname([Service, Proto]) ->
    socket_service_port(Service, Proto);
socket_getservbyname(Args) ->
    erlang:error({arity_error, {getservbyname, length(Args)}}).

socket_service_port(Service0, _Proto) ->
    Service = normalize_name(Service0),
    case Service of
        <<"http">> ->
            80;
        <<"https">> ->
            443;
        <<"ssh">> ->
            22;
        <<"smtp">> ->
            25;
        <<"domain">> ->
            53;
        _ ->
            try
                binary_to_integer(Service)
            catch
                error:badarg -> 0
            end
    end.

socket_getprotobyname(Proto0) ->
    case normalize_name(Proto0) of
        <<"tcp">> -> 6;
        <<"udp">> -> 17;
        <<"ipv6">> -> 41;
        _ -> 0
    end.

socket_getaddrinfo([Host, Port]) ->
    socket_getaddrinfo([Host, Port, 0, 0, 0, 0]);
socket_getaddrinfo([Host, Port, Family]) ->
    socket_getaddrinfo([Host, Port, Family, 0, 0, 0]);
socket_getaddrinfo([Host, Port, Family, Type]) ->
    socket_getaddrinfo([Host, Port, Family, Type, 0, 0]);
socket_getaddrinfo([Host, Port, Family, Type, Proto]) ->
    socket_getaddrinfo([Host, Port, Family, Type, Proto, 0]);
socket_getaddrinfo([Host, Port, Family0, Type0, Proto0, _Flags]) ->
    Family = socket_default(socket_int(Family0, 0), 0, 2),
    Type = socket_default(socket_int(Type0, 0), 0, 1),
    Proto = socket_default(socket_int(Proto0, 0), 0, 6),
    HostBin = socket_host(Host),
    PortValue = socket_port(Port),
    pyrlang_heap:list([{Family, Type, Proto, <<>>, {HostBin, PortValue}}]);
socket_getaddrinfo(Args) ->
    erlang:error({arity_error, {getaddrinfo, length(Args)}}).

socket_getnameinfo([SockAddr, _Flags]) ->
    case SockAddr of
        {Host, Port} ->
            {normalize_name(Host), integer_to_binary(socket_port(Port))};
        {Host, Port, _FlowInfo, _ScopeId} ->
            {normalize_name(Host), integer_to_binary(socket_port(Port))};
        _ ->
            {<<"localhost">>, <<"0">>}
    end;
socket_getnameinfo(Args) ->
    erlang:error({arity_error, {getnameinfo, length(Args)}}).

socket_host(none) ->
    <<"127.0.0.1">>;
socket_host(Host) ->
    case normalize_name(Host) of
        <<>> -> <<"127.0.0.1">>;
        HostBin -> HostBin
    end.

socket_port(none) ->
    0;
socket_port(Port) when is_integer(Port) ->
    Port;
socket_port(Port) when is_binary(Port) ->
    try
        binary_to_integer(Port)
    catch
        error:badarg -> socket_service_port(Port, <<"tcp">>)
    end;
socket_port(Port) when is_list(Port) ->
    socket_port(unicode:characters_to_binary(Port));
socket_port(Port) ->
    socket_int(Port, 0).

socket_inet_aton(Address) ->
    socket_inet_pton(2, Address).

socket_inet_ntoa(Packed) ->
    socket_inet_ntop(2, Packed).

socket_inet_pton(Family0, Address0) ->
    Family = socket_int(Family0, 2),
    Address = normalize_name(Address0),
    case Family of
        2 -> socket_pack_ipv4(Address);
        30 -> socket_pack_ipv6(Address);
        _ -> socket_raise_os_error(<<"unsupported address family">>)
    end.

socket_inet_ntop(Family0, Packed0) ->
    Family = socket_int(Family0, 2),
    Packed = normalize_name(Packed0),
    case {Family, Packed} of
        {2, <<A:8, B:8, C:8, D:8>>} ->
            iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A, B, C, D]));
        {30, <<0:120, 1:8>>} ->
            <<"::1">>;
        {30, <<0:128>>} ->
            <<"::">>;
        {30, _} ->
            <<"::">>;
        _ ->
            socket_raise_os_error(<<"packed IP wrong length for inet_ntop">>)
    end.

socket_pack_ipv4(Address) ->
    Parts = binary:split(Address, <<".">>, [global]),
    case Parts of
        [A0, B0, C0, D0] ->
            try
                A = binary_to_integer(A0),
                B = binary_to_integer(B0),
                C = binary_to_integer(C0),
                D = binary_to_integer(D0),
                case lists:all(fun(Byte) -> Byte >= 0 andalso Byte =< 255 end, [A, B, C, D]) of
                    true ->
                        <<A:8, B:8, C:8, D:8>>;
                    false ->
                        socket_raise_os_error(<<"illegal IP address string passed to inet_pton">>)
                end
            catch
                error:badarg ->
                    socket_raise_os_error(<<"illegal IP address string passed to inet_pton">>)
            end;
        _ ->
            socket_raise_os_error(<<"illegal IP address string passed to inet_pton">>)
    end.

socket_pack_ipv6(<<"::1">>) ->
    <<0:120, 1:8>>;
socket_pack_ipv6(<<"::">>) ->
    <<0:128>>;
socket_pack_ipv6(_Address) ->
    <<0:128>>.

socket_identity(Value) ->
    Value.

socket_dup(Fd) ->
    socket_int(Fd, 0).

socket_fileno([Self]) ->
    case socket_hidden_attr(Self, <<"_closed">>, false) of
        true -> -1;
        false -> socket_hidden_attr(Self, <<"_fileno">>, -1)
    end;
socket_fileno(Args) ->
    erlang:error({arity_error, {fileno, length(Args)}}).

socket_close([Self]) ->
    socket_set_hidden_attr(Self, <<"_closed">>, true);
socket_close(Args) ->
    erlang:error({arity_error, {close, length(Args)}}).

socket_detach([Self]) ->
    Fd = socket_fileno([Self]),
    ok = pyrlang_object:set_attr(Self, <<"_closed">>, true),
    ok = pyrlang_object:set_attr(Self, <<"_fileno">>, -1),
    Fd;
socket_detach(Args) ->
    erlang:error({arity_error, {detach, length(Args)}}).

socket_setblocking([Self, Flag]) ->
    Timeout =
        case Flag of
            false -> 0.0;
            0 -> 0.0;
            _ -> none
        end,
    socket_set_hidden_attr(Self, <<"_timeout">>, Timeout);
socket_setblocking(Args) ->
    erlang:error({arity_error, {setblocking, length(Args)}}).

socket_gettimeout([Self]) ->
    socket_hidden_attr(Self, <<"_timeout">>, none);
socket_gettimeout(Args) ->
    erlang:error({arity_error, {gettimeout, length(Args)}}).

socket_settimeout([Self, Timeout]) ->
    socket_set_hidden_attr(Self, <<"_timeout">>, Timeout);
socket_settimeout(Args) ->
    erlang:error({arity_error, {settimeout, length(Args)}}).

socket_noop([_Self | _Args]) ->
    none;
socket_noop(Args) ->
    erlang:error({arity_error, {socket_method, length(Args)}}).

socket_getsockopt([_Self, _Level, _OptName]) ->
    0;
socket_getsockopt([_Self, _Level, _OptName, BufLen]) when is_integer(BufLen), BufLen > 0 ->
    <<0:(BufLen * 8)>>;
socket_getsockopt(Args) ->
    erlang:error({arity_error, {getsockopt, length(Args)}}).

socket_bind([Self, Address]) ->
    socket_set_hidden_attr(Self, <<"_sockname">>, Address);
socket_bind(Args) ->
    erlang:error({arity_error, {bind, length(Args)}}).

socket_connect([Self, Address]) ->
    socket_set_hidden_attr(Self, <<"_peername">>, Address);
socket_connect(Args) ->
    erlang:error({arity_error, {connect, length(Args)}}).

socket_connect_ex([Self, Address]) ->
    _ = socket_connect([Self, Address]),
    0;
socket_connect_ex(Args) ->
    erlang:error({arity_error, {connect_ex, length(Args)}}).

socket_getsockname([Self]) ->
    socket_hidden_attr(Self, <<"_sockname">>, {<<"0.0.0.0">>, 0});
socket_getsockname(Args) ->
    erlang:error({arity_error, {getsockname, length(Args)}}).

socket_getpeername([Self]) ->
    case socket_hidden_attr(Self, <<"_peername">>, none) of
        none -> socket_raise_os_error(<<"socket is not connected">>);
        Peer -> Peer
    end;
socket_getpeername(Args) ->
    erlang:error({arity_error, {getpeername, length(Args)}}).

socket_accept([Self]) ->
    Fd = socket_next_fd(),
    Address = socket_hidden_attr(Self, <<"_sockname">>, {<<"127.0.0.1">>, 0}),
    {Fd, Address};
socket_accept(Args) ->
    erlang:error({arity_error, {'_accept', length(Args)}}).

socket_send([_Self, Data]) ->
    byte_size(normalize_name(Data));
socket_send([_Self, Data, _Flags]) ->
    byte_size(normalize_name(Data));
socket_send(Args) ->
    erlang:error({arity_error, {send, length(Args)}}).

socket_recv([_Self, Size]) when is_integer(Size), Size >= 0 ->
    <<0:(Size * 8)>>;
socket_recv([_Self, Size, _Flags]) when is_integer(Size), Size >= 0 ->
    <<0:(Size * 8)>>;
socket_recv(Args) ->
    erlang:error({arity_error, {recv, length(Args)}}).

socket_recv_into([_Self, _Buffer]) ->
    0;
socket_recv_into([_Self, _Buffer, _NBytes]) ->
    0;
socket_recv_into([_Self, _Buffer, _NBytes, _Flags]) ->
    0;
socket_recv_into(Args) ->
    erlang:error({arity_error, {recv_into, length(Args)}}).

socket_raise_os_error(Message) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"OSError">>), Message)).

typing_env() ->
    TypeVar = typing_type_parameter_class(<<"TypeVar">>, typevar),
    ParamSpec = typing_type_parameter_class(<<"ParamSpec">>, paramspec),
    TypeVarTuple = typing_type_parameter_class(<<"TypeVarTuple">>, typevartuple),
    ParamSpecArgs = typing_simple_class(<<"ParamSpecArgs">>),
    ParamSpecKwargs = typing_simple_class(<<"ParamSpecKwargs">>),
    TypeAliasType = typing_type_alias_type_class(),
    Generic = typing_generic_class(),
    #{
        <<"__name__">> => <<"_typing">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"_idfunc">> => {py_native_varargs, fun typing_idfunc/1},
        <<"TypeVar">> => TypeVar,
        <<"ParamSpec">> => ParamSpec,
        <<"TypeVarTuple">> => TypeVarTuple,
        <<"ParamSpecArgs">> => ParamSpecArgs,
        <<"ParamSpecKwargs">> => ParamSpecKwargs,
        <<"TypeAliasType">> => TypeAliasType,
        <<"Generic">> => Generic,
        <<"NoDefault">> => typing_no_default()
    }.

typing_simple_class(Name) ->
    typing_cached_class(Name, fun(_Class) ->
        #{
            <<"__module__">> => <<"_typing">>
        }
    end).

typing_generic_class() ->
    typing_cached_class(<<"Generic">>, fun(_Class) ->
        #{
            <<"__module__">> => <<"typing">>,
            <<"__parameters__">> => {},
            <<"__class_getitem__">> => typing_classmethod(
                {py_native_varargs, fun typing_generic_class_getitem/1}
            ),
            <<"__init_subclass__">> => typing_classmethod(
                {py_native_varargs, fun(_Args) -> none end}
            )
        }
    end).

typing_type_parameter_class(Name, Kind) ->
    typing_cached_class(Name, fun(Class) ->
        #{
            <<"__module__">> => <<"_typing">>,
            <<"__pyrlang_builtin_constructor__">> =>
                {py_native_call, fun(Args, KwArgs) ->
                    typing_type_parameter_new(Class, Kind, Args, KwArgs)
                end}
        }
    end).

typing_type_alias_type_class() ->
    typing_cached_class(<<"TypeAliasType">>, fun(Class) ->
        #{
            <<"__module__">> => <<"_typing">>,
            <<"__pyrlang_builtin_constructor__">> =>
                {py_native_call, fun(Args, KwArgs) ->
                    typing_type_alias_type_new(Class, Args, KwArgs)
                end}
        }
    end).

typing_cached_class(Name, AttrsFun) ->
    Key = {pyrlang_typing_class, Name},
    case erlang:get(Key) of
        {py_ref, _} = Existing ->
            try pyrlang_heap:type(Existing) of
                class -> Existing;
                _Other -> typing_create_cached_class(Key, Name, AttrsFun)
            catch
                _:_ -> typing_create_cached_class(Key, Name, AttrsFun)
            end;
        _ ->
            typing_create_cached_class(Key, Name, AttrsFun)
    end.

typing_create_cached_class(Key, Name, AttrsFun) ->
    Class = pyrlang_object:new_class(Name, [maps:get(<<"object">>, pyrlang_builtins:env())], #{}),
    maps:foreach(
        fun(Attr, Value) -> ok = pyrlang_object:set_class_attr(Class, Attr, Value) end,
        AttrsFun(Class)
    ),
    erlang:put(Key, Class),
    Class.

typing_classmethod(Callable) ->
    pyrlang_object:descriptor(
        fun(_Obj, Class) -> {py_bound_method, Callable, Class} end,
        undefined,
        #{kind => classmethod, callable => Callable}
    ).

typing_no_default() ->
    py_typing_no_default.

typing_idfunc([Value]) ->
    Value;
typing_idfunc([_Self, Value]) ->
    Value;
typing_idfunc(Args) ->
    erlang:error({arity_error, {'_typing._idfunc', length(Args)}}).

typing_generic_class_getitem([Class, _Args]) ->
    Class;
typing_generic_class_getitem(Args) ->
    erlang:error({arity_error, {'Generic.__class_getitem__', length(Args)}}).

typing_type_parameter_new(Class, Kind, [Name | Rest], KwArgs0) ->
    Allowed = [
        <<"bound">>, <<"covariant">>, <<"contravariant">>, <<"infer_variance">>, <<"default">>
    ],
    Unknown = maps:keys(maps:without(Allowed, KwArgs0)),
    case Unknown of
        [] -> ok;
        _ -> erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end,
    Instance = pyrlang_object:instantiate(Class),
    NameBin = normalize_name(Name),
    Default = maps:get(<<"default">>, KwArgs0, typing_no_default()),
    Constraints =
        case Kind of
            typevar -> list_to_tuple(Rest);
            _ -> {}
        end,
    Attrs0 = #{
        <<"__name__">> => NameBin,
        <<"__module__">> => <<"typing">>,
        <<"__bound__">> => maps:get(<<"bound">>, KwArgs0, none),
        <<"__constraints__">> => Constraints,
        <<"__covariant__">> => typing_truthy(maps:get(<<"covariant">>, KwArgs0, false)),
        <<"__contravariant__">> => typing_truthy(maps:get(<<"contravariant">>, KwArgs0, false)),
        <<"__infer_variance__">> => typing_truthy(maps:get(<<"infer_variance">>, KwArgs0, false)),
        <<"__default__">> => Default,
        <<"has_default">> => fun() -> Default =/= typing_no_default() end,
        <<"__typing_subst__">> => fun(Arg) -> Arg end
    },
    Attrs =
        case Kind of
            paramspec ->
                ArgsInstance = typing_param_spec_side(
                    typing_simple_class(<<"ParamSpecArgs">>), Instance
                ),
                KwargsInstance = typing_param_spec_side(
                    typing_simple_class(<<"ParamSpecKwargs">>), Instance
                ),
                Attrs0#{
                    <<"args">> => ArgsInstance,
                    <<"kwargs">> => KwargsInstance,
                    <<"__typing_prepare_subst__">> => fun(_Alias, Args) -> Args end
                };
            typevartuple ->
                Attrs0#{
                    <<"__typing_prepare_subst__">> => fun(_Alias, Args) -> Args end
                };
            typevar ->
                Attrs0
        end,
    maps:foreach(
        fun(Attr, Value) -> ok = pyrlang_object:set_attr(Instance, Attr, Value) end, Attrs
    ),
    Instance;
typing_type_parameter_new(_Class, _Kind, Args, _KwArgs) ->
    erlang:error({arity_error, {'_typing.type_parameter', length(Args)}}).

typing_param_spec_side(Class, Origin) ->
    Instance = pyrlang_object:instantiate(Class),
    ok = pyrlang_object:set_attr(Instance, <<"__origin__">>, Origin),
    Instance.

typing_type_alias_type_new(Class, [Name, Value | Rest], KwArgs0) ->
    Allowed = [<<"type_params">>],
    Unknown = maps:keys(maps:without(Allowed, KwArgs0)),
    case Unknown of
        [] -> ok;
        _ -> erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end,
    TypeParams =
        case Rest of
            [] -> maps:get(<<"type_params">>, KwArgs0, {});
            [Params] -> Params;
            _ -> erlang:error({arity_error, {'TypeAliasType', length([Name, Value | Rest])}})
        end,
    Instance = pyrlang_object:instantiate(Class),
    maps:foreach(
        fun(Attr, AttrValue) -> ok = pyrlang_object:set_attr(Instance, Attr, AttrValue) end,
        #{
            <<"__name__">> => normalize_name(Name),
            <<"__module__">> => <<"typing">>,
            <<"__value__">> => Value,
            <<"__type_params__">> => TypeParams
        }
    ),
    Instance;
typing_type_alias_type_new(_Class, Args, _KwArgs) ->
    erlang:error({arity_error, {'TypeAliasType', length(Args)}}).

typing_truthy(false) -> false;
typing_truthy(none) -> false;
typing_truthy(0) -> false;
typing_truthy(<<>>) -> false;
typing_truthy([]) -> false;
typing_truthy(_Value) -> true.

signal_env() ->
    Base = #{
        <<"__name__">> => <<"_signal">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"default_int_handler">> => signal_default_handler(),
        <<"signal">> => {py_native_varargs, fun signal_signal/1},
        <<"getsignal">> => {py_native_varargs, fun signal_getsignal/1},
        <<"raise_signal">> => {py_native_varargs, fun signal_raise_signal/1},
        <<"set_wakeup_fd">> => {py_native_varargs, fun signal_set_wakeup_fd/1},
        <<"siginterrupt">> => {py_native_varargs, fun signal_siginterrupt/1},
        <<"valid_signals">> => {py_native_varargs, fun signal_valid_signals/1},
        <<"strsignal">> => {py_native_varargs, fun signal_strsignal/1}
    },
    maps:merge(Base, signal_constants()).

signal_constants() ->
    #{
        <<"SIG_DFL">> => 0,
        <<"SIG_IGN">> => 1,
        <<"SIGHUP">> => 1,
        <<"SIGINT">> => 2,
        <<"SIGQUIT">> => 3,
        <<"SIGILL">> => 4,
        <<"SIGTRAP">> => 5,
        <<"SIGABRT">> => 6,
        <<"SIGIOT">> => 6,
        <<"SIGEMT">> => 7,
        <<"SIGFPE">> => 8,
        <<"SIGKILL">> => 9,
        <<"SIGBUS">> => 10,
        <<"SIGSEGV">> => 11,
        <<"SIGSYS">> => 12,
        <<"SIGPIPE">> => 13,
        <<"SIGALRM">> => 14,
        <<"SIGTERM">> => 15,
        <<"SIGURG">> => 16,
        <<"SIGSTOP">> => 17,
        <<"SIGTSTP">> => 18,
        <<"SIGCONT">> => 19,
        <<"SIGCHLD">> => 20,
        <<"SIGCLD">> => 20,
        <<"SIGTTIN">> => 21,
        <<"SIGTTOU">> => 22,
        <<"SIGIO">> => 23,
        <<"SIGPOLL">> => 23,
        <<"SIGXCPU">> => 24,
        <<"SIGXFSZ">> => 25,
        <<"SIGVTALRM">> => 26,
        <<"SIGPROF">> => 27,
        <<"SIGWINCH">> => 28,
        <<"SIGINFO">> => 29,
        <<"SIGUSR1">> => 30,
        <<"SIGUSR2">> => 31,
        <<"NSIG">> => 32,
        <<"ITIMER_REAL">> => 0,
        <<"ITIMER_VIRTUAL">> => 1,
        <<"ITIMER_PROF">> => 2
    }.

signal_numbers() ->
    lists:seq(1, 31).

signal_default_handler() ->
    {py_native_varargs, fun signal_default_int_handler/1}.

signal_handlers() ->
    Default = #{2 => signal_default_handler()},
    case erlang:get(pyrlang_signal_handlers) of
        undefined -> Default;
        Handlers when is_map(Handlers) -> maps:merge(Default, Handlers)
    end.

put_signal_handler(Signum, Handler) ->
    Handlers =
        case erlang:get(pyrlang_signal_handlers) of
            undefined -> #{};
            Current when is_map(Current) -> Current
        end,
    erlang:put(pyrlang_signal_handlers, maps:put(Signum, Handler, Handlers)).

signal_signal([Signum0, Handler]) ->
    Signum = signal_number(Signum0),
    Old = maps:get(Signum, signal_handlers(), 0),
    put_signal_handler(Signum, Handler),
    Old;
signal_signal(Args) ->
    erlang:error({arity_error, {signal, length(Args)}}).

signal_getsignal([Signum0]) ->
    Signum = signal_number(Signum0),
    maps:get(Signum, signal_handlers(), 0);
signal_getsignal(Args) ->
    erlang:error({arity_error, {getsignal, length(Args)}}).

signal_raise_signal([Signum0]) ->
    Signum = signal_number(Signum0),
    Handler = maps:get(Signum, signal_handlers(), 0),
    case {Signum, Handler =:= signal_default_handler()} of
        {2, true} ->
            signal_default_int_handler([Signum, none]);
        _ when Handler =:= 1 ->
            none;
        _Handler ->
            none
    end;
signal_raise_signal(Args) ->
    erlang:error({arity_error, {raise_signal, length(Args)}}).

signal_set_wakeup_fd([Fd]) ->
    signal_set_wakeup_fd([Fd, true]);
signal_set_wakeup_fd([Fd, _WarnOnFullBuffer]) ->
    Old =
        case erlang:get(pyrlang_signal_wakeup_fd) of
            undefined -> -1;
            Current -> Current
        end,
    erlang:put(pyrlang_signal_wakeup_fd, signal_fd(Fd)),
    Old;
signal_set_wakeup_fd(Args) ->
    erlang:error({arity_error, {set_wakeup_fd, length(Args)}}).

signal_siginterrupt([Signum0, _Flag]) ->
    _ = signal_number(Signum0),
    none;
signal_siginterrupt(Args) ->
    erlang:error({arity_error, {siginterrupt, length(Args)}}).

signal_valid_signals([]) ->
    pyrlang_heap:set(signal_numbers());
signal_valid_signals(Args) ->
    erlang:error({arity_error, {valid_signals, length(Args)}}).

signal_strsignal([Signum0]) ->
    Signum = signal_number(Signum0),
    iolist_to_binary(io_lib:format("Signal ~B", [Signum]));
signal_strsignal(Args) ->
    erlang:error({arity_error, {strsignal, length(Args)}}).

signal_default_int_handler(_Args) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"KeyboardInterrupt">>), <<>>)
    ).

signal_number(Value) ->
    Signum = socket_int(Value, -1),
    case lists:member(Signum, signal_numbers()) of
        true ->
            Signum;
        false ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>), <<"invalid signal number">>
                )
            )
    end.

signal_fd(Value) when is_integer(Value) ->
    Value;
signal_fd(Value) ->
    socket_int(Value, -1).

errno_env() ->
    Pairs = errno_pairs(),
    maps:merge(
        #{
            <<"__name__">> => <<"errno">>,
            <<"__file__">> => builtin,
            <<"__package__">> => <<"">>,
            <<"__path__">> => none,
            <<"errorcode">> => pyrlang_heap:dict([{Code, Name} || {Name, Code} <- Pairs])
        },
        maps:from_list(Pairs)
    ).

errno_pairs() ->
    [
        {<<"EPERM">>, 1},
        {<<"ENOENT">>, 2},
        {<<"ESRCH">>, 3},
        {<<"EINTR">>, 4},
        {<<"EIO">>, 5},
        {<<"ENXIO">>, 6},
        {<<"E2BIG">>, 7},
        {<<"ENOEXEC">>, 8},
        {<<"EBADF">>, 9},
        {<<"ECHILD">>, 10},
        {<<"EDEADLK">>, 11},
        {<<"ENOMEM">>, 12},
        {<<"EACCES">>, 13},
        {<<"EFAULT">>, 14},
        {<<"EBUSY">>, 16},
        {<<"EEXIST">>, 17},
        {<<"EXDEV">>, 18},
        {<<"ENODEV">>, 19},
        {<<"ENOTDIR">>, 20},
        {<<"EISDIR">>, 21},
        {<<"EINVAL">>, 22},
        {<<"ENFILE">>, 23},
        {<<"EMFILE">>, 24},
        {<<"ENOTTY">>, 25},
        {<<"EFBIG">>, 27},
        {<<"ENOSPC">>, 28},
        {<<"ESPIPE">>, 29},
        {<<"EROFS">>, 30},
        {<<"EMLINK">>, 31},
        {<<"EPIPE">>, 32},
        {<<"EDOM">>, 33},
        {<<"ERANGE">>, 34},
        {<<"EAGAIN">>, 35},
        {<<"EWOULDBLOCK">>, 35},
        {<<"EINPROGRESS">>, 36},
        {<<"EALREADY">>, 37},
        {<<"ENOTSOCK">>, 38},
        {<<"EDESTADDRREQ">>, 39},
        {<<"EMSGSIZE">>, 40},
        {<<"EPROTOTYPE">>, 41},
        {<<"ENOPROTOOPT">>, 42},
        {<<"EPROTONOSUPPORT">>, 43},
        {<<"ESOCKTNOSUPPORT">>, 44},
        {<<"ENOTSUP">>, 45},
        {<<"EOPNOTSUPP">>, 45},
        {<<"EPFNOSUPPORT">>, 46},
        {<<"EAFNOSUPPORT">>, 47},
        {<<"EADDRINUSE">>, 48},
        {<<"EADDRNOTAVAIL">>, 49},
        {<<"ENETDOWN">>, 50},
        {<<"ENETUNREACH">>, 51},
        {<<"ENETRESET">>, 52},
        {<<"ECONNABORTED">>, 53},
        {<<"ECONNRESET">>, 54},
        {<<"ENOBUFS">>, 55},
        {<<"EISCONN">>, 56},
        {<<"ENOTCONN">>, 57},
        {<<"ESHUTDOWN">>, 58},
        {<<"ETIMEDOUT">>, 60},
        {<<"ECONNREFUSED">>, 61},
        {<<"ELOOP">>, 62},
        {<<"ENAMETOOLONG">>, 63},
        {<<"EHOSTDOWN">>, 64},
        {<<"EHOSTUNREACH">>, 65},
        {<<"ENOTEMPTY">>, 66},
        {<<"ENOLCK">>, 77},
        {<<"ENOSYS">>, 78},
        {<<"EOVERFLOW">>, 84},
        {<<"ECANCELED">>, 89},
        {<<"EIDRM">>, 90},
        {<<"ENOMSG">>, 91},
        {<<"EILSEQ">>, 92},
        {<<"EBADMSG">>, 94},
        {<<"EMULTIHOP">>, 95},
        {<<"ENODATA">>, 96},
        {<<"ENOLINK">>, 97},
        {<<"ENOSR">>, 98},
        {<<"ENOSTR">>, 99},
        {<<"EPROTO">>, 100},
        {<<"ETIME">>, 101}
    ].

posix_env() ->
    maps:merge(os_open_flag_env(), #{
        <<"__name__">> => <<"posix">>,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"environ">> => pyrlang_heap:dict(os_environ()),
        <<"sep">> => <<"/">>,
        <<"altsep">> => none,
        <<"extsep">> => <<".">>,
        <<"pathsep">> => <<":">>,
        <<"linesep">> => <<"\n">>,
        <<"defpath">> => <<"/bin:/usr/bin">>,
        <<"devnull">> => <<"/dev/null">>,
        <<"curdir">> => <<".">>,
        <<"pardir">> => <<"..">>,
        <<"_have_functions">> => pyrlang_heap:list([]),
        <<"PathLike">> => os_pathlike_class(),
        <<"fspath">> => fun posix_fspath/1,
        <<"DirEntry">> => dir_entry_type(),
        <<"stat_result">> => stat_result_type(),
        <<"terminal_size">> => terminal_size_type(),
        <<"access">> => {py_native_call, fun posix_access_call/2},
        <<"get_terminal_size">> => {py_native_varargs, fun os_get_terminal_size/1},
        <<"getcwd">> => {py_native_varargs, fun os_getcwd/1},
        <<"listdir">> => {py_native_varargs, fun posix_listdir/1},
        <<"mkdir">> => {py_native_varargs, fun posix_mkdir/1},
        <<"makedirs">> => {py_native_call, fun posix_makedirs_call/2},
        <<"walk">> => {py_native_call, fun posix_walk_call/2},
        <<"rmdir">> => {py_native_call, fun posix_rmdir_call/2},
        <<"open">> => {py_native_call, fun posix_open_call/2},
        <<"close">> => {py_native_varargs, fun posix_close/1},
        <<"fstat">> => {py_native_call, fun posix_fstat_call/2},
        <<"chmod">> => {py_native_call, fun posix_chmod_call/2},
        <<"umask">> => {py_native_varargs, fun posix_umask/1},
        <<"urandom">> => fun os_urandom/1,
        <<"replace">> => fun posix_replace/2,
        <<"rename">> => fun posix_replace/2,
        <<"stat">> => {py_native_call, fun posix_stat_call/2},
        <<"lstat">> => {py_native_call, fun posix_stat_call/2},
        <<"scandir">> => {py_native_call, fun posix_scandir_call/2},
        <<"unlink">> => {py_native_call, fun posix_unlink_call/2},
        <<"remove">> => {py_native_call, fun posix_unlink_call/2},
        <<"supports_dir_fd">> => pyrlang_heap:set([]),
        <<"supports_fd">> => pyrlang_heap:set([]),
        <<"supports_follow_symlinks">> => pyrlang_heap:set([]),
        <<"_walk_symlinks_as_files">> => false,
        <<"_path_splitroot">> => fun posix_path_splitroot/1,
        <<"_path_splitroot_ex">> => fun posix_path_splitroot/1,
        <<"_path_normpath">> => fun posix_path_normpath/1
    }).

os_open_flag_env() ->
    #{
        <<"O_RDONLY">> => 0,
        <<"O_WRONLY">> => 1,
        <<"O_RDWR">> => 2,
        <<"O_APPEND">> => 8,
        <<"O_NONBLOCK">> => 4,
        <<"O_NOFOLLOW">> => 256,
        <<"O_CREAT">> => 512,
        <<"O_TRUNC">> => 1024,
        <<"O_EXCL">> => 2048,
        <<"O_DIRECTORY">> => 1048576,
        <<"O_CLOEXEC">> => 16777216,
        <<"SEEK_SET">> => 0,
        <<"SEEK_CUR">> => 1,
        <<"SEEK_END">> => 2,
        <<"F_OK">> => 0,
        <<"X_OK">> => 1,
        <<"W_OK">> => 2,
        <<"R_OK">> => 4
    }.

posix_fspath(Path) ->
    normalize_name(Path).

posix_access_call([Path, _Mode], _KwArgs) ->
    PathList = binary_to_list(normalize_name(Path)),
    filelib:is_file(PathList) orelse filelib:is_dir(PathList);
posix_access_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_access, length(Args)}}).

posix_listdir([]) ->
    posix_listdir([<<".">>]);
posix_listdir([Path]) ->
    case file:list_dir(binary_to_list(normalize_name(Path))) of
        {ok, Names} ->
            pyrlang_heap:list([unicode:characters_to_binary(Name) || Name <- Names]);
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"OSError">>), atom_to_binary(Reason, utf8)
                )
            )
    end;
posix_listdir(Args) ->
    erlang:error({arity_error, {posix_listdir, length(Args)}}).

posix_mkdir([Path]) ->
    posix_mkdir([Path, 8#777]);
posix_mkdir([Path, _Mode]) ->
    case file:make_dir(binary_to_list(normalize_name(Path))) of
        ok ->
            none;
        {error, eexist} ->
            none;
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"OSError">>), atom_to_binary(Reason, utf8)
                )
            )
    end;
posix_mkdir(Args) ->
    erlang:error({arity_error, {posix_mkdir, length(Args)}}).

posix_makedirs_call([Path], KwArgs) ->
    posix_makedirs_call([Path, 8#777], KwArgs);
posix_makedirs_call([Path, _Mode], _KwArgs) ->
    PathList = binary_to_list(normalize_name(Path)),
    EnsurePath = filename:join(PathList, ".pyrlang-dir"),
    case filelib:ensure_dir(EnsurePath) of
        ok ->
            none;
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"OSError">>), atom_to_binary(Reason, utf8)
                )
            )
    end;
posix_makedirs_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_makedirs, length(Args)}}).

posix_walk_call([], KwArgs) ->
    case maps:find(<<"top">>, KwArgs) of
        {ok, Top} -> posix_walk_call([Top], maps:remove(<<"top">>, KwArgs));
        error -> erlang:error({arity_error, {posix_walk, 0}})
    end;
posix_walk_call([Top], KwArgs) ->
    Topdown = maps:get(<<"topdown">>, KwArgs, true),
    FollowLinks = maps:get(<<"followlinks">>, KwArgs, false),
    pyrlang_heap:list(
        posix_walk_entries(normalize_name(Top), py_truthy(Topdown), py_truthy(FollowLinks))
    );
posix_walk_call([Top, Topdown], KwArgs) ->
    FollowLinks = maps:get(<<"followlinks">>, KwArgs, false),
    pyrlang_heap:list(
        posix_walk_entries(normalize_name(Top), py_truthy(Topdown), py_truthy(FollowLinks))
    );
posix_walk_call([Top, Topdown, _OnError], KwArgs) ->
    FollowLinks = maps:get(<<"followlinks">>, KwArgs, false),
    pyrlang_heap:list(
        posix_walk_entries(normalize_name(Top), py_truthy(Topdown), py_truthy(FollowLinks))
    );
posix_walk_call([Top, Topdown, _OnError, FollowLinks], _KwArgs) ->
    pyrlang_heap:list(
        posix_walk_entries(normalize_name(Top), py_truthy(Topdown), py_truthy(FollowLinks))
    );
posix_walk_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_walk, length(Args)}}).

posix_walk_entries(Top, Topdown, FollowLinks) ->
    TopList = binary_to_list(Top),
    case file:list_dir(TopList) of
        {ok, Names0} ->
            Names = [unicode:characters_to_binary(Name) || Name <- Names0],
            {Dirs, Files} = posix_walk_partition(Top, Names, FollowLinks, [], []),
            Entry = {Top, pyrlang_heap:list(Dirs), pyrlang_heap:list(Files)},
            Children = lists:append([
                posix_walk_entries(posix_join_path(Top, Dir), Topdown, FollowLinks)
             || Dir <- Dirs
            ]),
            case Topdown of
                true -> [Entry | Children];
                false -> Children ++ [Entry]
            end;
        {error, _Reason} ->
            []
    end.

posix_walk_partition(_Top, [], _FollowLinks, Dirs, Files) ->
    {lists:reverse(Dirs), lists:reverse(Files)};
posix_walk_partition(Top, [Name | Rest], FollowLinks, Dirs, Files) ->
    Path = posix_join_path(Top, Name),
    PathList = binary_to_list(Path),
    case filelib:is_dir(PathList) andalso (FollowLinks orelse not posix_is_symlink(PathList)) of
        true -> posix_walk_partition(Top, Rest, FollowLinks, [Name | Dirs], Files);
        false -> posix_walk_partition(Top, Rest, FollowLinks, Dirs, [Name | Files])
    end.

posix_join_path(Base, Name) ->
    unicode:characters_to_binary(
        filename:join(binary_to_list(Base), binary_to_list(normalize_name(Name)))
    ).

posix_is_symlink(PathList) ->
    case file:read_link_info(PathList) of
        {ok,
            {file_info, _Size, symlink, _Access, _ATime, _MTime, _CTime, _Mode, _Links, _Major,
                _Minor, _Inode, _Uid, _Gid}} ->
            true;
        _ ->
            false
    end.

posix_rmdir_call([Path], _KwArgs) ->
    case file:del_dir(binary_to_list(normalize_name(Path))) of
        ok ->
            none;
        {error, enoent} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"FileNotFoundError">>), normalize_name(Path)
                )
            );
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"OSError">>), atom_to_binary(Reason, utf8)
                )
            )
    end;
posix_rmdir_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_rmdir, length(Args)}}).

posix_open([_Path, _Flags]) ->
    0;
posix_open([_Path, _Flags, _Mode]) ->
    0;
posix_open(Args) ->
    erlang:error({arity_error, {posix_open, length(Args)}}).

posix_open_call(Args, _KwArgs) ->
    posix_open(Args).

posix_close([_Fd]) ->
    none;
posix_close(Args) ->
    erlang:error({arity_error, {posix_close, length(Args)}}).

posix_fstat_call([_Fd], _KwArgs) ->
    stat_result_instance(8#100644, 0, 0);
posix_fstat_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_fstat, length(Args)}}).

posix_chmod_call([_Path, _Mode], _KwArgs) ->
    none;
posix_chmod_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_chmod, length(Args)}}).

posix_umask([Mask]) when is_integer(Mask) ->
    Previous =
        case erlang:get(pyrlang_posix_umask) of
            undefined -> 8#022;
            Existing when is_integer(Existing) -> Existing
        end,
    erlang:put(pyrlang_posix_umask, Mask),
    Previous;
posix_umask(Args) ->
    erlang:error({arity_error, {posix_umask, length(Args)}}).

posix_replace(Source, Destination) ->
    _ = file:delete(binary_to_list(normalize_name(Destination))),
    case
        file:rename(
            binary_to_list(normalize_name(Source)), binary_to_list(normalize_name(Destination))
        )
    of
        ok ->
            none;
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"OSError">>), atom_to_binary(Reason, utf8)
                )
            )
    end.

posix_unlink(Path) ->
    case file:delete(binary_to_list(normalize_name(Path))) of
        ok ->
            none;
        {error, enoent} ->
            none;
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"OSError">>), atom_to_binary(Reason, utf8)
                )
            )
    end.

posix_unlink_call([Path], _KwArgs) ->
    posix_unlink(Path);
posix_unlink_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_unlink, length(Args)}}).

posix_stat(Path) ->
    PathList = binary_to_list(normalize_name(Path)),
    case file:read_file_info(PathList, [{time, posix}]) of
        {ok, Info} ->
            Size = filelib:file_size(PathList),
            IsDir = filelib:is_dir(PathList),
            Mode =
                case IsDir of
                    true -> 8#040755;
                    false -> 8#100644
                end,
            MTime =
                case Info of
                    {file_info, _Size0, _Type, _Access, _ATime, MTime0, _CTime, _Mode0, _Links,
                        _Major, _Minor, _Inode, _Uid, _Gid} ->
                        MTime0;
                    _ ->
                        0
                end,
            stat_result_instance(Mode, Size, MTime);
        {error, Reason} ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"OSError">>), atom_to_binary(Reason, utf8)
                )
            )
    end.

posix_stat_call([Path], _KwArgs) ->
    posix_stat(Path);
posix_stat_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_stat, length(Args)}}).

stat_result_type() ->
    case erlang:get(pyrlang_stat_result_type) of
        undefined ->
            Class = pyrlang_object:new_class(<<"stat_result">>, [], #{
                <<"__module__">> => <<"os">>
            }),
            erlang:put(pyrlang_stat_result_type, Class),
            Class;
        Class ->
            Class
    end.

stat_result_instance(Mode, Size, MTime) ->
    native_instance(stat_result_type(), <<"stat_result">>, #{
        <<"st_mode">> => Mode,
        <<"st_size">> => Size,
        <<"st_mtime">> => MTime,
        <<"st_mtime_ns">> => MTime * 1000000000
    }).

terminal_size_type() ->
    case erlang:get(pyrlang_terminal_size_type) of
        undefined ->
            TupleClass = maps:get(<<"tuple">>, pyrlang_builtins:env()),
            Class = pyrlang_object:new_class(<<"terminal_size">>, [TupleClass], #{
                <<"__module__">> => <<"os">>,
                <<"__pyrlang_builtin_constructor__">> =>
                    {py_native_call, fun terminal_size_new/2}
            }),
            erlang:put(pyrlang_terminal_size_type, Class),
            Class;
        Class ->
            Class
    end.

terminal_size_new([Sequence], KwArgs) when map_size(KwArgs) =:= 0 ->
    terminal_size_instance(terminal_size_values(Sequence));
terminal_size_new(Args, KwArgs) ->
    erlang:error({arity_error, {terminal_size, length(Args), maps:size(KwArgs)}}).

terminal_size_values(Sequence) ->
    case pyrlang_iter:values(Sequence) of
        [Columns, Lines] ->
            {Columns, Lines};
        Values ->
            pyrlang_exception:raise(
                pyrlang_exception:make(
                    pyrlang_exception:type(<<"ValueError">>), {terminal_size, length(Values)}
                )
            )
    end.

terminal_size_instance({Columns, Lines}) ->
    Values = {Columns, Lines},
    native_instance(terminal_size_type(), <<"terminal_size">>, #{
        <<"columns">> => Columns,
        <<"lines">> => Lines,
        <<"__getitem__">> => fun(Index) -> terminal_size_getitem(Values, Index) end,
        <<"__iter__">> => fun() -> pyrlang_iter:iter(Values) end,
        <<"__len__">> => fun() -> 2 end
    }).

terminal_size_getitem(Values, Index) when is_integer(Index) ->
    element(normalize_terminal_size_index(Index), Values);
terminal_size_getitem(_Values, Index) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(
            pyrlang_exception:type(<<"TypeError">>), {terminal_size_index, Index}
        )
    ).

dir_entry_type() ->
    case erlang:get(pyrlang_dir_entry_type) of
        undefined ->
            Class = pyrlang_object:new_class(<<"DirEntry">>, [], #{
                <<"__module__">> => <<"os">>
            }),
            erlang:put(pyrlang_dir_entry_type, Class),
            Class;
        Class ->
            Class
    end.

normalize_terminal_size_index(Index) when Index >= 0, Index < 2 ->
    Index + 1;
normalize_terminal_size_index(Index) when Index < 0, Index >= -2 ->
    Index + 3;
normalize_terminal_size_index(Index) ->
    pyrlang_exception:raise(
        pyrlang_exception:make(pyrlang_exception:type(<<"IndexError">>), Index)
    ).

os_get_terminal_size([]) ->
    terminal_size_instance({80, 24});
os_get_terminal_size([_Fd]) ->
    terminal_size_instance({80, 24});
os_get_terminal_size(Args) ->
    erlang:error({arity_error, {get_terminal_size, length(Args)}}).

posix_scandir_call([], KwArgs) ->
    posix_scandir_call([<<".">>], KwArgs);
posix_scandir_call([Path], _KwArgs) ->
    NamesRef = posix_listdir([Path]),
    Base = normalize_name(Path),
    Entries =
        [posix_scandir_entry(Base, Name) || Name <- pyrlang_heap:list_items(NamesRef)],
    pyrlang_heap:list(Entries);
posix_scandir_call(Args, _KwArgs) ->
    erlang:error({arity_error, {posix_scandir, length(Args)}}).

posix_scandir_entry(Base, Name) ->
    Path = filename:join(binary_to_list(Base), binary_to_list(normalize_name(Name))),
    PathBin = unicode:characters_to_binary(Path),
    IsDir = filelib:is_dir(Path),
    IsSymlink = posix_is_symlink(Path),
    native_instance(dir_entry_type(), <<"DirEntry">>, #{
        <<"name">> => Name,
        <<"path">> => PathBin,
        <<"is_dir">> => {py_native_call, fun(_Args, _KwArgs) -> IsDir end},
        <<"is_file">> => {py_native_call, fun(_Args, _KwArgs) -> not IsDir end},
        <<"is_symlink">> => {py_native_call, fun(_Args, _KwArgs) -> IsSymlink end},
        <<"stat">> => {py_native_call, fun(_Args, _KwArgs) -> posix_stat(PathBin) end}
    }).

posix_path_splitroot(Path0) ->
    Path = normalize_name(Path0),
    case Path of
        <<"/", Rest/binary>> -> {<<>>, <<"/">>, Rest};
        _ -> {<<>>, <<>>, Path}
    end.

posix_path_normpath(Path0) ->
    unicode:characters_to_binary(filename:absname(binary_to_list(normalize_name(Path0)))).

posixpath_env(Name) ->
    #{
        <<"__name__">> => Name,
        <<"__file__">> => builtin,
        <<"__package__">> => <<"">>,
        <<"__path__">> => none,
        <<"sep">> => <<"/">>,
        <<"altsep">> => none,
        <<"extsep">> => <<".">>,
        <<"join">> => {py_native_varargs, fun posixpath_join/1},
        <<"pathsep">> => <<":">>,
        <<"defpath">> => <<"/bin:/usr/bin">>,
        <<"devnull">> => <<"/dev/null">>,
        <<"curdir">> => <<".">>,
        <<"pardir">> => <<"..">>,
        <<"dirname">> => {py_native_varargs, fun posixpath_dirname/1},
        <<"basename">> => {py_native_varargs, fun posixpath_basename/1},
        <<"split">> => {py_native_varargs, fun posixpath_split/1},
        <<"splitext">> => {py_native_varargs, fun posixpath_splitext/1},
        <<"commonprefix">> => {py_native_varargs, fun posixpath_commonprefix/1},
        <<"abspath">> => {py_native_varargs, fun posixpath_abspath/1},
        <<"realpath">> => {py_native_varargs, fun posixpath_realpath/1},
        <<"relpath">> => {py_native_varargs, fun posixpath_relpath/1},
        <<"normcase">> => {py_native_varargs, fun posixpath_normcase/1},
        <<"normpath">> => {py_native_varargs, fun posixpath_normpath/1},
        <<"expanduser">> => {py_native_varargs, fun posixpath_expanduser/1},
        <<"isabs">> => {py_native_varargs, fun posixpath_isabs/1},
        <<"exists">> => {py_native_varargs, fun posixpath_exists/1},
        <<"isdir">> => {py_native_varargs, fun posixpath_isdir/1},
        <<"isfile">> => {py_native_varargs, fun posixpath_isfile/1}
    }.

posixpath_join([]) ->
    erlang:error({arity_error, {posixpath_join, 0}});
posixpath_join(Parts) ->
    unicode:characters_to_binary(
        filename:join([binary_to_list(normalize_name(Part)) || Part <- Parts])
    ).

posixpath_dirname([Path]) ->
    unicode:characters_to_binary(filename:dirname(binary_to_list(normalize_name(Path))));
posixpath_dirname(Args) ->
    erlang:error({arity_error, {posixpath_dirname, length(Args)}}).

posixpath_basename([Path]) ->
    unicode:characters_to_binary(filename:basename(binary_to_list(normalize_name(Path))));
posixpath_basename(Args) ->
    erlang:error({arity_error, {posixpath_basename, length(Args)}}).

posixpath_split([Path0]) ->
    Path = normalize_name(Path0),
    case rfind_index(Path, <<"/">>) of
        none ->
            {<<>>, Path};
        Index ->
            SplitAt = Index + 1,
            Head0 = binary:part(Path, 0, SplitAt),
            Tail = binary:part(Path, SplitAt, byte_size(Path) - SplitAt),
            {rstrip_path_separators(Head0), Tail}
    end;
posixpath_split(Args) ->
    erlang:error({arity_error, {posixpath_split, length(Args)}}).

posixpath_splitext([Path0]) ->
    Path = normalize_name(Path0),
    NameStart =
        case rfind_index(Path, <<"/">>) of
            none -> 0;
            Slash -> Slash + 1
        end,
    case rfind_index(Path, <<".">>) of
        Dot when is_integer(Dot), Dot > NameStart ->
            {binary:part(Path, 0, Dot), binary:part(Path, Dot, byte_size(Path) - Dot)};
        _ ->
            {Path, <<>>}
    end;
posixpath_splitext(Args) ->
    erlang:error({arity_error, {posixpath_splitext, length(Args)}}).

posixpath_commonprefix([Paths]) ->
    case [normalize_name(Path) || Path <- pyrlang_iter:values(Paths)] of
        [] -> <<>>;
        [First | Rest] -> common_binary_prefix(Rest, First)
    end;
posixpath_commonprefix(Args) ->
    erlang:error({arity_error, {posixpath_commonprefix, length(Args)}}).

common_binary_prefix([], Prefix) ->
    Prefix;
common_binary_prefix([Path | Rest], Prefix) ->
    common_binary_prefix(Rest, common_binary_prefix_pair(Prefix, Path)).

common_binary_prefix_pair(Prefix, Path) ->
    common_binary_prefix_pair(Prefix, Path, 0, min(byte_size(Prefix), byte_size(Path))).

common_binary_prefix_pair(Prefix, _Path, Size, Size) ->
    binary:part(Prefix, 0, Size);
common_binary_prefix_pair(Prefix, Path, Index, Size) ->
    case {binary:at(Prefix, Index), binary:at(Path, Index)} of
        {Byte, Byte} -> common_binary_prefix_pair(Prefix, Path, Index + 1, Size);
        _ -> binary:part(Prefix, 0, Index)
    end.

posixpath_abspath([Path]) ->
    unicode:characters_to_binary(filename:absname(binary_to_list(normalize_name(Path))));
posixpath_abspath(Args) ->
    erlang:error({arity_error, {posixpath_abspath, length(Args)}}).

posixpath_realpath([Path]) ->
    posix_normpath(posixpath_abspath([Path]));
posixpath_realpath(Args) ->
    erlang:error({arity_error, {posixpath_realpath, length(Args)}}).

posixpath_relpath([Path]) ->
    posixpath_relpath([Path, <<".">>]);
posixpath_relpath([Path, Start]) ->
    PathParts = relpath_parts(posixpath_abspath([Path])),
    StartParts = relpath_parts(posixpath_abspath([Start])),
    {PathRest, StartRest} = drop_common_prefix(PathParts, StartParts),
    UpParts = lists:duplicate(length(StartRest), <<"..">>),
    case UpParts ++ PathRest of
        [] -> <<".">>;
        Parts -> join_binary(Parts, <<"/">>)
    end;
posixpath_relpath(Args) ->
    erlang:error({arity_error, {posixpath_relpath, length(Args)}}).

relpath_parts(Path0) ->
    Path = posix_normpath(Path0),
    [Part || Part <- binary:split(Path, <<"/">>, [global]), Part =/= <<>>].

drop_common_prefix([Head | RestA], [Head | RestB]) ->
    drop_common_prefix(RestA, RestB);
drop_common_prefix(RestA, RestB) ->
    {RestA, RestB}.

posixpath_normcase([Path]) ->
    normalize_name(Path);
posixpath_normcase(Args) ->
    erlang:error({arity_error, {posixpath_normcase, length(Args)}}).

posixpath_normpath([Path]) ->
    posix_normpath(normalize_name(Path));
posixpath_normpath(Args) ->
    erlang:error({arity_error, {posixpath_normpath, length(Args)}}).

posixpath_expanduser([<<"~">>]) ->
    home_dir();
posixpath_expanduser([<<"~/", Rest/binary>>]) ->
    Home = home_dir(),
    <<Home/binary, "/", Rest/binary>>;
posixpath_expanduser([Path]) ->
    normalize_name(Path);
posixpath_expanduser(Args) ->
    erlang:error({arity_error, {posixpath_expanduser, length(Args)}}).

posixpath_isabs([<<"/", _Rest/binary>>]) ->
    true;
posixpath_isabs([_Path]) ->
    false;
posixpath_isabs(Args) ->
    erlang:error({arity_error, {posixpath_isabs, length(Args)}}).

posixpath_exists([Path]) ->
    PathList = binary_to_list(normalize_name(Path)),
    filelib:is_file(PathList) orelse filelib:is_dir(PathList);
posixpath_exists(Args) ->
    erlang:error({arity_error, {posixpath_exists, length(Args)}}).

posixpath_isdir([Path]) ->
    filelib:is_dir(binary_to_list(normalize_name(Path)));
posixpath_isdir(Args) ->
    erlang:error({arity_error, {posixpath_isdir, length(Args)}}).

posixpath_isfile([Path]) ->
    filelib:is_file(binary_to_list(normalize_name(Path)));
posixpath_isfile(Args) ->
    erlang:error({arity_error, {posixpath_isfile, length(Args)}}).

rfind_index(Binary, Pattern) ->
    case binary:matches(Binary, Pattern) of
        [] ->
            none;
        Matches ->
            {Index, _Length} = lists:last(Matches),
            Index
    end.

rstrip_path_separators(Head) ->
    case all_path_separators(Head) of
        true -> Head;
        false -> rstrip_path_separators_nonroot(Head)
    end.

all_path_separators(<<>>) ->
    false;
all_path_separators(Bin) ->
    lists:all(fun(Char) -> Char =:= $/ end, binary_to_list(Bin)).

rstrip_path_separators_nonroot(<<>>) ->
    <<>>;
rstrip_path_separators_nonroot(Bin) ->
    Size = byte_size(Bin),
    case binary:at(Bin, Size - 1) of
        $/ -> rstrip_path_separators_nonroot(binary:part(Bin, 0, Size - 1));
        _ -> Bin
    end.

posix_normpath(Path0) ->
    Path = normalize_name(Path0),
    Absolute =
        case Path of
            <<"/", _/binary>> -> true;
            _ -> false
        end,
    Parts = binary:split(Path, <<"/">>, [global]),
    Kept = lists:reverse(
        lists:foldl(fun(Part, Acc) -> normpath_part(Part, Acc, Absolute) end, [], Parts)
    ),
    Joined = join_binary(Kept, <<"/">>),
    case {Absolute, Joined} of
        {true, <<>>} -> <<"/">>;
        {true, _} -> <<"/", Joined/binary>>;
        {false, <<>>} -> <<".">>;
        {false, _} -> Joined
    end.

normpath_part(<<>>, Acc, _Absolute) ->
    Acc;
normpath_part(<<".">>, Acc, _Absolute) ->
    Acc;
normpath_part(<<"..">>, [], true) ->
    [];
normpath_part(<<"..">>, [<<"..">> | _Rest] = Acc, false) ->
    [<<"..">> | Acc];
normpath_part(<<"..">>, [_Head | Rest], _Absolute) ->
    Rest;
normpath_part(Part, Acc, _Absolute) ->
    [Part | Acc].

home_dir() ->
    case os:getenv("HOME") of
        false -> <<"/">>;
        Home -> unicode:characters_to_binary(Home)
    end.

normalize_env(Values) when is_map(Values) ->
    maps:from_list([
        {normalize_name(Key), normalize_name(Value)}
     || {Key, Value} <- maps:to_list(Values)
    ]);
normalize_env(Values) when is_list(Values) ->
    maps:from_list([{normalize_name(Key), normalize_name(Value)} || {Key, Value} <- Values]).

normalize_name(Name) when is_binary(Name) ->
    Name;
normalize_name(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
normalize_name(Name) when is_list(Name) ->
    unicode:characters_to_binary(Name);
normalize_name({py_ref, _} = Name) ->
    case string_subclass_value(Name) of
        {ok, Value} ->
            Value;
        error ->
            case pathlike_name(Name) of
                {ok, Value} -> Value;
                error -> erlang:error({type_error, {expected_string, Name}})
            end
    end.

normalize_bytes(Value) when is_binary(Value); is_atom(Value); is_list(Value) ->
    normalize_name(Value);
normalize_bytes({py_ref, _} = Ref) ->
    case string_subclass_value(Ref) of
        {ok, Value} ->
            Value;
        error ->
            case bytes_method_value(Ref) of
                {ok, Value} ->
                    Value;
                error ->
                    trace_normalize_bytes_error(Ref),
                    erlang:error({type_error, {expected_bytes, Ref}})
            end
    end.

trace_normalize_bytes_error(Ref) ->
    case os:getenv("PYRLANG_TRACE_BYTES") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_BYTES_REF type=~p class=~p attrs=~p stack=~p~n",
                [
                    safe_heap_type(Ref),
                    safe_class_name(Ref),
                    safe_attr_keys(Ref),
                    pyrlang_eval:trace_function_stack()
                ]
            )
    end.

safe_heap_type(Ref) ->
    try
        pyrlang_heap:type(Ref)
    catch
        _:_ -> unknown
    end.

safe_class_name(Ref) ->
    try
        pyrlang_object:class_name(pyrlang_builtins:object_class(Ref))
    catch
        _:_ -> unknown
    end.

safe_attr_keys(Ref) ->
    try
        case pyrlang_heap:data(Ref) of
            #{attrs := Attrs} when is_map(Attrs) -> maps:keys(Attrs);
            _ -> []
        end
    catch
        _:_ -> []
    end.

bytes_method_value({py_ref, _} = Ref) ->
    case call_optional_zero_arg(Ref, <<"__bytes__">>) of
        {ok, Value} ->
            normalize_bytes_result(Value);
        error ->
            case call_optional_zero_arg(Ref, <<"tobytes">>) of
                {ok, Value} -> normalize_bytes_result(Value);
                error -> error
            end
    end.

call_optional_zero_arg({py_ref, _} = Ref, Attr) ->
    try pyrlang_object:get_attr(Ref, Attr) of
        Method -> {ok, pyrlang_eval:call(Method, [])}
    catch
        _:_ -> error
    end.

normalize_bytes_result(Value) when is_binary(Value) ->
    {ok, Value};
normalize_bytes_result(Value) when is_list(Value) ->
    {ok, unicode:characters_to_binary(Value)};
normalize_bytes_result({py_ref, _} = Ref) ->
    case string_subclass_value(Ref) of
        {ok, Value} -> {ok, Value};
        error -> error
    end;
normalize_bytes_result(_Value) ->
    error.

string_subclass_value({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            case is_string_subclass_instance(Ref) of
                true ->
                    Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
                    case maps:find(<<"__pyrlang_value__">>, Attrs) of
                        {ok, Value} when is_binary(Value) -> {ok, Value};
                        _ -> error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end;
string_subclass_value(_Other) ->
    error.

is_string_subclass_instance({py_ref, _} = Ref) ->
    Class = pyrlang_builtins:object_class(Ref),
    lists:any(
        fun(MroClass) -> class_named(MroClass, <<"str">>) end,
        pyrlang_object:mro(Class)
    ).

class_named({py_ref, _} = Class, Name) ->
    try
        pyrlang_heap:type(Class) =:= class andalso pyrlang_object:class_name(Class) =:= Name
    catch
        _:_ -> false
    end;
class_named(_Other, _Name) ->
    false.

pathlike_name({py_ref, _} = Name) ->
    try pyrlang_object:get_attr(Name, <<"__fspath__">>) of
        Fspath ->
            Value = pyrlang_eval:call(Fspath, []),
            case Value of
                Bin when is_binary(Bin) -> {ok, Bin};
                List when is_list(List) -> {ok, unicode:characters_to_binary(List)};
                _ -> error
            end
    catch
        _:_ -> error
    end.

normalize_attr(Attr) ->
    normalize_name(Attr).

to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_list(Value) when is_list(Value) ->
    Value.
