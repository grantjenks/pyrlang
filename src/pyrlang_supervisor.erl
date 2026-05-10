-module(pyrlang_supervisor).

-export([
    child/3,
    child/4,
    start/1,
    start_link/1,
    which_children/1,
    stop/1
]).

-type restart() :: permanent | temporary.
-type child_spec() :: #{
    id := term(),
    start := fun(),
    args := [term()],
    restart := restart()
}.

-spec child(term(), fun(), [term()]) -> child_spec().
child(Id, Fun, Args) ->
    child(Id, Fun, Args, permanent).

-spec child(term(), fun(), [term()], restart()) -> child_spec().
child(Id, Fun, Args, Restart) when is_function(Fun), is_list(Args) ->
    #{id => Id, start => Fun, args => Args, restart => Restart}.

-spec start([child_spec()]) -> pid().
start(Specs) ->
    erlang:spawn(fun() -> init(Specs) end).

-spec start_link([child_spec()]) -> pid().
start_link(Specs) ->
    erlang:spawn_link(fun() -> init(Specs) end).

-spec which_children(pid()) -> [{term(), pid(), restart()}].
which_children(Sup) ->
    request(Sup, which_children).

-spec stop(pid()) -> ok.
stop(Sup) ->
    request(Sup, stop).

request(Sup, Request) ->
    Ref = erlang:make_ref(),
    Sup ! {pyrlang_supervisor_call, erlang:self(), Ref, Request},
    receive
        {pyrlang_supervisor_reply, Ref, Reply} -> Reply
    after 5000 ->
        erlang:error(timeout)
    end.

init(Specs) ->
    pyrlang_heap:init(),
    State = lists:foldl(fun start_child/2, #{children => #{}, refs => #{}}, Specs),
    loop(State).

loop(State) ->
    receive
        {pyrlang_supervisor_call, From, Ref, which_children} ->
            From ! {pyrlang_supervisor_reply, Ref, child_summary(State)},
            loop(State);
        {pyrlang_supervisor_call, From, Ref, stop} ->
            stop_children(State),
            From ! {pyrlang_supervisor_reply, Ref, ok},
            ok;
        {'DOWN', MonitorRef, process, _Pid, Reason} ->
            loop(handle_down(MonitorRef, Reason, State))
    end.

start_child(Spec, State0) ->
    #{id := Id, start := Fun, args := Args} = Spec,
    Pid = pyrlang_actor:spawn(Fun, Args),
    Ref = erlang:monitor(process, Pid),
    Child = #{spec => Spec, pid => Pid, ref => Ref},
    Children = maps:get(children, State0),
    Refs = maps:get(refs, State0),
    State0#{children := Children#{Id => Child}, refs := Refs#{Ref => Id}}.

handle_down(Ref, Reason, State0) ->
    Refs0 = maps:get(refs, State0),
    case maps:take(Ref, Refs0) of
        error ->
            State0;
        {Id, Refs1} ->
            Children0 = maps:get(children, State0),
            Child = maps:get(Id, Children0),
            Spec = maps:get(spec, Child),
            Children1 = maps:remove(Id, Children0),
            State1 = State0#{children := Children1, refs := Refs1},
            case should_restart(Spec, Reason) of
                true -> start_child(Spec, State1);
                false -> State1
            end
    end.

should_restart(#{restart := temporary}, _Reason) ->
    false;
should_restart(#{restart := permanent}, _Reason) ->
    true.

child_summary(State) ->
    [
        {Id, maps:get(pid, Child), maps:get(restart, maps:get(spec, Child))}
     || {Id, Child} <- maps:to_list(maps:get(children, State))
    ].

stop_children(State) ->
    lists:foreach(
        fun({_Id, Child}) ->
            erlang:exit(maps:get(pid, Child), shutdown)
        end,
        maps:to_list(maps:get(children, State))
    ).
