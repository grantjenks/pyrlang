-module(pyrlang_parser).

-export([parse_expr/1, parse_module/1, tokens/1]).

-spec parse_expr(binary() | string()) -> {ok, term()} | {error, term()}.
parse_expr(Source) ->
    try
        Toks = tokens(Source),
        case parse_expression(Toks) of
            {Ast, []} -> {ok, Ast};
            {_Ast, Rest} -> {error, {unexpected_tokens, Rest}}
        end
    catch
        throw:Reason -> {error, Reason}
    end.

-spec parse_module(binary() | string()) -> {ok, term()} | {error, term()}.
parse_module(Source) when is_binary(Source) ->
    parse_module(unicode:characters_to_list(Source));
parse_module(Source) ->
    try
        Lines = logical_lines(string:split(Source, "\n", all)),
        {Statements, []} = parse_block(Lines, 0),
        {ok, {module, Statements}}
    catch
        throw:Reason -> {error, Reason}
    end.

-spec tokens(binary() | string()) -> [term()].
tokens(Source) when is_binary(Source) ->
    tokens(unicode:characters_to_list(Source));
tokens(Source) ->
    combine_adjacent_string_tokens(lex(Source, [])).

parse_expression(Tokens) ->
    {Expr, Rest} = parse_lambda(Tokens),
    case Rest of
        [comma | Rest1] -> parse_bare_tuple_literal(Rest1, [Expr]);
        _ -> {Expr, Rest}
    end.

combine_adjacent_string_tokens(Tokens) ->
    combine_adjacent_string_tokens(Tokens, []).

combine_adjacent_string_tokens([{str, Left}, {str, Right} | Rest], Acc) ->
    combine_adjacent_string_tokens([{str, <<Left/binary, Right/binary>>} | Rest], Acc);
combine_adjacent_string_tokens([{fstr, Left}, {fstr, Right} | Rest], Acc) ->
    combine_adjacent_string_tokens([{fstr, <<Left/binary, Right/binary>>} | Rest], Acc);
combine_adjacent_string_tokens([{str, Left}, {fstr, Right} | Rest], Acc) ->
    combine_adjacent_string_tokens([{fstr, <<Left/binary, Right/binary>>} | Rest], Acc);
combine_adjacent_string_tokens([{fstr, Left}, {str, Right} | Rest], Acc) ->
    combine_adjacent_string_tokens([{fstr, <<Left/binary, Right/binary>>} | Rest], Acc);
combine_adjacent_string_tokens([{bytes, Left}, {bytes, Right} | Rest], Acc) ->
    combine_adjacent_string_tokens([{bytes, <<Left/binary, Right/binary>>} | Rest], Acc);
combine_adjacent_string_tokens([Token | Rest], Acc) ->
    combine_adjacent_string_tokens(Rest, [Token | Acc]);
combine_adjacent_string_tokens([], Acc) ->
    lists:reverse(Acc).

keep_line(Line) ->
    Trimmed = string:trim(Line),
    Trimmed =/= "" andalso not lists:prefix("#", Trimmed).

logical_lines(Lines) ->
    Prepared0 = strip_standalone_triple_strings(join_backslash_continuation_lines(join_multiline_triple_strings(Lines))),
    WithoutComments = [strip_inline_comment(Line) || Line <- Prepared0],
    Prepared = join_continuation_lines(WithoutComments),
    [{indent(Line), string:trim(Line)} || Line <- Prepared, keep_line(Line)].

join_multiline_triple_strings(Lines) ->
    join_multiline_triple_strings(Lines, none, []).

join_multiline_triple_strings([], none, Acc) ->
    lists:reverse(Acc);
join_multiline_triple_strings([], {Line, _Quote}, Acc) ->
    lists:reverse([Line | Acc]);
join_multiline_triple_strings([Line | Rest], none, Acc) ->
    case unclosed_triple_quote(Line) of
        {open, Quote} -> join_multiline_triple_strings(Rest, {Line, Quote}, Acc);
        none -> join_multiline_triple_strings(Rest, none, [Line | Acc])
    end;
join_multiline_triple_strings([Line | Rest], {AccLine, Quote}, Acc) ->
    Joined = AccLine ++ "\n" ++ Line,
    case contains_triple_quote(Line, Quote) of
        true -> join_multiline_triple_strings(Rest, none, [Joined | Acc]);
        false -> join_multiline_triple_strings(Rest, {Joined, Quote}, Acc)
    end.

unclosed_triple_quote(Line) ->
    case first_triple_quote(Line) of
        {Quote, AfterOpen} ->
            case contains_triple_quote(AfterOpen, Quote) of
                true -> none;
                false -> {open, Quote}
            end;
        none ->
            none
    end.

first_triple_quote(Text) ->
    first_triple_quote(Text, none).

first_triple_quote([$", $", $" | Rest], none) ->
    {"\"\"\"", Rest};
first_triple_quote([$', $', $' | Rest], none) ->
    {"'''", Rest};
first_triple_quote([$\\, _Escaped | Rest], Quote) when Quote =/= none ->
    first_triple_quote(Rest, Quote);
first_triple_quote([Quote | Rest], Quote) ->
    first_triple_quote(Rest, none);
first_triple_quote([$# | _Rest], none) ->
    none;
first_triple_quote([$" | Rest], none) ->
    first_triple_quote(Rest, $");
first_triple_quote([$' | Rest], none) ->
    first_triple_quote(Rest, $');
first_triple_quote([_Ch | Rest], Quote) ->
    first_triple_quote(Rest, Quote);
first_triple_quote([], _Quote) ->
    none.

join_backslash_continuation_lines(Lines) ->
    join_backslash_continuation_lines(Lines, none, []).

join_backslash_continuation_lines([], none, Acc) ->
    lists:reverse(Acc);
join_backslash_continuation_lines([], {Line}, Acc) ->
    lists:reverse([Line | Acc]);
join_backslash_continuation_lines([Line | Rest], none, Acc) ->
    case explicit_continuation_line(Line) of
        {true, Prefix} -> join_backslash_continuation_lines(Rest, {Prefix}, Acc);
        false -> join_backslash_continuation_lines(Rest, none, [Line | Acc])
    end;
join_backslash_continuation_lines([Line | Rest], {AccLine}, Acc) ->
    Joined0 = AccLine ++ " " ++ string:trim(Line),
    case explicit_continuation_line(Joined0) of
        {true, Prefix} -> join_backslash_continuation_lines(Rest, {Prefix}, Acc);
        false -> join_backslash_continuation_lines(Rest, none, [Joined0 | Acc])
    end.

explicit_continuation_line(Line) ->
    Trimmed = string:trim(Line, trailing),
    case Trimmed of
        [] ->
            false;
        _ ->
            case lists:last(Trimmed) of
                $\\ -> {true, lists:droplast(Trimmed)};
                _ -> false
            end
    end.

strip_inline_comment(Line) ->
    strip_inline_comment(Line, none, []).

strip_inline_comment([], _Quote, Acc) ->
    lists:reverse(Acc);
strip_inline_comment([$", $", $" | Rest], none, Acc) ->
    strip_inline_comment(Rest, {triple, $"}, [$", $", $" | Acc]);
strip_inline_comment([$', $', $' | Rest], none, Acc) ->
    strip_inline_comment(Rest, {triple, $'}, [$', $', $' | Acc]);
strip_inline_comment([Quote, Quote, Quote | Rest], {triple, Quote}, Acc) ->
    strip_inline_comment(Rest, none, [Quote, Quote, Quote | Acc]);
strip_inline_comment([$\\, Escaped | Rest], Quote, Acc) when Quote =/= none ->
    strip_inline_comment(Rest, Quote, [Escaped, $\\ | Acc]);
strip_inline_comment([Quote | Rest], Quote, Acc) ->
    strip_inline_comment(Rest, none, [Quote | Acc]);
strip_inline_comment([$" | Rest], none, Acc) ->
    strip_inline_comment(Rest, $", [$" | Acc]);
strip_inline_comment([$' | Rest], none, Acc) ->
    strip_inline_comment(Rest, $', [$' | Acc]);
strip_inline_comment([$# | _Rest], none, Acc) ->
    lists:reverse(Acc);
strip_inline_comment([Ch | Rest], Quote, Acc) ->
    strip_inline_comment(Rest, Quote, [Ch | Acc]).

join_continuation_lines(Lines) ->
    join_continuation_lines(Lines, none, []).

join_continuation_lines([], none, Acc) ->
    lists:reverse(Acc);
join_continuation_lines([], {Line, _Balance}, Acc) ->
    lists:reverse([Line | Acc]);
join_continuation_lines([Line | Rest], none, Acc) ->
    Balance = bracket_balance(Line),
    case Balance > 0 of
        true -> join_continuation_lines(Rest, {Line, Balance}, Acc);
        false -> join_continuation_lines(Rest, none, [Line | Acc])
    end;
join_continuation_lines([Line | Rest], {AccLine, Balance0}, Acc) ->
    Joined = AccLine ++ " " ++ string:trim(Line),
    Balance = Balance0 + bracket_balance(Line),
    case Balance > 0 of
        true -> join_continuation_lines(Rest, {Joined, Balance}, Acc);
        false -> join_continuation_lines(Rest, none, [Joined | Acc])
    end.

bracket_balance(Line) ->
    bracket_balance(Line, 0, none).

bracket_balance([], Balance, _Quote) ->
    Balance;
bracket_balance([$", $", $" | Rest], Balance, none) ->
    bracket_balance_triple(Rest, Balance, $");
bracket_balance([$', $', $' | Rest], Balance, none) ->
    bracket_balance_triple(Rest, Balance, $');
bracket_balance([$\\, _Escaped | Rest], Balance, Quote) when Quote =/= none ->
    bracket_balance(Rest, Balance, Quote);
bracket_balance([Quote | Rest], Balance, Quote) ->
    bracket_balance(Rest, Balance, none);
bracket_balance([$" | Rest], Balance, none) ->
    bracket_balance(Rest, Balance, $");
bracket_balance([$' | Rest], Balance, none) ->
    bracket_balance(Rest, Balance, $');
bracket_balance([$# | _Rest], Balance, none) ->
    Balance;
bracket_balance([Ch | Rest], Balance, none) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    bracket_balance(Rest, Balance + 1, none);
bracket_balance([Ch | Rest], Balance, none) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    bracket_balance(Rest, Balance - 1, none);
bracket_balance([_Ch | Rest], Balance, Quote) ->
    bracket_balance(Rest, Balance, Quote).

bracket_balance_triple([], Balance, _Quote) ->
    Balance;
bracket_balance_triple([Quote, Quote, Quote | Rest], Balance, Quote) ->
    bracket_balance(Rest, Balance, none);
bracket_balance_triple([_Ch | Rest], Balance, Quote) ->
    bracket_balance_triple(Rest, Balance, Quote).

strip_standalone_triple_strings(Lines) ->
    strip_standalone_triple_strings(Lines, none, 0, []).

strip_standalone_triple_strings([], _OpenQuote, _Balance, Acc) ->
    lists:reverse(Acc);
strip_standalone_triple_strings([Line | Rest], none, Balance0, Acc) ->
    Trimmed = string:trim(Line),
    case {Balance0, standalone_triple_quote_start(Trimmed)} of
        {0, {multi, Quote}} ->
            strip_standalone_triple_strings(Rest, Quote, 0, [docstring_pass_line(Line) | Acc]);
        {0, single} ->
            strip_standalone_triple_strings(Rest, none, 0, [docstring_pass_line(Line) | Acc]);
        _ ->
            Balance1 = Balance0 + bracket_balance(Line),
            strip_standalone_triple_strings(Rest, none, Balance1, [Line | Acc])
    end;
strip_standalone_triple_strings([Line | Rest], Quote, Balance, Acc) ->
    case contains_triple_quote(string:trim(Line), Quote) of
        true -> strip_standalone_triple_strings(Rest, none, Balance, Acc);
        false -> strip_standalone_triple_strings(Rest, Quote, Balance, Acc)
    end.

standalone_triple_quote_start(Line) ->
    standalone_triple_quote_start_unprefixed(strip_string_prefix(Line)).

standalone_triple_quote_start_unprefixed([$", $", $" | Rest]) ->
    case contains_triple_quote(Rest, "\"\"\"") of
        true -> single;
        false -> {multi, "\"\"\""}
    end;
standalone_triple_quote_start_unprefixed([$', $', $' | Rest]) ->
    case contains_triple_quote(Rest, "'''") of
        true -> single;
        false -> {multi, "'''"}
    end;
standalone_triple_quote_start_unprefixed(_Line) ->
    none.

contains_triple_quote(Text, Quote) ->
    string:str(Text, Quote) > 0.

strip_string_prefix([Ch | Rest]) when Ch =:= $r; Ch =:= $R; Ch =:= $u; Ch =:= $U; Ch =:= $b; Ch =:= $B; Ch =:= $f; Ch =:= $F ->
    strip_string_prefix(Rest);
strip_string_prefix(Line) ->
    Line.

docstring_pass_line(Line) ->
    leading_indent(Line) ++ "pass".

leading_indent([$\s | Rest]) ->
    [$\s | leading_indent(Rest)];
leading_indent(Line) ->
    case Line of
        [$\t | _Rest] -> throw(tabs_are_not_supported_for_indentation);
        _ -> []
    end.

indent(Line) ->
    indent(Line, 0).

indent([$\s | Rest], Count) ->
    indent(Rest, Count + 1);
indent([$\t | _Rest], _Count) ->
    throw(tabs_are_not_supported_for_indentation);
indent(_Line, Count) ->
    Count.

parse_block([], _Indent) ->
    {[], []};
parse_block([{Indent, _Text} | _Rest] = Lines, CurrentIndent) when Indent < CurrentIndent ->
    {[], Lines};
parse_block([{Indent, [$@ | _DecoratorText]} | _Rest] = Lines, CurrentIndent) when Indent =:= CurrentIndent ->
    {Decorators, [{Indent, Text} | Rest1]} = parse_decorator_lines(Lines, CurrentIndent, []),
    {Statement0, Rest2} = parse_statement(Text, Rest1, CurrentIndent),
    Statement = apply_decorators_to_statement(Decorators, Statement0),
    {Statements, Rest3} = parse_block(Rest2, CurrentIndent),
    {[Statement | Statements], Rest3};
parse_block([{Indent, Text} | Rest], CurrentIndent) when Indent =:= CurrentIndent ->
    case simple_statement_parts(Text) of
        [Text] ->
            {Statement, Rest1} = parse_statement(Text, Rest, CurrentIndent),
            {Statements, Rest2} = parse_block(Rest1, CurrentIndent),
            {[Statement | Statements], Rest2};
        Parts ->
            LineStatements = [parse_simple_statement(Part) || Part <- Parts],
            {Statements, Rest2} = parse_block(Rest, CurrentIndent),
            {LineStatements ++ Statements, Rest2}
    end;
parse_block([{Indent, Text} | _Rest], CurrentIndent) when Indent > CurrentIndent ->
    throw({unexpected_indent, CurrentIndent, Indent, Text}).

simple_statement_parts(Text) ->
    case can_split_simple_statement_line(Text) of
        true ->
            Parts = [string:trim(Part) || Part <- split_top_level_semicolons(Text), string:trim(Part) =/= ""],
            case Parts of
                [] -> [Text];
                [_Single] -> [Text];
                _ -> Parts
            end;
        false ->
            [Text]
    end.

can_split_simple_statement_line(Text) ->
    has_top_level_semicolon(Text) andalso not compound_statement_line(Text).

has_top_level_semicolon(Text) ->
    length(split_top_level_semicolons(Text)) > 1.

compound_statement_line(Text) ->
    Trimmed = string:trim(Text),
    lists:any(
        fun(Prefix) -> lists:prefix(Prefix, Trimmed) end,
        [
            "if ",
            "if(",
            "elif ",
            "elif(",
            "else:",
            "while ",
            "while(",
            "for ",
            "async for ",
            "with ",
            "async with ",
            "def ",
            "async def ",
            "class ",
            "try:",
            "except ",
            "finally:",
            "match "
        ]
    ).

parse_decorator_lines([{Indent, [$@ | ExprSource]} | Rest], Indent, Acc) ->
    case parse_expr(ExprSource) of
        {ok, Expr} -> parse_decorator_lines(Rest, Indent, [Expr | Acc]);
        {error, Reason} -> throw({bad_decorator, ExprSource, Reason})
    end;
parse_decorator_lines(Rest, _Indent, Acc) ->
    {lists:reverse(Acc), Rest}.

apply_decorators_to_statement(Decorators, {def, Name, Params, Body}) ->
    {def, Name, Params, Body, Decorators};
apply_decorators_to_statement(Decorators, {async_def, Name, Params, Body}) ->
    {async_def, Name, Params, Body, Decorators};
apply_decorators_to_statement(Decorators, {class, Name, Bases, Metaclass, Keywords, Body, []}) ->
    {class, Name, Bases, Metaclass, Keywords, Body, Decorators};
apply_decorators_to_statement(_Decorators, Other) ->
    throw({decorator_not_allowed, Other}).

parse_statement(Line, Rest, CurrentIndent) ->
    case parse_def_header(Line) of
        {ok_inline, Name, Params, Body} ->
            {{def, Name, Params, Body}, Rest};
        {ok_inline_async, Name, Params, Body} ->
            {{async_def, Name, Params, Body}, Rest};
        {ok, Name, Params} ->
            case Rest of
                [{ChildIndent, _} | _] when ChildIndent > CurrentIndent ->
                    {Body, Rest1} = parse_block(Rest, ChildIndent),
                    {{def, Name, Params, Body}, Rest1};
                _ ->
                    throw({expected_indented_block, Line})
            end;
        {ok_async, Name, Params} ->
            case Rest of
                [{ChildIndent, _} | _] when ChildIndent > CurrentIndent ->
                    {Body, Rest1} = parse_block(Rest, ChildIndent),
                    {{async_def, Name, Params, Body}, Rest1};
                _ ->
                    throw({expected_indented_block, Line})
            end;
        not_def ->
            case parse_class_header(Line) of
                {ok_inline, Name, Bases, Metaclass, Keywords, Body} ->
                    {{class, Name, Bases, Metaclass, Keywords, Body, []}, Rest};
                {ok, Name, Bases, Metaclass, Keywords} ->
                    case Rest of
                        [{ChildIndent, _} | _] when ChildIndent > CurrentIndent ->
                            {Body, Rest1} = parse_block(Rest, ChildIndent),
                            {{class, Name, Bases, Metaclass, Keywords, Body, []}, Rest1};
                        _ ->
                            throw({expected_indented_block, Line})
                    end;
                not_class ->
                    case parse_if_header(Line) of
                        {ok_inline, Condition, ThenBody} ->
                            {ElseBody, Rest2} = parse_if_tail(Rest, CurrentIndent),
                            {{if_stmt, Condition, ThenBody, ElseBody}, Rest2};
                        {ok, Condition} ->
                            {ThenBody, Rest1} = parse_required_child_block(Line, Rest, CurrentIndent),
                            {ElseBody, Rest2} = parse_if_tail(Rest1, CurrentIndent),
                            {{if_stmt, Condition, ThenBody, ElseBody}, Rest2};
                        not_if ->
                            parse_non_if_compound(Line, Rest, CurrentIndent)
                    end
            end
    end.

parse_if_tail([{Indent, "else:" ++ SuiteSource} | Rest], Indent) ->
    parse_else_clause(SuiteSource, Rest, Indent);
parse_if_tail([{Indent, "elif " ++ _} = Line | Rest], Indent) ->
    {ElifStmt, Rest1} = parse_elif_statement(Line, Rest, Indent),
    {[ElifStmt], Rest1};
parse_if_tail(Rest, _Indent) ->
    {[], Rest}.

parse_elif_statement({_Indent, Line}, Rest, CurrentIndent) ->
    case parse_elif_header(Line) of
        {ok_inline, Condition, ThenBody} ->
            {ElseBody, Rest2} = parse_if_tail(Rest, CurrentIndent),
            {{if_stmt, Condition, ThenBody, ElseBody}, Rest2};
        {ok, Condition} ->
            {ThenBody, Rest1} = parse_required_child_block(Line, Rest, CurrentIndent),
            {ElseBody, Rest2} = parse_if_tail(Rest1, CurrentIndent),
            {{if_stmt, Condition, ThenBody, ElseBody}, Rest2};
        not_elif ->
            throw({expected_elif, Line})
    end.

parse_non_if_compound(Line, Rest, CurrentIndent) ->
    case parse_while_header(Line) of
        {ok_inline, Condition, Body} ->
            {ElseBody, Rest2} = parse_loop_tail(Rest, CurrentIndent),
            {{while_stmt, Condition, Body, ElseBody}, Rest2};
        {ok, Condition} ->
            {Body, Rest1} = parse_required_child_block(Line, Rest, CurrentIndent),
            {ElseBody, Rest2} = parse_loop_tail(Rest1, CurrentIndent),
            {{while_stmt, Condition, Body, ElseBody}, Rest2};
        not_while ->
            case parse_for_header(Line) of
                {ok, Name, Iterable} ->
                    {Body, Rest1} = parse_required_child_block(Line, Rest, CurrentIndent),
                    {ElseBody, Rest2} = parse_loop_tail(Rest1, CurrentIndent),
                    {{for_stmt, Name, Iterable, Body, ElseBody}, Rest2};
                not_for ->
                    case parse_with_header(Line) of
                        {ok, Managers} ->
                            {Body, Rest1} = parse_required_child_block(Line, Rest, CurrentIndent),
                            {build_with_statement(Managers, Body), Rest1};
                        not_with ->
                            case parse_match_header(Line) of
                                {ok, Subject} ->
                                    {Cases, Rest1} = parse_match_cases(Line, Rest, CurrentIndent),
                                    {{match_stmt, Subject, Cases}, Rest1};
                                not_match ->
                                    case parse_try_header(Line) of
                                        ok ->
                                            {Body, Rest1} = parse_required_child_block(Line, Rest, CurrentIndent),
                                            {Handlers, ElseBody, FinallyBody, Rest2} = parse_try_clauses(Rest1, CurrentIndent, [], [], []),
                                            {{try_stmt, Body, lists:reverse(Handlers), ElseBody, FinallyBody}, Rest2};
                                        not_try ->
                                            {parse_simple_statement(Line), Rest}
                                    end
                            end
                    end
            end
    end.

parse_loop_tail([{Indent, "else:" ++ SuiteSource} | Rest], Indent) ->
    parse_else_clause(SuiteSource, Rest, Indent);
parse_loop_tail(Rest, _Indent) ->
    {[], Rest}.

parse_else_clause(SuiteSource, Rest, Indent) ->
    case string:trim(SuiteSource) of
        "" -> parse_required_child_block("else:", Rest, Indent);
        InlineSuite -> {parse_inline_suite_statements(InlineSuite), Rest}
    end.

parse_inline_suite_statements(SuiteSource) ->
    Parts = [string:trim(Part) || Part <- split_top_level_semicolons(SuiteSource), string:trim(Part) =/= ""],
    [parse_simple_statement(Part) || Part <- Parts].

parse_required_child_block(Line, Rest, CurrentIndent) ->
    case Rest of
        [{ChildIndent, _} | _] when ChildIndent > CurrentIndent ->
            parse_block(Rest, ChildIndent);
        _ ->
            throw({expected_indented_block, Line})
    end.

parse_simple_statement("return") ->
    {return, {none}};
parse_simple_statement("return " ++ ExprSource) ->
    case parse_expr(ExprSource) of
        {ok, Expr} -> {return, Expr};
        {error, Reason} -> throw({bad_return, ExprSource, Reason})
    end;
parse_simple_statement("yield") ->
    {yield, {none}};
parse_simple_statement("yield from " ++ ExprSource) ->
    case parse_expr(ExprSource) of
        {ok, Expr} -> {yield_from, Expr};
        {error, Reason} -> throw({bad_yield, ExprSource, Reason})
    end;
parse_simple_statement("yield " ++ ExprSource) ->
    case parse_expr(ExprSource) of
        {ok, Expr} -> {yield, Expr};
        {error, Reason} -> throw({bad_yield, ExprSource, Reason})
    end;
parse_simple_statement("raise") ->
    {raise, bare};
parse_simple_statement("raise " ++ ExprSource) ->
    parse_raise_statement(ExprSource);
parse_simple_statement("assert " ++ ExprSource) ->
    case parse_expr(ExprSource) of
        {ok, Expr} -> {assert, Expr};
        {error, Reason} -> throw({bad_assert, ExprSource, Reason})
    end;
parse_simple_statement("break") ->
    break;
parse_simple_statement("continue") ->
    continue;
parse_simple_statement("pass") ->
    pass;
parse_simple_statement("del " ++ TargetText) ->
    case parse_assignment_target(string:trim(TargetText)) of
        {ok, Target} -> {del, Target};
        error -> throw({bad_del_target, TargetText})
    end;
parse_simple_statement("global " ++ NamesText) ->
    {global, parse_global_names(NamesText)};
parse_simple_statement("nonlocal " ++ NamesText) ->
    {nonlocal, parse_global_names(NamesText)};
parse_simple_statement(Line) ->
    case parse_import_statement(Line) of
        {ok, Statement} ->
            Statement;
        not_import ->
            parse_non_import_simple_statement(Line)
    end.

parse_global_names(NamesText) ->
    Names = [string:trim(Part) || Part <- string:split(NamesText, ",", all)],
    case [Name || Name <- Names, Name =:= ""] of
        [] -> [list_to_binary(Name) || Name <- Names];
        _ -> throw({bad_global, NamesText})
    end.

parse_raise_statement(ExprSource) ->
    case split_raise_from(ExprSource) of
        {RaiseSource, CauseSource} ->
            case {parse_expr(string:trim(RaiseSource)), parse_expr(string:trim(CauseSource))} of
                {{ok, Expr}, {ok, Cause}} -> {raise_from, Expr, Cause};
                {{error, Reason}, _} -> throw({bad_raise, ExprSource, Reason});
                {_, {error, Reason}} -> throw({bad_raise, ExprSource, Reason})
            end;
        none ->
            case parse_expr(ExprSource) of
                {ok, Expr} -> {raise, Expr};
                {error, Reason} -> throw({bad_raise, ExprSource, Reason})
            end
    end.

split_raise_from(Text) ->
    split_raise_from(Text, [], 0, none).

split_raise_from([], _Acc, _Depth, _Quote) ->
    none;
split_raise_from([$ , $f, $r, $o, $m, $  | Rest], Acc, 0, none) ->
    {lists:reverse(Acc), Rest};
split_raise_from([$", $", $" | Rest], Acc, Depth, none) ->
    split_raise_from_triple(Rest, [$", $", $" | Acc], Depth, $");
split_raise_from([$', $', $' | Rest], Acc, Depth, none) ->
    split_raise_from_triple(Rest, [$', $', $' | Acc], Depth, $');
split_raise_from([$\\, Escaped | Rest], Acc, Depth, Quote) when Quote =/= none ->
    split_raise_from(Rest, [Escaped, $\\ | Acc], Depth, Quote);
split_raise_from([Quote | Rest], Acc, Depth, Quote) ->
    split_raise_from(Rest, [Quote | Acc], Depth, none);
split_raise_from([$" | Rest], Acc, Depth, none) ->
    split_raise_from(Rest, [$" | Acc], Depth, $");
split_raise_from([$' | Rest], Acc, Depth, none) ->
    split_raise_from(Rest, [$' | Acc], Depth, $');
split_raise_from([Ch | Rest], Acc, Depth, none) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    split_raise_from(Rest, [Ch | Acc], Depth + 1, none);
split_raise_from([Ch | Rest], Acc, Depth, none) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    split_raise_from(Rest, [Ch | Acc], Depth - 1, none);
split_raise_from([Ch | Rest], Acc, Depth, Quote) ->
    split_raise_from(Rest, [Ch | Acc], Depth, Quote).

split_raise_from_triple([], _Acc, _Depth, _Quote) ->
    none;
split_raise_from_triple([Quote, Quote, Quote | Rest], Acc, Depth, Quote) ->
    split_raise_from(Rest, [Quote, Quote, Quote | Acc], Depth, none);
split_raise_from_triple([Ch | Rest], Acc, Depth, Quote) ->
    split_raise_from_triple(Rest, [Ch | Acc], Depth, Quote).

parse_non_import_simple_statement(Line) ->
    case parse_type_alias_statement(Line) of
        {ok, Statement} ->
            Statement;
        not_type_alias ->
            parse_non_import_simple_statement_after_type_alias(Line)
    end.

parse_non_import_simple_statement_after_type_alias(Line) ->
    case split_augmented_assignment(Line) of
        {aug_assign, Target, Op, ExprSource} ->
            case parse_expr(ExprSource) of
                {ok, Expr} -> {aug_assign, Target, Op, Expr};
                {error, Reason} -> throw({bad_assignment, Line, Reason})
            end;
        none ->
            case split_annotated_assignment(Line) of
                {ann_assign, Target, none} ->
                    {ann_assign, Target, none};
                {ann_assign, Target, ExprSource} ->
                    case parse_expr(ExprSource) of
                        {ok, Expr} -> {ann_assign, Target, Expr};
                        {error, Reason} -> throw({bad_assignment, Line, Reason})
                    end;
                none ->
                    case split_assignment(Line) of
                        {assign, Name, ExprSource} ->
                            case parse_expr(ExprSource) of
                                {ok, Expr} -> {assign, list_to_binary(Name), Expr};
                                {error, Reason} -> throw({bad_assignment, Line, Reason})
                            end;
                        {assign_attr, Target, ExprSource} ->
                            case parse_expr(ExprSource) of
                                {ok, Expr} -> {assign_attr, Target, Expr};
                                {error, Reason} -> throw({bad_assignment, Line, Reason})
                            end;
                        {assign_subscript, Target, ExprSource} ->
                            case parse_expr(ExprSource) of
                                {ok, Expr} -> {assign_subscript, Target, Expr};
                                {error, Reason} -> throw({bad_assignment, Line, Reason})
                            end;
                        {assign_target, Target, ExprSource} ->
                            case parse_expr(ExprSource) of
                                {ok, Expr} -> {assign_target, Target, Expr};
                                {error, Reason} -> throw({bad_assignment, Line, Reason})
                            end;
                        {assign_chain, Targets, ExprSource} ->
                            case parse_expr(ExprSource) of
                                {ok, Expr} -> {assign_chain, Targets, Expr};
                                {error, Reason} -> throw({bad_assignment, Line, Reason})
                            end;
                        expr ->
                            case parse_expr(Line) of
                                {ok, Expr} -> {expr, Expr};
                                {error, Reason} -> throw({bad_expression_statement, Line, Reason})
                            end
                    end
            end
    end.

parse_type_alias_statement("type " ++ Rest0) ->
    Rest = string:trim(Rest0),
    case split_assignment(Rest) of
        {assign, Name, ExprSource} ->
            case parse_expr(ExprSource) of
                {ok, Expr} -> {ok, {type_alias, list_to_binary(Name), Expr}};
                {error, Reason} -> throw({bad_type_alias, Rest, Reason})
            end;
        _ ->
            not_type_alias
    end;
parse_type_alias_statement(_Line) ->
    not_type_alias.

parse_import_statement("import " ++ Rest) ->
    Specs = [parse_import_spec(string:trim(Part)) || Part <- string:split(Rest, ",", all)],
    {ok, {import, Specs}};
parse_import_statement("from " ++ Rest) ->
    case string:split(Rest, " import ", leading) of
        [ModuleText, NamesText] ->
            NormalizedNamesText = normalize_from_import_names_text(NamesText),
            Specs =
                case NormalizedNamesText of
                    "*" -> star;
                    _ -> [parse_from_import_spec(Part) || Part <- split_import_names(NormalizedNamesText)]
                end,
            {ok, {from_import, normalize_module_name(ModuleText), Specs}};
        _ ->
            not_import
    end;
parse_import_statement(_Line) ->
    not_import.

normalize_from_import_names_text(NamesText) ->
    Trimmed = string:trim(NamesText),
    case Trimmed of
        [$( | Rest] ->
            case lists:reverse(string:trim(Rest)) of
                [$) | ReversedInner] -> string:trim(lists:reverse(ReversedInner));
                _ -> Trimmed
            end;
        _ ->
            Trimmed
    end.

split_import_names(NamesText) ->
    [Name || Name <- [string:trim(Part) || Part <- string:split(NamesText, ",", all)], Name =/= ""].

parse_import_spec(Spec) ->
    case string:split(Spec, " as ", leading) of
        [Name, Alias] -> {normalize_module_name(Name), list_to_binary(string:trim(Alias)), explicit};
        [Name] ->
            Module = normalize_module_name(Name),
            {Module, default_import_alias(Module), default}
    end.

parse_from_import_spec(Spec) ->
    case string:split(Spec, " as ", leading) of
        [Name, Alias] -> {list_to_binary(string:trim(Name)), list_to_binary(string:trim(Alias))};
        [Name] ->
            Bin = list_to_binary(string:trim(Name)),
            {Bin, Bin}
    end.

normalize_module_name(Name) ->
    list_to_binary(string:trim(Name)).

default_import_alias(Module) ->
    case binary:split(Module, <<".">>) of
        [Top, _Rest] -> Top;
        [Top] -> Top
    end.

parse_def_header("async def " ++ Rest0) ->
    case parse_def_header("def " ++ Rest0) of
        {ok_inline, Name, Params, Body} -> {ok_inline_async, Name, Params, Body};
        {ok, Name, Params} -> {ok_async, Name, Params};
        not_def -> not_def
    end;
parse_def_header("def " ++ Rest0) ->
    Rest = string:trim(Rest0),
    case take_identifier(Rest, []) of
        {[], _AfterName} ->
            not_def;
        {Name, AfterName} ->
            parse_def_after_name(Name, string:trim(AfterName))
    end;
parse_def_header(_Line) ->
    not_def.

parse_def_after_name(Name, [$( | AfterOpen]) ->
    case take_balanced_def_params(AfterOpen, 1, none, []) of
        {ok, ParamsText, AfterClose} ->
            case parse_def_suffix(string:trim(AfterClose)) of
                block -> {ok, list_to_binary(Name), parse_params(ParamsText)};
                {inline, Body} -> {ok_inline, list_to_binary(Name), parse_params(ParamsText), Body};
                false -> not_def
            end;
        error ->
            not_def
    end;
parse_def_after_name(Name, [$[ | AfterOpen]) ->
    case take_balanced_type_params(AfterOpen, 1, none, []) of
        {ok, _ParamsText, AfterClose} ->
            parse_def_after_name(Name, string:trim(AfterClose));
        error ->
            not_def
    end;
parse_def_after_name(_Name, _AfterName) ->
    not_def.

take_identifier([Ch | Rest], Acc) when Ch >= $A, Ch =< $Z; Ch >= $a, Ch =< $z; Ch >= $0, Ch =< $9; Ch =:= $_ ->
    take_identifier(Rest, [Ch | Acc]);
take_identifier(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

take_balanced_def_params([], _Depth, _Quote, _Acc) ->
    error;
take_balanced_def_params([$\\, Escaped | Rest], Depth, Quote, Acc) when Quote =/= none ->
    take_balanced_def_params(Rest, Depth, Quote, [Escaped, $\\ | Acc]);
take_balanced_def_params([Quote | Rest], Depth, Quote, Acc) ->
    take_balanced_def_params(Rest, Depth, none, [Quote | Acc]);
take_balanced_def_params([$" | Rest], Depth, none, Acc) ->
    take_balanced_def_params(Rest, Depth, $", [$" | Acc]);
take_balanced_def_params([$' | Rest], Depth, none, Acc) ->
    take_balanced_def_params(Rest, Depth, $', [$' | Acc]);
take_balanced_def_params([$( | Rest], Depth, none, Acc) ->
    take_balanced_def_params(Rest, Depth + 1, none, [$( | Acc]);
take_balanced_def_params([$) | Rest], 1, none, Acc) ->
    {ok, lists:reverse(Acc), Rest};
take_balanced_def_params([$) | Rest], Depth, none, Acc) ->
    take_balanced_def_params(Rest, Depth - 1, none, [$) | Acc]);
take_balanced_def_params([Ch | Rest], Depth, Quote, Acc) ->
    take_balanced_def_params(Rest, Depth, Quote, [Ch | Acc]).

parse_def_suffix(":") ->
    block;
parse_def_suffix([$: | Rest]) ->
    case string:trim(Rest) of
        "" -> block;
        Suite -> {inline, parse_inline_suite_statements(Suite)}
    end;
parse_def_suffix([$-, $> | Rest]) ->
    case lists:reverse(string:trim(Rest)) of
        [$: | _] -> block;
        _ -> false
    end;
parse_def_suffix(_Suffix) ->
    false.

parse_class_header("class " ++ Rest0) ->
    Rest = string:trim(Rest0),
    case take_identifier(Rest, []) of
        {[], _AfterName} ->
            not_class;
        {Name, AfterName0} ->
            parse_class_after_name(Name, string:trim(AfterName0))
    end;
parse_class_header(_Line) ->
    not_class.

parse_class_after_name(Name, [$( | AfterOpen]) ->
    case take_balanced_def_params(AfterOpen, 1, none, []) of
        {ok, BasesText, AfterClose} ->
            parse_class_suffix(Name, BasesText, string:trim(AfterClose));
        error ->
            not_class
    end;
parse_class_after_name(Name, [$[ | AfterOpen]) ->
    case take_balanced_type_params(AfterOpen, 1, none, []) of
        {ok, _ParamsText, AfterClose} ->
            parse_class_after_name(Name, string:trim(AfterClose));
        error ->
            not_class
    end;
parse_class_after_name(Name, Suffix) ->
    parse_class_suffix(Name, "", Suffix).

take_balanced_type_params([], _Depth, _Quote, _Acc) ->
    error;
take_balanced_type_params([$\\, Escaped | Rest], Depth, Quote, Acc) when Quote =/= none ->
    take_balanced_type_params(Rest, Depth, Quote, [Escaped, $\\ | Acc]);
take_balanced_type_params([Quote | Rest], Depth, Quote, Acc) ->
    take_balanced_type_params(Rest, Depth, none, [Quote | Acc]);
take_balanced_type_params([$" | Rest], Depth, none, Acc) ->
    take_balanced_type_params(Rest, Depth, $", [$" | Acc]);
take_balanced_type_params([$' | Rest], Depth, none, Acc) ->
    take_balanced_type_params(Rest, Depth, $', [$' | Acc]);
take_balanced_type_params([Ch | Rest], Depth, none, Acc) when Ch =:= $[; Ch =:= $(; Ch =:= ${ ->
    take_balanced_type_params(Rest, Depth + 1, none, [Ch | Acc]);
take_balanced_type_params([$] | Rest], 1, none, Acc) ->
    {ok, lists:reverse(Acc), Rest};
take_balanced_type_params([Ch | Rest], Depth, none, Acc) when Ch =:= $]; Ch =:= $); Ch =:= $} ->
    take_balanced_type_params(Rest, Depth - 1, none, [Ch | Acc]);
take_balanced_type_params([Ch | Rest], Depth, Quote, Acc) ->
    take_balanced_type_params(Rest, Depth, Quote, [Ch | Acc]).

parse_class_suffix(Name, BasesText, ":") ->
    {Bases, Metaclass, Keywords} = parse_class_items(BasesText),
    {ok, list_to_binary(Name), Bases, Metaclass, Keywords};
parse_class_suffix(Name, BasesText, [$: | Rest]) ->
    case string:trim(Rest) of
        "" ->
            parse_class_suffix(Name, BasesText, ":");
        SuiteText ->
            {Bases, Metaclass, Keywords} = parse_class_items(BasesText),
            {ok_inline, list_to_binary(Name), Bases, Metaclass, Keywords, [parse_simple_statement(SuiteText)]}
    end;
parse_class_suffix(_Name, _BasesText, _Suffix) ->
    not_class.

parse_if_header("if " ++ Rest) ->
    parse_condition_header(Rest, if_stmt);
parse_if_header("if(" ++ Rest) ->
    parse_condition_header("(" ++ Rest, if_stmt);
parse_if_header(_Line) ->
    not_if.

parse_elif_header("elif " ++ Rest) ->
    parse_condition_header(Rest, elif_stmt);
parse_elif_header("elif(" ++ Rest) ->
    parse_condition_header("(" ++ Rest, elif_stmt);
parse_elif_header(_Line) ->
    not_elif.

parse_while_header("while " ++ Rest) ->
    parse_condition_header(Rest, while_stmt);
parse_while_header("while(" ++ Rest) ->
    parse_condition_header("(" ++ Rest, while_stmt);
parse_while_header(_Line) ->
    not_while.

parse_for_header("for " ++ Rest) ->
    case lists:reverse(Rest) of
        [$: | ReversedSpec] ->
            parse_for_spec(string:trim(lists:reverse(ReversedSpec)));
        _ ->
            not_for
    end;
parse_for_header("async for " ++ Rest) ->
    parse_for_header("for " ++ Rest);
parse_for_header(_Line) ->
    not_for.

parse_for_spec(Spec) ->
    case string:split(Spec, " in ", leading) of
        [TargetText, ExprSource] ->
            case parse_assignment_target(string:trim(TargetText)) of
                {ok, Target} ->
                    case parse_expr(ExprSource) of
                        {ok, Expr} -> {ok, Target, Expr};
                        {error, Reason} -> throw({bad_for_iterable, ExprSource, Reason})
                    end;
                error ->
                    throw({bad_for_target, TargetText})
            end;
        _ ->
            not_for
    end.

parse_with_header("with " ++ Rest) ->
    case lists:reverse(Rest) of
        [$: | ReversedSpec] ->
            parse_with_spec(string:trim(lists:reverse(ReversedSpec)));
        _ ->
            not_with
    end;
parse_with_header("async with " ++ Rest) ->
    parse_with_header("with " ++ Rest);
parse_with_header(_Line) ->
    not_with.

parse_with_spec(Spec) ->
    Items = [Item || Item <- [string:trim(Part) || Part <- split_top_level_commas(Spec)], Item =/= ""],
    case Items of
        [] -> throw({bad_with_manager, Spec, empty});
        _ -> {ok, [parse_with_item(Item) || Item <- Items]}
    end.

parse_with_item(Spec) ->
    case re:run(Spec, "^(.*)\\s+as\\s+(.+)$", [unicode, {capture, [1, 2], list}]) of
        {match, [ExprSource, Binding]} ->
            case parse_assignment_target(string:trim(Binding)) of
                {ok, Target} ->
                    case parse_expr(string:trim(ExprSource)) of
                        {ok, Expr} -> {Expr, Target};
                        {error, Reason} -> throw({bad_with_manager, ExprSource, Reason})
                    end;
                error ->
                    throw({bad_with_binding, Binding})
            end;
        nomatch ->
            case parse_expr(Spec) of
                {ok, Expr} -> {Expr, undefined};
                {error, Reason} -> throw({bad_with_manager, Spec, Reason})
            end
    end.

build_with_statement([{Manager, Binding}], Body) ->
    {with_stmt, Manager, Binding, Body};
build_with_statement([{Manager, Binding} | Rest], Body) ->
    {with_stmt, Manager, Binding, [build_with_statement(Rest, Body)]}.

parse_try_header("try:") ->
    ok;
parse_try_header(_Line) ->
    not_try.

parse_match_header("match " ++ Rest) ->
    case lists:reverse(Rest) of
        [$: | ReversedSubject] ->
            SubjectSource = lists:reverse(ReversedSubject),
            case parse_expr(SubjectSource) of
                {ok, Expr} -> {ok, Expr};
                {error, Reason} -> throw({bad_match_subject, SubjectSource, Reason})
            end;
        _ ->
            not_match
    end;
parse_match_header(_Line) ->
    not_match.

parse_match_cases(Line, Rest, CurrentIndent) ->
    case Rest of
        [{CaseIndent, _} | _] when CaseIndent > CurrentIndent ->
            parse_match_case_block(Rest, CaseIndent, []);
        _ ->
            throw({expected_indented_block, Line})
    end.

parse_match_case_block([{Indent, Line} | Rest], Indent, Acc) ->
    case parse_case_header(Line) of
        {ok, Pattern, Guard} ->
            {Body, Rest1} = parse_required_child_block(Line, Rest, Indent),
            parse_match_case_block(Rest1, Indent, [{Pattern, Guard, Body} | Acc]);
        not_case ->
            {lists:reverse(Acc), [{Indent, Line} | Rest]}
    end;
parse_match_case_block(Rest, _Indent, Acc) ->
    {lists:reverse(Acc), Rest}.

parse_case_header("case " ++ Rest) ->
    case lists:reverse(Rest) of
        [$: | ReversedSpec] ->
            Spec = string:trim(lists:reverse(ReversedSpec)),
            {PatternSource, Guard} = split_case_guard(Spec),
            {ok, parse_match_pattern(PatternSource), Guard};
        _ ->
            not_case
    end;
parse_case_header(_Line) ->
    not_case.

split_case_guard(Spec) ->
    case split_top_level_case_guard(Spec) of
        {PatternSource, GuardSource} ->
            case parse_expr(GuardSource) of
                {ok, Guard} -> {string:trim(PatternSource), Guard};
                {error, Reason} -> throw({bad_case_guard, GuardSource, Reason})
            end;
        none ->
            {Spec, none}
    end.

split_top_level_case_guard(Text) ->
    split_top_level_case_guard(Text, 0, none, []).

split_top_level_case_guard([], _Depth, _Quote, _Acc) ->
    none;
split_top_level_case_guard([$\\, Escaped | Rest], Depth, Quote, Acc) when Quote =/= none ->
    split_top_level_case_guard(Rest, Depth, Quote, [Escaped, $\\ | Acc]);
split_top_level_case_guard([Quote | Rest], Depth, Quote, Acc) ->
    split_top_level_case_guard(Rest, Depth, none, [Quote | Acc]);
split_top_level_case_guard([$" | Rest], Depth, none, Acc) ->
    split_top_level_case_guard(Rest, Depth, $", [$" | Acc]);
split_top_level_case_guard([$' | Rest], Depth, none, Acc) ->
    split_top_level_case_guard(Rest, Depth, $', [$' | Acc]);
split_top_level_case_guard([Ch | Rest], Depth, none, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    split_top_level_case_guard(Rest, Depth + 1, none, [Ch | Acc]);
split_top_level_case_guard([Ch | Rest], Depth, none, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    split_top_level_case_guard(Rest, Depth - 1, none, [Ch | Acc]);
split_top_level_case_guard([$ , $i, $f, $  | Rest], 0, none, Acc) ->
    {lists:reverse(Acc), string:trim(Rest)};
split_top_level_case_guard([Ch | Rest], Depth, Quote, Acc) ->
    split_top_level_case_guard(Rest, Depth, Quote, [Ch | Acc]).

parse_match_pattern(PatternSource0) ->
    PatternSource = string:trim(PatternSource0),
    case PatternSource of
        "_" ->
            wildcard;
        "" ->
            throw(empty_match_pattern);
        _ ->
            case [string:trim(Part) || Part <- split_top_level_pattern_or(PatternSource), string:trim(Part) =/= ""] of
                [Single] ->
                    parse_non_wildcard_match_pattern(Single);
                Parts ->
                    {or_pattern, [parse_match_pattern(Part) || Part <- Parts]}
            end
    end.

parse_non_wildcard_match_pattern(PatternSource) ->
    case parse_class_match_pattern(PatternSource) of
        {ok, Pattern} ->
            Pattern;
        not_class_pattern ->
            case valid_name(PatternSource) of
                true ->
                    case PatternSource of
                        "None" -> {value, {none}};
                        "True" -> {value, {bool, true}};
                        "False" -> {value, {bool, false}};
                        _ -> {capture, list_to_binary(PatternSource)}
                    end;
                false ->
                    case parse_expr(PatternSource) of
                        {ok, Expr} -> {value, Expr};
                        {error, Reason} -> throw({bad_match_pattern, PatternSource, Reason})
                    end
            end
    end.

parse_class_match_pattern(PatternSource) ->
    Trimmed = string:trim(PatternSource),
    case lists:reverse(Trimmed) of
        [$) | ReversedPrefix] ->
            Prefix = lists:reverse(ReversedPrefix),
            case split_class_pattern_open(Prefix) of
                {ClassSource, ArgsSource} ->
                    case parse_expr(ClassSource) of
                        {ok, ClassExpr} ->
                            {Positional, Keywords} = parse_match_pattern_args(ArgsSource),
                            {ok, {class_pattern, ClassExpr, Positional, Keywords}};
                        {error, Reason} ->
                            throw({bad_class_pattern, ClassSource, Reason})
                    end;
                none ->
                    not_class_pattern
            end;
        _ ->
            not_class_pattern
    end.

split_class_pattern_open(Prefix) ->
    split_class_pattern_open(Prefix, 0, none, [], []).

split_class_pattern_open([], _Depth, _Quote, _AfterOpen, _ClassAcc) ->
    none;
split_class_pattern_open([$\\, Escaped | Rest], Depth, Quote, AfterOpen, ClassAcc) when Quote =/= none ->
    split_class_pattern_open(Rest, Depth, Quote, [Escaped, $\\ | AfterOpen], ClassAcc);
split_class_pattern_open([Quote | Rest], Depth, Quote, AfterOpen, ClassAcc) ->
    split_class_pattern_open(Rest, Depth, none, [Quote | AfterOpen], ClassAcc);
split_class_pattern_open([$" | Rest], Depth, none, AfterOpen, ClassAcc) ->
    split_class_pattern_open(Rest, Depth, $", [$" | AfterOpen], ClassAcc);
split_class_pattern_open([$' | Rest], Depth, none, AfterOpen, ClassAcc) ->
    split_class_pattern_open(Rest, Depth, $', [$' | AfterOpen], ClassAcc);
split_class_pattern_open([$( | Rest], 0, none, AfterOpen, ClassAcc) ->
    ClassSource = string:trim(lists:reverse(ClassAcc)),
    ArgsSource = string:trim(lists:reverse(AfterOpen) ++ Rest),
    case ClassSource of
        "" -> none;
        _ -> {ClassSource, ArgsSource}
    end;
split_class_pattern_open([$) | Rest], Depth, none, AfterOpen, ClassAcc) ->
    split_class_pattern_open(Rest, Depth + 1, none, [$) | AfterOpen], ClassAcc);
split_class_pattern_open([$( | Rest], Depth, none, AfterOpen, ClassAcc) ->
    split_class_pattern_open(Rest, Depth - 1, none, [$( | AfterOpen], ClassAcc);
split_class_pattern_open([Ch | Rest], 0, none, AfterOpen, ClassAcc) ->
    split_class_pattern_open(Rest, 0, none, AfterOpen, [Ch | ClassAcc]);
split_class_pattern_open([Ch | Rest], Depth, Quote, AfterOpen, ClassAcc) ->
    split_class_pattern_open(Rest, Depth, Quote, [Ch | AfterOpen], ClassAcc).

parse_match_pattern_args("") ->
    {[], []};
parse_match_pattern_args(ArgsSource) ->
    Items = [string:trim(Item) || Item <- split_top_level_commas(ArgsSource), string:trim(Item) =/= ""],
    parse_match_pattern_args(Items, [], []).

parse_match_pattern_args([], Positional, Keywords) ->
    {lists:reverse(Positional), lists:reverse(Keywords)};
parse_match_pattern_args([Item | Rest], Positional, Keywords) ->
    case split_top_level_keyword(Item) of
        {keyword, Name, PatternSource} ->
            parse_match_pattern_args(Rest, Positional, [{list_to_binary(Name), parse_match_pattern(PatternSource)} | Keywords]);
        none ->
            parse_match_pattern_args(Rest, [parse_match_pattern(Item) | Positional], Keywords)
    end.

parse_condition_header(Rest, Kind) ->
    case split_inline_suite(Rest) of
        {ConditionSource, SuiteSource} ->
            case parse_expr(string:trim(ConditionSource)) of
                {ok, Expr} -> {ok_inline, Expr, parse_inline_suite_statements(string:trim(SuiteSource))};
                {error, Reason} -> throw({bad_condition, Kind, ConditionSource, Reason})
            end;
        none ->
            case lists:reverse(Rest) of
                [$: | ReversedExpr] ->
                    ExprSource = lists:reverse(ReversedExpr),
                    case parse_expr(ExprSource) of
                        {ok, Expr} -> {ok, Expr};
                        {error, Reason} -> throw({bad_condition, Kind, ExprSource, Reason})
                    end;
                _ ->
                    case Kind of
                        if_stmt -> not_if;
                        elif_stmt -> not_elif;
                        while_stmt -> not_while
                    end
            end
    end.

split_inline_suite(Source) ->
    split_inline_suite(Source, 0, none, []).

split_inline_suite([], _Balance, _Quote, _Acc) ->
    none;
split_inline_suite([$\\, Escaped | Rest], Balance, Quote, Acc) when Quote =/= none ->
    split_inline_suite(Rest, Balance, Quote, [Escaped, $\\ | Acc]);
split_inline_suite([Quote | Rest], Balance, Quote, Acc) ->
    split_inline_suite(Rest, Balance, none, [Quote | Acc]);
split_inline_suite([$" | Rest], Balance, none, Acc) ->
    split_inline_suite(Rest, Balance, $", [$" | Acc]);
split_inline_suite([$' | Rest], Balance, none, Acc) ->
    split_inline_suite(Rest, Balance, $', [$' | Acc]);
split_inline_suite([Ch | Rest], Balance, none, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    split_inline_suite(Rest, Balance + 1, none, [Ch | Acc]);
split_inline_suite([Ch | Rest], Balance, none, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    split_inline_suite(Rest, Balance - 1, none, [Ch | Acc]);
split_inline_suite([$:,$= | Rest], Balance, none, Acc) ->
    split_inline_suite(Rest, Balance, none, [$=, $: | Acc]);
split_inline_suite([$: | Rest], 0, none, Acc) ->
    case string:trim(Rest) of
        "" -> none;
        Suite -> {lists:reverse(Acc), Suite}
    end;
split_inline_suite([Ch | Rest], Balance, Quote, Acc) ->
    split_inline_suite(Rest, Balance, Quote, [Ch | Acc]).

parse_class_items(BasesText) ->
    Trimmed = string:trim(BasesText),
    case Trimmed of
        "" ->
            {[], undefined, []};
        _ ->
            Items = [Item || Item <- [string:trim(B) || B <- split_top_level_commas(Trimmed)], Item =/= ""],
            parse_class_items(Items, [], undefined, [])
    end.

parse_class_items([], Bases, Metaclass, Keywords) ->
    {lists:reverse(Bases), Metaclass, lists:reverse(Keywords)};
parse_class_items(["metaclass=" ++ ExprSource | Rest], Bases, undefined, Keywords) ->
    case parse_expr(ExprSource) of
        {ok, Expr} -> parse_class_items(Rest, Bases, Expr, Keywords);
        {error, Reason} -> throw({bad_metaclass, ExprSource, Reason})
    end;
parse_class_items(["metaclass=" ++ _ExprSource | _Rest], _Bases, _Metaclass, _Keywords) ->
    throw(duplicate_metaclass);
parse_class_items([Base | Rest], Bases, Metaclass, Keywords) ->
    case split_top_level_keyword(Base) of
        {keyword, Name, ExprSource} ->
            case parse_expr(ExprSource) of
                {ok, Expr} -> parse_class_items(Rest, Bases, Metaclass, [{list_to_binary(Name), Expr} | Keywords]);
                {error, Reason} -> throw({bad_class_keyword, Base, Reason})
            end;
        none ->
            case parse_expr(Base) of
                {ok, Expr} -> parse_class_items(Rest, [Expr | Bases], Metaclass, Keywords);
                {error, Reason} -> throw({bad_base_class, Base, Reason})
            end
    end.

parse_params(ParamsText) ->
    Trimmed = string:trim(ParamsText),
    case Trimmed of
        "" ->
            [];
        _ ->
            [parse_param(Param) || Param <- [string:trim(P) || P <- split_top_level_commas(Trimmed)], Param =/= ""]
    end.

split_top_level_commas(Text) ->
    split_top_level_commas(Text, 0, none, [], []).

split_top_level_commas([], _Depth, _Quote, Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
split_top_level_commas([$\\, Escaped | Rest], Depth, Quote, Current, Acc) when Quote =/= none ->
    split_top_level_commas(Rest, Depth, Quote, [Escaped, $\\ | Current], Acc);
split_top_level_commas([Quote | Rest], Depth, Quote, Current, Acc) ->
    split_top_level_commas(Rest, Depth, none, [Quote | Current], Acc);
split_top_level_commas([$" | Rest], Depth, none, Current, Acc) ->
    split_top_level_commas(Rest, Depth, $", [$" | Current], Acc);
split_top_level_commas([$' | Rest], Depth, none, Current, Acc) ->
    split_top_level_commas(Rest, Depth, $', [$' | Current], Acc);
split_top_level_commas([Ch | Rest], Depth, none, Current, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    split_top_level_commas(Rest, Depth + 1, none, [Ch | Current], Acc);
split_top_level_commas([Ch | Rest], Depth, none, Current, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    split_top_level_commas(Rest, Depth - 1, none, [Ch | Current], Acc);
split_top_level_commas([$, | Rest], 0, none, Current, Acc) ->
    split_top_level_commas(Rest, 0, none, [], [lists:reverse(Current) | Acc]);
split_top_level_commas([Ch | Rest], Depth, Quote, Current, Acc) ->
    split_top_level_commas(Rest, Depth, Quote, [Ch | Current], Acc).

split_top_level_pattern_or(Text) ->
    split_top_level_pattern_or(Text, 0, none, [], []).

split_top_level_pattern_or([], _Depth, _Quote, Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
split_top_level_pattern_or([$\\, Escaped | Rest], Depth, Quote, Current, Acc) when Quote =/= none ->
    split_top_level_pattern_or(Rest, Depth, Quote, [Escaped, $\\ | Current], Acc);
split_top_level_pattern_or([Quote | Rest], Depth, Quote, Current, Acc) ->
    split_top_level_pattern_or(Rest, Depth, none, [Quote | Current], Acc);
split_top_level_pattern_or([$" | Rest], Depth, none, Current, Acc) ->
    split_top_level_pattern_or(Rest, Depth, $", [$" | Current], Acc);
split_top_level_pattern_or([$' | Rest], Depth, none, Current, Acc) ->
    split_top_level_pattern_or(Rest, Depth, $', [$' | Current], Acc);
split_top_level_pattern_or([Ch | Rest], Depth, none, Current, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    split_top_level_pattern_or(Rest, Depth + 1, none, [Ch | Current], Acc);
split_top_level_pattern_or([Ch | Rest], Depth, none, Current, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    split_top_level_pattern_or(Rest, Depth - 1, none, [Ch | Current], Acc);
split_top_level_pattern_or([$| | Rest], 0, none, Current, Acc) ->
    split_top_level_pattern_or(Rest, 0, none, [], [lists:reverse(Current) | Acc]);
split_top_level_pattern_or([Ch | Rest], Depth, Quote, Current, Acc) ->
    split_top_level_pattern_or(Rest, Depth, Quote, [Ch | Current], Acc).

split_top_level_semicolons(Text) ->
    split_top_level_semicolons(Text, 0, none, [], []).

split_top_level_semicolons([], _Depth, _Quote, Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
split_top_level_semicolons([$\\, Escaped | Rest], Depth, Quote, Current, Acc) when Quote =/= none ->
    split_top_level_semicolons(Rest, Depth, Quote, [Escaped, $\\ | Current], Acc);
split_top_level_semicolons([$", $", $" | Rest], Depth, none, Current, Acc) ->
    split_top_level_semicolons(Rest, Depth, {triple, $"}, [$", $", $" | Current], Acc);
split_top_level_semicolons([$", $", $" | Rest], Depth, {triple, $"}, Current, Acc) ->
    split_top_level_semicolons(Rest, Depth, none, [$", $", $" | Current], Acc);
split_top_level_semicolons([$', $', $' | Rest], Depth, none, Current, Acc) ->
    split_top_level_semicolons(Rest, Depth, {triple, $'}, [$', $', $' | Current], Acc);
split_top_level_semicolons([$', $', $' | Rest], Depth, {triple, $'}, Current, Acc) ->
    split_top_level_semicolons(Rest, Depth, none, [$', $', $' | Current], Acc);
split_top_level_semicolons([Quote | Rest], Depth, Quote, Current, Acc) ->
    split_top_level_semicolons(Rest, Depth, none, [Quote | Current], Acc);
split_top_level_semicolons([$" | Rest], Depth, none, Current, Acc) ->
    split_top_level_semicolons(Rest, Depth, $", [$" | Current], Acc);
split_top_level_semicolons([$' | Rest], Depth, none, Current, Acc) ->
    split_top_level_semicolons(Rest, Depth, $', [$' | Current], Acc);
split_top_level_semicolons([Ch | Rest], Depth, none, Current, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    split_top_level_semicolons(Rest, Depth + 1, none, [Ch | Current], Acc);
split_top_level_semicolons([Ch | Rest], Depth, none, Current, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    split_top_level_semicolons(Rest, Depth - 1, none, [Ch | Current], Acc);
split_top_level_semicolons([$; | Rest], 0, none, Current, Acc) ->
    split_top_level_semicolons(Rest, 0, none, [], [lists:reverse(Current) | Acc]);
split_top_level_semicolons([Ch | Rest], Depth, Quote, Current, Acc) ->
    split_top_level_semicolons(Rest, Depth, Quote, [Ch | Current], Acc).

split_top_level_keyword(Text) ->
    split_top_level_keyword(Text, 0, none, []).

split_top_level_keyword([], _Depth, _Quote, _Acc) ->
    none;
split_top_level_keyword([$\\, Escaped | Rest], Depth, Quote, Acc) when Quote =/= none ->
    split_top_level_keyword(Rest, Depth, Quote, [Escaped, $\\ | Acc]);
split_top_level_keyword([Quote | Rest], Depth, Quote, Acc) ->
    split_top_level_keyword(Rest, Depth, none, [Quote | Acc]);
split_top_level_keyword([$" | Rest], Depth, none, Acc) ->
    split_top_level_keyword(Rest, Depth, $", [$" | Acc]);
split_top_level_keyword([$' | Rest], Depth, none, Acc) ->
    split_top_level_keyword(Rest, Depth, $', [$' | Acc]);
split_top_level_keyword([Ch | Rest], Depth, none, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    split_top_level_keyword(Rest, Depth + 1, none, [Ch | Acc]);
split_top_level_keyword([Ch | Rest], Depth, none, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    split_top_level_keyword(Rest, Depth - 1, none, [Ch | Acc]);
split_top_level_keyword([$=, $= | Rest], Depth, none, Acc) ->
    split_top_level_keyword(Rest, Depth, none, [$=, $= | Acc]);
split_top_level_keyword([$!, $= | Rest], Depth, none, Acc) ->
    split_top_level_keyword(Rest, Depth, none, [$=, $! | Acc]);
split_top_level_keyword([$<, $= | Rest], Depth, none, Acc) ->
    split_top_level_keyword(Rest, Depth, none, [$=, $< | Acc]);
split_top_level_keyword([$>, $= | Rest], Depth, none, Acc) ->
    split_top_level_keyword(Rest, Depth, none, [$=, $> | Acc]);
split_top_level_keyword([$= | Rest], 0, none, Acc) ->
    Name = string:trim(lists:reverse(Acc)),
    ExprSource = string:trim(Rest),
    case valid_name(Name) andalso ExprSource =/= "" of
        true -> {keyword, Name, ExprSource};
        false -> none
    end;
split_top_level_keyword([Ch | Rest], Depth, Quote, Acc) ->
    split_top_level_keyword(Rest, Depth, Quote, [Ch | Acc]).

parse_param(Param) ->
    case string:split(Param, "=", leading) of
        ["/"] ->
            posonly_marker;
        ["*"] ->
            kwonly_marker;
        ["**" ++ Name] ->
            {TrimmedName, Annotation} = parse_param_name_annotation(Name),
            true = valid_name(TrimmedName),
            {kwarg_rest, list_to_binary(TrimmedName), Annotation};
        ["*" ++ Name] ->
            {TrimmedName, Annotation} = parse_param_name_annotation(Name),
            true = valid_name(TrimmedName),
            {vararg, list_to_binary(TrimmedName), Annotation};
        [Name, DefaultSource] ->
            {TrimmedName, Annotation} = parse_param_name_annotation(Name),
            true = valid_name(TrimmedName),
            case parse_expr(DefaultSource) of
                {ok, Expr} -> {param, list_to_binary(TrimmedName), Expr, Annotation};
                {error, Reason} -> throw({bad_default_argument, Param, Reason})
            end;
        [Name] ->
            {TrimmedName, Annotation} = parse_param_name_annotation(Name),
            true = valid_name(TrimmedName),
            {param, list_to_binary(TrimmedName), undefined, Annotation}
    end.

parse_param_name_annotation(NameText) ->
    case string:split(NameText, ":", leading) of
        [Name, AnnotationSource] ->
            Annotation =
                case parse_expr(AnnotationSource) of
                    {ok, Expr} -> Expr;
                    {error, _Reason} -> undefined
                end,
            {string:trim(Name), Annotation};
        [Name] ->
            {string:trim(Name), undefined}
    end.

parse_try_clauses([{Indent, Line} | Rest], Indent, Handlers, ElseBody, _FinallyBody) ->
    case parse_except_header(Line) of
        {ok, Pattern, Binding} ->
            {Body, Rest1} = parse_required_child_block(Line, Rest, Indent),
            parse_try_clauses(Rest1, Indent, [{Pattern, Binding, Body} | Handlers], ElseBody, []);
        not_except ->
            case Line of
                "else:" ->
                    case Handlers of
                        [] ->
                            throw({expected_except_before_else, Line});
                        _ ->
                            {Body, Rest1} = parse_required_child_block(Line, Rest, Indent),
                            parse_try_clauses(Rest1, Indent, Handlers, Body, [])
                    end;
                "finally:" ->
                    {FinallyBody, Rest1} = parse_required_child_block(Line, Rest, Indent),
                    {Handlers, ElseBody, FinallyBody, Rest1};
                _ ->
                    case Handlers of
                        [] -> throw({expected_except_or_finally, Line});
                        _ -> {Handlers, ElseBody, [], [{Indent, Line} | Rest]}
                    end
            end
    end;
parse_try_clauses(Rest, _Indent, [], [], []) ->
    throw({expected_except_or_finally, Rest});
parse_try_clauses(Rest, _Indent, Handlers, ElseBody, FinallyBody) ->
    {Handlers, ElseBody, FinallyBody, Rest}.

parse_except_header("except:") ->
    {ok, any, undefined};
parse_except_header("except " ++ Rest) ->
    case lists:reverse(Rest) of
        [$: | ReversedSpec] ->
            parse_except_spec(string:trim(lists:reverse(ReversedSpec)));
        _ ->
            not_except
    end;
parse_except_header(_Line) ->
    not_except.

parse_except_spec(Spec) ->
    case re:run(Spec, "^(.*)\\s+as\\s+([A-Za-z_][A-Za-z0-9_]*)$", [unicode, {capture, [1, 2], list}]) of
        {match, [ExprSource, Binding]} ->
            {ok, parse_exception_pattern(string:trim(ExprSource)), list_to_binary(Binding)};
        nomatch ->
            {ok, parse_exception_pattern(Spec), undefined}
    end.

parse_exception_pattern("") ->
    any;
parse_exception_pattern(ExprSource) ->
    case parse_expr(ExprSource) of
        {ok, Expr} -> Expr;
        {error, Reason} -> throw({bad_except_pattern, ExprSource, Reason})
    end.

split_augmented_assignment(Line) ->
    case re:run(Line, "^(.*?)\\s*(<<=|>>=|\\+=|-=|\\*=|//=|/=|%=|\\|=|&=|\\^=)\\s*(.+)$", [unicode, {capture, [1, 2, 3], list}]) of
        {match, [TargetText, OpText, ExprSource]} ->
            case parse_assignment_target(string:trim(TargetText)) of
                {ok, Target} -> {aug_assign, Target, augmented_assignment_op(OpText), string:trim(ExprSource)};
                error -> none
            end;
        nomatch ->
            none
    end.

augmented_assignment_op("+=") -> plus;
augmented_assignment_op("-=") -> minus;
augmented_assignment_op("*=") -> star;
augmented_assignment_op("//=") -> floor_div;
augmented_assignment_op("/=") -> slash;
augmented_assignment_op("%=") -> percent;
augmented_assignment_op("|=") -> pipe;
augmented_assignment_op("&=") -> amp;
augmented_assignment_op("^=") -> caret;
augmented_assignment_op("<<=") -> lshift;
augmented_assignment_op(">>=") -> rshift.

split_annotated_assignment(Line) ->
    case find_annotation_colon(Line, 0, 0, none) of
        none ->
            none;
        Pos ->
            {Left, [$: | Right]} = lists:split(Pos, Line),
            case parse_assignment_target(string:trim(Left)) of
                {ok, Target} ->
                    RightTrimmed = string:trim(Right),
                    case find_annotation_value(RightTrimmed, 0, 0, none) of
                        none ->
                            {ann_assign, Target, none};
                        ValuePos ->
                            {_Annotation, [$= | ExprSource]} = lists:split(ValuePos, RightTrimmed),
                            {ann_assign, Target, string:trim(ExprSource)}
                    end;
                error ->
                    none
            end
    end.

find_annotation_colon([], _Pos, _Depth, _Quote) ->
    none;
find_annotation_colon([$\\, _Escaped | Rest], Pos, Depth, Quote) when Quote =/= none ->
    find_annotation_colon(Rest, Pos + 2, Depth, Quote);
find_annotation_colon([Quote | Rest], Pos, Depth, Quote) ->
    find_annotation_colon(Rest, Pos + 1, Depth, none);
find_annotation_colon([$" | Rest], Pos, Depth, none) ->
    find_annotation_colon(Rest, Pos + 1, Depth, $");
find_annotation_colon([$' | Rest], Pos, Depth, none) ->
    find_annotation_colon(Rest, Pos + 1, Depth, $');
find_annotation_colon([Ch | Rest], Pos, Depth, none) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    find_annotation_colon(Rest, Pos + 1, Depth + 1, none);
find_annotation_colon([Ch | Rest], Pos, Depth, none) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    find_annotation_colon(Rest, Pos + 1, Depth - 1, none);
find_annotation_colon([$: | _Rest], Pos, 0, none) ->
    Pos;
find_annotation_colon([_Ch | Rest], Pos, Depth, Quote) ->
    find_annotation_colon(Rest, Pos + 1, Depth, Quote).

find_annotation_value([], _Pos, _Depth, _Quote) ->
    none;
find_annotation_value([$\\, _Escaped | Rest], Pos, Depth, Quote) when Quote =/= none ->
    find_annotation_value(Rest, Pos + 2, Depth, Quote);
find_annotation_value([Quote | Rest], Pos, Depth, Quote) ->
    find_annotation_value(Rest, Pos + 1, Depth, none);
find_annotation_value([$" | Rest], Pos, Depth, none) ->
    find_annotation_value(Rest, Pos + 1, Depth, $");
find_annotation_value([$' | Rest], Pos, Depth, none) ->
    find_annotation_value(Rest, Pos + 1, Depth, $');
find_annotation_value([Ch | Rest], Pos, Depth, none) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    find_annotation_value(Rest, Pos + 1, Depth + 1, none);
find_annotation_value([Ch | Rest], Pos, Depth, none) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    find_annotation_value(Rest, Pos + 1, Depth - 1, none);
find_annotation_value([$=, $= | Rest], Pos, Depth, none) ->
    find_annotation_value(Rest, Pos + 2, Depth, none);
find_annotation_value([$= | _Rest], Pos, 0, none) ->
    Pos;
find_annotation_value([_Ch | Rest], Pos, Depth, Quote) ->
    find_annotation_value(Rest, Pos + 1, Depth, Quote).

split_assignment(Line) ->
    case find_assignment(Line, 0, none) of
        none ->
            expr;
        Pos ->
            {Left, [$= | Right]} = lists:split(Pos, Line),
            Target = string:trim(Left),
            RightTrimmed = string:trim(Right),
            case parse_assignment_target(Target) of
                {ok, AssignmentTarget} ->
                    case split_assignment(RightTrimmed) of
                        expr -> assignment_statement_for_target(AssignmentTarget, RightTrimmed);
                        Next -> {assign_chain, [AssignmentTarget | assignment_targets(Next)], assignment_expr_source(Next)}
                    end;
                error ->
                    expr
            end
    end.

assignment_statement_for_target({target_name, Name}, ExprSource) ->
    {assign, binary_to_list(Name), ExprSource};
assignment_statement_for_target({target_attr, AttrTarget}, ExprSource) ->
    {assign_attr, AttrTarget, ExprSource};
assignment_statement_for_target({target_subscript, SubscriptTarget}, ExprSource) ->
    {assign_subscript, SubscriptTarget, ExprSource};
assignment_statement_for_target(Target, ExprSource) ->
    {assign_target, Target, ExprSource}.

assignment_targets({assign, Name, _ExprSource}) ->
    [{target_name, list_to_binary(Name)}];
assignment_targets({assign_attr, AttrTarget, _ExprSource}) ->
    [{target_attr, AttrTarget}];
assignment_targets({assign_subscript, SubscriptTarget, _ExprSource}) ->
    [{target_subscript, SubscriptTarget}];
assignment_targets({assign_target, Target, _ExprSource}) ->
    [Target];
assignment_targets({assign_chain, Targets, _ExprSource}) ->
    Targets.

assignment_expr_source({assign, _Name, ExprSource}) ->
    ExprSource;
assignment_expr_source({assign_attr, _Target, ExprSource}) ->
    ExprSource;
assignment_expr_source({assign_subscript, _Target, ExprSource}) ->
    ExprSource;
assignment_expr_source({assign_target, _Target, ExprSource}) ->
    ExprSource;
assignment_expr_source({assign_chain, _Targets, ExprSource}) ->
    ExprSource.

find_assignment([], _Pos, _Seen) ->
    none;
find_assignment([$= | Rest], Pos, none) ->
    case Rest of
        [$= | _] -> none;
        _ -> Pos
    end;
find_assignment([$!, $= | Rest], Pos, Seen) ->
    find_assignment(Rest, Pos + 2, Seen);
find_assignment([$<, $= | Rest], Pos, Seen) ->
    find_assignment(Rest, Pos + 2, Seen);
find_assignment([$>, $= | Rest], Pos, Seen) ->
    find_assignment(Rest, Pos + 2, Seen);
find_assignment([_ | Rest], Pos, Seen) ->
    find_assignment(Rest, Pos + 1, Seen).

valid_name([]) ->
    false;
valid_name([First | Rest]) ->
    is_name_start(First) andalso lists:all(fun is_name_continue/1, Rest).

parse_assignment_target(TargetText) ->
    try parse_assignment_target_tokens(tokens(TargetText))
    catch
        _Class:_Reason -> error
    end.

parse_assignment_target_tokens(Tokens) ->
    try
        case parse_target_tuple(Tokens) of
            {Target, []} -> {ok, Target};
            {_Target, _Rest} -> error
        end
    catch
        _Class:_Reason -> error
    end.

parse_target_tuple(Tokens) ->
    {First, Rest} = parse_target_atom(Tokens),
    case Rest of
        [comma | Rest1] -> parse_target_tuple_tail(Rest1, [First]);
        _ -> {First, Rest}
    end.

parse_target_tuple_tail([], Acc) ->
    {{target_tuple, lists:reverse(Acc)}, []};
parse_target_tuple_tail(Tokens, Acc) ->
    {Target, Rest} = parse_target_atom(Tokens),
    case Rest of
        [comma | Rest1] -> parse_target_tuple_tail(Rest1, [Target | Acc]);
        _ -> {{target_tuple, lists:reverse([Target | Acc])}, Rest}
    end.

parse_target_atom([star | Rest0]) ->
    {Target, Rest1} = parse_target_atom(Rest0),
    {{target_starred, Target}, Rest1};
parse_target_atom(Tokens) ->
    {Expr, Rest} = parse_lambda(Tokens),
    case expr_to_assignment_target(Expr) of
        {ok, Target} -> {Target, Rest};
        error -> throw({bad_assignment_target, Expr})
    end.

expr_to_assignment_target({var, Name}) ->
    {ok, {target_name, Name}};
expr_to_assignment_target({attr, _Object, _Name} = Attr) ->
    {ok, {target_attr, Attr}};
expr_to_assignment_target({subscript, _Object, _Index} = Subscript) ->
    {ok, {target_subscript, Subscript}};
expr_to_assignment_target({starred, Expr}) ->
    case expr_to_assignment_target(Expr) of
        {ok, Target} -> {ok, {target_starred, Target}};
        error -> error
    end;
expr_to_assignment_target({tuple, Items}) ->
    exprs_to_assignment_targets(Items, target_tuple);
expr_to_assignment_target({list, Items}) ->
    exprs_to_assignment_targets(Items, target_list);
expr_to_assignment_target(_Other) ->
    error.

exprs_to_assignment_targets(Items, Kind) ->
    exprs_to_assignment_targets(Items, Kind, []).

exprs_to_assignment_targets([], Kind, Acc) ->
    {ok, {Kind, lists:reverse(Acc)}};
exprs_to_assignment_targets([Item | Rest], Kind, Acc) ->
    case expr_to_assignment_target(Item) of
        {ok, Target} -> exprs_to_assignment_targets(Rest, Kind, [Target | Acc]);
        error -> error
    end.

lex([], Acc) ->
    lists:reverse(Acc);
lex([Ch | Rest], Acc) when Ch =:= $\s; Ch =:= $\t; Ch =:= $\r; Ch =:= $\n ->
    lex(Rest, Acc);
lex([Ch | Rest], Acc) when Ch >= $0, Ch =< $9 ->
    {Token, Tail} = take_number([Ch | Rest]),
    lex(Tail, [Token | Acc]);
lex([P1, P2, $", $", $" | Rest], Acc) when
    ((P1 =:= $b orelse P1 =:= $B) andalso (P2 =:= $r orelse P2 =:= $R)) orelse
    ((P1 =:= $r orelse P1 =:= $R) andalso (P2 =:= $b orelse P2 =:= $B)) ->
    {Bytes, Tail} = take_raw_triple_string(Rest, $", []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([P1, P2, $', $', $' | Rest], Acc) when
    ((P1 =:= $b orelse P1 =:= $B) andalso (P2 =:= $r orelse P2 =:= $R)) orelse
    ((P1 =:= $r orelse P1 =:= $R) andalso (P2 =:= $b orelse P2 =:= $B)) ->
    {Bytes, Tail} = take_raw_triple_string(Rest, $', []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([P1, P2, $" | Rest], Acc) when
    ((P1 =:= $b orelse P1 =:= $B) andalso (P2 =:= $r orelse P2 =:= $R)) orelse
    ((P1 =:= $r orelse P1 =:= $R) andalso (P2 =:= $b orelse P2 =:= $B)) ->
    {Bytes, Tail} = take_raw_string(Rest, $", []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([P1, P2, $' | Rest], Acc) when
    ((P1 =:= $b orelse P1 =:= $B) andalso (P2 =:= $r orelse P2 =:= $R)) orelse
    ((P1 =:= $r orelse P1 =:= $R) andalso (P2 =:= $b orelse P2 =:= $B)) ->
    {Bytes, Tail} = take_raw_string(Rest, $', []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([P1, P2, $", $", $" | Rest], Acc) when
    ((P1 =:= $f orelse P1 =:= $F) andalso (P2 =:= $r orelse P2 =:= $R)) orelse
    ((P1 =:= $r orelse P1 =:= $R) andalso (P2 =:= $f orelse P2 =:= $F)) ->
    {String, Tail} = take_fstring_triple_string(Rest, $", []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([P1, P2, $', $', $' | Rest], Acc) when
    ((P1 =:= $f orelse P1 =:= $F) andalso (P2 =:= $r orelse P2 =:= $R)) orelse
    ((P1 =:= $r orelse P1 =:= $R) andalso (P2 =:= $f orelse P2 =:= $F)) ->
    {String, Tail} = take_fstring_triple_string(Rest, $', []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([P1, P2, $" | Rest], Acc) when
    ((P1 =:= $f orelse P1 =:= $F) andalso (P2 =:= $r orelse P2 =:= $R)) orelse
    ((P1 =:= $r orelse P1 =:= $R) andalso (P2 =:= $f orelse P2 =:= $F)) ->
    {String, Tail} = take_fstring_string(Rest, $", []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([P1, P2, $' | Rest], Acc) when
    ((P1 =:= $f orelse P1 =:= $F) andalso (P2 =:= $r orelse P2 =:= $R)) orelse
    ((P1 =:= $r orelse P1 =:= $R) andalso (P2 =:= $f orelse P2 =:= $F)) ->
    {String, Tail} = take_fstring_string(Rest, $', []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$b, $", $", $" | Rest], Acc) ->
    {Bytes, Tail} = take_triple_string(Rest, $", []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([$b, $', $', $' | Rest], Acc) ->
    {Bytes, Tail} = take_triple_string(Rest, $', []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([$b, $" | Rest], Acc) ->
    {Bytes, Tail} = take_string(Rest, $", []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([$b, $' | Rest], Acc) ->
    {Bytes, Tail} = take_string(Rest, $', []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([$B, $", $", $" | Rest], Acc) ->
    {Bytes, Tail} = take_triple_string(Rest, $", []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([$B, $', $', $' | Rest], Acc) ->
    {Bytes, Tail} = take_triple_string(Rest, $', []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([$B, $" | Rest], Acc) ->
    {Bytes, Tail} = take_string(Rest, $", []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([$B, $' | Rest], Acc) ->
    {Bytes, Tail} = take_string(Rest, $', []),
    lex(Tail, [{bytes, unicode:characters_to_binary(Bytes)} | Acc]);
lex([$r, $", $", $" | Rest], Acc) ->
    {String, Tail} = take_raw_triple_string(Rest, $", []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$r, $', $', $' | Rest], Acc) ->
    {String, Tail} = take_raw_triple_string(Rest, $', []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$r, $" | Rest], Acc) ->
    {String, Tail} = take_raw_string(Rest, $", []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$r, $' | Rest], Acc) ->
    {String, Tail} = take_raw_string(Rest, $', []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$R, $", $", $" | Rest], Acc) ->
    {String, Tail} = take_raw_triple_string(Rest, $", []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$R, $', $', $' | Rest], Acc) ->
    {String, Tail} = take_raw_triple_string(Rest, $', []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$R, $" | Rest], Acc) ->
    {String, Tail} = take_raw_string(Rest, $", []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$R, $' | Rest], Acc) ->
    {String, Tail} = take_raw_string(Rest, $', []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$f, $", $", $" | Rest], Acc) ->
    {String, Tail} = take_fstring_triple_string(Rest, $", []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$f, $', $', $' | Rest], Acc) ->
    {String, Tail} = take_fstring_triple_string(Rest, $', []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$f, $" | Rest], Acc) ->
    {String, Tail} = take_fstring_string(Rest, $", []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$f, $' | Rest], Acc) ->
    {String, Tail} = take_fstring_string(Rest, $', []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$F, $", $", $" | Rest], Acc) ->
    {String, Tail} = take_fstring_triple_string(Rest, $", []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$F, $', $', $' | Rest], Acc) ->
    {String, Tail} = take_fstring_triple_string(Rest, $', []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$F, $" | Rest], Acc) ->
    {String, Tail} = take_fstring_string(Rest, $", []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$F, $' | Rest], Acc) ->
    {String, Tail} = take_fstring_string(Rest, $', []),
    lex(Tail, [{fstr, unicode:characters_to_binary(String)} | Acc]);
lex([$", $", $" | Rest], Acc) ->
    {String, Tail} = take_triple_string(Rest, $", []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$', $', $' | Rest], Acc) ->
    {String, Tail} = take_triple_string(Rest, $', []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$" | Rest], Acc) ->
    {String, Tail} = take_string(Rest, $", []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([$' | Rest], Acc) ->
    {String, Tail} = take_string(Rest, $', []),
    lex(Tail, [{str, unicode:characters_to_binary(String)} | Acc]);
lex([Ch | Rest], Acc) when Ch =:= $_; Ch >= $A, Ch =< $Z; Ch >= $a, Ch =< $z ->
    {Name, Tail} = take_while([Ch | Rest], fun is_name_continue/1),
    Token =
        case Name of
            "True" -> {bool, true};
            "False" -> {bool, false};
            "None" -> none;
            "and" -> and_kw;
            "or" -> or_kw;
            "not" -> not_kw;
            "in" -> in_kw;
            "is" -> is_kw;
            "if" -> if_kw;
            "else" -> else_kw;
            "for" -> for_kw;
            "async" -> async_kw;
            "lambda" -> lambda_kw;
            "await" -> await_kw;
            "yield" -> yield_kw;
            _ -> {name, list_to_binary(Name)}
        end,
    lex(Tail, [Token | Acc]);
lex([$+ | Rest], Acc) -> lex(Rest, [plus | Acc]);
lex([$- | Rest], Acc) -> lex(Rest, [minus | Acc]);
lex([$*, $* | Rest], Acc) -> lex(Rest, [starstar | Acc]);
lex([$* | Rest], Acc) -> lex(Rest, [star | Acc]);
lex([$/, $/ | Rest], Acc) -> lex(Rest, [floor_div | Acc]);
lex([$/ | Rest], Acc) -> lex(Rest, [slash | Acc]);
lex([$% | Rest], Acc) -> lex(Rest, [percent | Acc]);
lex([$| | Rest], Acc) -> lex(Rest, [pipe | Acc]);
lex([$& | Rest], Acc) -> lex(Rest, [amp | Acc]);
lex([$^ | Rest], Acc) -> lex(Rest, [caret | Acc]);
lex([$~ | Rest], Acc) -> lex(Rest, [tilde | Acc]);
lex([$=, $= | Rest], Acc) -> lex(Rest, [eqeq | Acc]);
lex([$= | Rest], Acc) -> lex(Rest, [equal | Acc]);
lex([$!, $= | Rest], Acc) -> lex(Rest, [noteq | Acc]);
lex([$<, $< | Rest], Acc) -> lex(Rest, [lshift | Acc]);
lex([$<, $= | Rest], Acc) -> lex(Rest, [lte | Acc]);
lex([$>, $> | Rest], Acc) -> lex(Rest, [rshift | Acc]);
lex([$>, $= | Rest], Acc) -> lex(Rest, [gte | Acc]);
lex([$< | Rest], Acc) -> lex(Rest, [lt | Acc]);
lex([$> | Rest], Acc) -> lex(Rest, [gt | Acc]);
lex([$( | Rest], Acc) -> lex(Rest, [lparen | Acc]);
lex([$) | Rest], Acc) -> lex(Rest, [rparen | Acc]);
lex([$., $., $. | Rest], Acc) -> lex(Rest, [ellipsis | Acc]);
lex([$. | Rest], Acc) -> lex(Rest, [dot | Acc]);
lex([$[ | Rest], Acc) -> lex(Rest, [lbracket | Acc]);
lex([$] | Rest], Acc) -> lex(Rest, [rbracket | Acc]);
lex([${ | Rest], Acc) -> lex(Rest, [lbrace | Acc]);
lex([$} | Rest], Acc) -> lex(Rest, [rbrace | Acc]);
lex([$, | Rest], Acc) -> lex(Rest, [comma | Acc]);
lex([$:,$= | Rest], Acc) -> lex(Rest, [walrus | Acc]);
lex([$: | Rest], Acc) -> lex(Rest, [colon | Acc]);
lex([Ch | _Rest], _Acc) ->
    throw({unexpected_character, Ch}).

take_while([Ch | Rest], Pred) ->
    case Pred(Ch) of
        true ->
            {Taken, Tail} = take_while(Rest, Pred),
            {[Ch | Taken], Tail};
        false ->
            {[], [Ch | Rest]}
    end;
take_while([], _Pred) ->
    {[], []}.

take_number([$0, Prefix | Rest]) when Prefix =:= $x; Prefix =:= $X ->
    {Digits0, Tail} = take_while(Rest, fun(C) -> C =:= $_ orelse is_hex_digit(C) end),
    Digits = strip_number_underscores(Digits0),
    {{int, list_to_integer(Digits, 16)}, Tail};
take_number([$0, Prefix | Rest]) when Prefix =:= $o; Prefix =:= $O ->
    {Digits0, Tail} = take_while(Rest, fun(C) -> C =:= $_ orelse (C >= $0 andalso C =< $7) end),
    Digits = strip_number_underscores(Digits0),
    {{int, list_to_integer(Digits, 8)}, Tail};
take_number([$0, Prefix | Rest]) when Prefix =:= $b; Prefix =:= $B ->
    {Digits0, Tail} = take_while(Rest, fun(C) -> C =:= $_ orelse C =:= $0 orelse C =:= $1 end),
    Digits = strip_number_underscores(Digits0),
    {{int, list_to_integer(Digits, 2)}, Tail};
take_number(Chars) ->
    {Digits0, Tail} = take_while(Chars, fun is_decimal_digit_or_underscore/1),
    Digits = strip_number_underscores(Digits0),
    case Tail of
        [$., Next | AfterDot] when Next >= $0, Next =< $9 ->
            {Fraction0, Rest} = take_while([Next | AfterDot], fun is_decimal_digit_or_underscore/1),
            Fraction = strip_number_underscores(Fraction0),
            take_number_exponent(Digits ++ "." ++ Fraction, Rest, float);
        _ ->
            take_number_exponent(Digits, Tail, int)
    end.

take_number_exponent(Base, [$e | Rest], Kind) ->
    take_number_exponent_digits(Base, Rest, Kind);
take_number_exponent(Base, [$E | Rest], Kind) ->
    take_number_exponent_digits(Base, Rest, Kind);
take_number_exponent(Base, Tail, float) ->
    take_imaginary_suffix({float, list_to_float(Base)}, Tail);
take_number_exponent(Base, Tail, int) ->
    take_imaginary_suffix({int, list_to_integer(Base)}, Tail).

take_number_exponent_digits(Base, [$+ | Rest], Kind) ->
    take_number_exponent_digits(Base, Rest, Kind, "+");
take_number_exponent_digits(Base, [$- | Rest], Kind) ->
    take_number_exponent_digits(Base, Rest, Kind, "-");
take_number_exponent_digits(Base, Rest, Kind) ->
    take_number_exponent_digits(Base, Rest, Kind, "").

take_number_exponent_digits(Base, Rest, Kind, Sign) ->
    {Digits0, Tail} = take_while(Rest, fun is_decimal_digit_or_underscore/1),
    Digits = strip_number_underscores(Digits0),
    case Digits of
        [] ->
            throw({bad_number, Base ++ "e" ++ Sign});
        _ ->
            FloatBase =
                case Kind of
                    float -> Base;
                    int -> Base ++ ".0"
                end,
            take_imaginary_suffix({float, list_to_float(FloatBase ++ "e" ++ Sign ++ Digits)}, Tail)
    end.

take_imaginary_suffix({Kind, Value}, [$j | Tail]) when Kind =:= int; Kind =:= float ->
    {{imag, Value * 1.0}, Tail};
take_imaginary_suffix({Kind, Value}, [$J | Tail]) when Kind =:= int; Kind =:= float ->
    {{imag, Value * 1.0}, Tail};
take_imaginary_suffix(Token, Tail) ->
    {Token, Tail}.

is_decimal_digit_or_underscore(C) ->
    C =:= $_ orelse (C >= $0 andalso C =< $9).

strip_number_underscores(Chars) ->
    [Char || Char <- Chars, Char =/= $_].

take_string([$\\ | Rest0], Quote, Acc) ->
    {Escaped, Rest} = take_escape(Rest0),
    take_string(Rest, Quote, lists:reverse(Escaped) ++ Acc);
take_string([Quote | Rest], Quote, Acc) ->
    {lists:reverse(Acc), Rest};
take_string([Ch | Rest], Quote, Acc) ->
    take_string(Rest, Quote, [Ch | Acc]);
take_string([], _Quote, _Acc) ->
    throw(unterminated_string).

take_triple_string([Quote, Quote, Quote | Rest], Quote, Acc) ->
    {lists:reverse(Acc), Rest};
take_triple_string([$\\ | Rest0], Quote, Acc) ->
    {Escaped, Rest} = take_escape(Rest0),
    take_triple_string(Rest, Quote, lists:reverse(Escaped) ++ Acc);
take_triple_string([Ch | Rest], Quote, Acc) ->
    take_triple_string(Rest, Quote, [Ch | Acc]);
take_triple_string([], _Quote, _Acc) ->
    throw(unterminated_string).

take_escape([$a | Rest]) -> {[7], Rest};
take_escape([$b | Rest]) -> {[8], Rest};
take_escape([$f | Rest]) -> {[12], Rest};
take_escape([$n | Rest]) -> {[$\n], Rest};
take_escape([$r | Rest]) -> {[$\r], Rest};
take_escape([$t | Rest]) -> {[$\t], Rest};
take_escape([$v | Rest]) -> {[11], Rest};
take_escape([$\\ | Rest]) -> {[$\\], Rest};
take_escape([$' | Rest]) -> {[$'], Rest};
take_escape([$" | Rest]) -> {[$"], Rest};
take_escape([$\n | Rest]) -> {[], Rest};
take_escape([$x, A, B | Rest]) ->
    {[hex_escape([A, B])], Rest};
take_escape([$u, A, B, C, D | Rest]) ->
    {[hex_escape([A, B, C, D])], Rest};
take_escape([$U, A, B, C, D, E, F, G, H | Rest]) ->
    {[hex_escape([A, B, C, D, E, F, G, H])], Rest};
take_escape([First | _Rest] = Chars) when First >= $0, First =< $7 ->
    take_octal_escape(Chars, 0, 0);
take_escape([Escaped | Rest]) ->
    {[$\\, Escaped], Rest};
take_escape([]) ->
    {[$\\], []}.

take_octal_escape([Char | Rest], Count, Value) when Count < 3, Char >= $0, Char =< $7 ->
    take_octal_escape(Rest, Count + 1, Value * 8 + (Char - $0));
take_octal_escape(Rest, _Count, Value) ->
    {[Value], Rest}.

hex_escape(Digits) ->
    lists:foldl(
        fun(Digit, Acc) ->
            case hex_value(Digit) of
                error -> throw({bad_escape, Digits});
                Value -> Acc * 16 + Value
            end
        end,
        0,
        Digits
    ).

hex_value(Char) when Char >= $0, Char =< $9 ->
    Char - $0;
hex_value(Char) when Char >= $a, Char =< $f ->
    Char - $a + 10;
hex_value(Char) when Char >= $A, Char =< $F ->
    Char - $A + 10;
hex_value(_Char) ->
    error.

take_fstring_string(Chars, Quote, Acc) ->
    take_fstring_string(Chars, Quote, literal, 0, none, Acc).

take_fstring_string([$\\, Escaped | Rest], Quote, literal, Depth, ExprQuote, Acc) ->
    take_fstring_string(Rest, Quote, literal, Depth, ExprQuote, [Escaped, $\\ | Acc]);
take_fstring_string([Quote | Rest], Quote, literal, _Depth, _ExprQuote, Acc) ->
    {lists:reverse(Acc), Rest};
take_fstring_string([${ | Rest], Quote, literal, _Depth, _ExprQuote, Acc) ->
    take_fstring_string(Rest, Quote, expr, 0, none, [${ | Acc]);
take_fstring_string([$\\, Escaped | Rest], Quote, expr, Depth, ExprQuote, Acc) when ExprQuote =/= none ->
    take_fstring_string(Rest, Quote, expr, Depth, ExprQuote, [Escaped, $\\ | Acc]);
take_fstring_string([ExprQuote | Rest], Quote, expr, Depth, ExprQuote, Acc) ->
    take_fstring_string(Rest, Quote, expr, Depth, none, [ExprQuote | Acc]);
take_fstring_string([$" | Rest], Quote, expr, Depth, none, Acc) ->
    take_fstring_string(Rest, Quote, expr, Depth, $", [$" | Acc]);
take_fstring_string([$' | Rest], Quote, expr, Depth, none, Acc) ->
    take_fstring_string(Rest, Quote, expr, Depth, $', [$' | Acc]);
take_fstring_string([Ch | Rest], Quote, expr, Depth, none, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    take_fstring_string(Rest, Quote, expr, Depth + 1, none, [Ch | Acc]);
take_fstring_string([$} | Rest], Quote, expr, 0, none, Acc) ->
    take_fstring_string(Rest, Quote, literal, 0, none, [$} | Acc]);
take_fstring_string([Ch | Rest], Quote, expr, Depth, none, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    take_fstring_string(Rest, Quote, expr, Depth - 1, none, [Ch | Acc]);
take_fstring_string([Ch | Rest], Quote, Mode, Depth, ExprQuote, Acc) ->
    take_fstring_string(Rest, Quote, Mode, Depth, ExprQuote, [Ch | Acc]);
take_fstring_string([], _Quote, _Mode, _Depth, _ExprQuote, _Acc) ->
    throw(unterminated_string).

take_fstring_triple_string(Chars, Quote, Acc) ->
    take_fstring_triple_string(Chars, Quote, literal, 0, none, Acc).

take_fstring_triple_string([Quote, Quote, Quote | Rest], Quote, literal, _Depth, _ExprQuote, Acc) ->
    {lists:reverse(Acc), Rest};
take_fstring_triple_string([${ | Rest], Quote, literal, _Depth, _ExprQuote, Acc) ->
    take_fstring_triple_string(Rest, Quote, expr, 0, none, [${ | Acc]);
take_fstring_triple_string([$\\, Escaped | Rest], Quote, expr, Depth, ExprQuote, Acc) when ExprQuote =/= none ->
    take_fstring_triple_string(Rest, Quote, expr, Depth, ExprQuote, [Escaped, $\\ | Acc]);
take_fstring_triple_string([ExprQuote | Rest], Quote, expr, Depth, ExprQuote, Acc) ->
    take_fstring_triple_string(Rest, Quote, expr, Depth, none, [ExprQuote | Acc]);
take_fstring_triple_string([$" | Rest], Quote, expr, Depth, none, Acc) ->
    take_fstring_triple_string(Rest, Quote, expr, Depth, $", [$" | Acc]);
take_fstring_triple_string([$' | Rest], Quote, expr, Depth, none, Acc) ->
    take_fstring_triple_string(Rest, Quote, expr, Depth, $', [$' | Acc]);
take_fstring_triple_string([Ch | Rest], Quote, expr, Depth, none, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    take_fstring_triple_string(Rest, Quote, expr, Depth + 1, none, [Ch | Acc]);
take_fstring_triple_string([$} | Rest], Quote, expr, 0, none, Acc) ->
    take_fstring_triple_string(Rest, Quote, literal, 0, none, [$} | Acc]);
take_fstring_triple_string([Ch | Rest], Quote, expr, Depth, none, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    take_fstring_triple_string(Rest, Quote, expr, Depth - 1, none, [Ch | Acc]);
take_fstring_triple_string([Ch | Rest], Quote, Mode, Depth, ExprQuote, Acc) ->
    take_fstring_triple_string(Rest, Quote, Mode, Depth, ExprQuote, [Ch | Acc]);
take_fstring_triple_string([], _Quote, _Mode, _Depth, _ExprQuote, _Acc) ->
    throw(unterminated_string).

take_raw_string(Chars, Quote, Acc) ->
    take_raw_string(Chars, Quote, Acc, 0).

take_raw_string([Quote | Rest], Quote, Acc, Backslashes) ->
    case Backslashes rem 2 of
        0 -> {lists:reverse(Acc), Rest};
        1 -> take_raw_string(Rest, Quote, [Quote | Acc], 0)
    end;
take_raw_string([$\\ | Rest], Quote, Acc, Backslashes) ->
    take_raw_string(Rest, Quote, [$\\ | Acc], Backslashes + 1);
take_raw_string([Ch | Rest], Quote, Acc, _Backslashes) ->
    take_raw_string(Rest, Quote, [Ch | Acc], 0);
take_raw_string([], _Quote, _Acc, _Backslashes) ->
    throw(unterminated_string).

take_raw_triple_string([$\\, Quote | Rest], Quote, Acc) ->
    take_raw_triple_string(Rest, Quote, [Quote, $\\ | Acc]);
take_raw_triple_string([Quote, Quote, Quote | Rest], Quote, Acc) ->
    {lists:reverse(Acc), Rest};
take_raw_triple_string([Ch | Rest], Quote, Acc) ->
    take_raw_triple_string(Rest, Quote, [Ch | Acc]);
take_raw_triple_string([], _Quote, _Acc) ->
    throw(unterminated_string).

is_name_start(Ch) ->
    Ch =:= $_ orelse (Ch >= $A andalso Ch =< $Z) orelse (Ch >= $a andalso Ch =< $z).

is_name_continue(Ch) ->
    is_name_start(Ch) orelse (Ch >= $0 andalso Ch =< $9).

is_hex_digit(Ch) ->
    (Ch >= $0 andalso Ch =< $9) orelse
        (Ch >= $a andalso Ch =< $f) orelse
        (Ch >= $A andalso Ch =< $F).

parse_lambda([lambda_kw, colon | Rest]) ->
    {Expr, Rest1} = parse_lambda(Rest),
    {{lambda, [], Expr}, Rest1};
parse_lambda([lambda_kw | Rest]) ->
    {Params, ExprTokens} = take_lambda_params(Rest),
    {Expr, Rest1} = parse_lambda(ExprTokens),
    {{lambda, Params, Expr}, Rest1};
parse_lambda(Tokens) ->
    parse_named_expr(Tokens).

parse_named_expr([{name, Name}, walrus | Rest]) ->
    {Expr, Rest1} = parse_named_expr(Rest),
    {{named_expr, Name, Expr}, Rest1};
parse_named_expr(Tokens) ->
    parse_if_expr(Tokens).

parse_if_expr(Tokens) ->
    {ThenExpr, Rest} = parse_or(Tokens),
    case Rest of
        [if_kw | Rest1] ->
            {Condition, Rest2} = parse_or(Rest1),
            case Rest2 of
                [else_kw | Rest3] ->
                    {ElseExpr, Rest4} = parse_lambda(Rest3),
                    {{if_expr, Condition, ThenExpr, ElseExpr}, Rest4};
                _ ->
                    {ThenExpr, Rest}
            end;
        _ ->
            {ThenExpr, Rest}
    end.

take_lambda_params(Tokens) ->
    {Groups, Rest} = split_lambda_param_groups(Tokens, 0, [], []),
    {[parse_lambda_param(Group) || Group <- Groups], Rest}.

split_lambda_param_groups([colon | Rest], 0, Current, Acc) ->
    {lists:reverse(flush_lambda_param(Current, Acc)), Rest};
split_lambda_param_groups([comma | Rest], 0, Current, Acc) ->
    split_lambda_param_groups(Rest, 0, [], flush_lambda_param(Current, Acc));
split_lambda_param_groups([Token | Rest], Depth, Current, Acc) when Token =:= lparen; Token =:= lbracket; Token =:= lbrace ->
    split_lambda_param_groups(Rest, Depth + 1, [Token | Current], Acc);
split_lambda_param_groups([Token | Rest], Depth, Current, Acc) when Token =:= rparen; Token =:= rbracket; Token =:= rbrace ->
    split_lambda_param_groups(Rest, Depth - 1, [Token | Current], Acc);
split_lambda_param_groups([Token | Rest], Depth, Current, Acc) ->
    split_lambda_param_groups(Rest, Depth, [Token | Current], Acc);
split_lambda_param_groups([], _Depth, _Current, _Acc) ->
    throw({bad_lambda_params}).

flush_lambda_param([], Acc) ->
    Acc;
flush_lambda_param(Current, Acc) ->
    [lists:reverse(Current) | Acc].

parse_lambda_param([slash]) ->
    posonly_marker;
parse_lambda_param([star]) ->
    kwonly_marker;
parse_lambda_param([star, {name, Name}]) ->
    {vararg, Name};
parse_lambda_param([starstar, {name, Name}]) ->
    {kwarg_rest, Name};
parse_lambda_param([{name, Name}]) ->
    {param, Name, undefined};
parse_lambda_param([{name, Name}, equal | DefaultTokens]) ->
    case parse_lambda(DefaultTokens) of
        {Default, []} -> {param, Name, Default};
        {_Default, Rest} -> throw({bad_lambda_default, Rest})
    end;
parse_lambda_param(_Tokens) ->
    throw({bad_lambda_params}).

parse_or(Tokens) ->
    {Left, Rest} = parse_and(Tokens),
    parse_or_tail(Left, Rest).

parse_or_tail(Left, [or_kw | Rest]) ->
    {Right, Rest1} = parse_and(Rest),
    parse_or_tail({boolop, or_op, Left, Right}, Rest1);
parse_or_tail(Left, Rest) ->
    {Left, Rest}.

parse_and(Tokens) ->
    {Left, Rest} = parse_not(Tokens),
    parse_and_tail(Left, Rest).

parse_and_tail(Left, [and_kw | Rest]) ->
    {Right, Rest1} = parse_not(Rest),
    parse_and_tail({boolop, and_op, Left, Right}, Rest1);
parse_and_tail(Left, Rest) ->
    {Left, Rest}.

parse_not([not_kw | Rest]) ->
    {Expr, Rest1} = parse_not(Rest),
    {{unary, not_op, Expr}, Rest1};
parse_not(Tokens) ->
    parse_compare(Tokens).

parse_compare(Tokens) ->
    {Left, Rest} = parse_bit_or(Tokens),
    parse_compare_tail(Left, Rest, []).

parse_compare_tail(Left, Tokens, Acc) ->
    case take_compare_op(Tokens) of
        {ok, Op, Rest} ->
            {Right, Rest1} = parse_bit_or(Rest),
            parse_compare_tail(Left, Rest1, [{Op, Right} | Acc]);
        none ->
            case lists:reverse(Acc) of
                [] -> {Left, Tokens};
                [{Op, Right}] -> {{compare, Op, Left, Right}, Tokens};
                Chain -> {{compare_chain, Left, Chain}, Tokens}
            end
    end.

take_compare_op([eqeq | Rest]) -> {ok, eq, Rest};
take_compare_op([noteq | Rest]) -> {ok, ne, Rest};
take_compare_op([lt | Rest]) -> {ok, lt, Rest};
take_compare_op([lte | Rest]) -> {ok, lte, Rest};
take_compare_op([gt | Rest]) -> {ok, gt, Rest};
take_compare_op([gte | Rest]) -> {ok, gte, Rest};
take_compare_op([is_kw, not_kw | Rest]) -> {ok, is_not, Rest};
take_compare_op([is_kw | Rest]) -> {ok, is, Rest};
take_compare_op([not_kw, in_kw | Rest]) -> {ok, not_in, Rest};
take_compare_op([in_kw | Rest]) -> {ok, in, Rest};
take_compare_op(_Tokens) -> none.

parse_bit_or(Tokens) ->
    {Left, Rest} = parse_bit_xor(Tokens),
    parse_bit_or_tail(Left, Rest).

parse_bit_or_tail(Left, [pipe | Rest]) ->
    {Right, Rest1} = parse_bit_xor(Rest),
    parse_bit_or_tail({binop, pipe, Left, Right}, Rest1);
parse_bit_or_tail(Left, Rest) ->
    {Left, Rest}.

parse_bit_xor(Tokens) ->
    {Left, Rest} = parse_bit_and(Tokens),
    parse_bit_xor_tail(Left, Rest).

parse_bit_xor_tail(Left, [caret | Rest]) ->
    {Right, Rest1} = parse_bit_and(Rest),
    parse_bit_xor_tail({binop, caret, Left, Right}, Rest1);
parse_bit_xor_tail(Left, Rest) ->
    {Left, Rest}.

parse_bit_and(Tokens) ->
    {Left, Rest} = parse_shift(Tokens),
    parse_bit_and_tail(Left, Rest).

parse_bit_and_tail(Left, [amp | Rest]) ->
    {Right, Rest1} = parse_shift(Rest),
    parse_bit_and_tail({binop, amp, Left, Right}, Rest1);
parse_bit_and_tail(Left, Rest) ->
    {Left, Rest}.

parse_shift(Tokens) ->
    {Left, Rest} = parse_add(Tokens),
    parse_shift_tail(Left, Rest).

parse_shift_tail(Left, [lshift | Rest]) ->
    {Right, Rest1} = parse_add(Rest),
    parse_shift_tail({binop, lshift, Left, Right}, Rest1);
parse_shift_tail(Left, [rshift | Rest]) ->
    {Right, Rest1} = parse_add(Rest),
    parse_shift_tail({binop, rshift, Left, Right}, Rest1);
parse_shift_tail(Left, Rest) ->
    {Left, Rest}.

parse_add(Tokens) ->
    {Left, Rest} = parse_mul(Tokens),
    parse_add_tail(Left, Rest).

parse_add_tail(Left, [plus | Rest]) ->
    {Right, Rest1} = parse_mul(Rest),
    parse_add_tail({binop, plus, Left, Right}, Rest1);
parse_add_tail(Left, [minus | Rest]) ->
    {Right, Rest1} = parse_mul(Rest),
    parse_add_tail({binop, minus, Left, Right}, Rest1);
parse_add_tail(Left, Rest) ->
    {Left, Rest}.

parse_mul(Tokens) ->
    {Left, Rest} = parse_factor(Tokens),
    parse_mul_tail(Left, Rest).

parse_mul_tail(Left, [star | Rest]) ->
    {Right, Rest1} = parse_factor(Rest),
    parse_mul_tail({binop, star, Left, Right}, Rest1);
parse_mul_tail(Left, [slash | Rest]) ->
    {Right, Rest1} = parse_factor(Rest),
    parse_mul_tail({binop, slash, Left, Right}, Rest1);
parse_mul_tail(Left, [floor_div | Rest]) ->
    {Right, Rest1} = parse_factor(Rest),
    parse_mul_tail({binop, floor_div, Left, Right}, Rest1);
parse_mul_tail(Left, [percent | Rest]) ->
    {Right, Rest1} = parse_factor(Rest),
    parse_mul_tail({binop, percent, Left, Right}, Rest1);
parse_mul_tail(Left, Rest) ->
    {Left, Rest}.

parse_factor([plus | Rest]) ->
    parse_factor(Rest);
parse_factor([minus | Rest]) ->
    {Expr, Rest1} = parse_factor(Rest),
    {{unary, neg, Expr}, Rest1};
parse_factor([tilde | Rest]) ->
    {Expr, Rest1} = parse_factor(Rest),
    {{unary, invert, Expr}, Rest1};
parse_factor([await_kw | Rest]) ->
    {Expr, Rest1} = parse_factor(Rest),
    {{await, Expr}, Rest1};
parse_factor(Tokens) ->
    parse_power(Tokens).

parse_power(Tokens) ->
    {Primary, Rest} = parse_primary(Tokens),
    {Postfix, Rest1} = parse_postfix(Primary, Rest),
    case Rest1 of
        [starstar | Rest2] ->
            {Right, Rest3} = parse_factor(Rest2),
            {{binop, pow, Postfix, Right}, Rest3};
        _ ->
            {Postfix, Rest1}
    end.

parse_primary([{int, Value} | Rest]) ->
    {{int, Value}, Rest};
parse_primary([{float, Value} | Rest]) ->
    {{float, Value}, Rest};
parse_primary([{imag, Value} | Rest]) ->
    {{complex, 0.0, Value}, Rest};
parse_primary([{str, Value} | Rest]) ->
    {{str, Value}, Rest};
parse_primary([{fstr, Value} | Rest]) ->
    {{joined_str, parse_fstring_parts(Value)}, Rest};
parse_primary([{bytes, Value} | Rest]) ->
    {{bytes, Value}, Rest};
parse_primary([{bool, Value} | Rest]) ->
    {{bool, Value}, Rest};
parse_primary([none | Rest]) ->
    {{none}, Rest};
parse_primary([ellipsis | Rest]) ->
    {{ellipsis}, Rest};
parse_primary([{name, Name} | Rest]) ->
    {{var, Name}, Rest};
parse_primary([yield_kw | Rest]) ->
    {{yield_expr, {none}}, Rest};
parse_primary([lparen, rparen | Rest]) ->
    {{tuple, []}, Rest};
parse_primary([lparen, star | Rest]) ->
    parse_tuple_literal([star | Rest], []);
parse_primary([lparen | Rest]) ->
    {Expr, Rest1} = parse_lambda(Rest),
    case Rest1 of
        [for_kw | _Rest2] = CompRest ->
            {Clauses, Rest3} = parse_comprehension_clauses(CompRest),
            case Rest3 of
                [rparen | Rest4] -> {{gen_expr, Expr, Clauses}, Rest4};
                _ -> throw({expected, rparen})
            end;
        [async_kw, for_kw | _Rest2] = CompRest ->
            {Clauses, Rest3} = parse_comprehension_clauses(CompRest),
            case Rest3 of
                [rparen | Rest4] -> {{gen_expr, Expr, Clauses}, Rest4};
                _ -> throw({expected, rparen})
            end;
        [comma | Rest2] -> parse_tuple_literal(Rest2, [Expr]);
        [rparen | Rest2] -> {Expr, Rest2};
        _ -> throw({expected, rparen})
    end;
parse_primary([lbracket | Rest]) ->
    parse_list_literal(Rest, []);
parse_primary([lbrace | Rest]) ->
    parse_brace_literal(Rest);
parse_primary([]) ->
    throw(unexpected_end);
parse_primary([Token | _Rest]) ->
    throw({unexpected_token, Token}).

parse_fstring_parts(Value) ->
    parse_fstring_chars(binary_to_list(Value), [], []).

parse_fstring_chars([], LiteralAcc, PartsAcc) ->
    lists:reverse(flush_fstring_literal(LiteralAcc, PartsAcc));
parse_fstring_chars([${, ${ | Rest], LiteralAcc, PartsAcc) ->
    parse_fstring_chars(Rest, [${ | LiteralAcc], PartsAcc);
parse_fstring_chars([$}, $} | Rest], LiteralAcc, PartsAcc) ->
    parse_fstring_chars(Rest, [$} | LiteralAcc], PartsAcc);
parse_fstring_chars([${ | Rest], LiteralAcc, PartsAcc0) ->
    {ExprText, Rest1} = take_fstring_expr(Rest, []),
    PartsAcc1 = flush_fstring_literal(LiteralAcc, PartsAcc0),
    parse_fstring_chars(Rest1, [], [parse_fstring_expr(ExprText) | PartsAcc1]);
parse_fstring_chars([Ch | Rest], LiteralAcc, PartsAcc) ->
    parse_fstring_chars(Rest, [Ch | LiteralAcc], PartsAcc).

flush_fstring_literal([], PartsAcc) ->
    PartsAcc;
flush_fstring_literal(LiteralAcc, PartsAcc) ->
    [{literal, unicode:characters_to_binary(lists:reverse(LiteralAcc))} | PartsAcc].

take_fstring_expr(Chars, Acc) ->
    take_fstring_expr(Chars, 0, none, Acc).

take_fstring_expr([$} | Rest], 0, none, Acc) ->
    {lists:reverse(Acc), Rest};
take_fstring_expr([$\\, Escaped | Rest], Depth, Quote, Acc) when Quote =/= none ->
    take_fstring_expr(Rest, Depth, Quote, [Escaped, $\\ | Acc]);
take_fstring_expr([Quote | Rest], Depth, Quote, Acc) ->
    take_fstring_expr(Rest, Depth, none, [Quote | Acc]);
take_fstring_expr([$" | Rest], Depth, none, Acc) ->
    take_fstring_expr(Rest, Depth, $", [$" | Acc]);
take_fstring_expr([$' | Rest], Depth, none, Acc) ->
    take_fstring_expr(Rest, Depth, $', [$' | Acc]);
take_fstring_expr([Ch | Rest], Depth, none, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    take_fstring_expr(Rest, Depth + 1, none, [Ch | Acc]);
take_fstring_expr([Ch | Rest], Depth, none, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    take_fstring_expr(Rest, Depth - 1, none, [Ch | Acc]);
take_fstring_expr([Ch | Rest], Depth, Quote, Acc) ->
    take_fstring_expr(Rest, Depth, Quote, [Ch | Acc]);
take_fstring_expr([], _Depth, _Quote, _Acc) ->
    throw(unterminated_fstring_expression).

parse_fstring_expr(ExprText0) ->
    {ExprText, Conversion} = split_fstring_conversion(string:trim(ExprText0)),
    {ExprSource, FormatSpec} = split_fstring_format_spec(ExprText),
    {DebugPrefix, FinalExprSource} = split_fstring_debug_expr(ExprSource),
    case parse_expr(FinalExprSource) of
        {ok, Expr} ->
            case DebugPrefix of
                none -> {formatted, Expr, Conversion, FormatSpec};
                Prefix -> {formatted_debug, Prefix, Expr, Conversion, FormatSpec}
            end;
        {error, Reason} -> throw({bad_fstring_expression, ExprText, Reason})
    end.

split_fstring_conversion(ExprText) ->
    case string:split(ExprText, "!", leading) of
        [Expr, [Conv | _Rest]] when Conv =:= $r; Conv =:= $s; Conv =:= $a ->
            {string:trim(Expr), Conv};
        [_Expr, _BadConversion] ->
            throw({bad_fstring_conversion, ExprText});
        [Expr] ->
            {Expr, none}
    end.

split_fstring_format_spec(ExprText) ->
    split_fstring_format_spec(ExprText, 0, none, []).

split_fstring_format_spec([], _Balance, _Quote, Acc) ->
    {string:trim(lists:reverse(Acc)), none};
split_fstring_format_spec([$\\, Escaped | Rest], Balance, Quote, Acc) when Quote =/= none ->
    split_fstring_format_spec(Rest, Balance, Quote, [Escaped, $\\ | Acc]);
split_fstring_format_spec([Quote | Rest], Balance, Quote, Acc) ->
    split_fstring_format_spec(Rest, Balance, none, [Quote | Acc]);
split_fstring_format_spec([$" | Rest], Balance, none, Acc) ->
    split_fstring_format_spec(Rest, Balance, $", [$" | Acc]);
split_fstring_format_spec([$' | Rest], Balance, none, Acc) ->
    split_fstring_format_spec(Rest, Balance, $', [$' | Acc]);
split_fstring_format_spec([Ch | Rest], Balance, none, Acc) when Ch =:= $(; Ch =:= $[; Ch =:= ${ ->
    split_fstring_format_spec(Rest, Balance + 1, none, [Ch | Acc]);
split_fstring_format_spec([Ch | Rest], Balance, none, Acc) when Ch =:= $); Ch =:= $]; Ch =:= $} ->
    split_fstring_format_spec(Rest, Balance - 1, none, [Ch | Acc]);
split_fstring_format_spec([$: | Rest], 0, none, Acc) ->
    {string:trim(lists:reverse(Acc)), unicode:characters_to_binary(string:trim(Rest))};
split_fstring_format_spec([Ch | Rest], Balance, Quote, Acc) ->
    split_fstring_format_spec(Rest, Balance, Quote, [Ch | Acc]).

split_fstring_debug_expr(ExprSource0) ->
    ExprSource = string:trim(ExprSource0, trailing),
    case lists:reverse(ExprSource) of
        [$= | ReversedExpr] ->
            Prefix = unicode:characters_to_binary(ExprSource),
            {Prefix, string:trim(lists:reverse(ReversedExpr))};
        _ ->
            {none, ExprSource0}
    end.

parse_postfix(Expr, [lparen | Rest]) ->
    {Args, Rest1} = parse_arg_list(Rest, []),
    parse_postfix({call, Expr, Args}, Rest1);
parse_postfix(Expr, [dot, {name, Name} | Rest]) ->
    parse_postfix({attr, Expr, Name}, Rest);
parse_postfix(Expr, [lbracket | Rest]) ->
    {Subscript, Rest1} = parse_subscript(Rest),
    case Rest1 of
        [rbracket | Rest2] -> parse_postfix({subscript, Expr, Subscript}, Rest2);
        _ -> throw({expected, rbracket})
    end;
parse_postfix(Expr, Rest) ->
    {Expr, Rest}.

parse_subscript([colon | Rest]) ->
    parse_slice_stop(undefined, Rest);
parse_subscript(Tokens) ->
    {Index, Rest} = parse_lambda(Tokens),
    case Rest of
        [comma | Rest1] -> parse_subscript_tuple(Rest1, [Index]);
        [colon | Rest1] -> parse_slice_stop(Index, Rest1);
        _ -> {Index, Rest}
    end.

parse_subscript_tuple([rbracket | _Rest] = Rest, Acc) ->
    {{tuple, lists:reverse(Acc)}, Rest};
parse_subscript_tuple(Tokens, Acc) ->
    {Expr, Rest} = parse_lambda(Tokens),
    case Rest of
        [comma | Rest1] -> parse_subscript_tuple(Rest1, [Expr | Acc]);
        _ -> {{tuple, lists:reverse([Expr | Acc])}, Rest}
    end.

parse_slice_stop(Start, [rbracket | _Rest] = Rest) ->
    {{slice, Start, undefined}, Rest};
parse_slice_stop(Start, [colon | Rest]) ->
    parse_slice_step(Start, undefined, Rest);
parse_slice_stop(Start, Tokens) ->
    {Stop, Rest} = parse_lambda(Tokens),
    case Rest of
        [colon | Rest1] -> parse_slice_step(Start, Stop, Rest1);
        _ -> {{slice, Start, Stop}, Rest}
    end.

parse_slice_step(Start, Stop, [rbracket | _Rest] = Rest) ->
    {{slice, Start, Stop, undefined}, Rest};
parse_slice_step(Start, Stop, Tokens) ->
    {Step, Rest} = parse_lambda(Tokens),
    {{slice, Start, Stop, Step}, Rest}.

parse_arg_list([rparen | Rest], Acc) ->
    {lists:reverse(Acc), Rest};
parse_arg_list([starstar | Rest], Acc) ->
    {Expr, Rest1} = parse_lambda(Rest),
    case Rest1 of
        [comma, rparen | Rest2] -> {lists:reverse([{starstar_kwarg, Expr} | Acc]), Rest2};
        [comma | Rest2] -> parse_arg_list(Rest2, [{starstar_kwarg, Expr} | Acc]);
        [rparen | Rest2] -> {lists:reverse([{starstar_kwarg, Expr} | Acc]), Rest2};
        _ -> throw({expected, comma_or_rparen})
    end;
parse_arg_list([star | Rest], Acc) ->
    {Expr, Rest1} = parse_lambda(Rest),
    case Rest1 of
        [comma, rparen | Rest2] -> {lists:reverse([{star_arg, Expr} | Acc]), Rest2};
        [comma | Rest2] -> parse_arg_list(Rest2, [{star_arg, Expr} | Acc]);
        [rparen | Rest2] -> {lists:reverse([{star_arg, Expr} | Acc]), Rest2};
        _ -> throw({expected, comma_or_rparen})
    end;
parse_arg_list([{name, Name}, equal | Rest], Acc) ->
    {Expr, Rest1} = parse_lambda(Rest),
    case Rest1 of
        [comma, rparen | Rest2] -> {lists:reverse([{kwarg, Name, Expr} | Acc]), Rest2};
        [comma | Rest2] -> parse_arg_list(Rest2, [{kwarg, Name, Expr} | Acc]);
        [rparen | Rest2] -> {lists:reverse([{kwarg, Name, Expr} | Acc]), Rest2};
        _ -> throw({expected, comma_or_rparen})
    end;
parse_arg_list(Tokens, Acc) ->
    {Expr, Rest} = parse_lambda(Tokens),
    case Rest of
        [for_kw | _Rest1] = CompRest ->
            {Clauses, Rest2} = parse_comprehension_clauses(CompRest),
            parse_generator_arg(Expr, Clauses, Rest2, Acc);
        [async_kw, for_kw | _Rest1] = CompRest ->
            {Clauses, Rest2} = parse_comprehension_clauses(CompRest),
            parse_generator_arg(Expr, Clauses, Rest2, Acc);
        [comma, rparen | Rest2] -> {lists:reverse([{arg, Expr} | Acc]), Rest2};
        [comma | Rest2] -> parse_arg_list(Rest2, [{arg, Expr} | Acc]);
        [rparen | Rest2] -> {lists:reverse([{arg, Expr} | Acc]), Rest2};
        _ -> throw({expected, comma_or_rparen})
    end.

parse_comprehension_clauses([for_kw | Rest]) ->
    {Clause, Rest1} = parse_comprehension_for(Rest),
    parse_comprehension_clause_tail(Rest1, [Clause]);
parse_comprehension_clauses([async_kw, for_kw | Rest]) ->
    {Clause, Rest1} = parse_comprehension_for(Rest),
    parse_comprehension_clause_tail(Rest1, [Clause]);
parse_comprehension_clauses(_Tokens) ->
    throw({expected, for_kw}).

parse_comprehension_clause_tail([if_kw | Rest], Clauses) ->
    {Condition, Rest1} = parse_lambda(Rest),
    parse_comprehension_clause_tail(Rest1, add_condition_to_last_clause(Clauses, Condition));
parse_comprehension_clause_tail([for_kw | Rest], Clauses) ->
    {Clause, Rest1} = parse_comprehension_for(Rest),
    parse_comprehension_clause_tail(Rest1, [Clause | Clauses]);
parse_comprehension_clause_tail([async_kw, for_kw | Rest], Clauses) ->
    {Clause, Rest1} = parse_comprehension_for(Rest),
    parse_comprehension_clause_tail(Rest1, [Clause | Clauses]);
parse_comprehension_clause_tail(Rest, Clauses) ->
    {lists:reverse(Clauses), Rest}.

add_condition_to_last_clause([{for, Target, Iterable, Conditions} | Rest], Condition) ->
    [{for, Target, Iterable, [Condition | Conditions]} | Rest].

parse_comprehension_for(Tokens) ->
    {TargetTokens, RestAfterTarget} = take_until_top_level_in(Tokens, [], 0),
    case RestAfterTarget of
        [in_kw | Rest1] ->
            case parse_assignment_target_tokens(TargetTokens) of
                {ok, Target} ->
                    {Iterable, Rest2} = parse_lambda(Rest1),
                    {{for, Target, Iterable, []}, Rest2};
                error ->
                    throw({bad_comprehension_target, TargetTokens})
            end;
        _ ->
            throw({expected, in_kw})
    end.

take_until_top_level_in([in_kw | _Rest] = Tokens, Acc, 0) ->
    {lists:reverse(Acc), Tokens};
take_until_top_level_in([Token | Rest], Acc, Depth) ->
    take_until_top_level_in(Rest, [Token | Acc], comprehension_target_depth(Token, Depth));
take_until_top_level_in([], _Acc, _Depth) ->
    throw({expected, in_kw}).

comprehension_target_depth(lparen, Depth) -> Depth + 1;
comprehension_target_depth(lbracket, Depth) -> Depth + 1;
comprehension_target_depth(lbrace, Depth) -> Depth + 1;
comprehension_target_depth(rparen, Depth) -> Depth - 1;
comprehension_target_depth(rbracket, Depth) -> Depth - 1;
comprehension_target_depth(rbrace, Depth) -> Depth - 1;
comprehension_target_depth(_Token, Depth) -> Depth.

parse_generator_arg(Expr, Clauses, [rparen | Rest], Acc) ->
    {lists:reverse([{arg, {gen_expr, Expr, Clauses}} | Acc]), Rest};
parse_generator_arg(_Expr, _Clauses, _Rest, _Acc) ->
    throw({expected, rparen}).

parse_tuple_literal([rparen | Rest], Acc) ->
    {{tuple, lists:reverse(Acc)}, Rest};
parse_tuple_literal([star | Rest], Acc) ->
    {Expr, Rest1} = parse_lambda(Rest),
    parse_tuple_literal_after_expr({starred, Expr}, Rest1, Acc);
parse_tuple_literal(Tokens, Acc) ->
    {Expr, Rest} = parse_lambda(Tokens),
    parse_tuple_literal_after_expr(Expr, Rest, Acc).

parse_tuple_literal_after_expr(Expr, Rest, Acc) ->
    case Rest of
        [comma, rparen | Rest2] -> {{tuple, lists:reverse([Expr | Acc])}, Rest2};
        [comma | Rest2] -> parse_tuple_literal(Rest2, [Expr | Acc]);
        [rparen | Rest2] -> {{tuple, lists:reverse([Expr | Acc])}, Rest2};
        _ -> throw({expected, comma_or_rparen})
    end.

parse_bare_tuple_literal([], Acc) ->
    {{tuple, lists:reverse(Acc)}, []};
parse_bare_tuple_literal(Tokens, Acc) ->
    {Expr, Rest} = parse_lambda(Tokens),
    case Rest of
        [comma | Rest2] -> parse_bare_tuple_literal(Rest2, [Expr | Acc]);
        _ -> {{tuple, lists:reverse([Expr | Acc])}, Rest}
    end.

parse_list_literal([rbracket | Rest], Acc) ->
    {{list, lists:reverse(Acc)}, Rest};
parse_list_literal([star | Rest], Acc) ->
    {Expr, Rest1} = parse_lambda(Rest),
    parse_list_literal_after_expr({starred, Expr}, Rest1, Acc);
parse_list_literal(Tokens, []) ->
    {Expr, Rest} = parse_lambda(Tokens),
    case Rest of
        [for_kw | _Rest1] = CompRest ->
            {Clauses, Rest2} = parse_comprehension_clauses(CompRest),
            parse_list_comprehension(Expr, Clauses, Rest2);
        [async_kw, for_kw | _Rest1] = CompRest ->
            {Clauses, Rest2} = parse_comprehension_clauses(CompRest),
            parse_list_comprehension(Expr, Clauses, Rest2);
        _ ->
            parse_list_literal_after_expr(Expr, Rest, [])
    end;
parse_list_literal(Tokens, Acc) ->
    {Expr, Rest} = parse_lambda(Tokens),
    parse_list_literal_after_expr(Expr, Rest, Acc).

parse_list_literal_after_expr(Expr, Rest, Acc) ->
    case Rest of
        [comma, rbracket | Rest2] -> {{list, lists:reverse([Expr | Acc])}, Rest2};
        [comma | Rest2] -> parse_list_literal(Rest2, [Expr | Acc]);
        [rbracket | Rest2] -> {{list, lists:reverse([Expr | Acc])}, Rest2};
        _ -> throw({expected, comma_or_rbracket})
    end.

parse_list_comprehension(Expr, Clauses, [rbracket | Rest]) ->
    {{list_comp, Expr, Clauses}, Rest};
parse_list_comprehension(_Expr, _Clauses, _Rest) ->
    throw({expected, rbracket}).

parse_brace_literal([rbrace | Rest]) ->
    {{dict, []}, Rest};
parse_brace_literal([starstar | Rest]) ->
    parse_dict_unpack_literal(Rest, []);
parse_brace_literal([star | Rest]) ->
    parse_set_unpack_literal(Rest, []);
parse_brace_literal(Tokens) ->
    {First, Rest} = parse_lambda(Tokens),
    case Rest of
        [colon | Rest1] -> parse_dict_literal_value(First, Rest1, []);
        _ -> parse_set_literal_after_expr(First, Rest, [])
    end.

parse_dict_literal([rbrace | Rest], Acc) ->
    {{dict, lists:reverse(Acc)}, Rest};
parse_dict_literal([starstar | Rest], Acc) ->
    parse_dict_unpack_literal(Rest, Acc);
parse_dict_literal(Tokens, Acc) ->
    {Key, Rest} = parse_lambda(Tokens),
    case Rest of
        [colon | Rest1] ->
            parse_dict_literal_value(Key, Rest1, Acc);
        _ ->
            throw({expected, colon})
    end.

parse_dict_literal_value(Key, Tokens, Acc) ->
    {Value, Rest} = parse_lambda(Tokens),
    case Rest of
        [for_kw | _Rest1] = CompRest when Acc =:= [] ->
            {Clauses, Rest2} = parse_comprehension_clauses(CompRest),
            parse_dict_comprehension(Key, Value, Clauses, Rest2);
        [async_kw, for_kw | _Rest1] = CompRest when Acc =:= [] ->
            {Clauses, Rest2} = parse_comprehension_clauses(CompRest),
            parse_dict_comprehension(Key, Value, Clauses, Rest2);
        [comma, rbrace | Rest2] -> {{dict, lists:reverse([{Key, Value} | Acc])}, Rest2};
        [comma | Rest2] -> parse_dict_literal(Rest2, [{Key, Value} | Acc]);
        [rbrace | Rest2] -> {{dict, lists:reverse([{Key, Value} | Acc])}, Rest2};
        _ -> throw({expected, comma_or_rbrace})
    end.

parse_dict_unpack_literal(Tokens, Acc) ->
    {Expr, Rest} = parse_lambda(Tokens),
    case Rest of
        [comma, rbrace | Rest2] -> {{dict, lists:reverse([{dict_unpack, Expr} | Acc])}, Rest2};
        [comma | Rest2] -> parse_dict_literal(Rest2, [{dict_unpack, Expr} | Acc]);
        [rbrace | Rest2] -> {{dict, lists:reverse([{dict_unpack, Expr} | Acc])}, Rest2};
        _ -> throw({expected, comma_or_rbrace})
    end.

parse_set_literal_after_expr(Expr, Rest, Acc) ->
    case Rest of
        [for_kw | _Rest1] = CompRest when Acc =:= [] ->
            {Clauses, Rest2} = parse_comprehension_clauses(CompRest),
            parse_set_comprehension(Expr, Clauses, Rest2);
        [async_kw, for_kw | _Rest1] = CompRest when Acc =:= [] ->
            {Clauses, Rest2} = parse_comprehension_clauses(CompRest),
            parse_set_comprehension(Expr, Clauses, Rest2);
        [comma, rbrace | Rest2] -> {{set, lists:reverse([Expr | Acc])}, Rest2};
        [comma | Rest2] -> parse_set_literal(Rest2, [Expr | Acc]);
        [rbrace | Rest2] -> {{set, lists:reverse([Expr | Acc])}, Rest2};
        _ -> throw({expected, comma_or_rbrace})
    end.

parse_set_unpack_literal(Tokens, Acc) ->
    {Expr, Rest} = parse_lambda(Tokens),
    parse_set_literal_after_expr({starred, Expr}, Rest, Acc).

parse_set_literal([star | Rest], Acc) ->
    parse_set_unpack_literal(Rest, Acc);
parse_set_literal(Tokens, Acc) ->
    {Expr, Rest} = parse_lambda(Tokens),
    parse_set_literal_after_expr(Expr, Rest, Acc).

parse_dict_comprehension(Key, Value, Clauses, [rbrace | Rest]) ->
    {{dict_comp, Key, Value, Clauses}, Rest};
parse_dict_comprehension(_Key, _Value, _Clauses, _Rest) ->
    throw({expected, rbrace}).

parse_set_comprehension(Expr, Clauses, [rbrace | Rest]) ->
    {{set_comp, Expr, Clauses}, Rest};
parse_set_comprehension(_Expr, _Clauses, _Rest) ->
    throw({expected, rbrace}).
