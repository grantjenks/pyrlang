-module(pyrlang_heap_tests).

-include_lib("eunit/include/eunit.hrl").

list_mutation_is_actor_local_test() ->
    pyrlang_heap:init(),
    ParentList = pyrlang_heap:list([1, 2]),
    pyrlang_heap:list_append(ParentList, 3),
    ?assertEqual([1, 2, 3], pyrlang_heap:list_items(ParentList)).

send_copy_imports_mutable_objects_test() ->
    pyrlang_heap:init(),
    ParentList = pyrlang_heap:list([1, 2]),
    Wire = pyrlang_send:export(ParentList),
    pyrlang_heap:init(),
    ChildList = pyrlang_send:import(Wire),
    pyrlang_heap:list_append(ChildList, 99),
    ?assertEqual([1, 2, 99], pyrlang_heap:list_items(ChildList)).

send_copy_preserves_cycles_test() ->
    pyrlang_heap:init(),
    List = pyrlang_heap:list([]),
    pyrlang_heap:list_append(List, List),
    Wire = pyrlang_send:export(List),
    pyrlang_heap:init(),
    Copy = pyrlang_send:import(Wire),
    [Inner] = pyrlang_heap:list_items(Copy),
    ?assertEqual(Copy, Inner).

send_rejects_live_generators_as_actor_local_resources_test() ->
    pyrlang_heap:init(),
    Generator = pyrlang_generator:from_values([1]),
    ?assertError({unsendable, generator}, pyrlang_send:export(Generator)).
