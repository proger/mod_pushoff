%%%----------------------------------------------------------------------
%%% File    : mod_push.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : implements XEP-0357 Push and an IM-focussed app server
%%%           
%%% Created : 22 Dec 2014 by Christian Ulrich <christian@rechenwerk.net>
%%%
%%%
%%% Copyright (C) 2015  Christian Ulrich
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_push).

-author('christian@rechenwerk.net').

-behaviour(gen_mod).

-export([start/2, stop/1, depends/2,
         mod_opt_type/1,
         get_backend_opts/1,
         on_offline_message/3,
         on_remove_user/2,
         process_adhoc_command/4,
         unregister_client/1,
         check_secret/2]).

-include("logger.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").

-define(MODULE_APNS, mod_push_apns).

-define(NS_PUSH, <<"urn:xmpp:push:0">>).

-define(INCLUDE_SENDERS_DEFAULT, false).
-define(INCLUDE_MSG_COUNT_DEFAULT, true).
-define(INCLUDE_SUBSCR_COUNT_DEFAULT, true).
-define(INCLUDE_MSG_BODIES_DEFAULT, false).
-define(SILENT_PUSH_DEFAULT, true).

-define(OFFLINE_HOOK_PRIO, 1). % must fire before mod_offline (which has 50)

-define(MAX_INT, 4294967295).
-define(ADJUSTED_RESUME_TIMEOUT, 100*24*60*60).

%-------------------------------------------------------------------------
% xdata-form macros
%-------------------------------------------------------------------------

-define(VVALUE(Val),
(
    #xmlel{
        name     = <<"value">>,
        children = [{xmlcdata, Val}]
    }
)).

-define(VFIELD(Var, Val),
(
    #xmlel{
        name = <<"field">>,
        attrs = [{<<"var">>, Var}],
        children = vvaluel(Val)
    }
)).

-define(TVFIELD(Type, Var, Vals),
(
    #xmlel{
        name     = <<"field">>,
        attrs    = [{<<"type">>, Type}, {<<"var">>, Var}],
        children =
        lists:foldl(fun(Val, FieldAcc) -> vvaluel(Val) ++ FieldAcc end,
                    [], Vals)
    }
)).

-define(HFIELD(Val), ?TVFIELD(<<"hidden">>, <<"FORM_TYPE">>, [Val])).

-define(ITEM(Fields),
(
    #xmlel{name = <<"item">>,
           children = Fields}
)).

%-------------------------------------------------------------------------

-record(auth_data,
        {auth_key = <<"">> :: binary(),
         package_sid = <<"">> :: binary(),
         certfile = <<"">> :: binary()}).

-record(subscription, {resource :: binary(),
                       pending = false :: boolean(),
                       node :: binary(),
                       reg_type :: reg_type()}).

%% mnesia table
-record(push_user, {bare_jid :: bare_jid(),
                    subscriptions :: [subscription()],
                    config :: user_config(),
                    payload = [] :: payload()}).

%% mnesia table
-record(push_registration, {node :: binary(),
                            bare_jid :: bare_jid(),
                            device_id :: binary(),
                            device_name :: binary(),
                            token :: binary(),
                            secret :: binary(),
                            app_id :: binary(),
                            backend_id :: integer(),
                            timestamp = now() :: erlang:timestamp()}).

%% mnesia table
-record(push_backend,
        {id :: integer(),
         register_host :: binary(),
         pubsub_host :: binary(),
         type :: backend_type(),
         app_name :: binary(),
         cluster_nodes = [] :: [atom()],
         worker :: binary()}).

%% mnesia table
-record(push_stored_packet, {receiver :: ljid(),
                             sender :: jid(),
                             timestamp = now() :: erlang:timestamp(),
                             packet :: xmlelement()}).

-type auth_data() :: #auth_data{}.
-type backend_type() :: apns.
-type bare_jid() :: {binary(), binary()}.
-type payload_key() ::
    'last-message-sender' | 'last-subscription-sender' | 'message-count' |
    'pending-subscription-count' | 'last-message-body'.
-type payload_value() :: binary() | integer().
-type payload() :: [{payload_key(), payload_value()}].
-type push_backend() :: #push_backend{}.
-type push_registration() :: #push_registration{}.
-type reg_type() :: {local_reg, binary(), binary()} | % pubsub host, secret
                    {remote_reg, jid(), binary()}.  % pubsub host, secret
-type subscription() :: #subscription{}.
-type user_config_option() ::
    'include-senders' | 'include-message-count' | 'include-subscription-count' |
    'include-message-bodies'.
-type user_config() :: [user_config_option()].

%-------------------------------------------------------------------------

-spec(register_client
(
    User :: jid(),
    RegisterHost :: binary(),
    Type :: backend_type(),
    Token :: binary(),
    DeviceId :: binary(),
    DeviceName :: binary(),
    AppId :: binary())
    -> {registered,
        PubsubHost :: binary(),
        Node :: binary(),
        Secret :: binary()}
).

register_client(#jid{lresource = <<"">>}, _, _, _, <<"">>, _, _) ->
    error;

register_client(#jid{lresource = <<"">>}, _, _, _, undefined, _, _) ->
    error;

register_client(#jid{luser = LUser,
                     lserver = LServer,
                     lresource = LResource},
                RegisterHost, Type, Token, DeviceId, DeviceName, AppId) ->
    F = fun() ->
        MatchHeadBackend =
        #push_backend{register_host = RegisterHost, type = Type, _='_'},
        MatchingBackends =
        mnesia:select(push_backend, [{MatchHeadBackend, [], ['$_']}]),
        case MatchingBackends of
            [#push_backend{id = BackendId, pubsub_host = PubsubHost}|_] ->
                ?DEBUG("+++++ register_client: found backend", []),
                ChosenDeviceId = case DeviceId of
                    undefined -> LResource;
                    <<"">> -> LResource;
                    _ -> DeviceId
                end,
                Secret = randoms:get_string(),
                MatchHeadReg =
                #push_registration{bare_jid = {LUser, LServer},
                                   device_id = ChosenDeviceId, _='_'},
                ExistingReg =
                mnesia:select(push_registration, [{MatchHeadReg, [], ['$_']}]),
                Registration =
                case ExistingReg of
                    [] ->
                        NewNode = randoms:get_string(),
                        #push_registration{node = NewNode,
                                           bare_jid = {LUser, LServer},
                                           device_id = ChosenDeviceId,
                                           device_name = DeviceName,
                                           token = Token,
                                           secret = Secret,
                                           app_id = AppId,
                                           backend_id = BackendId};

                    [OldReg] ->
                        OldReg#push_registration{device_name = DeviceName,
                                                 token = Token,
                                                 secret = Secret,
                                                 app_id = AppId,
                                                 backend_id = BackendId,
                                                 timestamp = now()}
                end,
                mnesia:write(Registration),
                {PubsubHost, Registration#push_registration.node,
                 Registration#push_registration.secret};
            
            _ ->
                ?DEBUG("+++++ register_client: found no backend", []),
                error
        end
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> {error, ?ERR_ITEM_NOT_FOUND};
        {atomic, Result} -> {registered, Result}
    end. 

%-------------------------------------------------------------------------

%% Callback for workers

-spec(unregister_client
(
    Args :: {binary(), erlang:timestamp()})
    -> error | {error, xmlelement()} | {unregistered, ok} |
       {unregistered, [binary()]}
).

unregister_client({Node, Timestamp}) ->
    unregister_client(undefined, undefined, Timestamp, [Node]). 

%-------------------------------------------------------------------------

%% Either device ID or a list of node IDs must be given. If none of these are in
%% the payload, the resource of the from jid will be interpreted as device ID.
%% If both device ID and node list are given, the device_id will be ignored and
%% only registrations matching a node ID in the given list will be removed.

-spec(unregister_client
(
    Jid :: jid(),
    DeviceId :: binary(),
    NodeIds :: [binary()])
    -> error | {error, xmlelement()} | {unregistered, ok} |
       {unregistered, [binary()]}
).

unregister_client(Jid, DeviceId, NodeIds) ->
    unregister_client(Jid, DeviceId, '_', NodeIds).

%-------------------------------------------------------------------------

-spec(unregister_client
(
    UserJid :: jid(),
    DeviceId :: binary(),
    Timestamp :: erlang:timestamp(),
    Nodes :: [binary()])
    -> error | {error, xmlelement()} | {unregistered, ok} |
       {unregistered, [binary()]}
).

unregister_client(#jid{lresource = <<"">>}, undefined, _, []) -> error;
unregister_client(#jid{lresource = <<"">>}, <<"">>, _, []) -> error;
unregister_client(undefined, undefined, _, []) -> error;
unregister_client(undefined, <<"">>, _, []) -> error;

unregister_client(UserJid, DeviceId, Timestamp, Nodes) ->
    F = fun() ->
        case Nodes of
            [] ->
                #jid{luser = LUser, lserver= LServer, lresource = LResource} =
                UserJid,
                ChosenDeviceId = case DeviceId of
                    undefined -> LResource;
                    <<"">> -> LResource;
                    _ -> DeviceId
                end,
                MatchHead =
                #push_registration{bare_jid = {LUser, LServer},
                                   device_id = ChosenDeviceId,
                                   timestamp = Timestamp,
                                   _='_'},
                MatchingReg =
                mnesia:select(push_registration, [{MatchHead, [], ['$_']}]),
                case MatchingReg of
                    [] -> error;

                    [Reg] ->
                        ?DEBUG("+++++ deleting registration of user ~p whith node "
                               "~p",
                               [Reg#push_registration.bare_jid,
                                Reg#push_registration.node]),
                        mnesia:delete_object(Reg),
                        ok
                end;

            GivenNodes ->
                UnregisteredNodes =
                lists:foldl(
                    fun(Node, Acc) ->
                        RegResult = mnesia:read({push_registration, Node}),
                        case RegResult of
                            [] -> Acc;
                            [Reg] ->
                                UserOk =
                                case UserJid of
                                    #jid{luser = LUser, lserver = LServer} ->
                                        BareJid = 
                                        Reg#push_registration.bare_jid,
                                        BareJid =:= {LUser, LServer};
                                    undefined -> true
                                end,
                                case UserOk of
                                    true ->
                                        mnesia:delete_object(Reg),
                                        [Node|Acc];
                                    false -> [error|Acc]
                                end
                        end
                    end,
                    [],
                    GivenNodes),
                case [El || El <- UnregisteredNodes, El =:= error] of
                    [] -> UnregisteredNodes;
                    _ -> error
                end
        end
    end,
    case mnesia:transaction(F) of
        {aborted, Reason} ->
            ?DEBUG("+++++ unregister_client error: ~p", [Reason]),
            {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> error;
        {atomic, Result} -> {unregistered, Result}
    end.
                                         
%-------------------------------------------------------------------------

do_enable(#jid{luser = LUser, lserver = LServer, lresource = LResource},
          #jid{lserver = PubsubHost} = PubsubJid, Node, XDataForms, Secret) ->
    F = fun() ->
                MatchHeadBackend =
                    #push_backend{id = '$1', pubsub_host = PubsubHost, _='_'},
                RegType =
                    case mnesia:select(push_backend, [{MatchHeadBackend, [], ['$1']}]) of
                        [] -> {remote_reg, PubsubJid, Secret};
                        _ -> {local_reg, PubsubHost, Secret}
                    end,
                Subscr =
                    #subscription{resource = LResource,
                                  node = Node,
                                  reg_type = RegType},
                case mnesia:read({push_user, {LUser, LServer}}) of
                    [] ->
                        ?DEBUG("+++++ enable: no user found!", []),
                        %% NewUser will have empty payload
                        NewUser =
                            #push_user{bare_jid = {LUser, LServer},
                                       subscriptions = [Subscr],
                                       config = []},
                        mnesia:write(NewUser);

                    [#push_user{subscriptions = Subscriptions}] ->
                        ?DEBUG("+++++ enable: found user", []),
                        FilterNode =
                            fun
                                (S) when S#subscription.node =:= Node;
                                         S#subscription.resource =:= LResource ->
                                    false;
                                (_) -> true
                            end,
                        NewSubscriptions =
                            [Subscr|lists:filter(FilterNode, Subscriptions)],
                        %% NewUser will have empty payload
                        NewUser =
                            #push_user{bare_jid = {LUser, LServer},
                                       subscriptions = NewSubscriptions,
                                       config = []},
                        mnesia:write(NewUser)
                end
        end,
    case mnesia:transaction(F) of
        {aborted, Reason} ->
            ?DEBUG("+++++ enable transaction aborted: ~p", [Reason]),
            {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> {error, ?ERR_NOT_ACCEPTABLE};
        {atomic, []} -> {enabled, ok};
        {atomic, ResponseForm} -> {enabled, ResponseForm}
    end.

%-------------------------------------------------------------------------

-spec(list_registrations
(jid()) -> {error, xmlelement()} | {registrations, [push_registration()]}).

list_registrations(#jid{luser = LUser, lserver = LServer}) ->
    F = fun() ->
        MatchHead = #push_registration{bare_jid = {LUser, LServer}, _='_'},
        mnesia:select(push_registration, [{MatchHead, [], ['$_']}])
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, RegList} -> {registrations, RegList}
    end.

%-------------------------------------------------------------------------

-spec(on_offline_message(From :: jid(), To :: jid(), Stanza :: xmlelement()) -> any()).

on_offline_message(_From, To, Stanza) ->
    F = fun() -> dispatch([{now(), Stanza}], To, false) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {atomic, not_subscribed} ->
            ?DEBUG("+++++ mod_push offline: ~p is not_subscribed", [To]),
            ok;
        {aborted, Error} ->
            ?DEBUG("+++++ error in on_offline_message: ~p", [Error]),
            ok
    end.

%-------------------------------------------------------------------------

-spec(dispatch
(
    Stanzas :: [{erlang:timestamp(), xmlelement(), boolean()}],
    UserJid :: jid(),
    SetPending :: boolean())
    -> ok | not_subscribed
).

dispatch(_, _, _SetPending = true) ->
    throw(i_am_supposed_to_remove_setpending);
dispatch(Stanzas, UserJid, _SetPending = false) ->
    #jid{luser = LUser, lserver = LServer, lresource = LResource} = UserJid,
    case mnesia:read({push_user, {LUser, LServer}}) of
        [] -> not_subscribed;
        [PushUser] ->
            ?DEBUG("+++++ dispatch: found push_user", []),
            #push_user{subscriptions = Subscrs, config = Config,
                       payload = OldPayload} = PushUser,
            NewSubscrs = Subscrs,
            ?DEBUG("+++++ NewSubscrs = ~p", [NewSubscrs]),
            MatchingSubscr =
            [M || #subscription{pending = P, resource = R} = M <- NewSubscrs,
                  P =:= true, R =:= LResource],
            case MatchingSubscr of
                [] -> not_subscribed;
                [#subscription{reg_type = RegType, node = NodeId}] ->
                    ?DEBUG("+++++ dispatch: found subscription", []),
                    WriteUser =
                    fun(Payload) ->
                        NewUser =
                        PushUser#push_user{subscriptions = NewSubscrs,
                                           payload = Payload},
                        mnesia:write(NewUser)
                    end,
                    case make_payload(Stanzas, OldPayload, Config) of
                        none -> WriteUser(OldPayload);

                        {Payload, StanzasToStore} ->
                            Receiver = jlib:jid_tolower(UserJid),
                            lists:foreach(
                                fun({Timestamp, Stanza}) ->
                                    StoredPacket =
                                    #push_stored_packet{receiver = Receiver,
                                                        timestamp = Timestamp,
                                                        packet = Stanza},
                                    mnesia:write(StoredPacket)
                                end,
                                StanzasToStore),
                            WriteUser(Payload),
                            do_dispatch(RegType, {LUser, LServer}, NodeId, Payload)
                    end
            end
    end.
                                            
%-------------------------------------------------------------------------

-spec(do_dispatch
(
    RegType :: reg_type(),
    UserBare :: bare_jid(),
    NodeId :: binary(),
    Payload :: payload())
    -> dispatched | ok
).

do_dispatch({local_reg, _, Secret}, UserBare, NodeId, Payload) ->
    SelectedReg = mnesia:read({push_registration, NodeId}),
    case SelectedReg of
        [] ->
            ?INFO_MSG("push event for local user ~p, but user is not registered"
                      " at local app server", [UserBare]);
       
        [#push_registration{node = Node,
                            bare_jid = StoredUserBare,
                            token = Token,
                            secret = StoredSecret,
                            app_id = AppId,
                            backend_id = BackendId,
                            timestamp = Timestamp}] ->
            case {UserBare, Secret} of
                {StoredUserBare, StoredSecret} ->
                    
                    ?DEBUG("+++++ do_dispatch: found registration, dispatch locally",
                           []),
                    do_dispatch_local(UserBare, Payload, Token, AppId,
                                      BackendId, Node, Timestamp, true);

                {StoredUserBare, _} -> 
                    ?INFO_MSG("push event for local user ~p, but secret does "
                              "not match", [UserBare]);

                _ ->
                    ?INFO_MSG("push event for local user ~p, but the "
                              "user-provided node belongs to another user",
                              [UserBare]) 
            end
    end.

%-------------------------------------------------------------------------

-spec(do_dispatch_local
(
    UserBare :: bare_jid(),
    Payload :: payload(),
    Token :: binary(),
    AppId :: binary(),
    BackendId :: integer(),
    Node :: binary(),
    Timestamp :: erlang:timestamp(),
    AllowRelay :: boolean())
    -> ok
).

do_dispatch_local(UserBare, Payload, Token, AppId, BackendId, Node, Timestamp,
                  AllowRelay) ->
    DisableArgs = {Node, Timestamp},
    [#push_backend{worker = Worker, cluster_nodes = ClusterNodes}] =
    mnesia:read({push_backend, BackendId}),
    case lists:member(node(), ClusterNodes) of
        true ->
            ?DEBUG("+++++ dispatch_local: calling worker", []),
            gen_server:cast(Worker,
                            {dispatch, UserBare, Payload, Token, AppId,
                             DisableArgs});

        false ->
            case AllowRelay of
                false ->
                    ?DEBUG("+++++ Worker ~p is not running, cancel dispatching "
                           "push notification", [Worker]);
                true ->
                    Index = random:uniform(length(ClusterNodes)),
                    ChosenNode = lists:nth(Index, ClusterNodes),
                    ?DEBUG("+++++ Relaying push notification to node ~p",
                           [ChosenNode]),
                    gen_server:cast(
                        {Worker, ChosenNode},
                        {dispatch,
                         UserBare, Payload, Token, AppId, DisableArgs})
            end
    end.
           
%-------------------------------------------------------------------------

-spec(on_remove_user (User :: binary(), Server :: binary()) -> ok).

on_remove_user(User, Server) ->
    F = fun() ->
        case mnesia:read({push_user, {User, Server}}) of
            [] -> ok;
            [#push_user{subscriptions = Subscriptions}] ->
                lists:foreach(
                    fun(#subscription{resource = R}) ->
                        mnesia:delete({push_stored_packet, {User, Server, R}})
                    end,
                    Subscriptions),
                mnesia:delete({push_user, {User, Server}})
        end
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

-spec(check_secret
(
    Secret :: binary(),
    Opts :: [any()])
    -> boolean()
).

check_secret(Secret, PubOpts) ->
    case proplists:get_value(<<"secret">>, PubOpts) of
        [Secret] -> true;
        _ -> false
    end.

%-------------------------------------------------------------------------

-spec(add_backends
(
    Host :: binary())
    -> ok | error
).

add_backends(Host) ->
    CertFile =
    gen_mod:get_module_opt(Host, ?MODULE, certfile,
                           fun(C) when is_binary(C) -> C end,
                           <<"">>),
    BackendOpts =
    gen_mod:get_module_opt(Host, ?MODULE, backends,
                           fun(O) when is_list(O) -> O end,
                           []),
    Backends = parse_backends(BackendOpts, CertFile),
    lists:foreach(
        fun({Backend, AuthData}) ->
            RegisterHost = Backend#push_backend.register_host,
            ejabberd_router:register_route(RegisterHost),
            ejabberd_hooks:add(adhoc_local_commands, RegisterHost, ?MODULE, process_adhoc_command, 75),
            ?INFO_MSG("added adhoc command handler for app server ~p",
                      [RegisterHost]),
            NewBackend =
            case mnesia:read({push_backend, Backend#push_backend.id}) of
                [] -> Backend;
                [#push_backend{cluster_nodes = Nodes}] ->
                    NewNodes =
                    lists:merge(Nodes, Backend#push_backend.cluster_nodes),
                    Backend#push_backend{cluster_nodes = NewNodes}
            end,
            mnesia:write(NewBackend),
            start_worker(Backend, AuthData)
        end,
      Backends),
    Backends.
    

%-------------------------------------------------------------------------

-spec(start_worker
(
    Backend :: push_backend(),
    AuthData :: auth_data())
    -> ok
).

start_worker(#push_backend{worker = Worker, type = Type},
             #auth_data{auth_key = AuthKey,
                        package_sid = PackageSid,
                        certfile = CertFile}) ->
    Module =
    proplists:get_value(Type,
                        [{apns, ?MODULE_APNS}]),
    BackendSpec =
    {Worker,
     {gen_server, start_link,
      [{local, Worker}, Module,
       [AuthKey, PackageSid, CertFile], []]},
     permanent, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, BackendSpec).

%-------------------------------------------------------------------------

-spec(notify_previous_users (Host :: binary()) -> ok).

notify_previous_users(Host) ->
    MatchHead = #push_user{bare_jid = {'_', Host}, _='_'},
    Users = mnesia:select(push_user, [{MatchHead, [], ['$_']}]),
    lists:foreach(
        fun(#push_user{bare_jid = BareJid,
                       subscriptions = Subscrs,
                       config = Config,
                       payload = Payload}) ->
            lists:foreach(
                fun
                    (#subscription{pending = true,
                                   node = Node,
                                   reg_type = RegType}) ->
                        FilteredPayload = filter_payload(Payload, Config),
                        do_dispatch(RegType, BareJid, Node, FilteredPayload);

                    (_) -> ok
                end,
                Subscrs)
        end,
        Users),
    lists:foreach(fun mnesia:delete_object/1, Users).

%-------------------------------------------------------------------------

-spec(process_adhoc_command
(
    Acc :: any(),
    From :: jid(),
    To :: jid(),
    Request :: adhoc_request())
    -> any()
).

process_adhoc_command(Acc, From, #jid{lserver = LServer},
                      #adhoc_request{node = Command,
                                     action = <<"execute">>,
                                     xdata = XData} = Request) ->
    Action = case Command of
        <<"register-push-apns">> ->
            fun() ->
                Parsed = parse_form([XData],
                                    undefined,
                                    [{single, <<"token">>}],
                                    [{single, <<"device-id">>},
                                     {single, <<"device-name">>}]),
                case Parsed of
                    {result, [Base64Token, DeviceId, DeviceName]} ->
                        case catch base64:decode(Base64Token) of
                            {'EXIT', _} ->
                                error;

                            Token ->
                                register_client(From, LServer, apns, Token,
                                                DeviceId, DeviceName, <<"">>)
                        end;

                    _ -> error
                end
            end;

        <<"unregister-push">> ->
            fun() ->
                Parsed = parse_form([XData], undefined,
                                    [], [{single, <<"device-id">>},
                                         {multi, <<"nodes">>}]),
                case Parsed of
                    {result, [DeviceId, NodeIds]} -> 
                        unregister_client(From, DeviceId, NodeIds);

                    not_found ->
                        unregister_client(From, undefined, []);

                    _ -> error
                end
            end;

        <<"list-push-registrations">> -> fun() -> list_registrations(From) end;

        _ -> unknown
    end,
    Result = case Action of
        unknown -> unknown;
        _ ->
            Host = remove_subdomain(LServer),
            Access =
            gen_mod:get_module_opt(Host,
                                   ?MODULE,
                                   access_backends,
                                   fun(A) when is_atom(A) -> A end,
                                   all),
            case acl:match_rule(Host, Access, From) of
                deny -> {error, ?ERR_FORBIDDEN};
                allow -> Action()
            end
    end,
    case Result of
        unknown -> Acc;

        {registered, {PubsubHost, Node, Secret}} ->
            JidField = [?VFIELD(<<"jid">>, PubsubHost)],
            NodeField = case Node of
                <<"">> -> [];
                _ -> [?VFIELD(<<"node">>, Node)]
            end,
            SecretField = [?VFIELD(<<"secret">>, Secret)],
            Response =
            #adhoc_response{
                status = completed,
                elements = [#xmlel{name = <<"x">>,
                                   attrs = [{<<"xmlns">>, ?NS_XDATA},
                                            {<<"type">>, <<"result">>}],
                                   children =
                                   JidField ++ NodeField ++ SecretField}]},
            adhoc:produce_response(Request, Response);

        {unregistered, ok} ->
            Response =
            #adhoc_response{status = completed, elements = []},
            adhoc:produce_response(Request, Response);

        {unregistered, UnregisteredNodeIds} ->
            Field =
            ?TVFIELD(<<"list-multi">>, <<"nodes">>, UnregisteredNodeIds),
            Response =
            #adhoc_response{
                status = completed,
                elements = [#xmlel{name = <<"x">>,
                                    attrs = [{<<"xmlns">>, ?NS_XDATA},
                                             {<<"type">>, <<"result">>}],
                                    children = [Field]}]},
            adhoc:produce_response(Request, Response);

        {registrations, []} ->
            adhoc:produce_response(
                Request,
                #adhoc_response{status = completed, elements = []});

        {registrations, RegList} ->
            Items =
            lists:foldl(
                fun(Reg, ItemsAcc) ->
                    NameField = case Reg#push_registration.device_name of
                        undefined -> [];
                        Name -> [?VFIELD(<<"device-name">>, Name)]
                    end,
                    NodeField =
                    [?VFIELD(<<"node">>, Reg#push_registration.node)],
                    [?ITEM(NameField ++ NodeField) | ItemsAcc]
                end,
                [],
                RegList),
            Response =
            #adhoc_response{
                status = completed,
                elements = [#xmlel{name = <<"x">>,
                                   attrs = [{<<"xmlns">>, ?NS_XDATA},
                                            {<<"type">>, <<"result">>}],
                                   children = Items}]},
            adhoc:produce_response(Request, Response);

        error -> {error, ?ERR_BAD_REQUEST};

        {error, Error} -> {error, Error}
    end;

process_adhoc_command(Acc, _From, _To, _Request) ->
    Acc.
     
%-------------------------------------------------------------------------
% gen_mod callbacks
%-------------------------------------------------------------------------

-spec(start
(
    Host :: binary(),
    Opts :: [any()])
    -> any()
).

start(Host, _Opts) ->
    % FIXME: is this fixed?
    % FIXME: Currently we're assuming that in a cluster all instances have
    % exactly the same mod_push configuration. This is because we want every
    % instance to be able to serve the same proprietary push backends. The
    % opposite approach would be to partition the backends among the instances.
    % This would make cluster-internal messages necessary, so the current
    % implementation saves traffic. On the downside, config differences
    % between two instances would probably lead to unpredictable results and
    % the authorization data needed for e.g. APNS must be present on all
    % instances 
    % TODO: disable push subscription when session is deleted
    mnesia:create_table(push_user,
                        [{disc_copies, [node()]},
                         {type, set},
                         {attributes, record_info(fields, push_user)}]),
    mnesia:create_table(push_registration,
                        [{disc_copies, [node()]},
                         {type, set},
                         {attributes, record_info(fields, push_backend)}]),
    mnesia:create_table(push_backend,
                        [{ram_copies, [node()]},
                         {type, set},
                         {attributes, record_info(fields, push_backend)}]),
    mnesia:create_table(push_stored_packet,
                        [{disc_only_copies, [node()]},
                         {type, bag},
                         {attributes, record_info(fields, push_stored_packet)}]),
    UserFields = record_info(fields, push_user),
    RegFields = record_info(fields, push_registration),
    SPacketFields = record_info(fields, push_stored_packet),
    case mnesia:table_info(push_user, attributes) of
        UserFields -> ok;
        _ -> mnesia:transform_table(push_user, ignore, UserFields)
    end,
    case mnesia:table_info(push_registration, attributes) of
        RegFields -> ok;
        _ -> mnesia:transform_table(push_registration, ignore, RegFields)
    end,
    case mnesia:table_info(push_stored_packet, attributes) of
        SPacketFields -> ok;
        _ -> mnesia:transform_table(push_stored_packet, ignore, SPacketFields)
    end,

    ejabberd_hooks:add(remove_user, Host, ?MODULE, on_remove_user, 50),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, on_offline_message, ?OFFLINE_HOOK_PRIO),
    F = fun() -> Bs = add_backends(Host),
                 notify_previous_users(Host),
                 Bs end,
    case mnesia:transaction(F) of
        {atomic, Bs} -> ?DEBUG("++++++++ Added push backends: ~p", [Bs]);
        {aborted, Error} -> ?DEBUG("+++++++++ Error adding push backends: ~p", [Error])
    end.

%-------------------------------------------------------------------------

-spec(stop
(
    Host :: binary())
    -> any()
).

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PUSH),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, on_remove_user, 50),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, on_offline_message, ?OFFLINE_HOOK_PRIO),
    F = fun() ->
        mnesia:foldl(
            fun(Backend) ->
                RegHost = Backend#push_backend.register_host,
                PubsubHost = Backend#push_backend.pubsub_host,
                ejabberd_router:unregister_route(RegHost),
                ejabberd_router:unregister_route(PubsubHost),
                ejabberd_hooks:delete(adhoc_local_commands, RegHost, ?MODULE, process_adhoc_command, 75),
                {Local, Remote} =
                lists:partition(fun(N) -> N =:= node() end,
                                Backend#push_backend.cluster_nodes),
                case Local of
                    [] -> ok;
                    _ ->
                        case Remote of
                            [] ->
                                mnesia:delete({push_backend, Backend#push_backend.id});
                            _ ->
                                mnesia:write(
                                    Backend#push_backend{cluster_nodes = Remote})
                        end,
                        supervisor:terminate_child(ejabberd_sup,
                                                   Backend#push_backend.worker),
                        supervisor:delete_child(ejabberd_sup,
                                                Backend#push_backend.worker)
                end
            end,
            ok,
            push_backends,
            write)
       end,
    mnesia:transaction(F).

depends(_, _) ->
    [{mod_offline, hard}].

%-------------------------------------------------------------------------

mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(include_senders) -> fun(B) when is_boolean(B) -> B end;
mod_opt_type(include_message_count) -> fun(B) when is_boolean(B) -> B end;
mod_opt_type(include_subscription_count) -> fun(B) when is_boolean(B) -> B end;
mod_opt_type(include_message_bodies) -> fun(B) when is_boolean(B) -> B end;
mod_opt_type(access_backends) -> fun(A) when is_atom(A) -> A end;
mod_opt_type(certfile) -> fun(B) when is_binary(B) -> B end;
mod_opt_type(backends) -> fun ?MODULE:get_backend_opts/1;
mod_opt_type(_) ->
    [iqdisc, include_senders, include_message_count, include_subscription_count,
     include_message_bodies, access_backends, certfile, backends].

%-------------------------------------------------------------------------
% mod_push utility functions
%-------------------------------------------------------------------------

-spec(parse_backends
(
    BackendOpts :: [any()],
    DefaultCertFile :: binary())
    -> invalid | [{push_backend(), auth_data()}]
).

parse_backends(RawBackendOptsList, DefaultCertFile) ->
    BackendOptsList = get_backend_opts(RawBackendOptsList),
    MakeBackend =
    fun({RegHostJid, PubsubHostJid, Type, AppName, CertFile, AuthKey,
         PackageSid}, Acc) ->
        ChosenCertFile = case is_binary(CertFile) of
            true -> CertFile;
            false -> DefaultCertFile
        end,
        case is_binary(ChosenCertFile) and (ChosenCertFile =/= <<"">>) of
            true ->
                BackendId =
                erlang:phash2({RegHostJid#jid.lserver, Type}),
                AuthData =
                #auth_data{auth_key = AuthKey,
                           package_sid = PackageSid,
                           certfile = ChosenCertFile},
                Worker = make_worker_name(RegHostJid#jid.lserver, Type),
                Backend =
                #push_backend{
                   id = BackendId,
                   register_host = RegHostJid#jid.lserver,
                   pubsub_host = PubsubHostJid#jid.lserver,
                   type = Type,
                   app_name = AppName,
                   cluster_nodes = [node()],
                   worker = Worker},
                [{Backend, AuthData}|Acc];

            false ->
                ?ERROR_MSG("option certfile not defined for mod_push backend",
                           []),
                Acc
        end
    end,
    lists:foldl(MakeBackend, [], BackendOptsList).

%-------------------------------------------------------------------------

get_backend_opts(RawOptsList) ->
    lists:map(
        fun(Opts) ->
            RegHostJid =
            jlib:string_to_jid(proplists:get_value(register_host, Opts)),
            PubsubHostJid =
            jlib:string_to_jid(proplists:get_value(pubsub_host, Opts)),
            RawType = proplists:get_value(type, Opts),
            Type =
            case lists:member(RawType, [apns]) of
                true -> RawType
            end,
            AppName = proplists:get_value(app_name, Opts, <<"any">>),
            CertFile = proplists:get_value(certfile, Opts),
            AuthKey = proplists:get_value(auth_key, Opts),
            PackageSid = proplists:get_value(package_sid, Opts),
            {RegHostJid, PubsubHostJid, Type, AppName, CertFile, AuthKey,
             PackageSid}
        end,
        RawOptsList).

%-------------------------------------------------------------------------

-spec(make_payload
(
    UnackedStanzas :: [{erlang:timestamp(), xmlelement()}],
    StoredPayload :: payload(),
    Config :: user_config())
    -> none | {payload(), [{erlang:timestamp(), xmlelement()}]}
).

make_payload([], _StoredPayload, _Config) -> none;

make_payload(UnackedStanzas, StoredPayload, Config) ->
    UpdatePayload =
    fun(NewValues, OldPayload) ->
        lists:foldl(
            fun
                ({_Key, undefined}, Acc) -> Acc;
                ({Key, Value}, Acc) -> lists:keystore(Key, 1, Acc, {Key, Value})
            end,
            OldPayload,
            NewValues)
    end,
    MakeNewValues =
    fun(Stanza, OldPayload) ->
        FromS = proplists:get_value(<<"from">>, Stanza#xmlel.attrs),
        case Stanza of
            #xmlel{name = <<"message">>, children = Children} ->
                BodyPred =
                fun (#xmlel{name = <<"body">>}) -> true;
                    (_) -> false
                end,
                NewBody = case lists:filter(BodyPred, Children) of
                    [] -> undefined;
                    [#xmlel{children = [{xmlcdata, CData}]}|_] -> CData
                end,
                NewMsgCount = 
                case proplists:get_value('message-count', OldPayload, 0) of
                    ?MAX_INT -> 0;
                    C when is_integer(C) -> C + 1
                end,
                {push_and_store,
                 [{'last-message-body', NewBody},
                  {'last-message-sender', FromS},
                  {'message-count', NewMsgCount}]};

            #xmlel{name = <<"presence">>, attrs = Attrs} ->
                case proplists:get_value(<<"type">>, Attrs) of
                    <<"subscribe">> ->
                        OldSubscrCount =
                        proplists:get_value('pending-subscriptions', OldPayload, 0),
                        NewSubscrCount =
                        case OldSubscrCount of
                            ?MAX_INT -> 0;
                            C when is_integer(C) -> C + 1
                        end,
                        {push,
                         [{'pending-subscription-count', NewSubscrCount},
                          {'last-subscription-sender', FromS}]};

                    _ ->
                        {push, []}
                end;

            _ -> {push, []}
        end
    end,
    {NewPayload, StanzasToStore} =
    lists:foldl(
        fun({Timestamp, Stanza}, {PayloadAcc, StanzasAcc}) ->
            case MakeNewValues(Stanza, PayloadAcc) of
                {push, NewValues} -> 
                    {UpdatePayload(NewValues, PayloadAcc), StanzasAcc};

                {push_and_store, NewValues} ->
                    {UpdatePayload(NewValues, PayloadAcc),
                     [{Timestamp, Stanza}|StanzasAcc]}
            end
        end,                                              
        {StoredPayload, []},
        UnackedStanzas),
    {filter_payload(NewPayload, Config), StanzasToStore}.

%-------------------------------------------------------------------------

-spec(filter_payload
(
    Payload :: payload(),
    Config :: user_config())
    -> payload()
).

filter_payload(Payload, Config) ->
    OptsConfigMapping =
    [{'message-count', 'include-message-count'},
     {'last-message-sender', 'include-senders'},
     {'last-subscription-sender', 'include-senders'},
     {'last-message-body', 'include-message-bodies'},
     {'pending-subscription-count', 'include-subscription-count'}],
    lists:filter(
        fun({Key, _}) ->
            ConfigOpt = proplists:get_value(Key, OptsConfigMapping),
            proplists:get_value(ConfigOpt, Config)
        end,
        Payload).

%-------------------------------------------------------------------------
% general utility functions
%-------------------------------------------------------------------------

-spec(remove_subdomain (Hostname :: binary()) -> binary()).

remove_subdomain(Hostname) ->
    Dots = binary:matches(Hostname, <<".">>),
    case length(Dots) of
        NumberDots when NumberDots > 1 ->
            {Pos, _} = lists:nth(NumberDots - 1, Dots),
            binary:part(Hostname, {Pos + 1, byte_size(Hostname) - Pos - 1});
        _ -> Hostname
    end.

%-------------------------------------------------------------------------

vvaluel(Val) ->
    case Val of
        <<>> -> [];
        _ -> [?VVALUE(Val)]
    end.

%-------------------------------------------------------------------------

-spec(get_xdata_value
(
    FieldName :: binary(),
    Fields :: [{binary(), [binary()]}])
    -> error | binary()
).

get_xdata_value(FieldName, Fields) ->
    get_xdata_value(FieldName, Fields, undefined).

-spec(get_xdata_value
(
    FieldName :: binary(),
    Fields :: [{binary(), [binary()]}],
    DefaultValue :: any())
    -> any()
).

get_xdata_value(FieldName, Fields, DefaultValue) ->
    case proplists:get_value(FieldName, Fields, [DefaultValue]) of
        [Value] -> Value;
        _ -> error
    end.

-spec(get_xdata_values
(
    FieldName :: binary(),
    Fields :: [{binary(), [binary()]}])
    -> [binary()] 
).

get_xdata_values(FieldName, Fields) ->
    get_xdata_values(FieldName, Fields, []).

-spec(get_xdata_values
(
    FieldName :: binary(),
    Fields :: [{binary(), [binary()]}],
    DefaultValue :: any())
    -> any()
).

get_xdata_values(FieldName, Fields, DefaultValue) ->
    proplists:get_value(FieldName, Fields, DefaultValue).
    
%-------------------------------------------------------------------------

-spec(parse_form
(
    [false | xmlelement()],
    FormType :: binary(),
    RequiredFields :: [{multi, binary()} | {single, binary()} |
                       {{multi, binary()}, fun((binary()) -> any())} |
                       {{single, binary()}, fun((binary()) -> any())}],
    OptionalFields :: [{multi, binary()} | {single, binary()} |
                       {{multi, binary()}, fun((binary()) -> any())} |
                       {{single, binary()}, fun((binary()) -> any())}])
    -> not_found | error | {result, [any()]} 
).

parse_form([], _FormType, _RequiredFields, _OptionalFields) ->
    not_found;

parse_form([false|T], FormType, RequiredFields, OptionalFields) ->
    parse_form(T, FormType, RequiredFields, OptionalFields);

parse_form([XDataForm|T], FormType, RequiredFields, OptionalFields) ->
    case jlib:parse_xdata_submit(XDataForm) of
        invalid -> parse_form(T, FormType, RequiredFields, OptionalFields);
        Fields ->
            case get_xdata_value(<<"FORM_TYPE">>, Fields) of
                FormType ->
                    GetValues =
                    fun
                        ({multi, Key}) -> get_xdata_values(Key, Fields);
                        ({single, Key}) -> get_xdata_value(Key, Fields);
                        ({KeyTuple, Convert}) ->
                            case KeyTuple of
                                {multi, Key} ->
                                    Values = get_xdata_values(Key, Fields),
                                    Converted = lists:foldl(
                                        fun
                                        (_, error) -> error;
                                        (undefined, Acc) -> [undefined|Acc];
                                        (B, Acc) ->
                                            try [Convert(B)|Acc]
                                            catch error:badarg -> error
                                            end
                                        end,
                                        [],
                                        Values),
                                    lists:reverse(Converted);

                                {single, Key} ->
                                    case get_xdata_value(Key, Fields) of
                                        error -> error;
                                        undefined -> undefined;
                                        Value ->
                                           try Convert(Value)
                                           catch error:badarg -> error
                                           end
                                    end
                            end
                    end,
                    RequiredValues = lists:map(GetValues, RequiredFields),
                    OptionalValues = lists:map(GetValues, OptionalFields),
                    RequiredOk =
                    lists:all(
                        fun(V) ->
                            (V =/= undefined) and (V =/= []) and (V =/= error)
                        end,
                        RequiredValues),
                    OptionalOk =
                    lists:all(fun(V) -> V =/= error end, OptionalValues),
                    case RequiredOk and OptionalOk of
                        false -> error;
                        true ->
                            {result, RequiredValues ++ OptionalValues}
                    end;

                _ -> parse_form(T, FormType, RequiredFields, OptionalFields)
            end
    end.

%-------------------------------------------------------------------------

-spec(make_worker_name
(
    RegisterHost :: binary(),
    Type :: atom())
    -> atom()
).

make_worker_name(RegisterHost, Type) ->
    gen_mod:get_module_proc(RegisterHost, Type).

%-------------------------------------------------------------------------

-spec(ljid_to_jid
(
    ljid())
    -> jid()
).

ljid_to_jid({LUser, LServer, LResource}) ->
    #jid{user = LUser, server = LServer, resource = LResource,
         luser = LUser, lserver = LServer, lresource = LResource}.


%% Local Variables:
%% eval: (setq-local flycheck-erlang-include-path (list "../../../../src/ejabberd/include/"))
%% eval: (setq-local flycheck-erlang-library-path (list "/usr/local/Cellar/ejabberd/16.09/lib/cache_tab-1.0.4/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/ejabberd-16.09/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/esip-1.0.8/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/ezlib-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_tls-1.0.7/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_xml-1.1.15/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_yaml-1.0.6/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/goldrush-0.1.8/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/iconv-1.0.2/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/jiffy-0.14.7/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/lager-3.2.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/luerl-1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_mysql-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_oauth2-0.6.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_pam-1.0.0/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_pgsql-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_utils-1.0.5/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/stringprep-1.0.6/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/stun-1.0.7/ebin"))
%% End:
