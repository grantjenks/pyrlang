-module(pyrlang_actor_tests).

-include_lib("eunit/include/eunit.hrl").

spawn_send_receive_test() ->
    pyrlang_heap:init(),
    Parent = pyrlang_actor:self(),
    Pid = pyrlang_actor:spawn(fun() ->
        Msg = pyrlang_actor:recv(),
        pyrlang_actor:send(Parent, {got, Msg})
    end),
    ok = pyrlang_actor:send(Pid, <<"hello">>),
    ?assertEqual({got, <<"hello">>}, pyrlang_actor:recv(1000)).

actor_message_copy_isolates_mutable_heap_objects_test() ->
    pyrlang_heap:init(),
    Parent = pyrlang_actor:self(),
    List = pyrlang_heap:list([1]),
    Pid = pyrlang_actor:spawn(fun() ->
        ChildList = pyrlang_actor:recv(),
        pyrlang_heap:list_append(ChildList, 2),
        pyrlang_actor:send(Parent, pyrlang_heap:list_items(ChildList))
    end),
    ok = pyrlang_actor:send(Pid, List),
    pyrlang_heap:list_append(List, parent),
    ?assertEqual([1, 2], pyrlang_actor:recv(1000)),
    ?assertEqual([1, parent], pyrlang_heap:list_items(List)).

call_reply_test() ->
    pyrlang_heap:init(),
    Server = pyrlang_actor:spawn(fun server/0),
    ?assertEqual(5, pyrlang_actor:call(Server, {add, 2, 3}, 1000)).

monitor_down_test() ->
    pyrlang_heap:init(),
    Pid = pyrlang_actor:spawn(fun() -> ok end),
    Ref = pyrlang_actor:monitor(Pid),
    Msg = pyrlang_actor:recv_match(
        {'DOWN', Ref, pyrlang_pattern:any(), pyrlang_pattern:any()}, 1000, timeout
    ),
    ?assertMatch({'DOWN', Ref, Pid, _Reason}, Msg).

link_trap_exit_test() ->
    pyrlang_heap:init(),
    pyrlang_actor:trap_exit(true),
    Pid = pyrlang_actor:spawn_link(fun() -> timer:sleep(infinity) end),
    pyrlang_actor:exit(Pid, killed),
    ?assertEqual(
        {'EXIT', Pid, killed}, pyrlang_actor:recv_match({'EXIT', Pid, killed}, 1000, timeout)
    ),
    pyrlang_actor:trap_exit(false).

server() ->
    case pyrlang_actor:recv() of
        {From, Ref, {add, A, B}} ->
            pyrlang_actor:reply({From, Ref}, A + B);
        Other ->
            error({unexpected_request, Other})
    end.
