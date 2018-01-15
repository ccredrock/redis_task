%%%-------------------------------------------------------------------
%%% @author ccredrock@gmail.com
%%% @copyright 2017 redrock
%%% @doc monitor node alive
%%% @end
%%%-------------------------------------------------------------------
-module(redis_alive).

-export([alive_table/0, alive_nodes/0, zip_version/1]).

%% callbacks
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%------------------------------------------------------------------------------
-include("redis_task.hrl").

-define(TABLE_HEARTBEAT(NT), binary_to_atom(<<"node_heartbeat_", (NT)/binary>>, utf8)).
-define(TABLE_AVIVE(NT), binary_to_atom(<<"node_alive_", (NT)/binary>>, utf8)).

-define(LOOP_TIME,     1000).
-define(TIMEOUT_TIME,  5000).

-record(state, {heart_table, alive_table}).

%%------------------------------------------------------------------------------
-spec loop_time() -> pos_integer().
loop_time() ->
    application:get_env(reids_task, heartbeat_time, ?LOOP_TIME).

-spec heart_timeout() -> pos_integer().
heart_timeout() ->
    application:get_env(reids_task, heart_timeout, ?TIMEOUT_TIME).

-spec heart_table() -> atom().
heart_table() ->
    ?TABLE_HEARTBEAT(redis_task:node_type()).

-spec alive_table() -> atom().
alive_table() ->
    ?TABLE_AVIVE(redis_task:node_type()).

-spec alive_nodes() -> [binary()].
alive_nodes() ->
    [NodeID || {NodeID, _} <- redis_sync:list_val(alive_table())].

-spec zip_version(Versions::[#{}]) -> [{alive, binary()} | {dead, binary()}].
zip_version(Versions) ->
    Fun = fun(#{op := OP, key := NodeID}, Acc) ->
                  case lists:keyfind(NodeID, 2, Acc) of
                      false when OP =:= put -> [{alive, NodeID} | Acc];
                      false when OP =:= del -> [{dead, NodeID} | Acc];
                      _ -> Acc
                  end
          end,
    lists:foldr(Fun, [], Versions).

%%------------------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, {already_started, pid()}} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @hidden
init([]) ->
    {ok, _} = redis_sync:add_table(HeartTable = heart_table()),
    {ok, _} = redis_sync:add_table(AliveTable = alive_table()),
    ?INFO("init success ~p", [{HeartTable, AliveTable}]),
    {ok, #state{heart_table = heart_table(), alive_table = AliveTable}, 0}.

%% @hidden
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

%% @hidden
handle_cast(_Request, State) ->
    {noreply, State}.

%% @hidden
handle_info(timeout, State) ->
    handle_timeout(State),
    erlang:send_after(loop_time(), self(), timeout),
    {noreply, State};
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
handle_timeout(State) ->
    try
        Now = erlang:system_time(milli_seconds),
        heartbeat(Now, State),
        find_timeout(Now, State)
    catch
        _:R -> ?WARN("loop fail ~p", [{R, erlang:get_stacktrace(), State}])
    end.

%% @private
heartbeat(Now, #state{heart_table = HeartTable, alive_table = AliveTable}) ->
    ok = redis_sync:put_val(HeartTable, NodeID = redis_task:node_id(), #{heart_time => Now}),
    Lock = redis_sync:get_lock([AliveTable]),
    case redis_sync:get_val(AliveTable, NodeID) of
        null -> %% self set alive
            ok = redis_sync:lock_put(Lock, AliveTable, NodeID, #{alive => true}),
            ?INFO("node alive ~p", [{NodeID, Now}]);
        _ ->
            skip
    end.

%% @private
find_timeout(Now, #state{heart_table = HeartTable, alive_table = AliveTable}) ->
    Timeout = heart_timeout(),
    List = redis_sync:list_val(HeartTable),
    case [{ID, Time} || {ID, #{heart_time := Time}} <- List, Now - Time >= Timeout] of
        [] -> skip;
        [{ID, Time} | _] -> %% other set dead
            Lock = redis_sync:get_lock([AliveTable]),
            case redis_sync:get_val(AliveTable, NodeID = redis_task:node_id()) of
                null ->
                    skip;
                _ ->
                    ok = redis_sync:lock_del(Lock, AliveTable, NodeID),
                    ?WARN("node lost ~p", [{ID, Time, Now}])
            end
    end.

