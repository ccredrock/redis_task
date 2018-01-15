%%%-------------------------------------------------------------------
%%% @author ccredrock@gmail.com
%%% @copyright 2017 redrock
%%% @doc task base on redis
%%%     balance task
%%% @end
%%%-------------------------------------------------------------------
-module(redis_task).

%% start
-export([start/0]).       %% start applicatcion

%% config
-export([node_type/0,     %% config: node type
         node_id/0,       %% config: node id
         loop_time/0,     %% config: retry timeout
         task_groups/0]). %% config: task groups

-export([add_task/3,            %% add_task
         del_task/2,            %% del_task
         register_global/2]).   %% register_global

%% callbacks
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%------------------------------------------------------------------------------
-include("redis_task.hrl").

-define(LOOP_TIME, 1000).

-define(TABLE_TASK(NT, TG), binary_to_atom(<<"task_", (NT)/binary, (TG)/binary>>, utf8)).

%%------------------------------------------------------------------------------
-spec start() -> {'ok', [atom()]} | {'error', any()}.
start() ->
    application:ensure_all_started(?MODULE).

%%------------------------------------------------------------------------------
-spec node_type() -> binary().
node_type() ->
    {Project, _} = init:script_id(),
    rock_util:to_binary(application:get_env(reids_task, node_type, Project)).

-spec node_id() -> binary().
node_id() ->
    {ok, HostName} = inet:gethostname(),
    rock_util:to_binary(application:get_env(reids_task, node_id, HostName)).

-spec loop_time() -> pos_integer().
loop_time() ->
    application:get_env(reids_task, loop_time, ?LOOP_TIME).

-spec task_groups() -> [atom()].
task_groups() ->
    application:get_env(reids_task, task_groups, [global]).

-spec add_task(TaskGroup::atom(),
               ID::atom() | binary() | integer(),
               MFA::{atom(), atom(), list()}) -> [atom()].
add_task(TaskGroup, ID, MFA) ->
    redis_group:add_task(which_child(TaskGroup), ID, MFA).

%% @private [{Id,Child,Type,Modules}]
which_child(Table) ->
    List = supervisor:which_children(redis_table_sup),
    {Table, PID, _, _} = lists:keyfind(Table, 1, List),
    PID.

-spec del_task(TaskGroup::atom(),
               ID::atom() | binary() | integer()) -> [atom()].
del_task(TaskGroup, ID) ->
    redis_group:del_task(which_child(TaskGroup), ID).

-spec register_global(ID::atom() | binary() | integer(),
                      MFA::{atom(), atom(), list()}) -> [atom()].
register_global(ID, MFA) -> add_task('$group', ID, MFA).

%%------------------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, {already_started, pid()}} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @hidden
init([]) ->
    process_flag(trap_exit, true),
    ets:new(?ETS_GROUP, [named_table, public, {read_concurrency, true}]),
    List = [{X, {ok, _} = redis_group_sup:start_child(X)} || X <- task_groups()],
    ?INFO("init success ~p", [{List}]),
    {ok, {state}}.

%% @hidden
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

%% @hidden
handle_cast(_Request, State) ->
    {noreply, State}.

%% @hidden
handle_info({'EXIT', PID, Reason}, State) ->
    ?DEBUG("find process exit ~p", [{PID, Reason}]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @hidden
terminate(Reason, State) ->
    ?ERROR("process exit ~p", [{Reason, State}]).

