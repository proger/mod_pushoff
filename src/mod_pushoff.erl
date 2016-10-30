%%%----------------------------------------------------------------------
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

-module(mod_pushoff).

-author('christian@rechenwerk.net').

-behaviour(gen_mod).

-compile(export_all).
-export([start/2, stop/1, depends/2,
         mod_opt_type/1,
         get_backend_opts/1,
         on_offline_message/3,
         on_remove_user/2,
         process_adhoc_command/4,
         unregister_client/1,
         health/0]).

-include("logger.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").

-define(MODULE_APNS, mod_pushoff_apns).
-define(OFFLINE_HOOK_PRIO, 1). % must fire before mod_offline (which has 50)
-define(MAX_INT, 4294967295).

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
        {certfile = <<"">> :: binary(),
         gateway = <<"">> :: binary()}).

%% mnesia table
-record(pushoff_registration, {bare_jid :: bare_jid(),
                               token :: binary(),
                               backend_id :: integer(),
                               timestamp = now() :: erlang:timestamp()}).

%% mnesia table
-record(pushoff_backend,
        {id :: integer(),
         register_host :: binary(),
         type :: backend_type(),
         app_name :: binary(),
         cluster_nodes = [] :: [atom()],
         worker :: binary()}).

-type auth_data() :: #auth_data{}.
-type backend_type() :: apns.
-type bare_jid() :: {binary(), binary()}.
-type payload_value() :: binary() | integer().
-type payload() :: [{atom() | binary(), payload_value()}].
-type pushoff_backend() :: #pushoff_backend{}.
-type pushoff_registration() :: #pushoff_registration{}.

%-------------------------------------------------------------------------

-spec(register_client(User :: jid(), RegisterHost :: binary(),
                      Type :: backend_type(), Token :: binary()) -> {registered, ok}).

register_client(#jid{luser = LUser,
                     lserver = LServer,
                     lresource = _LResource}, RegisterHost, Type, Token) ->
    F = fun() ->
        MatchHeadBackend =
        #pushoff_backend{register_host = RegisterHost, type = Type, _='_'},
        MatchingBackends =
        mnesia:select(pushoff_backend, [{MatchHeadBackend, [], ['$_']}]),
        case MatchingBackends of
            [#pushoff_backend{id = BackendId}|_] ->
                ?DEBUG("+++++ register_client: found backend", []),
                MatchHeadReg =
                    #pushoff_registration{bare_jid = {LUser, LServer}, _='_'},
                ExistingReg =
                    mnesia:select(pushoff_registration, [{MatchHeadReg, [], ['$_']}]),
                Registration =
                    case ExistingReg of
                        [] ->
                            #pushoff_registration{bare_jid = {LUser, LServer},
                                                  token = Token,
                                                  backend_id = BackendId};

                    [OldReg] ->
                        OldReg#pushoff_registration{token = Token,
                                                    backend_id = BackendId,
                                                    timestamp = now()}
                end,
                mnesia:write(Registration),
                ok;
            
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

unregister_client({U, T}) -> unregister_client(U, T).

-spec(unregister_client(BareJid :: bare_jid(),
                        Timestamp :: erlang:timestamp()) -> error |
                                                            {error, xmlelement()} |
                                                            {unregistered, ok} |
                                                            {unregistered, [binary()]}).

unregister_client(#jid{luser = LUser, lserver = LServer}, Ts) ->
    unregister_client({LUser, LServer}, Ts);
unregister_client({LUser, LServer}, Timestamp) ->
    F = fun() ->
                MatchHead =
                    #pushoff_registration{bare_jid = {LUser, LServer},
                                          timestamp = Timestamp,
                                          _='_'},
                MatchingReg =
                    mnesia:select(pushoff_registration, [{MatchHead, [], ['$_']}]),
                case MatchingReg of
                    [] -> error;

                    [Reg] ->
                        ?DEBUG("+++++ deleting registration of user ~p",
                               [Reg#pushoff_registration.bare_jid]),
                        mnesia:delete_object(Reg),
                        ok
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

-spec(list_registrations(jid()) -> {error, xmlelement()} |
                                   {registrations, [pushoff_registration()]}).

list_registrations(#jid{luser = LUser, lserver = LServer}) ->
    F = fun() ->
        MatchHead = #pushoff_registration{bare_jid = {LUser, LServer}, _='_'},
        mnesia:select(pushoff_registration, [{MatchHead, [], ['$_']}])
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, RegList} -> {registrations, RegList}
    end.

%-------------------------------------------------------------------------

-spec(on_offline_message(From :: jid(), To :: jid(), Stanza :: xmlelement()) -> ok).

on_offline_message(From, To = #jid{luser = LUser, lserver = LServer}, Stanza) ->
    Transaction =
        fun() ->
                Regs = mnesia:read({pushoff_registration, {LUser, LServer}}),
                Backends = case Regs of
                               [#pushoff_registration{backend_id = BackendId}] ->
                                   mnesia:read({pushoff_backend, BackendId});
                               _ -> []
                           end,
                {Regs, Backends}
        end,
    case mnesia:transaction(Transaction) of
        {atomic, {[], _}} ->
            ?DEBUG("+++++ mod_pushoff dispatch: ~p is not_subscribed", [To]),
            ok;
        {atomic, {Regs, []}} ->
            ?DEBUG("+++++ mod_pushoff dispatch: no backends found for ~p", [Regs]),
            ok;
        {atomic, {[Reg], [Backend]}} ->
            dispatch(From, Reg, Stanza, Backend),
            ok;
        {aborted, Error} ->
            ?DEBUG("+++++ error in on_offline_message: ~p", [Error]),
            ok
    end.

%-------------------------------------------------------------------------

-spec(dispatch(From :: jid(), To :: pushoff_registration(), Stanza :: xmlelement(),
               Backend :: pushoff_backend()) -> ok).

dispatch(From,
         #pushoff_registration{bare_jid = UserBare, token = Token, timestamp = Timestamp},
         Stanza,
         #pushoff_backend{worker = Worker}) ->
    Payload = stanza_to_payload(From, Stanza),

    DisableArgs = {UserBare, Timestamp},
    gen_server:cast(Worker, {dispatch, UserBare, Payload, Token, DisableArgs}),
    ok.

%-------------------------------------------------------------------------

-spec(on_remove_user (User :: binary(), Server :: binary()) -> ok).

on_remove_user(User, Server) ->
    unregister_client({User, Server}, undefined).

%-------------------------------------------------------------------------

-spec(add_backends(Host :: binary()) -> ok | error).

add_backends(Host) ->
    BackendOpts =
    gen_mod:get_module_opt(Host, ?MODULE, backends,
                           fun(O) when is_list(O) -> O end,
                           []),
    Backends = parse_backends(BackendOpts),
    lists:foreach(
        fun({Backend, AuthData}) ->
            RegisterHost = Backend#pushoff_backend.register_host,
            %ejabberd_router:register_route(RegisterHost),
            ejabberd_hooks:add(adhoc_local_commands, RegisterHost, ?MODULE, process_adhoc_command, 75),
            ?INFO_MSG("added adhoc command handler for app server ~p",
                      [RegisterHost]),
            NewBackend =
            case mnesia:read({pushoff_backend, Backend#pushoff_backend.id}) of
                [] -> Backend;
                [#pushoff_backend{cluster_nodes = Nodes}] ->
                    NewNodes =
                    lists:merge(Nodes, Backend#pushoff_backend.cluster_nodes),
                    Backend#pushoff_backend{cluster_nodes = NewNodes}
            end,
            mnesia:write(NewBackend),
            start_worker(Backend, AuthData)
        end,
      Backends),
    Backends.
    

%-------------------------------------------------------------------------

-spec(start_worker(Backend :: pushoff_backend(), AuthData :: auth_data()) -> ok).

start_worker(#pushoff_backend{worker = Worker, type = Type},
             #auth_data{certfile = CertFile, gateway = Gateway}) ->
    Module =
    proplists:get_value(Type,
                        [{apns, ?MODULE_APNS}]),
    BackendSpec =
    {Worker,
     {gen_server, start_link,
      [{local, Worker}, Module,
       [CertFile, Gateway], []]},
     permanent, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, BackendSpec).

%-------------------------------------------------------------------------

-spec(process_adhoc_command(Acc :: any(), From :: jid(),
                            To :: jid(), Request :: adhoc_request()) -> any()).

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
                                    []),
                case Parsed of
                    {result, [Base64Token]} ->
                        case catch base64:decode(Base64Token) of
                            {'EXIT', _} ->
                                error;

                            Token ->
                                register_client(From, LServer, apns, Token)
                        end
                end
            end;

        <<"unregister-push">> -> fun() -> unregister_client(From, undefined) end;
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

        {registered, ok} ->
            Response =
            #adhoc_response{
                status = completed,
                elements = [#xmlel{name = <<"x">>,
                                   attrs = [{<<"xmlns">>, ?NS_XDATA},
                                            {<<"type">>, <<"result">>}],
                                   children = []}]},
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
                fun(_Reg, ItemsAcc) ->
                    NameField = [],
                    NodeField = [],
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

-spec(start(Host :: binary(), Opts :: [any()]) -> any()).

-define(RECORD(X), {X, record_info(fields, X)}).

mnesia_set_from_record({Name, Fields}) ->
    mnesia:create_table(Name,
                        [{disc_copies, [node()]},
                         {type, set},
                         {attributes, Fields}]),

    case mnesia:table_info(Name, attributes) of
        Fields -> ok;
        _ -> mnesia:transform_table(Name, ignore, Fields)
    end.

start(Host, _Opts) ->
    mnesia_set_from_record(?RECORD(pushoff_registration)),
    mnesia_set_from_record(?RECORD(pushoff_backend)),

    ejabberd_hooks:add(remove_user, Host, ?MODULE, on_remove_user, 50),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, on_offline_message, ?OFFLINE_HOOK_PRIO),
    F = fun() -> add_backends(Host) end,
    case mnesia:transaction(F) of
        {atomic, Bs} -> ?DEBUG("++++++++ Added push backends: ~p", [Bs]);
        {aborted, Error} -> ?DEBUG("+++++++++ Error adding push backends: ~p", [Error])
    end.

%-------------------------------------------------------------------------

-spec(stop(Host :: binary()) -> any()).

stop(Host) ->
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, on_remove_user, 50),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, on_offline_message, ?OFFLINE_HOOK_PRIO),
    F = fun() ->
        mnesia:foldl(
            fun(Backend) ->
                RegHost = Backend#pushoff_backend.register_host,
                %ejabberd_router:unregister_route(RegHost),
                ejabberd_hooks:delete(adhoc_local_commands, RegHost, ?MODULE, process_adhoc_command, 75),
                {Local, Remote} =
                lists:partition(fun(N) -> N =:= node() end,
                                Backend#pushoff_backend.cluster_nodes),
                case Local of
                    [] -> ok;
                    _ ->
                        case Remote of
                            [] ->
                                mnesia:delete({pushoff_backend, Backend#pushoff_backend.id});
                            _ ->
                                mnesia:write(
                                    Backend#pushoff_backend{cluster_nodes = Remote})
                        end,
                        supervisor:terminate_child(ejabberd_sup,
                                                   Backend#pushoff_backend.worker),
                        supervisor:delete_child(ejabberd_sup,
                                                Backend#pushoff_backend.worker)
                end
            end,
            ok,
            pushoff_backends,
            write)
       end,
    mnesia:transaction(F).

depends(_, _) ->
    [{mod_offline, hard}].

%-------------------------------------------------------------------------

mod_opt_type(backends) -> fun ?MODULE:get_backend_opts/1;
mod_opt_type(_) -> [backends].

get_backend_opts(RawOptsList) ->
    lists:map(
        fun(Opts) ->
            RegHostJid =
            jlib:string_to_jid(proplists:get_value(register_host, Opts)),
            RawType = proplists:get_value(type, Opts),
            Type =
            case lists:member(RawType, [apns]) of
                true -> RawType
            end,
            AppName = proplists:get_value(app_name, Opts, <<"any">>),
            CertFile = proplists:get_value(certfile, Opts),
            Gateway = proplists:get_value(gateway, Opts),
            {RegHostJid, Type, AppName, CertFile, Gateway}
        end,
        RawOptsList).

-spec(parse_backends(BackendOpts :: [any()]) -> invalid |
                                                [{pushoff_backend(), auth_data()}]).

parse_backends(RawBackendOptsList) ->
    BackendOptsList = get_backend_opts(RawBackendOptsList),
    MakeBackend =
    fun({RegHostJid, Type, AppName, ChosenCertFile, Gateway}, Acc) ->
        case is_binary(ChosenCertFile) and (ChosenCertFile =/= <<"">>) of
            true ->
                BackendId = erlang:phash2({RegHostJid#jid.lserver, Type}),
                AuthData = #auth_data{certfile = ChosenCertFile,
                                      gateway = Gateway},
                Worker = make_worker_name(RegHostJid#jid.lserver, Type),
                Backend =
                #pushoff_backend{
                   id = BackendId,
                   register_host = RegHostJid#jid.lserver,
                   type = Type,
                   app_name = AppName,
                   cluster_nodes = [node()],
                   worker = Worker},
                [{Backend, AuthData}|Acc];

            false ->
                ?ERROR_MSG("option certfile not defined for mod_pushoff backend", []),
                Acc
        end
    end,
    lists:foldl(MakeBackend, [], BackendOptsList).

%-------------------------------------------------------------------------

-spec(stanza_to_payload(jid(), xmlelement()) -> payload()).

stanza_to_payload(#jid{luser = FromU, lserver = FromS},
                  #xmlel{name = <<"message">>, children = Children}) ->
    From = iolist_to_binary([FromU, <<"@">> ,FromS]),
    BodyPred =
        fun (#xmlel{name = <<"body">>}) -> true;
            (_) -> false
        end,
    Body = case lists:filter(BodyPred, Children) of
               [] -> <<"">>;
               [#xmlel{children = [{xmlcdata, CData}]}|_] -> CData
           end,
    % Truncate messages as you can't fit too much data into one push
    Body1 = case size(Body) of
                N when N >= 1024 -> binary_part(Body, 1024);
                _ -> Body
            end,
    [{body, Body1}, {from, From}];

stanza_to_payload(_, _) -> {push, []}.

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

-spec(get_xdata_value(FieldName :: binary(),
                      Fields :: [{binary(), [binary()]}]) -> error |
                                                             binary()).

get_xdata_value(FieldName, Fields) ->
    get_xdata_value(FieldName, Fields, undefined).

-spec(get_xdata_value(FieldName :: binary(),
                      Fields :: [{binary(), [binary()]}],
                      DefaultValue :: any()) -> any()).

get_xdata_value(FieldName, Fields, DefaultValue) ->
    case proplists:get_value(FieldName, Fields, [DefaultValue]) of
        [Value] -> Value;
        _ -> error
    end.

-spec(get_xdata_values(FieldName :: binary(),
                       Fields :: [{binary(), [binary()]}]) -> [binary()]).

get_xdata_values(FieldName, Fields) ->
    get_xdata_values(FieldName, Fields, []).

-spec(get_xdata_values(FieldName :: binary(),
                       Fields :: [{binary(), [binary()]}],
                       DefaultValue :: any())
      -> any()).

get_xdata_values(FieldName, Fields, DefaultValue) ->
    proplists:get_value(FieldName, Fields, DefaultValue).
    
%-------------------------------------------------------------------------

-spec(parse_form(
        [false | xmlelement()],
        FormType :: binary(),
        RequiredFields :: [{multi, binary()} | {single, binary()} |
                           {{multi, binary()}, fun((binary()) -> any())} |
                           {{single, binary()}, fun((binary()) -> any())}],
        OptionalFields :: [{multi, binary()} | {single, binary()} |
                           {{multi, binary()}, fun((binary()) -> any())} |
                           {{single, binary()}, fun((binary()) -> any())}])
    -> not_found | error | {result, [any()]}).

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

-spec(make_worker_name(RegisterHost :: binary(), Type :: atom()) -> atom()).

make_worker_name(RegisterHost, Type) ->
    gen_mod:get_module_proc(RegisterHost, Type).

%-------------------------------------------------------------------------

health() ->
    Hosts = ejabberd_config:get_myhosts(),
    {[{ets:lookup(hooks, {offline_message_hook, H})} || H <- Hosts]}.


%% Local Variables:
%% eval: (setq-local flycheck-erlang-include-path (list "../../../../src/ejabberd/include/"))
%% eval: (setq-local flycheck-erlang-library-path (list "/usr/local/Cellar/ejabberd/16.09/lib/cache_tab-1.0.4/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/ejabberd-16.09/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/esip-1.0.8/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/ezlib-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_tls-1.0.7/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_xml-1.1.15/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_yaml-1.0.6/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/goldrush-0.1.8/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/iconv-1.0.2/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/jiffy-0.14.7/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/lager-3.2.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/luerl-1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_mysql-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_oauth2-0.6.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_pam-1.0.0/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_pgsql-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_utils-1.0.5/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/stringprep-1.0.6/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/stun-1.0.7/ebin"))
%% End:
