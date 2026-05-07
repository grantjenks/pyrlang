-module(pyrlang_cli).

-export([main/1, run/1, parse_args/1]).

-spec main([string()]) -> no_return().
main(Args) ->
    case run(Args) of
        {ok, none} ->
            halt(0);
        {ok, Value} ->
            io:format("~s~n", [format_value(Value)]),
            halt(0);
        {error, Reason} ->
            io:format(standard_error, "pyrlang: ~s~n", [format_value(Reason)]),
            halt(1)
    end.

-spec run([string() | binary()]) -> {ok, term()} | {error, term()}.
run(Args) ->
    case parse_args(Args) of
        {ok, #{file := File, file_args := FileArgs, path := ExtraPath}} ->
            FilePath = to_list(File),
            ok = pyrlang:set_path(ExtraPath ++ [filename:dirname(FilePath) | pyrlang_module:path()]),
            case pyrlang:run_file(FilePath, FileArgs) of
                {ok, Value, _Env} -> {ok, Value};
                {error, Reason} -> {error, Reason}
            end;
        {ok, #{module := Module, module_args := ModuleArgs, path := ExtraPath}} ->
            run_module(Module, ModuleArgs, ExtraPath);
        {error, Reason} ->
            {error, Reason}
    end.

-spec parse_args([string() | binary()]) -> {ok, map()} | {error, term()}.
parse_args(Args) ->
    parse_args([to_list(Arg) || Arg <- Args], #{path => []}, undefined).

parse_args([], _Options, undefined) ->
    {error, usage};
parse_args(["-m", Module | Rest], Options, undefined) ->
    {ok, Options#{module => Module, module_args => Rest}};
parse_args(["-m" | _Rest], _Options, _File) ->
    {error, missing_module};
parse_args(["-I", Path | Rest], Options, File) ->
    parse_args(Rest, add_path(Path, Options), File);
parse_args(["--path", Path | Rest], Options, File) ->
    parse_args(Rest, add_path(Path, Options), File);
parse_args([Arg | Rest], Options, File) ->
    case split_option(Arg, "--path=") of
        {ok, Path} ->
            parse_args(Rest, add_path(Path, Options), File);
        error ->
            case {is_option(Arg), File} of
                {true, _} -> {error, {unknown_option, Arg}};
                {false, undefined} -> {ok, Options#{file => Arg, file_args => Rest}};
                {false, _} -> {error, {multiple_files, File, Arg}}
            end
    end.

add_path(Path, Options) ->
    Options#{path := maps:get(path, Options, []) ++ [Path]}.

split_option(Arg, Prefix) ->
    case lists:prefix(Prefix, Arg) of
        true -> {ok, lists:nthtail(length(Prefix), Arg)};
        false -> error
    end.

is_option([$- | _]) ->
    true;
is_option(_Arg) ->
    false.

run_module(Module, ModuleArgs, ExtraPath) ->
    ok = pyrlang:start(),
    ok = pyrlang:set_path(ExtraPath ++ pyrlang_module:path()),
    try
        {Value, _Env} = pyrlang_module:run_as_main(Module, ModuleArgs),
        {ok, Value}
    catch
        throw:{py_exception, Exception} ->
            {error, Exception};
        error:Reason ->
            {error, Reason}
    end.

format_value(Value) when is_map(Value) ->
    case pyrlang_exception:is_exception(Value) of
        true ->
            Type = pyrlang_exception:exception_type(Value),
            Message = pyrlang_exception:message(Value),
            case Message of
                <<>> -> Type;
                _ -> <<Type/binary, ": ", Message/binary>>
            end;
        false ->
            unicode:characters_to_binary(io_lib:format("~p", [Value]))
    end;
format_value(Value) when is_binary(Value) ->
    Value;
format_value({py_ref, _} = Value) ->
    case pyrlang_exception:is_exception(Value) of
        true ->
            Type = pyrlang_exception:exception_type(Value),
            Message = pyrlang_exception:message(Value),
            case Message of
                <<>> -> Type;
                _ -> <<Type/binary, ": ", Message/binary>>
            end;
        false ->
            unicode:characters_to_binary(io_lib:format("~p", [Value]))
    end;
format_value(Value) when is_integer(Value) ->
    integer_to_binary(Value);
format_value(Value) when is_float(Value) ->
    unicode:characters_to_binary(float_to_list(Value));
format_value(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
format_value(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_list(Value) when is_list(Value) ->
    Value.
