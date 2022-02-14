%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_binding).

-include_lib("khepri/include/khepri.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include("amqqueue.hrl").

-export([recover/0, recover/2, exists/1, add/2, add/3, remove/1, remove/2, remove/3, remove/4]).
-export([list/1, list_for_source/1, list_for_destination/1,
         list_for_source_and_destination/2, list_explicit/0]).
-export([new_deletions/0, combine_deletions/2, add_deletion/3,
         process_deletions/2, binding_action/3]).
-export([info_keys/0, info/1, info/2, info_all/1, info_all/2, info_all/4]).
%% these must all be run inside a mnesia tx
-export([has_for_source_in_mnesia/1, remove_for_source_in_mnesia/1,
         remove_default_exchange_binding_rows_of/1]).

-export([remove_for_source_in_khepri/1,
         remove_for_destination_in_mnesia/2, remove_for_destination_in_khepri/2,
         remove_transient_for_destination_in_mnesia/1, remove_transient_for_destination_in_khepri/1,
         has_for_source_in_khepri/1, process_deletions_in_khepri/2]).

-export([implicit_for_destination/1, reverse_binding/1]).
-export([new/4]).

-define(DEFAULT_EXCHANGE(VHostPath), #resource{virtual_host = VHostPath,
                                              kind = exchange,
                                              name = <<>>}).

%%----------------------------------------------------------------------------

-export_type([key/0, deletions/0]).

-type key() :: binary().

-type bind_errors() :: rabbit_types:error(
                         {'resources_missing',
                          [{'not_found', (rabbit_types:binding_source() |
                                          rabbit_types:binding_destination())} |
                           {'absent', amqqueue:amqqueue()}]}).

-type bind_ok_or_error() :: 'ok' | bind_errors() |
                            rabbit_types:error(
                              {'binding_invalid', string(), [any()]}).
-type bind_res() :: bind_ok_or_error() | rabbit_misc:thunk(bind_ok_or_error()).
-type inner_fun() ::
        fun((rabbit_types:exchange(),
             rabbit_types:exchange() | amqqueue:amqqueue()) ->
                   rabbit_types:ok_or_error(rabbit_types:amqp_error())).
-type bindings() :: [rabbit_types:binding()].

%% TODO this should really be opaque but that seems to confuse 17.1's
%% dialyzer into objecting to everything that uses it.
-type deletions() :: dict:dict().

%%----------------------------------------------------------------------------

-spec new(rabbit_types:exchange(),
          key(),
          rabbit_types:exchange() | amqqueue:amqqueue(),
          rabbit_framing:amqp_table()) ->
    rabbit_types:binding().

new(Src, RoutingKey, Dst, #{}) ->
    new(Src, RoutingKey, Dst, []);
new(Src, RoutingKey, Dst, Arguments) when is_map(Arguments) ->
    new(Src, RoutingKey, Dst, maps:to_list(Arguments));
new(Src, RoutingKey, Dst, Arguments) ->
    #binding{source = Src, key = RoutingKey, destination = Dst, args = Arguments}.


-define(INFO_KEYS, [source_name, source_kind,
                    destination_name, destination_kind,
                    routing_key, arguments,
                    vhost]).

%% Global table recovery

recover() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> recover_in_mnesia() end,
      fun() -> recover_in_khepri() end).

recover_in_mnesia() ->
    rabbit_misc:execute_mnesia_transaction(
        fun () ->
            mnesia:lock({table, rabbit_durable_route}, read),
            mnesia:lock({table, rabbit_semi_durable_route}, write),
            Routes = rabbit_misc:dirty_read_all(rabbit_durable_route),
            Fun = fun(Route) ->
                mnesia:dirty_write(rabbit_semi_durable_route, Route)
            end,
        lists:foreach(Fun, Routes)
    end).

recover_in_khepri() ->
    rabbit_khepri:transaction(
        fun () ->
                Path = khepri_durable_routes_path(),
                {ok, Map} = rabbit_khepri:tx_match_and_get_data(Path ++ [?STAR_STAR]),
                Fun = fun([?MODULE, durable_routes | Rest], Value) ->
                              SemiDurablePath = [?MODULE, semi_durable_routes] ++ Rest,
                              khepri_tx:put(SemiDurablePath, #kpayload_data{data = Value})
                      end,
                maps:foreach(Fun, Map)
    end).

%% Virtual host-specific recovery

-spec recover([rabbit_exchange:name()], [rabbit_amqqueue:name()]) ->
                        'ok'.
recover(XNames, QNames) ->
    XNameSet = sets:from_list(XNames),
    QNameSet = sets:from_list(QNames),
    SelectSetInMnesia = fun (#resource{kind = exchange}) -> XNameSet;
                            (#resource{kind = queue})    -> QNameSet
                        end,
    SelectSetInKhepri = fun([_, _, _, _, exchange | _]) -> XNameSet;
                           ([_, _, _, _, queue | _]) -> QNameSet
                        end,
    {ok, Gatherer} = gatherer:start_link(),
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              [recover_semi_durable_route_in_mnesia(Gatherer, R, SelectSetInMnesia(Dst)) ||
                  R = #route{binding = #binding{destination = Dst}} <-
                      rabbit_misc:dirty_read_all(rabbit_semi_durable_route)]
      end,
      fun() ->
              Path = khepri_semi_durable_routes_path(),
              {ok, Map} = rabbit_khepri:match_and_get_data(Path ++ [?STAR_STAR]),
              maps:foreach(
                fun(K, _) ->
                        recover_semi_durable_route_in_khepri(Gatherer, K, SelectSetInKhepri(K))
                end, Map)
      end),
    empty = gatherer:out(Gatherer),
    ok = gatherer:stop(Gatherer),
    ok.

recover_semi_durable_route_in_mnesia(Gatherer, R = #route{binding = B}, ToRecover) ->
    #binding{source = Src, destination = Dst} = B,
    case sets:is_element(Dst, ToRecover) of
        true  -> {ok, X} = rabbit_exchange:lookup(Src),
                 ok = gatherer:fork(Gatherer),
                 ok = worker_pool:submit_async(
                        fun () ->
                                recover_semi_durable_route_txn_in_mnesia(R, X),
                                gatherer:finish(Gatherer)
                        end);
        false -> ok
    end.

recover_semi_durable_route_in_khepri(Gatherer, Path, ToRecover) ->
    Dst = destination_from_khepri_path(Path),
    Src = source_from_khepri_path(Path),
    case sets:is_element(Dst, ToRecover) of
        true  -> {ok, X} = rabbit_exchange:lookup(Src),
                 ok = gatherer:fork(Gatherer),
                 ok = worker_pool:submit_async(
                        fun () ->
                                recover_semi_durable_route_txn_in_khepri(Path, X),
                                gatherer:finish(Gatherer)
                        end);
        false -> ok
    end.

recover_semi_durable_route_txn_in_mnesia(R = #route{binding = B}, X) ->
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              case mnesia:read(rabbit_semi_durable_route, B, read) of
                  [] -> no_recover;
                  _  -> ok = sync_transient_route(R, fun mnesia:write/3),
                        rabbit_exchange:serial_in_mnesia(X)
              end
      end,
      fun (no_recover, _)     -> ok;
          (_Serial,    true)  -> x_callback(transaction, X, sync_binding, B);
          (Serial,     false) -> x_callback(Serial,      X, sync_binding, B)
      end).

recover_semi_durable_route_txn_in_khepri(Path, X) ->
    rabbit_khepri_misc:execute_khepri_transaction(
      fun () ->
              case khepri_tx:get(Path) of
                  {ok, #{Path := #{data := Set}}} ->
                      sync_transient_route_in_khepri(Path, Set),
                      {rabbit_exchange:serial_in_mnesia(X), Set};
                  _ ->
                      no_recover
              end
      end,
      fun (no_recover) -> ok;
          ({Serial, Set}) ->
              sets:fold(fun(B, none) ->
                                x_callback(transaction, X, sync_binding, B),
                                x_callback(Serial, X, sync_binding, B)
                        end, none, Set),
              ok
      end).

-spec exists(rabbit_types:binding()) -> boolean() | bind_errors().

exists(#binding{source = ?DEFAULT_EXCHANGE(_),
                destination = #resource{kind = queue, name = QName} = Queue,
                key = QName,
                args = []}) ->
    case rabbit_amqqueue:lookup(Queue) of
        {ok, _} -> true;
        {error, not_found} -> false
    end;
exists(Binding) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              binding_action(
                Binding, fun (_Src, _Dst, B) ->
                                 rabbit_misc:const(mnesia:read({rabbit_route, B}) /= [])
                         end, fun not_found_or_absent_errs_in_mnesia/1)
      end,
      fun() ->
              Path = khepri_route_path(Binding),
              binding_action_in_khepri(
                Binding, fun (_Src, _Dst, B) ->
                                 rabbit_misc:const(exists_in_khepri(Path, B))
                         end,
               fun not_found_or_absent_errs_in_khepri/1)
      end).

exists_in_khepri(Path, Binding) ->
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Set}}} ->
            sets:is_element(Binding, Set);
        _ ->
            false
    end.

-spec add(rabbit_types:binding(), rabbit_types:username()) -> bind_res().

add(Binding, ActingUser) -> add(Binding, fun (_Src, _Dst) -> ok end, ActingUser).

-spec add(rabbit_types:binding(), inner_fun(), rabbit_types:username()) -> bind_res().

add(Binding, InnerFun, ActingUser) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> add_in_mnesia(Binding, InnerFun, ActingUser) end,
      fun() -> add_in_khepri(Binding, InnerFun, ActingUser) end).

add_in_mnesia(Binding, InnerFun, ActingUser) ->
    binding_action(
      Binding,
      fun (Src, Dst, B) ->
              case rabbit_exchange:validate_binding(Src, B) of
                  ok ->
                      %% this argument is used to check queue exclusivity;
                      %% in general, we want to fail on that in preference to
                      %% anything else
                      case InnerFun(Src, Dst) of
                          ok ->
                              case mnesia:read({rabbit_route, B}) of
                                  []  -> add_in_mnesia(Src, Dst, B, ActingUser);
                                  [_] -> fun () -> ok end
                              end;
                          {error, _} = Err ->
                              rabbit_misc:const(Err)
                      end;
                  {error, _} = Err ->
                      rabbit_misc:const(Err)
              end
      end, fun not_found_or_absent_errs_in_mnesia/1).

add_in_khepri(Binding, InnerFun, ActingUser) ->
    Path = khepri_route_path(Binding),
    binding_action_in_khepri(
      Binding,
      fun (Src, Dst, B) ->
              case rabbit_exchange:validate_binding(Src, B) of
                  ok ->
                      %% this argument is used to check queue exclusivity;
                      %% in general, we want to fail on that in preference to
                      %% anything else
                      case InnerFun(Src, Dst) of
                          ok ->
                              case exists_in_khepri(Path, B) of
                                  true -> rabbit_misc:const(ok);
                                  false -> add_in_khepri(Src, Dst, B, ActingUser)
                              end;
                          {error, _} = Err ->
                              rabbit_misc:const(Err)
                      end;
                  {error, _} = Err ->
                      rabbit_misc:const(Err)
              end
      end, fun not_found_or_absent_errs_in_khepri/1).

add_in_mnesia(Src, Dst, B, ActingUser) ->
    [SrcDurable, DstDurable] = [durable(E) || E <- [Src, Dst]],
    ok = sync_route(#route{binding = B}, SrcDurable, DstDurable,
                    fun mnesia:write/3),
    x_callback(transaction, Src, sync_binding, B),
    Serial = rabbit_exchange:serial_in_mnesia(Src),
    fun () ->
        x_callback(Serial, Src, sync_binding, B),
        ok = rabbit_event:notify(
            binding_created,
            info(B) ++ [{user_who_performed_action, ActingUser}])
    end.

add_in_khepri(Src, Dst, B, ActingUser) ->
    [SrcDurable, DstDurable] = [durable(E) || E <- [Src, Dst]],
    ok = add_binding(#route{binding = B}, SrcDurable, DstDurable),
    Serial = rabbit_exchange:serial_in_khepri(Src),
    fun () ->
            x_callback(transaction, Src, sync_binding, B),
            x_callback(Serial, Src, sync_binding, B),
            %% TODO should it be a trigger? maybe the full fun?
            ok = rabbit_event:notify(
                   binding_created,
                   info(B) ++ [{user_who_performed_action, ActingUser}])
    end.

-spec remove(rabbit_types:binding()) -> bind_res().
remove(Binding) -> remove(Binding, fun (_Src, _Dst) -> ok end, ?INTERNAL_USER).

-spec remove(rabbit_types:binding(), rabbit_types:username()) -> bind_res().
remove(Binding, ActingUser) -> remove(Binding, fun (_Src, _Dst) -> ok end, ActingUser).


-spec remove(rabbit_types:binding(), inner_fun(), rabbit_types:username()) -> bind_res().
remove(Binding, InnerFun, ActingUser) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> remove_in_mnesia(Binding, InnerFun, ActingUser) end,
      fun() -> remove_in_khepri(Binding, InnerFun, ActingUser) end).

remove_in_mnesia(Binding, InnerFun, ActingUser) ->
    binding_action(
      Binding,
      fun (Src, Dst, B) ->
              lock_resource(Src, read),
              lock_resource(Dst, read),
              case mnesia:read(rabbit_route, B, write) of
                  [] -> case mnesia:read(rabbit_durable_route, B, write) of
                            [] -> rabbit_misc:const(ok);
                            %% We still delete the binding and run
                            %% all post-delete functions if there is only
                            %% a durable route in the database
                            _  -> remove_in_mnesia(Src, Dst, B, ActingUser)
                        end;
                  _  -> case InnerFun(Src, Dst) of
                            ok               -> remove_in_mnesia(Src, Dst, B, ActingUser);
                            {error, _} = Err -> rabbit_misc:const(Err)
                        end
              end
      end, fun absent_errs_only_in_mnesia/1).

remove_in_khepri(Binding, InnerFun, ActingUser) ->
    Path = khepri_route_path(Binding),
    DurablePath = khepri_durable_route_path(Binding),
    binding_action_in_khepri(
      Binding,
      fun (Src, Dst, B) ->
              case exists_in_khepri(Path, Binding) of
                  false ->
                      case exists_in_khepri(DurablePath, Binding) of
                          false -> rabbit_misc:const(ok);
                          %% We still delete the binding and run
                          %% all post-delete functions if there is only
                          %% a durable route in the database
                          true -> remove_in_khepri(Src, Dst, B, ActingUser)
                      end;
                  true ->
                      case InnerFun(Src, Dst) of
                          ok -> remove_in_khepri(Src, Dst, B, ActingUser);
                          {error, _} = Err -> rabbit_misc:const(Err)
                      end
              end
      end, fun absent_errs_only_in_khepri/1).

remove(Src, Dst, B, ActingUser) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> remove_in_mnesia(Src, Dst, B, ActingUser) end,
      fun() -> remove_in_khepri(Src, Dst, B, ActingUser) end).

remove_in_mnesia(Src, Dst, B, ActingUser) ->
    ok = sync_route(#route{binding = B}, durable(Src), durable(Dst),
                    fun delete/3),
    Deletions = maybe_auto_delete_in_mnesia(
                  B#binding.source, [B], new_deletions(), false),
    process_deletions(Deletions, ActingUser).

remove_in_khepri(Src, Dst, B, ActingUser) ->
    ok = delete_binding(B, durable(Src), durable(Dst)),
    Deletions = maybe_auto_delete_in_khepri(
                  B#binding.source, [B], new_deletions(), false),
    process_deletions(Deletions, ActingUser).

%% Implicit bindings are implicit as of rabbitmq/rabbitmq-server#1721.
remove_default_exchange_binding_rows_of(Dst = #resource{}) ->
    case implicit_for_destination(Dst) of
        [Binding] ->
            mnesia:dirty_delete(rabbit_durable_route, Binding),
            mnesia:dirty_delete(rabbit_semi_durable_route, Binding),
            mnesia:dirty_delete(rabbit_reverse_route,
                                reverse_binding(Binding)),
            mnesia:dirty_delete(rabbit_route, Binding);
        _ ->
            %% no binding to remove or
            %% a competing tx has beaten us to it?
            ok
    end,
    ok.

-spec list_explicit() -> bindings().

list_explicit() ->
    mnesia:async_dirty(
        fun () ->
            AllRoutes = mnesia:dirty_match_object(rabbit_route, #route{_ = '_'}),
            %% if there are any default exchange bindings left after an upgrade
            %% of a pre-3.8 database, filter them out
            AllBindings = [B || #route{binding = B} <- AllRoutes],
            lists:filter(fun(#binding{source = S}) ->
                            not (S#resource.kind =:= exchange andalso S#resource.name =:= <<>>)
                         end, AllBindings)
            end).

-spec list(rabbit_types:vhost()) -> bindings().

list(VHostPath) ->
    VHostResource = rabbit_misc:r(VHostPath, '_'),
    Route = #route{binding = #binding{source      = VHostResource,
                                      destination = VHostResource,
                                      _           = '_'},
                   _       = '_'},
    %% if there are any default exchange bindings left after an upgrade
    %% of a pre-3.8 database, filter them out
    AllBindings = [B || #route{binding = B} <- mnesia:dirty_match_object(rabbit_route,
                                                                         Route)],
    Filtered    = lists:filter(fun(#binding{source = S}) ->
                                       S =/= ?DEFAULT_EXCHANGE(VHostPath)
                               end, AllBindings),
    implicit_bindings(VHostPath) ++ Filtered.

-spec list_for_source
        (rabbit_types:binding_source()) -> bindings().

list_for_source(?DEFAULT_EXCHANGE(VHostPath)) ->
    implicit_bindings(VHostPath);
list_for_source(SrcName) ->
    mnesia:async_dirty(
      fun() ->
              Route = #route{binding = #binding{source = SrcName, _ = '_'}},
              [B || #route{binding = B}
                        <- mnesia:match_object(rabbit_route, Route, read)]
      end).

-spec list_for_destination
        (rabbit_types:binding_destination()) -> bindings().

list_for_destination(DstName = #resource{virtual_host = VHostPath}) ->
    AllBindings = mnesia:async_dirty(
          fun() ->
                  Route = #route{binding = #binding{destination = DstName,
                                                    _ = '_'}},
                  [reverse_binding(B) ||
                      #reverse_route{reverse_binding = B} <-
                          mnesia:match_object(rabbit_reverse_route,
                                              reverse_route(Route), read)]
          end),
    Filtered    = lists:filter(fun(#binding{source = S}) ->
                                       S =/= ?DEFAULT_EXCHANGE(VHostPath)
                               end, AllBindings),
    implicit_for_destination(DstName) ++ Filtered.

implicit_bindings(VHostPath) ->
    DstQueues = rabbit_amqqueue:list_names(VHostPath),
    [ #binding{source = ?DEFAULT_EXCHANGE(VHostPath),
               destination = DstQueue,
               key = QName,
               args = []}
      || DstQueue = #resource{name = QName} <- DstQueues ].

implicit_for_destination(DstQueue = #resource{kind = queue,
                                              virtual_host = VHostPath,
                                              name = QName}) ->
    [#binding{source = ?DEFAULT_EXCHANGE(VHostPath),
              destination = DstQueue,
              key = QName,
              args = []}];
implicit_for_destination(_) ->
    [].

-spec list_for_source_and_destination
        (rabbit_types:binding_source(), rabbit_types:binding_destination()) ->
                                                bindings().

list_for_source_and_destination(?DEFAULT_EXCHANGE(VHostPath),
                                #resource{kind = queue,
                                          virtual_host = VHostPath,
                                          name = QName} = DstQueue) ->
    [#binding{source = ?DEFAULT_EXCHANGE(VHostPath),
              destination = DstQueue,
              key = QName,
              args = []}];
list_for_source_and_destination(SrcName, DstName) ->
    mnesia:async_dirty(
      fun() ->
              Route = #route{binding = #binding{source      = SrcName,
                                                destination = DstName,
                                                _           = '_'}},
              [B || #route{binding = B} <- mnesia:match_object(rabbit_route,
                                                               Route, read)]
      end).

-spec info_keys() -> rabbit_types:info_keys().

info_keys() -> ?INFO_KEYS.

map(VHostPath, F) ->
    %% TODO: there is scope for optimisation here, e.g. using a
    %% cursor, parallelising the function invocation
    lists:map(F, list(VHostPath)).

infos(Items, B) -> [{Item, i(Item, B)} || Item <- Items].

i(source_name,      #binding{source      = SrcName})    -> SrcName#resource.name;
i(source_kind,      #binding{source      = SrcName})    -> SrcName#resource.kind;
i(vhost,            #binding{source      = SrcName})    -> SrcName#resource.virtual_host;
i(destination_name, #binding{destination = DstName})    -> DstName#resource.name;
i(destination_kind, #binding{destination = DstName})    -> DstName#resource.kind;
i(routing_key,      #binding{key         = RoutingKey}) -> RoutingKey;
i(arguments,        #binding{args        = Arguments})  -> Arguments;
i(Item, _) -> throw({bad_argument, Item}).

-spec info(rabbit_types:binding()) -> rabbit_types:infos().

info(B = #binding{}) -> infos(?INFO_KEYS, B).

-spec info(rabbit_types:binding(), rabbit_types:info_keys()) ->
          rabbit_types:infos().

info(B = #binding{}, Items) -> infos(Items, B).

-spec info_all(rabbit_types:vhost()) -> [rabbit_types:infos()].

info_all(VHostPath) -> map(VHostPath, fun (B) -> info(B) end).

-spec info_all(rabbit_types:vhost(), rabbit_types:info_keys()) ->
          [rabbit_types:infos()].

info_all(VHostPath, Items) -> map(VHostPath, fun (B) -> info(B, Items) end).

-spec info_all(rabbit_types:vhost(), rabbit_types:info_keys(),
                    reference(), pid()) -> 'ok'.

info_all(VHostPath, Items, Ref, AggregatorPid) ->
    rabbit_control_misc:emitting_map(
      AggregatorPid, Ref, fun(B) -> info(B, Items) end, list(VHostPath)).

-spec has_for_source_in_mnesia(rabbit_types:binding_source()) -> boolean().

has_for_source_in_mnesia(SrcName) ->
    Match = #route{binding = #binding{source = SrcName, _ = '_'}},
    %% we need to check for semi-durable routes (which subsumes
    %% durable routes) here too in case a bunch of routes to durable
    %% queues have been removed temporarily as a result of a node
    %% failure
    contains(rabbit_route, Match) orelse
        contains(rabbit_semi_durable_route, Match).

has_for_source_in_khepri(SrcName) ->
    (not maps:is_empty(match_source_in_khepri(SrcName, routes)))
        orelse (not maps:is_empty(match_source_in_khepri(
                                    SrcName, semi_durable_routes))).

-spec remove_for_source_in_mnesia(rabbit_types:binding_source()) -> bindings().

remove_for_source_in_mnesia(SrcName) ->
    lock_resource(SrcName),
    Match = #route{binding = #binding{source = SrcName, _ = '_'}},
    remove_routes(
      lists:usort(
        mnesia:dirty_match_object(rabbit_route, Match) ++
            mnesia:dirty_match_object(rabbit_semi_durable_route, Match))).

remove_for_source_in_khepri(SrcName) ->
    %% TODO merge these 4 tables into one, they are only flags!
    Bindings = match_source_in_khepri(SrcName, routes),
    SemiDurableBindings = match_source_in_khepri(SrcName, semi_durable_routes),
    remove_in_khepri(Bindings),
    remove_in_khepri(match_source_in_khepri(SrcName, durable_routes)),
    remove_in_khepri(SemiDurableBindings),
    remove_in_khepri(match_source_in_khepri(SrcName, reverse_routes)),
    maps:fold(fun(_, Set, Acc) ->
                      sets:to_list(Set) ++ Acc
              end, [], maps:merge(Bindings, SemiDurableBindings)).

remove_in_khepri(Map) when is_map(Map) ->
    maps:foreach(fun(K, _V) ->
                         khepri_tx:delete(K)
                 end, Map).

remove_in_khepri(Map, Type) when is_map(Map) ->
    maps:foreach(fun(K, _V) ->
                         khepri_tx:delete(update_khepri_path_to(K, Type))
                 end, Map).

-spec remove_for_destination_in_mnesia
        (rabbit_types:binding_destination(), boolean()) -> deletions().

remove_for_destination_in_mnesia(DstName, OnlyDurable) ->
    remove_for_destination_in_mnesia(DstName, OnlyDurable, fun remove_routes/1).

-spec remove_transient_for_destination_in_mnesia
        (rabbit_types:binding_destination()) -> deletions().

remove_transient_for_destination_in_mnesia(DstName) ->
    remove_for_destination_in_mnesia(DstName, false, fun remove_transient_routes/1).

%%----------------------------------------------------------------------------

durable(#exchange{durable = D}) -> D;
durable(Q) when ?is_amqqueue(Q) ->
    amqqueue:is_durable(Q).

binding_action(Binding, Fun, ErrFun) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> binding_action_in_mnesia(Binding, Fun, ErrFun) end,
      fun() -> binding_action_in_khepri(Binding, Fun, ErrFun) end).

binding_action_in_mnesia(Binding = #binding{source      = SrcName,
                                            destination = DstName,
                                            args        = Arguments}, Fun, ErrFun) ->
    call_with_source_and_destination_in_mnesia(
      SrcName, DstName,
      fun (Src, Dst) ->
              SortedArgs = rabbit_misc:sort_field_table(Arguments),
              Fun(Src, Dst, Binding#binding{args = SortedArgs})
      end, ErrFun).

binding_action_in_khepri(Binding = #binding{source      = SrcName,
                                            destination = DstName,
                                            args        = Arguments}, Fun, ErrFun) ->
    call_with_source_and_destination_in_khepri(
      SrcName, DstName,
      fun (Src, Dst) ->
              SortedArgs = rabbit_misc:sort_field_table(Arguments),
              Fun(Src, Dst, Binding#binding{args = SortedArgs})
      end, ErrFun).

call_with_source_and_destination_in_khepri(SrcName, DstName, Fun, ErrFun) ->
    SrcFun = khepri_lookup_fun_for_resource(SrcName),
    DstFun = khepri_lookup_fun_for_resource(DstName),
    rabbit_kepri_misc:execute_khepri_tx_with_tail(
      fun () ->
              case {SrcFun(SrcName), DstFun(DstName)} of
                  {[Src], [Dst]} -> Fun(Src, Dst);
                  {[],    [_]  } -> ErrFun([SrcName]);
                  {[_],   []   } -> ErrFun([DstName]);
                  {[],    []   } -> ErrFun([SrcName, DstName])
              end
      end).

khepri_lookup_fun_for_resource(#resource{kind = queue}) ->
    fun(Name) -> rabbit_amqqueue:lookup_as_list_in_khepri(rabbit_queue, Name) end;
khepri_lookup_fun_for_resource(#resource{kind = exchange}) ->
    fun rabbit_exchange:lookup_as_list_in_khepri/1.

sync_route(Route, true, true, Fun) ->
    ok = Fun(rabbit_durable_route, Route, write),
    sync_route(Route, false, true, Fun);

sync_route(Route, false, true, Fun) ->
    ok = Fun(rabbit_semi_durable_route, Route, write),
    sync_route(Route, false, false, Fun);

sync_route(Route, _SrcDurable, false, Fun) ->
    sync_transient_route(Route, Fun).

sync_transient_route(Route, Fun) ->
    ok = Fun(rabbit_route, Route, write),
    ok = Fun(rabbit_reverse_route, reverse_route(Route), write).

binding_set(Path) ->
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Set}}} ->
            Set;
        _ ->
            sets:new()
    end.

add_binding(Binding, true, true) ->
    Path = khepri_durable_route_path(Binding),
    Set = binding_set(Path),
    {ok, _} = khepri_tx:put(Path, #kpayload_data{data = sets:add_element(Binding, Set)}),
    add_binding(Binding, false, true);

add_binding(Binding, false, true) ->
    Path = khepri_semi_durable_route_path(Binding),
    Set = binding_set(Path),
    {ok, _} = khepri_tx:put(Path, #kpayload_data{data = sets:add_element(Binding, Set)}),
    add_binding(Binding, false, false);

add_binding(Binding, _SrcDurable, false) ->
    Path = khepri_route_path(Binding),
    Set = binding_set(Path),
    {ok, _} = khepri_tx:put(Path, #kpayload_data{data = sets:add_element(Binding, Set)}),
    ReversePath = khepri_reverse_route_path(Binding),
    RSet = binding_set(ReversePath),
    {ok, _} = khepri_tx:put(ReversePath,
                            #kpayload_data{data = sets:add_element(reverse_binding(Binding), RSet)}).

sync_transient_route_in_khepri(Path0, Set) ->
    Path = update_khepri_path_to(Path0, routes),
    ReversePath = update_khepri_path_to(Path0, reverse_routes),
    {ok, _} = khepri_tx:put(Path, #kpayload_data{data = Set}),
    {ok, _} = khepri_tx:put(ReversePath, #kpayload_data{data = reverse_set_of_bindings(Set)}).

delete_binding(Binding, true, true) ->
    Path = khepri_durable_route_path(Binding),
    Set = binding_set(Path),
    delete_binding_or_path(Path, Set, Binding),
    delete_binding(Binding, false, true);

delete_binding(Binding, false, true) ->
    Path = khepri_semi_durable_route_path(Binding),
    Set = binding_set(Path),
    delete_binding_or_path(Path, Set, Binding),
    delete_binding(Binding, false, false);

delete_binding(Binding, _SrcDurable, false) ->
    Path = khepri_route_path(Binding),
    Set = binding_set(Path),
    delete_binding_or_path(Path, Set, Binding),
    ReversePath = khepri_reverse_route_path(Binding),
    RSet = binding_set(ReversePath),
    delete_binding_or_path(ReversePath, RSet, reverse_binding(Binding)).

delete_binding_or_path(Path, Set0, Binding) ->
    Set = sets:del_element(Binding, Set0),
    case sets:is_empty(Set) of
        true ->
            khepri_tx:delete(Path);
        false ->
            {ok, _} = khepri_tx:put(Path, #kpayload_data{data = Set})
    end.

call_with_source_and_destination_in_mnesia(SrcName, DstName, Fun, ErrFun) ->
    SrcTable = table_for_resource(SrcName),
    DstTable = table_for_resource(DstName),
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () ->
              case {mnesia:read({SrcTable, SrcName}),
                    mnesia:read({DstTable, DstName})} of
                  {[Src], [Dst]} -> Fun(Src, Dst);
                  {[],    [_]  } -> ErrFun([SrcName]);
                  {[_],   []   } -> ErrFun([DstName]);
                  {[],    []   } -> ErrFun([SrcName, DstName])
              end
      end).

not_found_or_absent_errs_in_mnesia(Names) ->
    Errs = [not_found_or_absent_in_mnesia(Name) || Name <- Names],
    rabbit_misc:const({error, {resources_missing, Errs}}).

not_found_or_absent_errs_in_khepri(Names) ->
    Errs = [not_found_or_absent_in_khepri(Name) || Name <- Names],
    rabbit_misc:const({error, {resources_missing, Errs}}).

absent_errs_only_in_mnesia(Names) ->
    Errs = [E || Name <- Names,
                 {absent, _Q, _Reason} = E <- [not_found_or_absent_in_mnesia(Name)]],
    rabbit_misc:const(case Errs of
                          [] -> ok;
                          _  -> {error, {resources_missing, Errs}}
                      end).

absent_errs_only_in_khepri(Names) ->
    Errs = [E || Name <- Names,
                 {absent, _Q, _Reason} = E <- [not_found_or_absent_in_khepri(Name)]],
    rabbit_misc:const(case Errs of
                          [] -> ok;
                          _  -> {error, {resources_missing, Errs}}
                      end).

table_for_resource(#resource{kind = exchange}) -> rabbit_exchange;
table_for_resource(#resource{kind = queue})    -> rabbit_queue.

not_found_or_absent_in_mnesia(#resource{kind = exchange} = Name) ->
    {not_found, Name};
not_found_or_absent_in_mnesia(#resource{kind = queue}    = Name) ->
    case rabbit_amqqueue:not_found_or_absent_in_mnesia(Name) of
        not_found                 -> {not_found, Name};
        {absent, _Q, _Reason} = R -> R
    end.

not_found_or_absent_in_khepri(#resource{kind = exchange} = Name) ->
    {not_found, Name};
not_found_or_absent_in_khepri(#resource{kind = queue}    = Name) ->
    case rabbit_amqqueue:not_found_or_absent_in_khepri(Name) of
        not_found                 -> {not_found, Name};
        {absent, _Q, _Reason} = R -> R
    end.

contains(Table, MatchHead) ->
    continue(mnesia:select(Table, [{MatchHead, [], ['$_']}], 1, read)).

continue('$end_of_table')    -> false;
continue({[_|_], _})         -> true;
continue({[], Continuation}) -> continue(mnesia:select(Continuation)).

remove_routes(Routes) ->
    %% This partitioning allows us to suppress unnecessary delete
    %% operations on disk tables, which require an fsync.
    {RamRoutes, DiskRoutes} =
        lists:partition(fun (R) -> mnesia:read(
                                     rabbit_durable_route, R#route.binding, read) == [] end,
                        Routes),
    {RamOnlyRoutes, SemiDurableRoutes} =
        lists:partition(fun (R) -> mnesia:read(
                                     rabbit_semi_durable_route, R#route.binding, read) == [] end,
                        RamRoutes),
    %% Of course the destination might not really be durable but it's
    %% just as easy to try to delete it from the semi-durable table
    %% than check first
    [ok = sync_route(R, true,  true, fun delete/3) ||
        R <- DiskRoutes],
    [ok = sync_route(R, false, true, fun delete/3) ||
        R <- SemiDurableRoutes],
    [ok = sync_route(R, false, false, fun delete/3) ||
        R <- RamOnlyRoutes],
    [R#route.binding || R <- Routes].


delete(Tab, #route{binding = B}, LockKind) ->
    mnesia:delete(Tab, B, LockKind);
delete(Tab, #reverse_route{reverse_binding = B}, LockKind) ->
    mnesia:delete(Tab, B, LockKind).

remove_transient_routes(Routes) ->
    [begin
         ok = sync_transient_route(R, fun delete/3),
         R#route.binding
     end || R <- Routes].

remove_for_destination_in_mnesia(DstName, OnlyDurable, Fun) ->
    lock_resource(DstName),
    MatchFwd = #route{binding = #binding{destination = DstName, _ = '_'}},
    MatchRev = reverse_route(MatchFwd),
    Routes = case OnlyDurable of
                 false ->
                        [reverse_route(R) ||
                              R <- mnesia:dirty_match_object(
                                     rabbit_reverse_route, MatchRev)];
                 true  -> lists:usort(
                            mnesia:dirty_match_object(
                              rabbit_durable_route, MatchFwd) ++
                                mnesia:dirty_match_object(
                                  rabbit_semi_durable_route, MatchFwd))
             end,
    Bindings = Fun(Routes),
    group_bindings_fold(fun maybe_auto_delete_in_mnesia/4, new_deletions(),
                        lists:keysort(#binding.source, Bindings), OnlyDurable).

remove_transient_for_destination_in_khepri(DstName) ->
    ReverseBindingsMap = match_destination_in_khepri(DstName, reverse_routes),
    remove_in_khepri(ReverseBindingsMap),
    remove_in_khepri(ReverseBindingsMap, routes),
    Bindings = maps:fold(fun(_, Set, Acc) ->
                                 sets:to_list(Set) ++ Acc
                         end, [], ReverseBindingsMap),
    group_bindings_fold(fun maybe_auto_delete_in_khepri/4, new_deletions(),
                        lists:keysort(#binding.source, Bindings), false).

remove_for_destination_in_khepri(DstName, OnlyDurable) ->
    BindingsMap =
        case OnlyDurable of
            false ->
                ReverseBindingsMap = match_destination_in_khepri(DstName, reverse_routes),
                remove_in_khepri(ReverseBindingsMap),
                remove_in_khepri(ReverseBindingsMap, routes),
                remove_in_khepri(ReverseBindingsMap, durable_routes),
                remove_in_khepri(ReverseBindingsMap, semi_durable_routes),
                ReverseBindingsMap;
            true  ->
                DurableBindingsMap = match_destination_in_khepri(DstName, durable_routes),
                SemiDurableBindingsMap = match_destination_in_khepri(DstName, semi_durable_routes),
                BindingsMap0 = maps:merge(DurableBindingsMap, SemiDurableBindingsMap),
                remove_in_khepri(DurableBindingsMap),
                remove_in_khepri(SemiDurableBindingsMap),
                remove_in_khepri(BindingsMap0, routes),
                remove_in_khepri(BindingsMap0, reverse_routes),
                BindingsMap0
        end,
    Bindings = maps:fold(fun(_, Set, Acc) ->
                                 sets:to_list(Set) ++ Acc
                         end, [], BindingsMap),
    group_bindings_fold(fun maybe_auto_delete_in_khepri/4, new_deletions(),
                        lists:keysort(#binding.source, Bindings), OnlyDurable).

%% Instead of locking entire table on remove operations we can lock the
%% affected resource only.
lock_resource(Name) -> lock_resource(Name, write).

lock_resource(Name, LockKind) ->
    mnesia:lock({global, Name, mnesia:table_info(rabbit_route, where_to_write)},
                LockKind).

%% Requires that its input binding list is sorted in exchange-name
%% order, so that the grouping of bindings (for passing to
%% group_bindings_and_auto_delete1) works properly.
group_bindings_fold(_Fun, Acc, [], _OnlyDurable) ->
    Acc;
group_bindings_fold(Fun, Acc, [B = #binding{source = SrcName} | Bs],
                    OnlyDurable) ->
    group_bindings_fold(Fun, SrcName, Acc, Bs, [B], OnlyDurable).

group_bindings_fold(
  Fun, SrcName, Acc, [B = #binding{source = SrcName} | Bs], Bindings,
  OnlyDurable) ->
    group_bindings_fold(Fun, SrcName, Acc, Bs, [B | Bindings], OnlyDurable);
group_bindings_fold(Fun, SrcName, Acc, Removed, Bindings, OnlyDurable) ->
    %% Either Removed is [], or its head has a non-matching SrcName.
    group_bindings_fold(Fun, Fun(SrcName, Bindings, Acc, OnlyDurable), Removed,
                        OnlyDurable).

maybe_auto_delete_in_mnesia(XName, Bindings, Deletions, OnlyDurable) ->
    {Entry, Deletions1} =
        case mnesia:read({case OnlyDurable of
                              true  -> rabbit_durable_exchange;
                              false -> rabbit_exchange
                          end, XName}) of
            []  -> {{undefined, not_deleted, Bindings}, Deletions};
            [X] -> case rabbit_exchange:maybe_auto_delete_in_mnesia(X, OnlyDurable) of
                       not_deleted ->
                           {{X, not_deleted, Bindings}, Deletions};
                       {deleted, Deletions2} ->
                           {{X, deleted, Bindings},
                            combine_deletions(Deletions, Deletions2)}
                   end
        end,
    add_deletion(XName, Entry, Deletions1).

maybe_auto_delete_in_khepri(XName, Bindings, Deletions, OnlyDurable) ->
    {Entry, Deletions1} =
        case rabbit_exchange:lookup_in_khepri(case OnlyDurable of
                                                  true  -> rabbit_durable_exchange;
                                                  false -> rabbit_exchange
                                              end, XName) of
            {error, not_found}  -> {{undefined, not_deleted, Bindings}, Deletions};
            {ok, X} -> case rabbit_exchange:maybe_auto_delete_in_khepri(X, OnlyDurable) of
                           not_deleted ->
                               {{X, not_deleted, Bindings}, Deletions};
                           {deleted, Deletions2} ->
                               {{X, deleted, Bindings},
                                combine_deletions(Deletions, Deletions2)}
                       end
        end,
    add_deletion(XName, Entry, Deletions1).

reverse_route(#route{binding = Binding}) ->
    #reverse_route{reverse_binding = reverse_binding(Binding)};

reverse_route(#reverse_route{reverse_binding = Binding}) ->
    #route{binding = reverse_binding(Binding)}.

reverse_binding(#reverse_binding{source      = SrcName,
                                 destination = DstName,
                                 key         = Key,
                                 args        = Args}) ->
    #binding{source      = SrcName,
             destination = DstName,
             key         = Key,
             args        = Args};

reverse_binding(#binding{source      = SrcName,
                         destination = DstName,
                         key         = Key,
                         args        = Args}) ->
    #reverse_binding{source      = SrcName,
                     destination = DstName,
                     key         = Key,
                     args        = Args}.

reverse_set_of_bindings(Set) ->
    sets:fold(fun(B, Set0) ->
                      sets:add_element(reverse_binding(B), Set0)
              end, sets:new(), Set).

%% ----------------------------------------------------------------------------
%% Binding / exchange deletion abstraction API
%% ----------------------------------------------------------------------------

anything_but( NotThis, NotThis, NotThis) -> NotThis;
anything_but( NotThis, NotThis,    This) -> This;
anything_but( NotThis,    This, NotThis) -> This;
anything_but(_NotThis,    This,    This) -> This.

-spec new_deletions() -> deletions().

new_deletions() -> dict:new().

-spec add_deletion
        (rabbit_exchange:name(),
         {'undefined' | rabbit_types:exchange(),
          'deleted' | 'not_deleted',
          bindings()},
         deletions()) ->
            deletions().

add_deletion(XName, Entry, Deletions) ->
    dict:update(XName, fun (Entry1) -> merge_entry(Entry1, Entry) end,
                Entry, Deletions).

-spec combine_deletions(deletions(), deletions()) -> deletions().

combine_deletions(Deletions1, Deletions2) ->
    dict:merge(fun (_XName, Entry1, Entry2) -> merge_entry(Entry1, Entry2) end,
               Deletions1, Deletions2).

merge_entry({X1, Deleted1, Bindings1}, {X2, Deleted2, Bindings2}) ->
    {anything_but(undefined, X1, X2),
     anything_but(not_deleted, Deleted1, Deleted2),
     [Bindings1 | Bindings2]}.

-spec process_deletions(deletions(), rabbit_types:username()) -> rabbit_misc:thunk('ok').

process_deletions(Deletions, ActingUser) ->
    AugmentedDeletions =
        dict:map(fun (_XName, {X, deleted, Bindings}) ->
                         Bs = lists:flatten(Bindings),
                         x_callback(transaction, X, delete, Bs),
                         {X, deleted, Bs, none};
                     (_XName, {X, not_deleted, Bindings}) ->
                         Bs = lists:flatten(Bindings),
                         x_callback(transaction, X, remove_bindings, Bs),
                         {X, not_deleted, Bs, rabbit_exchange:serial_in_mnesia(X)}
                 end, Deletions),
    fun() ->
            dict:fold(fun (XName, {X, deleted, Bs, Serial}, ok) ->
                              ok = rabbit_event:notify(
                                     exchange_deleted,
                                     [{name, XName},
                                      {user_who_performed_action, ActingUser}]),
                              del_notify(Bs, ActingUser),
                              x_callback(Serial, X, delete, Bs);
                          (_XName, {X, not_deleted, Bs, Serial}, ok) ->
                              del_notify(Bs, ActingUser),
                              x_callback(Serial, X, remove_bindings, Bs)
                      end, ok, AugmentedDeletions)
    end.

process_deletions_in_khepri(Deletions, ActingUser) ->
    %% TODO store notifications as triggers for deletion of the path
    AugmentedDeletions =
        dict:map(fun (_XName, {X, deleted, Bindings}) ->
                         Bs = lists:flatten(Bindings),
                         x_callback(transaction, X, delete, Bs),
                         {X, deleted, Bs, none};
                     (_XName, {X, not_deleted, Bindings}) ->
                         Bs = lists:flatten(Bindings),
                         x_callback(transaction, X, remove_bindings, Bs),
                         {X, not_deleted, Bs, rabbit_exchange:serial_in_khepri(X)}
                 end, Deletions),
    dict:fold(fun (XName, {X, deleted, Bs, Serial}, ok) ->
                      ok = rabbit_event:notify(
                             exchange_deleted,
                             [{name, XName},
                              {user_who_performed_action, ActingUser}]),
                      del_notify(Bs, ActingUser),
                      x_callback(Serial, X, delete, Bs);
                  (_XName, {X, not_deleted, Bs, Serial}, ok) ->
                      del_notify(Bs, ActingUser),
                      x_callback(Serial, X, remove_bindings, Bs)
              end, ok, AugmentedDeletions).

del_notify(Bs, ActingUser) -> [rabbit_event:notify(
                               binding_deleted,
                               info(B) ++ [{user_who_performed_action, ActingUser}])
                             || B <- Bs].

x_callback(Serial, X, F, Bs) ->
    ok = rabbit_exchange:callback(X, F, Serial, [X, Bs]).

khepri_route_path(#binding{source = #resource{virtual_host = VHost, name = SrcName},
                           destination = #resource{kind = Kind, name = DstName},
                           key = RoutingKey}) ->
    [?MODULE, routes, VHost, SrcName, Kind, DstName, RoutingKey].

khepri_durable_route_path(#binding{source = #resource{virtual_host = VHost, name = SrcName},
                                   destination = #resource{kind = Kind, name = DstName},
                                   key = RoutingKey}) ->
    [?MODULE, durable_routes, VHost, SrcName, Kind, DstName, RoutingKey].

khepri_semi_durable_route_path(#binding{source = #resource{virtual_host = VHost, name = SrcName},
                                        destination = #resource{kind = Kind, name = DstName},
                                        key = RoutingKey}) ->
    [?MODULE, semi_durable_routes, VHost, SrcName, Kind, DstName, RoutingKey].

khepri_reverse_route_path(#reverse_binding{source = #resource{virtual_host = VHost, name = SrcName},
                                           destination = #resource{kind = Kind, name = DstName},
                                           key = RoutingKey}) ->
    [?MODULE, reverse_routes, VHost, SrcName, Kind, DstName, RoutingKey].

khepri_routes_path() ->
    [?MODULE, routes].

khepri_durable_routes_path() ->
    [?MODULE, durable_routes].

khepri_semi_durable_routes_path() ->
    [?MODULE, semi_durable_routes].

khepri_reverse_routes_path() ->
    [?MODULE, reverse_routes].

destination_from_khepri_path([?MODULE, _Type, VHost, _Src, Kind, Dst | _]) ->
    #resource{virtual_host = VHost, kind = Kind, name = Dst}.

source_from_khepri_path([?MODULE, _Type, VHost, Src | _]) ->
    #resource{virtual_host = VHost, kind = exchange, name = Src}.

update_khepri_path_to([?MODULE, _Type | Rest], RouteType) ->
    [?MODULE, RouteType] ++ Rest.

match_source_in_khepri(#resource{virtual_host = VHost, name = Name}, routes) ->
    Path = khepri_routes_path() ++ [VHost, Name, ?STAR_STAR],
    match_in_khepri(Path);
match_source_in_khepri(#resource{virtual_host = VHost, name = Name}, durable_routes) ->
    Path = khepri_durable_routes_path() ++ [VHost, Name, ?STAR_STAR],
    match_in_khepri(Path);
match_source_in_khepri(#resource{virtual_host = VHost, name = Name}, semi_durable_routes) ->
    Path = khepri_semi_durable_routes_path() ++ [VHost, Name, ?STAR_STAR],
    match_in_khepri(Path);
match_source_in_khepri(#resource{virtual_host = VHost, name = Name}, reverse_routes) ->
    Path = khepri_reverse_routes_path() ++ [VHost, Name, ?STAR_STAR],
    match_in_khepri(Path).

match_destination_in_khepri(#resource{virtual_host = VHost, kind = Kind, name = Name}, routes) ->
    Path = khepri_routes_path() ++ [VHost, ?STAR, Kind, Name, ?STAR_STAR],
    match_in_khepri(Path);
match_destination_in_khepri(#resource{virtual_host = VHost, kind = Kind, name = Name},
                            durable_routes) ->
    Path = khepri_durable_routes_path() ++ [VHost, ?STAR, Kind, Name, ?STAR_STAR],
    match_in_khepri(Path);
match_destination_in_khepri(#resource{virtual_host = VHost, kind = Kind, name = Name},
                            semi_durable_routes) ->
    Path = khepri_semi_durable_routes_path() ++ [VHost, ?STAR, Kind, Name, ?STAR_STAR],
    match_in_khepri(Path);
match_destination_in_khepri(#resource{virtual_host = VHost, kind = Kind, name = Name},
                            reverse_routes) ->
    Path = khepri_reverse_routes_path() ++ [VHost, ?STAR, Kind, Name, ?STAR_STAR],
    match_in_khepri(Path).

match_in_khepri(Path) ->
    {ok, Map} = rabbit_khepri:tx_match_and_get_data(Path),
    Map.
