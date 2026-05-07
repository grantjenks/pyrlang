-module(pyrlang_pattern).

-export([any/0, var/1, match/2, matches/2]).

-spec any() -> {py_any}.
any() ->
    {py_any}.

-spec var(atom() | binary() | string()) -> {py_var, atom() | binary() | string()}.
var(Name) ->
    {py_var, Name}.

-spec matches(term(), term()) -> boolean().
matches(Pattern, Value) ->
    case match(Pattern, Value) of
        {ok, _Bindings} -> true;
        nomatch -> false
    end.

-spec match(term(), term()) -> {ok, map()} | nomatch.
match(Pattern, Value) ->
    match(Pattern, Value, #{}).

match({py_any}, _Value, Bindings) ->
    {ok, Bindings};
match({py_var, Name}, Value, Bindings) ->
    case maps:find(Name, Bindings) of
        {ok, Value} -> {ok, Bindings};
        {ok, _Other} -> nomatch;
        error -> {ok, maps:put(Name, Value, Bindings)}
    end;
match(Pattern, Value, Bindings) when is_tuple(Pattern), is_tuple(Value), tuple_size(Pattern) =:= tuple_size(Value) ->
    match_tuple(Pattern, Value, 1, tuple_size(Pattern), Bindings);
match(Pattern, Value, Bindings) when is_list(Pattern), is_list(Value), length(Pattern) =:= length(Value) ->
    match_list(Pattern, Value, Bindings);
match(Pattern, Value, Bindings) when is_map(Pattern), is_map(Value) ->
    match_map(maps:to_list(Pattern), Value, Bindings);
match(Value, Value, Bindings) ->
    {ok, Bindings};
match(_Pattern, _Value, _Bindings) ->
    nomatch.

match_tuple(_Pattern, _Value, Pos, Size, Bindings) when Pos > Size ->
    {ok, Bindings};
match_tuple(Pattern, Value, Pos, Size, Bindings0) ->
    case match(element(Pos, Pattern), element(Pos, Value), Bindings0) of
        {ok, Bindings1} -> match_tuple(Pattern, Value, Pos + 1, Size, Bindings1);
        nomatch -> nomatch
    end.

match_list([], [], Bindings) ->
    {ok, Bindings};
match_list([Pattern | Patterns], [Value | Values], Bindings0) ->
    case match(Pattern, Value, Bindings0) of
        {ok, Bindings1} -> match_list(Patterns, Values, Bindings1);
        nomatch -> nomatch
    end.

match_map([], _Value, Bindings) ->
    {ok, Bindings};
match_map([{KeyPattern, ValuePattern} | Rest], ValueMap, Bindings0) ->
    case maps:find(KeyPattern, ValueMap) of
        {ok, Value} ->
            case match(ValuePattern, Value, Bindings0) of
                {ok, Bindings1} -> match_map(Rest, ValueMap, Bindings1);
                nomatch -> nomatch
            end;
        error ->
            nomatch
    end.
