%%%-------------------------------------------------------------------
%%% @author ccredrock@gmail.com
%%% @copyright 2017 redrock
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(redis_task_app).

-export([start/2, stop/1]).

%%------------------------------------------------------------------------------
-behaviour(application).

%%------------------------------------------------------------------------------
start(_StartType, _StartArgs) ->
    redis_task_sup:start_link().

stop(_State) ->
    ok.

