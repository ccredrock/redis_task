%%%-------------------------------------------------------------------
%%% @author ccredrock@gmail.com
%%% @copyright 2017 redrock
%%% @doc task base on redis
%%%     balance task
%%% @end
%%%-------------------------------------------------------------------
-module(redis_group).

-export([loop_time/0]).

-export([add_task/3,      %% add_task
         del_task/2]).    %% del_task

%% callbacks
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%------------------------------------------------------------------------------
-include("redis_task.hrl").

-define(LOOP_TIME, 1000).

-define(TABLE_TASK(NT, TG), binary_to_atom(<<"$task_", (NT)/binary, (TG)/binary>>, utf8)).

-record(state, {table, alive_table, alive_update = false, process = #{}}).

%%------------------------------------------------------------------------------
-spec loop_time() -> pos_integer().
loop_time() ->
    application:get_env(reids_task, loop_time, ?LOOP_TIME).

-spec add_task(PID::pid(),
               ID::atom() | binary() | integer(),
               MFA::{atom(), atom(), list()}) -> [atom()].
add_task(PID, ID, MFA) ->
    gen_server:call(PID, {add_task, ID, MFA}).

-spec del_task(PID::pid(),
               ID::atom() | binary() | integer()) -> [atom()].
del_task(PID, ID) ->
    gen_server:call(PID, {del_task, ID}).

%%------------------------------------------------------------------------------
-spec start_link(TaskGroup::atom()) -> {ok, pid()} | {error, {already_started, pid()}} | {error, any()}.
start_link(TaskGroup) ->
    gen_server:start_link(?MODULE, [TaskGroup], []).

%% @hidden
init([TaskGroup]) ->
    {ok, _} = redis_sync:add_table(?TABLE_TASK(redis_task:node_type(), rock_util:to_binary(TaskGroup))),
    ok = redis_sync:monitor(AliveTable = redis_alive:alive_table()),
    erlang:send(self(), timeout),
    {ok, #state{table = TaskGroup, alive_table = AliveTable}}.

%% @hidden
handle_call({add_task, ID, MFA}, _From, State) ->
    {reply, catch handle_add_task(ID, MFA, State), State};
handle_call({del_task, ID}, _From, State) ->
    {reply, catch handle_del_task(ID, State), State};
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

%% @hidden
handle_cast(_Request, State) ->
    {noreply, State}.

%% @hidden
handle_info({redis_sync, Table, _Lock, _ItermList}, State) ->
    {noreply, handle_alive_update(Table, State)};
handle_info(timeout, State) ->
    State1 = handle_timeout(State),
    erlang:send_after(loop_time(), self(), timeout),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @hidden
terminate(Reason, State) ->
    ?ERROR("process exit ~p", [{Reason, State}]).

%%------------------------------------------------------------------------------
%% @private
handle_alive_update(Table, #state{alive_table = AliveTable} = State) ->
    Locks = [redis_sync:get_lock([Table, AliveTable])],
    TaskCount = length(Tasks = redis_sync:list_val(Table)),
    NodeCount = length(Nodes = redis_alive:alive_nodes()),
    {NodeMap, LeftTasks} = get_node_more(Tasks, Nodes, Line = TaskCount div NodeCount),
    AssginTasks = fill_node_task(LeftTasks, NodeMap, Line),
    case redis_sync:lock_set(Locks, Table, [{put, ID, #{node => Node}} || {ID, Node} <- AssginTasks]) of
        ok -> State#state{alive_update = false};
        _ -> State#state{alive_update = ture}
    end.

%% @private get more than waterline tasks
get_node_more(Tasks, Nodes, Line) ->
    Map = maps:from_list([{Node, 0} || Node <- Nodes]),
    get_node_more1(Tasks, Line, Map, []).

%% @private
get_node_more1([{ID, #{node_id := Node}} | T], Line, AccNode, AccTasks) ->
    case maps:find(Node, AccNode) of
        error -> get_node_more1(T, Line, AccNode, AccTasks);
        {ok, Len} when Len >= Line -> get_node_more1(T, Line, AccNode, [ID | AccTasks]);
        {ok, Len} -> get_node_more1(T, Line, AccNode#{Node => Len + 1}, AccTasks)
    end;
get_node_more1([], _Line, AccNode, AccTasks) -> {AccNode, AccTasks}.

%% @private fill node task
fill_node_task(Tasks, NodeMap, WaterLine) ->
    fill_node_task1(Tasks, maps:to_list(NodeMap), WaterLine, [], []).

%% @private
fill_node_task1(Tasks, [{_, Cnt} = NH | NT], WaterLine, AccNodes, AccTasks) when Cnt >= WaterLine ->
    fill_node_task1(Tasks, NT, WaterLine, [NH | AccNodes], AccTasks);
fill_node_task1([Task | T], [{Node, Cnt} | NT], WaterLine, AccNodes, AccTasks) ->
    fill_node_task1(T, [{Node, Cnt} | NT], WaterLine, AccNodes, [{Task, Node} | AccTasks]);
fill_node_task1([Task | T], [], WaterLine, AccNodes, AccTasks) ->
    fill_node_task1([Task | T], AccNodes, WaterLine + 1, [], AccTasks);
fill_node_task1([], _Nodes, _WaterLine, _AccNodes, AccTasks) -> AccTasks.

%%------------------------------------------------------------------------------
%% @private
handle_add_task(ID, MFA, #state{table = Table, alive_table = AliveTable}) ->
    Locks = [redis_sync:get_lock([Table, AliveTable])],
    case redis_sync:get_val(Table, ID) of
        null ->
            Node = get_min_node(redis_sync:list_val(Table), redis_alive:alive_nodes()),
            ok = redis_sync:lock_put(Locks, Table, ID, #{node => Node, mfa => MFA});
        _ ->
            skip
    end.

%% @private get more than waterline tasks
get_min_node(Tasks, Nodes) ->
    Map = maps:from_list([{Node, 0} || Node <- Nodes]),
    {Node, _} = lists:keysort(2, maps:to_list(get_node_len(Tasks, Map))), Node.

%% @private
get_node_len([{_, #{node_id := Node}} | T], AccNode) ->
    case maps:find(Node, AccNode) of
        error -> get_node_len(T, AccNode);
        {ok, Len} -> get_node_len(T, AccNode#{Node => Len + 1})
    end;
get_node_len([], AccNode) -> AccNode.

%%------------------------------------------------------------------------------
%% @private
handle_del_task(ID, #state{table = Table, alive_table = AliveTable}) ->
    Locks = [redis_sync:get_lock([Table, AliveTable])],
    case redis_sync:get_val(Table, ID) of
        null -> skip;
        _ -> ok = redis_sync:lock_del(Locks, Table, ID)
    end.

%%------------------------------------------------------------------------------
%% @private
handle_timeout(State) ->
    State1 = handle_reborn(State),
    handle_kill(State1).

%% @private
handle_reborn(#state{table = Table, process = Map} = State) ->
    NodeID = redis_task:node_id(),
    case [{Name, MFA}
          || {Name, #{node_id := ID, mfa := MFA}} <- redis_sync:list_val(Table),
             ID =:= NodeID, (catch is_process_alive(map:get(Name, Map))) =/= true] of
        [] -> skip;
        List ->
            Fun = fun({Name, {M, F, A}}, Acc) ->
                          case catch apply(M, F, A) of
                              {ok, PID} -> Acc#{Name => PID};
                              _ -> Acc
                          end
                  end,
            Map1 = lists:foldl(Fun, Map, List),
            ?INFO("try start dead global ~p", [List]),
            State#state{process = Map1}
    end.

%% @private
handle_kill(#state{table = Table, process = Map} = State) ->
    NodeID = redis_task:node_id(),
    ExistList = [Name || {Name, #{node_id := ID}} <- redis_sync:list_val(Table), ID =:= NodeID],
    case [{Name, PID} || {Name, PID} <- maps:to_list(Map), not lists:member(Name, ExistList)] of
        [] -> skip;
        List ->
            Fun = fun({Name, PID}, Acc) ->
                          is_process_alive(PID) andalso (catch exit(PID, shutdown)),
                          maps:remove(Name, Acc)
                  end,
            Map1 = lists:foldl(Fun, Map, List),
            ?INFO("try kill no exist global ~p", [List]),
            State#state{process = Map1}
    end.

