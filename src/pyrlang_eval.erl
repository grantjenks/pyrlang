-module(pyrlang_eval).

-export([
    eval_expr/1, eval_expr/2,
    eval_module/1, eval_module/2,
    bind_module_globals/1,
    function_globals/1,
    call/2,
    builtin_attribute/2,
    eval_compare/3,
    current_exception_info/0,
    trace_function_stack/0,
    contextmanager_start/2,
    contextmanager_resume/2
]).

-type env() :: map().

-define(CURRENT_EXCEPTION_KEY, '$py_current_exception').
-define(MODULE_EVAL_KEY, '$py_module_eval').
-define(FUNCTION_GLOBAL_ENV_KEY, '$py_function_global_env').
-define(FUNCTION_ID_KEY, '$py_function_id').
-define(FUNCTION_LEXICAL_NAME_KEY, '$py_function_lexical_name').
-define(FUNCTION_ENV_STACK_KEY, '$py_function_env_stack').
-define(FUNCTION_CALL_STACK_KEY, '$py_function_call_stack').
-define(COMP_EVAL_KEY, '$py_comp_eval').
-define(MODULE_CLOSURE_MARKER, '$py_module_closure').
-define(LOCAL_CLOSURE_NAMES, '$py_local_closure_names').
-define(GLOBAL_DECL_NAMES, '$py_global_decl_names').
-define(CLASS_ATTR_ORDER_KEY, <<"__pyrlang_class_attr_order__">>).

-spec eval_expr(term()) -> term().
eval_expr(Ast) ->
    {Value, _Env} = eval_expr(Ast, #{}),
    Value.

-spec eval_expr(term(), env()) -> {term(), env()}.
eval_expr({int, Value}, Env) ->
    {Value, Env};
eval_expr({float, Value}, Env) ->
    {Value, Env};
eval_expr({complex, Real, Imag}, Env) ->
    {{py_complex, Real, Imag}, Env};
eval_expr({str, Value}, Env) ->
    {Value, Env};
eval_expr({joined_str, Parts}, Env0) ->
    eval_joined_str(Parts, Env0, []);
eval_expr({bytes, Value}, Env) ->
    {Value, Env};
eval_expr({bool, Value}, Env) ->
    {Value, Env};
eval_expr({none}, Env) ->
    {none, Env};
eval_expr({ellipsis}, Env) ->
    {ellipsis, Env};
eval_expr({var, Name}, Env) ->
    {lookup_var(Name, Env), Env};
eval_expr({unary, neg, Expr}, Env0) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    {negate_value(Value), Env1};
eval_expr({unary, not_op, Expr}, Env0) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    {not truthy(Value), Env1};
eval_expr({unary, invert, Expr}, Env0) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    {bnot Value, Env1};
eval_expr({await, Expr}, Env0) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    {await_value(Value), Env1};
eval_expr({boolop, and_op, Left, Right}, Env0) ->
    {LeftValue, Env1} = eval_expr(Left, Env0),
    case truthy(LeftValue) of
        true -> eval_expr(Right, Env1);
        false -> {LeftValue, Env1}
    end;
eval_expr({boolop, or_op, Left, Right}, Env0) ->
    {LeftValue, Env1} = eval_expr(Left, Env0),
    case truthy(LeftValue) of
        true -> {LeftValue, Env1};
        false -> eval_expr(Right, Env1)
    end;
eval_expr({if_expr, Condition, ThenExpr, ElseExpr}, Env0) ->
    {ConditionValue, Env1} = eval_expr(Condition, Env0),
    case truthy(ConditionValue) of
        true -> eval_expr(ThenExpr, Env1);
        false -> eval_expr(ElseExpr, Env1)
    end;
eval_expr({named_expr, Name, Expr}, Env0) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    {Value, Env1#{Name => Value}};
eval_expr({lambda, Params, {yield_expr, Expr}}, Env0) ->
    {PreparedParams, Env1} = prepare_params_with_env(Params, Env0),
    {
        {py_function, PreparedParams, [{yield, Expr}],
            function_closure_env(capture_lambda_closure_env(Env1)), true},
        Env1
    };
eval_expr({lambda, Params, Expr}, Env0) ->
    {PreparedParams, Env1} = prepare_params_with_env(Params, Env0),
    {
        {py_function, PreparedParams, [{return, Expr}],
            function_closure_env(capture_lambda_closure_env(Env1)), false},
        Env1
    };
eval_expr({yield_expr, _Expr}, _Env) ->
    erlang:error(yield_outside_generator_collection);
eval_expr({binop, Op, Left, Right}, Env0) ->
    {LeftValue, Env1} = eval_expr(Left, Env0),
    {RightValue, Env2} = eval_expr(Right, Env1),
    {eval_binop_or_raise(Op, LeftValue, RightValue), Env2};
eval_expr({compare, Op, Left, Right}, Env0) ->
    {LeftValue, Env1} = eval_expr(Left, Env0),
    {RightValue, Env2} = eval_expr(Right, Env1),
    {eval_compare(Op, LeftValue, RightValue), Env2};
eval_expr({compare_chain, Left, Chain}, Env0) ->
    {LeftValue, Env1} = eval_expr(Left, Env0),
    eval_compare_chain(LeftValue, Chain, Env1);
eval_expr({list, Items}, Env0) ->
    {Values, Env1} = eval_list_items(Items, Env0, []),
    {pyrlang_heap:list(Values), Env1};
eval_expr({list_comp, Expr, Clauses}, Env0) ->
    {Values, Env1} = eval_comp_collect(Clauses, Env0, fun(Env) -> eval_expr(Expr, Env) end),
    {
        pyrlang_heap:list(Values),
        restore_comp_targets(Env0, Env1, comp_clause_target_names(Clauses))
    };
eval_expr({list_comp, Expr, Target, IterableExpr, Condition}, Env0) ->
    {Iterable, Env1} = eval_expr(IterableExpr, Env0),
    {Values, Env2} = eval_list_comp(Expr, Target, iter_values(Iterable), Condition, Env1, []),
    {pyrlang_heap:list(Values), restore_comp_targets(Env1, Env2, target_bound_names(Target))};
eval_expr({tuple, Items}, Env0) ->
    {Values, Env1} = eval_list_items(Items, Env0, []),
    {list_to_tuple(Values), Env1};
eval_expr({dict, Pairs}, Env0) ->
    {Values, Env1} = eval_pairs(Pairs, Env0, []),
    {pyrlang_heap:dict(Values), Env1};
eval_expr({dict_comp, KeyExpr, ValueExpr, Clauses}, Env0) ->
    {Pairs, Env1} = eval_comp_collect(
        Clauses,
        Env0,
        fun(EnvA) ->
            {Key, Env2} = eval_expr(KeyExpr, EnvA),
            {Value, Env3} = eval_expr(ValueExpr, Env2),
            {{Key, Value}, Env3}
        end
    ),
    {pyrlang_heap:dict(Pairs), restore_comp_targets(Env0, Env1, comp_clause_target_names(Clauses))};
eval_expr({dict_comp, KeyExpr, ValueExpr, Target, IterableExpr, Condition}, Env0) ->
    {Iterable, Env1} = eval_expr(IterableExpr, Env0),
    {Pairs, Env2} = eval_dict_comp(
        KeyExpr, ValueExpr, Target, iter_values(Iterable), Condition, Env1, []
    ),
    {pyrlang_heap:dict(Pairs), restore_comp_targets(Env1, Env2, target_bound_names(Target))};
eval_expr({set, Items}, Env0) ->
    {Values, Env1} = eval_list_items(Items, Env0, []),
    {pyrlang_heap:set(Values), Env1};
eval_expr({set_comp, Expr, Clauses}, Env0) ->
    {Values, Env1} = eval_comp_collect(Clauses, Env0, fun(Env) -> eval_expr(Expr, Env) end),
    {pyrlang_heap:set(Values), restore_comp_targets(Env0, Env1, comp_clause_target_names(Clauses))};
eval_expr({set_comp, Expr, Target, IterableExpr, Condition}, Env0) ->
    {Iterable, Env1} = eval_expr(IterableExpr, Env0),
    {Values, Env2} = eval_set_comp(Expr, Target, iter_values(Iterable), Condition, Env1, []),
    {pyrlang_heap:set(Values), restore_comp_targets(Env1, Env2, target_bound_names(Target))};
eval_expr({gen_expr, Expr, Clauses}, Env0) ->
    trace_eval_flow(gen_expr_start, Clauses),
    {Values, Env1} = eval_comp_collect(Clauses, Env0, fun(Env) -> eval_expr(Expr, Env) end),
    trace_eval_flow({gen_expr_values, length(Values)}, Values),
    {
        pyrlang_generator:from_values(Values),
        restore_comp_targets(Env0, Env1, comp_clause_target_names(Clauses))
    };
eval_expr({gen_expr, Expr, Target, IterableExpr, Condition}, Env0) ->
    trace_eval_flow(gen_expr_start, Target),
    {Iterable, Env1} = eval_expr(IterableExpr, Env0),
    {Values, Env2} = eval_list_comp(Expr, Target, iter_values(Iterable), Condition, Env1, []),
    trace_eval_flow({gen_expr_values, length(Values)}, Values),
    {
        pyrlang_generator:from_values(Values),
        restore_comp_targets(Env1, Env2, target_bound_names(Target))
    };
eval_expr({call, {var, <<"globals">>}, []}, Env) ->
    {globals_mapping(Env), Env};
eval_expr({call, {var, <<"locals">>}, []}, Env) ->
    {pyrlang_heap:dict(Env), Env};
eval_expr({call, {var, <<"vars">>}, []}, Env) ->
    {pyrlang_heap:dict(Env), Env};
eval_expr({call, {var, <<"dir">>}, []}, Env) ->
    {pyrlang_heap:list(lists:sort(maps:keys(Env))), Env};
eval_expr({call, CalleeExpr, ArgExprs}, Env0) ->
    {Callee, Env1} = eval_expr(CalleeExpr, Env0),
    {PosArgs, KwArgs, Env2} = eval_call_args(ArgExprs, Env1, [], #{}),
    {call_value(Callee, {call_args, PosArgs, KwArgs}), Env2};
eval_expr({attr, ObjectExpr, Name}, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {get_attribute(Object, Name), Env1};
eval_expr({subscript, ObjectExpr, {slice, StartExpr, StopExpr}}, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Start, Env2} = eval_optional_slice(StartExpr, Env1),
    {Stop, Env3} = eval_optional_slice(StopExpr, Env2),
    {get_slice(Object, Start, Stop), Env3};
eval_expr({subscript, ObjectExpr, {slice, StartExpr, StopExpr, StepExpr}}, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Start, Env2} = eval_optional_slice(StartExpr, Env1),
    {Stop, Env3} = eval_optional_slice(StopExpr, Env2),
    {Step, Env4} = eval_optional_slice(StepExpr, Env3),
    {get_slice(Object, Start, Stop, Step), Env4};
eval_expr({subscript, ObjectExpr, IndexExpr}, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Index, Env2} = eval_expr(IndexExpr, Env1),
    {get_subscript_or_raise(Object, Index), Env2}.

await_value({py_coroutine, Body, LocalEnv, OwnerClass, PosArgs}) ->
    with_method_context(OwnerClass, PosArgs, fun() ->
        try eval_statements(Body, LocalEnv, none) of
            {Value, _Env} -> Value
        catch
            throw:{py_return, Value} -> Value
        end
    end);
await_value(Value) ->
    Value.

-spec eval_module(term()) -> {term(), env()}.
eval_module(Module) ->
    eval_module(Module, #{}).

-spec eval_module(term(), env()) -> {term(), env()}.
eval_module({module, Statements}, Env) ->
    pyrlang_heap:ensure(),
    Previous = erlang:get(?MODULE_EVAL_KEY),
    erlang:put(?MODULE_EVAL_KEY, true),
    try
        {Last, FinalEnv} = eval_statements(Statements, Env, none),
        {Last, bind_module_globals(FinalEnv)}
    after
        restore_module_eval(Previous)
    end.

restore_module_eval(undefined) ->
    erlang:erase(?MODULE_EVAL_KEY);
restore_module_eval(Value) ->
    erlang:put(?MODULE_EVAL_KEY, Value).

capture_closure_env(Env) ->
    case erlang:get(?MODULE_EVAL_KEY) of
        true ->
            shallow_capture_env(Env);
        _ ->
            case erlang:get(?FUNCTION_GLOBAL_ENV_KEY) of
                undefined -> Env;
                GlobalEnv -> capture_local_closure_env(Env, GlobalEnv)
            end
    end.

capture_lambda_closure_env(Env) ->
    case erlang:get(?MODULE_EVAL_KEY) of
        true ->
            case maps:is_key(<<"__name__">>, Env) of
                true -> module_identity_env(Env);
                false -> capture_closure_env(Env)
            end;
        _ ->
            capture_closure_env(Env)
    end.

function_closure_env(Env) ->
    Env#{?FUNCTION_ID_KEY => make_ref()}.

shallow_capture_env(Env) ->
    (maps:map(fun(_Name, Value) -> shallow_global_value(Value, Env) end, Env))#{
        ?MODULE_CLOSURE_MARKER => true
    }.

bind_module_globals(Env) ->
    Snapshot = maps:map(fun(_Name, Value) -> shallow_global_value(Value, Env) end, Env),
    maps:map(fun(_Name, Value) -> bind_function_globals(Value, Snapshot, Snapshot) end, Snapshot).

bind_function_globals(Value, Env) ->
    bind_function_globals(Value, Env, Env).

bind_function_globals({py_function, Params, Body, ClosureEnv} = Function, Env, GlobalEnv) ->
    case preserve_function_module(ClosureEnv, Env) of
        true -> Function;
        false -> {py_function, Params, Body, rebound_function_env(ClosureEnv, Env, GlobalEnv)}
    end;
bind_function_globals(
    {py_function, Params, Body, ClosureEnv, IsGenerator} = Function, Env, GlobalEnv
) ->
    case preserve_function_module(ClosureEnv, Env) of
        true ->
            Function;
        false ->
            {py_function, Params, Body, rebound_function_env(ClosureEnv, Env, GlobalEnv),
                IsGenerator}
    end;
bind_function_globals(
    {py_function, Params, Body, ClosureEnv, IsGenerator, OwnerClass} = Function, Env, GlobalEnv
) ->
    case preserve_function_module(ClosureEnv, Env) of
        true ->
            Function;
        false ->
            {py_function, Params, Body, rebound_function_env(ClosureEnv, Env, GlobalEnv),
                IsGenerator, OwnerClass}
    end;
bind_function_globals(Value, _Env, _GlobalEnv) ->
    Value.

rebound_function_env(ClosureEnv, Env, GlobalEnv) ->
    preserve_function_identity(
        ClosureEnv, maps:merge(prune_closure_env(ClosureEnv, GlobalEnv), Env)
    ).

preserve_function_module(ClosureEnv, Env) ->
    case
        {maps:get(<<"__name__">>, ClosureEnv, undefined), maps:get(<<"__name__">>, Env, undefined)}
    of
        {FunctionModule, LookupModule} when is_binary(FunctionModule), is_binary(LookupModule) ->
            FunctionModule =/= LookupModule;
        _ ->
            false
    end.

shallow_global_value({py_function, Params, Body, ClosureEnv}, GlobalEnv) ->
    {py_function, shallow_params(Params, GlobalEnv), Body,
        shallow_function_closure_env(ClosureEnv, GlobalEnv)};
shallow_global_value({py_function, Params, Body, ClosureEnv, IsGenerator}, GlobalEnv) ->
    {py_function, shallow_params(Params, GlobalEnv), Body,
        shallow_function_closure_env(ClosureEnv, GlobalEnv), IsGenerator};
shallow_global_value({py_function, Params, Body, ClosureEnv, IsGenerator, OwnerClass}, GlobalEnv) ->
    {py_function, shallow_params(Params, GlobalEnv), Body,
        shallow_function_closure_env(ClosureEnv, GlobalEnv), IsGenerator, OwnerClass};
shallow_global_value(Value, _GlobalEnv) ->
    Value.

module_identity_env(Env) ->
    lists:foldl(
        fun(Name, Acc) ->
            case maps:find(Name, Env) of
                {ok, Value} -> Acc#{Name => Value};
                error -> Acc
            end
        end,
        #{},
        [
            <<"__name__">>,
            <<"__package__">>,
            <<"__path__">>,
            <<"__file__">>,
            <<"__spec__">>
        ]
    ).

shallow_function_closure_env(ClosureEnv, GlobalEnv) ->
    Captured =
        case maps:get(?MODULE_CLOSURE_MARKER, ClosureEnv, false) of
            true ->
                module_identity_env(ClosureEnv);
            false ->
                capture_local_closure_env(ClosureEnv, GlobalEnv)
        end,
    preserve_function_identity(ClosureEnv, Captured).

preserve_function_identity(SourceEnv, TargetEnv) ->
    TargetEnv1 =
        case maps:find(?FUNCTION_ID_KEY, SourceEnv) of
            {ok, Id} -> TargetEnv#{?FUNCTION_ID_KEY => Id};
            error -> maps:remove(?FUNCTION_ID_KEY, TargetEnv)
        end,
    case maps:find(?FUNCTION_LEXICAL_NAME_KEY, SourceEnv) of
        {ok, Name} -> TargetEnv1#{?FUNCTION_LEXICAL_NAME_KEY => Name};
        error -> maps:remove(?FUNCTION_LEXICAL_NAME_KEY, TargetEnv1)
    end.

capture_local_closure_env(Env, GlobalEnv) ->
    LocalNames = maps:get(?LOCAL_CLOSURE_NAMES, Env, []),
    Captured = maps:fold(
        fun(Name, Value, Acc) ->
            Skip = Name =:= ?MODULE_CLOSURE_MARKER orelse Name =:= ?LOCAL_CLOSURE_NAMES,
            case Skip of
                true ->
                    Acc;
                false ->
                    case
                        lists:member(Name, LocalNames) orelse
                            not same_global_binding(Name, Value, GlobalEnv)
                    of
                        true -> Acc#{Name => Value};
                        false -> Acc
                    end
            end
        end,
        module_identity_env(Env),
        Env
    ),
    case LocalNames of
        [] -> Captured;
        _ -> Captured#{?LOCAL_CLOSURE_NAMES => LocalNames}
    end.

same_global_binding(Name, Value, GlobalEnv) ->
    case maps:find(Name, GlobalEnv) of
        {ok, GlobalValue} -> pyrlang_heap:value_key(Value) =:= pyrlang_heap:value_key(GlobalValue);
        _ -> false
    end.

shallow_params(Params, GlobalEnv) ->
    [shallow_param(Param, GlobalEnv) || Param <- Params].

shallow_param({param, Name, {default, Value}, Annotation}, GlobalEnv) ->
    {param, Name, {default, shallow_global_value(Value, GlobalEnv)},
        shallow_global_value(Annotation, GlobalEnv)};
shallow_param({param, Name, Default, Annotation}, GlobalEnv) ->
    {param, Name, Default, shallow_global_value(Annotation, GlobalEnv)};
shallow_param(Param, _GlobalEnv) ->
    Param.

prune_closure_env(Env, GlobalEnv) ->
    maps:filter(
        fun(Name, Value) ->
            Name =/= ?MODULE_CLOSURE_MARKER andalso
                not (is_py_function(Value) andalso maps:is_key(Name, GlobalEnv))
        end,
        Env
    ).

is_py_function({py_function, _Params, _Body, _Env}) -> true;
is_py_function({py_function, _Params, _Body, _Env, _IsGenerator}) -> true;
is_py_function({py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass}) -> true;
is_py_function(_Value) -> false.

-spec call(term(), [term()]) -> term().
call(Callable, Args) ->
    call_value(Callable, Args).

eval_statements(Statements, Env, Last) ->
    sync_function_stack_env(Env),
    eval_statements_inner(Statements, Env, Last).

sync_function_stack_env(Env) ->
    case erlang:get(?FUNCTION_ENV_STACK_KEY) of
        [Current | Rest] when is_map(Current) ->
            erlang:put(?FUNCTION_ENV_STACK_KEY, [Env | Rest]);
        _ ->
            ok
    end.

eval_statements_inner([], Env, Last) ->
    {Last, Env};
eval_statements_inner([{def, Name, Params, Body} | Rest], Env0, _Last) ->
    {Function, DefaultsEnv} = make_function_with_env(
        Name, Params, Body, Env0, contains_yield(Body)
    ),
    Env1 = DefaultsEnv#{Name => Function},
    sync_current_loading_module_env(Env1),
    eval_statements(Rest, Env1, Function);
eval_statements_inner([{def, Name, Params, Body, Decorators} | Rest], Env0, _Last) ->
    {Function, DefaultsEnv} = make_function_with_env(
        Name, Params, Body, Env0, contains_yield(Body)
    ),
    {Decorated, Env1} = apply_decorators(Decorators, Function, DefaultsEnv),
    Env2 = Env1#{Name => Decorated},
    sync_current_loading_module_env(Env2),
    eval_statements(Rest, Env2, Decorated);
eval_statements_inner([{async_def, Name, Params, Body} | Rest], Env0, _Last) ->
    {Function, DefaultsEnv} = make_function_with_env(Name, Params, Body, Env0, async_mode(Body)),
    Env1 = DefaultsEnv#{Name => Function},
    sync_current_loading_module_env(Env1),
    eval_statements(Rest, Env1, Function);
eval_statements_inner([{async_def, Name, Params, Body, Decorators} | Rest], Env0, _Last) ->
    {Function, DefaultsEnv} = make_function_with_env(Name, Params, Body, Env0, async_mode(Body)),
    {Decorated, Env1} = apply_decorators(Decorators, Function, DefaultsEnv),
    Env2 = Env1#{Name => Decorated},
    sync_current_loading_module_env(Env2),
    eval_statements(Rest, Env2, Decorated);
eval_statements_inner([{class, Name, BaseExprs, MetaclassExpr, Body} | Rest], Env0, _Last) ->
    {Class, Env1} = create_class(Name, BaseExprs, MetaclassExpr, [], Body, Env0),
    Env2 = Env1#{Name => Class},
    sync_current_loading_module_env(Env2),
    eval_statements(Rest, Env2, Class);
eval_statements_inner(
    [{class, Name, BaseExprs, MetaclassExpr, Body, Decorators} | Rest], Env0, _Last
) ->
    {Class, Env1} = create_class(Name, BaseExprs, MetaclassExpr, [], Body, Env0),
    {Decorated, Env2} = apply_decorators(Decorators, Class, Env1),
    Env3 = Env2#{Name => Decorated},
    sync_current_loading_module_env(Env3),
    eval_statements(Rest, Env3, Decorated);
eval_statements_inner(
    [{class, Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, []} | Rest], Env0, _Last
) ->
    {Class, Env1} = create_class(Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, Env0),
    Env2 = Env1#{Name => Class},
    sync_current_loading_module_env(Env2),
    eval_statements(Rest, Env2, Class);
eval_statements_inner(
    [{class, Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, Decorators} | Rest], Env0, _Last
) ->
    {Class, Env1} = create_class(Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, Env0),
    {Decorated, Env2} = apply_decorators(Decorators, Class, Env1),
    Env3 = Env2#{Name => Decorated},
    sync_current_loading_module_env(Env3),
    eval_statements(Rest, Env3, Decorated);
eval_statements_inner([{if_stmt, Condition, ThenBody, ElseBody} | Rest], Env0, _Last) ->
    {ConditionValue, Env1} = eval_expr(Condition, Env0),
    {BranchLast, Env2} =
        case truthy(ConditionValue) of
            true -> eval_statements(ThenBody, Env1, none);
            false -> eval_statements(ElseBody, Env1, none)
        end,
    eval_statements(Rest, Env2, BranchLast);
eval_statements_inner([{while_stmt, Condition, Body} | Rest], Env0, _Last) ->
    eval_statements([{while_stmt, Condition, Body, []} | Rest], Env0, none);
eval_statements_inner([{while_stmt, Condition, Body, ElseBody} | Rest], Env0, _Last) ->
    {LoopLast, Env1, Completed} = eval_while(Condition, Body, Env0, none),
    {Last, Env2} = eval_loop_else(Completed, ElseBody, Env1, LoopLast),
    eval_statements(Rest, Env2, Last);
eval_statements_inner([{for_stmt, Name, IterableExpr, Body} | Rest], Env0, _Last) ->
    eval_statements([{for_stmt, Name, IterableExpr, Body, []} | Rest], Env0, none);
eval_statements_inner([{for_stmt, Name, IterableExpr, Body, ElseBody} | Rest], Env0, _Last) ->
    {Iterable, Env1} = eval_expr(IterableExpr, Env0),
    {LoopLast, Env2, Completed} = eval_for(Name, pyrlang_iter:iter(Iterable), Body, Env1, none),
    {Last, Env3} = eval_loop_else(Completed, ElseBody, Env2, LoopLast),
    eval_statements(Rest, Env3, Last);
eval_statements_inner([{with_stmt, ManagerExpr, Binding, Body} | Rest], Env0, _Last) ->
    {WithLast, Env1} = eval_with(ManagerExpr, Binding, Body, Env0),
    eval_statements(Rest, Env1, WithLast);
eval_statements_inner([{try_stmt, Body, Handlers, ElseBody, FinallyBody} | Rest], Env0, _Last) ->
    {TryLast, Env1} = eval_try(Body, Handlers, ElseBody, FinallyBody, Env0),
    eval_statements(Rest, Env1, TryLast);
eval_statements_inner([{match_stmt, SubjectExpr, Cases} | Rest], Env0, _Last) ->
    {Subject, Env1} = eval_expr(SubjectExpr, Env0),
    {MatchLast, Env2} = eval_match_cases(Subject, Cases, Env1),
    eval_statements(Rest, Env2, MatchLast);
eval_statements_inner([{import, Specs} | Rest], Env0, _Last) ->
    sync_current_loading_module_env(Env0),
    {Last, Env1} = eval_imports(Specs, Env0, none),
    sync_current_loading_module_env(Env1),
    eval_statements(Rest, Env1, Last);
eval_statements_inner([{from_import, ModuleName, Specs} | Rest], Env0, _Last) ->
    sync_current_loading_module_env(Env0),
    {Last, Env1} = eval_from_import(ModuleName, Specs, Env0),
    sync_current_loading_module_env(Env1),
    eval_statements(Rest, Env1, Last);
eval_statements_inner([{assign, Name, Expr} | Rest], Env0, _Last) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_statements(Rest, bind_name(Name, Value, Env1), Value);
eval_statements_inner([{assign_target, Target, Expr} | Rest], Env0, _Last) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    Env2 = bind_assignment_target(Target, Value, Env1),
    eval_statements(Rest, Env2, Value);
eval_statements_inner([{assign_chain, Targets, Expr} | Rest], Env0, _Last) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    Env2 = lists:foldl(
        fun(Target, AccEnv) -> bind_assignment_target(Target, Value, AccEnv) end, Env1, Targets
    ),
    eval_statements(Rest, Env2, Value);
eval_statements_inner([{assign_attr, {attr, ObjectExpr, Name}, Expr} | Rest], Env0, _Last) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Value, Env2} = eval_expr(Expr, Env1),
    ok = pyrlang_object:set_attr(Object, Name, Value),
    eval_statements(Rest, Env2, Value);
eval_statements_inner(
    [{assign_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr}}, Expr} | Rest],
    Env0,
    _Last
) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Start, Env2} = eval_optional_slice(StartExpr, Env1),
    {Stop, Env3} = eval_optional_slice(StopExpr, Env2),
    {Value, Env4} = eval_expr(Expr, Env3),
    ok = set_slice_or_raise(Object, Start, Stop, Value),
    eval_statements(Rest, Env4, Value);
eval_statements_inner(
    [
        {assign_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr, undefined}}, Expr}
        | Rest
    ],
    Env0,
    Last
) ->
    eval_statements(
        [{assign_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr}}, Expr} | Rest],
        Env0,
        Last
    );
eval_statements_inner(
    [{assign_subscript, {subscript, ObjectExpr, IndexExpr}, Expr} | Rest], Env0, _Last
) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Index, Env2} = eval_expr(IndexExpr, Env1),
    {Value, Env3} = eval_expr(Expr, Env2),
    ok = set_subscript_or_raise(Object, Index, Value),
    eval_statements(Rest, Env3, Value);
eval_statements_inner([{aug_assign, Target, Op, Expr} | Rest], Env0, _Last) ->
    {Current, Env1} = read_assignment_target(Target, Env0),
    {Right, Env2} = eval_expr(Expr, Env1),
    Value = eval_aug_assign_value(Op, Current, Right),
    Env3 = bind_assignment_target(Target, Value, Env2),
    eval_statements(Rest, Env3, Value);
eval_statements_inner([{ann_assign, _Target, none} | Rest], Env0, _Last) ->
    eval_statements(Rest, Env0, none);
eval_statements_inner([{ann_assign, Target, Expr} | Rest], Env0, _Last) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    Env2 = bind_assignment_target(Target, Value, Env1),
    eval_statements(Rest, Env2, Value);
eval_statements_inner([{type_alias, Name, Expr} | Rest], Env0, _Last) ->
    Alias = make_type_alias(Name, Expr, Env0),
    eval_statements(Rest, Env0#{Name => Alias}, Alias);
eval_statements_inner([{del, Target} | Rest], Env0, _Last) ->
    Env1 = delete_assignment_target(Target, Env0),
    eval_statements(Rest, Env1, none);
eval_statements_inner([{return, Expr} | _Rest], Env0, _Last) ->
    {Value, _Env1} = eval_expr(Expr, Env0),
    throw({py_return, Value});
eval_statements_inner([{yield, _Expr} | _Rest], _Env0, _Last) ->
    erlang:error(yield_outside_generator_collection);
eval_statements_inner([{yield_from, _Expr} | _Rest], _Env0, _Last) ->
    erlang:error(yield_outside_generator_collection);
eval_statements_inner([{raise, bare} | _Rest], Env0, _Last) ->
    raise_current_exception(Env0);
eval_statements_inner([{raise, Expr} | _Rest], Env0, _Last) ->
    {Value, _Env1} = eval_expr(Expr, Env0),
    pyrlang_exception:raise(Value);
eval_statements_inner([{raise_from, Expr, _Cause} | _Rest], Env0, _Last) ->
    {Value, _Env1} = eval_expr(Expr, Env0),
    pyrlang_exception:raise(Value);
eval_statements_inner([{assert, Expr} | Rest], Env0, _Last) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    case truthy(Value) of
        true ->
            eval_statements(Rest, Env1, none);
        false ->
            raise_builtin(<<"AssertionError">>, <<>>)
    end;
eval_statements_inner([break | _Rest], Env0, _Last) ->
    throw({py_break, Env0});
eval_statements_inner([continue | _Rest], Env0, _Last) ->
    throw({py_continue, Env0});
eval_statements_inner([{global, Names} | Rest], Env0, Last) ->
    Existing = maps:get(?GLOBAL_DECL_NAMES, Env0, []),
    eval_statements(Rest, Env0#{?GLOBAL_DECL_NAMES => lists:usort(Existing ++ Names)}, Last);
eval_statements_inner([{nonlocal, _Names} | Rest], Env0, Last) ->
    eval_statements(Rest, Env0, Last);
eval_statements_inner([pass | Rest], Env0, Last) ->
    eval_statements(Rest, Env0, Last);
eval_statements_inner([{expr, Expr} | Rest], Env0, _Last) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_statements(Rest, Env1, Value).

sync_current_loading_module_env(Env) ->
    case erlang:get(?MODULE_EVAL_KEY) of
        true ->
            sync_current_loading_module_env_top_level(Env);
        _ ->
            ok
    end.

sync_current_loading_module_env_top_level(Env) ->
    case erlang:get(pyrlang_current_loading_module) of
        {py_ref, _} = ModuleRef ->
            try
                Data = pyrlang_heap:data(ModuleRef),
                ExistingEnv = maps:get(env, Data, #{}),
                ok = pyrlang_heap:set_data(ModuleRef, Data#{env := maps:merge(ExistingEnv, Env)})
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

lookup_var(Name, Env) ->
    case maps:find(Name, Env) of
        {ok, Value} ->
            maybe_bind_lookup_function(Name, Value, Env);
        error ->
            case lookup_enclosing_function_env(Name) of
                {ok, Value} ->
                    maybe_bind_lookup_function(Name, Value, Env);
                error ->
                    case lookup_function_global_env(Name) of
                        {ok, Value} ->
                            Value;
                        error ->
                            case lookup_module_global(Name, Env) of
                                {ok, Value} ->
                                    Value;
                                error ->
                                    case pyrlang_builtins:lookup(Name) of
                                        {ok, Value} ->
                                            Value;
                                        error ->
                                            trace_name_miss(Name, Env),
                                            pyrlang_exception:raise(
                                                pyrlang_exception:make(
                                                    pyrlang_exception:type(<<"NameError">>),
                                                    <<"name '", Name/binary, "' is not defined">>
                                                )
                                            )
                                    end
                            end
                    end
            end
    end.

lookup_enclosing_function_env(Name) ->
    case erlang:get(?FUNCTION_ENV_STACK_KEY) of
        [_Current | Outers] ->
            lookup_enclosing_function_env(Name, Outers);
        _ ->
            error
    end.

lookup_enclosing_function_env(_Name, []) ->
    error;
lookup_enclosing_function_env(Name, [Env | Rest]) ->
    case maps:find(Name, Env) of
        {ok, Value} -> {ok, Value};
        error -> lookup_enclosing_function_env(Name, Rest)
    end.

lookup_function_global_env(Name) ->
    case erlang:get(?FUNCTION_GLOBAL_ENV_KEY) of
        GlobalEnv when is_map(GlobalEnv) -> maps:find(Name, GlobalEnv);
        _ -> error
    end.

trace_name_miss(Name, Env) ->
    case os:getenv("PYRLANG_TRACE_NAME_MISS") of
        false ->
            ok;
        _ ->
            ModuleName = maps:get(<<"__name__">>, Env, undefined),
            io:format(
                standard_error,
                "PYRLANG_NAME_MISS ~p ~s stack=~p~n",
                [ModuleName, Name, trace_function_stack()]
            )
    end.

trace_eval_flow(Stage, Value) ->
    case os:getenv("PYRLANG_TRACE_NATIVE_FLOW") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_EVAL ~p ~p~n", [Stage, trace_eval_value(Value)])
    end.

trace_eval_value({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        Type -> {py_ref, Type}
    catch
        _:_ -> Ref
    end;
trace_eval_value({py_function, _Params, _Body, Env}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_eval_value({py_function, _Params, _Body, Env, _Mode}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_eval_value({py_function, _Params, _Body, Env, _Mode, _Owner}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_eval_value(List) when is_list(List) ->
    {list, length(List)};
trace_eval_value(Tuple) when is_tuple(Tuple) ->
    {tuple, tuple_size(Tuple)};
trace_eval_value(Value) ->
    Value.

maybe_bind_lookup_function(Name, Value, Env) ->
    case should_bind_lookup_function(Name, Value) of
        true -> bind_function_globals(Value, Env);
        false -> Value
    end.

should_bind_lookup_function(Name, Value) ->
    case is_py_function(Value) of
        false ->
            true;
        true ->
            case erlang:get(?FUNCTION_GLOBAL_ENV_KEY) of
                GlobalEnv when is_map(GlobalEnv) -> maps:is_key(Name, GlobalEnv);
                _ -> true
            end
    end.

lookup_module_global(_Name, #{<<"__name__">> := <<"__main__">>}) ->
    error;
lookup_module_global(<<"constructor">>, #{<<"__name__">> := <<"copyreg">>}) ->
    {ok, fun(_Object) -> none end};
lookup_module_global(Name, #{<<"__name__">> := ModuleName}) when is_binary(ModuleName) ->
    try pyrlang_module:get_attr(pyrlang_module:load(ModuleName), Name) of
        Value -> {ok, Value}
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> -> error;
                _ -> pyrlang_exception:raise(Exception)
            end;
        _:_ ->
            error
    end;
lookup_module_global(_Name, _Env) ->
    error.

globals_mapping(Env) ->
    case erlang:get(pyrlang_current_loading_module) of
        {py_ref, _} = ModuleRef ->
            {py_module_dict, ModuleRef};
        _ ->
            case maps:get(<<"__name__">>, Env, undefined) of
                undefined ->
                    pyrlang_heap:dict(Env);
                <<"__main__">> ->
                    pyrlang_heap:dict(Env);
                ModuleName ->
                    try
                        {py_module_dict, pyrlang_module:load(ModuleName)}
                    catch
                        _:_ -> pyrlang_heap:dict(Env)
                    end
            end
    end.

eval_exprs([], Env, Acc) ->
    {lists:reverse(Acc), Env};
eval_exprs([Expr | Rest], Env0, Acc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_exprs(Rest, Env1, [Value | Acc]).

eval_list_items([], Env, Acc) ->
    {lists:reverse(Acc), Env};
eval_list_items([{starred, Expr} | Rest], Env0, Acc) ->
    {Iterable, Env1} = eval_expr(Expr, Env0),
    eval_list_items(Rest, Env1, lists:reverse(iter_values(Iterable)) ++ Acc);
eval_list_items([Expr | Rest], Env0, Acc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_list_items(Rest, Env1, [Value | Acc]).

eval_call_args([], Env, PosAcc, KwAcc) ->
    {lists:reverse(PosAcc), KwAcc, Env};
eval_call_args([{arg, Expr} | Rest], Env0, PosAcc, KwAcc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_call_args(Rest, Env1, [Value | PosAcc], KwAcc);
eval_call_args([{kwarg, Name, Expr} | Rest], Env0, PosAcc, KwAcc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_call_args(Rest, Env1, PosAcc, put_kwarg(Name, Value, KwAcc));
eval_call_args([{star_arg, Expr} | Rest], Env0, PosAcc, KwAcc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_call_args(Rest, Env1, lists:reverse(iter_values(Value)) ++ PosAcc, KwAcc);
eval_call_args([{starstar_kwarg, Expr} | Rest], Env0, PosAcc, KwAcc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_call_args(Rest, Env1, PosAcc, merge_kwargs(kwargs_items(Value), KwAcc));
eval_call_args([Expr | Rest], Env0, PosAcc, KwAcc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_call_args(Rest, Env1, [Value | PosAcc], KwAcc).

put_kwarg(Name, Value, KwAcc) ->
    case maps:is_key(Name, KwAcc) of
        true -> erlang:error({type_error, {multiple_values_for_argument, Name}});
        false -> maps:put(Name, Value, KwAcc)
    end.

merge_kwargs([], KwAcc) ->
    KwAcc;
merge_kwargs([{Name, Value} | Rest], KwAcc) when is_binary(Name) ->
    merge_kwargs(Rest, put_kwarg(Name, Value, KwAcc));
merge_kwargs([{Name, _Value} | _Rest], _KwAcc) ->
    erlang:error({type_error, {keyword_must_be_string, Name}}).

kwargs_items({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> pyrlang_heap:dict_items(Ref);
        Type -> erlang:error({type_error, {not_mapping, Type}})
    end;
kwargs_items(Map) when is_map(Map) ->
    maps:to_list(Map);
kwargs_items(Other) ->
    erlang:error({type_error, {not_mapping, Other}}).

eval_pairs([], Env, Acc) ->
    {lists:reverse(Acc), Env};
eval_pairs([{dict_unpack, Expr} | Rest], Env0, Acc) ->
    {Mapping, Env1} = eval_expr(Expr, Env0),
    Items = module_dict_items(Mapping),
    eval_pairs(Rest, Env1, lists:reverse(Items) ++ Acc);
eval_pairs([{KeyExpr, ValueExpr} | Rest], Env0, Acc) ->
    {Key, Env1} = eval_expr(KeyExpr, Env0),
    {Value, Env2} = eval_expr(ValueExpr, Env1),
    eval_pairs(Rest, Env2, [{Key, Value} | Acc]).

eval_match_cases(_Subject, [], Env) ->
    {none, Env};
eval_match_cases(Subject, [{Pattern, Guard, Body} | Rest], Env0) ->
    case match_pattern(Pattern, Subject, Env0) of
        {match, Bindings, Env1} ->
            CaseEnv = maps:merge(Env1, Bindings),
            case match_guard(Guard, CaseEnv) of
                {true, GuardEnv} ->
                    eval_statements(Body, GuardEnv, none);
                {false, GuardEnv} ->
                    eval_match_cases(Subject, Rest, GuardEnv)
            end;
        {nomatch, Env1} ->
            eval_match_cases(Subject, Rest, Env1)
    end.

match_guard(none, Env) ->
    {true, Env};
match_guard(Guard, Env0) ->
    {Value, Env1} = eval_expr(Guard, Env0),
    {truthy(Value), Env1}.

match_pattern(wildcard, _Subject, Env) ->
    {match, #{}, Env};
match_pattern({capture, Name}, Subject, Env) ->
    {match, #{Name => Subject}, Env};
match_pattern({value, Expr}, Subject, Env0) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    case truthy(eval_compare(eq, Subject, Value)) of
        true -> {match, #{}, Env1};
        false -> {nomatch, Env1}
    end;
match_pattern({or_pattern, Patterns}, Subject, Env0) ->
    match_or_patterns(Patterns, Subject, Env0);
match_pattern({class_pattern, ClassExpr, Positional, Keywords}, Subject, Env0) ->
    {Class, Env1} = eval_expr(ClassExpr, Env0),
    case match_is_instance(Subject, Class) of
        true ->
            match_class_patterns(Subject, Class, Positional, Keywords, Env1);
        false ->
            {nomatch, Env1}
    end.

match_or_patterns([], _Subject, Env) ->
    {nomatch, Env};
match_or_patterns([Pattern | Rest], Subject, Env0) ->
    case match_pattern(Pattern, Subject, Env0) of
        {match, Bindings, Env1} -> {match, Bindings, Env1};
        {nomatch, Env1} -> match_or_patterns(Rest, Subject, Env1)
    end.

match_class_patterns(Subject, Class, Positional, Keywords, Env0) ->
    case match_positional_class_patterns(Subject, Class, Positional, Env0) of
        {match, PosBindings, Env1} ->
            case match_keyword_class_patterns(Subject, Keywords, Env1) of
                {match, KwBindings, Env2} -> {match, maps:merge(PosBindings, KwBindings), Env2};
                {nomatch, Env2} -> {nomatch, Env2}
            end;
        {nomatch, Env1} ->
            {nomatch, Env1}
    end.

match_positional_class_patterns(_Subject, _Class, [], Env) ->
    {match, #{}, Env};
match_positional_class_patterns(Subject, Class, Positional, Env0) ->
    Names = class_match_args(Class, length(Positional)),
    match_class_attr_patterns(Subject, lists:zip(Names, Positional), Env0, #{}).

match_keyword_class_patterns(Subject, Keywords, Env) ->
    match_class_attr_patterns(Subject, Keywords, Env, #{}).

match_class_attr_patterns(_Subject, [], Env, Bindings) ->
    {match, Bindings, Env};
match_class_attr_patterns(Subject, [{Name, Pattern} | Rest], Env0, Bindings0) ->
    case get_match_attr(Subject, Name) of
        {ok, Value} ->
            case match_pattern(Pattern, Value, Env0) of
                {match, NewBindings, Env1} ->
                    match_class_attr_patterns(
                        Subject, Rest, Env1, maps:merge(Bindings0, NewBindings)
                    );
                {nomatch, Env1} ->
                    {nomatch, Env1}
            end;
        error ->
            {nomatch, Env0}
    end.

class_match_args(Class, Count) ->
    try pyrlang_object:get_attr(Class, <<"__match_args__">>) of
        Args -> lists:sublist(match_arg_names(Args), Count)
    catch
        _:_ ->
            [integer_to_binary(Index) || Index <- lists:seq(0, Count - 1)]
    end.

match_arg_names(Args) when is_tuple(Args) ->
    tuple_to_list(Args);
match_arg_names({py_ref, _} = Args) ->
    case pyrlang_heap:type(Args) of
        list -> pyrlang_heap:list_items(Args);
        _ -> []
    end;
match_arg_names(_Args) ->
    [].

get_match_attr(Subject, Name) ->
    try pyrlang_object:get_attr(Subject, Name) of
        Value -> {ok, Value}
    catch
        _:_ -> error
    end.

match_is_instance({py_ref, _} = Subject, Class) ->
    case {is_class_ref(Class), pyrlang_heap:type(Subject)} of
        {true, instance} ->
            lists:member(Class, pyrlang_object:mro(maps:get(class, pyrlang_heap:data(Subject))));
        {true, class} ->
            lists:member(Class, pyrlang_object:mro(pyrlang_builtins:object_class(Subject)));
        _ ->
            false
    end;
match_is_instance(Subject, Class) ->
    case is_class_ref(Class) of
        true ->
            case pyrlang_builtins:object_class(Subject) of
                undefined -> false;
                SubjectClass -> lists:member(Class, pyrlang_object:mro(SubjectClass))
            end;
        false ->
            false
    end.

create_class(Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, Env0) ->
    trace_class(start, Name, Env0),
    {ExplicitBases, Env1} = eval_exprs(BaseExprs, Env0, []),
    trace_class(bases, Name, Env1),
    {ClassKwArgs, Env2} = eval_class_keywords(ClassKwExprs, Env1, #{}),
    trace_class(keywords, Name, Env2),
    EffectiveBases = implicit_object_base(ExplicitBases),
    sync_current_loading_module_env(Env2),
    trace_class(sync, Name, Env2),
    Attrs = ensure_class_module_attr(eval_class_body(Body, Env2, class_attrs_init()), Env2),
    trace_class(body, Name, Env2),
    {Class, EnvAfter, SelectedMetaclass} =
        case MetaclassExpr of
            undefined ->
                case select_metaclass(EffectiveBases) of
                    undefined ->
                        trace_class(new_class, Name, Env2),
                        {pyrlang_object:new_class(Name, EffectiveBases, Attrs), Env2, undefined};
                    InheritedMetaclass ->
                        trace_class(metaclass, Name, Env2),
                        {
                            call_metaclass(
                                InheritedMetaclass, Name, ExplicitBases, Attrs, ClassKwArgs
                            ),
                            Env2,
                            InheritedMetaclass
                        }
                end;
            _ ->
                trace_class(explicit_metaclass, Name, Env2),
                {Metaclass, Env3} = eval_expr(MetaclassExpr, Env2),
                {
                    call_metaclass(Metaclass, Name, ExplicitBases, Attrs, ClassKwArgs),
                    Env3,
                    Metaclass
                }
        end,
    trace_class(created, Name, EnvAfter),
    maybe_set_metaclass(Class, SelectedMetaclass),
    trace_class(metaclass_set, Name, EnvAfter),
    bind_class_name(Class, Name),
    trace_class(done, Name, EnvAfter),
    {Class, EnvAfter}.

trace_class(Stage, Name, Env) ->
    case os:getenv("PYRLANG_TRACE_MODULE") of
        false ->
            ok;
        ModuleName0 ->
            ModuleName = unicode:characters_to_binary(ModuleName0),
            case maps:get(<<"__name__">>, Env, undefined) of
                ModuleName ->
                    io:format(standard_error, "PYRLANG_CLASS ~s ~p ~s~n", [ModuleName, Stage, Name]);
                _ ->
                    ok
            end
    end.

ensure_class_module_attr(Attrs, Env) ->
    case maps:is_key(<<"__module__">>, Attrs) of
        true -> Attrs;
        false -> Attrs#{<<"__module__">> => maps:get(<<"__name__">>, Env, <<"__main__">>)}
    end.

class_attrs_init() ->
    #{?CLASS_ATTR_ORDER_KEY => []}.

class_attrs_public(Attrs) ->
    maps:remove(?CLASS_ATTR_ORDER_KEY, Attrs).

put_class_attr(Name, Value, Attrs) ->
    Attrs1 =
        case maps:is_key(Name, Attrs) orelse is_class_internal_attr(Name) of
            true ->
                Attrs;
            false ->
                Order = maps:get(?CLASS_ATTR_ORDER_KEY, Attrs, []),
                Attrs#{?CLASS_ATTR_ORDER_KEY => Order ++ [Name]}
        end,
    Attrs1#{Name => Value}.

remove_class_attr(Name, Attrs) ->
    Order = maps:get(?CLASS_ATTR_ORDER_KEY, Attrs, []),
    (maps:remove(Name, Attrs))#{?CLASS_ATTR_ORDER_KEY => [Key || Key <- Order, Key =/= Name]}.

class_attr_order(Attrs) ->
    Ordered = [
        Name
     || Name <- maps:get(?CLASS_ATTR_ORDER_KEY, Attrs, []), maps:is_key(Name, Attrs)
    ],
    Ordered ++
        [
            Name
         || Name <- maps:keys(Attrs),
            Name =/= ?CLASS_ATTR_ORDER_KEY,
            not lists:member(Name, Ordered)
        ].

is_class_internal_attr(<<"__pyrlang_", _Rest/binary>>) ->
    true;
is_class_internal_attr(_Name) ->
    false.

make_type_alias(Name, Expr, Env) ->
    case maps:find(<<"TypeAliasType">>, Env) of
        {ok, Class} when is_tuple(Class) ->
            try pyrlang_heap:type(Class) of
                class ->
                    Alias = pyrlang_object:instantiate(Class),
                    ok = pyrlang_object:set_attr(Alias, <<"__name__">>, Name),
                    ok = pyrlang_object:set_attr(
                        Alias, <<"__module__">>, maps:get(<<"__name__">>, Env, <<"__main__">>)
                    ),
                    ok = pyrlang_object:set_attr(
                        Alias, <<"__value__">>, {py_lazy_type_alias_value, Expr, Env}
                    ),
                    ok = pyrlang_object:set_attr(Alias, <<"__type_params__">>, {}),
                    Alias;
                _ ->
                    {py_type_alias, Name, Expr, Env}
            catch
                _:_ -> {py_type_alias, Name, Expr, Env}
            end;
        _ ->
            {py_type_alias, Name, Expr, Env}
    end.

eval_class_keywords([], Env, Acc) ->
    {Acc, Env};
eval_class_keywords([{Name, Expr} | Rest], Env0, Acc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_class_keywords(Rest, Env1, put_kwarg(Name, Value, Acc)).

implicit_object_base([]) ->
    [maps:get(<<"object">>, pyrlang_builtins:env())];
implicit_object_base(Bases) ->
    Bases.

select_metaclass(Bases) ->
    select_metaclass(Bases, undefined).

select_metaclass([], Selected) ->
    Selected;
select_metaclass([Base | Rest], undefined) ->
    select_metaclass(Rest, pyrlang_object:metaclass(Base));
select_metaclass([Base | Rest], Selected) ->
    case pyrlang_object:metaclass(Base) of
        undefined ->
            select_metaclass(Rest, Selected);
        Selected ->
            select_metaclass(Rest, Selected);
        Other ->
            case {metaclass_subclass(Other, Selected), metaclass_subclass(Selected, Other)} of
                {true, _} -> select_metaclass(Rest, Other);
                {_, true} -> select_metaclass(Rest, Selected);
                _ -> erlang:error({type_error, {metaclass_conflict, Selected, Other}})
            end
    end.

metaclass_subclass(Class, Target) ->
    case is_class_ref(Class) andalso is_class_ref(Target) of
        true -> lists:member(Target, pyrlang_object:mro(Class));
        false -> Class =:= Target
    end.

call_metaclass(Metaclass, Name, Bases, Attrs0, KwArgs) ->
    Attrs = prepare_classdict_attrs(Metaclass, Attrs0, Bases),
    AttrsRef = pyrlang_heap:dict(Attrs),
    BasesRef = pyrlang_heap:list(Bases),
    call_value(Metaclass, {call_args, [Name, BasesRef, AttrsRef], KwArgs}).

prepare_classdict_attrs(Metaclass, Attrs, Bases) ->
    Prepared =
        case is_enum_metaclass(Metaclass) of
            true ->
                MemberNames = enum_member_names(Attrs),
                Attrs1 = expand_enum_auto_values(Attrs, MemberNames, Bases),
                maps:put(
                    <<"_member_names">>,
                    pyrlang_heap:dict([{Name, none} || Name <- MemberNames]),
                    Attrs1
                );
            false ->
                Attrs
        end,
    class_attrs_public(Prepared).

is_enum_metaclass(Metaclass) ->
    case is_class_ref(Metaclass) of
        true ->
            lists:any(
                fun(Class) ->
                    Name = pyrlang_object:class_name(Class),
                    Name =:= <<"EnumType">> orelse Name =:= <<"EnumMeta">>
                end,
                pyrlang_object:mro(Metaclass)
            );
        false ->
            false
    end.

enum_member_names(Attrs) ->
    [Name || Name <- class_attr_order(Attrs), enum_member_name(Name, maps:get(Name, Attrs))].

enum_member_name(<<"_", _/binary>>, _Value) ->
    false;
enum_member_name(_Name, {py_function, _Params, _Body, _Env}) ->
    false;
enum_member_name(_Name, {py_function, _Params, _Body, _Env, _IsGenerator}) ->
    false;
enum_member_name(_Name, {py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass}) ->
    false;
enum_member_name(_Name, #{py_descriptor := true}) ->
    false;
enum_member_name(_Name, Value) when is_function(Value) ->
    false;
enum_member_name(_Name, Value) ->
    not is_class_ref(Value).

expand_enum_auto_values(Attrs, MemberNames, Bases) ->
    Generator = inherited_enum_next_value(Bases),
    {Expanded, _Count, _LastValues} =
        lists:foldl(
            fun(Name, {AccAttrs, Count, LastValues}) ->
                Value = maps:get(Name, AccAttrs),
                case enum_auto_instance(Value) of
                    {auto, AutoRef} ->
                        Generated = enum_generated_value(Generator, Name, Count, LastValues),
                        ok = pyrlang_object:set_attr(AutoRef, <<"value">>, Generated),
                        {AccAttrs#{Name := Generated}, Count + 1, LastValues ++ [Generated]};
                    not_auto ->
                        {AccAttrs, Count + 1, LastValues ++ [Value]}
                end
            end,
            {Attrs, 0, []},
            MemberNames
        ),
    Expanded.

inherited_enum_next_value(Bases) ->
    inherited_enum_next_value(Bases, none).

inherited_enum_next_value([], Default) ->
    Default;
inherited_enum_next_value([Base | Rest], Default) ->
    try pyrlang_object:get_attr(Base, <<"_generate_next_value_">>) of
        Generator -> Generator
    catch
        _:_ -> inherited_enum_next_value(Rest, Default)
    end.

enum_generated_value(none, _Name, Count, _LastValues) ->
    Count + 1;
enum_generated_value(Generator, Name, Count, LastValues) ->
    call_value(Generator, [Name, 1, Count, pyrlang_heap:list(LastValues)]).

enum_auto_instance({py_ref, _} = Ref) ->
    try
        case pyrlang_heap:type(Ref) of
            instance ->
                Class = maps:get(class, pyrlang_heap:data(Ref)),
                case pyrlang_object:class_name(Class) of
                    <<"auto">> -> {auto, Ref};
                    _ -> not_auto
                end;
            _ ->
                not_auto
        end
    catch
        _:_ -> not_auto
    end;
enum_auto_instance(_Value) ->
    not_auto.

maybe_set_metaclass(_Class, undefined) ->
    ok;
maybe_set_metaclass(Class, Metaclass) ->
    case is_class_ref(Metaclass) of
        true -> pyrlang_object:set_metaclass(Class, Metaclass);
        false -> ok
    end.

bind_class_name(Class, Name) ->
    Data = pyrlang_heap:data(Class),
    Attrs = maps:get(attrs, Data),
    UpdatedAttrs = maps:map(
        fun(_AttrName, Value) -> bind_class_name_in_value(Value, Name, Class) end, Attrs
    ),
    ok = pyrlang_heap:set_data(Class, Data#{attrs := UpdatedAttrs}).

bind_class_name_in_value({py_function, Params, Body, Env}, Name, Class) ->
    {py_function, Params, Body, Env#{Name => Class}};
bind_class_name_in_value({py_function, Params, Body, Env, IsGenerator}, Name, Class) ->
    {py_function, Params, Body, Env#{Name => Class}, IsGenerator};
bind_class_name_in_value({py_function, Params, Body, Env, IsGenerator, OwnerClass}, Name, Class) ->
    {py_function, Params, Body, Env#{Name => Class}, IsGenerator, OwnerClass};
bind_class_name_in_value(#{py_descriptor := true, kind := property} = Descriptor, Name, Class) ->
    case
        maps:is_key(fget, Descriptor) orelse maps:is_key(fset, Descriptor) orelse
            maps:is_key(fdel, Descriptor)
    of
        true -> bind_property_descriptor_class(Descriptor, Name, Class);
        false -> Descriptor
    end;
bind_class_name_in_value(#{py_descriptor := true, callable := Callable} = Descriptor, Name, Class) ->
    Descriptor#{callable := bind_class_name_in_value(Callable, Name, Class)};
bind_class_name_in_value(Value, _Name, _Class) ->
    Value.

bind_property_descriptor_class(Descriptor, Name, Class) ->
    Getter = bind_optional_descriptor_callable(maps:get(fget, Descriptor, none), Name, Class),
    Setter = bind_optional_descriptor_callable(maps:get(fset, Descriptor, none), Name, Class),
    Deleter = bind_optional_descriptor_callable(maps:get(fdel, Descriptor, none), Name, Class),
    Get =
        case Getter of
            none -> fun(_Obj, _Class) -> none end;
            _ -> fun(Obj, _Class) -> pyrlang_eval:call(Getter, [Obj]) end
        end,
    Set =
        case Setter of
            none ->
                undefined;
            _ ->
                fun(Obj, Value) ->
                    _ = pyrlang_eval:call(Setter, [Obj, Value]),
                    ok
                end
        end,
    Del =
        case Deleter of
            none ->
                undefined;
            _ ->
                fun(Obj) ->
                    _ = pyrlang_eval:call(Deleter, [Obj]),
                    ok
                end
        end,
    maps:put(
        del,
        Del,
        maps:put(
            set,
            Set,
            maps:put(
                get,
                Get,
                maps:put(fdel, Deleter, maps:put(fset, Setter, maps:put(fget, Getter, Descriptor)))
            )
        )
    ).

bind_optional_descriptor_callable(none, _Name, _Class) ->
    none;
bind_optional_descriptor_callable(Callable, Name, Class) ->
    bind_class_name_in_value(Callable, Name, Class).

get_attribute(Object, Name) ->
    case descriptor_attribute(Object, Name) of
        {ok, Value} ->
            Value;
        error ->
            case builtin_attribute(Object, Name) of
                {ok, Value} ->
                    Value;
                error ->
                    try
                        pyrlang_object:get_attr(Object, Name)
                    catch
                        error:{attribute_error, Attr} ->
                            trace_attr_miss(Object, Attr),
                            raise_builtin(<<"AttributeError">>, Attr)
                    end
            end
    end.

trace_attr_miss(Object, Attr) ->
    case os:getenv("PYRLANG_TRACE_ATTR_MISS") of
        false ->
            ok;
        "1" ->
            trace_attr_miss_line(Object, Attr);
        Target ->
            case unicode:characters_to_binary(Target) =:= Attr of
                true -> trace_attr_miss_line(Object, Attr);
                false -> ok
            end
    end.

trace_attr_miss_line(Object, Attr) ->
    io:format(
        standard_error,
        "PYRLANG_ATTR_MISS ~s ~s stack=~p~n",
        [describe_attr_object(Object), Attr, trace_function_stack()]
    ).

describe_attr_object({py_ref, _} = Ref) ->
    try
        case pyrlang_heap:type(Ref) of
            class ->
                <<"class:", (pyrlang_object:class_name(Ref))/binary>>;
            instance ->
                Class = maps:get(class, pyrlang_heap:data(Ref)),
                <<"instance:", (pyrlang_object:class_name(Class))/binary>>;
            Type ->
                unicode:characters_to_binary(io_lib:format("~p", [Type]))
        end
    catch
        _:_ -> <<"ref">>
    end;
describe_attr_object({py_module_dict, _}) ->
    <<"module_dict">>;
describe_attr_object({py_instance_dict, _}) ->
    <<"instance_dict">>;
describe_attr_object(Object) when is_tuple(Object), tuple_size(Object) > 0 ->
    unicode:characters_to_binary(io_lib:format("~p", [element(1, Object)]));
describe_attr_object(Object) when is_map(Object) ->
    <<"map">>;
describe_attr_object(Object) ->
    unicode:characters_to_binary(io_lib:format("~p", [Object])).

descriptor_attribute(
    #{py_descriptor := true, kind := property, get := Get} = Descriptor, <<"setter">>
) ->
    {ok, fun(Setter) ->
        Del = maps:get(del, Descriptor, undefined),
        pyrlang_object:descriptor(
            Get,
            fun(Obj, Value) ->
                _ = call(Setter, [Obj, Value]),
                ok
            end,
            Descriptor#{
                kind => property,
                del => Del,
                fset => Setter
            }
        )
    end};
descriptor_attribute(
    #{py_descriptor := true, kind := property, set := Set} = Descriptor, <<"getter">>
) ->
    {ok, fun(Getter) ->
        Del = maps:get(del, Descriptor, undefined),
        pyrlang_object:descriptor(
            fun(Obj, _Class) -> call(Getter, [Obj]) end,
            Set,
            Descriptor#{
                kind => property,
                del => Del,
                fget => Getter
            }
        )
    end};
descriptor_attribute(
    #{py_descriptor := true, kind := property, get := Get} = Descriptor, <<"deleter">>
) ->
    {ok, fun(Deleter) ->
        Set = maps:get(set, Descriptor, undefined),
        pyrlang_object:descriptor(
            Get,
            Set,
            Descriptor#{
                kind => property,
                del => fun(Obj) ->
                    _ = call(Deleter, [Obj]),
                    ok
                end,
                fdel => Deleter
            }
        )
    end};
descriptor_attribute(#{py_descriptor := true, kind := property} = Descriptor, <<"fget">>) ->
    {ok, maps:get(fget, Descriptor, none)};
descriptor_attribute(#{py_descriptor := true, kind := property} = Descriptor, <<"fset">>) ->
    {ok, maps:get(fset, Descriptor, none)};
descriptor_attribute(#{py_descriptor := true, kind := property} = Descriptor, <<"fdel">>) ->
    {ok, maps:get(fdel, Descriptor, none)};
descriptor_attribute(#{py_descriptor := true, kind := property} = Descriptor, <<"__doc__">>) ->
    {ok, maps:get(doc, Descriptor, none)};
descriptor_attribute(#{py_descriptor := true, callable := Callable}, <<"__func__">>) ->
    {ok, Callable};
descriptor_attribute(_Object, _Name) ->
    error.

builtin_attribute(Integer, <<"bit_length">>) when is_integer(Integer) ->
    {ok, fun() -> integer_bit_length(Integer) end};
builtin_attribute(Integer, <<"to_bytes">>) when is_integer(Integer) ->
    {ok, {py_native_call, fun(Args, KwArgs) -> integer_to_bytes(Integer, Args, KwArgs) end}};
builtin_attribute(none, <<"__new__">>) ->
    {ok, pyrlang_object:get_attr(maps:get(<<"object">>, pyrlang_builtins:env()), <<"__new__">>)};
builtin_attribute(Separator, <<"join">>) when is_binary(Separator) ->
    {ok, fun(Iterable) ->
        join_binary([py_string(Value) || Value <- iter_values(Iterable)], Separator)
    end};
builtin_attribute(Binary, <<"startswith">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_startswith(Binary, Args) end}};
builtin_attribute(Binary, <<"endswith">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_endswith(Binary, Args) end}};
builtin_attribute(Binary, <<"removeprefix">>) when is_binary(Binary) ->
    {ok, fun(Prefix) -> string_removeprefix(Binary, Prefix) end};
builtin_attribute(Binary, <<"removesuffix">>) when is_binary(Binary) ->
    {ok, fun(Suffix) -> string_removesuffix(Binary, Suffix) end};
builtin_attribute(Binary, <<"lower">>) when is_binary(Binary) ->
    {ok, fun() -> string:lowercase(Binary) end};
builtin_attribute(Binary, <<"upper">>) when is_binary(Binary) ->
    {ok, fun() -> string:uppercase(Binary) end};
builtin_attribute(Binary, <<"capitalize">>) when is_binary(Binary) ->
    {ok, fun() -> string_capitalize(Binary) end};
builtin_attribute(Binary, <<"title">>) when is_binary(Binary) ->
    {ok, fun() -> string_title(Binary) end};
builtin_attribute(Binary, <<"strip">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_strip(Binary, Args) end}};
builtin_attribute(Binary, <<"lstrip">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_lstrip(Binary, Args) end}};
builtin_attribute(Binary, <<"rstrip">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_rstrip(Binary, Args) end}};
builtin_attribute(Binary, <<"replace">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_replace(Binary, Args) end}};
builtin_attribute(Binary, <<"split">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_split(Binary, Args) end}};
builtin_attribute(Binary, <<"rsplit">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_rsplit(Binary, Args) end}};
builtin_attribute(Binary, <<"splitlines">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_splitlines(Binary, Args) end}};
builtin_attribute(Binary, <<"partition">>) when is_binary(Binary) ->
    {ok, fun(Sep) -> string_partition(Binary, Sep) end};
builtin_attribute(Binary, <<"rpartition">>) when is_binary(Binary) ->
    {ok, fun(Sep) -> string_rpartition(Binary, Sep) end};
builtin_attribute(Binary, <<"find">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_find(Binary, Args) end}};
builtin_attribute(Binary, <<"rfind">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_rfind(Binary, Args) end}};
builtin_attribute(Binary, <<"index">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_index(Binary, Args) end}};
builtin_attribute(Binary, <<"rindex">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_rindex(Binary, Args) end}};
builtin_attribute(Binary, <<"count">>) when is_binary(Binary) ->
    {ok, {py_native_varargs, fun(Args) -> string_count(Binary, Args) end}};
builtin_attribute(Binary, <<"isascii">>) when is_binary(Binary) ->
    {ok, fun() -> string_isascii(Binary) end};
builtin_attribute(Binary, <<"isdigit">>) when is_binary(Binary) ->
    {ok, fun() -> string_isdigit(Binary) end};
builtin_attribute(Binary, <<"isupper">>) when is_binary(Binary) ->
    {ok, fun() -> string_isupper(Binary) end};
builtin_attribute(Binary, <<"islower">>) when is_binary(Binary) ->
    {ok, fun() -> string_islower(Binary) end};
builtin_attribute(Binary, <<"isidentifier">>) when is_binary(Binary) ->
    {ok, fun() -> string_isidentifier(Binary) end};
builtin_attribute(Binary, <<"format">>) when is_binary(Binary) ->
    {ok, {py_native_call, fun(Args, KwArgs) -> string_format(Binary, Args, KwArgs) end}};
builtin_attribute(Binary, <<"format_map">>) when is_binary(Binary) ->
    {ok, fun(Mapping) -> string_format(Binary, [], mapping_to_map(Mapping)) end};
builtin_attribute(Binary, <<"encode">>) when is_binary(Binary) ->
    {ok,
        {py_native_call, fun(Args, KwArgs) -> binary_codec_call(Binary, Args, KwArgs, encode) end}};
builtin_attribute(Binary, <<"decode">>) when is_binary(Binary) ->
    {ok,
        {py_native_call, fun(Args, KwArgs) -> binary_codec_call(Binary, Args, KwArgs, decode) end}};
builtin_attribute(Binary, <<"hex">>) when is_binary(Binary) ->
    {ok, fun() -> binary_hex(Binary) end};
builtin_attribute(Binary, <<"translate">>) when is_binary(Binary) ->
    {ok, fun(Table) -> string_translate(Binary, Table) end};
builtin_attribute(Binary, <<"__iter__">>) when is_binary(Binary) ->
    {ok, fun() -> pyrlang_iter:iter(Binary) end};
builtin_attribute(Binary, <<"__getitem__">>) when is_binary(Binary) ->
    {ok, fun(Index) -> get_subscript(Binary, Index) end};
builtin_attribute(Binary, <<"__len__">>) when is_binary(Binary) ->
    {ok, fun() -> length([Char || <<Char/utf8>> <= Binary]) end};
builtin_attribute(Binary, <<"__contains__">>) when is_binary(Binary) ->
    {ok, fun(Needle) ->
        case binary:match(Binary, py_string(Needle)) of
            nomatch -> false;
            _ -> true
        end
    end};
builtin_attribute(Binary, <<"__eq__">>) when is_binary(Binary) ->
    {ok, fun(Other) -> Binary =:= py_string(Other) end};
builtin_attribute(Binary, <<"__ne__">>) when is_binary(Binary) ->
    {ok, fun(Other) -> Binary =/= py_string(Other) end};
builtin_attribute({py_ref, _} = Ref, <<"lower">>) ->
    case string_proxy_value(Ref) of
        {ok, Value} -> {ok, fun() -> string:lowercase(Value) end};
        error -> error
    end;
builtin_attribute({py_ref, _} = Ref, <<"upper">>) ->
    case string_proxy_value(Ref) of
        {ok, Value} -> {ok, fun() -> string:uppercase(Value) end};
        error -> error
    end;
builtin_attribute({py_ref, _}, <<"index">>) ->
    error;
builtin_attribute({py_ref, _}, <<"count">>) ->
    error;
builtin_attribute(Tuple, <<"index">>) when is_tuple(Tuple) ->
    {ok, {py_native_varargs, fun(Args) -> tuple_index(Tuple, Args) end}};
builtin_attribute(Tuple, <<"count">>) when is_tuple(Tuple) ->
    {ok, {py_native_varargs, fun(Args) -> tuple_count(Tuple, Args) end}};
builtin_attribute(#{py_exception := true, type := Type}, <<"__class__">>) ->
    {ok, pyrlang_exception:type(Type)};
builtin_attribute(#{py_exception := true} = Exception, Attr) ->
    case pyrlang_exception:get_attr(Exception, Attr) of
        {ok, Value} ->
            {ok, Value};
        error ->
            case maps:find(Attr, maps:get(kwargs, Exception, #{})) of
                {ok, Value} -> {ok, Value};
                error -> builtin_exception_attribute(Exception, Attr)
            end
    end;
builtin_attribute(_Object, <<"__doc__">>) ->
    {ok, none};
builtin_attribute({py_module_dict, ModuleRef}, <<"get">>) ->
    {ok,
        {py_native_varargs, fun
            ([Key]) -> maps:get(Key, pyrlang_module:env(ModuleRef), none);
            ([Key, Default]) -> maps:get(Key, pyrlang_module:env(ModuleRef), Default);
            (Args) -> erlang:error({arity_error, {module_dict_get, length(Args)}})
        end}};
builtin_attribute({py_module_dict, ModuleRef}, <<"items">>) ->
    {ok, fun() -> pyrlang_heap:list(maps:to_list(pyrlang_module:env(ModuleRef))) end};
builtin_attribute({py_module_dict, ModuleRef}, <<"keys">>) ->
    {ok, fun() -> pyrlang_heap:list(maps:keys(pyrlang_module:env(ModuleRef))) end};
builtin_attribute({py_module_dict, ModuleRef}, <<"values">>) ->
    {ok, fun() -> pyrlang_heap:list(maps:values(pyrlang_module:env(ModuleRef))) end};
builtin_attribute({py_module_dict, ModuleRef}, <<"copy">>) ->
    {ok, fun() -> pyrlang_heap:dict(maps:to_list(pyrlang_module:env(ModuleRef))) end};
builtin_attribute({py_module_dict, ModuleRef}, <<"update">>) ->
    {ok,
        {py_native_call, fun(Args, KwArgs) ->
            lists:foreach(
                fun({Key, Value}) -> ok = pyrlang_module:set_attr(ModuleRef, Key, Value) end,
                module_dict_update_items(Args)
            ),
            maps:foreach(
                fun(Key, Value) -> ok = pyrlang_module:set_attr(ModuleRef, Key, Value) end, KwArgs
            ),
            none
        end}};
builtin_attribute({py_module_dict, ModuleRef}, <<"pop">>) ->
    {ok,
        {py_native_varargs, fun
            ([Key]) -> module_dict_pop(ModuleRef, Key);
            ([Key, Default]) -> module_dict_pop(ModuleRef, Key, Default);
            (Args) -> erlang:error({arity_error, {module_dict_pop, length(Args)}})
        end}};
builtin_attribute({py_module_dict, ModuleRef}, <<"__getitem__">>) ->
    {ok, fun(Key) ->
        case maps:find(Key, pyrlang_module:env(ModuleRef)) of
            {ok, Value} -> Value;
            error -> raise_builtin(<<"KeyError">>, Key)
        end
    end};
builtin_attribute({py_module_dict, ModuleRef}, <<"__setitem__">>) ->
    {ok, fun(Key, Value) -> pyrlang_module:set_attr(ModuleRef, Key, Value) end};
builtin_attribute({py_module_dict, ModuleRef}, <<"__contains__">>) ->
    {ok, fun(Key) -> maps:is_key(Key, pyrlang_module:env(ModuleRef)) end};
builtin_attribute({py_instance_dict, Instance}, <<"get">>) ->
    {ok,
        {py_native_varargs, fun
            ([Key]) -> maps:get(Key, instance_dict_attrs(Instance), none);
            ([Key, Default]) -> maps:get(Key, instance_dict_attrs(Instance), Default);
            (Args) -> erlang:error({arity_error, {instance_dict_get, length(Args)}})
        end}};
builtin_attribute({py_instance_dict, Instance}, <<"items">>) ->
    {ok, fun() -> pyrlang_heap:list(maps:to_list(instance_dict_attrs(Instance))) end};
builtin_attribute({py_instance_dict, Instance}, <<"keys">>) ->
    {ok, fun() -> pyrlang_heap:list(maps:keys(instance_dict_attrs(Instance))) end};
builtin_attribute({py_instance_dict, Instance}, <<"values">>) ->
    {ok, fun() -> pyrlang_heap:list(maps:values(instance_dict_attrs(Instance))) end};
builtin_attribute({py_instance_dict, Instance}, <<"copy">>) ->
    {ok, fun() -> pyrlang_heap:dict(maps:to_list(instance_dict_attrs(Instance))) end};
builtin_attribute({py_instance_dict, Instance}, <<"update">>) ->
    {ok,
        {py_native_call, fun(Args, KwArgs) ->
            lists:foreach(
                fun({Key, Value}) -> ok = pyrlang_object:set_attr(Instance, Key, Value) end,
                module_dict_update_items(Args)
            ),
            maps:foreach(
                fun(Key, Value) -> ok = pyrlang_object:set_attr(Instance, Key, Value) end, KwArgs
            ),
            none
        end}};
builtin_attribute({py_instance_dict, Instance}, <<"pop">>) ->
    {ok,
        {py_native_varargs, fun
            ([Key]) -> instance_dict_pop(Instance, Key);
            ([Key, Default]) -> instance_dict_pop(Instance, Key, Default);
            (Args) -> erlang:error({arity_error, {instance_dict_pop, length(Args)}})
        end}};
builtin_attribute({py_instance_dict, Instance}, <<"__getitem__">>) ->
    {ok, fun(Key) ->
        Attrs = instance_dict_attrs(Instance),
        case maps:find(Key, Attrs) of
            {ok, Value} -> Value;
            error -> raise_builtin(<<"KeyError">>, Key)
        end
    end};
builtin_attribute({py_instance_dict, Instance}, <<"__setitem__">>) ->
    {ok, fun(Key, Value) ->
        Data = pyrlang_heap:data(Instance),
        Attrs = maps:get(attrs, Data, #{}),
        pyrlang_heap:set_data(Instance, Data#{attrs := maps:put(Key, Value, Attrs)})
    end};
builtin_attribute({py_instance_dict, Instance}, <<"__delitem__">>) ->
    {ok, fun(Key) ->
        case maps:is_key(Key, instance_dict_attrs(Instance)) of
            true -> pyrlang_object:del_attr(Instance, Key);
            false -> raise_builtin(<<"KeyError">>, Key)
        end
    end};
builtin_attribute({py_instance_dict, Instance}, <<"__contains__">>) ->
    {ok, fun(Key) -> maps:is_key(Key, instance_dict_attrs(Instance)) end};
builtin_attribute(_Object, _Name) ->
    error.

builtin_exception_attribute(#{py_exception := true} = Exception, <<"args">>) ->
    {ok, pyrlang_exception:args(Exception)};
builtin_exception_attribute(#{py_exception := true} = Exception, <<"errno">>) ->
    {ok, exception_arg(Exception, 1)};
builtin_exception_attribute(#{py_exception := true} = Exception, <<"strerror">>) ->
    {ok, exception_arg(Exception, 2)};
builtin_exception_attribute(#{py_exception := true} = Exception, <<"filename">>) ->
    {ok, exception_arg(Exception, 3)};
builtin_exception_attribute(#{py_exception := true}, <<"__traceback__">>) ->
    {ok, none};
builtin_exception_attribute(#{py_exception := true}, <<"__cause__">>) ->
    {ok, none};
builtin_exception_attribute(#{py_exception := true}, <<"__context__">>) ->
    {ok, none};
builtin_exception_attribute(#{py_exception := true}, <<"__suppress_context__">>) ->
    {ok, false};
builtin_exception_attribute(_Exception, _Attr) ->
    error.

instance_dict_attrs(Instance) ->
    Data = pyrlang_heap:data(Instance),
    maps:get(attrs, Data).

instance_dict_pop(Instance, Key) ->
    Attrs = instance_dict_attrs(Instance),
    case maps:find(Key, Attrs) of
        {ok, Value} ->
            ok = pyrlang_object:del_attr(Instance, Key),
            Value;
        error ->
            erlang:error({badkey, Key})
    end.

instance_dict_pop(Instance, Key, Default) ->
    Attrs = instance_dict_attrs(Instance),
    case maps:find(Key, Attrs) of
        {ok, Value} ->
            ok = pyrlang_object:del_attr(Instance, Key),
            Value;
        error ->
            Default
    end.

exception_arg(Exception, Position) ->
    Args = tuple_to_list(pyrlang_exception:args(Exception)),
    case length(Args) >= Position of
        true -> lists:nth(Position, Args);
        false -> none
    end.

string_startswith(Binary, [Prefix]) ->
    string_prefix_matches(Binary, Prefix);
string_startswith(Binary, [Prefix, Start]) ->
    string_prefix_matches(get_slice(Binary, Start, undefined), Prefix);
string_startswith(Binary, [Prefix, Start, Stop]) ->
    string_prefix_matches(get_slice(Binary, Start, Stop), Prefix);
string_startswith(_Binary, Args) ->
    erlang:error({arity_error, {startswith, length(Args)}}).

string_endswith(Binary, [Suffix]) ->
    string_suffix_matches(Binary, Suffix);
string_endswith(Binary, [Suffix, Start]) ->
    string_suffix_matches(get_slice(Binary, Start, undefined), Suffix);
string_endswith(Binary, [Suffix, Start, Stop]) ->
    string_suffix_matches(get_slice(Binary, Start, Stop), Suffix);
string_endswith(_Binary, Args) ->
    erlang:error({arity_error, {endswith, length(Args)}}).

string_prefix_matches(Binary, Prefixes) when is_tuple(Prefixes) ->
    lists:any(fun(Prefix) -> string_prefix_matches(Binary, Prefix) end, tuple_to_list(Prefixes));
string_prefix_matches(Binary, Prefix) ->
    PrefixBin = py_string(Prefix),
    Size = byte_size(PrefixBin),
    byte_size(Binary) >= Size andalso binary:part(Binary, 0, Size) =:= PrefixBin.

string_suffix_matches(Binary, Suffixes) when is_tuple(Suffixes) ->
    lists:any(fun(Suffix) -> string_suffix_matches(Binary, Suffix) end, tuple_to_list(Suffixes));
string_suffix_matches(Binary, Suffix) ->
    SuffixBin = py_string(Suffix),
    Size = byte_size(SuffixBin),
    BinarySize = byte_size(Binary),
    BinarySize >= Size andalso binary:part(Binary, BinarySize - Size, Size) =:= SuffixBin.

string_removeprefix(Binary, Prefix) ->
    PrefixBin = py_string(Prefix),
    Size = byte_size(PrefixBin),
    case byte_size(Binary) >= Size andalso binary:part(Binary, 0, Size) =:= PrefixBin of
        true -> binary:part(Binary, Size, byte_size(Binary) - Size);
        false -> Binary
    end.

string_removesuffix(Binary, Suffix) ->
    SuffixBin = py_string(Suffix),
    Size = byte_size(SuffixBin),
    BinarySize = byte_size(Binary),
    case BinarySize >= Size andalso binary:part(Binary, BinarySize - Size, Size) =:= SuffixBin of
        true -> binary:part(Binary, 0, BinarySize - Size);
        false -> Binary
    end.

string_strip(Binary, []) ->
    unicode:characters_to_binary(string:trim(unicode:characters_to_list(Binary)));
string_strip(Binary, [Chars]) ->
    trim_chars(Binary, py_string(Chars), both);
string_strip(_Binary, Args) ->
    erlang:error({arity_error, {strip, length(Args)}}).

string_lstrip(Binary, []) ->
    unicode:characters_to_binary(string:trim(unicode:characters_to_list(Binary), leading));
string_lstrip(Binary, [Chars]) ->
    trim_chars(Binary, py_string(Chars), leading);
string_lstrip(_Binary, Args) ->
    erlang:error({arity_error, {lstrip, length(Args)}}).

string_rstrip(Binary, []) ->
    unicode:characters_to_binary(string:trim(unicode:characters_to_list(Binary), trailing));
string_rstrip(Binary, [Chars]) ->
    trim_chars(Binary, py_string(Chars), trailing);
string_rstrip(_Binary, Args) ->
    erlang:error({arity_error, {rstrip, length(Args)}}).

trim_chars(Binary, Chars, Direction) ->
    List = unicode:characters_to_list(Binary),
    TrimChars = unicode:characters_to_list(Chars),
    Trimmed =
        case Direction of
            leading ->
                trim_chars_left(List, TrimChars);
            trailing ->
                lists:reverse(trim_chars_left(lists:reverse(List), TrimChars));
            both ->
                lists:reverse(
                    trim_chars_left(lists:reverse(trim_chars_left(List, TrimChars)), TrimChars)
                )
        end,
    unicode:characters_to_binary(Trimmed).

trim_chars_left([Ch | Rest], Chars) ->
    case lists:member(Ch, Chars) of
        true -> trim_chars_left(Rest, Chars);
        false -> [Ch | Rest]
    end;
trim_chars_left([], _Chars) ->
    [].

string_replace(Binary, [Old, New]) ->
    binary:replace(Binary, py_string(Old), py_string(New), [global]);
string_replace(Binary, [Old, New, Count]) when is_integer(Count), Count < 0 ->
    string_replace(Binary, [Old, New]);
string_replace(Binary, [Old, New, Count]) when is_integer(Count) ->
    replace_limited(Binary, py_string(Old), py_string(New), Count);
string_replace(_Binary, Args) ->
    erlang:error({arity_error, {replace, length(Args)}}).

string_translate(Binary, Table) ->
    Map = translation_map(Table),
    iolist_to_binary([translate_char(Char, Map) || <<Char/utf8>> <= Binary]).

binary_codec_call(Binary, Args, KwArgs, Name) ->
    binary_codec_check_kwargs(KwArgs, Name),
    binary_codec_check_duplicate_args(Args, KwArgs, Name),
    case length(Args) =< 2 of
        true -> Binary;
        false -> erlang:error({arity_error, {Name, length(Args), maps:size(KwArgs)}})
    end.

binary_codec_check_kwargs(KwArgs, Name) ->
    case [Key || Key <- maps:keys(KwArgs), Key =/= <<"encoding">>, Key =/= <<"errors">>] of
        [] -> ok;
        Extra -> erlang:error({type_error, {Name, unexpected_keyword_argument, Extra}})
    end.

binary_codec_check_duplicate_args(Args, KwArgs, Name) ->
    Positional = lists:sublist([<<"encoding">>, <<"errors">>], length(Args)),
    Duplicates = [Key || Key <- Positional, maps:is_key(Key, KwArgs)],
    case Duplicates of
        [] ->
            ok;
        [Duplicate | _] ->
            erlang:error({type_error, {Name, multiple_values_for_argument, Duplicate}})
    end.

translation_map({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> maps:from_list(pyrlang_heap:dict_items(Ref));
        _Type -> maps:from_list(kwargs_items(Ref))
    end;
translation_map(Map) when is_map(Map) ->
    Map.

translate_char(Char, Map) ->
    case maps:find(Char, Map) of
        {ok, none} -> <<>>;
        {ok, Value} when is_integer(Value) -> <<Value/utf8>>;
        {ok, Value} when is_binary(Value) -> Value;
        error -> <<Char/utf8>>
    end.

replace_limited(Binary, _Old, _New, 0) ->
    Binary;
replace_limited(Binary, Old, New, Count) ->
    case binary:match(Binary, Old) of
        {Pos, Size} ->
            Prefix = binary:part(Binary, 0, Pos),
            Suffix = binary:part(Binary, Pos + Size, byte_size(Binary) - Pos - Size),
            ReplacedSuffix = replace_limited(Suffix, Old, New, Count - 1),
            <<Prefix/binary, New/binary, ReplacedSuffix/binary>>;
        nomatch ->
            Binary
    end.

string_split(Binary, []) ->
    pyrlang_heap:list([
        unicode:characters_to_binary(Part)
     || Part <- string:tokens(unicode:characters_to_list(Binary), " \t\r\n")
    ]);
string_split(Binary, [none]) ->
    string_split(Binary, []);
string_split(Binary, [none, MaxSplit]) ->
    pyrlang_heap:list(split_whitespace(Binary, split_limit(MaxSplit)));
string_split(Binary, [Sep]) ->
    pyrlang_heap:list(binary:split(Binary, py_string(Sep), [global]));
string_split(Binary, [Sep, MaxSplit]) ->
    split_limited(Binary, py_string(Sep), MaxSplit, forward);
string_split(_Binary, Args) ->
    erlang:error({arity_error, {split, length(Args)}}).

string_rsplit(Binary, []) ->
    string_split(Binary, []);
string_rsplit(Binary, [none]) ->
    string_split(Binary, []);
string_rsplit(Binary, [none, MaxSplit]) ->
    pyrlang_heap:list(rsplit_whitespace(Binary, split_limit(MaxSplit)));
string_rsplit(Binary, [Sep]) ->
    pyrlang_heap:list(binary:split(Binary, py_string(Sep), [global]));
string_rsplit(Binary, [Sep, MaxSplit]) ->
    split_limited(Binary, py_string(Sep), MaxSplit, reverse);
string_rsplit(_Binary, Args) ->
    erlang:error({arity_error, {rsplit, length(Args)}}).

string_splitlines(Binary, []) ->
    pyrlang_heap:list(splitlines(Binary, false, <<>>, []));
string_splitlines(Binary, [KeepEnds]) ->
    pyrlang_heap:list(splitlines(Binary, truthy(KeepEnds), <<>>, []));
string_splitlines(_Binary, Args) ->
    erlang:error({arity_error, {splitlines, length(Args)}}).

split_limit(true) -> 1;
split_limit(false) -> 0;
split_limit(Value) when is_integer(Value) -> Value;
split_limit(Value) when is_float(Value) -> trunc(Value);
split_limit(_Value) -> -1.

split_whitespace(Binary, Limit) when Limit < 0 ->
    [
        unicode:characters_to_binary(Part)
     || Part <- string:tokens(unicode:characters_to_list(Binary), " \t\r\n\v\f")
    ];
split_whitespace(Binary, Limit) ->
    split_whitespace_limited(skip_left_ws(Binary), Limit, []).

split_whitespace_limited(<<>>, _Limit, Acc) ->
    lists:reverse(Acc);
split_whitespace_limited(Binary, 0, Acc) ->
    lists:reverse([Binary | Acc]);
split_whitespace_limited(Binary, Limit, Acc) ->
    {Token, Rest0} = take_non_ws(Binary, <<>>),
    Rest = skip_left_ws(Rest0),
    case Rest of
        <<>> -> lists:reverse([Token | Acc]);
        _ -> split_whitespace_limited(Rest, Limit - 1, [Token | Acc])
    end.

rsplit_whitespace(Binary, Limit) when Limit < 0 ->
    split_whitespace(Binary, Limit);
rsplit_whitespace(Binary, Limit) ->
    Parts = split_whitespace(Binary, -1),
    case length(Parts) =< Limit + 1 of
        true ->
            Parts;
        false ->
            {LeftParts, RightParts} = lists:split(length(Parts) - Limit, Parts),
            [join_binary(LeftParts, <<" ">>) | RightParts]
    end.

skip_left_ws(<<Char/utf8, Rest/binary>>) ->
    case is_ascii_ws(Char) of
        true -> skip_left_ws(Rest);
        false -> <<Char/utf8, Rest/binary>>
    end;
skip_left_ws(<<>>) ->
    <<>>.

take_non_ws(<<Char/utf8, Rest/binary>>, Acc) ->
    case is_ascii_ws(Char) of
        true -> {Acc, Rest};
        false -> take_non_ws(Rest, <<Acc/binary, Char/utf8>>)
    end;
take_non_ws(<<>>, Acc) ->
    {Acc, <<>>}.

is_ascii_ws($\s) -> true;
is_ascii_ws($\t) -> true;
is_ascii_ws($\r) -> true;
is_ascii_ws($\n) -> true;
is_ascii_ws($\v) -> true;
is_ascii_ws($\f) -> true;
is_ascii_ws(_) -> false.

splitlines(<<>>, _KeepEnds, <<>>, Acc) ->
    lists:reverse(Acc);
splitlines(<<>>, _KeepEnds, Current, Acc) ->
    lists:reverse([Current | Acc]);
splitlines(<<"\r\n", Rest/binary>>, KeepEnds, Current, Acc) ->
    Line =
        case KeepEnds of
            true -> <<Current/binary, "\r\n">>;
            false -> Current
        end,
    splitlines(Rest, KeepEnds, <<>>, [Line | Acc]);
splitlines(<<"\n", Rest/binary>>, KeepEnds, Current, Acc) ->
    Line =
        case KeepEnds of
            true -> <<Current/binary, "\n">>;
            false -> Current
        end,
    splitlines(Rest, KeepEnds, <<>>, [Line | Acc]);
splitlines(<<"\r", Rest/binary>>, KeepEnds, Current, Acc) ->
    Line =
        case KeepEnds of
            true -> <<Current/binary, "\r">>;
            false -> Current
        end,
    splitlines(Rest, KeepEnds, <<>>, [Line | Acc]);
splitlines(<<Char/utf8, Rest/binary>>, KeepEnds, Current, Acc) ->
    splitlines(Rest, KeepEnds, <<Current/binary, Char/utf8>>, Acc).

split_limited(Binary, Sep, MaxSplit, _Direction) when not is_integer(MaxSplit); MaxSplit < 0 ->
    pyrlang_heap:list(binary:split(Binary, Sep, [global]));
split_limited(Binary, Sep, MaxSplit, forward) ->
    pyrlang_heap:list(split_forward(Binary, Sep, MaxSplit, []));
split_limited(Binary, Sep, MaxSplit, reverse) ->
    Parts = binary:split(Binary, Sep, [global]),
    case length(Parts) =< MaxSplit + 1 of
        true ->
            pyrlang_heap:list(Parts);
        false ->
            PrefixCount = length(Parts) - MaxSplit,
            {PrefixParts, SuffixParts} = lists:split(PrefixCount, Parts),
            Prefix = join_binary(PrefixParts, Sep),
            pyrlang_heap:list([Prefix | SuffixParts])
    end.

split_forward(Binary, _Sep, 0, Acc) ->
    lists:reverse([Binary | Acc]);
split_forward(Binary, Sep, Count, Acc) ->
    case binary:match(Binary, Sep) of
        {Pos, Size} ->
            Prefix = binary:part(Binary, 0, Pos),
            Suffix = binary:part(Binary, Pos + Size, byte_size(Binary) - Pos - Size),
            split_forward(Suffix, Sep, Count - 1, [Prefix | Acc]);
        nomatch ->
            lists:reverse([Binary | Acc])
    end.

string_partition(Binary, Sep0) ->
    Sep = py_string(Sep0),
    case binary:match(Binary, Sep) of
        {Pos, Size} ->
            Prefix = binary:part(Binary, 0, Pos),
            Suffix = binary:part(Binary, Pos + Size, byte_size(Binary) - Pos - Size),
            {Prefix, Sep, Suffix};
        nomatch ->
            {Binary, <<>>, <<>>}
    end.

string_rpartition(Binary, Sep0) ->
    Sep = py_string(Sep0),
    case binary:matches(Binary, Sep) of
        [] ->
            {<<>>, <<>>, Binary};
        Matches ->
            {Pos, Size} = lists:last(Matches),
            Prefix = binary:part(Binary, 0, Pos),
            Suffix = binary:part(Binary, Pos + Size, byte_size(Binary) - Pos - Size),
            {Prefix, Sep, Suffix}
    end.

string_find(Binary, [Needle]) ->
    string_find(Binary, [Needle, 0, undefined]);
string_find(Binary, [Needle, Start]) ->
    string_find(Binary, [Needle, Start, undefined]);
string_find(Binary, [Needle, Start, Stop]) ->
    Sliced = get_slice(Binary, Start, Stop),
    Offset = string_slice_offset(Binary, Start),
    case binary:match(Sliced, py_string(Needle)) of
        {Pos, _Size} -> Pos + Offset;
        nomatch -> -1
    end;
string_find(_Binary, Args) ->
    erlang:error({arity_error, {find, length(Args)}}).

string_rfind(Binary, [Needle]) ->
    string_rfind(Binary, [Needle, 0, undefined]);
string_rfind(Binary, [Needle, Start]) ->
    string_rfind(Binary, [Needle, Start, undefined]);
string_rfind(Binary, [Needle, Start, Stop]) ->
    Sliced = get_slice(Binary, Start, Stop),
    Offset = string_slice_offset(Binary, Start),
    case binary:matches(Sliced, py_string(Needle)) of
        [] ->
            -1;
        Matches ->
            {Pos, _Size} = lists:last(Matches),
            Pos + Offset
    end;
string_rfind(_Binary, Args) ->
    erlang:error({arity_error, {rfind, length(Args)}}).

string_index(Binary, Args) ->
    case string_find(Binary, Args) of
        -1 -> raise_builtin(<<"ValueError">>, <<"substring not found">>);
        Pos -> Pos
    end.

string_rindex(Binary, Args) ->
    case string_rfind(Binary, Args) of
        -1 -> raise_builtin(<<"ValueError">>, <<"substring not found">>);
        Pos -> Pos
    end.

string_slice_offset(_Binary, undefined) ->
    0;
string_slice_offset(_Binary, none) ->
    0;
string_slice_offset(Binary, Start) when is_integer(Start) ->
    normalize_slice_start(Start, length([Char || <<Char/utf8>> <= Binary])).

string_count(Binary, [Needle]) ->
    string_count(Binary, [Needle, 0, undefined]);
string_count(Binary, [Needle, Start]) ->
    string_count(Binary, [Needle, Start, undefined]);
string_count(Binary, [Needle, Start, Stop]) ->
    Sliced = get_slice(Binary, Start, Stop),
    count_nonoverlapping(Sliced, py_string(Needle));
string_count(_Binary, Args) ->
    erlang:error({arity_error, {count, length(Args)}}).

tuple_index(Tuple, [Needle]) ->
    tuple_index(Tuple, [Needle, 0, undefined]);
tuple_index(Tuple, [Needle, Start]) ->
    tuple_index(Tuple, [Needle, Start, undefined]);
tuple_index(Tuple, [Needle, Start, Stop]) ->
    Items = tuple_to_list(Tuple),
    From = tuple_range_start(Start, length(Items)),
    To = tuple_range_stop(Stop, length(Items)),
    case tuple_index_from(Items, Needle, From, To, 0) of
        {ok, Index} -> Index;
        error -> raise_builtin(<<"ValueError">>, <<"tuple.index(x): x not in tuple">>)
    end;
tuple_index(_Tuple, Args) ->
    erlang:error({arity_error, {tuple_index, length(Args)}}).

tuple_index_from([], _Needle, _From, _To, _Index) ->
    error;
tuple_index_from([_Item | Rest], Needle, From, To, Index) when Index < From ->
    tuple_index_from(Rest, Needle, From, To, Index + 1);
tuple_index_from(_Items, _Needle, _From, To, Index) when Index >= To ->
    error;
tuple_index_from([Item | Rest], Needle, From, To, Index) ->
    case truthy(eval_compare(eq, Item, Needle)) of
        true -> {ok, Index};
        false -> tuple_index_from(Rest, Needle, From, To, Index + 1)
    end.

tuple_count(Tuple, [Needle]) ->
    length([Item || Item <- tuple_to_list(Tuple), truthy(eval_compare(eq, Item, Needle))]);
tuple_count(_Tuple, Args) ->
    erlang:error({arity_error, {tuple_count, length(Args)}}).

tuple_range_start(undefined, _Length) ->
    0;
tuple_range_start(Start, Length) ->
    clamp_slice_index(list_index(Start), Length).

tuple_range_stop(undefined, Length) ->
    Length;
tuple_range_stop(Stop, Length) ->
    clamp_slice_index(list_index(Stop), Length).

count_nonoverlapping(Binary, <<>>) ->
    length([Char || <<Char/utf8>> <= Binary]) + 1;
count_nonoverlapping(Binary, Needle) ->
    count_nonoverlapping(Binary, Needle, 0).

count_nonoverlapping(Binary, Needle, Count) ->
    case binary:match(Binary, Needle) of
        {Pos, Size} ->
            Next = Pos + Size,
            Rest = binary:part(Binary, Next, byte_size(Binary) - Next),
            count_nonoverlapping(Rest, Needle, Count + 1);
        nomatch ->
            Count
    end.

string_isdigit(<<>>) ->
    false;
string_isdigit(Binary) ->
    lists:all(fun(Ch) -> Ch >= $0 andalso Ch =< $9 end, binary_to_list(Binary)).

string_isupper(Binary) ->
    Letters = [
        Ch
     || Ch <- binary_to_list(Binary), (Ch >= $A andalso Ch =< $Z) orelse (Ch >= $a andalso Ch =< $z)
    ],
    Letters =/= [] andalso lists:all(fun(Ch) -> Ch >= $A andalso Ch =< $Z end, Letters).

string_islower(Binary) ->
    Letters = [
        Ch
     || Ch <- binary_to_list(Binary), (Ch >= $A andalso Ch =< $Z) orelse (Ch >= $a andalso Ch =< $z)
    ],
    Letters =/= [] andalso lists:all(fun(Ch) -> Ch >= $a andalso Ch =< $z end, Letters).

string_title(Binary) ->
    unicode:characters_to_binary(string_title_chars(binary_to_list(Binary), true, [])).

string_capitalize(<<>>) ->
    <<>>;
string_capitalize(Binary) ->
    unicode:characters_to_binary(string_capitalize_chars(binary_to_list(Binary))).

string_capitalize_chars([First | Rest]) ->
    [ascii_upper(First) | [ascii_lower(Ch) || Ch <- Rest]].

string_title_chars([], _NewWord, Acc) ->
    lists:reverse(Acc);
string_title_chars([Ch | Rest], NewWord, Acc) when Ch >= $A, Ch =< $Z ->
    Out =
        case NewWord of
            true -> Ch;
            false -> Ch + 32
        end,
    string_title_chars(Rest, false, [Out | Acc]);
string_title_chars([Ch | Rest], NewWord, Acc) when Ch >= $a, Ch =< $z ->
    Out =
        case NewWord of
            true -> Ch - 32;
            false -> Ch
        end,
    string_title_chars(Rest, false, [Out | Acc]);
string_title_chars([Ch | Rest], _NewWord, Acc) ->
    string_title_chars(Rest, true, [Ch | Acc]).

ascii_upper(Ch) when Ch >= $a, Ch =< $z ->
    Ch - 32;
ascii_upper(Ch) ->
    Ch.

ascii_lower(Ch) when Ch >= $A, Ch =< $Z ->
    Ch + 32;
ascii_lower(Ch) ->
    Ch.

string_isidentifier(<<>>) ->
    false;
string_isidentifier(Binary) ->
    [First | Rest] = binary_to_list(Binary),
    (First =:= $_ orelse (First >= $A andalso First =< $Z) orelse (First >= $a andalso First =< $z)) andalso
        lists:all(
            fun(Ch) ->
                Ch =:= $_ orelse (Ch >= $A andalso Ch =< $Z) orelse (Ch >= $a andalso Ch =< $z) orelse
                    (Ch >= $0 andalso Ch =< $9)
            end,
            Rest
        ).

string_isascii(Binary) ->
    lists:all(fun(Byte) -> Byte < 128 end, binary_to_list(Binary)).

binary_hex(Binary) ->
    binary_hex(Binary, <<>>).

binary_hex(<<>>, Acc) ->
    Acc;
binary_hex(<<Byte:8, Rest/binary>>, Acc) ->
    binary_hex(
        Rest, <<Acc/binary, (binary_hex_digit(Byte bsr 4)), (binary_hex_digit(Byte band 15))>>
    ).

binary_hex_digit(Value) when Value < 10 ->
    $0 + Value;
binary_hex_digit(Value) ->
    $a + (Value - 10).

string_format(Format, Args, KwArgs) ->
    string_format_parts(Format, Args, KwArgs, 0, []).

string_format_parts(<<"{{", Rest/binary>>, Args, KwArgs, Index, Acc) ->
    string_format_parts(Rest, Args, KwArgs, Index, [<<"{">> | Acc]);
string_format_parts(<<"}}", Rest/binary>>, Args, KwArgs, Index, Acc) ->
    string_format_parts(Rest, Args, KwArgs, Index, [<<"}">> | Acc]);
string_format_parts(<<"{", Rest/binary>>, Args, KwArgs, Index, Acc) ->
    case binary:match(Rest, <<"}">>) of
        {Pos, 1} ->
            Field = binary:part(Rest, 0, Pos),
            Tail = binary:part(Rest, Pos + 1, byte_size(Rest) - Pos - 1),
            {Name, Conversion, Spec} = split_format_field(Field),
            {Value, NextIndex} = string_format_field_value(Name, Args, KwArgs, Index),
            Text = string_format_field_text(Value, Conversion, Spec),
            string_format_parts(Tail, Args, KwArgs, NextIndex, [Text | Acc]);
        nomatch ->
            unicode:characters_to_binary(lists:reverse([<<"{">> | Acc]))
    end;
string_format_parts(<<Char/utf8, Rest/binary>>, Args, KwArgs, Index, Acc) ->
    string_format_parts(Rest, Args, KwArgs, Index, [<<Char/utf8>> | Acc]);
string_format_parts(<<>>, _Args, _KwArgs, _Index, Acc) ->
    join_binary(lists:reverse(Acc), <<>>).

split_format_field(Field) ->
    {Head, Spec} = split_format_field_part(Field, <<":">>),
    {Name, ConversionBin} = split_format_field_part(Head, <<"!">>),
    Conversion =
        case ConversionBin of
            <<>> -> none;
            <<Char/utf8, _Rest/binary>> -> Char
        end,
    {Name, Conversion, Spec}.

split_format_field_part(Field, Separator) ->
    case binary:match(Field, Separator) of
        {Pos, 1} ->
            Before = binary:part(Field, 0, Pos),
            After = binary:part(Field, Pos + 1, byte_size(Field) - Pos - 1),
            {Before, After};
        nomatch ->
            {Field, <<>>}
    end.

string_format_field_value(<<>>, Args, _KwArgs, Index) ->
    {lists:nth(Index + 1, Args), Index + 1};
string_format_field_value(Name, Args, KwArgs, Index) ->
    Value =
        case binary_to_integer_or_error(Name) of
            {ok, Integer} -> lists:nth(Integer + 1, Args);
            error -> maps:get(Name, KwArgs)
        end,
    {Value, Index}.

string_format_field_text(Value, none, Spec) ->
    format_brace_value(Value, Spec);
string_format_field_text(Value, Conversion, Spec) when
    Conversion =:= $s; Conversion =:= $r; Conversion =:= $a
->
    format_brace_value(py_string(Value), Spec);
string_format_field_text(Value, _Conversion, Spec) ->
    format_brace_value(Value, Spec).

format_brace_value(Value, <<>>) ->
    py_string(Value);
format_brace_value(Value, Spec) when is_integer(Value); is_boolean(Value) ->
    case integer_format_spec(numeric_value(Value), Spec) of
        {ok, Text} -> Text;
        unsupported -> py_string(Value)
    end;
format_brace_value(Value, Spec) when is_float(Value) ->
    case fstring_fixed_precision(Spec) of
        {ok, Precision} ->
            unicode:characters_to_binary(io_lib:format("~.*f", [Precision, numeric_value(Value)]));
        unsupported ->
            py_string(Value)
    end;
format_brace_value(Value, _Spec) ->
    py_string(Value).

integer_format_spec(Value, Spec) ->
    Chars = binary_to_list(Spec),
    {Type, Prefix} =
        case Chars of
            [] ->
                {$d, []};
            _ ->
                Last = lists:last(Chars),
                case lists:member(Last, "dioxX") of
                    true -> {Last, lists:droplast(Chars)};
                    false -> {$d, Chars}
                end
        end,
    case integer_format_width(Prefix) of
        {ok, Width, PadChar} ->
            Digits0 = integer_format_digits(Value, Type),
            Digits = pad_left(Digits0, Width, PadChar),
            {ok, unicode:characters_to_binary(Digits)};
        unsupported ->
            unsupported
    end.

integer_format_width([]) ->
    {ok, 0, $\s};
integer_format_width([$0 | Rest] = Chars) ->
    case all_digits(Chars) of
        true -> {ok, list_to_integer(Chars), $0};
        false -> integer_format_width(Rest)
    end;
integer_format_width(Chars) ->
    case all_digits(Chars) of
        true -> {ok, list_to_integer(Chars), $\s};
        false -> unsupported
    end.

integer_format_digits(Value, $x) ->
    string:lowercase(integer_to_list(Value, 16));
integer_format_digits(Value, $X) ->
    string:uppercase(integer_to_list(Value, 16));
integer_format_digits(Value, _Type) ->
    integer_to_list(Value).

all_digits([]) ->
    true;
all_digits(Chars) ->
    lists:all(fun(Char) -> Char >= $0 andalso Char =< $9 end, Chars).

pad_left(Text, Width, PadChar) ->
    Padding = Width - length(Text),
    case Padding > 0 of
        true -> lists:duplicate(Padding, PadChar) ++ Text;
        false -> Text
    end.

binary_to_integer_or_error(Binary) ->
    try
        {ok, binary_to_integer(Binary)}
    catch
        error:_ -> error
    end.

mapping_to_map({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> maps:from_list(pyrlang_heap:dict_items(Ref));
        _ -> #{}
    end;
mapping_to_map({py_module_dict, ModuleRef}) ->
    pyrlang_module:env(ModuleRef);
mapping_to_map(Map) when is_map(Map) ->
    Map;
mapping_to_map(_Other) ->
    #{}.

module_dict_update_items([]) ->
    [];
module_dict_update_items([Other]) ->
    module_dict_items(Other);
module_dict_update_items(Args) ->
    erlang:error({arity_error, {module_dict_update, length(Args)}}).

module_dict_items({py_module_dict, ModuleRef}) ->
    maps:to_list(pyrlang_module:env(ModuleRef));
module_dict_items({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> pyrlang_heap:dict_items(Ref);
        _Type -> [module_dict_update_pair(Item) || Item <- iter_values(Ref)]
    end;
module_dict_items(Map) when is_map(Map) ->
    maps:to_list(Map);
module_dict_items(Iterable) ->
    [module_dict_update_pair(Item) || Item <- iter_values(Iterable)].

module_dict_pop(ModuleRef, Key) ->
    Data = pyrlang_heap:data(ModuleRef),
    Env = maps:get(env, Data),
    case maps:take(Key, Env) of
        {Value, Env1} ->
            ok = pyrlang_heap:set_data(ModuleRef, Data#{env := Env1}),
            Value;
        error ->
            raise_builtin(<<"KeyError">>, Key)
    end.

module_dict_pop(ModuleRef, Key, Default) ->
    Data = pyrlang_heap:data(ModuleRef),
    Env = maps:get(env, Data),
    case maps:take(Key, Env) of
        {Value, Env1} ->
            ok = pyrlang_heap:set_data(ModuleRef, Data#{env := Env1}),
            Value;
        error ->
            Default
    end.

module_dict_update_pair({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list ->
            case pyrlang_heap:list_items(Ref) of
                [Key, Value] -> {Key, Value};
                Items -> erlang:error({type_error, {bad_dict_pair, Items}})
            end;
        _Type ->
            erlang:error({type_error, {bad_dict_pair, Ref}})
    end;
module_dict_update_pair({Key, Value}) ->
    {Key, Value};
module_dict_update_pair([Key, Value]) ->
    {Key, Value};
module_dict_update_pair(Other) when is_tuple(Other), tuple_size(Other) =:= 2 ->
    {element(1, Other), element(2, Other)};
module_dict_update_pair(Other) ->
    erlang:error({type_error, {bad_dict_pair, Other}}).

join_binary([], _Sep) ->
    <<>>;
join_binary([Part], _Sep) ->
    Part;
join_binary([Part | Rest], Sep) ->
    lists:foldl(fun(Next, Acc) -> <<Acc/binary, Sep/binary, Next/binary>> end, Part, Rest).

get_subscript_or_raise(Object, Index) ->
    try
        get_subscript(Object, Index)
    catch
        error:{badkey, Key} ->
            trace_key_miss(Object, Key),
            raise_builtin(<<"KeyError">>, Key);
        error:{index_error, BadIndex} ->
            raise_builtin(<<"IndexError">>, BadIndex);
        error:{type_error, Reason} ->
            raise_builtin(<<"TypeError">>, Reason)
    end.

trace_key_miss(Object, Key) ->
    case os:getenv("PYRLANG_TRACE_KEYERROR") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_KEY_MISS object=~s key=~p keys=~p stack=~p~n",
                [
                    describe_attr_object(Object),
                    Key,
                    trace_mapping_keys(Object),
                    trace_function_stack()
                ]
            )
    end.

trace_mapping_keys({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        dict -> [Key || {Key, _Value} <- pyrlang_heap:dict_items(Ref)];
        _ -> undefined
    catch
        _:_ -> undefined
    end;
trace_mapping_keys(Map) when is_map(Map) ->
    maps:keys(Map);
trace_mapping_keys(_Object) ->
    undefined.

trace_function_stack() ->
    case erlang:get(?FUNCTION_CALL_STACK_KEY) of
        Stack when is_list(Stack) ->
            [trace_function_label(Function) || Function <- lists:sublist(Stack, 8)];
        _ ->
            []
    end.

current_exception_info() ->
    case current_exception() of
        {ok, Exception} ->
            {exception_info_type(Exception), Exception, none};
        error ->
            {none, none, none}
    end.

current_exception() ->
    case erlang:get(?CURRENT_EXCEPTION_KEY) of
        undefined ->
            current_exception_from_env_stack();
        Exception ->
            {ok, Exception}
    end.

current_exception_from_env_stack() ->
    case erlang:get(?FUNCTION_ENV_STACK_KEY) of
        [Env | _Rest] when is_map(Env) ->
            maps:find(?CURRENT_EXCEPTION_KEY, Env);
        _Other ->
            error
    end.

raise_current_exception(Env) ->
    case maps:find(?CURRENT_EXCEPTION_KEY, Env) of
        {ok, Exception} ->
            pyrlang_exception:raise(Exception);
        error ->
            case current_exception() of
                {ok, Exception} ->
                    pyrlang_exception:raise(Exception);
                error ->
                    pyrlang_exception:raise(
                        pyrlang_exception:make(
                            pyrlang_exception:type(<<"RuntimeError">>),
                            <<"No active exception to reraise">>
                        )
                    )
            end
    end.

exception_info_type({py_ref, _} = Exception) ->
    pyrlang_builtins:object_class(Exception);
exception_info_type(Exception) ->
    pyrlang_exception:type(pyrlang_exception:exception_type(Exception)).

trace_function_label(Function) ->
    Module = trace_function_attr(Function, <<"__module__">>),
    QualName = trace_function_attr(Function, <<"__qualname__">>),
    <<Module/binary, ".", QualName/binary>>.

set_subscript_or_raise(Object, Index, Value) ->
    try
        set_subscript(Object, Index, Value)
    catch
        error:{index_error, BadIndex} ->
            raise_builtin(<<"IndexError">>, BadIndex);
        error:{type_error, Reason} ->
            raise_builtin(<<"TypeError">>, Reason)
    end.

raise_builtin(Type, Message) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(Type), Message)).

dict_ref_has_class(Ref) ->
    case pyrlang_heap:data(Ref) of
        #{class := _Class} -> true;
        _ -> false
    end.

get_subscript({py_ref, _} = Ref, Index) ->
    case pyrlang_heap:type(Ref) of
        class ->
            get_class_subscript(Ref, Index);
        list ->
            case slice_object_parts(Index) of
                {ok, {Start, Stop, none}} ->
                    pyrlang_heap:list(slice_values(pyrlang_heap:list_items(Ref), Start, Stop));
                {ok, {Start, Stop, Step}} ->
                    pyrlang_heap:list(
                        slice_values(pyrlang_heap:list_items(Ref), Start, Stop, Step)
                    );
                error ->
                    pyrlang_heap:list_get(Ref, list_index(Index))
            end;
        dict ->
            case dict_ref_has_class(Ref) of
                true -> call_value(pyrlang_object:get_attr(Ref, <<"__getitem__">>), [Index]);
                false -> pyrlang_heap:dict_get(Ref, Index)
            end;
        instance ->
            case tuple_subclass_items(Ref) of
                {ok, Items} when is_integer(Index) ->
                    lists:nth(normalize_index(Index, length(Items)) + 1, Items);
                _ ->
                    case string_subclass_value(Ref) of
                        {ok, Value} when is_integer(Index) ->
                            get_subscript(Value, Index);
                        _ ->
                            get_instance_subscript(Ref, Index)
                    end
            end;
        Type ->
            erlang:error({type_error, {not_subscriptable, Type}})
    end;
get_subscript({py_instance_dict, Instance}, Key) ->
    Data = pyrlang_heap:data(Instance),
    maps:get(Key, maps:get(attrs, Data));
get_subscript({py_module_dict, ModuleRef}, Key) ->
    maps:get(Key, pyrlang_module:env(ModuleRef));
get_subscript(Binary, Index) when is_binary(Binary) ->
    case slice_object_parts(Index) of
        {ok, {Start, Stop, none}} ->
            get_slice(Binary, Start, Stop);
        {ok, {Start, Stop, Step}} ->
            get_slice(Binary, Start, Stop, Step);
        error ->
            Units = binary_slice_units(Binary),
            lists:nth(normalize_index(list_index(Index), length(Units)) + 1, Units)
    end;
get_subscript(Tuple, Index) when is_tuple(Tuple) ->
    case slice_object_parts(Index) of
        {ok, {Start, Stop, none}} -> get_slice(Tuple, Start, Stop);
        {ok, {Start, Stop, Step}} -> get_slice(Tuple, Start, Stop, Step);
        error -> element(normalize_index(list_index(Index), tuple_size(Tuple)) + 1, Tuple)
    end;
get_subscript(Other, _Index) ->
    erlang:error({type_error, {not_subscriptable, Other}}).

slice_object_parts({py_ref, _} = Ref) ->
    try pyrlang_builtins:object_class(Ref) of
        Class ->
            case
                pyrlang_heap:type(Class) =:= class andalso
                    pyrlang_object:class_name(Class) =:= <<"slice">>
            of
                true ->
                    {ok, {
                        pyrlang_object:get_attr(Ref, <<"start">>),
                        pyrlang_object:get_attr(Ref, <<"stop">>),
                        pyrlang_object:get_attr(Ref, <<"step">>)
                    }};
                false ->
                    error
            end
    catch
        _:_ -> error
    end;
slice_object_parts(_Index) ->
    error.

get_instance_subscript(Ref, Index) ->
    case maybe_typing_alias_subscript(Ref, Index) of
        {ok, Alias} ->
            Alias;
        error ->
            try pyrlang_object:get_attr(Ref, <<"__getitem__">>) of
                GetItem -> call_value(GetItem, [Index])
            catch
                error:{attribute_error, _Name} ->
                    erlang:error({type_error, {not_subscriptable, Ref}});
                throw:{py_exception, Exception} ->
                    case pyrlang_exception:exception_type(Exception) of
                        <<"AttributeError">> ->
                            erlang:error({type_error, {not_subscriptable, Ref}});
                        _ ->
                            pyrlang_exception:raise(Exception)
                    end
            end
    end.

maybe_typing_alias_subscript(Ref, Index) ->
    try
        _Name = pyrlang_object:get_attr(Ref, <<"_name">>),
        Origin = pyrlang_object:get_attr(Ref, <<"__origin__">>),
        {ok, pyrlang_builtins:generic_alias(Origin, Index)}
    catch
        _:_ -> error
    end.

get_class_subscript(Class, Index) ->
    try pyrlang_object:get_attr(Class, <<"__class_getitem__">>) of
        Callable -> call_value(Callable, [Index])
    catch
        error:{attribute_error, _Name} ->
            pyrlang_builtins:generic_alias(Class, Index);
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> -> pyrlang_builtins:generic_alias(Class, Index);
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

eval_optional_slice(undefined, Env) ->
    {undefined, Env};
eval_optional_slice(Expr, Env0) ->
    eval_expr(Expr, Env0).

get_slice({py_ref, _} = Ref, Start, Stop) ->
    case pyrlang_heap:type(Ref) of
        list ->
            pyrlang_heap:list(slice_values(pyrlang_heap:list_items(Ref), Start, Stop));
        instance ->
            case tuple_subclass_items(Ref) of
                {ok, Items} ->
                    list_to_tuple(slice_values(Items, Start, Stop));
                error ->
                    case string_subclass_value(Ref) of
                        {ok, Value} ->
                            get_slice(Value, Start, Stop);
                        error ->
                            case call_slice_getitem(Ref, Start, Stop, none) of
                                {ok, Value} ->
                                    Value;
                                error ->
                                    trace_slice_error(Ref, Start, Stop),
                                    erlang:error({type_error, {not_sliceable, instance}})
                            end
                    end
            end;
        Type ->
            erlang:error({type_error, {not_sliceable, Type}})
    end;
get_slice(Binary, Start, Stop) when is_binary(Binary) ->
    iolist_to_binary(slice_values(binary_slice_units(Binary), Start, Stop));
get_slice(Tuple, Start, Stop) when is_tuple(Tuple) ->
    list_to_tuple(slice_values(tuple_to_list(Tuple), Start, Stop));
get_slice(Other, _Start, _Stop) ->
    erlang:error({type_error, {not_sliceable, Other}}).

get_slice(Object, Start, Stop, undefined) ->
    get_slice(Object, Start, Stop);
get_slice({py_ref, _} = Ref, Start, Stop, Step) ->
    case pyrlang_heap:type(Ref) of
        list ->
            pyrlang_heap:list(slice_values(pyrlang_heap:list_items(Ref), Start, Stop, Step));
        instance ->
            case tuple_subclass_items(Ref) of
                {ok, Items} ->
                    list_to_tuple(slice_values(Items, Start, Stop, Step));
                error ->
                    case string_subclass_value(Ref) of
                        {ok, Value} ->
                            get_slice(Value, Start, Stop, Step);
                        error ->
                            case call_slice_getitem(Ref, Start, Stop, Step) of
                                {ok, Value} ->
                                    Value;
                                error ->
                                    trace_slice_error(Ref, Start, Stop),
                                    erlang:error({type_error, {not_sliceable, instance}})
                            end
                    end
            end;
        Type ->
            erlang:error({type_error, {not_sliceable, Type}})
    end;
get_slice(Binary, Start, Stop, Step) when is_binary(Binary) ->
    iolist_to_binary(slice_values(binary_slice_units(Binary), Start, Stop, Step));
get_slice(Tuple, Start, Stop, Step) when is_tuple(Tuple) ->
    list_to_tuple(slice_values(tuple_to_list(Tuple), Start, Stop, Step));
get_slice(Other, _Start, _Stop, _Step) ->
    erlang:error({type_error, {not_sliceable, Other}}).

trace_slice_error(Ref, Start, Stop) ->
    case os:getenv("PYRLANG_TRACE_SLICE_ERRORS") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_SLICE_ERROR ~s start=~p stop=~p stack=~p~n",
                [describe_attr_object(Ref), Start, Stop, trace_function_stack()]
            )
    end.

call_slice_getitem(Ref, Start, Stop, Step) ->
    try pyrlang_object:get_attr(Ref, <<"__getitem__">>) of
        Getitem ->
            {ok, SliceClass} = pyrlang_builtins:lookup(<<"slice">>),
            Slice = call_value(SliceClass, [
                slice_bound(Start), slice_bound(Stop), slice_bound(Step)
            ]),
            {ok, call_value(Getitem, [Slice])}
    catch
        error:{attribute_error, _Name} -> error
    end.

slice_bound(undefined) -> none;
slice_bound(Value) -> Value.

slice_values(Values, Start0, Stop0) ->
    Length = length(Values),
    Start = normalize_slice_start(Start0, Length),
    Stop = normalize_slice_stop(Stop0, Length),
    Count = max(0, Stop - Start),
    lists:sublist(lists:nthtail(Start, Values), Count).

slice_values(Values, Start0, Stop0, Step0) ->
    Length = length(Values),
    Step = normalize_slice_step(Step0),
    Start = normalize_slice_start(Start0, Length, Step),
    Stop = normalize_slice_stop(Stop0, Length, Step),
    slice_values_step(Values, Start, Stop, Step, []).

slice_values_step(Values, Index, Stop, Step, Acc) when Step > 0, Index < Stop ->
    slice_values_step(Values, Index + Step, Stop, Step, [lists:nth(Index + 1, Values) | Acc]);
slice_values_step(Values, Index, Stop, Step, Acc) when Step < 0, Index > Stop ->
    slice_values_step(Values, Index + Step, Stop, Step, [lists:nth(Index + 1, Values) | Acc]);
slice_values_step(_Values, _Index, _Stop, _Step, Acc) ->
    lists:reverse(Acc).

binary_slice_units(Binary) ->
    case unicode:characters_to_list(Binary, utf8) of
        Chars when is_list(Chars) ->
            [<<Char/utf8>> || Char <- Chars];
        _InvalidUtf8 ->
            [<<Byte>> || <<Byte:8>> <= Binary]
    end.

normalize_slice_start(undefined, _Length) ->
    0;
normalize_slice_start(none, _Length) ->
    0;
normalize_slice_start(Index, Length) when is_integer(Index) ->
    clamp_slice_index(Index, Length).

normalize_slice_stop(undefined, Length) ->
    Length;
normalize_slice_stop(none, Length) ->
    Length;
normalize_slice_stop(Index, Length) when is_integer(Index) ->
    clamp_slice_index(Index, Length).

normalize_slice_step(true) ->
    1;
normalize_slice_step(false) ->
    raise_builtin(<<"ValueError">>, <<"slice step cannot be zero">>);
normalize_slice_step(0) ->
    raise_builtin(<<"ValueError">>, <<"slice step cannot be zero">>);
normalize_slice_step(Step) when is_integer(Step) ->
    Step.

normalize_slice_start(undefined, Length, Step) when Step < 0 ->
    Length - 1;
normalize_slice_start(undefined, _Length, _Step) ->
    0;
normalize_slice_start(none, Length, Step) ->
    normalize_slice_start(undefined, Length, Step);
normalize_slice_start(Index, Length, Step) when is_integer(Index), Step < 0 ->
    clamp_negative_step_slice_index(Index, Length);
normalize_slice_start(Index, Length, _Step) when is_integer(Index) ->
    clamp_slice_index(Index, Length).

normalize_slice_stop(undefined, _Length, Step) when Step < 0 ->
    -1;
normalize_slice_stop(undefined, Length, _Step) ->
    Length;
normalize_slice_stop(none, Length, Step) ->
    normalize_slice_stop(undefined, Length, Step);
normalize_slice_stop(Index, Length, Step) when is_integer(Index), Step < 0 ->
    clamp_negative_step_slice_index(Index, Length);
normalize_slice_stop(Index, Length, _Step) when is_integer(Index) ->
    clamp_slice_index(Index, Length).

clamp_slice_index(Index, Length) when Index < 0 ->
    max(0, min(Length, Length + Index));
clamp_slice_index(Index, Length) ->
    max(0, min(Length, Index)).

clamp_negative_step_slice_index(Index, Length) when Index < 0 ->
    max(-1, min(Length - 1, Length + Index));
clamp_negative_step_slice_index(Index, Length) ->
    max(-1, min(Length - 1, Index)).

set_subscript({py_ref, _} = Ref, Index, Value) ->
    case pyrlang_heap:type(Ref) of
        list ->
            pyrlang_heap:list_set(Ref, list_index(Index), Value);
        dict ->
            case dict_ref_has_class(Ref) of
                true ->
                    _ = call_value(pyrlang_object:get_attr(Ref, <<"__setitem__">>), [Index, Value]),
                    ok;
                false ->
                    pyrlang_heap:dict_put(Ref, Index, Value)
            end;
        instance ->
            Setter =
                try
                    pyrlang_object:get_attr(Ref, <<"__setitem__">>)
                catch
                    error:{attribute_error, <<"__setitem__">>} ->
                        trace_subscript_set_missing(Ref, Index),
                        erlang:error({attribute_error, <<"__setitem__">>})
                end,
            _ = call_value(Setter, [Index, Value]),
            ok;
        Type ->
            erlang:error({type_error, {not_subscriptable, Type}})
    end;
set_subscript({py_instance_dict, Instance}, Key, Value) ->
    Data = pyrlang_heap:data(Instance),
    Attrs = maps:get(attrs, Data),
    pyrlang_heap:set_data(Instance, Data#{attrs := maps:put(Key, Value, Attrs)});
set_subscript({py_module_dict, ModuleRef}, Key, Value) ->
    pyrlang_module:set_attr(ModuleRef, Key, Value).

trace_subscript_set_missing(Ref, Index) ->
    case os:getenv("PYRLANG_TRACE_SUBSCRIPT") of
        false ->
            ok;
        _ ->
            ClassName =
                try
                    pyrlang_object:class_name(pyrlang_object:class(Ref))
                catch
                    _:_ -> <<"?">>
                end,
            Attrs =
                try
                    maps:keys(maps:get(attrs, pyrlang_heap:data(Ref), #{}))
                catch
                    _:_ -> []
                end,
            io:format(
                standard_error,
                "PYRLANG_SUBSCRIPT_SET_MISSING class=~p index=~p attrs=~p stack=~p~n",
                [ClassName, Index, Attrs, trace_function_stack()]
            )
    end.

set_slice_or_raise(Object, Start, Stop, Value) ->
    try
        set_slice(Object, Start, Stop, Value)
    catch
        error:{type_error, Reason} ->
            raise_builtin(<<"TypeError">>, Reason)
    end.

set_slice({py_ref, _} = Ref, Start0, Stop0, Value) ->
    case pyrlang_heap:type(Ref) of
        list ->
            Items = pyrlang_heap:list_items(Ref),
            Length = length(Items),
            Start = normalize_slice_start(Start0, Length),
            Stop = normalize_slice_stop(Stop0, Length),
            Count = max(0, Stop - Start),
            {Prefix, Rest} = lists:split(Start, Items),
            {_Removed, Suffix} = lists:split(Count, Rest),
            pyrlang_heap:set_data(Ref, Prefix ++ pyrlang_iter:values(Value) ++ Suffix);
        instance ->
            call_value(pyrlang_object:get_attr(Ref, <<"__setitem__">>), [
                {slice, Start0, Stop0}, Value
            ]),
            ok;
        Type ->
            erlang:error({type_error, {not_slice_assignable, Type}})
    end;
set_slice(Other, _Start, _Stop, _Value) ->
    erlang:error({type_error, {not_slice_assignable, Other}}).

del_subscript({py_ref, _} = Ref, Index) ->
    case pyrlang_heap:type(Ref) of
        list when is_integer(Index) ->
            Items = pyrlang_heap:list_items(Ref),
            ZeroIndex = normalize_index(Index, length(Items)),
            {Prefix, [_Removed | Suffix]} = lists:split(ZeroIndex, Items),
            pyrlang_heap:set_data(Ref, Prefix ++ Suffix);
        dict ->
            case dict_ref_has_class(Ref) of
                true -> call_value(pyrlang_object:get_attr(Ref, <<"__delitem__">>), [Index]);
                false -> pyrlang_heap:dict_del(Ref, Index)
            end;
        instance ->
            call_value(pyrlang_object:get_attr(Ref, <<"__delitem__">>), [Index]);
        Type ->
            erlang:error({type_error, {not_subscriptable, Type}})
    end;
del_subscript({py_instance_dict, Instance}, Key) ->
    Data = pyrlang_heap:data(Instance),
    Attrs = maps:get(attrs, Data),
    pyrlang_heap:set_data(Instance, Data#{attrs := maps:remove(Key, Attrs)});
del_subscript({py_module_dict, ModuleRef}, Key) ->
    Data = pyrlang_heap:data(ModuleRef),
    Env = maps:get(env, Data),
    pyrlang_heap:set_data(ModuleRef, Data#{env := maps:remove(Key, Env)}).

del_slice({py_ref, _} = Ref, Start0, Stop0) ->
    case pyrlang_heap:type(Ref) of
        list ->
            Items = pyrlang_heap:list_items(Ref),
            Length = length(Items),
            Start = normalize_slice_start(Start0, Length),
            Stop = normalize_slice_stop(Stop0, Length),
            Count = max(0, Stop - Start),
            {Prefix, Rest} = lists:split(Start, Items),
            {_Removed, Suffix} = lists:split(Count, Rest),
            pyrlang_heap:set_data(Ref, Prefix ++ Suffix);
        instance ->
            call_value(pyrlang_object:get_attr(Ref, <<"__delitem__">>), [{slice, Start0, Stop0}]),
            ok;
        Type ->
            erlang:error({type_error, {not_slice_deletable, Type}})
    end;
del_slice(Other, _Start, _Stop) ->
    erlang:error({type_error, {not_slice_deletable, Other}}).

apply_decorators(Decorators, Value, Env0) ->
    lists:foldr(
        fun(DecoratorExpr, {Current, Env}) ->
            {Decorator, Env1} = eval_expr(DecoratorExpr, Env),
            {call_value(Decorator, [Current]), Env1}
        end,
        {Value, Env0},
        Decorators
    ).

eval_binop(plus, Left, Right) when is_integer(Left), is_integer(Right) ->
    Left + Right;
eval_binop(plus, Left, Right) when is_number(Left), is_number(Right) ->
    Left + Right;
eval_binop(plus, Left, Right) when is_boolean(Left); is_boolean(Right) ->
    numeric_value(Left) + numeric_value(Right);
eval_binop(plus, Left, Right) when is_binary(Left), is_binary(Right) ->
    <<Left/binary, Right/binary>>;
eval_binop(plus, {py_ref, _} = Left, {py_ref, _} = Right) ->
    case {pyrlang_heap:type(Left), pyrlang_heap:type(Right)} of
        {list, list} ->
            pyrlang_heap:list(pyrlang_heap:list_items(Left) ++ pyrlang_heap:list_items(Right));
        _ ->
            case numeric_binop_or_error(plus, Left, Right) of
                {ok, Value} ->
                    Value;
                error ->
                    case {tuple_subclass_items(Left), tuple_subclass_items(Right)} of
                        {{ok, LeftItems}, {ok, RightItems}} ->
                            list_to_tuple(LeftItems ++ RightItems);
                        _ ->
                            case {string_subclass_value(Left), string_subclass_value(Right)} of
                                {{ok, LeftValue}, {ok, RightValue}} ->
                                    <<LeftValue/binary, RightValue/binary>>;
                                _ ->
                                    eval_binop_special(plus, Left, Right)
                            end
                    end
            end
    end;
eval_binop(plus, {py_ref, _} = Left, Right) when is_binary(Right) ->
    case string_subclass_value(Left) of
        {ok, LeftValue} -> <<LeftValue/binary, Right/binary>>;
        error -> eval_binop_special(plus, Left, Right)
    end;
eval_binop(plus, Left, {py_ref, _} = Right) when is_binary(Left) ->
    case string_subclass_value(Right) of
        {ok, RightValue} -> <<Left/binary, RightValue/binary>>;
        error -> eval_binop_special(plus, Left, Right)
    end;
eval_binop(plus, {py_ref, _} = Left, Right) when is_tuple(Right) ->
    case tuple_subclass_items(Left) of
        {ok, LeftItems} -> list_to_tuple(LeftItems ++ tuple_to_list(Right));
        error -> eval_binop_special(plus, Left, Right)
    end;
eval_binop(plus, Left, {py_ref, _} = Right) when is_tuple(Left) ->
    case tuple_subclass_items(Right) of
        {ok, RightItems} -> list_to_tuple(tuple_to_list(Left) ++ RightItems);
        error -> eval_binop_special(plus, Left, Right)
    end;
eval_binop(plus, Left, Right) when is_tuple(Left), is_tuple(Right) ->
    list_to_tuple(tuple_to_list(Left) ++ tuple_to_list(Right));
eval_binop(minus, Left, Right) when is_integer(Left), is_integer(Right) ->
    Left - Right;
eval_binop(minus, Left, Right) when is_number(Left), is_number(Right) ->
    Left - Right;
eval_binop(minus, Left, Right) when is_boolean(Left); is_boolean(Right) ->
    numeric_value(Left) - numeric_value(Right);
eval_binop(minus, {py_ref, _} = Left, Right) ->
    case pyrlang_heap:type(Left) of
        set ->
            RightKeys = keyed_values(iter_values(Right)),
            pyrlang_heap:set([
                Item
             || Item <- pyrlang_heap:set_items(Left),
                not maps:is_key(pyrlang_heap:value_key(Item), RightKeys)
            ]);
        _ ->
            eval_numeric_binop_or_special(minus, Left, Right)
    end;
eval_binop(star, Left, Right) when is_integer(Left), is_integer(Right) ->
    Left * Right;
eval_binop(star, Left, Right) when is_number(Left), is_number(Right) ->
    Left * Right;
eval_binop(star, Left, Right) when is_binary(Left), (is_integer(Right) orelse is_boolean(Right)) ->
    binary:copy(Left, repeat_count(numeric_value(Right)));
eval_binop(star, Left, Right) when (is_integer(Left) orelse is_boolean(Left)), is_binary(Right) ->
    binary:copy(Right, repeat_count(numeric_value(Left)));
eval_binop(star, {py_ref, _} = Left, Right) when is_integer(Right) orelse is_boolean(Right) ->
    case repeat_ref_sequence(Left, numeric_value(Right)) of
        {ok, Value} -> Value;
        error -> eval_numeric_binop_or_special(star, Left, Right)
    end;
eval_binop(star, Left, {py_ref, _} = Right) when is_integer(Left) orelse is_boolean(Left) ->
    case repeat_ref_sequence(Right, numeric_value(Left)) of
        {ok, Value} -> Value;
        error -> eval_numeric_binop_or_special(star, Left, Right)
    end;
eval_binop(star, Left, Right) when is_tuple(Left), (is_integer(Right) orelse is_boolean(Right)) ->
    list_to_tuple(repeat_list(tuple_to_list(Left), numeric_value(Right)));
eval_binop(star, Left, Right) when (is_integer(Left) orelse is_boolean(Left)), is_tuple(Right) ->
    list_to_tuple(repeat_list(tuple_to_list(Right), numeric_value(Left)));
eval_binop(star, Left, Right) when is_boolean(Left); is_boolean(Right) ->
    numeric_value(Left) * numeric_value(Right);
eval_binop(pow, Left, Right) when is_integer(Left), is_integer(Right), Right >= 0 ->
    integer_pow(Left, Right);
eval_binop(pow, Left, Right) when is_number(Left), is_number(Right) ->
    math:pow(Left, Right);
eval_binop(pow, Left, Right) when
    (is_boolean(Left) orelse is_number(Left)), (is_boolean(Right) orelse is_number(Right))
->
    math:pow(numeric_value(Left), numeric_value(Right));
eval_binop(slash, Left, Right) when is_integer(Left), is_integer(Right), Right =/= 0 ->
    Left / Right;
eval_binop(slash, Left, Right) when is_number(Left), is_number(Right), Right /= 0 ->
    Left / Right;
eval_binop(floor_div, Left, Right) when is_number(Left), is_number(Right), Right /= 0 ->
    floor(Left / Right);
eval_binop(percent, Left, Right) when is_number(Left), is_number(Right), Right /= 0 ->
    python_modulo(Left, Right);
eval_binop(percent, Format, Args) when is_binary(Format) ->
    format_percent(Format, Args);
eval_binop(lshift, Left, Right) when is_integer(Left), is_integer(Right), Right >= 0 ->
    Left bsl Right;
eval_binop(rshift, Left, Right) when is_integer(Left), is_integer(Right), Right >= 0 ->
    Left bsr Right;
eval_binop(pipe, Left, Right) when is_integer(Left), is_integer(Right) ->
    Left bor Right;
eval_binop(amp, Left, Right) when is_integer(Left), is_integer(Right) ->
    Left band Right;
eval_binop(amp, {py_ref, _} = Left, Right) ->
    case pyrlang_heap:type(Left) of
        set ->
            RightKeys = keyed_values(iter_values(Right)),
            pyrlang_heap:set([
                Item
             || Item <- pyrlang_heap:set_items(Left),
                maps:is_key(pyrlang_heap:value_key(Item), RightKeys)
            ]);
        _ ->
            eval_numeric_binop_or_special(amp, Left, Right)
    end;
eval_binop(caret, Left, Right) when is_integer(Left), is_integer(Right) ->
    Left bxor Right;
eval_binop(pipe, {py_ref, _} = Left, Right) ->
    case pyrlang_heap:type(Left) of
        set ->
            pyrlang_heap:set(pyrlang_heap:set_items(Left) ++ iter_values(Right));
        dict ->
            pyrlang_heap:dict(pyrlang_heap:dict_items(Left) ++ kwargs_items(Right));
        _ ->
            case numeric_binop_or_error(pipe, Left, Right) of
                {ok, Value} -> Value;
                error -> eval_type_union_or_special(Left, Right)
            end
    end;
eval_binop(pipe, Left, Right) ->
    case numeric_binop_or_error(pipe, Left, Right) of
        {ok, Value} -> Value;
        error -> eval_type_union_or_special(Left, Right)
    end;
eval_binop(Op, Left, Right) ->
    eval_numeric_binop_or_special(Op, Left, Right).

eval_aug_assign_value(plus, {py_ref, _} = Current, Right) ->
    case pyrlang_heap:type(Current) of
        list ->
            lists:foreach(
                fun(Value) -> ok = pyrlang_heap:list_append(Current, Value) end,
                pyrlang_iter:values(Right)
            ),
            Current;
        _ ->
            eval_binop_or_raise(plus, Current, Right)
    end;
eval_aug_assign_value(Op, Current, Right) ->
    eval_binop_or_raise(Op, Current, Right).

eval_type_union_or_special(Left, Right) ->
    case pyrlang_builtins:type_union(Left, Right) of
        {ok, Union} -> Union;
        error -> eval_binop_special(pipe, Left, Right)
    end.

eval_numeric_binop_or_special(Op, Left, Right) ->
    case numeric_binop_or_error(Op, Left, Right) of
        {ok, Value} -> Value;
        error -> eval_binop_special(Op, Left, Right)
    end.

numeric_binop_or_error(Op, Left, Right) ->
    case {numeric_operand(Left), numeric_operand(Right)} of
        {{ok, LeftValue}, {ok, RightValue}} -> numeric_binop(Op, LeftValue, RightValue);
        _ -> error
    end.

numeric_binop(plus, Left, Right) ->
    {ok, Left + Right};
numeric_binop(minus, Left, Right) ->
    {ok, Left - Right};
numeric_binop(star, Left, Right) ->
    {ok, Left * Right};
numeric_binop(pow, Left, Right) when is_integer(Left), is_integer(Right), Right >= 0 ->
    {ok, integer_pow(Left, Right)};
numeric_binop(pow, Left, Right) ->
    {ok, math:pow(Left, Right)};
numeric_binop(slash, _Left, 0) ->
    raise_builtin(<<"ZeroDivisionError">>, <<"division by zero">>);
numeric_binop(slash, Left, Right) ->
    {ok, Left / Right};
numeric_binop(floor_div, _Left, 0) ->
    raise_builtin(<<"ZeroDivisionError">>, <<"integer division or modulo by zero">>);
numeric_binop(floor_div, Left, Right) ->
    {ok, floor(Left / Right)};
numeric_binop(percent, _Left, Right) when Right == 0 ->
    raise_builtin(<<"ZeroDivisionError">>, <<"integer modulo by zero">>);
numeric_binop(percent, Left, Right) when is_number(Left), is_number(Right) ->
    {ok, python_modulo(Left, Right)};
numeric_binop(lshift, Left, Right) when is_integer(Left), is_integer(Right), Right >= 0 ->
    {ok, Left bsl Right};
numeric_binop(rshift, Left, Right) when is_integer(Left), is_integer(Right), Right >= 0 ->
    {ok, Left bsr Right};
numeric_binop(pipe, Left, Right) when is_integer(Left), is_integer(Right) ->
    {ok, Left bor Right};
numeric_binop(amp, Left, Right) when is_integer(Left), is_integer(Right) ->
    {ok, Left band Right};
numeric_binop(caret, Left, Right) when is_integer(Left), is_integer(Right) ->
    {ok, Left bxor Right};
numeric_binop(_Op, _Left, _Right) ->
    error.

python_modulo(Left, Right) ->
    normalize_numeric_result(Left - Right * floor(Left / Right)).

normalize_numeric_result(Value) when is_float(Value) ->
    case Value =:= trunc(Value) of
        true -> trunc(Value);
        false -> Value
    end;
normalize_numeric_result(Value) ->
    Value.

numeric_operand(true) ->
    {ok, 1};
numeric_operand(false) ->
    {ok, 0};
numeric_operand(Value) when is_integer(Value); is_float(Value) ->
    {ok, Value};
numeric_operand({py_ref, _} = Ref) ->
    pyrlang_builtins:int_subclass_value(Ref);
numeric_operand(_Value) ->
    error.

repeat_ref_sequence(Ref, Count) ->
    case pyrlang_heap:type(Ref) of
        list ->
            {ok, pyrlang_heap:list(repeat_list(pyrlang_heap:list_items(Ref), Count))};
        instance ->
            case string_subclass_value(Ref) of
                {ok, Value} -> {ok, binary:copy(Value, repeat_count(Count))};
                error -> error
            end;
        _Type ->
            error
    end.

repeat_list(Items, Count0) ->
    Count = repeat_count(Count0),
    lists:append(lists:duplicate(Count, Items)).

repeat_count(Count) when Count < 0 ->
    0;
repeat_count(Count) ->
    Count.

eval_binop_special(Op, Left, Right) ->
    case call_special(Left, binop_method(Op), [Right]) of
        {ok, Value} ->
            Value;
        error ->
            case call_special(Right, reflected_binop_method(Op), [Left]) of
                {ok, Value} -> Value;
                error -> erlang:error({unsupported_binop, Op, Left, Right})
            end
    end.

eval_binop_or_raise(slash, _Left, Right) when Right == 0 ->
    raise_builtin(<<"ZeroDivisionError">>, <<"division by zero">>);
eval_binop_or_raise(floor_div, _Left, Right) when Right == 0 ->
    raise_builtin(<<"ZeroDivisionError">>, <<"integer division or modulo by zero">>);
eval_binop_or_raise(percent, Left, Right) when not is_binary(Left), Right == 0 ->
    raise_builtin(<<"ZeroDivisionError">>, <<"integer modulo by zero">>);
eval_binop_or_raise(Op, Left, Right) ->
    try
        eval_binop(Op, Left, Right)
    catch
        error:{unsupported_binop, _Op, _Left, _Right} ->
            raise_builtin(<<"TypeError">>, {unsupported_binop, Op, Left, Right})
    end.

eval_compare(eq, Left, Right) ->
    special_compare(Left, <<"__eq__">>, Right, default_eq(Left, Right));
eval_compare(ne, Left, Right) ->
    case call_special(Left, <<"__ne__">>, [Right]) of
        {ok, Value} -> Value;
        error -> not eval_compare(eq, Left, Right)
    end;
eval_compare(lt, Left, Right) ->
    special_compare(Left, <<"__lt__">>, Right, default_compare(lt, Left, Right));
eval_compare(lte, Left, Right) ->
    special_compare(Left, <<"__le__">>, Right, default_compare(lte, Left, Right));
eval_compare(gt, Left, Right) ->
    special_compare(Left, <<"__gt__">>, Right, default_compare(gt, Left, Right));
eval_compare(gte, Left, Right) ->
    special_compare(Left, <<"__ge__">>, Right, default_compare(gte, Left, Right));
eval_compare(is, Left, Right) ->
    pyrlang_heap:value_key(Left) =:= pyrlang_heap:value_key(Right);
eval_compare(is_not, Left, Right) ->
    pyrlang_heap:value_key(Left) =/= pyrlang_heap:value_key(Right);
eval_compare(in, Left, Right) when is_binary(Right) ->
    case binary:match(Right, py_string(Left)) of
        nomatch -> false;
        _ -> true
    end;
eval_compare(in, Left, Right) ->
    case call_special(Right, <<"__contains__">>, [Left]) of
        {ok, Value} -> truthy(Value);
        error -> value_member(Left, iter_values(Right))
    end;
eval_compare(not_in, Left, Right) ->
    not eval_compare(in, Left, Right).

default_eq(Left, Right) when is_number(Left), is_number(Right) ->
    Left == Right;
default_eq({py_float_special, nan}, _Right) ->
    false;
default_eq(_Left, {py_float_special, nan}) ->
    false;
default_eq({py_float_special, Kind}, {py_float_special, Kind}) ->
    true;
default_eq({py_float_special, _LeftKind}, {py_float_special, _RightKind}) ->
    false;
default_eq({py_complex, LeftReal, LeftImag}, {py_complex, RightReal, RightImag}) ->
    LeftReal == RightReal andalso LeftImag == RightImag;
default_eq({py_complex, Real, Imag}, Right) when is_number(Right) ->
    Imag == 0 andalso Real == Right;
default_eq(Left, {py_complex, Real, Imag}) when is_number(Left) ->
    Imag == 0 andalso Left == Real;
default_eq({py_ref, _} = Left, {py_ref, _} = Right) ->
    case {pyrlang_heap:type(Left), pyrlang_heap:type(Right)} of
        {list, list} ->
            python_sequence_equal(pyrlang_heap:list_items(Left), pyrlang_heap:list_items(Right));
        {dict, dict} ->
            python_dict_equal(Left, Right);
        {set, set} ->
            python_set_equal(pyrlang_heap:set_items(Left), pyrlang_heap:set_items(Right));
        _ ->
            case {string_subclass_value(Left), string_subclass_value(Right)} of
                {{ok, LeftValue}, {ok, RightValue}} -> LeftValue =:= RightValue;
                _ -> Left =:= Right
            end
    end;
default_eq({py_ref, _} = Left, Right) when is_tuple(Right) ->
    case tuple_subclass_items(Left) of
        {ok, LeftItems} -> list_to_tuple(LeftItems) =:= Right;
        error -> Left =:= Right
    end;
default_eq(Left, {py_ref, _} = Right) when is_tuple(Left) ->
    case tuple_subclass_items(Right) of
        {ok, RightItems} -> Left =:= list_to_tuple(RightItems);
        error -> Left =:= Right
    end;
default_eq({py_ref, _} = Left, Right) when is_binary(Right) ->
    case string_subclass_value(Left) of
        {ok, LeftValue} -> LeftValue =:= Right;
        error -> Left =:= Right
    end;
default_eq(Left, {py_ref, _} = Right) when is_binary(Left) ->
    case string_subclass_value(Right) of
        {ok, RightValue} -> Left =:= RightValue;
        error -> Left =:= Right
    end;
default_eq(Left, Right) ->
    pyrlang_heap:value_key(Left) =:= pyrlang_heap:value_key(Right).

python_sequence_equal([], []) ->
    true;
python_sequence_equal([Left | LeftRest], [Right | RightRest]) ->
    truthy(eval_compare(eq, Left, Right)) andalso python_sequence_equal(LeftRest, RightRest);
python_sequence_equal(_Left, _Right) ->
    false.

python_dict_equal(Left, Right) ->
    LeftItems = pyrlang_heap:dict_items(Left),
    RightItems = pyrlang_heap:dict_items(Right),
    length(LeftItems) =:= length(RightItems) andalso
        lists:all(
            fun({Key, LeftValue}) ->
                case pyrlang_heap:dict_find(Right, Key) of
                    {ok, RightValue} -> truthy(eval_compare(eq, LeftValue, RightValue));
                    error -> false
                end
            end,
            LeftItems
        ).

python_set_equal(LeftItems, RightItems) ->
    RightKeys = keyed_values(RightItems),
    length(LeftItems) =:= length(RightItems) andalso
        lists:all(fun(Item) -> maps:is_key(pyrlang_heap:value_key(Item), RightKeys) end, LeftItems).

value_member(Value, Items) ->
    Key = pyrlang_heap:value_key(Value),
    lists:any(fun(Item) -> pyrlang_heap:value_key(Item) =:= Key end, Items).

keyed_values(Items) ->
    maps:from_list([{pyrlang_heap:value_key(Item), true} || Item <- Items]).

eval_compare_chain(_LeftValue, [], Env) ->
    {true, Env};
eval_compare_chain(LeftValue, [{Op, RightExpr} | Rest], Env0) ->
    {RightValue, Env1} = eval_expr(RightExpr, Env0),
    case eval_compare(Op, LeftValue, RightValue) of
        true -> eval_compare_chain(RightValue, Rest, Env1);
        false -> {false, Env1}
    end.

binop_method(plus) -> <<"__add__">>;
binop_method(minus) -> <<"__sub__">>;
binop_method(star) -> <<"__mul__">>;
binop_method(pow) -> <<"__pow__">>;
binop_method(slash) -> <<"__truediv__">>;
binop_method(floor_div) -> <<"__floordiv__">>;
binop_method(percent) -> <<"__mod__">>;
binop_method(lshift) -> <<"__lshift__">>;
binop_method(rshift) -> <<"__rshift__">>;
binop_method(amp) -> <<"__and__">>;
binop_method(caret) -> <<"__xor__">>;
binop_method(pipe) -> <<"__or__">>.

reflected_binop_method(plus) -> <<"__radd__">>;
reflected_binop_method(minus) -> <<"__rsub__">>;
reflected_binop_method(star) -> <<"__rmul__">>;
reflected_binop_method(pow) -> <<"__rpow__">>;
reflected_binop_method(slash) -> <<"__rtruediv__">>;
reflected_binop_method(floor_div) -> <<"__rfloordiv__">>;
reflected_binop_method(percent) -> <<"__rmod__">>;
reflected_binop_method(lshift) -> <<"__rlshift__">>;
reflected_binop_method(rshift) -> <<"__rrshift__">>;
reflected_binop_method(amp) -> <<"__rand__">>;
reflected_binop_method(caret) -> <<"__rxor__">>;
reflected_binop_method(pipe) -> <<"__ror__">>.

format_percent(Format, Args) ->
    Chars = unicode_chars(Format),
    case format_uses_mapping(Chars) of
        true ->
            unicode:characters_to_binary(lists:reverse(format_percent_mapping(Chars, Args, [])));
        false ->
            case
                (not format_has_conversion(Chars)) andalso
                    format_arg_is_ignored_without_conversions(Args)
            of
                true ->
                    {Output, []} = format_percent(Chars, [], []),
                    unicode:characters_to_binary(lists:reverse(Output));
                false ->
                    Values = format_args(Args),
                    {Output, RestValues} = format_percent(Chars, Values, []),
                    case RestValues of
                        [] ->
                            unicode:characters_to_binary(lists:reverse(Output));
                        _ ->
                            case format_arg_is_mapping(Args) of
                                true ->
                                    unicode:characters_to_binary(lists:reverse(Output));
                                false ->
                                    trace_percent_extra_args(Format, Args, RestValues),
                                    raise_builtin(
                                        <<"TypeError">>,
                                        <<"not all arguments converted during string formatting">>
                                    )
                            end
                    end
            end
    end.

format_args({py_ref, _} = Ref) ->
    [Ref];
format_args(Tuple) when is_tuple(Tuple) ->
    case internal_value_tuple(Tuple) of
        true -> [Tuple];
        false -> tuple_to_list(Tuple)
    end;
format_args(Value) ->
    [Value].

format_arg_is_mapping({py_ref, _} = Ref) ->
    try
        pyrlang_heap:type(Ref) =:= dict
    catch
        _:_ -> false
    end;
format_arg_is_mapping(_Args) ->
    false.

format_arg_is_ignored_without_conversions({py_ref, _} = Ref) ->
    try
        case pyrlang_heap:type(Ref) of
            list -> true;
            dict -> true;
            _ -> false
        end
    catch
        _:_ -> false
    end;
format_arg_is_ignored_without_conversions(_Args) ->
    false.

trace_percent_extra_args(Format, Args, RestValues) ->
    case os:getenv("PYRLANG_TRACE_PERCENT") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_PERCENT_EXTRA format=~p args=~p args_type=~s rest=~p stack=~p~n",
                [Format, Args, describe_attr_object(Args), RestValues, trace_function_stack()]
            )
    end.

internal_value_tuple(Tuple) when tuple_size(Tuple) >= 1 ->
    case element(1, Tuple) of
        py_async_generator -> true;
        py_bound_method -> true;
        py_complex -> true;
        py_coroutine -> true;
        py_exception_type -> true;
        py_float_special -> true;
        py_function -> true;
        py_generic_alias -> true;
        py_module_dict -> true;
        py_native_call -> true;
        py_native_callable -> true;
        py_native_varargs -> true;
        py_range -> true;
        py_ref -> true;
        py_slice -> true;
        py_union_type -> true;
        py_weakref -> true;
        slice -> true;
        _ -> false
    end;
internal_value_tuple(_Tuple) ->
    false.

format_percent([], Values, Acc) ->
    {Acc, Values};
format_percent([$%, $% | Rest], Values, Acc) ->
    format_percent(Rest, Values, [$% | Acc]);
format_percent([$% | Rest], [Value | Values], Acc) ->
    {Spec, Tail} = take_percent_spec(Rest),
    format_percent(Tail, Values, format_percent_value(Spec, Value, Acc));
format_percent([$% | _Rest], [], _Acc) ->
    trace_percent_not_enough(),
    raise_builtin(<<"TypeError">>, <<"not enough arguments for format string">>);
format_percent([Char | Rest], Values, Acc) ->
    format_percent(Rest, Values, [Char | Acc]).

trace_percent_not_enough() ->
    case os:getenv("PYRLANG_TRACE_PERCENT") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_PERCENT_NOT_ENOUGH stack=~p~n", [
                trace_function_stack()
            ])
    end.

format_uses_mapping([]) ->
    false;
format_uses_mapping([$%, $% | Rest]) ->
    format_uses_mapping(Rest);
format_uses_mapping([$%, $( | _Rest]) ->
    true;
format_uses_mapping([_Char | Rest]) ->
    format_uses_mapping(Rest).

format_has_conversion([]) ->
    false;
format_has_conversion([$%, $% | Rest]) ->
    format_has_conversion(Rest);
format_has_conversion([$% | _Rest]) ->
    true;
format_has_conversion([_Char | Rest]) ->
    format_has_conversion(Rest).

format_percent_mapping([], _Mapping, Acc) ->
    Acc;
format_percent_mapping([$%, $% | Rest], Mapping, Acc) ->
    format_percent_mapping(Rest, Mapping, [$% | Acc]);
format_percent_mapping([$%, $( | Rest], Mapping, Acc) ->
    {KeyChars, AfterKey} = take_percent_mapping_key(Rest, []),
    {Spec, Tail} = take_percent_spec(AfterKey),
    Key = unicode:characters_to_binary(KeyChars),
    Value = get_subscript(Mapping, Key),
    format_percent_mapping(Tail, Mapping, format_percent_value(Spec, Value, Acc));
format_percent_mapping([$% | Rest], Mapping, Acc) ->
    {Spec, Tail} = take_percent_spec(Rest),
    format_percent_mapping(Tail, Mapping, format_percent_value(Spec, Mapping, Acc));
format_percent_mapping([Char | Rest], Mapping, Acc) ->
    format_percent_mapping(Rest, Mapping, [Char | Acc]).

take_percent_mapping_key([$) | Rest], Acc) ->
    {lists:reverse(Acc), Rest};
take_percent_mapping_key([Char | Rest], Acc) ->
    take_percent_mapping_key(Rest, [Char | Acc]);
take_percent_mapping_key([], _Acc) ->
    raise_builtin(<<"ValueError">>, <<"incomplete format key">>).

take_percent_spec([]) ->
    raise_builtin(<<"ValueError">>, <<"incomplete format">>);
take_percent_spec(Chars) ->
    take_percent_spec(Chars, false, []).

take_percent_spec([], _ZeroPad, _WidthChars) ->
    raise_builtin(<<"ValueError">>, <<"incomplete format">>);
take_percent_spec([$0 | Rest], _ZeroPad, []) ->
    take_percent_spec(Rest, true, []);
take_percent_spec([Char | Rest], ZeroPad, WidthChars) when Char >= $0, Char =< $9 ->
    take_percent_spec(Rest, ZeroPad, [Char | WidthChars]);
take_percent_spec([Spec | Rest], ZeroPad, WidthChars) ->
    case lists:member(Spec, "diouxXeEfFgGcrsa") of
        true -> {{Spec, ZeroPad, percent_width(WidthChars)}, Rest};
        false -> take_percent_spec(Rest, ZeroPad, WidthChars)
    end.

percent_width([]) ->
    none;
percent_width(WidthChars) ->
    list_to_integer(lists:reverse(WidthChars)).

format_percent_value({Spec, ZeroPad, Width}, Value, Acc) when Spec =:= $s ->
    prepend_percent_text(py_string(Value), ZeroPad, Width, Acc);
format_percent_value({Spec, ZeroPad, Width}, Value, Acc) when Spec =:= $r; Spec =:= $a ->
    prepend_percent_text(pyrlang_builtins:builtin_repr(Value), ZeroPad, Width, Acc);
format_percent_value({Spec, ZeroPad, Width}, Value, Acc) when
    Spec =:= $d; Spec =:= $i; Spec =:= $u
->
    prepend_percent_text(
        unicode:characters_to_binary(integer_to_list(numeric_value(Value))), ZeroPad, Width, Acc
    );
format_percent_value({Spec, ZeroPad, Width}, Value, Acc) when Spec =:= $x; Spec =:= $X ->
    Digits = integer_to_list(numeric_value(Value), 16),
    Text =
        case Spec of
            $X -> string:uppercase(Digits);
            _ -> string:lowercase(Digits)
        end,
    prepend_percent_text(unicode:characters_to_binary(Text), ZeroPad, Width, Acc);
format_percent_value({$c, ZeroPad, Width}, Value, Acc) when is_integer(Value) ->
    prepend_percent_text(<<Value/utf8>>, ZeroPad, Width, Acc);
format_percent_value({$c, ZeroPad, Width}, Value, Acc) when is_binary(Value) ->
    prepend_percent_text(Value, ZeroPad, Width, Acc);
format_percent_value({_Spec, ZeroPad, Width}, Value, Acc) ->
    prepend_percent_text(py_string(Value), ZeroPad, Width, Acc).

prepend_percent_text(Text0, ZeroPad, Width, Acc) ->
    Text = percent_pad(Text0, ZeroPad, Width),
    lists:reverse(unicode_chars(Text)) ++ Acc.

percent_pad(Text, _ZeroPad, none) ->
    Text;
percent_pad(Text, ZeroPad, Width) ->
    Length = length(unicode_chars(Text)),
    case Length >= Width of
        true ->
            Text;
        false ->
            PadChar =
                case ZeroPad of
                    true -> <<"0">>;
                    false -> <<" ">>
                end,
            Padding = binary:copy(PadChar, Width - Length),
            <<Padding/binary, Text/binary>>
    end.

unicode_chars(Binary) ->
    [Char || <<Char/utf8>> <= Binary].

py_string(none) ->
    <<"None">>;
py_string(not_implemented) ->
    <<"NotImplemented">>;
py_string(true) ->
    <<"True">>;
py_string(false) ->
    <<"False">>;
py_string(Value) when is_binary(Value) ->
    Value;
py_string(Value) when is_integer(Value) ->
    integer_to_binary(Value);
py_string(Value) when is_float(Value) ->
    unicode:characters_to_binary(float_to_list(Value));
py_string({py_float_special, nan}) ->
    <<"nan">>;
py_string({py_float_special, inf}) ->
    <<"inf">>;
py_string({py_float_special, neg_inf}) ->
    <<"-inf">>;
py_string(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
py_string({py_ref, _} = Ref) ->
    case string_subclass_value(Ref) of
        {ok, Value} -> Value;
        error -> object_string(Ref)
    end;
py_string(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

string_proxy_value({py_ref, _} = Ref) ->
    try
        case pyrlang_heap:type(Ref) of
            instance ->
                Class = maps:get(class, pyrlang_heap:data(Ref)),
                case pyrlang_object:class_name(Class) of
                    <<"__proxy__">> -> {ok, py_string(Ref)};
                    _Other -> error
                end;
            _Other ->
                error
        end
    catch
        _:_ -> error
    end.

object_string(Ref) ->
    try pyrlang_object:get_attr(Ref, <<"__str__">>) of
        Str ->
            case pyrlang_eval:call(Str, []) of
                Value when is_binary(Value) -> Value;
                Ref -> unicode:characters_to_binary(io_lib:format("~p", [Ref]));
                Other -> py_string(Other)
            end
    catch
        _:_ -> unicode:characters_to_binary(io_lib:format("~p", [Ref]))
    end.

special_compare(Left, Method, Right, Default) ->
    case call_special(Left, Method, [Right]) of
        {ok, not_implemented} -> Default;
        {ok, Value} -> Value;
        error -> Default
    end.

default_compare(Op, Left, Right) ->
    case python_order(Left, Right) of
        unordered -> false;
        lt -> Op =:= lt orelse Op =:= lte;
        eq -> Op =:= lte orelse Op =:= gte;
        gt -> Op =:= gt orelse Op =:= gte
    end.

python_order({py_float_special, nan}, _Right) ->
    unordered;
python_order(_Left, {py_float_special, nan}) ->
    unordered;
python_order({py_float_special, Kind}, {py_float_special, Kind}) ->
    eq;
python_order({py_float_special, neg_inf}, _Right) ->
    lt;
python_order(_Left, {py_float_special, neg_inf}) ->
    gt;
python_order({py_float_special, inf}, _Right) ->
    gt;
python_order(_Left, {py_float_special, inf}) ->
    lt;
python_order(Left, Right) when is_tuple(Left), is_tuple(Right) ->
    sequence_order(tuple_to_list(Left), tuple_to_list(Right));
python_order({py_ref, _} = Left, {py_ref, _} = Right) ->
    case {pyrlang_heap:type(Left), pyrlang_heap:type(Right)} of
        {list, list} ->
            sequence_order(pyrlang_heap:list_items(Left), pyrlang_heap:list_items(Right));
        _ ->
            case {string_subclass_value(Left), string_subclass_value(Right)} of
                {{ok, LeftValue}, {ok, RightValue}} -> erlang_order(LeftValue, RightValue);
                _ -> erlang_order(Left, Right)
            end
    end;
python_order({py_ref, _} = Left, Right) when is_binary(Right) ->
    case string_subclass_value(Left) of
        {ok, LeftValue} -> erlang_order(LeftValue, Right);
        error -> erlang_order(Left, Right)
    end;
python_order(Left, {py_ref, _} = Right) when is_binary(Left) ->
    case string_subclass_value(Right) of
        {ok, RightValue} -> erlang_order(Left, RightValue);
        error -> erlang_order(Left, Right)
    end;
python_order(Left, Right) ->
    erlang_order(Left, Right).

sequence_order([], []) ->
    eq;
sequence_order([], [_ | _]) ->
    lt;
sequence_order([_ | _], []) ->
    gt;
sequence_order([Left | LeftRest], [Right | RightRest]) ->
    case python_order(Left, Right) of
        eq -> sequence_order(LeftRest, RightRest);
        Order -> Order
    end.

erlang_order(Left, Right) ->
    case Left =:= Right of
        true ->
            eq;
        false ->
            case Left < Right of
                true -> lt;
                false -> gt
            end
    end.

call_special({py_ref, _} = Object, Method, Args) ->
    case pyrlang_heap:type(Object) of
        class ->
            error;
        _Type ->
            try pyrlang_object:get_attr(Object, Method) of
                Callable -> {ok, call_value(Callable, Args)}
            catch
                error:{attribute_error, _Name} -> error;
                throw:{py_exception, _Exception} -> error
            end
    end;
call_special(_Object, _Method, _Args) ->
    error.

numeric_value(true) -> 1;
numeric_value(false) -> 0;
numeric_value(Value) when is_binary(Value), byte_size(Value) =:= 1 -> binary:first(Value);
numeric_value(Value) when is_integer(Value); is_float(Value) -> Value.

negate_value({py_float_special, inf}) ->
    {py_float_special, neg_inf};
negate_value({py_float_special, neg_inf}) ->
    {py_float_special, inf};
negate_value({py_float_special, nan}) ->
    {py_float_special, nan};
negate_value({py_complex, Real, Imag}) ->
    {py_complex, -Real, -Imag};
negate_value(Value) ->
    -Value.

integer_pow(_Base, 0) ->
    1;
integer_pow(Base, Exp) when Exp > 0 ->
    integer_pow(Base, Exp, 1).

integer_pow(_Base, 0, Acc) ->
    Acc;
integer_pow(Base, Exp, Acc) when Exp rem 2 =:= 1 ->
    integer_pow(Base * Base, Exp div 2, Acc * Base);
integer_pow(Base, Exp, Acc) ->
    integer_pow(Base * Base, Exp div 2, Acc).

integer_bit_length(0) ->
    0;
integer_bit_length(Value) ->
    length(integer_to_list(abs(Value), 2)).

integer_to_bytes(Integer, Args, KwArgs0) ->
    case maps:keys(maps:without([<<"length">>, <<"byteorder">>, <<"signed">>], KwArgs0)) of
        [] ->
            ok;
        Unknown ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end,
    case Args of
        [_Length, _Byteorder, _Signed | _Rest] ->
            erlang:error({arity_error, {to_bytes, length(Args), maps:size(KwArgs0)}});
        _ ->
            ok
    end,
    check_integer_to_bytes_duplicate_args(Args, KwArgs0),
    Length = integer_to_bytes_length(integer_to_bytes_arg(1, <<"length">>, Args, KwArgs0, 1)),
    Byteorder = py_string(integer_to_bytes_arg(2, <<"byteorder">>, Args, KwArgs0, <<"big">>)),
    Signed = truthy(integer_to_bytes_arg(3, <<"signed">>, Args, KwArgs0, false)),
    Bits = Length * 8,
    Encoded = integer_to_bytes_encoded(Integer, Bits, Signed),
    integer_to_bytes_binary(Encoded, Length, Byteorder).

check_integer_to_bytes_duplicate_args(Args, KwArgs) ->
    PositionalKeys = lists:sublist([<<"length">>, <<"byteorder">>, <<"signed">>], length(Args)),
    case [Key || Key <- PositionalKeys, maps:is_key(Key, KwArgs)] of
        [] -> ok;
        [Key | _] -> erlang:error({type_error, {multiple_values_for_argument, Key}})
    end.

integer_to_bytes_arg(Position, Key, Args, KwArgs, Default) ->
    case length(Args) >= Position of
        true -> lists:nth(Position, Args);
        false -> maps:get(Key, KwArgs, Default)
    end.

integer_to_bytes_length(true) ->
    1;
integer_to_bytes_length(false) ->
    0;
integer_to_bytes_length(Length) when is_integer(Length), Length >= 0 ->
    Length;
integer_to_bytes_length(Length) when is_integer(Length) ->
    raise_builtin(<<"ValueError">>, {negative_byte_length, Length});
integer_to_bytes_length(Length) ->
    erlang:error({type_error, {byte_length_not_integer, Length}}).

integer_to_bytes_encoded(Integer, Bits, false) when Integer >= 0 ->
    Max = (1 bsl Bits) - 1,
    case Integer =< Max of
        true -> Integer;
        false -> raise_builtin(<<"OverflowError">>, <<"int too big to convert">>)
    end;
integer_to_bytes_encoded(Integer, _Bits, false) ->
    raise_builtin(<<"OverflowError">>, {negative_integer, Integer});
integer_to_bytes_encoded(Integer, 0, true) ->
    case Integer of
        0 -> 0;
        _ -> raise_builtin(<<"OverflowError">>, <<"int too big to convert">>)
    end;
integer_to_bytes_encoded(Integer, Bits, true) ->
    Min = -(1 bsl (Bits - 1)),
    Max = (1 bsl (Bits - 1)) - 1,
    case Integer >= Min andalso Integer =< Max of
        true when Integer >= 0 -> Integer;
        true -> (1 bsl Bits) + Integer;
        false -> raise_builtin(<<"OverflowError">>, <<"int too big to convert">>)
    end.

integer_to_bytes_binary(_Encoded, 0, <<"big">>) ->
    <<>>;
integer_to_bytes_binary(_Encoded, 0, <<"little">>) ->
    <<>>;
integer_to_bytes_binary(Encoded, Length, <<"big">>) ->
    list_to_binary([(Encoded bsr (8 * Shift)) band 16#FF || Shift <- lists:seq(Length - 1, 0, -1)]);
integer_to_bytes_binary(Encoded, Length, <<"little">>) ->
    list_to_binary([(Encoded bsr (8 * Shift)) band 16#FF || Shift <- lists:seq(0, Length - 1)]);
integer_to_bytes_binary(_Encoded, _Length, Byteorder) ->
    raise_builtin(<<"ValueError">>, {invalid_byteorder, Byteorder}).

list_index(true) ->
    1;
list_index(false) ->
    0;
list_index(Index) when is_integer(Index) ->
    Index;
list_index(<<Index:8>>) ->
    Index;
list_index({py_ref, _} = Index) ->
    case pyrlang_builtins:int_subclass_value(Index) of
        {ok, Value} -> Value;
        error -> object_index_value(Index)
    end;
list_index(Index) ->
    erlang:error({type_error, {list_index, Index}}).

object_index_value(Object) ->
    try pyrlang_object:get_attr(Object, <<"__index__">>) of
        Method ->
            case call_value(Method, []) of
                Value when is_integer(Value) -> Value;
                Other -> erlang:error({type_error, {index_returned_non_int, Other}})
            end
    catch
        error:{attribute_error, _Name} ->
            erlang:error({type_error, {list_index, Object}});
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> -> erlang:error({type_error, {list_index, Object}});
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

normalize_index(Index, Length) when Index < 0 ->
    Normalized = Length + Index,
    case Normalized >= 0 of
        true -> Normalized;
        false -> erlang:error({index_error, Index})
    end;
normalize_index(Index, Length) when Index >= 0, Index < Length ->
    Index;
normalize_index(Index, _Length) ->
    erlang:error({index_error, Index}).

truthy(false) ->
    false;
truthy(none) ->
    false;
truthy(0) ->
    false;
truthy(<<>>) ->
    false;
truthy({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list -> pyrlang_heap:list_items(Ref) =/= [];
        dict -> pyrlang_heap:dict_items(Ref) =/= [];
        set -> pyrlang_heap:set_items(Ref) =/= [];
        instance -> instance_truthy(Ref);
        _ -> true
    end;
truthy(Tuple) when is_tuple(Tuple) ->
    tuple_size(Tuple) =/= 0;
truthy(_) ->
    true.

instance_truthy(Ref) ->
    case call_truthy_special(Ref, <<"__bool__">>) of
        {ok, Value} ->
            truthy(Value);
        error ->
            case call_truthy_special(Ref, <<"__len__">>) of
                {ok, Len} when is_integer(Len); is_float(Len) ->
                    Len =/= 0;
                {ok, true} ->
                    true;
                {ok, false} ->
                    false;
                {ok, _Other} ->
                    true;
                error ->
                    case tuple_subclass_items(Ref) of
                        {ok, Items} ->
                            Items =/= [];
                        error ->
                            case string_subclass_value(Ref) of
                                {ok, Value} -> Value =/= <<>>;
                                error -> true
                            end
                    end
            end
    end.

call_truthy_special(Ref, Method) ->
    try pyrlang_object:get_attr(Ref, Method) of
        Callable -> {ok, pyrlang_eval:call(Callable, [])}
    catch
        _:_ -> error
    end.

tuple_subclass_items({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
            case maps:find(<<"__pyrlang_tuple_items__">>, Attrs) of
                {ok, Tuple} when is_tuple(Tuple) -> {ok, tuple_to_list(Tuple)};
                _ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.

string_subclass_value({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            case is_string_subclass_instance(Ref) of
                true ->
                    Attrs = maps:get(attrs, pyrlang_heap:data(Ref)),
                    case maps:find(<<"__pyrlang_value__">>, Attrs) of
                        {ok, Value} when is_binary(Value) -> {ok, Value};
                        _ -> error
                    end;
                false ->
                    error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end;
string_subclass_value(_Other) ->
    error.

is_string_subclass_instance({py_ref, _} = Ref) ->
    Class = pyrlang_builtins:object_class(Ref),
    lists:any(
        fun(MroClass) -> class_named(MroClass, <<"str">>) end,
        pyrlang_object:mro(Class)
    ).

class_named({py_ref, _} = Class, Name) ->
    try
        pyrlang_heap:type(Class) =:= class andalso pyrlang_object:class_name(Class) =:= Name
    catch
        _:_ -> false
    end;
class_named(_Class, _Name) ->
    false.

eval_while(Condition, Body, Env0, Last) ->
    {ConditionValue, Env1} = eval_expr(Condition, Env0),
    case truthy(ConditionValue) of
        true ->
            try
                {BodyLast, Env2} = eval_statements(Body, Env1, none),
                eval_while(Condition, Body, Env2, BodyLast)
            catch
                throw:{py_continue, ContinueEnv} -> eval_while(Condition, Body, ContinueEnv, Last);
                throw:py_continue -> eval_while(Condition, Body, Env1, Last);
                throw:{py_break, BreakEnv} -> {Last, BreakEnv, false};
                throw:py_break -> {Last, Env1, false}
            end;
        false ->
            {Last, Env1, true}
    end.

eval_for(Target, Iterator, Body, Env0, Last) ->
    case next_iterator_value(Iterator) of
        done ->
            {Last, Env0, true};
        {ok, Value} ->
            Env1 = bind_assignment_target(Target, Value, Env0),
            try
                {BodyLast, Env2} = eval_statements(Body, Env1, none),
                eval_for(Target, Iterator, Body, Env2, BodyLast)
            catch
                throw:{py_exception_with_env, Exception, ExceptionEnv} ->
                    throw({py_exception_with_env, Exception, ExceptionEnv});
                throw:{py_exception, Exception} ->
                    throw({py_exception_with_env, Exception, Env1});
                throw:{py_continue, ContinueEnv} ->
                    eval_for(Target, Iterator, Body, ContinueEnv, Last);
                throw:py_continue ->
                    eval_for(Target, Iterator, Body, Env1, Last);
                throw:{py_break, BreakEnv} ->
                    {Last, BreakEnv, false};
                throw:py_break ->
                    {Last, Env1, false}
            end
    end.

next_iterator_value(Iterator) ->
    try pyrlang_iter:next(Iterator) of
        Value ->
            {ok, Value}
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"StopIteration">> -> done;
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

eval_loop_else(true, ElseBody, Env, _LoopLast) ->
    eval_statements(ElseBody, Env, none);
eval_loop_else(false, _ElseBody, Env, LoopLast) ->
    {LoopLast, Env}.

bind_assignment_target({target_name, Name}, Value, Env) ->
    bind_name(Name, Value, Env);
bind_assignment_target({target_attr, {attr, ObjectExpr, Name}}, Value, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    ok = pyrlang_object:set_attr(Object, Name, Value),
    Env1;
bind_assignment_target(
    {target_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr}}}, Value, Env0
) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Start, Env2} = eval_optional_slice(StartExpr, Env1),
    {Stop, Env3} = eval_optional_slice(StopExpr, Env2),
    ok = set_slice_or_raise(Object, Start, Stop, Value),
    Env3;
bind_assignment_target(
    {target_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr, undefined}}},
    Value,
    Env0
) ->
    bind_assignment_target(
        {target_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr}}}, Value, Env0
    );
bind_assignment_target({target_subscript, {subscript, ObjectExpr, IndexExpr}}, Value, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Index, Env2} = eval_expr(IndexExpr, Env1),
    ok = set_subscript_or_raise(Object, Index, Value),
    Env2;
bind_assignment_target({target_starred, Target}, Value, Env) ->
    bind_assignment_target(Target, Value, Env);
bind_assignment_target({target_tuple, Targets}, Value, Env) ->
    bind_sequence_assignment_targets(Targets, Value, Env);
bind_assignment_target({target_list, Targets}, Value, Env) ->
    bind_sequence_assignment_targets(Targets, Value, Env).

bind_name(Name, Value, Env) ->
    case lists:member(Name, maps:get(?GLOBAL_DECL_NAMES, Env, [])) of
        true ->
            bind_global_name(Name, Value, Env);
        false ->
            Env1 = Env#{Name => Value},
            sync_bound_module_name(Name, Value, Env1),
            Env1
    end.

sync_bound_module_name(Name, Value, Env) ->
    case top_level_module_binding() of
        true -> set_current_loading_module_name(Name, Value, Env);
        false -> ok
    end.

set_current_loading_module_name(Name, Value, Env) ->
    ModuleName = maps:get(<<"__name__">>, Env, undefined),
    case erlang:get(pyrlang_current_loading_module) of
        {py_ref, _} = ModuleRef when is_binary(ModuleName) ->
            try pyrlang_heap:data(ModuleRef) of
                #{name := ModuleName} -> pyrlang_module:set_attr(ModuleRef, Name, Value);
                _Other -> ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

top_level_module_binding() ->
    case {erlang:get(?MODULE_EVAL_KEY), erlang:get(?COMP_EVAL_KEY)} of
        {true, true} -> false;
        {true, _} -> true;
        _ -> false
    end.

bind_global_name(Name, Value, Env) ->
    _ = set_module_global_name(Name, Value, Env),
    Env#{Name => Value}.

set_module_global_name(Name, Value, Env) ->
    case maps:get(<<"__name__">>, Env, undefined) of
        ModuleName when is_binary(ModuleName) ->
            set_global_name_in_module(ModuleName, Name, Value);
        _ ->
            ok
    end.

set_global_name_in_module(<<"__main__">>, _Name, _Value) ->
    ok;
set_global_name_in_module(ModuleName, Name, Value) ->
    case erlang:get(pyrlang_current_loading_module) of
        {py_ref, _} = ModuleRef ->
            try pyrlang_heap:data(ModuleRef) of
                #{name := ModuleName} ->
                    pyrlang_module:set_attr(ModuleRef, Name, Value);
                _Other ->
                    pyrlang_module:set_attr(pyrlang_module:load(ModuleName), Name, Value)
            catch
                _:_ -> ok
            end;
        _ ->
            try
                pyrlang_module:set_attr(pyrlang_module:load(ModuleName), Name, Value)
            catch
                _:_ -> ok
            end
    end.

read_assignment_target({target_name, Name}, Env) ->
    {lookup_var(Name, Env), Env};
read_assignment_target({target_attr, {attr, ObjectExpr, Name}}, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {pyrlang_object:get_attr(Object, Name), Env1};
read_assignment_target({target_subscript, {subscript, ObjectExpr, IndexExpr}}, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Index, Env2} = eval_expr(IndexExpr, Env1),
    {get_subscript_or_raise(Object, Index), Env2};
read_assignment_target(Target, _Env) ->
    erlang:error({type_error, {invalid_augmented_assignment_target, Target}}).

delete_assignment_target({target_name, Name}, Env) ->
    maps:remove(Name, Env);
delete_assignment_target({target_attr, {attr, ObjectExpr, Name}}, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    ok = pyrlang_object:del_attr(Object, Name),
    Env1;
delete_assignment_target(
    {target_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr}}}, Env0
) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Start, Env2} = eval_optional_slice(StartExpr, Env1),
    {Stop, Env3} = eval_optional_slice(StopExpr, Env2),
    ok = del_slice(Object, Start, Stop),
    Env3;
delete_assignment_target(
    {target_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr, undefined}}}, Env0
) ->
    delete_assignment_target(
        {target_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr}}}, Env0
    );
delete_assignment_target({target_subscript, {subscript, ObjectExpr, IndexExpr}}, Env0) ->
    {Object, Env1} = eval_expr(ObjectExpr, Env0),
    {Index, Env2} = eval_expr(IndexExpr, Env1),
    ok = del_subscript(Object, Index),
    Env2;
delete_assignment_target({target_tuple, Targets}, Env) ->
    lists:foldl(fun(Target, AccEnv) -> delete_assignment_target(Target, AccEnv) end, Env, Targets);
delete_assignment_target({target_list, Targets}, Env) ->
    lists:foldl(fun(Target, AccEnv) -> delete_assignment_target(Target, AccEnv) end, Env, Targets);
delete_assignment_target(Target, _Env) ->
    erlang:error({type_error, {invalid_delete_target, Target}}).

bind_sequence_assignment_targets(Targets, Value, Env) ->
    Values = iter_values(Value),
    case split_starred_assignment_targets(Targets) of
        none ->
            case length(Targets) =:= length(Values) of
                true -> bind_assignment_pairs(Targets, Values, Env);
                false -> raise_builtin(<<"ValueError">>, <<"not enough values to unpack">>)
            end;
        {BeforeTargets, StarredTarget, AfterTargets} ->
            BeforeCount = length(BeforeTargets),
            AfterCount = length(AfterTargets),
            case length(Values) >= BeforeCount + AfterCount of
                true ->
                    {BeforeValues, RestValues} = lists:split(BeforeCount, Values),
                    StarredCount = length(RestValues) - AfterCount,
                    {StarredValues, AfterValues} = lists:split(StarredCount, RestValues),
                    Env1 = bind_assignment_pairs(BeforeTargets, BeforeValues, Env),
                    Env2 = bind_assignment_target(
                        StarredTarget, pyrlang_heap:list(StarredValues), Env1
                    ),
                    bind_assignment_pairs(AfterTargets, AfterValues, Env2);
                false ->
                    raise_builtin(<<"ValueError">>, <<"not enough values to unpack">>)
            end;
        many ->
            raise_builtin(<<"SyntaxError">>, <<"multiple starred assignment targets">>)
    end.

bind_assignment_pairs(Targets, Values, Env) ->
    lists:foldl(
        fun({Target, Item}, AccEnv) -> bind_assignment_target(Target, Item, AccEnv) end,
        Env,
        lists:zip(Targets, Values)
    ).

split_starred_assignment_targets(Targets) ->
    split_starred_assignment_targets(Targets, [], none).

split_starred_assignment_targets([], _Before, none) ->
    none;
split_starred_assignment_targets([], Before, {Starred, AfterRev}) ->
    {lists:reverse(Before), Starred, lists:reverse(AfterRev)};
split_starred_assignment_targets([{target_starred, Target} | Rest], Before, none) ->
    split_starred_assignment_targets(Rest, Before, {Target, []});
split_starred_assignment_targets(
    [{target_starred, _Target} | _Rest], _Before, {_Starred, _AfterRev}
) ->
    many;
split_starred_assignment_targets([Target | Rest], Before, none) ->
    split_starred_assignment_targets(Rest, [Target | Before], none);
split_starred_assignment_targets([Target | Rest], Before, {Starred, AfterRev}) ->
    split_starred_assignment_targets(Rest, Before, {Starred, [Target | AfterRev]}).

eval_joined_str([], Env, Acc) ->
    {join_binary(lists:reverse(Acc), <<>>), Env};
eval_joined_str([{literal, Value} | Rest], Env, Acc) ->
    eval_joined_str(Rest, Env, [Value | Acc]);
eval_joined_str([{formatted, Expr, Conversion} | Rest], Env0, Acc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_joined_str(Rest, Env1, [format_fstring_value(Value, Conversion) | Acc]);
eval_joined_str([{formatted, Expr, Conversion, FormatSpec} | Rest], Env0, Acc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    eval_joined_str(Rest, Env1, [format_fstring_value(Value, Conversion, FormatSpec) | Acc]);
eval_joined_str([{formatted_debug, Prefix, Expr, Conversion, FormatSpec} | Rest], Env0, Acc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    Formatted = format_fstring_value(Value, Conversion, FormatSpec),
    eval_joined_str(Rest, Env1, [<<Prefix/binary, Formatted/binary>> | Acc]).

format_fstring_value(Value, Conversion, none) ->
    format_fstring_value(Value, Conversion);
format_fstring_value(Value, none, FormatSpec) when is_float(Value); is_integer(Value) ->
    case fstring_fixed_precision(FormatSpec) of
        {ok, Precision} ->
            unicode:characters_to_binary(io_lib:format("~.*f", [Precision, numeric_value(Value)]));
        unsupported ->
            format_fstring_value(Value, none)
    end;
format_fstring_value(Value, Conversion, _FormatSpec) ->
    format_fstring_value(Value, Conversion).

format_fstring_value(Value, none) ->
    py_string(Value);
format_fstring_value(Value, $s) ->
    py_string(Value);
format_fstring_value(Value, $r) ->
    py_string(Value);
format_fstring_value(Value, $a) ->
    py_string(Value).

fstring_fixed_precision(Spec) when is_binary(Spec) ->
    case re:run(binary_to_list(Spec), "^[0-9]*\\.([0-9]+)[fF]$", [{capture, [1], list}]) of
        {match, [Digits]} -> {ok, list_to_integer(Digits)};
        nomatch -> unsupported
    end.

eval_comp_collect(Clauses, Env0, Emit) ->
    Previous = erlang:get(?COMP_EVAL_KEY),
    erlang:put(?COMP_EVAL_KEY, true),
    try
        {Values, Env1} = eval_comp_loop(Clauses, Env0, Emit, []),
        {lists:reverse(Values), Env1}
    after
        restore_process_value(?COMP_EVAL_KEY, Previous)
    end.

comp_clause_target_names(Clauses) ->
    lists:usort(
        lists:flatmap(
            fun
                ({for, Target, _IterableExpr, _Conditions}) -> target_bound_names(Target);
                (_Other) -> []
            end,
            Clauses
        )
    ).

target_bound_names({target_name, Name}) ->
    [Name];
target_bound_names({target_tuple, Targets}) ->
    lists:flatmap(fun target_bound_names/1, Targets);
target_bound_names({target_list, Targets}) ->
    lists:flatmap(fun target_bound_names/1, Targets);
target_bound_names({target_starred, Target}) ->
    target_bound_names(Target);
target_bound_names(_Target) ->
    [].

restore_comp_targets(OuterEnv, LocalEnv, Names) ->
    lists:foldl(
        fun(Name, EnvAcc) ->
            case maps:find(Name, OuterEnv) of
                {ok, Value} -> EnvAcc#{Name => Value};
                error -> maps:remove(Name, EnvAcc)
            end
        end,
        LocalEnv,
        Names
    ).

eval_comp_loop([], Env0, Emit, Acc) ->
    {Value, Env1} = Emit(Env0),
    {[Value | Acc], Env1};
eval_comp_loop([{for, Target, IterableExpr, Conditions} | RestClauses], Env0, Emit, Acc0) ->
    {Iterable, Env1} = eval_expr(IterableExpr, Env0),
    eval_comp_iter(
        Target, iter_values(Iterable), lists:reverse(Conditions), RestClauses, Env1, Emit, Acc0
    ).

eval_comp_iter(_Target, [], _Conditions, _RestClauses, Env, _Emit, Acc) ->
    {Acc, Env};
eval_comp_iter(Target, [Value | Rest], Conditions, RestClauses, Env0, Emit, Acc0) ->
    Env1 = bind_assignment_target(Target, Value, Env0),
    {Include, Env2} = eval_comp_conditions(Conditions, Env1),
    {Acc1, Env3} =
        case Include of
            true -> eval_comp_loop(RestClauses, Env2, Emit, Acc0);
            false -> {Acc0, Env2}
        end,
    eval_comp_iter(Target, Rest, Conditions, RestClauses, Env3, Emit, Acc1).

eval_comp_conditions([], Env) ->
    {true, Env};
eval_comp_conditions([Condition | Rest], Env0) ->
    {ConditionValue, Env1} = eval_expr(Condition, Env0),
    case truthy(ConditionValue) of
        true -> eval_comp_conditions(Rest, Env1);
        false -> {false, Env1}
    end.

eval_list_comp(_Expr, _Target, [], _Condition, Env, Acc) ->
    {lists:reverse(Acc), Env};
eval_list_comp(Expr, Target, [Value | Rest], Condition, Env0, Acc) ->
    Env1 = bind_assignment_target(Target, Value, Env0),
    {Include, Env2} =
        case Condition of
            none ->
                {true, Env1};
            _ ->
                {ConditionValue, ConditionEnv} = eval_expr(Condition, Env1),
                {truthy(ConditionValue), ConditionEnv}
        end,
    case Include of
        true ->
            {Item, Env3} = eval_expr(Expr, Env2),
            eval_list_comp(Expr, Target, Rest, Condition, Env3, [Item | Acc]);
        false ->
            eval_list_comp(Expr, Target, Rest, Condition, Env2, Acc)
    end.

eval_dict_comp(_KeyExpr, _ValueExpr, _Target, [], _Condition, Env, Acc) ->
    {lists:reverse(Acc), Env};
eval_dict_comp(KeyExpr, ValueExpr, Target, [Value | Rest], Condition, Env0, Acc) ->
    Env1 = bind_assignment_target(Target, Value, Env0),
    {Include, Env2} = eval_comp_condition(Condition, Env1),
    case Include of
        true ->
            {Key, Env3} = eval_expr(KeyExpr, Env2),
            {ItemValue, Env4} = eval_expr(ValueExpr, Env3),
            eval_dict_comp(KeyExpr, ValueExpr, Target, Rest, Condition, Env4, [
                {Key, ItemValue} | Acc
            ]);
        false ->
            eval_dict_comp(KeyExpr, ValueExpr, Target, Rest, Condition, Env2, Acc)
    end.

eval_set_comp(_Expr, _Target, [], _Condition, Env, Acc) ->
    {lists:reverse(Acc), Env};
eval_set_comp(Expr, Target, [Value | Rest], Condition, Env0, Acc) ->
    Env1 = bind_assignment_target(Target, Value, Env0),
    {Include, Env2} = eval_comp_condition(Condition, Env1),
    case Include of
        true ->
            {Item, Env3} = eval_expr(Expr, Env2),
            eval_set_comp(Expr, Target, Rest, Condition, Env3, [Item | Acc]);
        false ->
            eval_set_comp(Expr, Target, Rest, Condition, Env2, Acc)
    end.

eval_comp_condition(none, Env) ->
    {true, Env};
eval_comp_condition(Condition, Env0) ->
    {ConditionValue, Env1} = eval_expr(Condition, Env0),
    {truthy(ConditionValue), Env1}.

iter_values(Value) ->
    pyrlang_iter:values(Value).

eval_with(ManagerExpr, Binding, Body, Env0) ->
    {Manager, Env1} = eval_expr(ManagerExpr, Env0),
    Enter = pyrlang_object:get_attr(Manager, <<"__enter__">>),
    Exit = pyrlang_object:get_attr(Manager, <<"__exit__">>),
    Entered = call_value(Enter, []),
    BodyEnv =
        case Binding of
            undefined -> Env1;
            Target -> bind_assignment_target(Target, Entered, Env1)
        end,
    try
        {Value, Env2} = eval_statements(Body, BodyEnv, none),
        _ = call_value(Exit, [none, none, none]),
        {Value, Env2}
    catch
        throw:{py_exception, Exception} ->
            Suppressed = call_value(Exit, [
                pyrlang_exception:exception_type(Exception), Exception, none
            ]),
            case truthy(Suppressed) of
                true -> {none, BodyEnv};
                false -> pyrlang_exception:raise(Exception)
            end;
        throw:{py_return, ReturnValue} ->
            _ = call_value(Exit, [none, none, none]),
            throw({py_return, ReturnValue});
        throw:{py_break, BreakEnv} ->
            _ = call_value(Exit, [none, none, none]),
            throw({py_break, BreakEnv});
        throw:py_break ->
            _ = call_value(Exit, [none, none, none]),
            throw(py_break);
        throw:{py_continue, ContinueEnv} ->
            _ = call_value(Exit, [none, none, none]),
            throw({py_continue, ContinueEnv});
        throw:py_continue ->
            _ = call_value(Exit, [none, none, none]),
            throw(py_continue)
    end.

contains_yield(Statements) ->
    lists:any(fun statement_contains_yield/1, Statements).

async_mode(Body) ->
    case contains_yield(Body) of
        true -> async_generator;
        false -> async
    end.

statement_contains_yield({yield, _Expr}) ->
    true;
statement_contains_yield({yield_from, _Expr}) ->
    true;
statement_contains_yield({if_stmt, _Condition, ThenBody, ElseBody}) ->
    contains_yield(ThenBody) orelse contains_yield(ElseBody);
statement_contains_yield({while_stmt, _Condition, Body}) ->
    contains_yield(Body);
statement_contains_yield({while_stmt, _Condition, Body, ElseBody}) ->
    contains_yield(Body) orelse contains_yield(ElseBody);
statement_contains_yield({for_stmt, _Name, _Iterable, Body}) ->
    contains_yield(Body);
statement_contains_yield({for_stmt, _Name, _Iterable, Body, ElseBody}) ->
    contains_yield(Body) orelse contains_yield(ElseBody);
statement_contains_yield({try_stmt, Body, Handlers, ElseBody, FinallyBody}) ->
    contains_yield(Body) orelse contains_yield(ElseBody) orelse contains_yield(FinallyBody) orelse
        lists:any(
            fun({_Pattern, _Binding, HandlerBody}) -> contains_yield(HandlerBody) end, Handlers
        );
statement_contains_yield({with_stmt, _Manager, _Binding, Body}) ->
    contains_yield(Body);
statement_contains_yield({def, _Name, _Params, _Body}) ->
    false;
statement_contains_yield({def, _Name, _Params, _Body, _Decorators}) ->
    false;
statement_contains_yield({async_def, _Name, _Params, _Body}) ->
    false;
statement_contains_yield({async_def, _Name, _Params, _Body, _Decorators}) ->
    false;
statement_contains_yield({class, _Name, _Bases, _Metaclass, _Body}) ->
    false;
statement_contains_yield({class, _Name, _Bases, _Metaclass, _Body, _Decorators}) ->
    false;
statement_contains_yield(_Other) ->
    false.

collect_yields([], Env, Acc) ->
    {lists:reverse(Acc), Env};
collect_yields([{yield, Expr} | Rest], Env0, Acc) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    collect_yields(Rest, Env1, [Value | Acc]);
collect_yields([{yield_from, Expr} | Rest], Env0, Acc) ->
    {Iterable, Env1} = eval_expr(Expr, Env0),
    collect_yields(Rest, Env1, lists:reverse(iter_values(Iterable)) ++ Acc);
collect_yields([{if_stmt, Condition, ThenBody, ElseBody} | Rest], Env0, Acc0) ->
    {ConditionValue, Env1} = eval_expr(Condition, Env0),
    BranchBody =
        case truthy(ConditionValue) of
            true -> ThenBody;
            false -> ElseBody
        end,
    try collect_yields(BranchBody, Env1, []) of
        {Values, Env2} ->
            collect_yields(Rest, Env2, lists:reverse(Values) ++ Acc0)
    catch
        throw:{py_generator_return, Values, ReturnEnv} ->
            throw({py_generator_return, prepend_collected_yields(Acc0, Values), ReturnEnv})
    end;
collect_yields([{for_stmt, Target, IterableExpr, Body} | Rest], Env0, Acc0) ->
    collect_yields([{for_stmt, Target, IterableExpr, Body, []} | Rest], Env0, Acc0);
collect_yields([{for_stmt, Target, IterableExpr, Body, ElseBody} | Rest], Env0, Acc0) ->
    {Iterable, Env1} = eval_expr(IterableExpr, Env0),
    try
        {LoopValues, Env2, Completed} = collect_yield_for(
            Target, pyrlang_iter:iter(Iterable), Body, Env1, []
        ),
        {ElseValues, Env3} = collect_loop_else_yields(Completed, ElseBody, Env2),
        collect_yields(Rest, Env3, lists:reverse(ElseValues) ++ lists:reverse(LoopValues) ++ Acc0)
    catch
        throw:{py_generator_return, Values, ReturnEnv} ->
            throw({py_generator_return, prepend_collected_yields(Acc0, Values), ReturnEnv})
    end;
collect_yields([{while_stmt, Condition, Body} | Rest], Env0, Acc0) ->
    collect_yields([{while_stmt, Condition, Body, []} | Rest], Env0, Acc0);
collect_yields([{while_stmt, Condition, Body, ElseBody} | Rest], Env0, Acc0) ->
    try
        {LoopValues, Env1, Completed} = collect_yield_while(Condition, Body, Env0, []),
        {ElseValues, Env2} = collect_loop_else_yields(Completed, ElseBody, Env1),
        collect_yields(Rest, Env2, lists:reverse(ElseValues) ++ lists:reverse(LoopValues) ++ Acc0)
    catch
        throw:{py_generator_return, Values, ReturnEnv} ->
            throw({py_generator_return, prepend_collected_yields(Acc0, Values), ReturnEnv})
    end;
collect_yields([{with_stmt, ManagerExpr, Binding, Body} | Rest], Env0, Acc0) ->
    try collect_yield_with(ManagerExpr, Binding, Body, Env0) of
        {Values, Env1} ->
            collect_yields(Rest, Env1, lists:reverse(Values) ++ Acc0)
    catch
        throw:{py_generator_return, Values, ReturnEnv} ->
            throw({py_generator_return, prepend_collected_yields(Acc0, Values), ReturnEnv})
    end;
collect_yields([{try_stmt, Body, Handlers, ElseBody, FinallyBody} | Rest], Env0, Acc0) ->
    try collect_yield_try(Body, Handlers, ElseBody, FinallyBody, Env0) of
        {Values, Env1} ->
            collect_yields(Rest, Env1, lists:reverse(Values) ++ Acc0)
    catch
        throw:{py_generator_return, Values, ReturnEnv} ->
            throw({py_generator_return, prepend_collected_yields(Acc0, Values), ReturnEnv})
    end;
collect_yields([break | _Rest], Env, Acc) ->
    throw({py_generator_break, lists:reverse(Acc), Env});
collect_yields([continue | _Rest], Env, Acc) ->
    throw({py_generator_continue, lists:reverse(Acc), Env});
collect_yields([{return, _Expr} | _Rest], Env, Acc) ->
    throw({py_generator_return, lists:reverse(Acc), Env});
collect_yields([Statement | Rest], Env0, Acc) ->
    {_Value, Env1} = eval_statements([Statement], Env0, none),
    collect_yields(Rest, Env1, Acc).

prepend_collected_yields(Acc, Values) ->
    lists:reverse(lists:reverse(Values) ++ Acc).

collect_yield_for(Target, Iterator, Body, Env0, Acc0) ->
    case next_iterator_value(Iterator) of
        done ->
            {lists:reverse(Acc0), Env0, true};
        {ok, Value} ->
            Env1 = bind_assignment_target(Target, Value, Env0),
            try collect_yields(Body, Env1, []) of
                {Values, Env2} ->
                    collect_yield_for(Target, Iterator, Body, Env2, lists:reverse(Values) ++ Acc0)
            catch
                throw:{py_generator_return, Values, ReturnEnv} ->
                    throw({py_generator_return, prepend_collected_yields(Acc0, Values), ReturnEnv});
                throw:{py_generator_continue, Values, ContinueEnv} ->
                    collect_yield_for(
                        Target, Iterator, Body, ContinueEnv, lists:reverse(Values) ++ Acc0
                    );
                throw:{py_generator_break, Values, BreakEnv} ->
                    {lists:reverse(lists:reverse(Values) ++ Acc0), BreakEnv, false};
                throw:{py_continue, ContinueEnv} ->
                    collect_yield_for(Target, Iterator, Body, ContinueEnv, Acc0);
                throw:py_continue ->
                    collect_yield_for(Target, Iterator, Body, Env1, Acc0);
                throw:{py_break, BreakEnv} ->
                    {lists:reverse(Acc0), BreakEnv, false};
                throw:py_break ->
                    {lists:reverse(Acc0), Env1, false}
            end
    end.

collect_yield_while(Condition, Body, Env0, Acc0) ->
    {ConditionValue, Env1} = eval_expr(Condition, Env0),
    case truthy(ConditionValue) of
        true ->
            try collect_yields(Body, Env1, []) of
                {Values, Env2} ->
                    collect_yield_while(Condition, Body, Env2, lists:reverse(Values) ++ Acc0)
            catch
                throw:{py_generator_return, Values, ReturnEnv} ->
                    throw({py_generator_return, prepend_collected_yields(Acc0, Values), ReturnEnv});
                throw:{py_generator_continue, Values, ContinueEnv} ->
                    collect_yield_while(
                        Condition, Body, ContinueEnv, lists:reverse(Values) ++ Acc0
                    );
                throw:{py_generator_break, Values, BreakEnv} ->
                    {lists:reverse(lists:reverse(Values) ++ Acc0), BreakEnv, false};
                throw:{py_continue, ContinueEnv} ->
                    collect_yield_while(Condition, Body, ContinueEnv, Acc0);
                throw:py_continue ->
                    collect_yield_while(Condition, Body, Env1, Acc0);
                throw:{py_break, BreakEnv} ->
                    {lists:reverse(Acc0), BreakEnv, false};
                throw:py_break ->
                    {lists:reverse(Acc0), Env1, false}
            end;
        false ->
            {lists:reverse(Acc0), Env1, true}
    end.

collect_loop_else_yields(true, ElseBody, Env) ->
    collect_yields(ElseBody, Env, []);
collect_loop_else_yields(false, _ElseBody, Env) ->
    {[], Env}.

collect_yield_with(ManagerExpr, Binding, Body, Env0) ->
    {Manager, Env1} = eval_expr(ManagerExpr, Env0),
    Enter = pyrlang_object:get_attr(Manager, <<"__enter__">>),
    Exit = pyrlang_object:get_attr(Manager, <<"__exit__">>),
    Entered = call_value(Enter, []),
    BodyEnv =
        case Binding of
            undefined -> Env1;
            Target -> bind_assignment_target(Target, Entered, Env1)
        end,
    try
        {Values, Env2} = collect_yields(Body, BodyEnv, []),
        _ = call_value(Exit, [none, none, none]),
        {Values, Env2}
    catch
        throw:{py_generator_return, ReturnValues, ReturnEnv} ->
            _ = call_value(Exit, [none, none, none]),
            throw({py_generator_return, ReturnValues, ReturnEnv});
        throw:{py_exception, Exception} ->
            Suppressed = call_value(Exit, [
                pyrlang_exception:exception_type(Exception), Exception, none
            ]),
            case truthy(Suppressed) of
                true -> {[], BodyEnv};
                false -> pyrlang_exception:raise(Exception)
            end;
        throw:{py_return, ReturnValue} ->
            _ = call_value(Exit, [none, none, none]),
            throw({py_return, ReturnValue});
        throw:{py_break, BreakEnv} ->
            _ = call_value(Exit, [none, none, none]),
            throw({py_break, BreakEnv});
        throw:py_break ->
            _ = call_value(Exit, [none, none, none]),
            throw(py_break);
        throw:{py_continue, ContinueEnv} ->
            _ = call_value(Exit, [none, none, none]),
            throw({py_continue, ContinueEnv});
        throw:py_continue ->
            _ = call_value(Exit, [none, none, none]),
            throw(py_continue)
    end.

collect_yield_try(Body, Handlers, ElseBody, FinallyBody, Env0) ->
    Result =
        try collect_yields(Body, Env0, []) of
            {BodyValues, Env1} ->
                case ElseBody of
                    [] ->
                        {normal, BodyValues, Env1};
                    _ ->
                        {ElseValues, ElseEnv} = collect_yields(ElseBody, Env1, []),
                        {normal, BodyValues ++ ElseValues, ElseEnv}
                end
        catch
            throw:{py_exception, Exception} ->
                collect_yield_handle_exception(Exception, Handlers, Env0);
            throw:{py_generator_return, Values, ReturnEnv} ->
                {generator_return, Values, ReturnEnv}
        end,
    collect_yield_finally(Result, FinallyBody).

collect_yield_handle_exception(Exception, [], _Env) ->
    pyrlang_exception:raise(Exception);
collect_yield_handle_exception(Exception, [{Pattern, Binding, Body} | Rest], Env0) ->
    case exception_pattern_matches(Pattern, Exception, Env0) of
        true ->
            PreviousException = maps:find(?CURRENT_EXCEPTION_KEY, Env0),
            HandlerEnv = Env0#{?CURRENT_EXCEPTION_KEY => Exception},
            Env1 =
                case Binding of
                    undefined -> HandlerEnv;
                    Name -> HandlerEnv#{Name => Exception}
                end,
            with_process_exception(Exception, fun() ->
                try collect_yields(Body, Env1, []) of
                    {Values, Env2} ->
                        {normal, Values, restore_current_exception(Env2, PreviousException)}
                catch
                    throw:{py_generator_return, Values, ReturnEnv} ->
                        {generator_return, Values,
                            restore_current_exception(ReturnEnv, PreviousException)};
                    throw:{py_exception, NewException} ->
                        pyrlang_exception:raise(NewException)
                end
            end);
        false ->
            collect_yield_handle_exception(Exception, Rest, Env0)
    end.

collect_yield_finally({normal, Values, Env}, []) ->
    {Values, Env};
collect_yield_finally({generator_return, Values, Env}, []) ->
    throw({py_generator_return, Values, Env});
collect_yield_finally({normal, Values, Env}, FinallyBody) ->
    case contains_yield(FinallyBody) of
        false -> {Values, Env};
        true -> collect_yield_finally_with_yields(normal, Values, Env, FinallyBody)
    end;
collect_yield_finally({generator_return, Values, Env}, FinallyBody) ->
    case contains_yield(FinallyBody) of
        false -> throw({py_generator_return, Values, Env});
        true -> collect_yield_finally_with_yields(generator_return, Values, Env, FinallyBody)
    end.

collect_yield_finally_with_yields(Kind, Values, Env, FinallyBody) ->
    try collect_yields(FinallyBody, Env, []) of
        {FinallyValues, FinallyEnv} ->
            Combined = Values ++ FinallyValues,
            case Kind of
                normal -> {Combined, FinallyEnv};
                generator_return -> throw({py_generator_return, Combined, FinallyEnv})
            end
    catch
        throw:{py_generator_return, FinallyValues, FinallyEnv} ->
            throw({py_generator_return, Values ++ FinallyValues, FinallyEnv});
        throw:{py_exception, Exception} ->
            pyrlang_exception:raise(Exception)
    end.

eval_imports([], Env, Last) ->
    {Last, Env};
eval_imports([{ModuleName, Alias, explicit} | Rest], Env0, _Last) ->
    Module = pyrlang_module:load(ModuleName),
    eval_imports(Rest, Env0#{Alias => Module}, Module);
eval_imports([{ModuleName, Alias, default} | Rest], Env0, _Last) ->
    Module = pyrlang_module:load(ModuleName),
    Bound =
        case binary:split(ModuleName, <<".">>) of
            [Alias, _Rest] -> pyrlang_module:load(Alias);
            [Alias] -> Module
        end,
    eval_imports(Rest, Env0#{Alias => Bound}, Module).

eval_from_import(ModuleName, star, Env0) ->
    ResolvedModuleName = resolve_import_name(ModuleName, Env0),
    Module = pyrlang_module:load(ResolvedModuleName),
    Public = star_import_bindings(Module),
    Env1 = maps:merge(Env0, Public),
    {Module, maybe_bind_relative_child_module(ModuleName, ResolvedModuleName, Module, Env0, Env1)};
eval_from_import(ModuleName, Specs, Env0) ->
    ResolvedModuleName = resolve_import_name(ModuleName, Env0),
    Module = pyrlang_module:load(ResolvedModuleName),
    Env1 = lists:foldl(
        fun({Name, Alias}, Env) ->
            Env#{Alias => get_from_import_attr(ResolvedModuleName, Module, Name)}
        end,
        Env0,
        Specs
    ),
    {Module, Env1}.

resolve_import_name(<<".", _/binary>> = ModuleName, Env) ->
    pyrlang_module:resolve_import_name(ModuleName, maps:get(<<"__package__">>, Env, none));
resolve_import_name(ModuleName, _Env) ->
    ModuleName.

get_from_import_attr(ModuleName, Module, Name) ->
    try
        pyrlang_module:get_attr(Module, Name)
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> ->
                    pyrlang_module:load(<<ModuleName/binary, ".", Name/binary>>);
                _ ->
                    pyrlang_exception:raise(Exception)
            end
    end.

is_private_name(<<"_", _/binary>>) ->
    true;
is_private_name(_Name) ->
    false.

star_import_bindings(Module) ->
    case module_all_names(Module) of
        {ok, Names} ->
            maps:from_list([{Name, pyrlang_module:get_attr(Module, Name)} || Name <- Names]);
        error ->
            maps:filter(
                fun(Name, _Value) -> not is_private_name(Name) end, pyrlang_module:env(Module)
            )
    end.

module_all_names(Module) ->
    try pyrlang_module:get_attr(Module, <<"__all__">>) of
        All -> {ok, [normalize_import_name(Name) || Name <- pyrlang_iter:values(All)]}
    catch
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> -> error;
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

normalize_import_name(Name) when is_binary(Name) ->
    Name;
normalize_import_name(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
normalize_import_name(Name) when is_list(Name) ->
    unicode:characters_to_binary(Name).

maybe_bind_relative_child_module(<<".", _/binary>>, ResolvedModuleName, Module, Env0, Env1) ->
    Parts = binary:split(ResolvedModuleName, <<".">>, [global]),
    case lists:droplast(Parts) of
        [] ->
            Env1;
        ParentParts ->
            ParentName = join_binary(ParentParts, <<".">>),
            case maps:get(<<"__name__">>, Env0, undefined) of
                ParentName ->
                    Env1#{lists:last(Parts) => Module};
                _ ->
                    Env1
            end
    end;
maybe_bind_relative_child_module(_ModuleName, _ResolvedModuleName, _Module, _Env0, Env1) ->
    Env1.

eval_try(Body, Handlers, ElseBody, FinallyBody, Env0) ->
    Result =
        try
            {Value, Env1} = eval_try_body(Body, Env0, none),
            case ElseBody of
                [] ->
                    {normal, Value, Env1};
                _ ->
                    {ElseValue, ElseEnv} = eval_statements(ElseBody, Env1, none),
                    {normal, ElseValue, ElseEnv}
            end
        catch
            throw:{py_exception_with_env, Exception, ExceptionEnv} ->
                handle_exception(Exception, Handlers, ExceptionEnv);
            throw:{py_exception, Exception} ->
                handle_exception(Exception, Handlers, Env0);
            throw:{py_return_with_env, ReturnValue, ReturnEnv} ->
                {return, ReturnValue, ReturnEnv};
            throw:{py_return, ReturnValue} ->
                {return, ReturnValue, Env0}
        end,
    run_finally(Result, FinallyBody).

eval_try_body([], Env, Last) ->
    {Last, Env};
eval_try_body([Statement | Rest], Env0, Last) ->
    try eval_statements([Statement], Env0, Last) of
        {Value, Env1} -> eval_try_body(Rest, Env1, Value)
    catch
        throw:{py_exception_with_env, Exception, ExceptionEnv} ->
            throw({py_exception_with_env, Exception, ExceptionEnv});
        throw:{py_exception, Exception} ->
            throw({py_exception_with_env, Exception, Env0});
        throw:{py_return, ReturnValue} ->
            throw({py_return_with_env, ReturnValue, Env0})
    end.

handle_exception(Exception, [], _Env) ->
    pyrlang_exception:raise(Exception);
handle_exception(Exception, [{Pattern, Binding, Body} | Rest], Env0) ->
    case exception_pattern_matches(Pattern, Exception, Env0) of
        true ->
            PreviousException = maps:find(?CURRENT_EXCEPTION_KEY, Env0),
            HandlerEnv = Env0#{?CURRENT_EXCEPTION_KEY => Exception},
            Env1 =
                case Binding of
                    undefined -> HandlerEnv;
                    Name -> HandlerEnv#{Name => Exception}
                end,
            with_process_exception(Exception, fun() ->
                try
                    {Value, Env2} = eval_statements(Body, Env1, none),
                    {normal, Value, restore_current_exception(Env2, PreviousException)}
                catch
                    throw:{py_return, ReturnValue} ->
                        {return, ReturnValue, restore_current_exception(Env1, PreviousException)};
                    throw:{py_exception, NewException} ->
                        pyrlang_exception:raise(NewException)
                end
            end);
        false ->
            handle_exception(Exception, Rest, Env0)
    end.

restore_current_exception(Env, {ok, Exception}) ->
    Env#{?CURRENT_EXCEPTION_KEY => Exception};
restore_current_exception(Env, error) ->
    maps:remove(?CURRENT_EXCEPTION_KEY, Env).

with_process_exception(Exception, Fun) ->
    Previous = erlang:get(?CURRENT_EXCEPTION_KEY),
    erlang:put(?CURRENT_EXCEPTION_KEY, Exception),
    try
        Fun()
    after
        restore_process_value(?CURRENT_EXCEPTION_KEY, Previous)
    end.

exception_pattern_matches(any, Exception, _Env) ->
    pyrlang_exception:is_exception(Exception);
exception_pattern_matches(PatternExpr, Exception, Env0) ->
    {Pattern, _Env1} = eval_expr(PatternExpr, Env0),
    pyrlang_exception:matches(Pattern, Exception).

run_finally({Kind, Value, Env} = Result, []) when Kind =:= normal; Kind =:= return ->
    case Result of
        {normal, _Value, _Env} -> {Value, Env};
        {return, ReturnValue, _ReturnEnv} -> throw({py_return, ReturnValue})
    end;
run_finally({Kind, Value, Env}, FinallyBody) ->
    try eval_statements(FinallyBody, Env, none) of
        {_FinallyValue, FinallyEnv} ->
            case Kind of
                normal -> {Value, FinallyEnv};
                return -> throw({py_return, Value})
            end
    catch
        throw:{py_return, ReturnValue} -> throw({py_return, ReturnValue});
        throw:{py_exception, Exception} -> pyrlang_exception:raise(Exception)
    end.

call_value({py_function, Params, Body, ClosureEnv} = Function, Args) ->
    trace_function_call(Function, Args),
    with_function_call_context(Function, fun() ->
        execute_function(Function, Params, Body, ClosureEnv, false, undefined, Args)
    end);
call_value({py_function, Params, Body, ClosureEnv, IsGenerator} = Function, Args) ->
    trace_function_call(Function, Args),
    with_function_call_context(Function, fun() ->
        execute_function(Function, Params, Body, ClosureEnv, IsGenerator, undefined, Args)
    end);
call_value({py_function, Params, Body, ClosureEnv, IsGenerator, OwnerClass} = Function, Args) ->
    trace_function_call(Function, Args),
    with_function_call_context(Function, fun() ->
        execute_function(Function, Params, Body, ClosureEnv, IsGenerator, OwnerClass, Args)
    end);
call_value({py_bound_method, Callable, Self}, {call_args, PosArgs, KwArgs}) ->
    call_value(Callable, {call_args, [Self | PosArgs], KwArgs});
call_value({py_bound_method, Callable, Self}, Args) ->
    call_value(Callable, [Self | Args]);
call_value({py_exception_type, _Type} = Type, {call_args, Args, KwArgs}) ->
    pyrlang_exception:make_args(Type, Args, KwArgs);
call_value({py_exception_type, _Type} = Type, Args) ->
    pyrlang_exception:make_args(Type, Args);
call_value({py_weakref, Target}, {call_args, [], KwArgs}) when map_size(KwArgs) =:= 0 ->
    Target;
call_value({py_weakref, Target}, []) ->
    Target;
call_value({py_weakref, _Target}, {call_args, Args, KwArgs}) ->
    erlang:error({arity_error, {weakref_call, length(Args), maps:size(KwArgs)}});
call_value({py_weakref, _Target}, Args) ->
    erlang:error({arity_error, {weakref_call, length(Args)}});
call_value({py_native_varargs, Fun}, {call_args, Args, KwArgs}) when
    is_function(Fun, 1), map_size(KwArgs) =:= 0
->
    Fun(Args);
call_value({py_native_varargs, _Fun}, {call_args, _Args, KwArgs}) when map_size(KwArgs) =/= 0 ->
    erlang:error({type_error, {unexpected_keyword_argument, maps:keys(KwArgs)}});
call_value({py_native_varargs, Fun}, Args) when is_function(Fun, 1), is_list(Args) ->
    Fun(Args);
call_value({py_native_varargs, Fun, _Bind}, Args) when is_function(Fun, 1) ->
    call_value({py_native_varargs, Fun}, Args);
call_value({py_native_callable, Fun}, {call_args, Args, KwArgs}) when
    is_function(Fun, 1), map_size(KwArgs) =:= 0
->
    Fun(Args);
call_value({py_native_callable, _Fun}, {call_args, _Args, KwArgs}) when map_size(KwArgs) =/= 0 ->
    erlang:error({type_error, {unexpected_keyword_argument, maps:keys(KwArgs)}});
call_value({py_native_callable, Fun}, Args) when is_function(Fun, 1), is_list(Args) ->
    Fun(Args);
call_value({py_native_callable, Fun, _Bind}, Args) when is_function(Fun, 1) ->
    call_value({py_native_callable, Fun}, Args);
call_value({py_native_call, Fun}, {call_args, Args, KwArgs}) when is_function(Fun, 2) ->
    Fun(Args, KwArgs);
call_value({py_native_call, Fun}, Args) when is_function(Fun, 2), is_list(Args) ->
    Fun(Args, #{});
call_value({py_native_call, Fun, _Bind}, Args) when is_function(Fun, 2) ->
    call_value({py_native_call, Fun}, Args);
call_value(Callee, Args) ->
    case is_class_ref(Callee) of
        true ->
            instantiate_class(Callee, Args);
        false ->
            case callable_object(Callee) of
                {ok, Call} -> call_value(Call, Args);
                error -> call_non_class(Callee, Args)
            end
    end.

with_function_call_context(Function, Fun) ->
    Previous = erlang:get(?FUNCTION_CALL_STACK_KEY),
    Stack =
        case Previous of
            Existing when is_list(Existing) -> Existing;
            _ -> []
        end,
    erlang:put(?FUNCTION_CALL_STACK_KEY, [Function | Stack]),
    try
        Fun()
    after
        restore_process_value(?FUNCTION_CALL_STACK_KEY, Previous)
    end.

callable_object({py_ref, _} = Ref) ->
    try pyrlang_object:get_attr(Ref, <<"__call__">>) of
        Call -> {ok, Call}
    catch
        error:{attribute_error, _Name} -> error
    end;
callable_object(_Other) ->
    error.

execute_function(Function, Params, Body, ClosureEnv, IsGenerator, OwnerClass, Args) ->
    Previous = erlang:get(?MODULE_EVAL_KEY),
    PreviousGlobalEnv = erlang:get(?FUNCTION_GLOBAL_ENV_KEY),
    erlang:put(?MODULE_EVAL_KEY, false),
    GlobalEnv = function_global_env(ClosureEnv),
    erlang:put(?FUNCTION_GLOBAL_ENV_KEY, GlobalEnv),
    try
        execute_function_body(
            Params,
            Body,
            function_execution_env(ClosureEnv, GlobalEnv, Function),
            IsGenerator,
            OwnerClass,
            Args
        )
    after
        restore_module_eval(Previous),
        restore_process_value(?FUNCTION_GLOBAL_ENV_KEY, PreviousGlobalEnv)
    end.

function_globals(ClosureEnv) ->
    function_global_env(ClosureEnv).

function_global_env(ClosureEnv) ->
    case maps:get(<<"__name__">>, ClosureEnv, undefined) of
        <<"__main__">> ->
            ClosureEnv;
        ModuleName when is_binary(ModuleName) ->
            function_global_module_env(ModuleName, ClosureEnv);
        _ ->
            case erlang:get(?FUNCTION_GLOBAL_ENV_KEY) of
                undefined -> ClosureEnv;
                Existing -> Existing
            end
    end.

function_global_module_env(ModuleName, ClosureEnv) ->
    case erlang:get(pyrlang_current_loading_module) of
        {py_ref, _} = ModuleRef ->
            try
                Data = pyrlang_heap:data(ModuleRef),
                CurrentEnv = maps:get(env, Data, #{}),
                case same_loading_module_env(Data, CurrentEnv, ClosureEnv) of
                    true ->
                        maps:merge(ClosureEnv, CurrentEnv);
                    false ->
                        case maps:get(<<"__name__">>, CurrentEnv, undefined) of
                            ModuleName -> CurrentEnv;
                            _ -> load_function_global_module_env(ModuleName, ClosureEnv)
                        end
                end
            catch
                _:_ -> load_function_global_module_env(ModuleName, ClosureEnv)
            end;
        _ ->
            load_function_global_module_env(ModuleName, ClosureEnv)
    end.

load_function_global_module_env(ModuleName, ClosureEnv) ->
    try
        Data = pyrlang_heap:data(pyrlang_module:load(ModuleName)),
        maps:get(env, Data, ClosureEnv)
    catch
        _:_ -> ClosureEnv
    end.

same_loading_module_env(Data, CurrentEnv, ClosureEnv) ->
    ClosureFile = maps:get(<<"__file__">>, ClosureEnv, undefined),
    ClosureFile =/= undefined andalso
        (ClosureFile =:= maps:get(<<"__file__">>, CurrentEnv, undefined) orelse
            ClosureFile =:= maps:get(path, Data, undefined)).

function_execution_env(ClosureEnv, GlobalEnv, Function) ->
    Env =
        case maps:get(?MODULE_CLOSURE_MARKER, ClosureEnv, false) of
            true ->
                maps:merge(GlobalEnv, module_closure_locals(ClosureEnv, GlobalEnv));
            false ->
                maps:merge(GlobalEnv, ClosureEnv)
        end,
    function_self_env(Function, Env).

function_self_env(Function, Env) ->
    Env1 =
        case function_lexical_name(Function) of
            LexicalName when is_binary(LexicalName) -> Env#{LexicalName => Function};
            _ -> Env
        end,
    try pyrlang_object:get_attr(Function, <<"__name__">>) of
        Name when is_binary(Name) ->
            case maps:is_key(Name, Env1) of
                true -> Env1;
                false -> Env1#{Name => Function}
            end;
        _Other ->
            Env1
    catch
        _:_ -> Env1
    end.

function_lexical_name({py_function, _Params, _Body, ClosureEnv}) ->
    maps:get(?FUNCTION_LEXICAL_NAME_KEY, ClosureEnv, undefined);
function_lexical_name({py_function, _Params, _Body, ClosureEnv, _Mode}) ->
    maps:get(?FUNCTION_LEXICAL_NAME_KEY, ClosureEnv, undefined);
function_lexical_name({py_function, _Params, _Body, ClosureEnv, _Mode, _OwnerClass}) ->
    case maps:get(?MODULE_CLOSURE_MARKER, ClosureEnv, false) of
        true -> undefined;
        false -> maps:get(?FUNCTION_LEXICAL_NAME_KEY, ClosureEnv, undefined)
    end;
function_lexical_name(_Function) ->
    undefined.

module_closure_locals(ClosureEnv, GlobalEnv) ->
    maps:filter(
        fun(Name, _Value) ->
            Name =/= ?MODULE_CLOSURE_MARKER andalso not maps:is_key(Name, GlobalEnv)
        end,
        ClosureEnv
    ).

execute_function_body(Params, Body, ClosureEnv, IsGenerator, OwnerClass, Args) ->
    {PosArgs, KwArgs} = normalize_call_args(Args),
    case bind_arguments(Params, PosArgs, KwArgs, ClosureEnv) of
        {ok, LocalEnv0} ->
            LocalEnv = mark_function_local_names(Params, LocalEnv0),
            with_function_env(LocalEnv, fun() ->
                with_method_context(OwnerClass, PosArgs, fun() ->
                    case IsGenerator of
                        true ->
                            {Values, _Env} = collect_generator_values(Body, LocalEnv),
                            pyrlang_generator:from_values(Values);
                        async ->
                            {py_coroutine, Body, LocalEnv, OwnerClass, PosArgs};
                        async_generator ->
                            {py_async_generator, Body, LocalEnv, OwnerClass, PosArgs};
                        false ->
                            try eval_statements(Body, LocalEnv, none) of
                                {_Value, _Env} -> none
                            catch
                                throw:{py_return, Value} ->
                                    Value;
                                throw:{py_exception_with_env, Exception, _ExceptionEnv} ->
                                    pyrlang_exception:raise(Exception)
                            end
                    end
                end)
            end);
        {error, Reason} ->
            trace_bind_error(Params, PosArgs, KwArgs, Reason),
            erlang:error(Reason)
    end.

mark_function_local_names(Params, Env) ->
    Existing = maps:get(?LOCAL_CLOSURE_NAMES, Env, []),
    Names = [Name || Name <- function_param_names(Params), Name =/= undefined],
    Env#{?LOCAL_CLOSURE_NAMES => lists:usort(Existing ++ Names)}.

function_param_names([]) ->
    [];
function_param_names([{param, Name, _Default, _Annotation} | Rest]) ->
    [Name | function_param_names(Rest)];
function_param_names([{param, Name, _Default} | Rest]) ->
    [Name | function_param_names(Rest)];
function_param_names([{vararg, Name, _Annotation} | Rest]) ->
    [Name | function_param_names(Rest)];
function_param_names([{vararg, Name} | Rest]) ->
    [Name | function_param_names(Rest)];
function_param_names([{kwarg_rest, Name, _Annotation} | Rest]) ->
    [Name | function_param_names(Rest)];
function_param_names([{kwarg_rest, Name} | Rest]) ->
    [Name | function_param_names(Rest)];
function_param_names([_Marker | Rest]) ->
    function_param_names(Rest).

collect_generator_values(Body, Env) ->
    try collect_yields(Body, Env, []) of
        {Values, FinalEnv} -> {Values, FinalEnv}
    catch
        throw:{py_generator_return, Values, ReturnEnv} -> {Values, ReturnEnv}
    end.

contextmanager_start({py_function, Params, Body, ClosureEnv, true} = Function, Args) ->
    contextmanager_start_function(Function, Params, Body, ClosureEnv, undefined, Args);
contextmanager_start({py_function, Params, Body, ClosureEnv, true, OwnerClass} = Function, Args) ->
    contextmanager_start_function(Function, Params, Body, ClosureEnv, OwnerClass, Args);
contextmanager_start(Function, Args) ->
    Value = call_value(Function, Args),
    {done, Value, #{}}.

contextmanager_start_function(Function, Params, Body, ClosureEnv, OwnerClass, Args) ->
    trace_function_call(Function, Args),
    with_function_call_context(Function, fun() ->
        Previous = erlang:get(?MODULE_EVAL_KEY),
        PreviousGlobalEnv = erlang:get(?FUNCTION_GLOBAL_ENV_KEY),
        erlang:put(?MODULE_EVAL_KEY, false),
        GlobalEnv = function_global_env(ClosureEnv),
        erlang:put(?FUNCTION_GLOBAL_ENV_KEY, GlobalEnv),
        try
            Env = function_execution_env(ClosureEnv, GlobalEnv, Function),
            {PosArgs, KwArgs} = normalize_call_args(Args),
            case bind_arguments(Params, PosArgs, KwArgs, Env) of
                {ok, LocalEnv0} ->
                    LocalEnv = mark_function_local_names(Params, LocalEnv0),
                    with_function_env(LocalEnv, fun() ->
                        with_method_context(OwnerClass, PosArgs, fun() ->
                            contextmanager_run(Body, LocalEnv, none, [])
                        end)
                    end);
                {error, Reason} ->
                    trace_bind_error(Params, PosArgs, KwArgs, Reason),
                    erlang:error(Reason)
            end
        after
            restore_module_eval(Previous),
            restore_process_value(?FUNCTION_GLOBAL_ENV_KEY, PreviousGlobalEnv)
        end
    end).

contextmanager_resume(
    #{statements := Statements, env := Env, last := Last, stack := Stack}, normal
) ->
    contextmanager_run(Statements, Env, Last, Stack);
contextmanager_resume(#{env := Env, stack := Stack}, {throw, Exception}) ->
    case contextmanager_throw(Exception, Env, Stack) of
        {propagate, _PropagatedException, _PropagatedEnv} -> {done, false, Env};
        {handled, {done, _Last, HandledEnv}} -> {done, true, HandledEnv};
        {handled, {yielded, Value, Frame}} -> {yielded, Value, Frame}
    end.

contextmanager_run([], Env, Last, Stack) ->
    contextmanager_continue(Stack, Env, Last);
contextmanager_run([{yield, Expr} | Rest], Env0, _Last, Stack) ->
    {Value, Env1} = eval_expr(Expr, Env0),
    {yielded, Value, #{statements => Rest, env => Env1, last => Value, stack => Stack}};
contextmanager_run(
    [{try_stmt, Body, Handlers, ElseBody, FinallyBody} = Statement | Rest], Env0, Last, Stack
) ->
    case statement_contains_yield(Statement) of
        true ->
            contextmanager_run(Body, Env0, none, [
                {try_context, Handlers, ElseBody, FinallyBody, Rest} | Stack
            ]);
        false ->
            {Value, Env1} = eval_statements([Statement], Env0, Last),
            contextmanager_run(Rest, Env1, Value, Stack)
    end;
contextmanager_run([{if_stmt, Condition, ThenBody, ElseBody} | Rest], Env0, _Last, Stack) ->
    {ConditionValue, Env1} = eval_expr(Condition, Env0),
    BranchBody =
        case truthy(ConditionValue) of
            true -> ThenBody;
            false -> ElseBody
        end,
    contextmanager_run(BranchBody ++ Rest, Env1, none, Stack);
contextmanager_run([{with_stmt, ManagerExpr, Binding, Body} | Rest], Env0, _Last, Stack) ->
    {Manager, Env1} = eval_expr(ManagerExpr, Env0),
    Enter = pyrlang_object:get_attr(Manager, <<"__enter__">>),
    Exit = pyrlang_object:get_attr(Manager, <<"__exit__">>),
    Entered = call_value(Enter, []),
    BodyEnv =
        case Binding of
            undefined -> Env1;
            Target -> bind_assignment_target(Target, Entered, Env1)
        end,
    contextmanager_run(Body, BodyEnv, none, [{with_context, Exit, Rest} | Stack]);
contextmanager_run([{return, _Expr} | _Rest], Env, Last, Stack) ->
    contextmanager_return(Env, Last, Stack);
contextmanager_run([Statement | Rest], Env0, Last, Stack) ->
    case statement_contains_yield(Statement) of
        false ->
            {Value, Env1} = eval_statements([Statement], Env0, Last),
            contextmanager_run(Rest, Env1, Value, Stack);
        true ->
            erlang:error({unsupported_contextmanager_yield_statement, Statement})
    end.

contextmanager_continue([], Env, Last) ->
    {done, Last, Env};
contextmanager_continue([{try_context, _Handlers, ElseBody, FinallyBody, Rest} | Stack], Env, Last) ->
    contextmanager_run(ElseBody ++ FinallyBody ++ Rest, Env, Last, Stack);
contextmanager_continue([{with_context, Exit, Rest} | Stack], Env, Last) ->
    _ = call_value(Exit, [none, none, none]),
    contextmanager_run(Rest, Env, Last, Stack).

contextmanager_return(Env, Last, []) ->
    {done, Last, Env};
contextmanager_return(Env, Last, [{with_context, Exit, _Rest} | Stack]) ->
    _ = call_value(Exit, [none, none, none]),
    contextmanager_return(Env, Last, Stack);
contextmanager_return(Env, Last, [{try_context, _Handlers, _ElseBody, FinallyBody, _Rest} | Stack]) ->
    {FinallyLast, FinallyEnv} = eval_statements(FinallyBody, Env, Last),
    contextmanager_return(FinallyEnv, FinallyLast, Stack).

contextmanager_throw(Exception, Env, []) ->
    {propagate, Exception, Env};
contextmanager_throw(Exception, Env, [{with_context, Exit, Rest} | Stack]) ->
    Suppressed = call_value(Exit, [pyrlang_exception:exception_type(Exception), Exception, none]),
    case truthy(Suppressed) of
        true -> {handled, contextmanager_run(Rest, Env, none, Stack)};
        false -> contextmanager_throw(Exception, Env, Stack)
    end;
contextmanager_throw(Exception, Env, [{try_context, Handlers, _ElseBody, FinallyBody, Rest} | Stack]) ->
    contextmanager_throw_try(Exception, Handlers, Env, FinallyBody, Rest, Stack).

contextmanager_throw_try(Exception, [], Env, FinallyBody, _Rest, Stack) ->
    {_, FinallyEnv} = eval_statements(FinallyBody, Env, none),
    contextmanager_throw(Exception, FinallyEnv, Stack);
contextmanager_throw_try(
    Exception, [{Pattern, Binding, Body} | Handlers], Env, FinallyBody, Rest, Stack
) ->
    case exception_pattern_matches(Pattern, Exception, Env) of
        true ->
            PreviousException = maps:find(?CURRENT_EXCEPTION_KEY, Env),
            HandlerEnv = Env#{?CURRENT_EXCEPTION_KEY => Exception},
            Env1 =
                case Binding of
                    undefined -> HandlerEnv;
                    Name -> HandlerEnv#{Name => Exception}
                end,
            with_process_exception(Exception, fun() ->
                try eval_statements(Body, Env1, none) of
                    {Value, Env2} ->
                        RestoredEnv = restore_current_exception(Env2, PreviousException),
                        {handled,
                            contextmanager_run(FinallyBody ++ Rest, RestoredEnv, Value, Stack)}
                catch
                    throw:{py_exception, RaisedException} ->
                        {_, FinallyEnv} = eval_statements(
                            FinallyBody, restore_current_exception(Env1, PreviousException), none
                        ),
                        case RaisedException =:= Exception of
                            true -> contextmanager_throw(Exception, FinallyEnv, Stack);
                            false -> pyrlang_exception:raise(RaisedException)
                        end
                end
            end);
        false ->
            contextmanager_throw_try(Exception, Handlers, Env, FinallyBody, Rest, Stack)
    end.

normalize_call_args({call_args, PosArgs, KwArgs}) ->
    {PosArgs, KwArgs};
normalize_call_args(Args) when is_list(Args) ->
    {Args, #{}}.

with_function_env(Env, Fun) ->
    Previous = erlang:get(?FUNCTION_ENV_STACK_KEY),
    Stack =
        case Previous of
            Existing when is_list(Existing) -> Existing;
            _ -> []
        end,
    erlang:put(?FUNCTION_ENV_STACK_KEY, [Env | Stack]),
    try
        Fun()
    after
        restore_process_value(?FUNCTION_ENV_STACK_KEY, Previous)
    end.

trace_bind_error(Params, PosArgs, KwArgs, Reason) ->
    case os:getenv("PYRLANG_TRACE_BIND") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_BIND_ERROR reason=~p params=~p pos_types=~p kwargs=~p~n",
                [Reason, Params, [describe_attr_object(Arg) || Arg <- PosArgs], maps:keys(KwArgs)]
            )
    end.

prepare_params_with_env(Params, Env) ->
    prepare_params_with_env(Params, Env, []).

prepare_params_with_env([], Env, Acc) ->
    {lists:reverse(Acc), Env};
prepare_params_with_env([Param | Rest], Env0, Acc) ->
    {PreparedParam, Env1} = prepare_param_with_env(Param, Env0),
    prepare_params_with_env(Rest, Env1, [PreparedParam | Acc]).

prepare_param_with_env({param, Name, undefined}, Env) ->
    {{param, Name, undefined}, Env};
prepare_param_with_env({param, Name, undefined, AnnotationExpr}, Env0) ->
    {Annotation, Env1} = prepare_annotation_with_env(AnnotationExpr, Env0),
    {{param, Name, undefined, Annotation}, Env1};
prepare_param_with_env({param, Name, DefaultExpr}, Env0) ->
    {DefaultValue, Env1} = eval_expr(DefaultExpr, Env0),
    {{param, Name, {default, DefaultValue}}, Env1};
prepare_param_with_env({param, Name, DefaultExpr, AnnotationExpr}, Env0) ->
    {DefaultValue, Env1} = eval_expr(DefaultExpr, Env0),
    {Annotation, Env2} = prepare_annotation_with_env(AnnotationExpr, Env1),
    {{param, Name, {default, DefaultValue}, Annotation}, Env2};
prepare_param_with_env({vararg, Name, AnnotationExpr}, Env0) ->
    {Annotation, Env1} = prepare_annotation_with_env(AnnotationExpr, Env0),
    {{vararg, Name, Annotation}, Env1};
prepare_param_with_env({vararg, Name}, Env) ->
    {{vararg, Name}, Env};
prepare_param_with_env({kwarg_rest, Name, AnnotationExpr}, Env0) ->
    {Annotation, Env1} = prepare_annotation_with_env(AnnotationExpr, Env0),
    {{kwarg_rest, Name, Annotation}, Env1};
prepare_param_with_env({kwarg_rest, Name}, Env) ->
    {{kwarg_rest, Name}, Env};
prepare_param_with_env(posonly_marker, Env) ->
    {posonly_marker, Env};
prepare_param_with_env(kwonly_marker, Env) ->
    {kwonly_marker, Env};
prepare_param_with_env(Name, Env) when is_binary(Name) ->
    {{param, Name, undefined}, Env}.

prepare_annotation_with_env(undefined, Env) ->
    {undefined, Env};
prepare_annotation_with_env(AnnotationExpr, Env0) ->
    try
        eval_expr(AnnotationExpr, Env0)
    catch
        _:_ -> {undefined, Env0}
    end.

make_function(Name, Params, Body, ClosureEnv, DefaultsEnv, Mode) ->
    {Function, _DefaultsEnv1} = make_function_with_env(
        Name, Params, Body, ClosureEnv, DefaultsEnv, Mode
    ),
    Function.

make_function_with_env(Name, Params, Body, Env, Mode) ->
    make_function_with_env(Name, Params, Body, Env, Env, Mode).

make_function_with_env(Name, Params, Body, ClosureEnv, DefaultsEnv, Mode) ->
    {PreparedParams, DefaultsEnv1} = prepare_params_with_env(Params, DefaultsEnv),
    CapturedEnv =
        case DefaultsEnv of
            ClosureEnv -> DefaultsEnv1;
            _ -> ClosureEnv
        end,
    Closure = function_closure_env((capture_closure_env(CapturedEnv))#{
        ?FUNCTION_LEXICAL_NAME_KEY => Name
    }),
    Function = {py_function, PreparedParams, Body, Closure, Mode},
    ok = pyrlang_object:set_attr(Function, <<"__name__">>, Name),
    ok = pyrlang_object:set_attr(Function, <<"__qualname__">>, Name),
    ok = pyrlang_object:set_attr(
        Function, <<"__annotations__">>, function_annotations(PreparedParams)
    ),
    {Function, DefaultsEnv1}.

function_annotations(Params) ->
    pyrlang_heap:dict(function_annotation_items(Params)).

function_annotation_items([]) ->
    [];
function_annotation_items([{param, Name, _Default, Annotation} | Rest]) ->
    function_annotation_item(Name, Annotation, Rest);
function_annotation_items([{vararg, Name, Annotation} | Rest]) ->
    function_annotation_item(Name, Annotation, Rest);
function_annotation_items([{kwarg_rest, Name, Annotation} | Rest]) ->
    function_annotation_item(Name, Annotation, Rest);
function_annotation_items([_Param | Rest]) ->
    function_annotation_items(Rest).

function_annotation_item(_Name, undefined, Rest) ->
    function_annotation_items(Rest);
function_annotation_item(Name, Annotation, Rest) ->
    [{Name, Annotation} | function_annotation_items(Rest)].

bind_arguments(Params, PosArgs, KwArgs, ClosureEnv) ->
    case parameter_specs(Params) of
        {ok, Specs, VarArgName, KwRestName} ->
            case bind_positional(Specs, PosArgs, #{}, KwArgs) of
                {ok, Bound0, RemainingSpecs, ExtraPosArgs, KwArgs1} ->
                    case bind_remaining(RemainingSpecs, KwArgs1, Bound0) of
                        {ok, Bound1, RemainingKw} ->
                            bind_extras(
                                ExtraPosArgs,
                                RemainingKw,
                                VarArgName,
                                KwRestName,
                                maps:merge(ClosureEnv, Bound1)
                            );
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parameter_specs(Params) ->
    parameter_specs(Params, poskw, [], undefined, undefined).

parameter_specs([], _Section, Specs, VarArgName, KwRestName) ->
    {ok, lists:reverse(Specs), VarArgName, KwRestName};
parameter_specs(
    [{param, Name, Default, _Annotation} | Rest], Section, Specs, VarArgName, KwRestName
) ->
    parameter_specs(Rest, Section, [{Section, Name, Default} | Specs], VarArgName, KwRestName);
parameter_specs([{param, Name, Default} | Rest], Section, Specs, VarArgName, KwRestName) ->
    parameter_specs(Rest, Section, [{Section, Name, Default} | Specs], VarArgName, KwRestName);
parameter_specs([posonly_marker | Rest], poskw, Specs, VarArgName, KwRestName) ->
    parameter_specs(Rest, poskw, mark_positional_only(Specs), VarArgName, KwRestName);
parameter_specs([posonly_marker | _Rest], Section, _Specs, _VarArgName, _KwRestName) ->
    {error, {type_error, {invalid_positional_only_marker, Section}}};
parameter_specs([kwonly_marker | Rest], Section, Specs, undefined, KwRestName) when
    Section =/= kwonly
->
    parameter_specs(Rest, kwonly, Specs, undefined, KwRestName);
parameter_specs([kwonly_marker | _Rest], _Section, _Specs, VarArgName, _KwRestName) ->
    {error, {type_error, {invalid_keyword_only_marker, VarArgName}}};
parameter_specs([{vararg, Name, _Annotation} | Rest], _Section, Specs, undefined, KwRestName) ->
    parameter_specs(Rest, kwonly, Specs, Name, KwRestName);
parameter_specs([{vararg, Name} | Rest], _Section, Specs, undefined, KwRestName) ->
    parameter_specs(Rest, kwonly, Specs, Name, KwRestName);
parameter_specs([{vararg, Name, _Annotation} | _Rest], _Section, _Specs, _VarArgName, _KwRestName) ->
    {error, {type_error, {duplicate_vararg, Name}}};
parameter_specs([{vararg, Name} | _Rest], _Section, _Specs, _VarArgName, _KwRestName) ->
    {error, {type_error, {duplicate_vararg, Name}}};
parameter_specs([{kwarg_rest, Name, _Annotation} | Rest], Section, Specs, VarArgName, undefined) ->
    parameter_specs(Rest, Section, Specs, VarArgName, Name);
parameter_specs([{kwarg_rest, Name} | Rest], Section, Specs, VarArgName, undefined) ->
    parameter_specs(Rest, Section, Specs, VarArgName, Name);
parameter_specs(
    [{kwarg_rest, Name, _Annotation} | _Rest], _Section, _Specs, _VarArgName, _KwRestName
) ->
    {error, {type_error, {duplicate_kwarg_rest, Name}}};
parameter_specs([{kwarg_rest, Name} | _Rest], _Section, _Specs, _VarArgName, _KwRestName) ->
    {error, {type_error, {duplicate_kwarg_rest, Name}}}.

mark_positional_only(Specs) ->
    [mark_positional_only_spec(Spec) || Spec <- Specs].

mark_positional_only_spec({poskw, Name, Default}) ->
    {posonly, Name, Default};
mark_positional_only_spec(Spec) ->
    Spec.

bind_positional(Specs, [], Bound, KwArgs) ->
    {ok, Bound, Specs, [], KwArgs};
bind_positional([], PosArgs, Bound, KwArgs) ->
    {ok, Bound, [], PosArgs, KwArgs};
bind_positional([{kwonly, _Name, _Default} | _Rest] = Specs, PosArgs, Bound, KwArgs) ->
    {ok, Bound, Specs, PosArgs, KwArgs};
bind_positional([{posonly, Name, _Default} | Rest], [Value | Values], Bound, KwArgs) ->
    bind_positional(Rest, Values, Bound#{Name => Value}, KwArgs);
bind_positional([{poskw, Name, _Default} | Rest], [Value | Values], Bound, KwArgs) ->
    case maps:is_key(Name, KwArgs) of
        true -> {error, {type_error, {multiple_values_for_argument, Name}}};
        false -> bind_positional(Rest, Values, Bound#{Name => Value}, KwArgs)
    end.

bind_remaining([], KwArgs, Env) ->
    {ok, Env, KwArgs};
bind_remaining([{posonly, Name, Default} | Rest], KwArgs0, Env0) ->
    case Default of
        {default, Value} -> bind_remaining(Rest, KwArgs0, Env0#{Name => Value});
        undefined -> {error, {arity_error, {missing_required_argument, Name}}}
    end;
bind_remaining([{Kind, Name, Default} | Rest], KwArgs0, Env0) when
    Kind =:= poskw; Kind =:= kwonly
->
    case maps:take(Name, KwArgs0) of
        {Value, KwArgs1} ->
            bind_remaining(Rest, KwArgs1, Env0#{Name => Value});
        error ->
            case Default of
                {default, Value} -> bind_remaining(Rest, KwArgs0, Env0#{Name => Value});
                undefined -> {error, {arity_error, {missing_required_argument, Name}}}
            end
    end.

bind_extras([], RemainingKw, undefined, undefined, Env) ->
    case maps:to_list(RemainingKw) of
        [] -> {ok, Env};
        [{Name, _Value} | _] -> {error, {type_error, {unexpected_keyword_argument, Name}}}
    end;
bind_extras([], RemainingKw, undefined, KwRestName, Env) ->
    {ok, Env#{KwRestName => pyrlang_heap:dict(RemainingKw)}};
bind_extras(ExtraPosArgs, _RemainingKw, undefined, _KwRestName, _Env) ->
    {error, {arity_error, {too_many_positional_arguments, length(ExtraPosArgs)}}};
bind_extras(ExtraPosArgs, RemainingKw, VarArgName, undefined, Env) ->
    case maps:to_list(RemainingKw) of
        [] -> {ok, Env#{VarArgName => list_to_tuple(ExtraPosArgs)}};
        [{Name, _Value} | _] -> {error, {type_error, {unexpected_keyword_argument, Name}}}
    end;
bind_extras(ExtraPosArgs, RemainingKw, VarArgName, KwRestName, Env) ->
    {ok, Env#{
        VarArgName => list_to_tuple(ExtraPosArgs),
        KwRestName => pyrlang_heap:dict(RemainingKw)
    }}.

with_method_context(undefined, _Args, Fun) ->
    Fun();
with_method_context(_OwnerClass, [], Fun) ->
    Fun();
with_method_context(OwnerClass, [Self | _], Fun) ->
    PreviousClass = erlang:get(pyrlang_current_class),
    PreviousSelf = erlang:get(pyrlang_current_self),
    erlang:put(pyrlang_current_class, OwnerClass),
    erlang:put(pyrlang_current_self, Self),
    try
        Fun()
    after
        restore_process_value(pyrlang_current_class, PreviousClass),
        restore_process_value(pyrlang_current_self, PreviousSelf)
    end.

restore_process_value(Key, undefined) ->
    erlang:erase(Key);
restore_process_value(Key, Value) ->
    erlang:put(Key, Value).

call_non_class(Fun, {call_args, Args, KwArgs}) when is_function(Fun), map_size(KwArgs) =:= 0 ->
    apply(Fun, Args);
call_non_class(Fun, {call_args, _Args, KwArgs}) when is_function(Fun) ->
    trace_unexpected_fun_kwargs(Fun, KwArgs),
    erlang:error({type_error, {unexpected_keyword_argument, maps:keys(KwArgs)}});
call_non_class(Fun, Args) when is_function(Fun) ->
    apply(Fun, Args);
call_non_class(Other, _Args) ->
    trace_not_callable(Other),
    erlang:error({not_callable, Other}).

trace_not_callable(Other) ->
    case os:getenv("PYRLANG_TRACE_NOT_CALLABLE") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_NOT_CALLABLE value=~p stack=~p~n",
                [describe_attr_object(Other), trace_function_stack()]
            )
    end.

trace_unexpected_fun_kwargs(Fun, KwArgs) ->
    case os:getenv("PYRLANG_TRACE_NATIVE_KW") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_NATIVE_KW fun=~p kw=~p stack=~p~n",
                [erlang:fun_info(Fun), maps:keys(KwArgs), trace_function_stack()]
            )
    end.

trace_function_call(Function, Args0) ->
    case os:getenv("PYRLANG_TRACE_CALLS") of
        false ->
            ok;
        Value ->
            Step = trace_step(Value),
            Count = erlang:get(pyrlang_trace_call_count),
            Next =
                case Count of
                    undefined -> 1;
                    N when is_integer(N) -> N + 1;
                    _ -> 1
                end,
            erlang:put(pyrlang_trace_call_count, Next),
            case Next rem Step of
                0 ->
                    {PosArgs, KwArgs} = normalize_call_args(Args0),
                    io:format(
                        standard_error,
                        "PYRLANG_CALL ~B ~s.~s pos=~p kw=~p~n",
                        [
                            Next,
                            trace_function_attr(Function, <<"__module__">>),
                            trace_function_attr(Function, <<"__qualname__">>),
                            [describe_attr_object(Arg) || Arg <- PosArgs],
                            maps:keys(KwArgs)
                        ]
                    );
                _ ->
                    ok
            end
    end.

trace_step(Value) ->
    try list_to_integer(Value) of
        N when N > 0 -> N;
        _ -> 10000
    catch
        _:_ -> 10000
    end.

trace_function_attr(Function, Name) ->
    try pyrlang_object:get_attr(Function, Name) of
        Value when is_binary(Value) -> Value;
        Value -> unicode:characters_to_binary(io_lib:format("~p", [Value]))
    catch
        _:_ -> <<"?">>
    end.

eval_class_body([], _Env, Attrs) ->
    Attrs;
eval_class_body([{def, Name, Params, Body} | Rest], Env, Attrs) ->
    Function = make_function(Name, Params, Body, Env, maps:merge(Env, Attrs), contains_yield(Body)),
    eval_class_body(Rest, Env, put_class_attr(Name, Function, Attrs));
eval_class_body([{def, Name, Params, Body, Decorators} | Rest], Env0, Attrs) ->
    Function = make_function(
        Name, Params, Body, Env0, maps:merge(Env0, Attrs), contains_yield(Body)
    ),
    {Decorated, Env1} = apply_decorators(Decorators, Function, maps:merge(Env0, Attrs)),
    eval_class_body(Rest, Env1, put_class_attr(Name, Decorated, Attrs));
eval_class_body([{async_def, Name, Params, Body} | Rest], Env, Attrs) ->
    Function = make_function(Name, Params, Body, Env, maps:merge(Env, Attrs), async_mode(Body)),
    eval_class_body(Rest, Env, put_class_attr(Name, Function, Attrs));
eval_class_body([{async_def, Name, Params, Body, Decorators} | Rest], Env0, Attrs) ->
    Function = make_function(Name, Params, Body, Env0, maps:merge(Env0, Attrs), async_mode(Body)),
    {Decorated, Env1} = apply_decorators(Decorators, Function, maps:merge(Env0, Attrs)),
    eval_class_body(Rest, Env1, put_class_attr(Name, Decorated, Attrs));
eval_class_body([{class, Name, BaseExprs, MetaclassExpr, Body} | Rest], Env0, Attrs) ->
    {Class, Env1} = create_class(Name, BaseExprs, MetaclassExpr, [], Body, maps:merge(Env0, Attrs)),
    eval_class_body(Rest, Env1, put_class_attr(Name, Class, Attrs));
eval_class_body([{class, Name, BaseExprs, MetaclassExpr, Body, Decorators} | Rest], Env0, Attrs) ->
    {Class, Env1} = create_class(Name, BaseExprs, MetaclassExpr, [], Body, maps:merge(Env0, Attrs)),
    {Decorated, Env2} = apply_decorators(Decorators, Class, maps:merge(Env1, Attrs)),
    eval_class_body(Rest, Env2, put_class_attr(Name, Decorated, Attrs));
eval_class_body(
    [{class, Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, []} | Rest], Env0, Attrs
) ->
    {Class, Env1} = create_class(
        Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, maps:merge(Env0, Attrs)
    ),
    eval_class_body(Rest, Env1, put_class_attr(Name, Class, Attrs));
eval_class_body(
    [{class, Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, Decorators} | Rest], Env0, Attrs
) ->
    {Class, Env1} = create_class(
        Name, BaseExprs, MetaclassExpr, ClassKwExprs, Body, maps:merge(Env0, Attrs)
    ),
    {Decorated, Env2} = apply_decorators(Decorators, Class, maps:merge(Env1, Attrs)),
    eval_class_body(Rest, Env2, put_class_attr(Name, Decorated, Attrs));
eval_class_body([{if_stmt, Condition, ThenBody, ElseBody} | Rest], Env0, Attrs0) ->
    {ConditionValue, Env1} = eval_expr(Condition, maps:merge(Env0, Attrs0)),
    Body =
        case truthy(ConditionValue) of
            true -> ThenBody;
            false -> ElseBody
        end,
    Attrs1 = eval_class_body(Body, Env1, Attrs0),
    eval_class_body(Rest, Env1, Attrs1);
eval_class_body([{for_stmt, Name, IterableExpr, Body} | Rest], Env0, Attrs0) ->
    eval_class_body([{for_stmt, Name, IterableExpr, Body, []} | Rest], Env0, Attrs0);
eval_class_body([{for_stmt, Name, IterableExpr, Body, ElseBody} | Rest], Env0, Attrs0) ->
    {Iterable, Env1} = eval_expr(IterableExpr, maps:merge(Env0, Attrs0)),
    {LoopAttrs, Completed} = eval_class_for(Name, pyrlang_iter:iter(Iterable), Body, Env1, Attrs0),
    Attrs1 =
        case Completed of
            true -> eval_class_body(ElseBody, Env1, LoopAttrs);
            false -> LoopAttrs
        end,
    eval_class_body(Rest, Env1, Attrs1);
eval_class_body([{while_stmt, Condition, Body} | Rest], Env0, Attrs0) ->
    eval_class_body([{while_stmt, Condition, Body, []} | Rest], Env0, Attrs0);
eval_class_body([{while_stmt, Condition, Body, ElseBody} | Rest], Env0, Attrs0) ->
    {LoopAttrs, Completed} = eval_class_while(Condition, Body, Env0, Attrs0),
    Attrs1 =
        case Completed of
            true -> eval_class_body(ElseBody, Env0, LoopAttrs);
            false -> LoopAttrs
        end,
    eval_class_body(Rest, Env0, Attrs1);
eval_class_body([{with_stmt, ManagerExpr, Binding, Body} | Rest], Env0, Attrs0) ->
    Attrs1 = eval_class_with(ManagerExpr, Binding, Body, Env0, Attrs0),
    eval_class_body(Rest, Env0, Attrs1);
eval_class_body([{try_stmt, Body, Handlers, ElseBody, FinallyBody} | Rest], Env0, Attrs0) ->
    Attrs1 = eval_class_try(Body, Handlers, ElseBody, FinallyBody, Env0, Attrs0),
    eval_class_body(Rest, Env0, Attrs1);
eval_class_body([{import, Specs} | Rest], Env0, Attrs0) ->
    {_Last, Env1} = eval_imports(Specs, maps:merge(Env0, Attrs0), none),
    Attrs1 = copy_new_or_changed_bindings(Env1, Env0, Attrs0),
    eval_class_body(Rest, Env0, Attrs1);
eval_class_body([{from_import, ModuleName, Specs} | Rest], Env0, Attrs0) ->
    {_Last, Env1} = eval_from_import(ModuleName, Specs, maps:merge(Env0, Attrs0)),
    Attrs1 = copy_new_or_changed_bindings(Env1, Env0, Attrs0),
    eval_class_body(Rest, Env0, Attrs1);
eval_class_body([{assign, Name, Expr} | Rest], Env0, Attrs) ->
    {Value, Env1} = eval_expr(Expr, maps:merge(Env0, Attrs)),
    eval_class_body(Rest, Env1, put_class_attr(Name, Value, Attrs));
eval_class_body([{assign_target, Target, Expr} | Rest], Env0, Attrs0) ->
    {Value, Env1} = eval_expr(Expr, maps:merge(Env0, Attrs0)),
    {Env2, Attrs1} = bind_class_assignment_target(Target, Value, Env1, Attrs0),
    eval_class_body(Rest, Env2, Attrs1);
eval_class_body([{assign_chain, Targets, Expr} | Rest], Env0, Attrs0) ->
    {Value, Env1} = eval_expr(Expr, maps:merge(Env0, Attrs0)),
    {Env2, Attrs1} = lists:foldl(
        fun(Target, {AccEnv, AccAttrs}) ->
            bind_class_assignment_target(Target, Value, AccEnv, AccAttrs)
        end,
        {Env1, Attrs0},
        Targets
    ),
    eval_class_body(Rest, Env2, Attrs1);
eval_class_body([{assign_attr, {attr, ObjectExpr, Name}, Expr} | Rest], Env0, Attrs) ->
    {Object, Env1} = eval_expr(ObjectExpr, maps:merge(Env0, Attrs)),
    {Value, Env2} = eval_expr(Expr, Env1),
    ok = pyrlang_object:set_attr(Object, Name, Value),
    eval_class_body(Rest, Env2, Attrs);
eval_class_body(
    [{assign_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr}}, Expr} | Rest],
    Env0,
    Attrs
) ->
    {Object, Env1} = eval_expr(ObjectExpr, maps:merge(Env0, Attrs)),
    {Start, Env2} = eval_optional_slice(StartExpr, Env1),
    {Stop, Env3} = eval_optional_slice(StopExpr, Env2),
    {Value, Env4} = eval_expr(Expr, Env3),
    ok = set_slice_or_raise(Object, Start, Stop, Value),
    eval_class_body(Rest, Env4, Attrs);
eval_class_body(
    [
        {assign_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr, undefined}}, Expr}
        | Rest
    ],
    Env0,
    Attrs
) ->
    eval_class_body(
        [{assign_subscript, {subscript, ObjectExpr, {slice, StartExpr, StopExpr}}, Expr} | Rest],
        Env0,
        Attrs
    );
eval_class_body([{assign_subscript, {subscript, ObjectExpr, IndexExpr}, Expr} | Rest], Env0, Attrs) ->
    {Object, Env1} = eval_expr(ObjectExpr, maps:merge(Env0, Attrs)),
    {Index, Env2} = eval_expr(IndexExpr, Env1),
    {Value, Env3} = eval_expr(Expr, Env2),
    ok = set_subscript_or_raise(Object, Index, Value),
    eval_class_body(Rest, Env3, Attrs);
eval_class_body([{aug_assign, Target, Op, Expr} | Rest], Env0, Attrs0) ->
    {Current, Env1} = read_assignment_target(Target, maps:merge(Env0, Attrs0)),
    {Right, Env2} = eval_expr(Expr, Env1),
    Value = eval_aug_assign_value(Op, Current, Right),
    {Env3, Attrs1} = bind_class_assignment_target(Target, Value, Env2, Attrs0),
    eval_class_body(Rest, Env3, Attrs1);
eval_class_body([{ann_assign, _Target, none} | Rest], Env0, Attrs0) ->
    eval_class_body(Rest, Env0, Attrs0);
eval_class_body([{ann_assign, Target, Expr} | Rest], Env0, Attrs0) ->
    {Value, Env1} = eval_expr(Expr, maps:merge(Env0, Attrs0)),
    {Env2, Attrs1} = bind_class_assignment_target(Target, Value, Env1, Attrs0),
    eval_class_body(Rest, Env2, Attrs1);
eval_class_body([{type_alias, Name, Expr} | Rest], Env0, Attrs0) ->
    Alias = make_type_alias(Name, Expr, maps:merge(Env0, Attrs0)),
    eval_class_body(Rest, Env0#{Name => Alias}, put_class_attr(Name, Alias, Attrs0));
eval_class_body([{del, Target} | Rest], Env0, Attrs0) ->
    {Env1, Attrs1} = delete_class_assignment_target(Target, Env0, Attrs0),
    eval_class_body(Rest, Env1, Attrs1);
eval_class_body([{raise, bare} | _Rest], Env0, Attrs) ->
    raise_current_exception(maps:merge(Env0, Attrs));
eval_class_body([{raise, Expr} | _Rest], Env0, Attrs) ->
    {Value, _Env1} = eval_expr(Expr, maps:merge(Env0, Attrs)),
    pyrlang_exception:raise(Value);
eval_class_body([break | _Rest], _Env, _Attrs) ->
    throw(py_break);
eval_class_body([continue | _Rest], _Env, _Attrs) ->
    throw(py_continue);
eval_class_body([{global, _Names} | Rest], Env, Attrs) ->
    eval_class_body(Rest, Env, Attrs);
eval_class_body([{nonlocal, _Names} | Rest], Env, Attrs) ->
    eval_class_body(Rest, Env, Attrs);
eval_class_body([{expr, Expr} | Rest], Env, Attrs) ->
    {_Value, Env1} = eval_expr(Expr, maps:merge(Env, Attrs)),
    eval_class_body(Rest, Env1, Attrs);
eval_class_body([pass | Rest], Env, Attrs) ->
    eval_class_body(Rest, Env, Attrs);
eval_class_body([Other | _Rest], _Env, _Attrs) ->
    erlang:error({unsupported_class_body_statement, Other}).

eval_class_for(Target, Iterator, Body, Env, Attrs0) ->
    case next_iterator_value(Iterator) of
        done ->
            {Attrs0, true};
        {ok, Value} ->
            {Env1, BodyAttrs} = bind_class_assignment_target(Target, Value, Env, Attrs0),
            try eval_class_body(Body, Env1, BodyAttrs) of
                Attrs1 -> eval_class_for(Target, Iterator, Body, Env1, Attrs1)
            catch
                throw:py_continue -> eval_class_for(Target, Iterator, Body, Env1, BodyAttrs);
                throw:py_break -> {BodyAttrs, false}
            end
    end.

bind_class_assignment_target({target_name, Name}, Value, Env, Attrs) ->
    {Env, put_class_attr(Name, Value, Attrs)};
bind_class_assignment_target({target_tuple, Targets}, Value, Env, Attrs) ->
    bind_class_sequence_assignment_targets(Targets, Value, Env, Attrs);
bind_class_assignment_target({target_list, Targets}, Value, Env, Attrs) ->
    bind_class_sequence_assignment_targets(Targets, Value, Env, Attrs);
bind_class_assignment_target(Target, Value, Env, Attrs) ->
    {bind_assignment_target(Target, Value, maps:merge(Env, Attrs)), Attrs}.

delete_class_assignment_target({target_name, Name}, Env, Attrs) ->
    {Env, remove_class_attr(Name, Attrs)};
delete_class_assignment_target({target_tuple, Targets}, Env, Attrs) ->
    lists:foldl(
        fun(Target, {AccEnv, AccAttrs}) ->
            delete_class_assignment_target(Target, AccEnv, AccAttrs)
        end,
        {Env, Attrs},
        Targets
    );
delete_class_assignment_target({target_list, Targets}, Env, Attrs) ->
    delete_class_assignment_target({target_tuple, Targets}, Env, Attrs);
delete_class_assignment_target(Target, Env, Attrs) ->
    {delete_assignment_target(Target, maps:merge(Env, Attrs)), Attrs}.

bind_class_sequence_assignment_targets(Targets, Value, Env, Attrs) ->
    Values = iter_values(Value),
    case length(Targets) =:= length(Values) of
        true ->
            lists:foldl(
                fun({Target, Item}, {AccEnv, AccAttrs}) ->
                    bind_class_assignment_target(Target, Item, AccEnv, AccAttrs)
                end,
                {Env, Attrs},
                lists:zip(Targets, Values)
            );
        false ->
            raise_builtin(<<"ValueError">>, <<"not enough values to unpack">>)
    end.

eval_class_while(Condition, Body, Env, Attrs0) ->
    {ConditionValue, _Env1} = eval_expr(Condition, maps:merge(Env, Attrs0)),
    case truthy(ConditionValue) of
        true ->
            try eval_class_body(Body, Env, Attrs0) of
                Attrs1 -> eval_class_while(Condition, Body, Env, Attrs1)
            catch
                throw:py_continue -> eval_class_while(Condition, Body, Env, Attrs0);
                throw:py_break -> {Attrs0, false}
            end;
        false ->
            {Attrs0, true}
    end.

eval_class_with(ManagerExpr, Binding, Body, Env0, Attrs0) ->
    {Manager, Env1} = eval_expr(ManagerExpr, maps:merge(Env0, Attrs0)),
    Enter = pyrlang_object:get_attr(Manager, <<"__enter__">>),
    Exit = pyrlang_object:get_attr(Manager, <<"__exit__">>),
    Entered = call_value(Enter, []),
    {BodyEnv, BodyAttrs} =
        case Binding of
            undefined -> {Env1, Attrs0};
            Target -> bind_class_assignment_target(Target, Entered, Env1, Attrs0)
        end,
    try
        Attrs1 = eval_class_body(Body, BodyEnv, BodyAttrs),
        _ = call_value(Exit, [none, none, none]),
        Attrs1
    catch
        throw:{py_exception, Exception} ->
            Suppressed = call_value(Exit, [
                pyrlang_exception:exception_type(Exception), Exception, none
            ]),
            case truthy(Suppressed) of
                true -> BodyAttrs;
                false -> pyrlang_exception:raise(Exception)
            end;
        throw:py_break ->
            _ = call_value(Exit, [none, none, none]),
            throw(py_break);
        throw:py_continue ->
            _ = call_value(Exit, [none, none, none]),
            throw(py_continue)
    end.

eval_class_try(Body, Handlers, ElseBody, FinallyBody, Env, Attrs0) ->
    Result =
        try eval_class_body(Body, Env, Attrs0) of
            Attrs1 ->
                case ElseBody of
                    [] -> {normal, Attrs1};
                    _ -> {normal, eval_class_body(ElseBody, Env, Attrs1)}
                end
        catch
            throw:{py_exception, Exception} ->
                try handle_class_exception(Exception, Handlers, Env, Attrs0) of
                    Attrs1 -> {normal, Attrs1}
                catch
                    throw:{py_exception, NewException} -> {exception, NewException, Attrs0}
                end;
            throw:py_break ->
                {break, Attrs0};
            throw:py_continue ->
                {continue, Attrs0}
        end,
    run_class_finally(Result, FinallyBody, Env).

handle_class_exception(Exception, [], _Env, _Attrs) ->
    pyrlang_exception:raise(Exception);
handle_class_exception(Exception, [{Pattern, Binding, Body} | Rest], Env, Attrs0) ->
    case exception_pattern_matches(Pattern, Exception, maps:merge(Env, Attrs0)) of
        true ->
            HandlerEnv = Env#{?CURRENT_EXCEPTION_KEY => Exception},
            HandlerAttrs =
                case Binding of
                    undefined -> Attrs0;
                    Name -> put_class_attr(Name, Exception, Attrs0)
                end,
            with_process_exception(Exception, fun() ->
                eval_class_body(Body, HandlerEnv, HandlerAttrs)
            end);
        false ->
            handle_class_exception(Exception, Rest, Env, Attrs0)
    end.

run_class_finally({normal, Attrs}, FinallyBody, Env) ->
    eval_class_body(FinallyBody, Env, Attrs);
run_class_finally({exception, Exception, Attrs}, FinallyBody, Env) ->
    _ = eval_class_body(FinallyBody, Env, Attrs),
    pyrlang_exception:raise(Exception);
run_class_finally({break, Attrs}, FinallyBody, Env) ->
    _ = eval_class_body(FinallyBody, Env, Attrs),
    throw(py_break);
run_class_finally({continue, Attrs}, FinallyBody, Env) ->
    _ = eval_class_body(FinallyBody, Env, Attrs),
    throw(py_continue).

copy_new_or_changed_bindings(Env, OuterEnv, Attrs0) ->
    maps:fold(
        fun(Name, Value, Attrs) ->
            case maps:find(Name, OuterEnv) of
                {ok, Value} -> Attrs;
                _ -> put_class_attr(Name, Value, Attrs)
            end
        end,
        Attrs0,
        Env
    ).

is_class_ref({py_ref, _} = Ref) ->
    try
        pyrlang_heap:type(Ref) =:= class
    catch
        _:_ -> false
    end;
is_class_ref(_Other) ->
    false.

instantiate_class(Class, Args) ->
    case maybe_enum_member_lookup(Class, Args) of
        {ok, Member} ->
            Member;
        error ->
            instantiate_non_enum_class(Class, Args)
    end.

instantiate_non_enum_class(Class, Args) ->
    case own_class_attr(Class, <<"__pyrlang_builtin_constructor__">>) of
        {ok, Constructor} ->
            call_value(Constructor, Args);
        error ->
            case own_class_attr(Class, <<"__new__">>) of
                {ok, _New} ->
                    instantiate_python_class(
                        Class, Args, {ok, pyrlang_object:get_attr(Class, <<"__new__">>)}
                    );
                error ->
                    instantiate_without_own_constructor(Class, Args)
            end
    end.

instantiate_without_own_constructor(Class, Args) ->
    case tuple_subclass_class(Class) of
        true ->
            instantiate_python_class(Class, Args, inherited_new_lookup(Class));
        false ->
            case inherited_new_lookup(Class) of
                {ok, _New} = NewLookup ->
                    instantiate_python_class(Class, Args, NewLookup);
                error ->
                    case pyrlang_object:class_attr(Class, <<"__pyrlang_builtin_constructor__">>) of
                        {ok, Constructor} ->
                            case is_type_subclass(Class) of
                                true ->
                                    instantiate_python_class(
                                        Class, Args, inherited_new_lookup(Class)
                                    );
                                false ->
                                    call_value(Constructor, Args)
                            end;
                        error ->
                            instantiate_python_class(Class, Args, inherited_new_lookup(Class))
                    end
            end
    end.

tuple_subclass_class(Class) ->
    TupleClass = maps:get(<<"tuple">>, pyrlang_builtins:env()),
    is_class_ref(Class) andalso Class =/= TupleClass andalso
        lists:member(TupleClass, pyrlang_object:mro(Class)).

maybe_enum_member_lookup(Class, Args) ->
    case enum_members(Class) of
        {ok, Members} ->
            {PosArgs, KwArgs} = normalize_call_args(Args),
            case {PosArgs, map_size(KwArgs)} of
                {[{py_ref, _} = Value], 0} ->
                    case instance_of_class(Value, Class) of
                        true -> {ok, Value};
                        false -> find_enum_member(Members, Value)
                    end;
                {[Value], 0} ->
                    find_enum_member(Members, Value);
                _ ->
                    error
            end;
        error ->
            error
    end.

enum_members(Class) ->
    try pyrlang_object:get_attr(Class, <<"__members__">>) of
        Members ->
            {ok, enum_member_values(Members)}
    catch
        _:_ -> error
    end.

enum_member_values({py_ref, _} = Members) ->
    case pyrlang_heap:type(Members) of
        dict -> [Value || {_Name, Value} <- pyrlang_heap:dict_items(Members)];
        _ -> []
    end;
enum_member_values(Members) when is_map(Members) ->
    maps:values(Members);
enum_member_values(_Members) ->
    [].

find_enum_member([], _Value) ->
    error;
find_enum_member([Member | Rest], Value) ->
    case enum_member_matches(Member, Value) of
        true -> {ok, Member};
        false -> find_enum_member(Rest, Value)
    end.

enum_member_matches(Member, Value) ->
    Member =:= Value orelse
        try
            pyrlang_object:get_attr(Member, <<"_value_">>) =:= Value
        catch
            _:_ -> false
        end.

own_class_attr(Class, Name) ->
    Data = pyrlang_heap:data(Class),
    maps:find(Name, maps:get(attrs, Data)).

inherited_new_lookup(Class) ->
    case pyrlang_object:class_attr(Class, <<"__new__">>) of
        {ok, New} ->
            case object_new_lookup() of
                {ok, New} -> error;
                _ -> {ok, pyrlang_object:get_attr(Class, <<"__new__">>)}
            end;
        error ->
            error
    end.

object_new_lookup() ->
    ObjectClass = maps:get(<<"object">>, pyrlang_builtins:env()),
    pyrlang_object:class_attr(ObjectClass, <<"__new__">>).

is_type_subclass(Class) ->
    TypeClass = maps:get(<<"type">>, pyrlang_builtins:env()),
    Class =/= TypeClass andalso lists:member(TypeClass, pyrlang_object:mro(Class)).

instantiate_python_class(Class, Args, NewLookup) ->
    {PosArgs, KwArgs} = normalize_call_args(Args),
    Instance =
        case NewLookup of
            {ok, New} ->
                call_value(New, {call_args, [Class | PosArgs], KwArgs});
            error ->
                pyrlang_object:instantiate(Class)
        end,
    case instance_of_class(Instance, Class) of
        true ->
            case instance_init(Class, Instance) of
                {ok, Init} ->
                    _ = call_value(Init, Args),
                    Instance;
                error ->
                    case {PosArgs, map_size(KwArgs)} of
                        {[], 0} ->
                            case pyrlang_object:is_exception_class(Class) of
                                true ->
                                    ok = init_exception_instance(Instance, []),
                                    Instance;
                                false ->
                                    Instance
                            end;
                        {_SomeArgs, 0} ->
                            case pyrlang_object:is_exception_class(Class) of
                                true ->
                                    ok = init_exception_instance(Instance, PosArgs),
                                    Instance;
                                false ->
                                    erlang:error(
                                        {arity_error,
                                            {no_init, pyrlang_object:class_name(Class),
                                                length(PosArgs), maps:size(KwArgs)}}
                                    )
                            end;
                        _ ->
                            erlang:error(
                                {arity_error,
                                    {no_init, pyrlang_object:class_name(Class), length(PosArgs),
                                        maps:size(KwArgs)}}
                            )
                    end
            end;
        false ->
            Instance
    end.

init_exception_instance({py_ref, _} = Instance, Args) ->
    Data = pyrlang_heap:data(Instance),
    Attrs = maps:get(attrs, Data),
    pyrlang_heap:set_data(Instance, Data#{attrs := maps:put(<<"args">>, list_to_tuple(Args), Attrs)}).

instance_init(Class, Instance) ->
    case is_class_ref(Instance) of
        true ->
            case pyrlang_object:class_attr(Class, <<"__init__">>) of
                {ok, Init} -> {ok, pyrlang_object:bind_attr(Init, Instance, Class)};
                error -> error
            end;
        false ->
            try pyrlang_object:get_attr(Instance, <<"__init__">>) of
                Init -> {ok, Init}
            catch
                error:{attribute_error, _Name} -> error
            end
    end.

instance_of_class({py_ref, _} = Instance, Class) ->
    try pyrlang_heap:type(Instance) of
        instance ->
            InstanceClass = maps:get(class, pyrlang_heap:data(Instance)),
            lists:member(Class, pyrlang_object:mro(InstanceClass));
        class ->
            case pyrlang_object:metaclass(Instance) of
                undefined -> false;
                Metaclass -> lists:member(Class, pyrlang_object:mro(Metaclass))
            end;
        list ->
            case pyrlang_heap:data(Instance) of
                #{class := InstanceClass} ->
                    lists:member(Class, pyrlang_object:mro(InstanceClass));
                _ ->
                    false
            end;
        dict ->
            case pyrlang_heap:data(Instance) of
                #{class := InstanceClass} ->
                    lists:member(Class, pyrlang_object:mro(InstanceClass));
                _ ->
                    false
            end;
        _ ->
            false
    catch
        _:_ -> false
    end;
instance_of_class(_Value, _Class) ->
    false.
