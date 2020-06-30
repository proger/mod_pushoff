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

-define(RETRY_INTERVAL, 30000).

-record(state,
        {send_queue :: queue:queue(any()),
         retry_list :: [any()],
         pending_timer :: reference(),
         retry_timer :: reference(),
         pending_timestamp :: erlang:timestamp(),
         retry_timestamp :: erlang:timestamp(),
         gateway :: string(),
         api_key :: string()}).

init([Gateway, ApiKey]) ->
    inets:start(),
    crypto:start(),
    ssl:start(),
    {ok, #state{send_queue = queue:new(),
                retry_list = [],
                pending_timer = make_ref(),
                retry_timer = make_ref(),
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

handle_info(send, #state{send_queue = SendQ,
                         retry_list = RetryList,
                         retry_timer = RetryTimer,
                         gateway = Gateway,
                         api_key = ApiKey} = State) ->

    NewState =
    case mod_pushoff_utils:enqueue_some(SendQ) of
        empty ->
            State#state{send_queue = SendQ};
        {Head, NewSendQ} ->
            HTTPOptions = [],
            Options = [],

            {Body, DisableArgs} = pending_element_to_json(Head),

            Request = {Gateway, [{"Authorization", ApiKey}], "application/json", Body},
            Response = httpc:request(post, Request, HTTPOptions, Options), %https://firebase.google.com/docs/cloud-messaging/http-server-ref
            case Response of
                {ok, {{_, StatusCode5xx, _}, _, ErrorBody5xx}} when StatusCode5xx >= 500, StatusCode5xx < 600 ->
                      ?INFO_MSG("recoverable error: ~p, retrying...", [ErrorBody5xx]),
                      NewRetryList = pending_to_retry(Head, RetryList),
                      {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                      State#state{retry_list = NewRetryList,
                                  send_queue = NewSendQ,
                                  retry_timer = NewRetryTimer,
                                  retry_timestamp = Timestamp};

                {ok, {{_, 200, _}, _, ResponseBody}} ->
                      case parse_response(ResponseBody) of
                          ok -> ok;
                          E ->
                              ?ERROR_MSG("error: ~p, deleting registration", [E]),
                              mod_pushoff_mnesia:unregister_client(DisableArgs)
                      end,
                      Timestamp = erlang:timestamp(),
                      State#state{send_queue = NewSendQ,
                                  pending_timestamp = Timestamp};

                {ok, {{_, _, _}, _, ResponseBody}} ->
                      ?ERROR_MSG("error: ~p, deleting registration", [ResponseBody]),
                      mod_pushoff_mnesia:unregister_client(DisableArgs),
                      Timestamp = erlang:timestamp(),
                      State#state{send_queue = NewSendQ,
                                  pending_timestamp = Timestamp};

                {error, Reason} ->
                      ?ERROR_MSG("request failed: ~p, retrying...", [Reason]),
                      NewRetryList = pending_to_retry(Head, RetryList),
                      {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                      State#state{retry_list = NewRetryList,
                                  send_queue = NewSendQ,
                                  retry_timer = NewRetryTimer,
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

-spec pending_to_retry(any(), [any()]) -> {[any()]}.

pending_to_retry(Head, RetryList) -> RetryList ++ Head.

pending_element_to_json({_, Payload, Token, DisableArgs}) ->
    Body = proplists:get_value(body, Payload),
    From = proplists:get_value(from, Payload),
    BF = [{body, Body}, {title, From}],
    PushMessage = {[{to,           Token},
                    {priority,     <<"high">>},
                    {data,         {BF}}
                    %% If you need notification in android system tray, use:
                    %%, {notification, {BF}}
                   ]},
    {jiffy:encode(PushMessage), DisableArgs};

pending_element_to_json(_) ->
    unknown.

parse_response(ResponseBody) ->
    try jiffy:decode(ResponseBody) of
        {JsonData} ->
            case proplists:get_value(<<"success">>, JsonData) of
                1 -> ok;
                0 -> [{Result}] = proplists:get_value(<<"results">>, JsonData),
                     {error, proplists:get_value(<<"error">>, Result)}
            end;
        Bad -> {error, Bad}
    catch throw:E -> E end.
