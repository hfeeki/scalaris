%  @copyright 2010-2011 Zuse Institute Berlin

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

%% @author Nico Kruber <kruber@zib.de>
%% @doc    Simple passive load balancing sampling k nodes and choosing the
%%         one that reduces the standard deviation the most.
%%         Splits loads in half, if there is no load address ranges are split.
%% @end
%% @version $Id$
-module(lb_psv_split).
-author('kruber@zib.de').
-vsn('$Id$ ').

%-define(TRACE(X,Y), ct:pal(X,Y)).
-define(TRACE(X,Y), ok).
-define(TRACE_SEND(Pid, Msg), ?TRACE("[ ~.0p ] to ~.0p: ~.0p)~n", [self(), Pid, Msg])).
-define(TRACE1(Msg, State), ?TRACE("[ ~.0p ]~n  Msg: ~.0p~n  State: ~.0p)~n", [self(), Msg, State])).

-behaviour(lb_psv_beh).
-include("lb_psv_beh.hrl").

-ifdef(with_export_type_support).
-export_type([custom_message/0]).
-endif.

-export([my_sort_fun/2]).

-type custom_message() :: none().

%% @doc Gets the number of IDs to sample during join.
%%      Note: this is executed at the joining node.
-spec get_number_of_samples(Conn::dht_node_join:connection()) -> ok.
get_number_of_samples(Connection) ->
    comm:send_local(self(), {join, get_number_of_samples,
                             conf_get_number_of_samples(), Connection}).

%% @doc Sends the number of IDs to sample during join to the joining node.
%%      Note: this is executed at the existing node.
-spec get_number_of_samples_remote(
        SourcePid::comm:mypid(), Conn::dht_node_join:connection()) -> ok.
get_number_of_samples_remote(SourcePid, Connection) ->
    comm:send(SourcePid, {join, get_number_of_samples,
                          conf_get_number_of_samples(), Connection}).

%% @doc Creates a join operation if a node would join at my node with the
%%      given key. This will simulate the join operation and return a lb_op()
%%      with all the data needed in sort_candidates/1.
%%      Note: this is executed at an existing node.
-spec create_join(DhtNodeState::dht_node_state:state(), SelectedKey::?RT:key(),
                  SourcePid::comm:mypid(), Conn::dht_node_join:connection())
        -> dht_node_state:state().
create_join(DhtNodeState, SelectedKey, SourcePid, Conn) ->
    case dht_node_state:get(DhtNodeState, slide_pred) of
        null ->
            Candidate =
                try
                    MyNode = dht_node_state:get(DhtNodeState, node),
                    MyNodeId = node:id(MyNode),
                    MyLoad = dht_node_state:get(DhtNodeState, load),
                    {SplitKey, OtherLoadNew} =
                        case MyLoad >= 2 of
                            true ->
                                TargetLoad = util:floor(MyLoad / 2),
%%                                 ct:pal("T: ~.0p, My: ~.0p~n", [TargetLoad, MyLoad]),
                                try lb_common:split_by_load(DhtNodeState, TargetLoad)
                                catch
                                    throw:'no key in range' ->
                                        %%                                 log:log(info, "[ Node ~w ] could not split load - no key in my range, "
                                        %%                                             "splitting address range instead", [self()]),
                                        lb_common:split_my_range(DhtNodeState, SelectedKey)
                                end;
                            _ -> % split address range (fall-back):
                                lb_common:split_my_range(DhtNodeState, SelectedKey)
                        end,
                    MyPredId = node:id(dht_node_state:get(DhtNodeState, pred)),
                    case SplitKey of
                        MyNodeId ->
                            log:log(warn, "[ Node ~w ] join requested for my ID (~.0p), "
                                        "sending no_op...", [self(), MyNodeId]),
                            lb_op:no_op();
                        MyPredId ->
                            log:log(warn, "[ Node ~w ] join requested for my pred's ID (~.0p), "
                                        "sending no_op...", [self(), MyPredId]),
                            lb_op:no_op();
                        _ ->
%%                             ct:pal("MK: ~.0p, SK: ~.0p~n", [MyNodeId, SplitKey]),
                            MyLoadNew = MyLoad - OtherLoadNew,
                            MyNodeDetails1 = node_details:set(node_details:new(), node, MyNode),
                            MyNodeDetails = node_details:set(MyNodeDetails1, load, MyLoad),
                            MyNodeDetailsNew = node_details:set(MyNodeDetails, load, MyLoadNew),
                            OtherNodeDetails = node_details:set(node_details:new(), load, 0),
                            OtherNodeDetailsNew1 = node_details:set(node_details:new(), new_key, SplitKey),
                            OtherNodeDetailsNew2 = node_details:set(OtherNodeDetailsNew1, load, OtherLoadNew),
                            Interval = node:mk_interval_between_ids(MyPredId, SplitKey),
                            OtherNodeDetailsNew = node_details:set(OtherNodeDetailsNew2, my_range, Interval),
                            lb_op:slide_op(OtherNodeDetails, MyNodeDetails,
                                           OtherNodeDetailsNew, MyNodeDetailsNew)
                    end
                catch
                    Error:Reason ->
                        log:log(error, "[ Node ~w ] could not create a candidate "
                                    "for another node: ~.0p:~.0p~n"
                                    "  SelectedKey: ~.0p, SourcePid: ~.0p~n  State: ~.0p",
                                [self(), Error, Reason, SelectedKey, SourcePid, DhtNodeState]),
                        lb_op:no_op()
                end,
            Msg = {join, get_candidate_response, SelectedKey, Candidate, Conn},
            ?TRACE_SEND(SourcePid, Msg),
            comm:send(SourcePid, Msg);
        _ ->
            % postpone message:
            Msg = {join, get_candidate, SourcePid, SelectedKey, ?MODULE, Conn},
            ?TRACE_SEND(SourcePid, Msg),
            _ = comm:send_local_after(100, self(), Msg),
            ok
    end,
    DhtNodeState.

%% @doc Sort function for two operations and their Sum2Change.
%%      Op1 will be preferred over Op2, i.e. Op1 is smaller than Op2, if its
%%      Sum2Change is smaller or if it is equal and its new node's address
%%      space is larger.
-spec my_sort_fun(Op1::{lb_op:lb_op(), integer()},
                  Op2::{lb_op:lb_op(), integer()}) -> boolean().
my_sort_fun({Op1, Op1Change}, {Op2, Op2Change}) ->
    case Op1Change < Op2Change of
        true -> true;
        _ when Op1Change =:= Op2Change ->
            Op1NewInterval = node_details:get(lb_op:get(Op1, n1_new), my_range),
            {_, Op1NewPredId, Op1NewMyId, _} =
                intervals:get_bounds(Op1NewInterval),
            Op1NewRange = try ?RT:get_range(Op1NewPredId, Op1NewMyId)
                          catch throw:not_supported -> 0
                          end,
            Op2NewInterval = node_details:get(lb_op:get(Op2, n1_new), my_range),
            {_, Op2NewPredId, Op2NewMyId, _} =
                intervals:get_bounds(Op2NewInterval),
            Op2NewRange = try ?RT:get_range(Op2NewPredId, Op2NewMyId)
                          catch throw:not_supported -> 0
                          end,
            Op2NewRange =< Op1NewRange orelse
                ((Op1NewRange =:= Op2NewRange) andalso Op1 =< Op2);
        _ -> false
    end.

%% @doc Sorts all provided operations so that the one with the biggest change
%%      of the standard deviation is at the front. In case of no load changes,
%%      the operation with the largest address range at the joining node will
%%      be at the front.
%%      Note: this is executed at the joining node.
-spec sort_candidates(Ops::[lb_op:lb_op()]) -> [lb_op:lb_op()].
sort_candidates(Ops) ->
    lb_common:bestStddev(Ops, plus_infinity, fun my_sort_fun/2).

-spec process_join_msg(comm:message(), State::any(),
        DhtNodeState::dht_node_state:state()) -> unknown_event.
process_join_msg(_Msg, _State, _DhtNodeState) ->
    unknown_event.

%% @doc Checks whether config parameters of the passive load balancing
%%      algorithm exist and are valid.
-spec check_config() -> boolean().
check_config() ->
    config:cfg_is_integer(lb_psv_split_samples) and
    config:cfg_is_greater_than_equal(lb_psv_split_samples, 1).

%% @doc Gets the number of nodes to sample (set in the config files).
-spec conf_get_number_of_samples() -> pos_integer().
conf_get_number_of_samples() ->
    config:read(lb_psv_split_samples).
