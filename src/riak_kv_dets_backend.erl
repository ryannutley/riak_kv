%% -------------------------------------------------------------------
%%
%% riak_dets_backend: storage engine based on DETS tables
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc riak_kv_dets_backend is a Riak storage backend using dets.

-module(riak_kv_dets_backend).
-behavior(riak_kv_backend).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-export([capability/1,capability/3,
         start/2,stop/1,get/2,put/3,list/1,list_bucket/2,
         delete/2, fold/3, fold_bucket_keys/4, is_empty/1, drop/1, callback/3]).

% @type state() = term().
-record(state, {table, path}).

-spec capability(atom()) -> boolean() | 'maybe'.

capability(has_ordered_keys) ->
    false;
capability(keys_and_values_stored_together) ->
    true;
capability(vclocks_and_values_stored_together) ->
    true;
capability(fold_will_block) ->
    true; %% SLF TODO: change this
capability(_) ->
    false.

-spec capability(term(), binary(), atom()) -> boolean().

capability(_State, _Bucket, has_ordered_keys) ->
    false;
capability(_State, _Bucket, keys_and_values_stored_together) ->
    true;
capability(_State, _Bucket, vclocks_and_values_stored_together) ->
    true;
capability(_State, _Bucket, fold_will_block) ->
    true; %% SLF TODO: change this
capability(_State, _Bucket, _) ->
    false.

% @spec start(Partition :: integer(), Config :: proplist()) ->
%                        {ok, state()} | {{error, Reason :: term()}, state()}
start(Partition, Config) ->
    ConfigRoot = proplists:get_value(riak_kv_dets_backend_root, Config),
    if ConfigRoot =:= undefined ->
            riak:stop("riak_kv_dets_backend_root unset, failing.~n");
       true -> ok
    end,

    TablePath = filename:join([ConfigRoot, integer_to_list(Partition)]),
    case filelib:ensure_dir(TablePath) of
        ok -> ok;
        _Error ->
            riak:stop("riak_kv_dets_backend could not ensure"
                      " the existence of its root directory")
    end,

    DetsName = list_to_atom(integer_to_list(Partition)),
    case dets:open_file(DetsName, [{file, TablePath}, 
                                   {min_no_slots, 8192},
                                   {max_no_slots, 16777216}]) of
        {ok, DetsName} ->
            ok = dets:sync(DetsName),
            {ok, #state{table=DetsName, path=TablePath}};
        {error, Reason}  ->
            riak:stop("dets:open_file failed"),
            {error, Reason}
    end.

% @spec stop(state()) -> ok | {error, Reason :: term()}
stop(#state{table=T}) -> dets:close(T).

% get(state(), riak_object:bkey()) ->
%   {ok, Val :: binary()} | {error, Reason :: term()}
% key must be 160b
get(#state{table=T}, BKey) ->
    case dets:lookup(T, BKey) of
        [] -> {error, notfound};
        [{BKey,Val}] -> {ok, Val};
        {error, Err} -> {error, Err}
    end.

% put(state(), riak_object:bkey(), Val :: binary()) ->
%   ok | {error, Reason :: term()}
% key must be 160b
put(#state{table=T},BKey,Val) -> dets:insert(T, {BKey,Val}).

% delete(state(), riak_object:bkey()) ->
%   ok | {error, Reason :: term()}
% key must be 160b
delete(#state{table=T}, BKey) -> dets:delete(T, BKey).

% list(state()) -> [riak_object:bkey()]
list(#state{table=T}) ->
    MList = dets:match(T,{'$1','_'}),
    list(MList,[]).
list([],Acc) -> Acc;
list([[K]|Rest],Acc) -> list(Rest,[K|Acc]).

list_bucket(#state{table=T}, {filter, Bucket, Fun}) ->
    MList = lists:filter(Fun, dets:match(T,{{Bucket,'$1'},'_'})),
    list(MList,[]);
list_bucket(#state{table=T}, Bucket) ->
    case Bucket of
        '_' -> MatchSpec = {{'$1','_'},'_'};
        _ -> MatchSpec = {{Bucket,'$1'},'_'}
    end,
    MList = dets:match(T,MatchSpec),
    list(MList,[]).

fold(#state{table=T}, Fun0, Acc) -> 
    Fun = fun({{B,K}, V}, AccIn) -> Fun0({B,K}, V, AccIn) end,
    dets:foldl(Fun, Acc, T).

fold_bucket_keys(#state{table=T}, Bucket, Fun0, Acc) -> 
    Fun = fun({{B,K}, V}, AccIn) when Bucket == '_'; B == Bucket ->
                  Fun0({B,K}, V, AccIn);
             (_BK_V, AccIn) ->
                  AccIn
          end,
    dets:foldl(Fun, Acc, T).

is_empty(#state{table=T}) ->
    ok = dets:sync(T),
    dets:info(T, size) =:= 0.

drop(#state{table=T, path=P}) ->
    ok = dets:close(T),
    ok = file:delete(P).

%% Ignore callbacks for other backends so multi backend works
callback(_State, _Ref, _Msg) ->
    ok.

-ifdef(TEST).
%%
%% Test
%%

simple_test() ->
    ?assertCmd("rm -rf test/dets-backend"),
    Config = [{riak_kv_dets_backend_root, "test/dets-backend"}],
    riak_kv_backend:standard_test(?MODULE, Config).

-ifdef(EQC).

eqc_test_() ->
    {timeout, 60,
     [{"eqc test", ?_test(eqc_test_inner())}]}.

eqc_test_inner() ->
    Cleanup = 
        fun(State, OldS) ->
                case State of
                    #state{} ->
                        drop(State);
                    _ ->
                        ok
                end,                
                [file:delete(S#state.path) || S <- OldS]
        end,
    Config = [{riak_kv_dets_backend_root, "test/dets-backend"}],
    ?assertCmd("rm -rf test/dets-backend"),
    ?assertEqual(true, backend_eqc:test(?MODULE, false, Config, Cleanup)).
-endif. % EQC
-endif. % TEST
