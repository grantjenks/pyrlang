-module(pyrlang_object).

-export([
    new_class/2,
    new_class/3,
    new_class/4,
    instantiate/1,
    class_name/1,
    bases/1,
    metaclass/1,
    set_metaclass/2,
    mro/1,
    class_attr/2,
    bind_attr/3,
    set_class_attr/3,
    get_attr/2,
    set_attr/3,
    del_attr/2,
    descriptor/2,
    descriptor/3,
    is_exception_class/1,
    is_exception_instance/1,
    exception_class_matches/2,
    super/0,
    super/1,
    call/2
]).

-define(PY_FUNCTION_ATTRS_KEY, pyrlang_function_attrs).
-define(PY_SUBCLASSES_KEY, pyrlang_subclasses).
-define(FUNCTION_ID_KEY, '$py_function_id').
-define(CLASS_ATTR_ORDER_KEY, <<"__pyrlang_class_attr_order__">>).

-spec new_class(binary() | string() | atom(), map() | [{term(), term()}]) -> term().
new_class(Name, Attrs) ->
    new_class(Name, [], Attrs).

-spec new_class(binary() | string() | atom(), [term()], map() | [{term(), term()}]) -> term().
new_class(Name, Bases, Attrs0) ->
    new_class(Name, Bases, Attrs0, undefined).

-spec new_class(binary() | string() | atom(), [term()], map() | [{term(), term()}], term()) -> term().
new_class(Name, Bases, Attrs0, Metaclass) ->
    Attrs = normalize_attrs(Attrs0),
    Ref = pyrlang_heap:placeholder(class),
    Data0 = #{
        name => normalize_name(Name),
        bases => Bases,
        metaclass => Metaclass,
        attrs => Attrs,
        mro => []
    },
    ok = pyrlang_heap:set_data(Ref, Data0),
    Mro = c3_mro(Ref, Bases),
    BoundAttrs = bind_function_owners(Ref, Attrs),
    ok = pyrlang_heap:set_data(Ref, Data0#{attrs := BoundAttrs, mro := Mro}),
    register_subclasses(Ref, Bases),
    notify_set_name(Ref, BoundAttrs),
    Ref.

-spec instantiate(term()) -> term().
instantiate(Class) ->
    class = pyrlang_heap:type(Class),
    pyrlang_heap:allocate(instance, #{class => Class, attrs => #{}}).

-spec class_name(term()) -> binary().
class_name(Class) ->
    class = pyrlang_heap:type(Class),
    maps:get(name, pyrlang_heap:data(Class)).

-spec bases(term()) -> [term()].
bases(Class) ->
    class = pyrlang_heap:type(Class),
    maps:get(bases, pyrlang_heap:data(Class)).

-spec metaclass(term()) -> term().
metaclass({py_exception_type, _Name}) ->
    undefined;
metaclass(Class) ->
    class = pyrlang_heap:type(Class),
    maps:get(metaclass, pyrlang_heap:data(Class), undefined).

-spec set_metaclass(term(), term()) -> ok.
set_metaclass(Class, Metaclass) ->
    class = pyrlang_heap:type(Class),
    Data = pyrlang_heap:data(Class),
    pyrlang_heap:set_data(Class, Data#{metaclass => Metaclass}).

-spec mro(term()) -> [term()].
mro({py_exception_type, _Name} = ExceptionType) ->
    [ExceptionType];
mro(Class) ->
    class = pyrlang_heap:type(Class),
    maps:get(mro, pyrlang_heap:data(Class)).

-spec class_attr(term(), term()) -> {ok, term()} | error.
class_attr(Class, Name) ->
    lookup_class_attr(Class, normalize_attr(Name)).

-spec set_class_attr(term(), term(), term()) -> ok.
set_class_attr(Class, Name, Value) ->
    class = pyrlang_heap:type(Class),
    Data = pyrlang_heap:data(Class),
    Attrs = maps:get(attrs, Data),
    pyrlang_heap:set_data(Class, Data#{attrs := put_class_attr(normalize_attr(Name), Value, Attrs)}).

-spec get_attr(term(), term()) -> term().
get_attr({py_super, Class, Instance}, Name0) ->
    Name = normalize_attr(Name0),
    super_get_attr(Class, Instance, Name);
get_attr({py_function, _Params, _Body, _Env} = Function, Name0) ->
    function_get_attr(Function, normalize_attr(Name0));
get_attr({py_function, _Params, _Body, _Env, _IsGenerator} = Function, Name0) ->
    function_get_attr(Function, normalize_attr(Name0));
get_attr({py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass} = Function, Name0) ->
    function_get_attr(Function, normalize_attr(Name0));
get_attr({py_bound_method, Callable, _Self}, <<"__func__">>) ->
    Callable;
get_attr({py_bound_method, _Callable, Self}, <<"__self__">>) ->
    Self;
get_attr({py_bound_method, Callable, _Self}, Name0) ->
    get_attr(Callable, normalize_attr(Name0));
get_attr({py_exception_type, Type}, <<"__name__">>) ->
    Type;
get_attr({py_exception_type, Type}, <<"__module__">>) ->
    maps:get(<<"__module__">>, exception_type_attrs(Type), <<"builtins">>);
get_attr({py_exception_type, Type}, Name0) ->
    Name = normalize_attr(Name0),
    case maps:find(Name, exception_type_attrs(Type)) of
        {ok, Value} -> Value;
        error -> erlang:error({attribute_error, Name})
    end;
get_attr({py_union_type, Options}, <<"__args__">>) ->
    list_to_tuple(Options);
get_attr({py_union_type, _Options}, <<"__module__">>) ->
    <<"types">>;
get_attr({py_union_type, _Options}, <<"__name__">>) ->
    <<"UnionType">>;
get_attr({py_union_type, _Options}, Name0) ->
    erlang:error({attribute_error, normalize_attr(Name0)});
get_attr({py_type_alias, Name, _Expr, _Env}, <<"__name__">>) ->
    Name;
get_attr({py_type_alias, _Name, _Expr, Env}, <<"__module__">>) ->
    maps:get(<<"__name__">>, Env, <<"__main__">>);
get_attr({py_type_alias, _Name, Expr, Env}, <<"__value__">>) ->
    {Value, _Env1} = pyrlang_eval:eval_expr(Expr, Env),
    Value;
get_attr({py_type_alias, _Name, _Expr, _Env}, <<"__type_params__">>) ->
    {};
get_attr({py_type_alias, _Name, _Expr, _Env}, Name0) ->
    erlang:error({attribute_error, normalize_attr(Name0)});
get_attr({py_generic_alias, Origin, _Args}, <<"__origin__">>) ->
    Origin;
get_attr({py_generic_alias, _Origin, Args}, <<"__args__">>) ->
    generic_alias_args_tuple(Args);
get_attr({py_generic_alias, _Origin, _Args}, <<"__parameters__">>) ->
    {};
get_attr({py_generic_alias, _Origin, _Args}, <<"__unpacked__">>) ->
    false;
get_attr({py_generic_alias, Origin, _Args}, <<"__module__">>) ->
    try get_attr(Origin, <<"__module__">>)
    catch
        _:_ -> <<"types">>
    end;
get_attr({py_generic_alias, Origin, _Args}, <<"__qualname__">>) ->
    try get_attr(Origin, <<"__qualname__">>)
    catch
        _:_ -> <<"GenericAlias">>
    end;
get_attr({py_generic_alias, Origin, _Args}, <<"__mro_entries__">>) ->
    fun(_Bases) -> {Origin} end;
get_attr({py_generic_alias, _Origin, _Args}, Name0) ->
    erlang:error({attribute_error, normalize_attr(Name0)});
get_attr({py_coroutine, _Body, _Env, _OwnerClass, _PosArgs}, <<"close">>) ->
    fun() -> none end;
get_attr({py_coroutine, _Body, _Env, _OwnerClass, _PosArgs}, Name0) ->
    erlang:error({attribute_error, normalize_attr(Name0)});
get_attr({py_async_generator, _Body, _Env, _OwnerClass, _PosArgs}, <<"aclose">>) ->
    fun() -> none end;
get_attr({py_async_generator, _Body, _Env, _OwnerClass, _PosArgs}, Name0) ->
    erlang:error({attribute_error, normalize_attr(Name0)});
get_attr({py_native_varargs, _Fun}, <<"__doc__">>) ->
    none;
get_attr({py_native_varargs, _Fun}, <<"__name__">>) ->
    <<"<built-in function>">>;
get_attr({py_native_varargs, _Fun}, <<"__qualname__">>) ->
    <<"<built-in function>">>;
get_attr({py_native_varargs, _Fun}, <<"__module__">>) ->
    <<"builtins">>;
get_attr({py_native_varargs, _Fun}, <<"__repr__">>) ->
    fun() -> <<"<built-in function>">> end;
get_attr({py_native_varargs, _Fun, _Bind}, Name0) ->
    get_attr({py_native_varargs, _Fun}, Name0);
get_attr({py_native_callable, _Fun}, <<"__doc__">>) ->
    none;
get_attr({py_native_callable, _Fun}, <<"__name__">>) ->
    <<"<native>">>;
get_attr({py_native_callable, _Fun}, <<"__qualname__">>) ->
    <<"<native>">>;
get_attr({py_native_callable, _Fun}, <<"__module__">>) ->
    <<"builtins">>;
get_attr({py_native_callable, _Fun}, <<"__repr__">>) ->
    fun() -> <<"<native>">> end;
get_attr({py_native_callable, _Fun, _Bind}, Name0) ->
    get_attr({py_native_callable, _Fun}, Name0);
get_attr({py_native_call, _Fun}, <<"__doc__">>) ->
    none;
get_attr({py_native_call, _Fun}, <<"__name__">>) ->
    <<"<built-in function>">>;
get_attr({py_native_call, _Fun}, <<"__qualname__">>) ->
    <<"<built-in function>">>;
get_attr({py_native_call, _Fun}, <<"__module__">>) ->
    <<"builtins">>;
get_attr({py_native_call, _Fun}, <<"__repr__">>) ->
    fun() -> <<"<built-in function>">> end;
get_attr({py_native_call, _Fun, _Bind}, Name0) ->
    get_attr({py_native_call, _Fun}, Name0);
get_attr(Fun, <<"__doc__">>) when is_function(Fun) ->
    none;
get_attr(Fun, <<"__name__">>) when is_function(Fun) ->
    <<"<built-in function>">>;
get_attr(Fun, <<"__qualname__">>) when is_function(Fun) ->
    <<"<built-in function>">>;
get_attr(Fun, <<"__module__">>) when is_function(Fun) ->
    <<"builtins">>;
get_attr(#{py_descriptor := true} = Descriptor, Name0) ->
    descriptor_get_attr(Descriptor, normalize_attr(Name0));
get_attr({py_ref, _} = Instance, Name0) ->
    Name = normalize_attr(Name0),
    case pyrlang_heap:type(Instance) of
        instance ->
            instance_get_attr(Instance, Name);
        class ->
            class_get_attr(Instance, Name);
        module ->
            pyrlang_module:get_attr(Instance, Name);
        list ->
            list_get_attr(Instance, Name);
        dict ->
            dict_get_attr(Instance, Name);
        set ->
            set_get_attr(Instance, Name);
        iterator ->
            iterator_get_attr(Instance, Name);
        generator ->
            generator_get_attr(Instance, Name)
    end;
get_attr(_Object, Name0) ->
    erlang:error({attribute_error, normalize_attr(Name0)}).

-spec set_attr(term(), term(), term()) -> ok.
set_attr({py_function, _Params, _Body, _Env} = Function, Name0, Value) ->
    function_set_attr(Function, normalize_attr(Name0), Value);
set_attr({py_function, _Params, _Body, _Env, _IsGenerator} = Function, Name0, Value) ->
    function_set_attr(Function, normalize_attr(Name0), Value);
set_attr({py_function, _Params, _Body, _Env, _IsGenerator, _OwnerClass} = Function, Name0, Value) ->
    function_set_attr(Function, normalize_attr(Name0), Value);
set_attr({py_exception_type, Type}, Name0, Value) ->
    Name = normalize_attr(Name0),
    Attrs = exception_type_attrs(Type),
    erlang:put({py_exception_type_attrs, Type}, maps:put(Name, Value, Attrs)),
    ok;
set_attr(#{py_exception := true} = Exception, Name0, Value) ->
    pyrlang_exception:set_attr(Exception, normalize_attr(Name0), Value);
set_attr(#{py_descriptor := true}, <<"__doc__">>, _Value) ->
    ok;
set_attr({py_instance_dict, Instance}, Name0, Value) ->
    Name = normalize_attr(Name0),
    Data = pyrlang_heap:data(Instance),
    Attrs = maps:get(attrs, Data),
    pyrlang_heap:set_data(Instance, Data#{attrs := maps:put(Name, Value, Attrs)});
set_attr({py_ref, _} = Instance, Name0, Value) ->
    Name = normalize_attr(Name0),
    case pyrlang_heap:type(Instance) of
        module ->
            pyrlang_module:set_attr(Instance, Name, Value);
        class ->
            set_class_attr(Instance, Name, Value);
        instance ->
            Data = pyrlang_heap:data(Instance),
            Class = maps:get(class, Data),
            case Name of
                <<"__class__">> ->
                    case lookup_data_descriptor(Class, Name) of
                        {ok, Descriptor} ->
                            descriptor_set(Descriptor, Instance, Value);
                        error ->
                            class = pyrlang_heap:type(Value),
                            pyrlang_heap:set_data(Instance, Data#{class := Value})
                    end;
                <<"__dict__">> ->
                    pyrlang_heap:set_data(Instance, Data#{attrs := attrs_from_dict_assignment(Value)});
                _ ->
                    case lookup_data_descriptor(Class, Name) of
                        {ok, Descriptor} ->
                            descriptor_set(Descriptor, Instance, Value);
                        error ->
                            Attrs = maps:get(attrs, Data),
                            pyrlang_heap:set_data(Instance, Data#{attrs := maps:put(Name, Value, Attrs)})
                    end
            end;
        list ->
            list_set_attr(Instance, Name, Value);
        dict ->
            dict_set_attr(Instance, Name, Value)
    end;
set_attr(_Object, Name0, _Value) ->
    erlang:error({attribute_error, normalize_attr(Name0)}).

attrs_from_dict_assignment({py_instance_dict, Source}) ->
    SourceData = pyrlang_heap:data(Source),
    maps:get(attrs, SourceData);
attrs_from_dict_assignment(Value) ->
    dict = pyrlang_heap:type(Value),
    maps:from_list(pyrlang_heap:dict_items(Value)).

exception_type_attrs(Type) ->
    DefaultAttrs = exception_default_attrs(Type),
    case erlang:get({py_exception_type_attrs, Type}) of
        undefined -> DefaultAttrs;
        Attrs when is_map(Attrs) -> maps:merge(DefaultAttrs, Attrs)
    end.

exception_default_attrs(_Type) ->
    #{
        <<"__init__">> => {py_native_varargs, fun exception_dunder_init/1},
        <<"__str__">> => fun exception_dunder_str/1
    }.

exception_dunder_init([Self | Args]) ->
    case is_exception_instance(Self) of
        true ->
            Data = pyrlang_heap:data(Self),
            Attrs = maps:get(attrs, Data),
            ok = pyrlang_heap:set_data(Self, Data#{attrs := maps:put(<<"args">>, list_to_tuple(Args), Attrs)}),
            none;
        false ->
            none
    end;
exception_dunder_init(Args) ->
    erlang:error({arity_error, {'BaseException.__init__', length(Args)}}).

exception_dunder_str(Self) ->
    case is_exception_instance(Self) of
        true -> pyrlang_exception:message(Self);
        false -> <<>>
    end.

-spec del_attr(term(), term()) -> ok.
del_attr({py_ref, _} = Ref, Name0) ->
    Name = normalize_attr(Name0),
    case pyrlang_heap:type(Ref) of
        module ->
            Data = pyrlang_heap:data(Ref),
            Env = maps:get(env, Data),
            case maps:is_key(Name, Env) of
                true -> pyrlang_heap:set_data(Ref, Data#{env := maps:remove(Name, Env)});
                false -> erlang:error({attribute_error, Name})
            end;
        class ->
            del_class_attr(Ref, Name);
        instance ->
            Data = pyrlang_heap:data(Ref),
            Class = maps:get(class, Data),
            case lookup_data_descriptor(Class, Name) of
                {ok, Descriptor} ->
                    descriptor_delete(Descriptor, Ref);
                error ->
                    Attrs = maps:get(attrs, Data),
                    case maps:is_key(Name, Attrs) of
                        true -> pyrlang_heap:set_data(Ref, Data#{attrs := maps:remove(Name, Attrs)});
                        false -> erlang:error({attribute_error, Name})
                    end
            end;
        _Other ->
            erlang:error({attribute_error, Name})
    end;
del_attr(_Object, Name0) ->
    erlang:error({attribute_error, normalize_attr(Name0)}).

del_class_attr(Class, Name) ->
    Data = pyrlang_heap:data(Class),
    Attrs = maps:get(attrs, Data),
    case maps:is_key(Name, Attrs) of
        true -> pyrlang_heap:set_data(Class, Data#{attrs := remove_class_attr(Name, Attrs)});
        false -> erlang:error({attribute_error, Name})
    end.

function_get_attr(Function, Name) ->
    case maps:find(function_attr_key(Function, Name), function_attrs()) of
        {ok, Value} -> Value;
        error -> function_default_attr(Function, Name)
    end.

function_default_attr(_Function, <<"__doc__">>) ->
    none;
function_default_attr(_Function, <<"__name__">>) ->
    <<"<lambda>">>;
function_default_attr(_Function, <<"__qualname__">>) ->
    <<"<lambda>">>;
function_default_attr(Function, <<"__module__">>) ->
    function_module(Function);
function_default_attr(_Function, <<"__dict__">>) ->
    pyrlang_heap:dict([]);
function_default_attr(Function, <<"__get__">>) ->
    {py_native_varargs, fun
        ([Obj]) -> function_descriptor_get(Function, Obj, undefined);
        ([Obj, Class]) -> function_descriptor_get(Function, Obj, Class);
        (Args) -> erlang:error({arity_error, {'function.__get__', length(Args)}})
    end};
function_default_attr(Function, <<"__defaults__">>) ->
    case positional_defaults(function_params(Function)) of
        [] -> none;
        Defaults -> list_to_tuple(Defaults)
    end;
function_default_attr(Function, <<"__kwdefaults__">>) ->
    case keyword_only_defaults(function_params(Function)) of
        [] -> none;
        Defaults -> pyrlang_heap:dict(Defaults)
    end;
function_default_attr(_Function, <<"__annotations__">>) ->
    pyrlang_heap:dict([]);
function_default_attr(Function, <<"__globals__">>) ->
    pyrlang_heap:dict(pyrlang_eval:function_globals(function_env(Function)));
function_default_attr(_Function, <<"__text_signature__">>) ->
    none;
function_default_attr(Function, <<"__code__">>) ->
    function_code(Function);
function_default_attr(_Function, Name) ->
    erlang:error({attribute_error, Name}).

function_descriptor_get(Function, none, _Class) ->
    Function;
function_descriptor_get(Function, undefined, _Class) ->
    Function;
function_descriptor_get(Function, Obj, _Class) ->
    {py_bound_method, Function, Obj}.

function_module({py_function, _Params, _Body, Env}) ->
    maps:get(<<"__name__">>, Env, <<"__main__">>);
function_module({py_function, _Params, _Body, Env, _Mode}) ->
    maps:get(<<"__name__">>, Env, <<"__main__">>);
function_module({py_function, _Params, _Body, Env, _Mode, _Owner}) ->
    maps:get(<<"__name__">>, Env, <<"__main__">>).

function_env({py_function, _Params, _Body, Env}) ->
    Env;
function_env({py_function, _Params, _Body, Env, _Mode}) ->
    Env;
function_env({py_function, _Params, _Body, Env, _Mode, _Owner}) ->
    Env.

function_params({py_function, Params, _Body, _Env}) ->
    Params;
function_params({py_function, Params, _Body, _Env, _Mode}) ->
    Params;
function_params({py_function, Params, _Body, _Env, _Mode, _Owner}) ->
    Params.

function_code(Function) ->
    #{posonly := PosOnly, poskw := PosKw, kwonly := KwOnly, vararg := VarArg, kwrest := KwRest} =
        function_param_info(function_params(Function)),
    Positional = PosOnly ++ PosKw,
    VarNames = Positional ++ KwOnly ++ optional_name(VarArg) ++ optional_name(KwRest),
    Code = instantiate(pyrlang_builtins:code_type()),
    Attrs = #{
        <<"co_argcount">> => length(Positional),
        <<"co_posonlyargcount">> => length(PosOnly),
        <<"co_kwonlyargcount">> => length(KwOnly),
        <<"co_nlocals">> => length(VarNames),
        <<"co_stacksize">> => 0,
        <<"co_flags">> => function_flags(Function, VarArg, KwRest),
        <<"co_name">> => function_default_attr(Function, <<"__name__">>),
        <<"co_qualname">> => function_default_attr(Function, <<"__qualname__">>),
        <<"co_filename">> => <<>>,
        <<"co_firstlineno">> => 1,
        <<"co_consts">> => {},
        <<"co_names">> => {},
        <<"co_varnames">> => list_to_tuple(VarNames),
        <<"co_freevars">> => {},
        <<"co_cellvars">> => {}
    },
    maps:foreach(fun(Name, Value) -> ok = set_attr(Code, Name, Value) end, Attrs),
    Code.

function_param_info(Params) ->
    function_param_info(Params, poskw, [], [], [], undefined, undefined).

function_param_info([], _Section, PosOnly, PosKw, KwOnly, VarArg, KwRest) ->
    #{posonly => lists:reverse(PosOnly), poskw => lists:reverse(PosKw), kwonly => lists:reverse(KwOnly), vararg => VarArg, kwrest => KwRest};
function_param_info([posonly_marker | Rest], poskw, PosOnly, PosKw, KwOnly, VarArg, KwRest) ->
    function_param_info(Rest, poskw, PosKw ++ PosOnly, [], KwOnly, VarArg, KwRest);
function_param_info([kwonly_marker | Rest], _Section, PosOnly, PosKw, KwOnly, VarArg, KwRest) ->
    function_param_info(Rest, kwonly, PosOnly, PosKw, KwOnly, VarArg, KwRest);
function_param_info([{param, Name, _Default, _Annotation} | Rest], kwonly, PosOnly, PosKw, KwOnly, VarArg, KwRest) ->
    function_param_info(Rest, kwonly, PosOnly, PosKw, [Name | KwOnly], VarArg, KwRest);
function_param_info([{param, Name, _Default} | Rest], kwonly, PosOnly, PosKw, KwOnly, VarArg, KwRest) ->
    function_param_info(Rest, kwonly, PosOnly, PosKw, [Name | KwOnly], VarArg, KwRest);
function_param_info([{param, Name, _Default, _Annotation} | Rest], Section, PosOnly, PosKw, KwOnly, VarArg, KwRest) when Section =:= poskw ->
    function_param_info(Rest, poskw, PosOnly, [Name | PosKw], KwOnly, VarArg, KwRest);
function_param_info([{param, Name, _Default} | Rest], Section, PosOnly, PosKw, KwOnly, VarArg, KwRest) when Section =:= poskw ->
    function_param_info(Rest, poskw, PosOnly, [Name | PosKw], KwOnly, VarArg, KwRest);
function_param_info([{vararg, Name, _Annotation} | Rest], _Section, PosOnly, PosKw, KwOnly, _VarArg, KwRest) ->
    function_param_info(Rest, kwonly, PosOnly, PosKw, KwOnly, Name, KwRest);
function_param_info([{vararg, Name} | Rest], _Section, PosOnly, PosKw, KwOnly, _VarArg, KwRest) ->
    function_param_info(Rest, kwonly, PosOnly, PosKw, KwOnly, Name, KwRest);
function_param_info([{kwarg_rest, Name, _Annotation} | Rest], Section, PosOnly, PosKw, KwOnly, VarArg, _KwRest) ->
    function_param_info(Rest, Section, PosOnly, PosKw, KwOnly, VarArg, Name);
function_param_info([{kwarg_rest, Name} | Rest], Section, PosOnly, PosKw, KwOnly, VarArg, _KwRest) ->
    function_param_info(Rest, Section, PosOnly, PosKw, KwOnly, VarArg, Name).

positional_defaults(Params) ->
    [Value || Param <- positional_params(Params), {default, Value} <- [param_default(Param)]].

positional_params(Params) ->
    #{posonly := PosOnly, poskw := PosKw} = function_param_entries(Params),
    PosOnly ++ PosKw.

keyword_only_defaults(Params) ->
    [{param_name(Param), Value} || Param <- maps:get(kwonly, function_param_entries(Params)), {default, Value} <- [param_default(Param)]].

function_param_entries(Params) ->
    function_param_entries(Params, poskw, [], [], []).

function_param_entries([], _Section, PosOnly, PosKw, KwOnly) ->
    #{posonly => lists:reverse(PosOnly), poskw => lists:reverse(PosKw), kwonly => lists:reverse(KwOnly)};
function_param_entries([posonly_marker | Rest], poskw, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, poskw, PosKw ++ PosOnly, [], KwOnly);
function_param_entries([kwonly_marker | Rest], _Section, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, kwonly, PosOnly, PosKw, KwOnly);
function_param_entries([{param, _Name, _Default, _Annotation} = Param | Rest], kwonly, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, kwonly, PosOnly, PosKw, [Param | KwOnly]);
function_param_entries([{param, _Name, _Default} = Param | Rest], kwonly, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, kwonly, PosOnly, PosKw, [Param | KwOnly]);
function_param_entries([{param, _Name, _Default, _Annotation} = Param | Rest], poskw, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, poskw, PosOnly, [Param | PosKw], KwOnly);
function_param_entries([{param, _Name, _Default} = Param | Rest], poskw, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, poskw, PosOnly, [Param | PosKw], KwOnly);
function_param_entries([{vararg, _Name} | Rest], _Section, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, kwonly, PosOnly, PosKw, KwOnly);
function_param_entries([{vararg, _Name, _Annotation} | Rest], _Section, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, kwonly, PosOnly, PosKw, KwOnly);
function_param_entries([{kwarg_rest, _Name} | Rest], Section, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, Section, PosOnly, PosKw, KwOnly);
function_param_entries([{kwarg_rest, _Name, _Annotation} | Rest], Section, PosOnly, PosKw, KwOnly) ->
    function_param_entries(Rest, Section, PosOnly, PosKw, KwOnly).

param_name({param, Name, _Default, _Annotation}) ->
    Name;
param_name({param, Name, _Default}) ->
    Name.

param_default({param, _Name, Default, _Annotation}) ->
    Default;
param_default({param, _Name, Default}) ->
    Default.

optional_name(undefined) ->
    [];
optional_name(Name) ->
    [Name].

function_flags(Function, VarArg, KwRest) ->
    vararg_flag(VarArg) bor kwrest_flag(KwRest) bor mode_flag(function_mode(Function)).

vararg_flag(undefined) -> 0;
vararg_flag(_Name) -> 4.

kwrest_flag(undefined) -> 0;
kwrest_flag(_Name) -> 8.

function_mode({py_function, _Params, _Body, _Env}) ->
    false;
function_mode({py_function, _Params, _Body, _Env, Mode}) ->
    Mode;
function_mode({py_function, _Params, _Body, _Env, Mode, _Owner}) ->
    Mode.

mode_flag(true) -> 32;
mode_flag(async) -> 128;
mode_flag(async_generator) -> 512;
mode_flag(_Mode) -> 0.

function_set_attr(Function, Name, Value) ->
    trace_object_flow(function_set_attr_start, {Name, Function}),
    Attrs = function_attrs(),
    Key = function_attr_key(Function, Name),
    trace_object_flow(function_set_attr_key, Key),
    erlang:put(?PY_FUNCTION_ATTRS_KEY, maps:put(Key, Value, Attrs)),
    trace_object_flow(function_set_attr_done, {Name, Value}),
    ok.

function_attr_key({py_function, Params, Body, _Env}, Name) when Name =:= <<"__name__">>; Name =:= <<"__qualname__">>; Name =:= <<"__module__">> ->
    {py_function, Params, Body, Name};
function_attr_key({py_function, Params, Body, _Env, Mode}, Name) when Name =:= <<"__name__">>; Name =:= <<"__qualname__">>; Name =:= <<"__module__">> ->
    {py_function, Params, Body, Mode, Name};
function_attr_key({py_function, Params, Body, _Env, Mode, _Owner}, Name) when Name =:= <<"__name__">>; Name =:= <<"__qualname__">>; Name =:= <<"__module__">> ->
    {py_function, Params, Body, Mode, Name};
function_attr_key({py_function, Params, Body, Env}, Name) ->
    function_identity_attr_key(Params, Body, Env, false, undefined, Name);
function_attr_key({py_function, Params, Body, Env, Mode}, Name) ->
    function_identity_attr_key(Params, Body, Env, Mode, undefined, Name);
function_attr_key({py_function, Params, Body, Env, Mode, Owner}, Name) ->
    function_identity_attr_key(Params, Body, Env, Mode, Owner, Name);
function_attr_key(Function, Name) ->
    {py_function, Function, Name}.

function_identity_attr_key(Params, Body, Env, Mode, Owner, Name) ->
    case maps:get(?FUNCTION_ID_KEY, Env, undefined) of
        undefined -> {py_function_hash, erlang:phash2({Params, Body, Mode, Owner}), Name};
        Id -> {py_function_id, Id, Name}
    end.

function_attrs() ->
    case erlang:get(?PY_FUNCTION_ATTRS_KEY) of
        undefined -> #{};
        Attrs when is_map(Attrs) -> Attrs
    end.

trace_object_flow(Stage, Value) ->
    case os:getenv("PYRLANG_TRACE_NATIVE_FLOW") of
        false ->
            ok;
        _ ->
            io:format(standard_error, "PYRLANG_OBJECT ~p ~p~n", [Stage, trace_object_value(Value)])
    end.

trace_object_value({py_function, _Params, _Body, Env}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_object_value({py_function, _Params, _Body, Env, _Mode}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_object_value({py_function, _Params, _Body, Env, _Mode, _Owner}) when is_map(Env) ->
    {py_function, maps:get(<<"__name__">>, Env, undefined), maps:is_key(?FUNCTION_ID_KEY, Env)};
trace_object_value({py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        Type -> {py_ref, Type}
    catch
        _:_ -> Ref
    end;
trace_object_value({A, B}) ->
    {trace_object_value(A), trace_object_value(B)};
trace_object_value(Value) ->
    Value.

describe_value({py_ref, _} = Ref) ->
    try
        case pyrlang_heap:type(Ref) of
            class ->
                <<"class:", (class_name(Ref))/binary>>;
            instance ->
                Class = maps:get(class, pyrlang_heap:data(Ref)),
                <<"instance:", (class_name(Class))/binary>>;
            Type ->
                unicode:characters_to_binary(io_lib:format("~p", [Type]))
        end
    catch
        _:_ -> <<"ref">>
    end;
describe_value({py_exception_type, Type}) ->
    <<"exception_type:", Type/binary>>;
describe_value({py_super, Class, Instance}) ->
    <<"super:", (describe_value(Class))/binary, ":", (describe_value(Instance))/binary>>;
describe_value(Value) when is_binary(Value) ->
    Value;
describe_value(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

-spec descriptor(fun(), fun() | undefined) -> map().
descriptor(Get, Set) ->
    descriptor(Get, Set, #{}).

-spec descriptor(fun(), fun() | undefined, map()) -> map().
descriptor(Get, Set, Extra) when is_function(Get, 2) ->
    Extra#{py_descriptor => true, get => Get, set => Set}.

descriptor_get_attr(Descriptor, <<"__get__">>) ->
    {py_native_varargs, fun
        ([Obj]) -> descriptor_get(Descriptor, Obj, undefined);
        ([Obj, Class]) -> descriptor_get(Descriptor, Obj, Class);
        (Args) -> erlang:error({arity_error, {'descriptor.__get__', length(Args)}})
    end};
descriptor_get_attr(Descriptor, <<"__doc__">>) ->
    maps:get(doc, Descriptor, none);
descriptor_get_attr(Descriptor, <<"fget">>) ->
    maps:get(fget, Descriptor, none);
descriptor_get_attr(Descriptor, <<"fset">>) ->
    maps:get(fset, Descriptor, none);
descriptor_get_attr(Descriptor, <<"fdel">>) ->
    maps:get(fdel, Descriptor, none);
descriptor_get_attr(_Descriptor, Name) ->
    erlang:error({attribute_error, Name}).

-spec super() -> {py_super, term(), term()}.
super() ->
    case {erlang:get(pyrlang_current_class), erlang:get(pyrlang_current_self)} of
        {undefined, _} -> erlang:error(super_outside_method);
        {_, undefined} -> erlang:error(super_outside_method);
        {Class, Self} -> {py_super, Class, Self}
    end.

-spec super([term()]) -> {py_super, term(), term()}.
super([]) ->
    super();
super([Class]) ->
    {py_super, Class, Class};
super([Class, Instance]) ->
    {py_super, Class, Instance};
super(Args) ->
    erlang:error({arity_error, {super, length(Args)}}).

-spec call(term(), [term()]) -> term().
call({py_bound_method, Fun, Self}, Args) when is_function(Fun), is_list(Args) ->
    apply(Fun, [Self | Args]);
call(Fun, Args) when is_function(Fun), is_list(Args) ->
    apply(Fun, Args).

generic_alias_args_tuple(Args) when is_tuple(Args) ->
    Args;
generic_alias_args_tuple(Args) ->
    {Args}.

super_get_attr(Class, Instance, Name) ->
    Mro = super_mro(Class, Instance),
    Rest = drop_through_class(Class, Mro),
    case lookup_mro(Rest, Name) of
        {ok, #{py_descriptor := true} = Value} when Name =:= <<"__new__">> -> bind_attr(Value, Instance, Class);
        {ok, Value} when Name =:= <<"__new__">> -> Value;
        {ok, Value} -> bind_attr(Value, Instance, Class);
        error ->
            trace_super_miss(Class, Instance, Name, Mro, Rest),
            erlang:error({attribute_error, Name})
    end.

trace_super_miss(Class, Instance, Name, Mro, Rest) ->
    case os:getenv("PYRLANG_TRACE_SUPER") of
        false ->
            ok;
        _ ->
            io:format(
                standard_error,
                "PYRLANG_SUPER_MISS class=~s instance=~s name=~s mro=~p rest=~p stack=~p~n",
                [describe_value(Class), describe_value(Instance), Name, [describe_value(Value) || Value <- Mro], [describe_value(Value) || Value <- Rest], pyrlang_eval:trace_function_stack()]
            )
    end.

super_mro(Class, Instance) ->
    case pyrlang_heap:type(Instance) of
        class ->
            ClassMro = mro(Instance),
            case lists:member(Class, ClassMro) of
                true ->
                    ClassMro;
                false ->
                    case metaclass(Instance) of
                        undefined ->
                            ClassMro;
                        Metaclass ->
                            MetaclassMro = mro(Metaclass),
                            case lists:member(Class, MetaclassMro) of
                                true -> MetaclassMro;
                                false -> ClassMro
                            end
                    end
            end;
        instance ->
            mro(instance_class(Instance));
        list ->
            case list_instance_class(Instance) of
                {ok, ListClass} -> mro(ListClass);
                error -> []
            end;
        dict ->
            case dict_instance_class(Instance) of
                {ok, DictClass} -> mro(DictClass);
                error -> []
            end
    end.

instance_class(Instance) ->
    case pyrlang_heap:type(Instance) of
        instance ->
            maps:get(class, pyrlang_heap:data(Instance));
        list ->
            {ok, Class} = list_instance_class(Instance),
            Class;
        dict ->
            {ok, Class} = dict_instance_class(Instance),
            Class
    end.

drop_through_class(_Class, []) ->
    [];
drop_through_class(Class, [Class | Rest]) ->
    Rest;
drop_through_class(Class, [_Other | Rest]) ->
    drop_through_class(Class, Rest).

instance_get_attr(Instance, Name) ->
    Data = pyrlang_heap:data(Instance),
    Class = maps:get(class, Data),
    case lookup_data_descriptor(Class, Name) of
        {ok, Descriptor} ->
            descriptor_get(Descriptor, Instance, Class);
        error ->
            case Name of
                <<"__class__">> ->
                    Class;
                <<"__dict__">> ->
                    {py_instance_dict, Instance};
                _ ->
                    Attrs = maps:get(attrs, Data),
                    case maps:find(Name, Attrs) of
                        {ok, {py_lazy_type_alias_value, Expr, AliasEnv}} when Name =:= <<"__value__">> ->
                            {Value, _Env1} = pyrlang_eval:eval_expr(Expr, AliasEnv),
                            Value;
                        {ok, Value} ->
                            Value;
                        error ->
                            case lookup_class_attr(Class, Name) of
                                {ok, Value} -> bind_attr(Value, Instance, Class);
                                error -> missing_instance_attr(Instance, Class, Name)
                            end
                    end
            end
    end.

missing_instance_attr(_Instance, _Class, <<"__getattr__">>) ->
    erlang:error({attribute_error, <<"__getattr__">>});
missing_instance_attr(Instance, Class, Name) ->
    case string_subclass_value(Instance) of
        {ok, Value} ->
            case pyrlang_eval:builtin_attribute(Value, Name) of
                {ok, Attr} -> Attr;
                error -> missing_instance_attr_getattr(Instance, Class, Name)
            end;
        error ->
            missing_instance_attr_getattr(Instance, Class, Name)
    end.

missing_instance_attr_getattr(Instance, Class, Name) ->
    case lookup_class_attr(Class, <<"__getattr__">>) of
        {ok, Getattr} ->
            pyrlang_eval:call(bind_attr(Getattr, Instance, Class), [Name]);
        error ->
            erlang:error({attribute_error, Name})
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
    end.

is_string_subclass_instance({py_ref, _} = Ref) ->
    Class = pyrlang_builtins:object_class(Ref),
    lists:any(
        fun(MroClass) -> class_named(MroClass, <<"str">>) end,
        pyrlang_object:mro(Class)
    ).

class_named({py_ref, _} = Class, Name) ->
    try pyrlang_heap:type(Class) =:= class andalso class_name(Class) =:= Name
    catch
        _:_ -> false
    end;
class_named(_Class, _Name) ->
    false.

class_get_attr(Class, <<"__dict__">>) ->
    Data = pyrlang_heap:data(Class),
    pyrlang_heap:dict(public_class_attr_items(maps:get(attrs, Data)));
class_get_attr(Class, <<"__name__">>) ->
    class_name(Class);
class_get_attr(Class, <<"__qualname__">>) ->
    class_name(Class);
class_get_attr(Class, <<"__module__">>) ->
    Data = pyrlang_heap:data(Class),
    Attrs = maps:get(attrs, Data),
    maps:get(<<"__module__">>, Attrs, <<"builtins">>);
class_get_attr(Class, <<"__doc__">>) ->
    Data = pyrlang_heap:data(Class),
    Attrs = maps:get(attrs, Data),
    maps:get(<<"__doc__">>, Attrs, none);
class_get_attr(Class, <<"__bases__">>) ->
    list_to_tuple(bases(Class));
class_get_attr(Class, <<"__mro__">>) ->
    list_to_tuple(mro(Class));
class_get_attr(Class, <<"__subclasses__">>) ->
    {py_native_varargs, fun
        ([]) -> pyrlang_heap:list(subclasses(Class));
        (Args) -> erlang:error({arity_error, {'__subclasses__', length(Args)}})
    end};
class_get_attr(Class, <<"mro">>) ->
    {py_native_varargs, fun
        ([]) -> pyrlang_heap:list(mro(Class));
        ([Target]) -> pyrlang_heap:list(mro(Target));
        (Args) -> erlang:error({arity_error, {mro, length(Args)}})
    end};
class_get_attr(Class, Name) ->
    case lookup_class_attr(Class, Name) of
        {ok, Value} -> bind_class_attr(Value, Class);
        error ->
            case maps:get(metaclass, pyrlang_heap:data(Class), undefined) of
                undefined ->
                    erlang:error({attribute_error, Name});
                Metaclass ->
                    case lookup_class_attr(Metaclass, Name) of
                        {ok, Value} -> bind_attr(Value, Class, Metaclass);
                        error -> erlang:error({attribute_error, Name})
                    end
            end
    end.

lookup_data_descriptor(Class, Name) ->
    case lookup_class_attr(Class, Name) of
        {ok, Value} ->
            case is_data_descriptor(Value) of
                true -> {ok, Value};
                false -> error
            end;
        error ->
            error
    end.

lookup_class_attr(Class, Name) ->
    lookup_mro(mro(Class), Name).

public_class_attrs(Attrs) ->
    maps:filter(fun(Name, _Value) -> not is_internal_attr(Name) end, Attrs).

public_class_attr_items(Attrs) ->
    Public = public_class_attrs(Attrs),
    Ordered = [Name || Name <- maps:get(?CLASS_ATTR_ORDER_KEY, Attrs, []), maps:is_key(Name, Public)],
    Remaining = [Name || Name <- maps:keys(Public), not lists:member(Name, Ordered)],
    [{Name, maps:get(Name, Public)} || Name <- Ordered ++ Remaining].

put_class_attr(Name, Value, Attrs) ->
    Attrs1 =
        case maps:is_key(Name, Attrs) orelse is_internal_attr(Name) of
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

is_internal_attr(<<"__pyrlang_", _Rest/binary>>) ->
    true;
is_internal_attr(_Name) ->
    false.

lookup_mro([], _Name) ->
    error;
lookup_mro([{py_exception_type, Type} | Rest], Name) ->
    case maps:find(Name, exception_type_attrs(Type)) of
        {ok, Value} -> {ok, Value};
        error -> lookup_mro(Rest, Name)
    end;
lookup_mro([Class | Rest], Name) ->
    Data = pyrlang_heap:data(Class),
    Attrs = maps:get(attrs, Data),
    case maps:find(Name, Attrs) of
        {ok, Value} -> {ok, Value};
        error -> lookup_mro(Rest, Name)
    end.

subclasses(Class) ->
    maps:get(pyrlang_heap:value_key(Class), subclass_registry(), []).

register_subclasses(_Class, []) ->
    ok;
register_subclasses(Class, [Base | Rest]) ->
    Registry = subclass_registry(),
    Key = pyrlang_heap:value_key(Base),
    Existing = maps:get(Key, Registry, []),
    Updated =
        case lists:member(Class, Existing) of
            true -> Existing;
            false -> Existing ++ [Class]
        end,
    erlang:put(?PY_SUBCLASSES_KEY, Registry#{Key => Updated}),
    register_subclasses(Class, Rest).

subclass_registry() ->
    case erlang:get(?PY_SUBCLASSES_KEY) of
        Registry when is_map(Registry) -> Registry;
        _ -> #{}
    end.

bind_attr(Value, Instance, Class) ->
    case is_descriptor(Value) of
        true -> descriptor_get(Value, Instance, Class);
        false when is_function(Value) -> {py_bound_method, Value, Instance};
        false -> maybe_bind_py_function(Value, Instance)
    end.

maybe_bind_py_function({py_function, _Params, _Body, _Env} = Value, Instance) ->
    {py_bound_method, Value, Instance};
maybe_bind_py_function({py_function, _Params, _Body, _Env, _IsGenerator} = Value, Instance) ->
    {py_bound_method, Value, Instance};
maybe_bind_py_function({py_function, _Params, _Body, _Env, _IsGenerator, _Owner} = Value, Instance) ->
    {py_bound_method, Value, Instance};
maybe_bind_py_function({py_native_varargs, _Fun} = Value, Instance) ->
    {py_bound_method, Value, Instance};
maybe_bind_py_function({py_native_varargs, _Fun, no_bind} = Value, _Instance) ->
    Value;
maybe_bind_py_function({py_native_varargs, _Fun, _Bind} = Value, Instance) ->
    {py_bound_method, Value, Instance};
maybe_bind_py_function({py_native_call, _Fun} = Value, Instance) ->
    {py_bound_method, Value, Instance};
maybe_bind_py_function({py_native_call, _Fun, no_bind} = Value, _Instance) ->
    Value;
maybe_bind_py_function({py_native_call, _Fun, _Bind} = Value, Instance) ->
    {py_bound_method, Value, Instance};
maybe_bind_py_function({py_native_callable, _Fun} = Value, _Instance) ->
    Value;
maybe_bind_py_function({py_native_callable, _Fun, _Bind} = Value, _Instance) ->
    Value;
maybe_bind_py_function(Value, _Instance) ->
    Value.

bind_function_owners(Class, Attrs) ->
    maps:map(fun(Name, Value) -> bind_function_owner(Class, Name, Value) end, Attrs).

bind_function_owner(Class, <<"__init_subclass__">>, Value) ->
    Callable = bind_function_owner(Class, Value),
    descriptor(
        fun(_Obj, TargetClass) -> {py_bound_method, Callable, TargetClass} end,
        undefined,
        #{kind => classmethod, callable => Callable}
    );
bind_function_owner(Class, _Name, Value) ->
    bind_function_owner(Class, Value).

bind_function_owner(Class, {py_function, Params, Body, Env}) ->
    {py_function, Params, Body, Env, false, Class};
bind_function_owner(Class, {py_function, Params, Body, Env, IsGenerator}) ->
    {py_function, Params, Body, Env, IsGenerator, Class};
bind_function_owner(Class, #{py_descriptor := true, kind := property} = Descriptor) ->
    case maps:is_key(fget, Descriptor) orelse maps:is_key(fset, Descriptor) orelse maps:is_key(fdel, Descriptor) of
        true -> bind_property_function_owner(Class, Descriptor);
        false -> Descriptor
    end;
bind_function_owner(Class, #{py_descriptor := true, callable := Callable} = Descriptor) ->
    Descriptor#{callable := bind_function_owner(Class, Callable)};
bind_function_owner(Class, {py_ref, _} = Ref) ->
    case has_descriptor_method(Ref, <<"__get__">>) of
        true -> bind_instance_function_attrs(Class, Ref);
        false -> ok
    end,
    Ref;
bind_function_owner(_Class, Value) ->
    Value.

bind_property_function_owner(Class, Descriptor) ->
    Getter = bind_optional_property_callable(Class, maps:get(fget, Descriptor, none)),
    Setter = bind_optional_property_callable(Class, maps:get(fset, Descriptor, none)),
    Deleter = bind_optional_property_callable(Class, maps:get(fdel, Descriptor, none)),
    Get =
        case Getter of
            none -> fun(_Obj, _OwnerClass) -> none end;
            _ -> fun(Obj, _OwnerClass) -> pyrlang_eval:call(Getter, [Obj]) end
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

bind_optional_property_callable(_Class, none) ->
    none;
bind_optional_property_callable(Class, Callable) ->
    bind_function_owner(Class, Callable).

bind_instance_function_attrs(Class, {py_ref, _} = Ref) ->
    try pyrlang_heap:type(Ref) of
        instance ->
            Data = pyrlang_heap:data(Ref),
            Attrs = maps:get(attrs, Data, #{}),
            UpdatedAttrs = maps:map(fun(_Name, Value) -> bind_function_owner(Class, Value) end, Attrs),
            ok = pyrlang_heap:set_data(Ref, Data#{attrs := UpdatedAttrs});
        _ ->
            ok
    catch
        _:_ -> ok
    end.

notify_set_name(Class, Attrs) ->
    maps:foreach(fun(Name, Value) -> maybe_call_set_name(Class, Name, Value) end, Attrs).

maybe_call_set_name(Class, Name, Value) ->
    try get_attr(Value, <<"__set_name__">>) of
        SetName ->
            _ = pyrlang_eval:call(SetName, [Class, Name]),
            ok
    catch
        error:{attribute_error, _Attr} ->
            ok;
        throw:{py_exception, Exception} ->
            case pyrlang_exception:exception_type(Exception) of
                <<"AttributeError">> -> ok;
                _ -> pyrlang_exception:raise(Exception)
            end
    end.

bind_class_attr(Value, Class) ->
    case is_descriptor(Value) of
        true -> descriptor_get(Value, undefined, Class);
        false -> Value
    end.

is_descriptor(Value) when is_map(Value) ->
    maps:get(py_descriptor, Value, false) =:= true andalso maps:is_key(get, Value);
is_descriptor({py_ref, _} = Value) ->
    has_descriptor_method(Value, <<"__get__">>);
is_descriptor(_Value) ->
    false.

is_data_descriptor(#{kind := property}) ->
    true;
is_data_descriptor(Value) when is_map(Value) ->
    is_descriptor(Value) andalso (
        maps:get(set, Value, undefined) =/= undefined orelse
        maps:get(del, Value, undefined) =/= undefined
    );
is_data_descriptor({py_ref, _} = Value) ->
    is_descriptor(Value) andalso (
        has_descriptor_method(Value, <<"__set__">>) orelse
        has_descriptor_method(Value, <<"__delete__">>)
    );
is_data_descriptor(_Value) ->
    false.

has_descriptor_method({py_ref, _} = Value, Name) ->
    try
        case pyrlang_heap:type(Value) of
            instance ->
                Class = maps:get(class, pyrlang_heap:data(Value)),
                pyrlang_object:class_attr(Class, Name) =/= error;
            class ->
                case metaclass(Value) of
                    undefined -> false;
                    Metaclass -> pyrlang_object:class_attr(Metaclass, Name) =/= error
                end;
            _ ->
                false
        end
    catch
        _:_ -> false
    end.

descriptor_get(#{kind := classmethod, callable := Callable}, _Instance, Class) ->
    {py_bound_method, Callable, Class};
descriptor_get(#{kind := staticmethod, callable := Callable}, _Instance, _Class) ->
    Callable;
descriptor_get(#{kind := property} = Descriptor, undefined, _Class) ->
    Descriptor;
descriptor_get({py_ref, _} = Descriptor, Instance0, Class0) ->
    Instance = descriptor_arg(Instance0),
    Class = descriptor_arg(Class0),
    pyrlang_eval:call(get_attr(Descriptor, <<"__get__">>), [Instance, Class]);
descriptor_get(Descriptor, Instance, Class) ->
    Get = maps:get(get, Descriptor),
    Get(Instance, Class).

descriptor_set(Descriptor, Instance, Value) when is_map(Descriptor) ->
    case maps:get(set, Descriptor, undefined) of
        undefined -> erlang:error({attribute_error, readonly_descriptor});
        Set when is_function(Set, 2) -> Set(Instance, Value)
    end;
descriptor_set({py_ref, _} = Descriptor, Instance, Value) ->
    try
        _ = pyrlang_eval:call(get_attr(Descriptor, <<"__set__">>), [Instance, Value]),
        ok
    catch
        error:{attribute_error, _Attr} -> erlang:error({attribute_error, readonly_descriptor})
    end.

descriptor_delete(Descriptor, Instance) when is_map(Descriptor) ->
    case maps:get(del, Descriptor, undefined) of
        undefined -> erlang:error({attribute_error, readonly_descriptor});
        Del when is_function(Del, 1) -> Del(Instance)
    end;
descriptor_delete({py_ref, _} = Descriptor, Instance) ->
    try
        _ = pyrlang_eval:call(get_attr(Descriptor, <<"__delete__">>), [Instance]),
        ok
    catch
        error:{attribute_error, _Attr} -> erlang:error({attribute_error, readonly_descriptor})
    end.

descriptor_arg(undefined) ->
    none;
descriptor_arg(Value) ->
    Value.

-spec is_exception_class(term()) -> boolean().
is_exception_class({py_ref, _} = Class) ->
    try
        pyrlang_heap:type(Class) =:= class andalso
            lists:any(fun is_exception_mro_entry/1, mro(Class))
    catch
        _:_ -> false
    end;
is_exception_class(_Class) ->
    false.

-spec is_exception_instance(term()) -> boolean().
is_exception_instance({py_ref, _} = Instance) ->
    try
        pyrlang_heap:type(Instance) =:= instance andalso
            is_exception_class(maps:get(class, pyrlang_heap:data(Instance)))
    catch
        _:_ -> false
    end;
is_exception_instance(_Instance) ->
    false.

-spec exception_class_matches(term(), binary()) -> boolean().
exception_class_matches(Class, Expected) ->
    is_exception_class(Class) andalso
        lists:any(
            fun
                ({py_exception_type, Type}) -> pyrlang_exception:type_matches(Type, Expected);
                (_Other) -> false
            end,
            mro(Class)
        ).

is_exception_mro_entry({py_exception_type, _Type}) ->
    true;
is_exception_mro_entry(_Other) ->
    false.

list_instance_class(Ref) ->
    case pyrlang_heap:data(Ref) of
        #{class := Class} -> {ok, Class};
        _ -> error
    end.

list_instance_attrs(Ref) ->
    Data = pyrlang_heap:data(Ref),
    maps:get(attrs, Data).

list_set_attr(Ref, Name, Value) ->
    case list_instance_class(Ref) of
        {ok, Class} ->
            case lookup_data_descriptor(Class, Name) of
                {ok, Descriptor} ->
                    descriptor_set(Descriptor, Ref, Value);
                error ->
                    Data = pyrlang_heap:data(Ref),
                    Attrs = maps:get(attrs, Data),
                    pyrlang_heap:set_data(Ref, Data#{attrs := maps:put(Name, Value, Attrs)})
            end;
        error ->
            erlang:error({attribute_error, Name})
    end.

list_get_attr(Ref, Name) ->
    case list_instance_class(Ref) of
        {ok, Class} -> list_instance_get_attr(Ref, Class, Name);
        error -> list_builtin_get_attr(Ref, Name)
    end.

list_instance_get_attr(_Ref, Class, <<"__class__">>) ->
    Class;
list_instance_get_attr(Ref, _Class, <<"__dict__">>) ->
    {py_instance_dict, Ref};
list_instance_get_attr(Ref, Class, Name) ->
    case lookup_data_descriptor(Class, Name) of
        {ok, Descriptor} ->
            descriptor_get(Descriptor, Ref, Class);
        error ->
            Attrs = list_instance_attrs(Ref),
            case maps:find(Name, Attrs) of
                {ok, Value} ->
                    Value;
                error ->
                    case lookup_class_attr(Class, Name) of
                        {ok, Value} -> bind_attr(Value, Ref, Class);
                        error -> missing_list_instance_attr(Ref, Class, Name)
                    end
            end
    end.

missing_list_instance_attr(Ref, Class, Name) ->
    try list_builtin_get_attr(Ref, Name) of
        Value ->
            Value
    catch
        error:{attribute_error, _Name} ->
            case lookup_class_attr(Class, <<"__getattr__">>) of
                {ok, Getattr} -> pyrlang_eval:call(bind_attr(Getattr, Ref, Class), [Name]);
                error -> erlang:error({attribute_error, Name})
            end
    end.

list_builtin_get_attr(Ref, <<"append">>) ->
    fun(Value) ->
        ok = pyrlang_heap:list_append(Ref, Value),
        none
    end;
list_builtin_get_attr(Ref, <<"__contains__">>) ->
    fun(Value) ->
        python_member(Value, pyrlang_heap:list_items(Ref))
    end;
list_builtin_get_attr(Ref, <<"__getitem__">>) ->
    fun(Index) ->
        pyrlang_heap:list_get(Ref, Index)
    end;
list_builtin_get_attr(Ref, <<"__setitem__">>) ->
    fun(Index, Value) ->
        ok = pyrlang_heap:list_set(Ref, Index, Value),
        none
    end;
list_builtin_get_attr(Ref, <<"extend">>) ->
    fun(Other) ->
        lists:foreach(fun(Value) -> ok = pyrlang_heap:list_append(Ref, Value) end, iterable_values(Other)),
        none
    end;
list_builtin_get_attr(Ref, <<"clear">>) ->
    fun() ->
        ok = pyrlang_heap:set_data(Ref, []),
        none
    end;
list_builtin_get_attr(Ref, <<"count">>) ->
    fun(Value) ->
        length([Item || Item <- pyrlang_heap:list_items(Ref), python_equal(Value, Item)])
    end;
list_builtin_get_attr(Ref, <<"index">>) ->
    {py_native_varargs, fun(Args) -> list_index(Ref, Args) end};
list_builtin_get_attr(Ref, <<"insert">>) ->
    fun(Index, Value) ->
        ok = pyrlang_heap:list_insert(Ref, Index, Value),
        none
    end;
list_builtin_get_attr(Ref, <<"remove">>) ->
    fun(Value) ->
        case list_remove_first(pyrlang_heap:list_items(Ref), Value, []) of
            {ok, Items} ->
                ok = pyrlang_heap:set_data(Ref, Items),
                none;
            error ->
                pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), Value))
        end
    end;
list_builtin_get_attr(Ref, <<"reverse">>) ->
    fun() ->
        ok = pyrlang_heap:set_data(Ref, lists:reverse(pyrlang_heap:list_items(Ref))),
        none
    end;
list_builtin_get_attr(Ref, <<"pop">>) ->
    {py_native_varargs, fun(Args) -> list_pop(Ref, Args) end};
list_builtin_get_attr(Ref, <<"sort">>) ->
    {py_native_call, fun(Args, KwArgs) ->
        list_sort(Ref, Args, KwArgs),
        none
    end};
list_builtin_get_attr(_Ref, Name) ->
    erlang:error({attribute_error, Name}).

list_remove_first([], _Value, _Prefix) ->
    error;
list_remove_first([Item | Rest], Value, Prefix) ->
    case python_equal(Value, Item) of
        true -> {ok, lists:reverse(Prefix) ++ Rest};
        false -> list_remove_first(Rest, Value, [Item | Prefix])
    end.

list_index(Ref, [Value]) ->
    list_index(Ref, [Value, 0, undefined]);
list_index(Ref, [Value, Start]) ->
    list_index(Ref, [Value, Start, undefined]);
list_index(Ref, [Value, Start0, Stop0]) ->
    Items = pyrlang_heap:list_items(Ref),
    Start = list_index_bound(Start0, length(Items), 0),
    Stop = list_index_bound(Stop0, length(Items), length(Items)),
    case list_index_from(Items, Value, Start, Stop, 0) of
        {ok, Index} ->
            Index;
        error ->
            pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"ValueError">>), <<"list.index(x): x not in list">>))
    end;
list_index(_Ref, Args) ->
    erlang:error({arity_error, {list_index, length(Args)}}).

list_index_bound(undefined, _Length, Default) ->
    Default;
list_index_bound(none, _Length, Default) ->
    Default;
list_index_bound(Value, Length, _Default) ->
    Index = list_index_value(Value),
    if
        Index < 0 -> max(0, Length + Index);
        Index > Length -> Length;
        true -> Index
    end.

list_index_from([], _Value, _Start, _Stop, _Index) ->
    error;
list_index_from([_Item | Rest], Value, Start, Stop, Index) when Index < Start ->
    list_index_from(Rest, Value, Start, Stop, Index + 1);
list_index_from(_Items, _Value, _Start, Stop, Index) when Index >= Stop ->
    error;
list_index_from([Item | Rest], Value, Start, Stop, Index) ->
    case python_equal(Value, Item) of
        true -> {ok, Index};
        false -> list_index_from(Rest, Value, Start, Stop, Index + 1)
    end.

list_pop(Ref, Args) ->
    Items = pyrlang_heap:list_items(Ref),
    case Items of
        [] ->
            pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"IndexError">>), <<"pop from empty list">>));
        _ ->
            Index =
                case Args of
                    [] -> length(Items) - 1;
                    [Index0] -> list_index_value(Index0);
                    _ -> erlang:error({arity_error, {list_pop, length(Args)}})
                end,
            ZeroIndex = normalize_list_index(Index, length(Items)),
            {Before, [Value | After]} = lists:split(ZeroIndex, Items),
            ok = pyrlang_heap:set_data(Ref, Before ++ After),
            Value
    end.

list_index_value(true) -> 1;
list_index_value(false) -> 0;
list_index_value(Index) when is_integer(Index) -> Index;
list_index_value({py_ref, _} = Index) ->
    case pyrlang_builtins:int_subclass_value(Index) of
        {ok, Value} -> Value;
        error -> object_index_value(Index)
    end;
list_index_value(Index) ->
    erlang:error({type_error, {list_index, Index}}).

object_index_value(Object) ->
    try pyrlang_object:get_attr(Object, <<"__index__">>) of
        Method ->
            case pyrlang_eval:call(Method, []) of
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

normalize_list_index(Index, Length) when Index < 0 ->
    Normalized = Length + Index,
    case Normalized >= 0 of
        true -> Normalized;
        false -> pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"IndexError">>), <<"pop index out of range">>))
    end;
normalize_list_index(Index, Length) when Index >= 0, Index < Length ->
    Index;
normalize_list_index(_Index, _Length) ->
    pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"IndexError">>), <<"pop index out of range">>)).

list_sort(Ref, [], KwArgs) ->
    Key = maps:get(<<"key">>, KwArgs, none),
    Reverse = maps:get(<<"reverse">>, KwArgs, false),
    Unknown = maps:keys(maps:without([<<"key">>, <<"reverse">>], KwArgs)),
    case Unknown of
        [] ->
            Items = pyrlang_heap:list_items(Ref),
            Decorated = [{list_sort_key(Key, Item), Item} || Item <- Items],
            Sorted = [Item || {_SortKey, Item} <- lists:sort(Decorated)],
            Final =
                case Reverse of
                    true -> lists:reverse(Sorted);
                    _ -> Sorted
                end,
            pyrlang_heap:set_data(Ref, Final);
        _ ->
            erlang:error({type_error, {unexpected_keyword_argument, Unknown}})
    end;
list_sort(_Ref, Args, _KwArgs) ->
    erlang:error({arity_error, {list_sort, length(Args)}}).

list_sort_key(none, Item) ->
    Item;
list_sort_key(Key, Item) ->
    pyrlang_eval:call(Key, [Item]).

dict_instance_class(Ref) ->
    case pyrlang_heap:data(Ref) of
        #{class := Class} -> {ok, Class};
        _ -> error
    end.

dict_instance_attrs(Ref) ->
    Data = pyrlang_heap:data(Ref),
    maps:get(attrs, Data).

dict_set_attr(Ref, Name, Value) ->
    case dict_instance_class(Ref) of
        {ok, Class} ->
            case lookup_data_descriptor(Class, Name) of
                {ok, Descriptor} ->
                    descriptor_set(Descriptor, Ref, Value);
                error ->
                    Data = pyrlang_heap:data(Ref),
                    Attrs = maps:get(attrs, Data),
                    pyrlang_heap:set_data(Ref, Data#{attrs := maps:put(Name, Value, Attrs)})
            end;
        error ->
            erlang:error({attribute_error, Name})
    end.

dict_get_attr(Ref, Name) ->
    case dict_instance_class(Ref) of
        {ok, Class} -> dict_instance_get_attr(Ref, Class, Name);
        error -> dict_builtin_get_attr(Ref, Name)
    end.

dict_instance_get_attr(_Ref, Class, <<"__class__">>) ->
    Class;
dict_instance_get_attr(Ref, _Class, <<"__dict__">>) ->
    {py_instance_dict, Ref};
dict_instance_get_attr(Ref, Class, Name) ->
    case lookup_data_descriptor(Class, Name) of
        {ok, Descriptor} ->
            descriptor_get(Descriptor, Ref, Class);
        error ->
            Attrs = dict_instance_attrs(Ref),
            case maps:find(Name, Attrs) of
                {ok, Value} ->
                    Value;
                error ->
                    case lookup_class_attr(Class, Name) of
                        {ok, Value} -> bind_attr(Value, Ref, Class);
                        error -> missing_dict_instance_attr(Ref, Class, Name)
                    end
            end
    end.

missing_dict_instance_attr(Ref, Class, Name) ->
    try dict_builtin_get_attr(Ref, Name) of
        Value ->
            Value
    catch
        error:{attribute_error, _Name} ->
            case lookup_class_attr(Class, <<"__getattr__">>) of
                {ok, Getattr} -> pyrlang_eval:call(bind_attr(Getattr, Ref, Class), [Name]);
                error -> erlang:error({attribute_error, Name})
            end
    end.

dict_builtin_get_attr(Ref, <<"get">>) ->
    {py_native_varargs, fun
        ([Key]) ->
            dict_lookup(Ref, Key, none);
        ([Key, Default]) ->
            dict_lookup(Ref, Key, Default);
        (Args) ->
            erlang:error({arity_error, {dict_get, length(Args)}})
    end};
dict_builtin_get_attr(Ref, <<"set">>) ->
    fun(Key, Value) ->
        ok = pyrlang_heap:dict_put(Ref, Key, Value),
        none
    end;
dict_builtin_get_attr(Ref, <<"clear">>) ->
    fun() ->
        ok = pyrlang_heap:set_data(Ref, #{}),
        none
    end;
dict_builtin_get_attr(Ref, <<"copy">>) ->
    fun() ->
        pyrlang_heap:dict(pyrlang_heap:dict_items(Ref))
    end;
dict_builtin_get_attr(Ref, <<"__getitem__">>) ->
    fun(Key) ->
        pyrlang_heap:dict_get(Ref, Key)
    end;
dict_builtin_get_attr(Ref, <<"__setitem__">>) ->
    fun(Key, Value) ->
        ok = pyrlang_heap:dict_put(Ref, Key, Value),
        none
    end;
dict_builtin_get_attr(Ref, <<"__delitem__">>) ->
    fun(Key) ->
        ok = pyrlang_heap:dict_del(Ref, Key),
        none
    end;
dict_builtin_get_attr(Ref, <<"setdefault">>) ->
    {py_native_varargs, fun
        ([Key]) ->
            dict_setdefault(Ref, Key, none);
        ([Key, Default]) ->
            dict_setdefault(Ref, Key, Default);
        (Args) ->
            erlang:error({arity_error, {dict_setdefault, length(Args)}})
    end};
dict_builtin_get_attr(Ref, <<"pop">>) ->
    {py_native_varargs, fun
        ([Key]) ->
            dict_pop(Ref, Key, no_default);
        ([Key, Default]) ->
            dict_pop(Ref, Key, {default, Default});
        (Args) ->
            erlang:error({arity_error, {dict_pop, length(Args)}})
    end};
dict_builtin_get_attr(Ref, <<"update">>) ->
    {py_native_call, fun(Args, KwArgs) ->
        dict_update(Ref, Args, KwArgs),
        none
    end};
dict_builtin_get_attr(Ref, <<"keys">>) ->
    fun() ->
        pyrlang_heap:list([Key || {Key, _Value} <- pyrlang_heap:dict_items(Ref)])
    end;
dict_builtin_get_attr(Ref, <<"values">>) ->
    fun() ->
        pyrlang_heap:list([Value || {_Key, Value} <- pyrlang_heap:dict_items(Ref)])
    end;
dict_builtin_get_attr(Ref, <<"items">>) ->
    fun() ->
        pyrlang_heap:list([{Key, Value} || {Key, Value} <- pyrlang_heap:dict_items(Ref)])
    end;
dict_builtin_get_attr(Ref, <<"__contains__">>) ->
    fun(Key) ->
        pyrlang_heap:dict_contains(Ref, Key)
    end;
dict_builtin_get_attr(Ref, <<"_member_names">>) ->
    case pyrlang_heap:dict_find(Ref, <<"_member_names">>) of
        {ok, Value} -> Value;
        error -> erlang:error({attribute_error, <<"_member_names">>})
    end;
dict_builtin_get_attr(_Ref, Name) ->
    erlang:error({attribute_error, Name}).

dict_lookup(Ref, Key, Default) ->
    case pyrlang_heap:dict_find(Ref, Key) of
        {ok, Value} -> Value;
        error -> Default
    end.

dict_setdefault(Ref, Key, Default) ->
    case pyrlang_heap:dict_find(Ref, Key) of
        {ok, Value} ->
            Value;
        error ->
            ok = pyrlang_heap:dict_put(Ref, Key, Default),
            Default
    end.

dict_pop(Ref, Key, Default) ->
    case pyrlang_heap:dict_find(Ref, Key) of
        {ok, Value} ->
            ok = pyrlang_heap:dict_del(Ref, Key),
            Value;
        error ->
            case Default of
                {default, Value} -> Value;
                no_default -> pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Key))
            end
    end.

dict_update(Ref, [], KwArgs) ->
    maps:foreach(fun(Key, Value) -> ok = pyrlang_heap:dict_put(Ref, Key, Value) end, KwArgs);
dict_update(Ref, [Other], KwArgs) ->
    lists:foreach(fun({Key, Value}) -> ok = pyrlang_heap:dict_put(Ref, Key, Value) end, dict_update_items(Other)),
    dict_update(Ref, [], KwArgs);
dict_update(_Ref, Args, _KwArgs) ->
    erlang:error({arity_error, {dict_update, length(Args)}}).

dict_update_items({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        dict -> pyrlang_heap:dict_items(Ref);
        _Type ->
            case dict_mapping_items(Ref) of
                {ok, Items} -> Items;
                error -> [dict_update_pair(Item) || Item <- iterable_values(Ref)]
            end
    end;
dict_update_items({py_instance_dict, Instance}) ->
    Data = pyrlang_heap:data(Instance),
    maps:to_list(maps:get(attrs, Data, #{}));
dict_update_items({py_module_dict, ModuleRef}) ->
    maps:to_list(pyrlang_module:env(ModuleRef));
dict_update_items(Map) when is_map(Map) ->
    maps:to_list(Map);
dict_update_items(Iterable) ->
    [dict_update_pair(Item) || Item <- iterable_values(Iterable)].

dict_mapping_items(Object) ->
    try pyrlang_object:get_attr(Object, <<"keys">>) of
        KeysCallable ->
            Keys = pyrlang_eval:call(KeysCallable, []),
            GetItem = pyrlang_object:get_attr(Object, <<"__getitem__">>),
            {ok, [{Key, pyrlang_eval:call(GetItem, [Key])} || Key <- iterable_values(Keys)]}
    catch
        _:_ -> error
    end.

dict_update_pair({py_ref, _} = Ref) ->
    case pyrlang_heap:type(Ref) of
        list ->
            case pyrlang_heap:list_items(Ref) of
                [Key, Value] -> {Key, Value};
                Items -> erlang:error({type_error, {bad_dict_pair, Items}})
            end;
        _Type ->
            erlang:error({type_error, {bad_dict_pair, Ref}})
    end;
dict_update_pair({Key, Value}) ->
    {Key, Value};
dict_update_pair([Key, Value]) ->
    {Key, Value};
dict_update_pair(Other) when is_tuple(Other), tuple_size(Other) =:= 2 ->
    {element(1, Other), element(2, Other)};
dict_update_pair(Other) ->
    erlang:error({type_error, {bad_dict_pair, Other}}).

set_get_attr(Ref, <<"add">>) ->
    fun(Value) ->
        ok = pyrlang_heap:set_add(Ref, Value),
        none
    end;
set_get_attr(Ref, <<"discard">>) ->
    fun(Value) ->
        ok = pyrlang_heap:set_remove(Ref, Value),
        none
    end;
set_get_attr(Ref, <<"remove">>) ->
    fun(Value) ->
        case pyrlang_heap:set_contains(Ref, Value) of
            true ->
                ok = pyrlang_heap:set_remove(Ref, Value),
                none;
            false ->
                pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), Value))
        end
    end;
set_get_attr(Ref, <<"union">>) ->
    {py_native_varargs, fun(Args) ->
        Items = pyrlang_heap:set_items(Ref) ++ lists:append([iterable_values(Arg) || Arg <- Args]),
        pyrlang_heap:set(Items)
    end};
set_get_attr(Ref, <<"copy">>) ->
    fun() ->
        pyrlang_heap:set(pyrlang_heap:set_items(Ref))
    end;
set_get_attr(Ref, <<"difference">>) ->
    {py_native_varargs, fun(Args) ->
        pyrlang_heap:set(set_difference_items(pyrlang_heap:set_items(Ref), Args))
    end};
set_get_attr(Ref, <<"difference_update">>) ->
    {py_native_varargs, fun(Args) ->
        ok = pyrlang_heap:set_data(Ref, keyed_set_items(set_difference_items(pyrlang_heap:set_items(Ref), Args))),
        none
    end};
set_get_attr(Ref, <<"intersection">>) ->
    {py_native_varargs, fun(Args) ->
        pyrlang_heap:set(set_intersection_items(pyrlang_heap:set_items(Ref), Args))
    end};
set_get_attr(Ref, <<"intersection_update">>) ->
    {py_native_varargs, fun(Args) ->
        ok = pyrlang_heap:set_data(Ref, keyed_set_items(set_intersection_items(pyrlang_heap:set_items(Ref), Args))),
        none
    end};
set_get_attr(Ref, <<"symmetric_difference">>) ->
    fun(Other) ->
        pyrlang_heap:set(set_symmetric_difference_items(pyrlang_heap:set_items(Ref), iterable_values(Other)))
    end;
set_get_attr(Ref, <<"symmetric_difference_update">>) ->
    fun(Other) ->
        ok = pyrlang_heap:set_data(Ref, keyed_set_items(set_symmetric_difference_items(pyrlang_heap:set_items(Ref), iterable_values(Other)))),
        none
    end;
set_get_attr(Ref, <<"update">>) ->
    {py_native_varargs, fun(Args) ->
        Items = pyrlang_heap:set_items(Ref) ++ lists:append([iterable_values(Arg) || Arg <- Args]),
        ok = pyrlang_heap:set_data(Ref, keyed_set_items(Items)),
        none
    end};
set_get_attr(Ref, <<"issuperset">>) ->
    fun(Other) ->
        lists:all(fun(Value) -> pyrlang_heap:set_contains(Ref, Value) end, iterable_values(Other))
    end;
set_get_attr(Ref, <<"issubset">>) ->
    fun(Other) ->
        OtherKeys = maps:from_list([{pyrlang_heap:value_key(Value), true} || Value <- iterable_values(Other)]),
        lists:all(fun(Value) -> maps:is_key(pyrlang_heap:value_key(Value), OtherKeys) end, pyrlang_heap:set_items(Ref))
    end;
set_get_attr(Ref, <<"isdisjoint">>) ->
    fun(Other) ->
        not lists:any(fun(Value) -> pyrlang_heap:set_contains(Ref, Value) end, iterable_values(Other))
    end;
set_get_attr(Ref, <<"pop">>) ->
    fun() ->
        case pyrlang_heap:set_items(Ref) of
            [] ->
                pyrlang_exception:raise(pyrlang_exception:make(pyrlang_exception:type(<<"KeyError">>), <<"pop from an empty set">>));
            [Value | _Rest] ->
                ok = pyrlang_heap:set_remove(Ref, Value),
                Value
        end
    end;
set_get_attr(Ref, <<"__contains__">>) ->
    fun(Value) ->
        pyrlang_heap:set_contains(Ref, Value)
    end;
set_get_attr(_Ref, Name) ->
    erlang:error({attribute_error, Name}).

keyed_set_items(Items) ->
    maps:from_list([{pyrlang_heap:value_key(Item), Item} || Item <- Items]).

set_difference_items(Items, Args) ->
    RemoveKeys = maps:from_list([
        {pyrlang_heap:value_key(Value), true}
        || Value <- lists:append([iterable_values(Arg) || Arg <- Args])
    ]),
    [Item || Item <- Items, not maps:is_key(pyrlang_heap:value_key(Item), RemoveKeys)].

set_intersection_items(Items, []) ->
    Items;
set_intersection_items(Items, Args) ->
    OtherKeySets = [
        maps:from_list([{pyrlang_heap:value_key(Value), true} || Value <- iterable_values(Arg)])
        || Arg <- Args
    ],
    [Item || Item <- Items, lists:all(fun(Keys) -> maps:is_key(pyrlang_heap:value_key(Item), Keys) end, OtherKeySets)].

set_symmetric_difference_items(LeftItems, RightItems) ->
    Left = keyed_set_items(LeftItems),
    Right = keyed_set_items(RightItems),
    LeftOnly = [Value || {Key, Value} <- maps:to_list(Left), not maps:is_key(Key, Right)],
    RightOnly = [Value || {Key, Value} <- maps:to_list(Right), not maps:is_key(Key, Left)],
    LeftOnly ++ RightOnly.

python_member(Value, Items) ->
    lists:any(fun(Item) -> python_equal(Value, Item) end, Items).

python_equal(Left, Right) when is_number(Left), is_number(Right) ->
    Left == Right;
python_equal(Left, Right) ->
    pyrlang_heap:value_key(Left) =:= pyrlang_heap:value_key(Right).

iterator_get_attr(Ref, <<"__iter__">>) ->
    fun() -> Ref end;
iterator_get_attr(Ref, <<"__next__">>) ->
    fun() -> pyrlang_iter:next(Ref) end;
iterator_get_attr(_Ref, Name) ->
    erlang:error({attribute_error, Name}).

generator_get_attr(Ref, <<"__iter__">>) ->
    fun() -> Ref end;
generator_get_attr(Ref, <<"__next__">>) ->
    {py_native_varargs, fun
        ([]) -> pyrlang_generator:next(Ref);
        (Args) -> erlang:error({arity_error, {'generator.__next__', length(Args)}})
    end};
generator_get_attr(Ref, <<"send">>) ->
    {py_native_varargs, fun
        ([_Value]) -> pyrlang_generator:next(Ref);
        (Args) -> erlang:error({arity_error, {'generator.send', length(Args)}})
    end};
generator_get_attr(_Ref, <<"throw">>) ->
    {py_native_varargs, fun generator_throw/1};
generator_get_attr(_Ref, <<"close">>) ->
    fun() -> none end;
generator_get_attr(_Ref, <<"gi_running">>) ->
    false;
generator_get_attr(_Ref, <<"gi_suspended">>) ->
    false;
generator_get_attr(_Ref, <<"gi_frame">>) ->
    none;
generator_get_attr(_Ref, <<"gi_code">>) ->
    none;
generator_get_attr(_Ref, <<"__name__">>) ->
    <<"generator">>;
generator_get_attr(_Ref, <<"__qualname__">>) ->
    <<"generator">>;
generator_get_attr(_Ref, Name) ->
    erlang:error({attribute_error, Name}).

generator_throw([Exception]) ->
    pyrlang_exception:raise(generator_throw_exception(Exception));
generator_throw([{py_exception_type, _} = Type, Value]) ->
    pyrlang_exception:raise(pyrlang_exception:make(Type, Value));
generator_throw([{py_exception_type, _} = Type, Value, _Traceback]) ->
    pyrlang_exception:raise(pyrlang_exception:make(Type, Value));
generator_throw(Args) ->
    erlang:error({arity_error, {'generator.throw', length(Args)}}).

generator_throw_exception(Exception) ->
    case pyrlang_exception:is_exception(Exception) of
        true -> Exception;
        false ->
            case Exception of
                {py_exception_type, _} = Type -> pyrlang_exception:make(Type);
                _ -> pyrlang_exception:make(pyrlang_exception:type(<<"TypeError">>), <<"exceptions must derive from BaseException">>)
            end
    end.

iterable_values(Value) ->
    pyrlang_iter:values(Value).

c3_mro(Class, []) ->
    [Class];
c3_mro(Class, Bases) ->
    BaseMros = [mro(Base) || Base <- Bases],
    [Class | c3_merge(BaseMros ++ [Bases], [])].

c3_merge(Seqs0, Acc) ->
    Seqs = [Seq || Seq <- Seqs0, Seq =/= []],
    case Seqs of
        [] ->
            lists:reverse(Acc);
        _ ->
            Candidate = c3_candidate(Seqs),
            c3_merge(remove_candidate(Candidate, Seqs), [Candidate | Acc])
    end.

c3_candidate(Seqs) ->
    Heads = [Head || [Head | _Tail] <- Seqs],
    case [Head || Head <- Heads, not appears_in_any_tail(Head, Seqs)] of
        [Candidate | _] -> Candidate;
        [] -> erlang:error(inconsistent_mro)
    end.

appears_in_any_tail(Candidate, Seqs) ->
    lists:any(
        fun
            ([_Head | Tail]) -> lists:member(Candidate, Tail);
            ([]) -> false
        end,
        Seqs
    ).

remove_candidate(Candidate, Seqs) ->
    [
        case Seq of
            [Candidate | Tail] -> Tail;
            _ -> Seq
        end
        || Seq <- Seqs
    ].

normalize_attrs(Attrs) when is_map(Attrs) ->
    maps:from_list([{normalize_attr(Key), Value} || {Key, Value} <- maps:to_list(Attrs)]);
normalize_attrs(Attrs) when is_list(Attrs) ->
    lists:foldl(
        fun({Key, Value}, Acc) -> put_class_attr(normalize_attr(Key), Value, Acc) end,
        #{?CLASS_ATTR_ORDER_KEY => []},
        Attrs
    ).

normalize_name(Name) when is_binary(Name) ->
    Name;
normalize_name(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
normalize_name(Name) when is_list(Name) ->
    unicode:characters_to_binary(Name).

normalize_attr(Name) ->
    normalize_name(Name).
