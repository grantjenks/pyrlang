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
        {ok, #{shell := true, path := ExtraPath}} ->
            run_shell(ExtraPath);
        {ok, #{command := Command, command_args := CommandArgs, path := ExtraPath}} ->
            run_command(Command, CommandArgs, ExtraPath);
        {ok, #{file := File, file_args := FileArgs, path := ExtraPath}} ->
            FilePath = to_list(File),
            ok = pyrlang:set_path(
                ExtraPath ++ [filename:dirname(FilePath) | pyrlang_module:path()]
            ),
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

parse_args([], Options, undefined) ->
    {ok, Options#{shell => true}};
parse_args(["-c", Command | Rest], Options, undefined) ->
    {ok, Options#{command => Command, command_args => Rest}};
parse_args(["-c" | _Rest], _Options, _File) ->
    {error, missing_command};
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

run_command(Command, CommandArgs, ExtraPath) ->
    ok = pyrlang:start(),
    ok = pyrlang:set_path(ExtraPath ++ pyrlang_module:path()),
    ok = pyrlang_module:set_argv(["-c" | CommandArgs]),
    case pyrlang_parser:parse_module(Command) of
        {ok, Ast} ->
            Env0 = (pyrlang_builtins:env())#{
                <<"__name__">> => <<"__main__">>,
                <<"__package__">> => none
            },
            try
                {Value, _Env} = pyrlang_eval:eval_module(Ast, Env0),
                {ok, Value}
            catch
                throw:{py_exception, Exception} ->
                    {error, Exception};
                error:Reason ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

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

run_shell(ExtraPath) ->
    ok = pyrlang:start(),
    ok = pyrlang:set_path(ExtraPath ++ pyrlang_module:path()),
    ok = pyrlang_module:set_argv([""]),
    Env0 = (pyrlang_builtins:env())#{
        <<"__name__">> => <<"__main__">>,
        <<"__package__">> => none
    },
    repl_loop(Env0).

repl_loop(Env) ->
    case read_repl_line("pyr> ") of
        eof ->
            {ok, none};
        Line ->
            case string:trim(Line) of
                "" ->
                    repl_loop(Env);
                "exit()" ->
                    {ok, none};
                "quit()" ->
                    {ok, none};
                _ ->
                    case read_repl_source([Line]) of
                        eof ->
                            {ok, none};
                        {ok, Kind, Ast} ->
                            case eval_repl_ast(Kind, Ast, Env) of
                                {ok, Env1} ->
                                    repl_loop(Env1);
                                {error, Reason} ->
                                    io:format(standard_error, "~s~n", [format_value(Reason)]),
                                    repl_loop(Env)
                            end;
                        {error, Reason} ->
                            io:format(standard_error, "~s~n", [format_value(Reason)]),
                            repl_loop(Env)
                    end
            end
    end.

read_repl_source(Lines) ->
    Source = lists:flatten(lists:reverse(Lines)),
    case parse_repl_source(Source) of
        {ok, _Kind, _Ast} = Ok ->
            Ok;
        {incomplete, _Reason} ->
            case read_repl_line("...> ") of
                eof -> eof;
                Line -> read_repl_source([Line | Lines])
            end;
        {error, _Reason} = Error ->
            Error
    end.

read_repl_line(Prompt) ->
    case io:get_line(Prompt) of
        eof -> eof;
        Line -> Line
    end.

parse_repl_source(Source) ->
    case pyrlang_parser:parse_expr(Source) of
        {ok, Ast} ->
            {ok, expr, Ast};
        {error, _ExprReason} ->
            case pyrlang_parser:parse_module(Source) of
                {ok, Ast} ->
                    {ok, module, Ast};
                {error, Reason} ->
                    case repl_needs_more_input(Source, Reason) of
                        true -> {incomplete, Reason};
                        false -> {error, Reason}
                    end
            end
    end.

repl_needs_more_input(Source, Reason) ->
    source_has_open_group(Source) orelse
        source_ends_with_backslash(Source) orelse
        incomplete_block_error(Reason).

source_has_open_group(Source) ->
    group_balance(Source, 0) > 0.

group_balance([], Balance) ->
    Balance;
group_balance([Char | Rest], Balance) when Char =:= $(; Char =:= $[; Char =:= ${ ->
    group_balance(Rest, Balance + 1);
group_balance([Char | Rest], Balance) when Char =:= $); Char =:= $]; Char =:= $} ->
    group_balance(Rest, max(0, Balance - 1));
group_balance([_Char | Rest], Balance) ->
    group_balance(Rest, Balance).

source_ends_with_backslash(Source) ->
    case string:trim(Source, trailing) of
        [] -> false;
        Trimmed -> lists:last(Trimmed) =:= $\\
    end.

incomplete_block_error({expected_indented_block, _Line}) ->
    true;
incomplete_block_error({bad_assignment, _Line, unexpected_end}) ->
    true;
incomplete_block_error({bad_expression_statement, _Line, {expected, comma_or_rparen}}) ->
    true;
incomplete_block_error(_Reason) ->
    false.

eval_repl_ast(expr, Ast, Env0) ->
    try
        {Value, Env1} = pyrlang_eval:eval_expr(Ast, Env0),
        case Value of
            none -> ok;
            _ -> io:format("~s~n", [pyrlang_builtins:builtin_repr(Value)])
        end,
        {ok, pyrlang_eval:bind_module_globals(Env1)}
    catch
        throw:{py_exception, Exception} ->
            {error, Exception};
        error:Reason ->
            {error, Reason}
    end;
eval_repl_ast(module, Ast, Env0) ->
    try
        {_Value, Env1} = pyrlang_eval:eval_module(Ast, Env0),
        {ok, Env1}
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
