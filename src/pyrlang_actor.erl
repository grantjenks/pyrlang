-module(pyrlang_actor).

-include("pyrlang.hrl").

-compile(
    {no_auto_import, [
        spawn/1,
        spawn/2,
        spawn_link/1,
        spawn_link/2,
        self/0,
        make_ref/0,
        register/2,
        whereis/1,
        link/1,
        monitor/1,
        exit/2
    ]}
).

-export([
    spawn/1,
    spawn/2,
    spawn_link/1,
    spawn_link/2,
    self/0,
    make_ref/0,
    send/2,
    recv/0,
    recv/1,
    recv/2,
    recv_match/1,
    recv_match/3,
    recv_match_bindings/3,
    call/2,
    call/3,
    call_monitored/2,
    call_monitored/3,
    reply/2,
    link/1,
    monitor/1,
    demonitor/1,
    trap_exit/1,
    exit/2,
    register/2,
    whereis/1
]).

-spec spawn(fun()) -> pid().
spawn(Fun) ->
    spawn(Fun, []).

-spec spawn(fun(), [term()]) -> pid().
spawn(Fun, Args) when is_function(Fun), is_list(Args) ->
    pyrlang_heap:ensure(),
    WireArgs = pyrlang_send:export(Args),
    erlang:spawn(fun() -> boot(Fun, WireArgs) end).

-spec spawn_link(fun()) -> pid().
spawn_link(Fun) ->
    spawn_link(Fun, []).

-spec spawn_link(fun(), [term()]) -> pid().
spawn_link(Fun, Args) when is_function(Fun), is_list(Args) ->
    pyrlang_heap:ensure(),
    WireArgs = pyrlang_send:export(Args),
    erlang:spawn_link(fun() -> boot(Fun, WireArgs) end).

boot(Fun, WireArgs) ->
    pyrlang_heap:init(),
    erlang:put(?PY_ACTOR_KEY, true),
    Args = pyrlang_send:import(WireArgs),
    apply(Fun, Args).

-spec self() -> pid().
self() ->
    erlang:self().

-spec make_ref() -> reference().
make_ref() ->
    erlang:make_ref().

-spec send(pid(), term()) -> ok.
send(Pid, Message) when is_pid(Pid) ->
    pyrlang_heap:ensure(),
    Wire = pyrlang_send:export(Message),
    Pid ! {?PY_MSG, erlang:self(), Wire},
    ok.

-spec recv() -> term().
recv() ->
    recv(infinity).

-spec recv(timeout()) -> term().
recv(Timeout) ->
    recv(Timeout, timeout).

-spec recv(timeout(), term()) -> term().
recv(Timeout, Default) ->
    receive
        {?PY_MSG, _From, Wire} ->
            pyrlang_send:import(Wire);
        {'DOWN', Ref, process, Pid, Reason} ->
            {'DOWN', Ref, Pid, Reason};
        {'EXIT', Pid, Reason} ->
            {'EXIT', Pid, Reason}
    after normalize_timeout(Timeout) ->
        Default
    end.

-spec recv_match(term()) -> term().
recv_match(Pattern) ->
    recv_match(Pattern, infinity, timeout).

-spec recv_match(term(), timeout(), term()) -> term().
recv_match(Pattern, Timeout, Default) ->
    case recv_match_bindings(Pattern, Timeout, Default) of
        {ok, Value, _Bindings} -> Value;
        Default -> Default
    end.

-spec recv_match_bindings(term(), timeout(), term()) -> {ok, term(), map()} | term().
recv_match_bindings(Pattern, Timeout, Default) ->
    Deadline = deadline(Timeout),
    scan_mailbox(Pattern, Deadline, Default, []).

-spec call(pid(), term()) -> term().
call(Pid, Request) ->
    call(Pid, Request, 5000).

-spec call(pid(), term(), timeout()) -> term().
call(Pid, Request, Timeout) ->
    Ref = make_ref(),
    ok = send(Pid, {erlang:self(), Ref, Request}),
    Pattern = {Ref, pyrlang_pattern:var(reply)},
    case recv_match(Pattern, Timeout, timeout) of
        {Ref, Reply} -> Reply;
        timeout -> erlang:error(timeout)
    end.

-spec call_monitored(pid(), term()) -> term().
call_monitored(Pid, Request) ->
    call_monitored(Pid, Request, 5000).

-spec call_monitored(pid(), term(), timeout()) -> term().
call_monitored(Pid, Request, Timeout) ->
    Ref = make_ref(),
    MonitorRef = erlang:monitor(process, Pid),
    ok = send(Pid, {erlang:self(), Ref, Request}),
    wait_monitored_reply(Ref, MonitorRef, Pid, deadline(Timeout), []).

-spec reply({pid(), reference()}, term()) -> ok.
reply({Pid, Ref}, Value) ->
    send(Pid, {Ref, Value}).

-spec link(pid()) -> true.
link(Pid) ->
    erlang:link(Pid).

-spec monitor(pid()) -> reference().
monitor(Pid) ->
    erlang:monitor(process, Pid).

-spec demonitor(reference()) -> boolean().
demonitor(Ref) ->
    erlang:demonitor(Ref, [flush]).

-spec trap_exit(boolean()) -> boolean().
trap_exit(Flag) when is_boolean(Flag) ->
    erlang:process_flag(trap_exit, Flag).

-spec exit(pid(), term()) -> true.
exit(Pid, Reason) ->
    erlang:exit(Pid, Reason).

-spec register(atom(), pid()) -> true.
register(Name, Pid) ->
    erlang:register(Name, Pid).

-spec whereis(atom()) -> pid() | undefined.
whereis(Name) ->
    erlang:whereis(Name).

wait_monitored_reply(Ref, MonitorRef, Pid, Deadline, Stashed) ->
    Timeout = remaining(Deadline),
    receive
        {?PY_MSG, _From, Wire} = Raw ->
            case is_reply_wire(Ref, Wire) of
                true ->
                    erlang:demonitor(MonitorRef, [flush]),
                    restore_stashed(Stashed),
                    {Ref, Reply} = pyrlang_send:import(Wire),
                    Reply;
                false ->
                    wait_monitored_reply(Ref, MonitorRef, Pid, Deadline, [Raw | Stashed])
            end;
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            restore_stashed(Stashed),
            erlang:error({actor_down, Pid, Reason});
        Other ->
            wait_monitored_reply(Ref, MonitorRef, Pid, Deadline, [Other | Stashed])
    after Timeout ->
        erlang:demonitor(MonitorRef, [flush]),
        restore_stashed(Stashed),
        erlang:error(timeout)
    end.

is_reply_wire(Ref, {?PY_WIRE, {tuple, [{reference, Ref}, _Reply]}, Objects}) when is_map(Objects) ->
    true;
is_reply_wire(_Ref, _Wire) ->
    false.

scan_mailbox(Pattern, Deadline, Default, Stashed) ->
    Timeout = remaining(Deadline),
    receive
        {?PY_MSG, _From, Wire} = Raw ->
            Value = pyrlang_send:import(Wire),
            case pyrlang_pattern:match(Pattern, Value) of
                {ok, Bindings} ->
                    restore_stashed(Stashed),
                    {ok, Value, Bindings};
                nomatch ->
                    scan_mailbox(Pattern, Deadline, Default, [Raw | Stashed])
            end;
        {'DOWN', Ref, process, Pid, Reason} = Raw ->
            Value = {'DOWN', Ref, Pid, Reason},
            case pyrlang_pattern:match(Pattern, Value) of
                {ok, Bindings} ->
                    restore_stashed(Stashed),
                    {ok, Value, Bindings};
                nomatch ->
                    scan_mailbox(Pattern, Deadline, Default, [Raw | Stashed])
            end;
        {'EXIT', Pid, Reason} = Raw ->
            Value = {'EXIT', Pid, Reason},
            case pyrlang_pattern:match(Pattern, Value) of
                {ok, Bindings} ->
                    restore_stashed(Stashed),
                    {ok, Value, Bindings};
                nomatch ->
                    scan_mailbox(Pattern, Deadline, Default, [Raw | Stashed])
            end
    after Timeout ->
        restore_stashed(Stashed),
        Default
    end.

restore_stashed(Stashed) ->
    lists:foreach(fun(Msg) -> erlang:self() ! Msg end, lists:reverse(Stashed)).

deadline(infinity) ->
    infinity;
deadline(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout.

remaining(infinity) ->
    infinity;
remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

normalize_timeout(infinity) ->
    infinity;
normalize_timeout(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Timeout.
