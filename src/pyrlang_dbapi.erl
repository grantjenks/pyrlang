-module(pyrlang_dbapi).

-export([
    apilevel/0,
    threadsafety/0,
    paramstyle/0,
    error/1,
    operational_error/1,
    programming_error/1
]).

-spec apilevel() -> binary().
apilevel() ->
    <<"2.0">>.

-spec threadsafety() -> 1.
threadsafety() ->
    1.

-spec paramstyle() -> qmark.
paramstyle() ->
    qmark.

-spec error(term()) -> no_return().
error(Reason) ->
    erlang:error({dbapi_error, Reason}).

-spec operational_error(term()) -> no_return().
operational_error(Reason) ->
    erlang:error({dbapi_operational_error, Reason}).

-spec programming_error(term()) -> no_return().
programming_error(Reason) ->
    erlang:error({dbapi_programming_error, Reason}).
