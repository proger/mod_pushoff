%%%
%%% Copyright (C) 2015  Christian Ulrich
%%% Copyright (C) 2016  Vlad Ki
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

-module(mod_pushoff).

-author('christian@rechenwerk.net').
-author('proger@wilab.org.ua').
-author('dimskii123@gmail.com').

-behaviour(gen_mod).

-compile(export_all).
-export([start/2, stop/1, depends/2, mod_opt_type/1, parse_backends/1,
         offline_message/1, adhoc_local_commands/4, remove_user/2,
         health/0]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("adhoc.hrl").

-include("mod_pushoff.hrl").

-define(MODULE_APNS, mod_pushoff_apns).
-define(MODULE_FCM, mod_pushoff_fcm).
-define(OFFLINE_HOOK_PRIO, 1). % must fire before mod_offline (which has 50)

%
% types
%

-record(apns_config,
        {certfile = <<"">> :: binary(),
         gateway = <<"">> :: binary()}).

-record(fcm_config,
        {gateway = <<"">> :: binary(),
         api_key = <<"">> :: binary()}).

-type apns_config() :: #apns_config{}.
-type fcm_config() :: #fcm_config{}.

-record(backend_config,
        {type :: backend_type(),
         config :: apns_config() | fcm_config()}).

-type backend_config() :: #backend_config{}.

%
% dispatch to workers
%

-spec(stanza_to_payload(message()) -> [{atom(), any()}]).

stanza_to_payload(#message{id = Id, body = [#text{data=CData}|_], from = From}) ->
    Plist = [{body, case size(CData) of
                        S when S >= 1024 ->
                            %% Truncate messages as you can't fit too much data into one push
                            binary_part(CData, 1024);
                        _ -> CData end},
             {from, jid:encode(From)}],
    case Id of
        <<"">> -> Plist;
        _ -> [{id, Id}|Plist]
    end;
stanza_to_payload(_) -> ignore.

-spec(dispatch(pushoff_registration(), [{atom(), any()}]) -> ok).

dispatch(#pushoff_registration{bare_jid = UserBare, token = Token, timestamp = Timestamp,
                               backend_id = BackendId},
         Payload) ->
    DisableArgs = {UserBare, Timestamp},
    gen_server:cast(backend_worker(BackendId),
                    {dispatch, UserBare, Payload, Token, DisableArgs}),
    ok.


%
% ejabberd hooks
%

-spec(offline_message({any(), message()}) -> ok).

offline_message({_, #message{to = To} = Stanza}) ->
    case stanza_to_payload(Stanza) of
        ignore -> ok;
        Payload ->
            case mod_pushoff_mnesia:list_registrations(To) of
                {registrations, []} ->
                    ?DEBUG("~p is not_subscribed", [To]),
                    ok;
                {registrations, [Reg]} ->
                    dispatch(Reg, Payload),
                    ok;
                {error, _} -> ok
            end
    end.


-spec(remove_user(User :: binary(), Server :: binary()) ->
             {error, stanza_error()} |
             {unregistered, [pushoff_registration()]}).

remove_user(User, Server) ->
    mod_pushoff_mnesia:unregister_client({User, Server}, '_').


-spec adhoc_local_commands(Acc :: empty | adhoc_command(),
                           From :: jid(),
                           To :: jid(),
                           Request :: adhoc_command()) ->
                                  adhoc_command() |
                                  {error, stanza_error()}.

adhoc_local_commands(Acc, From, To, #adhoc_command{node = Command, action = execute, xdata = XData} = Req) ->
    Host = To#jid.lserver,
    Access = gen_mod:get_module_opt(Host, ?MODULE, access_backends,
                                    fun(A) when is_atom(A) -> A end, all),
    Result = case acl:match_rule(Host, Access, From) of
        deny -> {error, xmpp:err_forbidden()};
        allow -> adhoc_perform_action(Command, From, XData)
    end,

    case Result of
        unknown -> Acc;
        {error, Error} -> {error, Error};

        {registered, ok} ->
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed});

        {unregistered, Regs} ->
            X = xmpp_util:set_xdata_field(#xdata_field{var = <<"removed-registrations">>,
                                                       values = [T || #pushoff_registration{token=T} <- Regs]}, #xdata{}),
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed, xdata = X});

        {registrations, Regs} ->
            X = xmpp_util:set_xdata_field(#xdata_field{var = <<"registrations">>,
                                                       values = [T || #pushoff_registration{token=T} <- Regs]}, #xdata{}),
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed, xdata = X})
    end;
adhoc_local_commands(Acc, _From, _To, _Request) ->
    Acc.


adhoc_perform_action(<<"register-push-apns">>, #jid{lserver = LServer} = From, XData) ->
    case xmpp_util:get_xdata_values(<<"token">>, XData) of
        [Base64Token] ->
            case catch base64:decode(Base64Token) of
                {'EXIT', _} -> {error, xmpp:err_bad_request()};
                Token -> mod_pushoff_mnesia:register_client(From, {LServer, apns}, Token)
            end;
        _ -> {error, xmpp:err_bad_request()}
    end;
adhoc_perform_action(<<"register-push-fcm">>, #jid{lserver = LServer} = From, XData) ->
    case xmpp_util:get_xdata_values(<<"token">>, XData) of
        [AsciiToken] -> mod_pushoff_mnesia:register_client(From, {LServer, fcm}, AsciiToken);
        _ -> {error, xmpp:err_bad_request()}
    end;
adhoc_perform_action(<<"unregister-push">>, From, _) ->
    mod_pushoff_mnesia:unregister_client(From, undefined);
adhoc_perform_action(<<"list-push-registrations">>, From, _) ->
    mod_pushoff_mnesia:list_registrations(From);
adhoc_perform_action(_, _, _) ->
    unknown.

%
% ejabberd gen_mod callbacks and configuration
%

-spec(start(Host :: binary(), Opts :: [any()]) -> any()).

start(Host, Opts) ->
    mod_pushoff_mnesia:create(),

    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message, ?OFFLINE_HOOK_PRIO),
    ejabberd_hooks:add(adhoc_local_commands, Host, ?MODULE, adhoc_local_commands, 75),

    Results = [start_worker(Host, B) || B <- proplists:get_value(backends, Opts)],
    ?INFO_MSG("++++++++ mod_pushoff:start(~p, ~p): workers ~p", [Host, Opts, Results]),
    ok.

-spec(stop(Host :: binary()) -> any()).

stop(Host) ->
    ejabberd_hooks:delete(adhoc_local_commands, Host, ?MODULE, adhoc_local_commands, 75),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message, ?OFFLINE_HOOK_PRIO),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),

    [begin
         Worker = backend_worker({Host, Type}),
         supervisor:terminate_child(ejabberd_sup, Worker),
         supervisor:delete_child(ejabberd_sup, Worker)
     end || #backend_config{type=Type} <- backend_configs(Host)],
    ok.

depends(_, _) ->
    [{mod_offline, hard}].

mod_opt_type(backends) -> fun ?MODULE:parse_backends/1;
mod_opt_type(_) -> [backends].

parse_backends(Plists) ->
    [parse_backend(Plist) || Plist <- Plists].

parse_backend(Opts) ->
    RawType = proplists:get_value(type, Opts),
    Type =
        case lists:member(RawType, [apns, fcm]) of
            true -> RawType
        end,
    Gateway = proplists:get_value(gateway, Opts),
    CertFile = proplists:get_value(certfile, Opts),
    ApiKey = proplists:get_value(api_key, Opts),

    #backend_config{
       type = Type,
       config =
           case Type of
               apns ->
                   #apns_config{certfile = CertFile, gateway = Gateway};
               fcm ->
                   #fcm_config{gateway = Gateway, api_key = ApiKey}
           end
      }.

%
% workers
%

-spec(backend_worker(backend_id()) -> atom()).

backend_worker({Host, Type}) -> gen_mod:get_module_proc(Host, Type).

backend_configs(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, backends,
                           fun(O) when is_list(O) -> O end, []).

-spec(start_worker(Host :: binary(), Backend :: backend_config()) -> ok).

start_worker(Host, #backend_config{type = Type, config = TypeConfig}) ->
    Module = proplists:get_value(Type, [{apns, ?MODULE_APNS}, {fcm, ?MODULE_FCM}]),
    Worker = backend_worker({Host, Type}),
    BackendSpec = 
    case Type of
        apns ->
                  {Worker,
                   {gen_server, start_link,
                    [{local, Worker}, Module,
                     %% TODO: mb i should send one record like BackendConfig#backend_config.config and parse it in each module
                     [TypeConfig#apns_config.certfile, TypeConfig#apns_config.gateway], []]},
                   permanent, 1000, worker, [?MODULE]};
        fcm ->
                  {Worker,
                   {gen_server, start_link,
                    [{local, Worker}, Module,
                     %% TODO: mb i should send one record like BackendConfig#backend_config.config and parse it in each module
                     [TypeConfig#fcm_config.gateway, TypeConfig#fcm_config.api_key], []]},
                   permanent, 1000, worker, [?MODULE]}
    end,

    supervisor:start_child(ejabberd_sup, BackendSpec).

%
% operations
%

health() ->
    Hosts = ejabberd_config:get_myhosts(),
    [{offline_message_hook, [ets:lookup(hooks, {offline_message_hook, H}) || H <- Hosts]},
     {adhoc_local_commands, [ets:lookup(hooks, {adhoc_local_commands, H}) || H <- Hosts]},
     {mnesia, mod_pushoff_mnesia:health()}].
