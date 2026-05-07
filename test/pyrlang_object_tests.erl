-module(pyrlang_object_tests).

-include_lib("eunit/include/eunit.hrl").

class_instance_attr_lookup_test() ->
    pyrlang_heap:init(),
    Class = pyrlang_object:new_class(<<"Box">>, #{<<"kind">> => <<"box">>}),
    Instance = pyrlang_object:instantiate(Class),
    ?assertEqual(<<"box">>, pyrlang_object:get_attr(Instance, <<"kind">>)),
    ok = pyrlang_object:set_attr(Instance, <<"kind">>, <<"crate">>),
    ?assertEqual(<<"crate">>, pyrlang_object:get_attr(Instance, <<"kind">>)).

bound_method_receives_self_test() ->
    pyrlang_heap:init(),
    Method = fun(Self, Amount) ->
        Current = pyrlang_object:get_attr(Self, <<"value">>),
        pyrlang_object:set_attr(Self, <<"value">>, Current + Amount),
        pyrlang_object:get_attr(Self, <<"value">>)
    end,
    Class = pyrlang_object:new_class(<<"Counter">>, #{<<"inc">> => Method}),
    Instance = pyrlang_object:instantiate(Class),
    ok = pyrlang_object:set_attr(Instance, <<"value">>, 10),
    Bound = pyrlang_object:get_attr(Instance, <<"inc">>),
    ?assertEqual(15, pyrlang_object:call(Bound, [5])).

data_descriptor_takes_precedence_over_instance_attr_test() ->
    pyrlang_heap:init(),
    Descriptor = pyrlang_object:descriptor(
        fun(Instance, _Class) ->
            pyrlang_heap:dict_get(pyrlang_object:get_attr(Instance, <<"storage">>), <<"value">>)
        end,
        fun(Instance, Value) ->
            pyrlang_heap:dict_put(pyrlang_object:get_attr(Instance, <<"storage">>), <<"value">>, Value)
        end
    ),
    Class = pyrlang_object:new_class(<<"WithDescriptor">>, #{<<"value">> => Descriptor}),
    Instance = pyrlang_object:instantiate(Class),
    Store = pyrlang_heap:dict([{<<"value">>, 1}]),
    ok = pyrlang_object:set_attr(Instance, <<"storage">>, Store),
    ok = pyrlang_object:set_attr(Instance, <<"value">>, 42),
    ?assertEqual(42, pyrlang_object:get_attr(Instance, <<"value">>)).

c3_mro_diamond_test() ->
    pyrlang_heap:init(),
    A = pyrlang_object:new_class(<<"A">>, #{<<"name">> => <<"A">>}),
    B = pyrlang_object:new_class(<<"B">>, [A], #{}),
    C = pyrlang_object:new_class(<<"C">>, [A], #{<<"name">> => <<"C">>}),
    D = pyrlang_object:new_class(<<"D">>, [B, C], #{}),
    Names = [pyrlang_object:class_name(Class) || Class <- pyrlang_object:mro(D)],
    ?assertEqual([<<"D">>, <<"B">>, <<"C">>, <<"A">>], Names),
    Instance = pyrlang_object:instantiate(D),
    ?assertEqual(<<"C">>, pyrlang_object:get_attr(Instance, <<"name">>)).
