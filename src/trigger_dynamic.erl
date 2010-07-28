%  @copyright 2009-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Christian Hennig <hennig@zib.de>
%% @doc    Dynamic trigger for (parameterized) modules.
%%
%% Can be used by a module <code>Module</code> in order to get a configurable
%% message (by default <code>{trigger}</code>) every
%% <code>BaseIntervalFun()</code> (default: <code>Module:get_base_interval()</code>),
%% <code>MinIntervalFun()</code> (default: <code>Module:get_min_interval()</code>),
%% <code>0</code> and <code>MinIntervalFun()</code> or
%% <code>MaxIntervalFun()</code> (default: <code>Module:get_max_interval()</code>),
%% milliseconds depending on a user-provided function (note: this is not fully
%% implemented yet).
%% 
%% Use this module through the interface provided by the trigger module,
%% initializing it with trigger_periodic!
%% @version $Id$
-module(trigger_dynamic).
-author('hennig@zib.de').
-vsn('$Id$').

-behaviour(trigger_beh).

-include("scalaris.hrl").

-export([init/4, now/1, next/2, stop/1]).

-opaque state() :: {BaseIntervalFun::trigger:interval_fun(),
                    MinIntervalFun::trigger:interval_fun(),
                    MaxIntervalFun::trigger:interval_fun(),
                    MsgTag::comm:message_tag(), TimerRef::ok | reference()}.

%% @doc Initializes the trigger with the given interval functions and the given
%%      message tag used for the trigger message.
-spec init(BaseIntervalFun::trigger:interval_fun(), MinIntervalFun::trigger:interval_fun(), MaxIntervalFun::trigger:interval_fun(), comm:message_tag()) -> state().
init(BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag) when is_function(BaseIntervalFun, 0) ->
    {BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, ok}.

%% @doc Sets the trigger to send its message immediately, for example after
%%      its initialization.
-spec now(state()) -> state().
now({BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, TimerRef}) ->
    comm:send_local(self(), {MsgTag}),
    {BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, TimerRef}.

%% @doc Sets the trigger to send its message after some delay (in milliseconds).
%%      If the trigger has not been called before, BaseIntervalFun()
%%      will be used, otherwise function U will be evaluated in order to decide
%%      whether to use MaxIntervalFun() (return value 0),
%%      MinIntervalFun() (return value 2),
%%      0 (now) and MinIntervalFun() (return value 3) or
%%      BaseIntervalFun() (any other return value) for the delay.
-spec next(state(), IntervalTag::trigger:interval()) -> state().
next({BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, ok}, IntervalTag) ->
    NewTimerRef = send_message(IntervalTag, BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag),
    {BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, NewTimerRef};

next({BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, TimerRef}, IntervalTag) ->
    % timer still running?
    erlang:cancel_timer(TimerRef),
    NewTimerRef = send_message(IntervalTag, BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag),
    {BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, NewTimerRef}.

-spec send_message(IntervalTag::trigger:interval(),
                   BaseIntervalFun::trigger:interval_fun(),
                   MinIntervalFun::trigger:interval_fun(),
                   MaxIntervalFun::trigger:interval_fun(),
                   MsgTag::comm:message_tag()) -> reference().
send_message(IntervalTag, BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag) ->
    case IntervalTag of
        max_interval ->
            comm:send_local_after(MaxIntervalFun(), self(), {MsgTag});
        base_interval ->
            comm:send_local_after(BaseIntervalFun(), self(), {MsgTag});
        min_interval ->
            comm:send_local_after(MinIntervalFun(), self(), {MsgTag});
        now_and_min_interval ->
            comm:send_local(self(), {MsgTag}),
            comm:send_local_after(MinIntervalFun(), self(), {MsgTag});
        _ ->
            comm:send_local_after(BaseIntervalFun(), self(), {MsgTag})
     end.

-spec stop(state()) -> state().
stop({_BaseIntervalFun, _MinIntervalFun, _MaxIntervalFun, _MsgTag, ok} = State) ->
    State;
stop({BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, TimerRef}) ->
    % timer still running?
    erlang:cancel_timer(TimerRef),
    {BaseIntervalFun, MinIntervalFun, MaxIntervalFun, MsgTag, ok}.
