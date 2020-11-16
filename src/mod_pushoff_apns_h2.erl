%% @doc
%% This is a backend_worker-compatible gen_server that keeps a single http/2 connection to APNs.
%% Uses up to 1 streams to POST one message at a time in an almost fire-and-forget fashion.
%% You must spawn one such backend per topic (aka app) and APNs server host (i.e. sandbox or production).

-module(mod_pushoff_apns_h2).
-mode(compile).
-behaviour(gen_server).
-compile(export_all).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).

%-include("logger.hrl").
-define(ERROR_MSG(X,Y), io:format(X,Y)).
-define(WARNING_MSG(X,Y), io:format(X,Y)).
-define(DEBUG(X,Y), io:format(X,Y)).

-type token() :: binary(). %% token as a hex string
-type disable_args() :: any().
-type message() :: {dispatch, any(), any(), token(), disable_args()}.

-type sending() ::
    undefined | #{message := message(),
                  stream_id := integer(),
                  h2state := sent | have_headers | have_data,
                  headers := undefined | [mod_pushoff_h2:header()],
                  data := undefined | binary()}.

-type state() ::
    #{send_queue := queue:queue(message()),
      connection := pid(),
      certfile := string(),
      apns := binary(), %% hostname
      topic := binary(), %% APNs Topic
      sending := sending()}.

init(#{backend_type := ?MODULE, certfile := Certfile, gateway := APNS, topic := Topic}) ->
    {ok, #{send_queue => queue:new(), connection => undefined, certfile => erlang:binary_to_list(Certfile), apns => APNS, topic => erlang:iolist_to_binary(Topic), sending => undefined}}.

handle_cast({dispatch, _UserBare, _Payload, Token, _DisableArgs} = M, #{send_queue := Q} = State) ->
    case Token of
        <<"babababababababababababababababababababababababababababababababa">> ->
            {noreply, State}; %% magic simulator token, ignore
        _ ->
            self() ! dequeue,
            {noreply, State#{send_queue => queue:in(M, Q)}}
    end;

handle_cast(_Req, State) ->
    {noreply, State}.

handle_call(_Req, _From, State) ->
    {reply, {error, badarg}, State}.

handle_info({'EXIT', From, Reason}, #{connection := From} = State) when is_pid(From) ->
    ?ERROR_MSG("mod_pushoff_apns_h2 connection terminated ~p", [Reason]),
    {noreply, do_connect(State)};

handle_info(dequeue, #{connection := undefined} = State) ->
    self() ! dequeue,
    {noreply, do_connect(State)};
handle_info(dequeue, #{sending := #{}} = State) ->
    {noreply, State};
handle_info(dequeue, #{connection := Connection, send_queue := Q, apns := APNS, topic := Topic, sending := undefined} = State) ->
    case queue:out(Q) of
        {empty, Q} -> {noreply, State};
        {{value, M}, Q2} -> {noreply, State#{sending => do_send(M, APNS, Topic, Connection), send_queue => Q2}}
    end;

handle_info({'RECV_HEADERS', StreamId, RecvHeaders}, #{sending := #{message := _, stream_id := StreamId} = ReqState} = State) ->
    {noreply, State#{sending => ReqState#{h2state => have_headers, headers => RecvHeaders}}};
handle_info({'RECV_DATA', StreamId, RecvData, false, false}, #{sending := #{message := _, stream_id := StreamId} = ReqState} = State) ->
    {noreply, State#{sending => ReqState#{h2state => have_data, data => RecvData}}};
handle_info({'END_STREAM', StreamId}, #{sending := #{message := _, stream_id := StreamId}} = State) ->
    do_handle_response(State);
handle_info({'RESET_BY_PEER', StreamId, Code}, #{sending := #{message := _, stream_id := StreamId}} = State) ->
    ?WARNING_MSG("stream reset by peer with code ~p~n", [Code]),
    do_handle_response(State);
handle_info({'CLOSED_BY_PEER', StreamId, Code}, #{sending := #{message := _, stream_id := StreamId}} = State) ->
    ?WARNING_MSG("stream reset by peer with code ~p~n", [Code]),
    do_handle_response(State);

handle_info(Info, State) ->
    ?DEBUG("mod_pushoff_apns_h2 received unexpected message ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #{connection := undefined} = State) -> loss_report(State), ok;
terminate(_Reason, #{connection := Connection} = State) -> loss_report(State), mod_pushoff_h2:close(Connection), ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

loss_report(#{send_queue := Q}) ->
    ?WARNING_MSG("mod_pushoff_apns_h2 lost ~p messages~n", [queue:len(Q)]).

do_handle_response(#{sending := #{message := M, stream_id := _StreamId, headers := Headers, data := Data}, connection := Connection, send_queue := Q} = State) ->
    case response_status(Headers, Data) of
        unregistered ->
            {dispatch, _UserBare, _Payload, _Token, DisableArgs} = M,
            mod_pushoff_mnesia:unregister_client(DisableArgs), % TODO: maybe sweep the queue for similar messages?
            self() ! dequeue,
            {noreply, State#{sending => undefined}};
        transient ->
            mod_pushoff_h2:close(Connection),
            self() ! dequeue,
            {noreply, State#{sending => undefined, connection => undefined, send_queue => queue:in_r(M, Q)}};
        crash ->
            {stop, unrecoverable, State};
        ok ->
            self() ! dequeue,
            {noreply, State#{sending => undefined}}
    end.

do_send(M, APNS, Topic, Connection) ->
    {Headers, Payload} = make_request(APNS, Topic, M),
    {ok, StreamId} = mod_pushoff_h2:new_stream(Connection, []),
    ok = mod_pushoff_h2:send_headers(Connection, StreamId, Headers, []),
    ok = mod_pushoff_h2:send_data(Connection, StreamId, Payload, [{end_stream, true}]),
    #{message => M, stream_id => StreamId, h2state => sent, headers => undefined, data => undefined}.

do_connect(#{certfile := Certfile, apns := APNS, topic := Topic, sending := Sending} = State) ->
    {ok, Connection} = mod_pushoff_h2:new_connection(ssl, erlang:binary_to_list(APNS), 443,
        [{max_concurrent_streams, 1}, {transport_options, [{certfile, Certfile}, {alpn_advertised_protocols,[<<"h2">>]}]}]),
    Sending1 = case Sending of
        undefined -> undefined;
        #{message := M} -> do_send(M, APNS, Topic, Connection)
    end,
    State#{connection => Connection, sending => Sending1}.

response_status([{<<":status">>, Status}|_] = Headers, Data) ->
    case status(Status) of
        ok -> ok;
        unregistered -> unregistered;
        bad_request ->
            case Data of
                <<"{\"reason\":\"BadDeviceToken\"}">> ->
                    unregistered;
                _ -> ?ERROR_MSG("mod_pushoff_apns_h2 bad request: ~p", [{Headers, Data}]), crash
            end;
        authentication_error -> ?ERROR_MSG("mod_pushoff_apns_h2 bad authentication (wrong or expired certfile?): ~p", [{Headers, Data}]), crash;
        too_many_requests -> ok; % one device is receiving too many messages; silently dropping
        internal_server_error -> transient;
        server_unavailable -> transient
    end.

post(Host, Path) ->
    [{<<":method">>,<<"POST">>}, {<<":scheme">>,<<"https">>}, {<<":authority">>,Host}, {<<":path">>,Path}].

alert_headers(APNS, Topic, RawToken, Id) ->
    Token = to_hex(RawToken),
    post(APNS, <<"/3/device/", Token/binary>>)
      ++ [{<<"apns-push-type">>,<<"alert">>}, {<<"apns-topic">>,Topic}, {<<"apns-priority">>,<<"10">>},
          {<<"apns-collapse-id">>,Id}]. %% XXX: max allowed length of Id is 64 bytes, we use commonly use UUIDs with a 4-char prefix

payload(Id) ->
    iolist_to_binary([<<"{ \"aps\" : { \"alert\" : \"Incoming Message\", \"mutable-content\": 1, \"sound\": \"default\" }, \"message-id\": \"">>, Id, <<"\" }">>]).

make_request(APNS, Topic, {dispatch, _UserBare, [{id, Id}], Token, _DisableArgs}) -> {alert_headers(APNS, Topic, Token, Id), payload(Id)}.

% https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/handling_notification_responses_from_apns
status(<<"200">>) -> ok;
status(<<"400">>) -> bad_request;
status(<<"403">>) -> authentication_error; %% config error
status(<<"405">>) -> throw(method_not_allowed);
status(<<"410">>) -> unregistered; %% important
status(<<"413">>) -> throw(payload_too_large);
status(<<"429">>) -> too_many_requests;
status(<<"500">>) -> internal_server_error;
status(<<"503">>) -> server_unavailable.

to_hex(B) -> to_hex(B, []).

to_hex(<<>>, Acc) -> erlang:iolist_to_binary(lists:reverse(Acc));
to_hex(<<C1:4, C2:4, Rest/binary>>, Acc) -> to_hex(Rest, [hexdigit(C2), hexdigit(C1) | Acc]).

%% @spec hexdigit(integer()) -> char()
hexdigit(C) when C >= 0, C =< 9 -> C + $0;
hexdigit(C) when C =< 15 -> C + $a - 10.

receiveall() ->
    receive X -> io:format("================== ~p~n", [X]), receiveall() end.

main([Host, Certfile, Topic, Token]) ->
    ssl:start(),
    dbg:tracer(),
    dbg:p(new, m),
    {ok, Pid} = gen_server:start_link(?MODULE, #{backend_type => apns, certfile => Certfile, gateway => iolist_to_binary(Host), topic => iolist_to_binary(Topic)}, []),
    gen_server:cast(Pid, {dispatch, undefined, undefined, iolist_to_binary(Token), undefined}),
    erlang:send_after(0, self(), {?MODULE, Pid}),
    receiveall().

% vim: set sts=4 et sw=4:
