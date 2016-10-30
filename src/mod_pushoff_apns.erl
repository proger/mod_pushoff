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

%% This implements the "legacy" binary API

-module(mod_pushoff_apns).

-author('christian@rechenwerk.net').

-behaviour(gen_server).
-compile(export_all).
-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

-include("logger.hrl").

-define(APNS_PORT, 2195).
-define(SSL_TIMEOUT, 3000).
-define(MAX_PAYLOAD_SIZE, 2048).
-define(MESSAGE_EXPIRY_TIME, 86400).
-define(MESSAGE_PRIORITY, 10).
-define(MAX_PENDING_NOTIFICATIONS, 16).
-define(PENDING_INTERVAL, 3000).
-define(RETRY_INTERVAL, 30000).
-define(CIPHERSUITES,
        [{K,C,H} || {K,C,H} <- ssl:cipher_suites(erlang),
                    %K =/= ecdh_ecdsa, K =/= ecdh_rsa, K =/= rsa,
                    K =/= ecdh_ecdsa, K =/= ecdh_rsa,
                    C =/= rc4_128, C =/= des_cbc, C =/= '3des_ede_cbc',
                    %H =/= sha, H =/= md5]).
                    H =/= md5]).

-record(state,
        {certfile :: binary(),
         out_socket :: ssl:socket(),
         pending_list :: [{pos_integer(), any()}],
         send_list :: [any()],
         retry_list :: [any()],
         pending_timer :: reference(),
         retry_timer :: reference(),
         pending_timestamp :: erlang:timestamp(),
         retry_timestamp :: erlang:timestamp(),
         message_id :: pos_integer(),
         gateway :: string()}).

init([CertFile, Gateway]) ->
    ?INFO_MSG("+++++++++ mod_pushoff_apns:init, certfile = ~p, gateway ~p", [CertFile, Gateway]),
    inets:start(),
    crypto:start(),
    ssl:start(),
    {ok, #state{certfile = CertFile,
                pending_list = [],
                send_list = [],
                retry_list = [],
                pending_timer = make_ref(),
                retry_timer = make_ref(),
                message_id = 0,
                gateway = Gateway}}.

handle_info({ssl, _Socket, Data},
            #state{pending_list = PendingList,
                   retry_list = RetryList,
                   pending_timer = PendingTimer,
                   retry_timer = RetryTimer} = State) ->
    erlang:cancel_timer(PendingTimer),
    NewState =
    try
        <<RCommand:1/unit:8, RStatus:1/unit:8, RId:4/unit:8>> = iolist_to_binary(Data),
        {RCommand, RStatus, RId}
    of
        {8, Status, Id} ->
            DropProcessed = lists:dropwhile(fun({Key, _}) -> Key =/= Id end, PendingList),
            case DropProcessed of
                [] -> State;

                [{_, {UserB, _, Token, DisableArgs} = Element}|NewPending] ->
                    case Status of
                        10 ->
                            ?WARNING_MSG("APNS: got maintenance error, retrying...", []),
                            {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                            State#state{pending_list = NewPending,
                                        retry_list = [Element|RetryList],
                                        retry_timer = NewRetryTimer,
                                        retry_timestamp = Timestamp};

                        7 ->
                            ?ERROR_MSG("APNS: invalid payload size, retrying...", []),
                            {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                            State#state{
                                pending_list = NewPending,
                                retry_list =
                                [{UserB, [], Token, DisableArgs}|RetryList],
                                retry_timer = NewRetryTimer,
                                retry_timestamp = Timestamp};

                        8 ->
                            ?ERROR_MSG("APNS error: invalid token for ~p ~p", [UserB, Token]),
                            mod_pushoff:unregister_client(DisableArgs),
                            State#state{pending_list = NewPending};

                        S ->
                            ?ERROR_MSG("non-recoverable APNS error: ~p", [S]),
                            mod_pushoff:unregister_client(DisableArgs),
                            State#state{pending_list = NewPending}
                    end
            end;

        _ ->
            ?ERROR_MSG("invalid APNS response", []),
            State
    catch {'EXIT', _} ->
        ?ERROR_MSG("invalid APNS response", []),
        State
    end,
    self() ! send,
    {noreply, NewState#state{pending_timestamp = undefined}};
         
handle_info({ssl_closed, _SslSocket}, State) ->
    ?INFO_MSG("connection to APNS closed!", []),
    {noreply, State#state{out_socket = undefined}};

%% retry_timeout
handle_info({retry, Timestamp},
            #state{send_list = SendList,
                   retry_list = RetryList,
                   pending_timer = PendingTimer,
                   retry_timestamp = StoredTimestamp} = State) ->
    NewState =
    case Timestamp of
        StoredTimestamp ->
            NewSendList = SendList ++ RetryList,
            case erlang:read_timer(PendingTimer) of
                false -> self() ! send;
                _ -> State
            end,
            State#state{send_list = NewSendList, retry_list = []};

        _ -> State
    end,
    {noreply, NewState};

handle_info({pending_timeout, Timestamp},
            #state{pending_timestamp = StoredTimestamp} = State) ->
    NewState =
    case Timestamp of
        StoredTimestamp ->
            self() ! send,
            State#state{pending_list = []};

        _ -> State
    end,
    {noreply, NewState};

handle_info(send, #state{certfile = CertFile,
                         out_socket = OldSocket,
                         pending_list = PendingList,
                         send_list = SendList,
                         retry_list = RetryList,
                         retry_timer = RetryTimer,
                         message_id = MessageId,
                         gateway = Gateway} = State) ->
    NewState =
    case get_socket(OldSocket, CertFile, Gateway) of
        {error, Reason} ->
            ?ERROR_MSG("connection to APNS failed: ~p", [Reason]),
            NewRetryList = pending_to_retry(PendingList, RetryList),
            {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
            State#state{out_socket = error,
                        pending_list = [],
                        retry_list = NewRetryList,
                        retry_timer = NewRetryTimer,
                        retry_timestamp = Timestamp};

        Socket ->
            {NewPendingList,
             NewSendList,
             NewMessageId} = enqueue_some(PendingList, SendList, MessageId),
            case NewPendingList of
                [] ->
                    State#state{pending_list = NewPendingList,
                                send_list = NewSendList,
                                message_id = NewMessageId};

                _ ->
                    Notifications = make_notifications(NewPendingList),
                    case ssl:send(Socket, Notifications) of
                        {error, Reason} ->
                            ?ERROR_MSG("sending to APNS failed: ~p", [Reason]),
                            NewRetryList = pending_to_retry(NewPendingList, RetryList),
                            {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                            State#state{out_socket = error,
                                        pending_list = [],
                                        retry_list = NewRetryList,
                                        send_list = NewSendList,
                                        retry_timer = NewRetryTimer,
                                        message_id = NewMessageId,
                                        retry_timestamp = Timestamp};

                        ok ->
                            ?DEBUG("sending to APNS successful: ~p", [NewPendingList]),
                            Timestamp = erlang:now(),
                            NewPendingTimer =
                            erlang:send_after(?PENDING_INTERVAL, self(),
                                              {pending_timeout, Timestamp}),
                            State#state{out_socket = Socket,
                                        pending_list = NewPendingList,
                                        send_list = NewSendList,
                                        pending_timer = NewPendingTimer,
                                        message_id = NewMessageId,
                                        pending_timestamp = Timestamp}
                    end
            end
    end,
    {noreply, NewState};

handle_info(Info, State) ->
    ?DEBUG("+++++++ mod_pushoff_apns received unexpected signal ~p", [Info]),
    {noreply, State}.

handle_call(_Req, _From, State) -> {reply, {error, badarg}, State}.

handle_cast({dispatch, UserBare, Payload, Token, DisableArgs},
            #state{send_list = SendList,
                   pending_timer = PendingTimer,
                   retry_timer = RetryTimer} = State) ->
    % TODO: use queue?
    NewSendList = SendList ++ [{UserBare, Payload, Token, DisableArgs}],
    case {erlang:read_timer(PendingTimer), erlang:read_timer(RetryTimer)} of
        {false, false} -> self() ! send;
        _ -> ok
    end,
    {noreply, State#state{send_list = NewSendList}};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

terminate(_Reason, #state{out_socket = OutSocket}) ->
    case OutSocket of
        undefined -> ok;
        error -> ok;
        _ -> ssl:close(OutSocket)
    end,
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

make_notifications(PendingList) ->
    lists:foldl(
        fun({MessageId, {_, Payload, Token, _}}, Acc) ->
            PushMessage = {struct, [{xmpp, {struct, Payload}}]},
            EncodedMessage = iolist_to_binary(mochijson2:encode(PushMessage)),
            ?DEBUG("++++++ Encoded message: ~p", [EncodedMessage]),
            MessageLength = size(EncodedMessage),
            TokenLength = size(Token),
            Frame =
             <<1:1/unit:8, TokenLength:2/unit:8, Token/binary,
               2:1/unit:8, MessageLength:2/unit:8, EncodedMessage/binary,
               3:1/unit:8, 4:2/unit:8, MessageId:4/unit:8>>,
               %4:8, 4:16/big, ?MESSAGE_EXPIRY_TIME:4/big-unsigned-integer-unit:8,
               %5:8, 1:16/big, ?MESSAGE_PRIORITY:8>>,
            FrameLength = size(Frame),
            <<Acc/binary, <<2:1/unit:8, FrameLength:4/unit:8, Frame/binary>>/binary>>
        end,
        <<"">>,
        PendingList).

get_socket(OldSocket, CertFile, Gateway) ->
    case OldSocket of
        _Invalid when OldSocket =:= undefined;
                     OldSocket =:= error ->
            SslOpts =
            [{certfile, CertFile},
             {versions, ['tlsv1.2']},
             {ciphers, ?CIPHERSUITES},
             {reuse_sessions, true},
             {secure_renegotiate, true}],
             %{verify, verify_peer},
             %{cacertfile, CACertFile}],
            case ssl:connect(Gateway, ?APNS_PORT, SslOpts, ?SSL_TIMEOUT) of
                {ok, S} -> S;
                {error, E} -> {error, E}
            end;

       _ -> OldSocket
    end.

pending_to_retry(PendingList, RetryList) ->
    %% FIXME: keystore
    RetryList ++
    lists:map(
        fun({_, Element}) -> Element end,
        PendingList).

restart_retry_timer(OldTimer) ->
    erlang:cancel_timer(OldTimer),
    Timestamp = erlang:now(),
    NewTimer = erlang:send_after(?RETRY_INTERVAL, self(), {retry, Timestamp}),
    {NewTimer, Timestamp}.

% produces 4-byte message ids, used for error reporting
wrapping_successor(Max) when Max =:= (4294967296 - 1) -> 0;
wrapping_successor(OldMessageId) -> OldMessageId + 1.

enumerate_from(N0, Xs) ->
    lists:foldl(
      fun(X, {N, Acc}) ->
              N1 = wrapping_successor(N),
              {N1, [{N1, X}|Acc]}
      end,
      {N0, []},
      Xs).

enqueue_some(PendingList, SendList, MessageId) ->
    PendingSpace = ?MAX_PENDING_NOTIFICATIONS - length(PendingList),
    {NewPendingElements, NewSendList} =
        case length(SendList) > PendingSpace of
            true -> lists:split(PendingSpace, SendList);
            false -> {SendList, []}
        end,
    {NewMessageId, Result} = enumerate_from(MessageId, NewPendingElements),
    {PendingList ++ Result, NewSendList, NewMessageId}.


test() ->
    UserBare = {<<"jane">>,<<"localhost">>},
    Timestamp = now(),
    DisableArgs = {UserBare, Timestamp},
    Payload = [{body, <<"sup">>},
               {from, <<"john@localhost">>}],
    Token = <<"token">>,
    SendList = [{UserBare, Payload, Token, DisableArgs}],
    {NP, _NS, _NMID} = enqueue_some([], SendList, 0),
    make_notifications(NP).

%% Local Variables:
%% eval: (setq-local flycheck-erlang-include-path (list "../../../../src/ejabberd/include/"))
%% eval: (setq-local flycheck-erlang-library-path (list "/usr/local/Cellar/ejabberd/16.09/lib/cache_tab-1.0.4/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/ejabberd-16.09/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/esip-1.0.8/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/ezlib-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_tls-1.0.7/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_xml-1.1.15/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/fast_yaml-1.0.6/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/goldrush-0.1.8/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/iconv-1.0.2/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/jiffy-0.14.7/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/lager-3.2.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/luerl-1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_mysql-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_oauth2-0.6.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_pam-1.0.0/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_pgsql-1.0.1/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/p1_utils-1.0.5/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/stringprep-1.0.6/ebin" "/usr/local/Cellar/ejabberd/16.09/lib/stun-1.0.7/ebin"))
%% End:
