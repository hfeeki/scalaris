%  @copyright 2010-2012 Zuse Institute Berlin
%  @end
%
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
%%%-------------------------------------------------------------------
%%% File    tester.erl
%%% @author Thorsten Schuett <schuett@zib.de>
%%% @doc    test generator
%%% @end
%%% Created :  30 March 2010 by Thorsten Schuett <schuett@zib.de>
%%%-------------------------------------------------------------------
%% @version $Id$
-module(tester).

-author('schuett@zib.de').
-vsn('$Id$').

-export([test/4, test/5, test_log/4,
         test_with_scheduler/3, test_with_scheduler/4]).

-export([type_check_module/2]).

-include("tester.hrl").
-include("unittest.hrl").

-type test_option() :: multi_threaded | {threads, pos_integer()} | with_feeder.
-type test_options() :: [test_option()].

-spec test/4 :: (module(), atom(), non_neg_integer(), non_neg_integer()) -> ok.
test(Module, Func, Arity, Iterations) ->
    test(Module, Func, Arity, Iterations, []).

-spec test/5 :: (module(), atom(), non_neg_integer(), non_neg_integer(), test_options()) -> ok.
test(Module, Func, Arity, Iterations, Options) ->
    EmptyParseState = tester_parse_state:new_parse_state(),
    ParseState = try tester_collect_function_info:collect_fun_info(Module, Func, Arity,
                                      EmptyParseState)
    catch
        throw:Term2 -> ?ct_fail("exception (throw) in ~p:~p(): ~p~n",
                                [Module, Func,
                                 {exception, {Term2, erlang:get_stacktrace(),
                                              util:get_linetrace()}}]);
        % special handling for exits that come from a ct:fail() call:
        exit:{test_case_failed, Reason2} ->
            ?ct_fail("error ~p:~p/~p failed with ~p~n",
                     [Module, Func, Arity, {Reason2, erlang:get_stacktrace(),
                                     util:get_linetrace()}]);
        exit:Reason2 -> ?ct_fail("exception (exit) in ~p:~p(): ~p~n",
                                 [Module, Func,
                                  {exception, {Reason2, erlang:get_stacktrace(),
                                               util:get_linetrace()}}]);
        error:Reason2 -> ?ct_fail("exception (error) in ~p:~p(): ~p~n",
                                  [Module, Func,
                                   {exception, {Reason2, erlang:get_stacktrace(),
                                                util:get_linetrace()}}])
    end,
    Threads = proplists:get_value(threads, Options, case proplists:get_bool(multi_threaded, Options) of
                                                       true -> erlang:system_info(schedulers);
                                                       false -> 1
                                                    end),
    run_test(Module, Func, Arity, Iterations, ParseState, Threads, Options),
    ok.

-spec test_log/4 :: (module(), atom(), non_neg_integer(), non_neg_integer()) -> ok.
test_log(Module, Func, Arity, Iterations) ->
    EmptyParseState = tester_parse_state:new_parse_state(),
    ParseState = try tester_collect_function_info:collect_fun_info(Module, Func, Arity,
                                      EmptyParseState)
    catch
        throw:Term2 -> ?ct_fail("exception (throw) in ~p:~p(): ~p~n",
                                [Module, Func,
                                 {exception, {Term2, erlang:get_stacktrace(),
                                              util:get_linetrace()}}]);
        % special handling for exits that come from a ct:fail() call:
        exit:{test_case_failed, Reason2} ->
            ?ct_fail("error ~p:~p() failed with ~p~n", [Module, Func,
                                                        {Reason2, erlang:get_stacktrace(),
                                                         util:get_linetrace()}]);
        exit:Reason2 -> ?ct_fail("exception (exit) in ~p:~p(): ~p~n",
                                 [Module, Func,
                                  {exception, {Reason2, erlang:get_stacktrace(),
                                               util:get_linetrace()}}]);
        error:Reason2 -> ?ct_fail("exception (error) in ~p:~p(): ~p~n",
                                  [Module, Func,
                                   {exception, {Reason2, erlang:get_stacktrace(),
                                                util:get_linetrace()}}])
    end,
    io:format(""),
    _ = run(Module, Func, Arity, Iterations, ParseState, []),
    ok.

% @doc options are white_list and seed
-spec test_with_scheduler(list(module()), fun(), list()) -> any().
test_with_scheduler(Modules, F, Options) ->
    test_with_scheduler(Modules, F, Options, 1).

-spec test_with_scheduler(list(module()), fun(), list(), number()) -> any().
test_with_scheduler(Modules, F, Options, Repetitions) ->
    _InstrumentRes = [tester_scheduler:instrument_module(Module) || Module <- Modules],
    Processes = unittest_helper:get_processes(),
    Res = repeat(fun () ->
                         {ok, Pid} = tester_scheduler:start(Options),
                         (catch register(usscheduler, Pid)),
                         Res = (catch F()),
                         unittest_helper:kill_new_processes(Processes, [quiet]),
                         (catch exit(Pid)),
                         (catch unregister(usscheduler)),
                         Res
                 end, Repetitions),
    _DeleteRes = [code:delete(Module) || Module <- Modules],
    Res.

repeat(F, 1) ->
    F();
repeat(F, Repetitions) ->
    _Res = F(),
    repeat(F, Repetitions - 1).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% run tests
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec run/6 :: (module(), atom(), non_neg_integer(), non_neg_integer(),
                tester_parse_state:state(), test_options()) -> any().
run(Module, Func, Arity, Iterations, ParseState, Options) ->
    FeederFun = list_to_atom(atom_to_list(Func) ++ "_feeder"),
    case proplists:get_bool(with_feeder, Options) of
        true ->
            % get spec from feeder
            case tester_parse_state:lookup_type({'fun', Module,
                                                 FeederFun, Arity},
                                                ParseState) of
                {value, FeederFunType} ->
                    % get spec from tested-fun
                    {value, FunType} = tester_parse_state:lookup_type({'fun', Module,
                                                                       Func, Arity},
                                                                      ParseState),
                    run_helper(Module, Func, Arity, Iterations, FunType,
                               FeederFunType, ParseState, Options);
                none ->
                   {fail, no_result, no_result_type, feeder_fun_type_not_found,
                    tester_parse_state,
                    lookup_type,
                    {'fun', Module,
                     FeederFun, Arity},
                    'maybe_not_exported_or_no_spec_or...', erlang:get_stacktrace(),
                    util:get_linetrace()}
            end;
        false ->
            FeederFunType = {union_fun, []},
            % get spec from tested-fun
            {value, FunType} = tester_parse_state:lookup_type({'fun', Module,
                                                               Func, Arity},
                                                              ParseState),
            run_helper(Module, Func, Arity, Iterations, FunType, FeederFunType, ParseState, Options)
    end.

-spec run_helper/8 :: (Module::module(), Fun::atom(), Arity::non_neg_integer(),
                       Iterations::non_neg_integer(),
                       FunType | {union_fun, [FunType,...]},
                       FeederFunType | {union_fun, [FeederFunType,...]},
                       tester_parse_state:state(), test_options()) -> any()
        when is_subtype(FunType, {'fun', type_spec(), type_spec()}).
run_helper(_Module, _Func, _Arity, 0, _FunType, _FeederFunType, _TypeInfos, _Options) ->
    ok;
run_helper(Module, Func, Arity, Iterations, FunType, FeederFunType, TypeInfos, Options) ->
    case run_test_ttt(Module, Func, FunType, FeederFunType, TypeInfos, Options) of
        ok ->
            run_helper(Module, Func, Arity, Iterations - 1, FunType, FeederFunType,
                       TypeInfos, Options);
        Error ->
            Error
    end.

get_arg_and_result_type({union_fun, FunTypes} = _FunType,
                        {union_fun, FeederFunTypes} = _FeederFunType, Options) ->
    {'fun', ArgType, ResultType} = case proplists:get_bool(with_feeder, Options) of
                                        true ->
                                            util:randomelem(FeederFunTypes);
                                       false ->
                                           util:randomelem(FunTypes)
                                    end,
    {ArgType, ResultType}.

run_test_ttt(Module, Func,
             {union_fun, FunTypes} = FunType,
             {union_fun, _FeederFunTypes} = FeederFunType,
             TypeInfos, Options) ->
    {ArgType, ResultType} = get_arg_and_result_type(FunType, FeederFunType, Options),
    Size = 30,
    Args = try tester_value_creator:create_value(ArgType, Size, TypeInfos)
           catch
               Error:Reason ->
                   ct:pal("Reason: ~p~n", [Reason]),
                   {fail, no_result, no_result_type, Error, tester_value_creator,
                    create_value,
                    [ArgType, Size, TypeInfos],
                    Reason, erlang:get_stacktrace(), util:get_linetrace()}
           end,
    case proplists:get_bool(with_feeder, Options) of
        true ->
            % result is a tuple
            Result = apply_feeder(Module, Func, Args, ResultType, TypeInfos),
            case Result of
                {ok, FeededArgs} ->
                    FunResultTypes = [InnerResultType || {'fun', InnerArgType, InnerResultType} <- FunTypes,
                                                         case tester_type_checker:check(FeededArgs, InnerArgType, TypeInfos) of
                                                             true -> true;
                                                             {false, _} -> false
                                                         end],
                    case FunResultTypes of
                        [] ->
                            {fail, no_result, no_result_type,
                             type_check_failed_feeder_result_is_not_valid_input_for_fun,
                             Module, Func, Args, none, erlang:get_stacktrace(),
                             util:get_linetrace()};
                        _ ->
                            apply_args(Module, Func, tuple_to_list(FeededArgs),
                                       {union, FunResultTypes}, TypeInfos)
                    end;
                FeederError ->
                    FeederError
            end;
        false ->
            apply_args(Module, Func, Args, ResultType, TypeInfos)
    end.

% @doc called before the actual test to convert the input values. Can
% be used to implement types which cannot be expressed by type-specs
apply_feeder(Module, Func, Args, ResultType, TypeInfos) ->
    FeederFun = list_to_atom(atom_to_list(Func) ++ "_feeder"),
    try
        Result = apply(Module, FeederFun, Args),
        case tester_type_checker:check(Result, ResultType, TypeInfos) of
            true ->
                {ok, Result};
            {false, ErrMsg} ->
                {fail, no_result, ResultType, type_check_failed_of_feeder_result, Module,
                 FeederFun,
                 Args,
                 ErrMsg, erlang:get_stacktrace(), util:get_linetrace()}
        end
    catch
        Error:Reason ->
            ct:pal("Reason: ~p~n", [Reason]),
            {fail, no_result, no_result_type, Error, Module,
             FeederFun,
             Args,
             Reason, erlang:get_stacktrace(), util:get_linetrace()}
    end.

apply_args(Module, Func, Args, ResultType, TypeInfos) ->
%%    ct:pal("Calling: ~.0p:~.0p(~.0p)", [Module, Func, Args]),
    try erlang:apply(Module, Func, Args) of
        Result ->
%%            ct:pal("Result: ~.0p ~n~.0p", [Result, ResultType]),
            case tester_type_checker:check(Result, ResultType, TypeInfos) of
                true ->
                    ok;
                {false, ErrorMsg} ->
                    % @todo give good error message
                    {fail, Result, ResultType, type_check_failed_on_fun_result, Module, Func,
                     Args, ErrorMsg, no_stacktrace, util:get_linetrace()}
            end
    catch
        exit:{test_case_failed, Reason} ->
            {fail, no_result, no_result_type, test_case_failed, Module, Func,
             Args, Reason, erlang:get_stacktrace(), util:get_linetrace()};
        Error:Reason ->
            {fail, no_result, no_result_type, Error, Module, Func, Args, Reason,
             erlang:get_stacktrace(), util:get_linetrace()}
    end.

-spec run_test/7 :: (module(), atom(), non_neg_integer(), non_neg_integer(),
                     tester_parse_state:state(), integer(), test_options()) -> ok.
run_test(Module, Func, Arity, Iterations, ParseState, Threads, Options) ->
    Master = self(),
    _Pids = [spawn(fun () ->
                           Result = run(Module, Func, Arity,
                                        Iterations div Threads, ParseState, Options),
                           Master ! {result, Result}
                   end) || _ <- lists:seq(1, Threads)],
    Results = [receive {result, Result} -> Result end || _ <- lists:seq(1, Threads)],
    %ct:pal("~w~n", [Results]),
    _ = [fun (Result) ->
                 case Result of
                     {fail, ResultValue, ResultType, Error, Module, Func, Args, Term,
                      StackTrace, LineTrace} ->
                         ArgsStr = case lists:flatten([io_lib:format(", ~1000p", [Arg]) || Arg <- Args]) of
                                       [$,, $ | X] -> X;
                                       X -> X
                                   end,
                         ct:pal("Failed~n"
                                " Message    ~p in ~1000p:~1000p(~s):~n"
                                "            ~p~n"
                                " Result     ~p~n"
                                " ResultType ~p~n"
                                " Stacktrace ~p~n"
                                " Linetrace  ~p~n",
                                [Error, Module, Func, ArgsStr, Term, ResultValue,
                                 ResultType, StackTrace, LineTrace]),
                         ?ct_fail("~.0p in ~.0p:~.0p(~.0p): ~.0p",
                                  [Error, Module, Func, Args, Term]);
                     ok -> ok
                 end
         end(XResult) || XResult <- Results],
    %ct:pal("~w~n", [Results]),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% type check a module
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec type_check_module({module(), [{atom(), non_neg_integer()}]},
                       pos_integer()) -> ok.
type_check_module({Module, InExcludeList}, Count) ->
    ExpFuncs = Module:module_info(exports),
    ExcludeList = [{module_info, 0}, {module_info, 1}] ++ InExcludeList,

    ErrList = [ case lists:member(X, ExpFuncs) of
                    true -> true;
                    false ->
                        ct:pal("Excluded non exported function ~p:~p~n", [Module,X]),
                        false
                end ||
                  X <- ExcludeList ],
    case lists:all(fun(X) -> X end, ErrList) of
        true -> ok;
        false -> throw(error)
    end,

    ResList = [ begin
          ct:pal("Testing ~p:~p/~p~n", [Module, Fun, Arity]),
          test(Module, Fun, Arity, Count)
      end
      || {Fun, Arity} = FA <- ExpFuncs,
         %% >= R15 generates behaviour_info without a type spec so
         %% tester cannot find it. Erlang < R15 checks behaviour_info
         %% itself, so no own tests necessary here.
         %% Silently drop it for modules that export it.
         not lists:member(FA, [{behaviour_info, 1} | ExcludeList]) ],
    case {ResList, InExcludeList} of
        {[], []} -> ok;
        {[], _} ->
            ct:pal("Excluded all exported functions for module ~p?!~n",
                   [Module]),
            throw(error);
        _ -> ok
    end,
    ok.
