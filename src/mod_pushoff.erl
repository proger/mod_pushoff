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
%%%

-module(mod_pushoff).

-author('christian@rechenwerk.net').
-author('proger@wilab.org.ua').
-author('dimskii123@gmail.com').

-behaviour(gen_mod).

-compile(export_all).
-export([start/2, stop/1, depends/2,
         mod_opt_type/1,
         parse_backends/1,
         on_offline_message/3,
         on_remove_user/2,
         process_adhoc_command/4,
         unregister_client/1,
         health/0]).

-include("logger.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").

-define(MODULE_APNS, mod_pushoff_apns).
-define(MODULE_FCM, mod_pushoff_fcm).
-define(OFFLINE_HOOK_PRIO, 1). % must fire before mod_offline (which has 50)

%
% xdata-form macros
%

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

%
% types
%

-type bare_jid() :: {binary(), binary()}.
-type backend_type() :: apns | fcm.
-type backend_id() :: {binary(), backend_type()}.

-record(backend_config,
        {type :: backend_type(),
         certfile = <<"">> :: binary(),
         gateway = <<"">> :: binary(),
         api_key = <<"">> :: binary()}).

%% mnesia table
-record(pushoff_registration, {bare_jid :: bare_jid(),
                               token :: binary(),
                               backend_id :: backend_id(),
                               timestamp :: erlang:timestamp()}).

-type pushoff_registration() :: #pushoff_registration{}.

-type backend_config() :: #backend_config{}.
-type payload_value() :: binary() | integer().
-type payload() :: [{atom() | binary(), payload_value()}].

%%

-spec(register_client(jid(), backend_id(), binary()) -> {registered, ok}).

register_client(#jid{luser = LUser,
                     lserver = LServer,
                     lresource = _LResource}, BackendId, ApnsToken) ->
    F = fun() ->
                MatchHeadReg =
                    #pushoff_registration{bare_jid = {LUser, LServer}, _='_'},
                ExistingReg =
                    mnesia:select(pushoff_registration, [{MatchHeadReg, [], ['$_']}]),
                    ?DEBUG("Existing client: ~p", [ExistingReg]),
                Registration =
                    case ExistingReg of
                        [] ->
                            #pushoff_registration{bare_jid = {LUser, LServer},
                                                  token = ApnsToken,
                                                  backend_id = BackendId,
                                                  timestamp = erlang:timestamp()};

                        [OldReg] ->
                            OldReg#pushoff_registration{token = ApnsToken,
                                                        backend_id = BackendId,
                                                        timestamp = erlang:timestamp()}
                    end,
                mnesia:write(Registration),
                ok
           end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> {error, ?ERR_ITEM_NOT_FOUND};
        {atomic, Result} -> {registered, Result}
    end. 


-spec(unregister_client({bare_jid(), erlang:timestamp()}) -> error |
                                                             {error, xmlelement()} |
                                                             {unregistered, ok} |
                                                             {unregistered, [binary()]}).

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

-spec(list_registrations(jid()) -> {error, xmlelement()} |
                                   {registrations, [pushoff_registration()]}).

list_registrations(#jid{luser = LUser, lserver = LServer}) ->
    F = fun() ->
        MatchHead = #pushoff_registration{bare_jid = {LUser, LServer}, _='_'},
        mnesia:select(pushoff_registration, [{MatchHead, [], ['$_']}])
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, RegList} -> 
            {registrations, RegList}
    end.

-spec(on_offline_message(From :: jid(), To :: jid(), Stanza :: xmlelement()) -> ok).

on_offline_message(From, To = #jid{luser = LUser, lserver = LServer}, Stanza) ->
    
    
    Transaction =
        fun() -> mnesia:read({pushoff_registration, {LUser, LServer}}) end,
    TransactionResult = mnesia:transaction(Transaction),
    case TransactionResult of
        {atomic, []} ->
            ?DEBUG("+++++ mod_pushoff dispatch: ~p is not_subscribed", [To]),
            ok;
        {atomic, [Reg]} ->
            dispatch(From, Reg, Stanza),
            ok;
        {aborted, Error} ->
            ?DEBUG("+++++ error in on_offline_message: ~p", [Error]),
            ok
    end.

-spec(dispatch(From :: jid(), To :: pushoff_registration(), Stanza :: xmlelement()) -> ok).

dispatch(From,
         #pushoff_registration{bare_jid = UserBare, token = Token, timestamp = Timestamp,
                               backend_id = BackendId},
         Stanza) ->
    case stanza_to_payload(From, Stanza) of
        ignore -> ok;
        Payload ->
            DisableArgs = {UserBare, Timestamp},
            ?DEBUG("PUSH to user<~p>, with token<~p>, payload<~p>, backendId<~p>", [UserBare, Token, Payload, BackendId]),
            gen_server:cast(backend_worker(BackendId),
                             {dispatch, UserBare, Payload, Token, DisableArgs}),
            ok
    end.

-spec(on_remove_user (User :: binary(), Server :: binary()) -> ok).

on_remove_user(User, Server) ->
    unregister_client({User, Server}, undefined).

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
                            register_client(From, {LServer, apns}, Token)
                    end
                end
            end;

        <<"unregister-push">> -> fun() -> unregister_client(From, undefined) end;
        <<"list-push-registrations">> -> fun() -> list_registrations(From) end;

        <<"register-push-fcm">> ->
            fun() ->
                Parsed = parse_form([XData],
                                    undefined,
                                    [{single, <<"token">>}],
                                    []),
                case Parsed of
                    {result, [AsciiToken]} ->
                        register_client(From, {LServer, fcm}, AsciiToken)
                end
            end;
        <<"unregister-push-fcm">> -> fun() -> unregister_client(From, undefined) end;
        <<"list-push-registrations-fcm">> -> fun() -> list_registrations(From) end;
        _ -> unknown
    end,
    Result = case Action of
        unknown -> unknown;
        _ ->
            Host = remove_subdomain(LServer), % why?
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

-spec(start(Host :: binary(), Opts :: [any()]) -> any()).

start(Host, _Opts) ->
    mnesia_set_from_record(?RECORD(pushoff_registration)),

    ejabberd_hooks:add(remove_user, Host, ?MODULE, on_remove_user, 50),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, on_offline_message, ?OFFLINE_HOOK_PRIO),
    ejabberd_hooks:add(adhoc_local_commands, Host, ?MODULE, process_adhoc_command, 75),

    Bs = backend_configs(Host),
    Results = [start_worker(Host, B) || B <- Bs],
    ?DEBUG("++++++++ Added push backends: ~p resulted in ~p", [Bs, Results]),
    ok.

-spec(stop(Host :: binary()) -> any()).

stop(Host) ->
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, on_remove_user, 50),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, on_offline_message, ?OFFLINE_HOOK_PRIO),
    ejabberd_hooks:delete(adhoc_local_commands, Host, ?MODULE, process_adhoc_command, 75),

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
    ?DEBUG("IN PARSE_BACKEND RawType <~p>", [RawType]),
    Gateway = proplists:get_value(gateway, Opts),
    CertFile = 
    case Type of
        apns ->
            proplists:get_value(certfile, Opts);
        fcm ->
            <<"">>
    end,
    ApiKey = 
    case Type of
        apns ->
            <<"">>;
        fcm ->
            proplists:get_value(api_key, Opts)
    end,

    #backend_config{type = Type,
                    certfile = CertFile,
                    gateway = Gateway,
                    api_key = ApiKey}.


-spec(backend_worker(backend_id()) -> atom()).

backend_worker({Host, Type}) -> gen_mod:get_module_proc(Host, Type).

backend_configs(Host) ->
    BackendOpts = gen_mod:get_module_opt(Host, ?MODULE, backends,
                                         fun(O) when is_list(O) -> O end, []),
    parse_backends(BackendOpts).


-spec(start_worker(Host :: binary(), Backend :: backend_config()) -> ok).

start_worker(Host, #backend_config{type = Type, certfile = CertFile, gateway = Gateway, api_key = ApiKey}) ->
    Module = proplists:get_value(Type, [{apns, ?MODULE_APNS}, {fcm, ?MODULE_FCM}]),
    Worker = backend_worker({Host, Type}),
    BackendSpec = {Worker,
                   {gen_server, start_link,
                    [{local, Worker}, Module,
                     [CertFile, Gateway, ApiKey], []]},
                   permanent, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, BackendSpec).

-spec(stanza_to_payload(jid(), xmlelement()) -> payload()).

stanza_to_payload(#jid{luser = FromU, lserver = FromS},
                  #xmlel{name = <<"message">>, attrs = Attrs, children = Children}) ->
    From = iolist_to_binary([FromU, <<"@">> ,FromS]),
    Body = case [CData || #xmlel{name = <<"body">>, children = [{xmlcdata, CData}]} <- Children] of
               [] -> <<"">>;
               [CData|_] when size(CData) >= 1024 ->
                   %% Truncate messages as you can't fit too much data into one push
                   binary_part(CData, 1024);
               [CData|_] -> CData
           end,
    case [Id || {<<"id">>, Id} <- Attrs] of
        [] -> [{body, Body}, {from, From}];
        [Id|_] -> [{id, Id}, {body, Body}, {from, From}]
    end;

stanza_to_payload(_, _) -> ignore.

-spec(remove_subdomain (Hostname :: binary()) -> binary()).

remove_subdomain(Hostname) ->
    Dots = binary:matches(Hostname, <<".">>),
    case length(Dots) of
        NumberDots when NumberDots > 1 ->
            {Pos, _} = lists:nth(NumberDots - 1, Dots),
            binary:part(Hostname, {Pos + 1, byte_size(Hostname) - Pos - 1});
        _ -> Hostname
    end.

vvaluel(Val) ->
    case Val of
        <<>> -> [];
        _ -> [?VVALUE(Val)]
    end.

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

health() ->
    Hosts = ejabberd_config:get_myhosts(),
    {[{ets:lookup(hooks, {offline_message_hook, H})} || H <- Hosts]}.
