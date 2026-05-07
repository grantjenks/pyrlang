-module(pyrlang_send).

-include("pyrlang.hrl").

-export([export/1, import/1, copy/1]).

-record(export_state, {next = 1 :: pos_integer(), refs = #{} :: map(), objects = #{} :: map()}).

-spec copy(term()) -> term().
copy(Value) ->
    import(export(Value)).

-spec export(term()) -> term().
export(Value) ->
    {Root, State} = export_value(Value, #export_state{}),
    {?PY_WIRE, Root, State#export_state.objects}.

-spec import(term()) -> term().
import({?PY_WIRE, Root, Objects}) when is_map(Objects) ->
    RefMap = allocate_import_placeholders(Objects),
    import_value(Root, Objects, RefMap);
import(Other) ->
    Other.

export_value({?PY_REF, Id} = Ref, State0) when is_integer(Id) ->
    case maps:find(Ref, State0#export_state.refs) of
        {ok, WireId} ->
            {{obj, WireId}, State0};
        error ->
            WireId = State0#export_state.next,
            Cell = pyrlang_heap:object(Ref),
            State1 = State0#export_state{
                next = WireId + 1,
                refs = maps:put(Ref, WireId, State0#export_state.refs)
            },
            {WireData, State2} = export_object_data(maps:get(type, Cell), maps:get(data, Cell), State1),
            Objects = maps:put(WireId, {maps:get(type, Cell), WireData}, State2#export_state.objects),
            {{obj, WireId}, State2#export_state{objects = Objects}}
    end;
export_value(Value, State) when is_integer(Value) ->
    {{int, Value}, State};
export_value(Value, State) when is_float(Value) ->
    {{float, Value}, State};
export_value(Value, State) when is_binary(Value) ->
    {{binary, Value}, State};
export_value(Value, State) when is_atom(Value) ->
    {{atom, Value}, State};
export_value(Value, State) when is_pid(Value) ->
    {{pid, Value}, State};
export_value(Value, State) when is_reference(Value) ->
    {{reference, Value}, State};
export_value(Value, State) when is_function(Value) ->
    {{erl_fun, Value}, State};
export_value(Value, State) when is_tuple(Value) ->
    export_tuple(Value, tuple_size(Value), 1, [], State);
export_value(Value, State) when is_list(Value) ->
    export_list(Value, [], State);
export_value(Value, State) when is_map(Value) ->
    export_map(maps:to_list(Value), [], State).

export_object_data(list, Items, State) ->
    export_list(Items, [], State);
export_object_data(dict, Map, State) when is_map(Map) ->
    export_map(maps:to_list(Map), [], State);
export_object_data(set, Map, State) when is_map(Map) ->
    export_map(maps:to_list(Map), [], State);
export_object_data(object, Attrs, State) when is_map(Attrs) ->
    export_map(maps:to_list(Attrs), [], State);
export_object_data(instance, #{attrs := Attrs} = Data, State) when is_map(Attrs) ->
    case maps:get(<<"__pyrlang_unsendable__">>, Attrs, false) of
        false -> export_custom_object_data(instance, Data, State);
        Reason -> erlang:error({unsendable, Reason})
    end;
export_object_data(generator, _Data, _State) ->
    erlang:error({unsendable, generator});
export_object_data(iterator, _Data, _State) ->
    erlang:error({unsendable, iterator});
export_object_data(Type, Data, State) ->
    export_custom_object_data(Type, Data, State).

export_custom_object_data(Type, Data, State) ->
    {WireData, State1} = export_value(Data, State),
    {{custom, Type, WireData}, State1}.

export_tuple(Tuple, Size, Pos, Acc, State) when Pos =< Size ->
    {Wire, State1} = export_value(element(Pos, Tuple), State),
    export_tuple(Tuple, Size, Pos + 1, [Wire | Acc], State1);
export_tuple(_Tuple, _Size, _Pos, Acc, State) ->
    {{tuple, lists:reverse(Acc)}, State}.

export_list([Item | Rest], Acc, State) ->
    {Wire, State1} = export_value(Item, State),
    export_list(Rest, [Wire | Acc], State1);
export_list([], Acc, State) ->
    {{list, lists:reverse(Acc)}, State}.

export_map([{Key, Value} | Rest], Acc, State) ->
    {WireKey, State1} = export_value(Key, State),
    {WireValue, State2} = export_value(Value, State1),
    export_map(Rest, [{WireKey, WireValue} | Acc], State2);
export_map([], Acc, State) ->
    {{map, lists:reverse(Acc)}, State}.

allocate_import_placeholders(Objects) ->
    maps:fold(
        fun(WireId, {Type, _WireData}, RefMap) ->
            maps:put(WireId, pyrlang_heap:placeholder(Type), RefMap)
        end,
        #{},
        Objects
    ).

import_value({obj, WireId}, Objects, RefMap) ->
    import_object(WireId, Objects, RefMap);
import_value({int, Value}, _Objects, _RefMap) ->
    Value;
import_value({float, Value}, _Objects, _RefMap) ->
    Value;
import_value({binary, Value}, _Objects, _RefMap) ->
    Value;
import_value({atom, Value}, _Objects, _RefMap) ->
    Value;
import_value({pid, Value}, _Objects, _RefMap) ->
    Value;
import_value({reference, Value}, _Objects, _RefMap) ->
    Value;
import_value({erl_fun, Value}, _Objects, _RefMap) ->
    Value;
import_value({tuple, Items}, Objects, RefMap) ->
    list_to_tuple([import_value(Item, Objects, RefMap) || Item <- Items]);
import_value({list, Items}, Objects, RefMap) ->
    [import_value(Item, Objects, RefMap) || Item <- Items];
import_value({map, Pairs}, Objects, RefMap) ->
    maps:from_list([
        {import_value(Key, Objects, RefMap), import_value(Value, Objects, RefMap)}
        || {Key, Value} <- Pairs
    ]).

%% Fill placeholders lazily on first import reference use. This handles cycles:
%% references may point at placeholders before their data has been installed.
import_object(WireId, Objects, RefMap) ->
    Ref = maps:get(WireId, RefMap),
    case pyrlang_heap:data(Ref) of
        undefined ->
            {Type, WireData} = maps:get(WireId, Objects),
            ok = pyrlang_heap:set_data(Ref, '$pyrlang_loading'),
            Data = import_object_data(Type, WireData, Objects, RefMap),
            ok = pyrlang_heap:set_data(Ref, Data),
            Ref;
        '$pyrlang_loading' ->
            Ref;
        _ ->
            Ref
    end.

import_object_data(list, {list, Items}, Objects, RefMap) ->
    [import_value_with_objects(Item, Objects, RefMap) || Item <- Items];
import_object_data(dict, {map, Pairs}, Objects, RefMap) ->
    maps:from_list([
        {import_value_with_objects(Key, Objects, RefMap), import_value_with_objects(Value, Objects, RefMap)}
        || {Key, Value} <- Pairs
    ]);
import_object_data(set, {map, Pairs}, Objects, RefMap) ->
    maps:from_list([
        {import_value_with_objects(Key, Objects, RefMap), import_value_with_objects(Value, Objects, RefMap)}
        || {Key, Value} <- Pairs
    ]);
import_object_data(object, {map, Pairs}, Objects, RefMap) ->
    maps:from_list([
        {import_value_with_objects(Key, Objects, RefMap), import_value_with_objects(Value, Objects, RefMap)}
        || {Key, Value} <- Pairs
    ]);
import_object_data(_Type, {custom, _TypeName, WireData}, Objects, RefMap) ->
    import_value_with_objects(WireData, Objects, RefMap).

import_value_with_objects({obj, WireId}, Objects, RefMap) ->
    import_object(WireId, Objects, RefMap);
import_value_with_objects(Wire, Objects, RefMap) ->
    import_value(Wire, Objects, RefMap).
