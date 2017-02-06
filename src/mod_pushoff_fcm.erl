%%%
%%% Copyright (C) 2015  Christian Ulrich
%%% Copyright (C) 2016  Vlad Ki
%%% Copyright (C) 2017  Dima Stolpakov =)
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

%% This implements the "legacy" binary API

-module(mod_pushoff_fcm).

-author('christian@rechenwerk.net').
-author('proger@wilab.org.ua').
-author('dimskii123@gmail.com').

-behaviour(gen_server).
-compile(export_all).
-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

-include("logger.hrl").

-define(MAX_PAYLOAD_SIZE, 2048).
-define(MESSAGE_EXPIRY_TIME, 86400).
-define(MESSAGE_PRIORITY, 10).
-define(MAX_PENDING_NOTIFICATIONS, 1).
-define(PENDING_INTERVAL, 1).
-define(RETRY_INTERVAL, 30000).
-define(PUSH_URL, "https://fcm.googleapis.com/fcm/send").

-record(state,
        {pending_list :: [{pos_integer(), any()}],
         send_queue :: queue:queue(any()),
         retry_list :: [any()],
         pending_timer :: reference(),
         retry_timer :: reference(),
         pending_timestamp :: erlang:timestamp(),
         retry_timestamp :: erlang:timestamp(),
         message_id :: pos_integer(),
         gateway :: string(),
         api_key :: string()}).

init([Gateway, ApiKey]) ->
    ?INFO_MSG("+++++++++ mod_pushoff_fcm:init, gateway <~p>, ApiKey <~p>", [Gateway, ApiKey]),
    inets:start(),
    crypto:start(),
    ssl:start(),
    {ok, #state{pending_list = [],
                send_queue = queue:new(),
                retry_list = [],
                pending_timer = make_ref(),
                retry_timer = make_ref(),
                message_id = 0,
                gateway = mod_pushoff_utils:force_string(Gateway),
                api_key = "key=" ++ mod_pushoff_utils:force_string(ApiKey)}}.

handle_info({retry, StoredTimestamp},
            #state{send_queue = SendQ,
                   retry_list = RetryList,
                   pending_timer = PendingTimer,
                   retry_timestamp = StoredTimestamp} = State) ->
    case erlang:read_timer(PendingTimer) of
        false -> self() ! send;
        _ -> meh
    end,
    {noreply,
     State#state{send_queue = lists:foldl(fun(E, Q) -> queue:snoc(Q, E) end, SendQ, RetryList),
                 retry_list = []}};

handle_info({retry, _T1}, #state{retry_timestamp = _T2} = State) ->
    {noreply, State};

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

handle_info(send, #state{pending_list = PendingList,
                         send_queue = SendQ,
                         retry_list = RetryList,
                         retry_timer = RetryTimer,
                         message_id = MessageId,
                         gateway = Gateway,
                         api_key = ApiKey} = State) ->
            {NewPendingList,
             NewSendQ,
             NewMessageId} = mod_pushoff_utils:enqueue_some(PendingList, SendQ, MessageId, ?MAX_PENDING_NOTIFICATIONS),

            NewState = 
            case NewPendingList of
                [] ->
                    State#state{pending_list = NewPendingList,
                                send_queue = NewSendQ,
                                message_id = NewMessageId};

                _ ->

                    HTTPOptions = [],
                    Options = [],
                    
                    [Head | _] = NewPendingList,
                    Body = case Head of 
                        {_MessageId, {_, _Payload, _Token, _}} ->
                            _Body = proplists:get_value(body, _Payload),
                            _From = proplists:get_value(from, _Payload),
                            PushMessage = {struct, [
                                                    {to,           _Token},
                                                    {data,         {struct, [
                                                                             {body, _Body},
                                                                             {title, _From}
                                                                            ]}},
                                                    {notification, {struct, [
                                                                             {body, _Body},
                                                                             {title, _From}
                                                                            ]}}
                                                   ]},
                            iolist_to_binary(mochijson2:encode(PushMessage));
                        _ ->
                            ?ERROR_MSG("no pattern for matching for pending list", []),
                            unknown
                    end,


                    Request = {Gateway, [{"Authorization", ApiKey}], "application/json", Body},
                    Response = httpc:request(post, Request, HTTPOptions, Options),
                    case Response of
                              {ok, {{_, StatusCode5xx, _}, _, ErrorBody5xx}} when StatusCode5xx >= 500, StatusCode5xx < 600 ->
                                    ?DEBUG("recoverable FCM error: ~p, retrying...", [ErrorBody5xx]),
                                    {NewPendingList1, NewRetryList} = pending_to_retry(NewPendingList, RetryList),
                                    {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                                    State#state{pending_list = NewPendingList1,
                                                retry_list = NewRetryList,
                                                send_queue = NewSendQ,
                                                retry_timer = NewRetryTimer,
                                                message_id = NewMessageId,
                                                retry_timestamp = Timestamp};
%==============================================================================================================
                              {ok, {{_, 200, _}, _, ResponseBody}} ->
                                    ?DEBUG("+++++ raw response: StatusCode = ~p, Body = ~p", [200, ResponseBody]),
                                    Timestamp = erlang:timestamp(),
                                    NewPendingTimer = erlang:send_after(?PENDING_INTERVAL, self(),
                                                                        {pending_timeout, Timestamp}),
                                    State#state{pending_list = NewPendingList,
                                                send_queue = NewSendQ,
                                                pending_timer = NewPendingTimer,
                                                message_id = NewMessageId,
                                                pending_timestamp = Timestamp};

                              {ok, {{_, _, _}, _, ResponseBody}} ->
                                    ?DEBUG("non-recoverable FCM error: ~p, delete registration", [ResponseBody]),
                                    {NewPendingList1, NewRetryList} = pending_to_retry(NewPendingList, RetryList),
                                    {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                                    State#state{pending_list = NewPendingList1,
                                                retry_list = NewRetryList,
                                                send_queue = NewSendQ,
                                                retry_timer = NewRetryTimer,
                                                message_id = NewMessageId,
                                                retry_timestamp = Timestamp};

                              {error, Reason} ->
                                    ?ERROR_MSG("FCM request failed: ~p, retrying...", [Reason]),
                                    {NewPendingList1, NewRetryList} = pending_to_retry(NewPendingList, RetryList),
                                    {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                                    State#state{pending_list = NewPendingList1,
                                                retry_list = NewRetryList,
                                                send_queue = NewSendQ,
                                                retry_timer = NewRetryTimer,
                                                message_id = NewMessageId,
                                                retry_timestamp = Timestamp}
                    end
            end,
    {noreply, NewState};

handle_info(Info, State) ->
    ?DEBUG("+++++++ mod_pushoff_fcm received unexpected signal ~p", [Info]),
    {noreply, State}.

handle_call(_Req, _From, State) -> {reply, {error, badarg}, State}.

handle_cast({dispatch, UserBare, Payload, Token, DisableArgs},
            #state{send_queue = SendQ,
                   pending_timer = PendingTimer,
                   retry_timer = RetryTimer} = State) ->
    case {erlang:read_timer(PendingTimer), erlang:read_timer(RetryTimer)} of
        {false, false} -> self() ! send;
        _ -> ok
    end,
    {noreply,
     State#state{send_queue = queue:snoc(SendQ, {UserBare, Payload, Token, DisableArgs})}};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

terminate(_Reason, #state{}) ->
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

restart_retry_timer(OldTimer) ->
    erlang:cancel_timer(OldTimer),
    Timestamp = erlang:timestamp(),
    NewTimer = erlang:send_after(?RETRY_INTERVAL, self(), {retry, Timestamp}),
    {NewTimer, Timestamp}.

-spec pending_to_retry([any()], [any()]) -> {[any()], [any()]}.

pending_to_retry(PendingList, RetryList) -> {[], RetryList ++ [E || {_, E} <- PendingList]}.
