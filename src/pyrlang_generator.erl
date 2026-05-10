-module(pyrlang_generator).

-export([from_values/1, next/1, values/1]).

-spec from_values([term()]) -> term().
from_values(Values) when is_list(Values) ->
    pyrlang_heap:allocate(generator, #{values => Values, index => 1}).

-spec next(term()) -> term().
next(Ref) ->
    generator = pyrlang_heap:type(Ref),
    Data = pyrlang_heap:data(Ref),
    Values = maps:get(values, Data),
    Index = maps:get(index, Data),
    case Index =< length(Values) of
        true ->
            Value = lists:nth(Index, Values),
            ok = pyrlang_heap:set_data(Ref, Data#{index := Index + 1}),
            Value;
        false ->
            pyrlang_exception:raise(
                pyrlang_exception:make(pyrlang_exception:type(<<"StopIteration">>))
            )
    end.

-spec values(term()) -> [term()].
values(Ref) ->
    generator = pyrlang_heap:type(Ref),
    collect(Ref, []).

collect(Ref, Acc) ->
    try next(Ref) of
        Value -> collect(Ref, [Value | Acc])
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"StopIteration">> -> lists:reverse(Acc);
                _ -> pyrlang_exception:raise(Exception)
            end
    end.
