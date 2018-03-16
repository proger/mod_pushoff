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

-module(mod_pushoff_utils).

-author('dimskii123@gmail.com').

-compile(export_all).
-export([enqueue_some/4,
         enqueue_some/1,
         force_string/1]).

-include("logger.hrl").

-spec enqueue_some([any()], queue:queue(any()), pos_integer(), pos_integer())
                  -> {[any()], queue:queue(any()), pos_integer()}.

enqueue_some(PendingList, SendQ, MessageId, MaxPendingNotifications) ->
    ?INFO_MSG("enqueue_some(), PendingList = <~p>, SendQ = <~p>, MessageId = <~p>, MaxPendingNotifications = <~p>", [PendingList, SendQ, MessageId, MaxPendingNotifications]),
    PendingSpace = MaxPendingNotifications - length(PendingList),
    {NewPendingElements, NewSendQ} =
        case queue:len(SendQ) > PendingSpace of
            true ->
                {P, Q} = queue:split(PendingSpace, SendQ),
                {queue:to_list(P), Q};
            false ->
                {queue:to_list(SendQ), queue:new()}
        end,
    {NewMessageId, Result} = enumerate_from(MessageId, NewPendingElements),
    {PendingList ++ Result, NewSendQ, NewMessageId}.

-spec enqueue_some(queue:queue(any())) -> any().

enqueue_some(SendQ) -> % enqueue one element for fcm module
    case queue:out(SendQ) of
        {{value, Head}, NewSendQ} ->
            {Head, NewSendQ};
        {empty, _} ->
            empty
    end.

-spec enumerate_from(pos_integer(), [any()]) -> [{pos_integer(), any()}].

enumerate_from(N0, Xs) ->
    lists:foldl(
      fun(X, {N, Acc}) ->
              N1 = wrapping_successor(N),
              {N1, [{N1, X}|Acc]}
      end,
      {N0, []},
      Xs).

% produces 4-byte message ids, used for error reporting
wrapping_successor(Max) when Max =:= (4294967296 - 1) -> 0;
wrapping_successor(OldMessageId) -> OldMessageId + 1.

force_string(V) when is_binary(V) -> binary_to_list(V);
force_string(V) -> V.
