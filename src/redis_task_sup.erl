%%%-------------------------------------------------------------------
%%% @author ccredrock@gmail.com
%%% @copyright 2017 redrock
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(redis_task_sup).

-export([start_link/0, init/1]).

%%------------------------------------------------------------------------------
-behaviour(supervisor).

%%------------------------------------------------------------------------------
start_link() ->
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    {ok, _} = supervisor:start_child(?MODULE, {redis_group_sup,
                                               {redis_group_sup, start_link, []},
                                               permanent, infinity, supervisor,
                                               [redis_group_sup]}),
    {ok, _} = supervisor:start_child(?MODULE, {redis_alive,
                                               {redis_alive, start_link, []},
                                               transient, infinity, worker,
                                               [redis_alive]}),
    {ok, _} = supervisor:start_child(?MODULE, {redis_task,
                                               {redis_task, start_link, []},
                                               transient, infinity, worker,
                                               [redis_task]}),
    {ok, Sup}.

init([]) ->
    {ok, {{one_for_one, 1, 60}, []}}.

