-module(pyrlang_supervisor_tests).

-include_lib("eunit/include/eunit.hrl").

one_for_one_permanent_child_restarts_test() ->
    pyrlang_heap:init(),
    Sup = pyrlang_supervisor:start([
        pyrlang_supervisor:child(worker, fun worker_loop/0, [])
    ]),
    [{worker, Pid1, permanent}] = pyrlang_supervisor:which_children(Sup),
    erlang:exit(Pid1, killed),
    timer:sleep(50),
    [{worker, Pid2, permanent}] = pyrlang_supervisor:which_children(Sup),
    ?assertNotEqual(Pid1, Pid2),
    ?assert(erlang:is_process_alive(Pid2)),
    ok = pyrlang_supervisor:stop(Sup).

temporary_child_is_not_restarted_test() ->
    pyrlang_heap:init(),
    Sup = pyrlang_supervisor:start([
        pyrlang_supervisor:child(temp, fun() -> ok end, [], temporary)
    ]),
    timer:sleep(50),
    ?assertEqual([], pyrlang_supervisor:which_children(Sup)),
    ok = pyrlang_supervisor:stop(Sup).

worker_loop() ->
    case pyrlang_actor:recv() of
        stop -> ok;
        _ -> worker_loop()
    end.
