-module(pyrlang).

-export([start/0, eval_expr/1, run_string/1, set_path/1, run_file/1, run_file/2]).

-spec start() -> ok.
start() ->
    _ = pyrlang_heap:ensure(),
    ok.

-spec eval_expr(binary() | string()) -> {ok, term()} | {error, term()}.
eval_expr(Source) ->
    start(),
    case pyrlang_parser:parse_expr(Source) of
        {ok, Ast} ->
            try {ok, pyrlang_eval:eval_expr(Ast)}
            catch
                throw:{py_exception, Exception} -> {error, Exception}
            end;
        {error, Reason} -> {error, Reason}
    end.

-spec run_string(binary() | string()) -> {ok, term(), map()} | {error, term()}.
run_string(Source) ->
    start(),
    case pyrlang_parser:parse_module(Source) of
        {ok, Module} ->
            try
                {Value, Env} = pyrlang_eval:eval_module(Module),
                {ok, Value, Env}
            catch
                throw:{py_exception, Exception} -> {error, Exception}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec set_path([binary() | string()]) -> ok.
set_path(Paths) ->
    pyrlang_module:set_path(Paths).

-spec run_file(binary() | string()) -> {ok, term(), map()} | {error, term()}.
run_file(Path0) ->
    run_file(Path0, []).

-spec run_file(binary() | string(), [binary() | string()]) -> {ok, term(), map()} | {error, term()}.
run_file(Path0, Args) ->
    Path =
        case Path0 of
            Bin when is_binary(Bin) -> binary_to_list(Bin);
            List when is_list(List) -> List
        end,
    case file:read_file(Path) of
        {ok, Source} ->
            start(),
            ok = pyrlang_module:set_argv([Path | Args]),
            case pyrlang_parser:parse_module(Source) of
                {ok, Module} ->
                    Env0 = (pyrlang_builtins:env())#{
                        <<"__name__">> => <<"__main__">>,
                        <<"__file__">> => unicode:characters_to_binary(Path),
                        <<"__package__">> => none
                    },
                    try
                        {Value, Env} = pyrlang_eval:eval_module(Module, Env0),
                        {ok, Value, Env}
                    catch
                        throw:{py_exception, Exception} -> {error, Exception}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.
