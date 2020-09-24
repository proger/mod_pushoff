%% http2_client - A HTTP/2 client which caters to the requirements of GRPC
%% Copyright 2017 Bluehouse Technology Ltd.
%%%-------------------------------------------------------------------
%%% Licensed to the Apache Software Foundation (ASF) under one
%%% or more contributor license agreements.  See the NOTICE file
%%% distributed with this work for additional information
%%% regarding copyright ownership.  The ASF licenses this file
%%% to you under the Apache License, Version 2.0 (the
%%% "License"); you may not use this file except in compliance
%%% with the License.  You may obtain a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%

%% @doc
%% A minimal HTTP/2 client to support gRPC.
%% 
%% ```
%% The client implements only those features that are required by gRPC, it is
%% not a complete implementation of the HTTP/2 spec. In particular is does not
%% support:
%% - Push promise. The gRPC protocol does not use it.
%%
%%   The initial SETTINGS frame sent by the client will disable push promise 
%%   messages, and if a push promise is received from the server this will
%%   result in a protocol error.
%%
%% - Priorization and dependency between streams. The API will not offer any
%%   support for sending PRIORITY frames to the server, and any PRIORITY
%%   frame that is received will be ignored.
%%
%% General structure:
%% Starting a new connection will spawn a process. This process opens a
%% socket. The socket is set to 'active_once', so that it will send messages
%% to the connection process. The api will also send messages to the
%% process, in order to send or retrieve messages.
%%
%% (Note that there may be another process involved in the gRPC framework 
%% to deal with streams, in order to be able to provide a synchronous API on
%% that level).
%%
%% The connection process will manage the following information:
%% - socket (so that the certificate and other properties can be accessed)
%% - streams, each with its own set of information
%% - flow control information on the level of the connection, for both sides
%%   (client and server).
%% - header compression contexts: "One compression context and one 
%%   decompression context are used for the entire connection." (All HEADERS
%%   and CONTINUATION frames must be decompressed! Even PUSH_PROMISE frames 
%%   must be decompressed, otherwise this will be screwed.)
%% - Settings, as exchanged via SETTINGS frames. Both for the client and for
%%   the server side.
%%     - MAX_CONCURRENT_STREAMS (if we want to support it)
%%     - INITIAL_FLOW_CONTROL_WINDOW
%%     - SETTINGS_HEADER_TABLE_SIZE 
%%     (- SETTINGS_ENABLE_PUSH - Client will always disable it, server is
%%       irrelevant)
%%     - SETTINGS_INITIAL_WINDOW_SIZE 
%%     - SETTINGS_MAX_FRAME_SIZE 
%%     - SETTINGS_MAX_HEADER_LIST_SIZE (perhaps this can be igored)
%% - Id of the last stream created, so that the correct id can be assigned
%%   to the next stream.
%%
%% for each stream it will manage:
%% - stream id
%% - state (idle, open, half-open)
%% - flow control information on the level of the connection, for both sides
%%   (client and server).
%%
%% flow control information will be:
%% - remaining bytes in window - what can still be sent/received (client and server)
%% - window size (client and server)
%% For the client side also information for the management of the flow
%% control is required: a callback function and its state.
%%
%% When the socket receives a packet, it will send a message to the connection
%% process (because of the active_once setting).  This will take care of the
%% http/2 framing and if it decides that a complete frame has been received,
%% it will send a message to the process that created the stream.  (Note
%% that that is not the Connection process itself, which receives the
%% messages from the socket). 
%%
%% The picture below shows how grpc_client interfaces with http2_client. http2_client 
%% can of course also be used by other applications that need a simple http/2 client.
%%
%%                +<--scope of--->+<------- scope of http2_client -------->+
%%                +  grpc_client  +                                        +
%%                +               +                                        +
%%    Application +               +    Connection               Socket     +     Server
%%         |      +               +        |                      |        +        |           
%%         |------+-----new-------+------>| |                     |        +        |           
%%         |      +    host, scheme       | |-------new--------->| |       +        |           
%%         |      +               +       | |                    | |--connect----> | |          
%%         |      +               +       | |                    | |       +        |           
%%         |<-----+----c_pid------+-------| |                    | |       +        |           
%%         |      +               +        |                      |        +        |           
%%         |      +    Stream     +        |                      |        +        |           
%%         |      +       |       +        |                      |        +        |           
%%         |-----new---->| |      +        |                      |        +        |           
%%         |    c_pid    | |--new stream->| |                     |        +        |           
%%         |      +      | |    s_pid     | |-------preface----->| |       +        |
%%         |      +      | |      +       | |      +settings     | |-------+------->|
%%         |      +      | |      +       | |                     |        +        |           
%%         |      +      | |      +       | |                    | |<---settings----|           
%%         |      +      | |      +       | |<-------------------| |       +        |           
%%         |      +      | |      +       | |                     |        +        |           
%%         |      +      | |      +       | |                    | |<-----ack-------|           
%%         |      +      | |      +       | |<-------------------| |       +        |           
%%         |      +      | |      +       | |                     |        +        |           
%%         |      +      | |      +       | |--------ack-------->| |       +        |           
%%         |      +      | |      +       |Register stream       | |       +        |           
%%         |<----s_pid---| |<-----ok------| |                    | |-------+------->|           
%%         |      +       |       +        |                      |        +        |           
%%         |      +       |       +        |                      |        +        |           
%%         |-----send--->| |      +        |                      |        +        |           
%%         |      +      | |------+------>| |                     |        +        |           
%%         |      +       |       +       | |-------message----->| |       +        |           
%%         |-----rcv---->| |      +        |                     | |-------+------->|           
%%         |      +      |Wait... +        |                      |        +        |
%%         |      +      | |      +        |                      |        +        |
%%         |      +      | |      +        |                      |        +        |
%%         |      +      | |      +        |                     | |<---message-----|           
%%         |      +      | |      +       | |<-------------------| |       +        |           
%%         |      +      | |      +       |Find stream           | |       +        |           
%%         |      +      | |<-----+-------| |                    | |       +        |           
%%         |<-----+------| |      +        |                      |        +        |           
%%         |      +       |       +        |                      |        +        |           
%%         |      +       |       +        |                      |        +        |           '''

-module(mod_pushoff_h2).

-behaviour(gen_server).

-export([new_connection/4, 
         new_stream/2,
         send_headers/4,
         send_data/4,
         rst_stream/3,
         connection_window_update/2,
         stream_window_update/3,
         ping/1, ping/2,
         close/1,
         peercert/1]).

-define(MAX_WINDOW_SIZE, 2147483647).
-define(STREAM_COOL_OFF_PERIOD, 3000). %% Period a stream is kept in 'closed'
                                       %% state before cleanup (microseconds).

%% defaults
-define(INITIAL_WINDOW_SIZE, 65535).
-define(MAX_FRAME_SIZE, 16384).

%% Error codes
-define(NO_ERROR, 16#0).
-define(PROTOCOL_ERROR, 16#1).
-define(INTERNAL_ERROR, 16#2).
-define(FLOW_CONTROL_ERROR, 16#3).
-define(SETTINGS_TIMEOUT, 16#4).
-define(STREAM_CLOSED, 16#5).
-define(FRAME_SIZE_ERROR, 16#6).
-define(REFUSED_STREAM, 16#7).
-define(CANCEL, 16#8).
-define(COMPRESSION_ERROR, 16#9).
-define(CONNECT_ERROR, 16#a).
-define(ENHANCE_YOUR_CALM, 16#b).
-define(INADEQUATE_SECURITY, 16#c).

%% Flags
-define(ACK, 16#1).
-define(END_STREAM, 16#1).
-define(END_HEADERS, 16#4).
-define(PADDED, 16#8).
-define(PRIORITY_F, 16#20).

%% Frame types
-define(DATA, 16#0).
-define(HEADERS, 16#1).
-define(RST_STREAM, 16#3).
-define(SETTINGS, 16#4).
-define(PING, 16#6).
-define(GOAWAY, 16#7).
-define(WINDOW_UPDATE, 16#8).
-define(CONTINUATION, 16#9).

-type stream_id() :: integer().
-type header() :: [{Name::binary, Value::binary()}].
-type send_option() :: {end_stream, boolean()}.

-type window_manager() :: fun((integer(), %% Current window
                               integer(), %% Initial window
                               integer(), %% Frame size
                               any()) -> {{window_update, integer()}, any} |
                                         {ok, any()}).

-type connection_option() ::
    {window_mgmt_fun, window_manager()} |
    {window_mgmt_data, any()} |
    {max_concurrent_streams, integer() | undefined} |
    {initial_window_size, integer()} |
    {max_frame_size, integer()} |
    {transport_options, [ssl:ssl_option()] | [gen_tcp:option()]}.

-type stream_option() ::
    {window_mgmt_fun, fun()} |
    {window_mgmt_data, any()}.

-type settings() ::
    #{max_concurrent_streams := integer() | undefined,
      initial_window_size := integer(),
      max_frame_size := integer()}.

-type continuation_data() ::
    #{stream_id => integer(),
      buffer := binary(),
      end_stream := boolean()}.

-type stream() ::
    #{id := integer(),
      client_window := integer(),  %% Nr of bytes that the client is willing to 
                                   %% process for this stream
      window_mgmt_fun := fun(),    %% Function to be called to manage the client
                                   %% window.
      window_mgmt_data := any(),   %% Data to be passed to window_mgmt_fun.
      server_window := integer(),  %% Nr of bytes that can still be sent to
                                   %% server for this stream.
      owner := pid()}.

-type connection() ::
    #{socket := gen_tcp:socket() | ssl:sslsocket(),
      state := open | closed_by_peer,
      buffer := <<>>,
      host := string(),
      port := integer(),
      transport := gen_tcp | ssl,
      streams := [stream()],
      client_settings := settings(),
      server_settings := settings(),
      client_window := integer(),  %% Nr of bytes that the client is willing to 
                                   %% process
      window_mgmt_fun := fun(),    %% Function to be called to manage the client
                                   %% window.
      window_mgmt_data := any(),   %% Data to be passed to window_mgmt_fun.
      server_window := integer(),  %% Nr of bytes that can still be sent to srvr
      decode_state := mod_pushoff_cow_hpack:state(),
      encode_state := mod_pushoff_cow_hpack:state(),
      last_stream := integer(),
      continuation := continuation_data() | undefined,
      ping_sent := [{binary(),     %% the opaque data that was sent
                     integer()}],  %% the time when it was sent
      stream_count := integer()}.

-export_type([connection_option/0,
              stream_option/0]).

%% exports for internal use
-export([window_mgr/4]).

%% gen_server behaviors
-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

%% API
-spec new_connection(Transport::tcp | ssl,
                     Host::string(),
                     Port::integer(),
                     Options::[connection_option()]) -> {ok, connection()} |
                                                        {error, term()}.
%% @doc Open a new connection.
new_connection(Transport, Host, Port, Options) ->
    process_flag(trap_exit, true),
    gen_server:start_link(?MODULE, {Transport, Host, Port, Options, self()}, []).

-spec close(connection()) -> ok.
%% @doc Close (stop/clean up) the connection.
close(Pid) ->
    gen_server:stop(Pid).

-spec new_stream(Connection::connection(),
                 Options::[stream_option()]) -> {ok, stream_id()} |
                                                {error, term()}.
%% @doc Create a new stream.
new_stream(Connection, Options) ->
    gen_server:call(Connection, {new_stream, Options}).

-spec send_headers(connection(), stream_id(), [header()],
                   Options::[send_option()]) -> ok | {error, term()}.
%% @doc Send headers.
send_headers(Pid, StreamId, Headers, Options) ->
    gen_server:call(Pid, {send_headers, StreamId, Headers, Options}).

-spec send_data(connection(), stream_id(), Data::binary(),
                Options::[send_option()]) -> ok | {error, term()}.
%% @doc Send a data frame.
send_data(Pid, StreamId, Data, Options) ->
    gen_server:call(Pid, {send_data, StreamId, Data, Options}).

-spec rst_stream(connection(), stream_id(), ErrorCode::integer()) -> 
  ok | {error, term()}.
%% @doc Send a RST_STREAM frame
rst_stream(Pid, StreamId, ErrorCode) ->
    gen_server:call(Pid, {rst_stream, StreamId, ErrorCode}).

-spec connection_window_update(connection(), Increment::integer()) ->
    ok | {error, term()}.
%% @doc Increment the connection window. Note that this typically handled via the 
%% window management function (either a custom one if that has been provided 
%% when the stream was created, or the default one).
connection_window_update(Pid, Increment) ->
    gen_server:call(Pid, {connection_window_update, Increment}).

-spec stream_window_update(connection(), stream_id(), Increment::integer()) ->
    ok | {error, term()}.
%% @doc Increment the stream window. Note that this typically handled via the 
%% window management function (either a custom one if that has been provided 
%% when the stream was created, or the default one).
stream_window_update(Pid, StreamId, Increment) ->
    gen_server:call(Pid, {stream_window_update, StreamId, Increment}).

-spec ping(Connection::pid()) ->
    {ok, RoundTripTime::integer()} | {error, term()}.
%% @equiv ping(Connection, infinity)
ping(Pid) ->
    ping(Pid, infinity).

-spec ping(Connection::pid(), Timeout::timeout()) ->
    {ok, RoundTripTime::integer()} | {error, term()}.
%% @doc Send a PING frame.
%%
%% The PING frame is a mechanism for measuring a minimal round-trip time from
%% the sender, as well as determining whether an idle connection is still
%% functional.
%%
%% Will return {error, timeout} if no answer was received within the specified
%% period.
ping(Pid, Timeout) ->
    gen_server:call(Pid, {ping, Timeout}).

-spec peercert(pid()) -> {ok, Cert::binary()} | {error, Reason::term()}.
%% @doc The peer certificate is returned as a DER-encoded binary.
%% The certificate can be decoded with public_key:pkix_decode_cert/2.
peercert(Pid) ->
    gen_server:call(Pid, peercert).

%% @private
%% This is the default window management function. It tops up the window to 
%% its initial size if the remaining window is less than half the original 
%% window.
window_mgr(CurrentWindow, InitialWindow, FrameSize, Data) 
  when CurrentWindow < InitialWindow div 2 orelse
       CurrentWindow < FrameSize ->
    {{window_update, InitialWindow - CurrentWindow}, Data};
window_mgr(_CurrentWindow, _InitialWindow, _, Data) ->
    {ok, Data}.

%% gen_server implementation

%% @private
init({Transport0, Host, Port, Options, Owner}) ->
    Transport = map_transport(Transport0),
    {TransportOptions, H2Opts} = 
        case lists:keytake(transport_options, 1, Options) of
            {value, {_, TOpts}, OtherOptions} ->
                {TOpts, OtherOptions};
            false ->
                {[], Options}
        end,
    ConnectResult = Transport:connect(Host, Port,
                                      TransportOptions ++ default_opts(Transport)),
    case ConnectResult of
        {ok, Socket} ->
            new_connection(
              #{socket => Socket,
                owner => Owner,
                host => Host,
                port => Port,
                state => open,
                buffer => <<>>,
                window_mgmt_fun => proplists:get_value(window_mgmt_fun,
                                                       H2Opts, fun window_mgr/4),
                window_mgmt_data => proplists:get_value(window_mgmt_fun,
                                                        H2Opts, undefined),
                transport => Transport,
                server_settings => default_settings(),
                client_window => ?INITIAL_WINDOW_SIZE,
                server_window => ?INITIAL_WINDOW_SIZE,
                streams => [],
                continuation_data => undefined,
                last_stream => 0, %% The last stream identifier can be 
                                  %% set to 0 if no streams were processed.
                ping_sent => [],
                stream_count => 0,
                timeout => 3000   %% milliseconds
               }, H2Opts);
        {error, Error} ->
            {stop, Error}
    end.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec handle_call(term(), pid(), connection()) ->
    {reply, term(), connection()}.
%% @private
handle_call(peercert, _From, #{transport := ssl, socket := Socket} = C) ->
    {reply, ssl:peercert(Socket), C};
handle_call(peercert, _From, C) ->
    {reply, {error, not_an_ssl_socket}, C};

handle_call({ping, Timeout}, From, C) ->
    OpaqueData = list_to_binary([rand:uniform(255) || _ <- lists:seq(1,8)]),
    do_ping(C, OpaqueData, From, Timeout);

handle_call({new_stream, _}, _From,
            #{state := closed_by_peer} = C) ->
    {reply, {error, connection_closed_for_new_streams}, C};
handle_call({new_stream, _}, _From,
            #{server_settings := #{max_concurrent_streams := Max},
              stream_count := Count} = C) when Count >= Max ->
    {reply, {error, no_more_streams_allowed_by_server}, C};
handle_call({new_stream, Options}, From, #{streams := Streams,
                                           stream_count := Count} = C) ->
    case new_stream(C, From, Options) of
        {ok, #{id := Id} = Stream} -> 
            {reply, {ok, Id}, C#{last_stream => Id,
                                 streams => [{Id, Stream} | Streams],
                                 stream_count => Count + 1}};
        {error, _} = Error ->
            {reply, Error, C}
    end;

%% HEADERS frames can be sent on a stream in the "idle", "reserved (local)",
%% "open", or "half-closed (remote)" state.

handle_call({send_headers, StreamId, Headers, Options}, _From,
            #{streams := Streams} = C) ->
    case find_stream(StreamId, Streams) of
        not_found ->
            {reply, {error, stream_not_found}, C};
        #{state := Status} when Status == half_closed_local ->
            {reply, {error, stream_closed_for_sending}, C};
        #{} = Stream ->
            do_send_headers(C, Stream, Headers, Options)
    end;

handle_call({send_data, StreamId, Data, Options}, _From, C) ->
    do_send_data(C, StreamId, Data, Options, size(Data));

handle_call({rst_stream, StreamId, ErrorCode}, _From,
            #{streams := Streams} = C) ->
    case find_stream(StreamId, Streams) of
        not_found ->
            {reply, {error, stream_not_found}, C};
        #{} = Stream ->
            {reply, ok, stream_error(C, Stream, ErrorCode)}
    end;

handle_call({stream_window_update, StreamId, Increment}, _From,
            #{streams := Streams} = C) ->
    case find_stream(StreamId, Streams) of
        not_found ->
            {reply, {error, stream_not_found}, C};
        #{client_window_size := WindowSize,
          initial_window_size := InitialSize}
          when WindowSize + Increment > InitialSize ->
            {reply, {error, increment_too_large}, C};
        #{} = Stream ->
            do_window_update(C, Stream, Increment)
    end;

handle_call({connection_window_update, Increment}, _From,
            #{client_window_size := WindowSize,
              initial_window_size := InitialSize} = C) ->
    case (WindowSize + Increment > InitialSize)  of
        true ->
            {reply, {error, increment_too_large}, C};
        false ->
            %% StreamId == 0 means Connection
            do_window_update(C, #{id => 0}, Increment)
    end;
handle_call(_Message, _From, C) ->
%%    io:format("received unexpected message: ~p~n in state ~p~n", 
%%              [Message, C]),
    {reply, ok, C}.

%% @private
handle_cast(_, State) ->
    {noreply, State}.

%% @private
%% Buffer contains what remains of the previous packet
handle_info({T, _Port, Data}, #{buffer := Buffer} = C) when T == tcp;
                                                            T == ssl ->
    handle_packet(<<Buffer/binary, Data/binary>>, C#{buffer => <<>>});
handle_info({T, _Port}, #{streams := Streams} = C) when T == tcp_closed;
                                                        T == ssl_closed ->
    end_streams(Streams, ?PROTOCOL_ERROR),
    {stop, closed_by_peer, C};
handle_info({cleanup_stream, StreamId}, #{streams := Streams} = C) ->
    {noreply, C#{streams => remove_stream(StreamId, Streams)}};
handle_info({ping_timeout, Opaque}, #{ping_sent := Pings} = C) ->
    case lists:keytake(Opaque, 1, Pings) of
        {value, {_, From, _}, OtherPings} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, C#{ping_sent => OtherPings}};
        false ->
            {noreply, C}
    end;
handle_info(_Other, C) ->
%%    io:format("got unexpected info: ~p~n", [_Other]),
    {noreply, C}.

%% @private
terminate(closed_by_peer, _) ->
    ok;
terminate(_Reason, #{transport := ssl, socket := Socket}) ->
    ssl:close(Socket);
terminate(_Reason, #{transport := tcp, socket := Socket}) ->
    gen_tcp:close(Socket);
terminate(_Reason, _) ->
    ok.

%% internal functions
new_connection(Connection, Options) ->
    %% tell server that we don't support push
    NonDefaultSettings = (maps:from_list(Options))#{enable_push => 0},
    AllSettings = maps:merge(default_settings(), NonDefaultSettings),
    #{header_table_size := HeaderTabSize} = AllSettings,
    case settings_frame(NonDefaultSettings) of
        {ok, Frame} ->
            send_settings(Frame, 
                          Connection#{client_settings => AllSettings,
                                      decode_state => mod_pushoff_cow_hpack:init(HeaderTabSize)
                                     });
        {error, Error} ->
            {stop, {building_settings_frame, Error}}
    end.

send_settings(SettingsFrame, Connection) ->
    case send(Connection,
              [<<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>, SettingsFrame]) of
        ok ->
            receive_server_settings(Connection);
        {error, Error} ->
            {stop, {sending_settings_frame, Error}}
    end.

receive_server_settings(Connection) ->
    case recv(Connection, 9) of
        {ok, <<0:24, 16#4:8, 16#0:8, 0:1, 0:31>>} ->
            %% SETTINGS frame contains no payload
            acknowledge(Connection);
        {ok, <<Length:24, 16#4:8, 16#0:8, 0:1, 0:31>>} ->
            read_server_settings(Length, Connection);
        {ok, _Other} ->
            Error = {receiving_settings_frame, unexpected_response},
            send_goaway(Connection, ?PROTOCOL_ERROR, Error),
            {stop, Error};
        {error, Error} ->
            send_goaway(Connection, ?PROTOCOL_ERROR, Error),
            {stop, {receiving_settings_frame, Error}}
    end.

read_server_settings(Length, Connection) ->
    case recv(Connection, Length) of
        {ok, Payload} ->
            parse_server_settings(Payload, Connection);
        {error, Error} ->
            send_goaway(Connection, ?PROTOCOL_ERROR, Error),
            {stop, {receiving_settings_frame_payload, Error}}
    end.

parse_server_settings(<<>>, Connection) ->
    acknowledge(Connection);
parse_server_settings(<<Type:16, Value:32, Rest/binary>>,
                      #{server_settings := Settings} = Connection) ->
    case parse_setting(Type, Value) of
        ok ->
            parse_server_settings(Rest, Connection);
        {ok, K, V} ->
            parse_server_settings(Rest, 
                                  Connection#{server_settings => Settings#{K => V}});
        {error, Error} ->
            send_goaway(Connection, ?PROTOCOL_ERROR, Error),
            {stop, {parsing_settings_frame, Error}}
    end.

%% We have received the server settings, send an ack and
%% process the settings (in particular, initiate the encoder state).
%% so they can be processed (and an ack can be sent).
acknowledge(#{server_settings := #{header_table_size := ServerHeaderTabSize}} = Connection) ->
    {ok, AckFrame} = settings_ack_frame(),
    case send(Connection, AckFrame) of
        ok ->
            receive_ack(Connection#{encode_state => mod_pushoff_cow_hpack:init(ServerHeaderTabSize)});
        {error, Error} ->
            send_goaway(Connection, ?PROTOCOL_ERROR, Error),
            {stop, {sending_ack, Error}}
    end.

receive_ack(Connection) ->
    %% Now we should receive a SETTINGS frame with the ACK flag set.
    %% However, we may also receive a WINDOW_UPDATE frame (the golang
    %% server does that). Since we don't do anything with the ACK anyway,
    %% we will ignore it, and consider the handshake complete.
    active_once(Connection),
    {ok, Connection}.

parse_setting(16#1, Value) ->
    {ok, header_table_size, Value};
parse_setting(16#4, Value) when Value =< 2147483647 ->
    {ok, initial_window_size, Value};
parse_setting(16#4, _) ->
    {error, wrong_value_for_initial_window_size};
parse_setting(16#5, Value) when Value >= 16384, 
                                Value =< 16777215 ->
    {ok, max_frame_size, Value};
parse_setting(16#5, _) ->
    {error, wrong_value_for_max_frame_size};
%% TODO
parse_setting(_, _) ->
    ok.


%%    +-----------------------------------------------+
%%    |                 Length (24)                   |
%%    +---------------+---------------+---------------+
%%    |   Type (8)    |   Flags (8)   |
%%    +-+-------------+---------------+-------------------------------+
%%    |R|                 Stream Identifier (31)                      |
%%    +=+=============================================================+
%%    |                   Frame Payload (0...)                      ...
%%    +---------------------------------------------------------------+
handle_packet(<<Length:24, Type:8, Flags:1/binary, _R:1, StreamId:31, 
                Payload:Length/binary, Rest/bits>>, C) ->
    handle_packet(Rest, 
                  handle_message0(Type, Flags, StreamId, Payload, Length, C));
handle_packet(Rest, C) ->
    active_once(C),
    {noreply, C#{buffer => Rest}}.

%% receive CONTINUATION frame as expected
handle_message0(?CONTINUATION, Flags, StreamId, Payload, Size, 
                #{continuation_data := #{stream_id := StreamId,
                                         buffer := Buffer,
                                         end_stream := EndStream}} = C) ->
    ContinuationFlags = continuation_flags(Flags),
    HeadersFlags = case EndStream of
                       true -> ContinuationFlags ++ [?END_STREAM];
                       false -> ContinuationFlags
                   end,
    handle_headers(HeadersFlags, StreamId,
                   <<Buffer/binary, Payload/binary>>,
                   size(Payload) + Size, C#{continuation_data => undefined});
%% receive something else while expecting CONTINUATION frame
handle_message0(_, _Flags, _StreamId, _Payload, _Size,
                #{continuation_data := #{}} = C) ->
    connection_error(C, ?PROTOCOL_ERROR);
%% receive unexpected CONTINUATION frame
handle_message0(?CONTINUATION, _Flags, _StreamId, _Payload, _Size,
                #{continuation_data := undefined} = C) ->
    connection_error(C, ?PROTOCOL_ERROR);
%% not expecting CONTINUATION frame and not getting it.
handle_message0(Type, Flags, StreamId, Payload, Size, C) ->
    handle_message(Type, Flags, StreamId, Payload, Size, C).

handle_message(?PING, Flags, StreamId, Payload, Size, C) ->
    handle_ping(ping_flags(Flags), StreamId, Payload, Size, C);
handle_message(?GOAWAY, _Flags, StreamId, Payload, Size, C) ->
    handle_goaway([], StreamId, Payload, Size, C);
handle_message(?RST_STREAM, _Flags, StreamId, Payload, Size, C) ->
    handle_rst_stream([], StreamId, Payload, Size, C);
handle_message(?WINDOW_UPDATE, _Flags, StreamId, Payload, Size, C) ->
    handle_window_update([], StreamId, Payload, Size, C);
handle_message(?SETTINGS, Flags, StreamId, Payload, Size, C) ->
    handle_settings(settings_flags(Flags), StreamId, Payload, Size, C);
handle_message(?DATA, Flags, StreamId, Payload, Size, C) ->
    handle_data(data_flags(Flags), StreamId, Payload, Size, C);
handle_message(?HEADERS, Flags, StreamId, Payload, Size, C) ->
    handle_headers(headers_flags(Flags), StreamId, Payload, Size, C).

settings_flags(<<_:7, Ack:1>>) ->
    [F || F <- [Ack * ?ACK], F /= 0].

data_flags(<<_:4, Padded:1, _:2, EndStream:1>>) ->
    [F || F <- [Padded * ?PADDED, EndStream * ?END_STREAM], F /= 0].

%%    PING
%%
%%    +---------------------------------------------------------------+
%%    |                                                               |
%%    |                      Opaque Data (64)                         |
%%    |                                                               |
%%    +---------------------------------------------------------------+

ping_flags(<<_:7, Ack:1>>) ->
    [F || F <- [Ack * ?ACK], F /= 0].

ping_frame(Flags, OpaqueData) ->
    make_frame(?PING, Flags, 0, OpaqueData, 8).

handle_ping(_Flags, StreamId, _Msg, _Size, C) when StreamId /= 0 ->
    connection_error(C, ?PROTOCOL_ERROR);
handle_ping([?ACK], 0, <<Opaque:8/binary>>, _Size,
            #{ping_sent := Pings} = C) ->
    case lists:keytake(Opaque, 1, Pings) of
        {value, {_, From, TimeSent}, OtherPings} ->
            gen_server:reply(From, {ok, ping_time() - TimeSent}),
            C#{ping_sent => OtherPings};
        false ->
            C
    end;
handle_ping([], 0, <<Opaque:8/binary>>, _Size, C) ->
    send(C, ping_frame([?ACK], Opaque)),
    C.

%%    GOAWAY
%%
%%    +-+-------------------------------------------------------------+
%%    |R|                  Last-Stream-ID (31)                        |
%%    +-+-------------------------------------------------------------+
%%    |                      Error Code (32)                          |
%%    +---------------------------------------------------------------+
%%    |                  Additional Debug Data (*)                    |
%%    +---------------------------------------------------------------+

goaway_frame(StreamId, ErrorCode) ->
    Payload = <<0:1, StreamId:31, ErrorCode:32>>,
    make_frame(?GOAWAY, [], 0, Payload, 8).

handle_goaway(_Flags, StreamId, _Msg, _Size, C) when StreamId /= 0 ->
    connection_error(C, ?PROTOCOL_ERROR);
handle_goaway(_Flags, 0,
              <<_R:1, LastStreamId:31, ErrorCode:32, _Rest/binary>>, 
              _Size, #{streams := Streams} = C) ->
    %% Streams with IDs =< LastStreamId may still be handled.
    C#{state => closed_by_peer,
       streams => cleanup_streams_newer_than(LastStreamId, Streams, ErrorCode)}.

%%    RST_STREAM
%%
%%    +---------------------------------------------------------------+
%%    |                        Error Code (32)                        |
%%    +---------------------------------------------------------------+

rst_stream_frame(StreamId, ErrorCode) ->
    Payload = <<ErrorCode:32>>,
    make_frame(?RST_STREAM, [], StreamId, Payload, 4).

handle_rst_stream(_Flags, 0, _Msg, _Size, C) ->
    connection_error(C, ?PROTOCOL_ERROR);
handle_rst_stream(_Flags, StreamId, <<ErrorCode:32>>, _Size,
                  #{streams := Streams} = C) ->
    case find_stream(StreamId, Streams) of
        not_found ->
            connection_error(C, ?PROTOCOL_ERROR); 
        #{state := State} when State == idle ->
            connection_error(C, ?PROTOCOL_ERROR); 
        #{owner := Owner} = Stream ->
              Owner ! {'RESET_BY_PEER', StreamId, ErrorCode},
              schedule_cleanup(Stream),
              C#{streams => update_stream(Streams,
                                          Stream#{state => closed})}
    end.

%%    WINDOW_UPDATE
%%
%%    +-+-------------------------------------------------------------+
%%    |R|              Window Size Increment (31)                     |
%%    +-+-------------------------------------------------------------+

window_update_frame(Increment, #{id := StreamId}) ->
    make_frame(?WINDOW_UPDATE, [], StreamId, <<0:1, Increment:31>>, 4).

handle_window_update(_Flags, 0, <<_R:1, Increment:31>>, _Size,
                     #{server_window := Window} = C) ->
    NewWindow = Window + Increment,
    case NewWindow > ?MAX_WINDOW_SIZE of
        true ->
            connection_error(C, ?FLOW_CONTROL_ERROR);
        false ->
            C#{server_window => NewWindow}
    end;
handle_window_update(_Flags, StreamId, <<_R:1, Increment:31>>, _Size,
                     #{streams := Streams} = C) ->
    case find_stream(StreamId, Streams) of
        not_found ->
            connection_error(C, ?PROTOCOL_ERROR); 
        #{server_window := Window} = Stream ->
              NewWindow = Window + Increment,
              case NewWindow > ?MAX_WINDOW_SIZE of
                  true ->
                      stream_error(C, Stream, ?FLOW_CONTROL_ERROR);
                  false ->
                      C#{streams => update_stream(Streams,
                                                  Stream#{
                                                      server_window => NewWindow})}
              end
    end.

%%   The payload of a SETTINGS frame consists of zero or more parameters,
%%   each consisting of an unsigned 16-bit setting identifier and an
%%   unsigned 32-bit value.
%%
%%    +-------------------------------+
%%    |       Identifier (16)         |
%%    +-------------------------------+-------------------------------+
%%    |                        Value (32)                             |
%%    +---------------------------------------------------------------+

handle_settings(_Flags, StreamId, _Data, _Size, C) when StreamId /= 0 ->
    connection_error(C, ?PROTOCOL_ERROR);
handle_settings([], StreamId, _Data, _Size, C) when StreamId == 0 ->
    C;
handle_settings([?ACK], _, _Data, _Size, C) ->
    %% Ack is ignored.
    C.
%% TODO: other SETTINGS frames.

%%    +---------------+
%%    |Pad Length? (8)|
%%    +---------------+-----------------------------------------------+
%%    |                            Data (*)                         ...
%%    +---------------------------------------------------------------+
%%    |                           Padding (*)                       ...
%%    +---------------------------------------------------------------+

%% If a DATA frame is  received whose stream identifier field is 0x0, the
%% recipient MUST respond with a connection error of type PROTOCOL_ERROR.
handle_data(_Flags, 0, _Data, _Size, C) ->
    connection_error(C, ?PROTOCOL_ERROR);
handle_data([?PADDED | OtherFlags], StreamId, Data, Size, C) ->
    case unpad(Data, Size) of
        {error, Error} ->
            connection_error(C, Error);
        {ok, Unpadded} ->
            handle_data(OtherFlags, StreamId, Unpadded, Size, C)
    end;
handle_data(Flags, StreamId, Data, Size, 
            #{streams := Streams,
              client_settings := #{max_frame_size := MaxFrameSize,
                                   initial_window_size := InitialConnectionWindow},
              client_window := ConnectionWindow,
              window_mgmt_fun := ConnectionWindowMgmtFun,
              window_mgmt_data := ConnectionWindowMgmtData} = C) ->
    case find_stream(StreamId, Streams) of
        not_found ->
            connection_error(C, ?PROTOCOL_ERROR); %% there is nothing about this case 
                                                  %% in the spec.
        #{state := State} = Stream when State == idle; 
                                        State == half_closed_remote ->
            stream_error(C, Stream, ?STREAM_CLOSED); %% Should these be considered in
                                                     %% the connection flow control window?
        #{client_window := StreamWindow,
          client_initial_window := InitialStreamWindow,
          window_mgmt_fun := StreamWindowMgmtFun,
          window_mgmt_data := StreamWindowMgmtData,
          owner := Owner,
          state := State} = Stream ->
              NewConnectionWindow = ConnectionWindow - Size,
              NewStreamWindow = StreamWindow - Size,
              %% See if we need to update the connection window
              {NewConnectionWindowMgtData, 
               FinalConnectionWindow} = 
                  case ConnectionWindowMgmtFun(NewConnectionWindow,
                                               InitialConnectionWindow,
                                               MaxFrameSize, 
                                               ConnectionWindowMgmtData) of
                      {ok, NewData} ->
                          {NewData, NewConnectionWindow};
                      {{window_update, Increment}, NewData} ->
                          do_window_update(C, #{id => 0}, Increment),
                          {NewData, NewConnectionWindow + Increment}
                  end,
              %% also on the stream level
              {NewStreamWindowMgtData, FinalStreamWindow} = 
                  case StreamWindowMgmtFun(NewStreamWindow,
                                           InitialStreamWindow,
                                           MaxFrameSize, 
                                           StreamWindowMgmtData) of
                      {ok, NewStreamData} ->
                          {NewStreamData, NewStreamWindow};
                      {{window_update, StreamIncrement}, NewStreamData} ->
                          do_window_update(C, Stream, StreamIncrement),
                          {NewStreamData, NewStreamWindow + StreamIncrement}
                  end,
              %% Make it visible if the data does not fit in one of the flow
              %% control windows (in theory the server should never send
              %% such data).
              Owner ! {'RECV_DATA', StreamId, Data, 
                       Size > StreamWindow, Size > ConnectionWindow},
              NewState = case lists:member(?END_STREAM, Flags) of
                             true ->
                                 %% Signal end of stream
                                 Owner ! {'END_STREAM', StreamId},
                                 case State of 
                                     half_closed_local ->
                                         closed;
                                     open ->
                                         half_closed_remote
                                 end;
                             false ->
                                 State
                         end,
              C#{streams => update_stream(Streams,
                                          Stream#{
                                              state => NewState,
                                              client_window => FinalStreamWindow,
                                              window_mgmt_data => NewStreamWindowMgtData}),
                 client_window => FinalConnectionWindow,
                 window_mgmt_data => NewConnectionWindowMgtData}
    end.

unpad(<<PadLength:8, _/binary>>, Size) when PadLength >= Size ->
    {error, ?PROTOCOL_ERROR};
unpad(<<PadLength:8, Padded/binary>>, Size) ->
    DataLength = Size - PadLength,
    <<Data:DataLength/binary, _:PadLength/binary>> = Padded,
    {ok, Data}.

%%    +---------------+
%%    |Pad Length? (8)|
%%    +-+-------------+-----------------------------------------------+
%%    |E|                 Stream Dependency? (31)                     |
%%    +-+-------------+-----------------------------------------------+
%%    |  Weight? (8)  |
%%    +-+-------------+-----------------------------------------------+
%%    |                   Header Block Fragment (*)                 ...
%%    +---------------------------------------------------------------+
%%    |                           Padding (*)                       ...
%%    +---------------------------------------------------------------+

headers_flags(<<_:2, Priority:1, _:1, Padded:1,
                EndHeaders:1, _:1, EndStream:1>>) ->
    %% Note that the order is signficant, it determines the "unpacking"
    %% of the message.
    [F || F <- [Padded * ?PADDED,
                Priority * ?PRIORITY_F,
                EndHeaders * ?END_HEADERS,
                EndStream * ?END_STREAM], F /= 0].

%% A HEADERS frame may contain padding and priority information, but 
%% none of that is supported, so it is just the Header Block Fragment.
headers_frame(HeaderBlockFragment, Flags, #{id := StreamId}) ->
    make_frame(?HEADERS, Flags, StreamId, HeaderBlockFragment,
               size(HeaderBlockFragment)).

handle_headers(_Flags, 0, _Data, _Size, C) ->
    connection_error(C, ?PROTOCOL_ERROR);
handle_headers([?PADDED | OtherFlags], StreamId, Data, Size, C) ->
    case unpad(Data, Size) of
        {error, Error} ->
            connection_error(C, Error);
        {ok, Unpadded} ->
            handle_headers(OtherFlags, StreamId, Unpadded, Size, C)
    end;

handle_headers([?PRIORITY_F | OtherFlags], StreamId, Data, Size, C) ->
    <<_E:1, _StreamDependency:31, _Weight:8, Fragment/binary>> = Data,
    handle_headers(OtherFlags, StreamId, Fragment, Size, C);
handle_headers([?END_HEADERS | OtherFlags], StreamId, Data, _Size, 
               #{streams := Streams,
                 decode_state := DecodeState} = C) ->
    %% In general the decoding must be done even in case of errors, because the 
    %% decode_state must be kept in sync with the server
    {Headers, NewDecodeState} = mod_pushoff_cow_hpack:decode(Data, DecodeState),
    C2 = C#{decode_state => NewDecodeState},
    case find_stream(StreamId, Streams) of
        not_found ->
            connection_error(C2, ?PROTOCOL_ERROR); %% there is nothing about this case 
                                                   %% in the spec.
        #{state := State} = Stream when State == half_closed_remote ->
            stream_error(C2, Stream, ?STREAM_CLOSED); %% Should these be considered in
                                                      %% the connection flow control window?
        #{owner := Owner,
          state := State} = Stream ->
            Owner ! {'RECV_HEADERS', StreamId, Headers}, 
            NewState = case is_end_stream(OtherFlags) of
                           true ->
                               %% Signal end of stream
                               Owner ! {'END_STREAM', StreamId},
                               case State of 
                                   half_closed_local ->
                                       schedule_cleanup(Stream),
                                       closed;
                                   _ ->
                                       half_closed_remote
                               end;
                           false ->
                               case State of
                                   idle ->
                                       open;
                                   _ ->
                                       State
                               end
                       end,
            C2#{streams => update_stream(Streams,
                                         Stream#{state => NewState})}
    end;
%% END_HEADERS not set: expect a CONTINUATION frame.
handle_headers(OtherFlags, StreamId, Data, _Size, C) ->
    C#{continuation_data => #{buffer => Data,
                              stream_id => StreamId,
                              end_stream => is_end_stream(OtherFlags)}}.

is_end_stream(Flags) ->
    lists:member(?END_STREAM, Flags).

%%    CONTINUATION
%%
%%    +---------------------------------------------------------------+
%%    |                   Header Block Fragment (*)                 ...
%%    +---------------------------------------------------------------+

continuation_flags(<<_:5, EndHeaders:1, _:2>>) ->
    [F || F <- [EndHeaders * ?END_HEADERS], F /= 0].

continuation_frame(HeaderBlockFragment, Flags, #{id := StreamId}) ->
    make_frame(?CONTINUATION, Flags, StreamId, HeaderBlockFragment,
               size(HeaderBlockFragment)).

connection_error(C, ErrorCode) ->
    send_goaway(C, ErrorCode, connection_error),
    close_connection(C).

%% An endpoint that detects a stream error sends a RST_STREAM frame that
%% contains the stream identifier of the stream where the error occurred.  The
%% RST_STREAM frame includes an error code that indicates the type of error.
stream_error(#{streams := Streams} = C,
             #{id := StreamId,
               state := StreamState} = Stream, ErrorCode) ->
    case StreamState of
        _ when StreamState == closed;
               StreamState == idle ->
            ok;
        _ -> 
            send(C, rst_stream_frame(StreamId, ErrorCode))
    end,
    schedule_cleanup(Stream),
    C#{streams => update_stream(Streams, Stream#{state => closed})}.

%% Sending headers change the state of an idle stream
%% to 'open'.
%% If the headers are "big", they may be split over several 
%% frames using CONTINUATION frames.
%%
%% HEADER frames modify the compression context.  When transmitted over a
%% connection, a header list is serialized into a header block using HTTP
%% header compression [COMPRESSION].  The serialized header block is then
%% divided into one or more octet sequences, called header block fragments, and
%% transmitted within the payload of HEADERS, PUSH_PROMISE [out of scope], or
%% CONTINUATION frames.

do_send_headers(#{encode_state := EncodeState,
                  server_settings := #{max_frame_size := MaxFrameSize},
                  streams := Streams} = Connection,
                #{state := StreamState} = Stream, Headers, Options) ->
    EndStream = proplists:get_value(end_stream, Options, false),
    {NewState, Flags} =
        case {StreamState, EndStream} of
            {idle, false} ->
                {open, []};
            {_, false}  ->
                {StreamState, []};
            {half_closed_remote, true} ->
                {closed, [?END_STREAM]};
            {_, true} ->
                {half_closed_local, [?END_STREAM]}
        end,
    {Encoded, NewEncodeState} = mod_pushoff_cow_hpack:encode(Headers, EncodeState),
    case send_header_block(iolist_to_binary(Encoded),
                           MaxFrameSize, Flags, Connection, Stream) of
        ok ->
            {reply, ok,
             Connection#{encode_state => NewEncodeState,
                         streams => update_stream(Streams,
                                                  Stream#{state => NewState})}};
        Error ->
            {reply, Error, Connection}
    end.

send_header_block(Encoded, MaxFrameSize, Flags, Connection, Stream)
  when byte_size(Encoded) =< MaxFrameSize ->
    send_fragment(Encoded, [?END_HEADERS | Flags], Connection, Stream);
send_header_block(Encoded, MaxFrameSize, Flags, Connection, Stream) ->
    <<First:MaxFrameSize/binary, Rest/binary>> = Encoded,
    case send_fragment(First, Flags, Connection, Stream) of
        ok -> 
            send_continuation(Rest, MaxFrameSize, Flags, Connection, Stream);
        Error ->
            Error
    end.

send_fragment(Encoded, Flags, Connection, Stream) ->
    send(Connection, headers_frame(Encoded, Flags, Stream)).

send_continuation(Encoded, MaxFrameSize, Flags, Connection, Stream)
  when byte_size(Encoded) =< MaxFrameSize ->
    send_continuation_fragment(Encoded, [?END_HEADERS | Flags],
                               Connection, Stream);
send_continuation(Encoded, MaxFrameSize, Flags, Connection, Stream) ->
    <<First:MaxFrameSize/binary, Rest/binary>> = Encoded,
    case send_continuation_fragment(First, Flags, Connection, Stream) of
        ok -> 
            send_continuation(Rest, MaxFrameSize, Flags, Connection, Stream);
        Error ->
            Error
    end.

send_continuation_fragment(Encoded, Flags, Connection, Stream) ->
    send(Connection, continuation_frame(Encoded, Flags, Stream)).

do_window_update(C, _Stream, Increment) when Increment < 1; 
                                             Increment > 2147483647 ->
    {reply, {error, illegal_value}, C};
do_window_update(C, Stream, Increment) ->
    send(C, window_update_frame(Increment, Stream)).

do_ping(#{ping_sent := Sent} = C, Opaque, From, Timeout) ->
    case send(C, ping_frame([], Opaque)) of
        ok ->
            set_timer(Timeout, {ping_timeout, Opaque}),
            {noreply, C#{ping_sent => [{Opaque, From,
                                        ping_time()} | Sent]}};
        _ ->
            {reply, {error, failed_to_send}, C}
    end.


%% DATA frames only be sent when a stream is in the "open" or "half-closed
%% (remote)" state.
%% DATA frames are subject to flow control.
%% server_window keeps track of the nr of bytes that may still be
%% sent to the server, both on the Connection and Stream level.
do_send_data(#{server_window := ConnectionWindow} = C, _, _Data, _Options, Size)
  when Size > ConnectionWindow ->
    {reply, {error, {flow_control, connection_window_exceeded}}, C};
do_send_data(#{streams := Streams} = C, StreamId, Data, Options, Size) ->
    case find_stream(StreamId, Streams) of
        not_found ->
            {reply, {error, stream_not_found}, C};
        #{state := State} when State == idle; 
                               State == half_closed_local ->
            {reply, {error, stream_not_open_for_data}, C};
        #{server_window := StreamWindow} when Size > StreamWindow ->
            {reply, {error, {flow_control, stream_window_exceeded}}, C};
        #{} = Stream ->
            do_send_data2(C, Stream, Data, Options, Size)
    end.

do_send_data2(#{server_settings := #{max_frame_size := MaxFrameSize},
                streams := Streams,
                server_window := ConnectionWindow} = Connection,
              #{server_window := StreamWindow,
                state := State} = Stream, Data, Options,
              Size) ->
    EndStream = proplists:get_value(end_stream, Options, false),
    {NewState, Flags} =
        case {State, EndStream} of
            {_, false}  ->
                {State, []};
            {half_closed_remote, true} ->
                {closed, [?END_STREAM]};
            {open, true} ->
                {half_closed_local, [?END_STREAM]}
        end,
    case send_data_frame(Data, MaxFrameSize, Flags, Connection, Stream, Size) of
        ok ->
            NewStream = Stream#{server_window => StreamWindow - Size,
                                state => NewState},
            {reply, ok,
             Connection#{server_window => ConnectionWindow - Size,
                         streams => update_stream(Streams, NewStream)}};
        Error ->
            {reply, Error, Connection}
    end.

send_data_frame(Data, MaxFrameSize, Flags, Connection, Stream, Size)
  when Size =< MaxFrameSize ->
    send(Connection, data_frame(Data, Flags, Stream, Size));
send_data_frame(Data, MaxFrameSize, Flags, Connection, Stream, Size) ->
    <<First:MaxFrameSize, Rest/binary>> = Data,
    %% There is only 1 applicable flag (END_STREAM), which will only be sent
    %% with the last packet. So for this packet flags = [].
    case send(Connection, data_frame(First, [], Stream, MaxFrameSize)) of
        ok -> 
            send_data_frame(Rest, MaxFrameSize, Flags,
                            Connection, Stream, Size - MaxFrameSize);
        Error ->
            Error
    end.

new_stream(#{last_stream := Last,
             client_settings :=  #{initial_window_size := ClientWindow},
             server_settings :=  #{initial_window_size := ServerWindow}},
           {From, _}, Options) ->
    Id = case Last of
             0 -> 1;
             _ -> Last + 2  %% client MUST use odd-numbered stream identifiers
         end,
    {ok, #{owner => From,
           id => Id,
           state => idle,
           client_window => ClientWindow,
           window_mgmt_fun => proplists:get_value(window_mgmt_fun,
                                                  Options, fun window_mgr/4),
           window_mgmt_data => proplists:get_value(window_mgmt_data,
                                                   Options, undefined),
           client_initial_window => ClientWindow,
           server_window => ServerWindow}}.

default_settings() ->
    #{header_table_size => 4096,
      max_concurrent_streams => undefined,
      initial_window_size => ?INITIAL_WINDOW_SIZE,
      low_water_mark => ?MAX_FRAME_SIZE,
      max_frame_size => ?MAX_FRAME_SIZE}.


%%    +---------------+
%%    |Pad Length? (8)|
%%    +---------------+-----------------------------------------------+
%%    |                            Data (*)                         ...
%%    +---------------------------------------------------------------+
%%    |                           Padding (*)                       ...
%%    +---------------------------------------------------------------+
%%
%%    Padding is not supported.
data_frame(Data, Flags, #{id := StreamId}, Size) ->
    make_frame(?DATA, Flags, StreamId, Data, Size).


settings_frame(Settings) ->
    Payload = [settings_parameter(K, V) || {K, V} <- maps:to_list(Settings)],
    frame(?SETTINGS, [], 0, Payload, Settings).

settings_ack_frame() ->
    frame(?SETTINGS, [?ACK], 0, <<>>, 0).

settings_parameter(enable_push, Value) ->
    <<16#2:16, Value:32>>;
settings_parameter(max_concurrent_streams, undefined) ->
    [];
settings_parameter(max_concurrent_streams, Value) ->
    <<16#3:16, Value:32>>;
settings_parameter(initial_window_size, Value) ->
    <<16#4:16, Value:32>>;
settings_parameter(max_frame_size, Value) ->
    <<16#5:16, Value:32>>;
settings_parameter(_Key, _Value) ->
    [].

frame(Type, Flags, StreamId, Payload, #{max_frame_size := Max}) ->
    frame(Type, Flags, StreamId, Payload, Max);

frame(Type, Flags, StreamId, Payload, Max) ->
    Length = iolist_size(Payload), 
    %   Length:  The length of the frame payload expressed as an unsigned
    %      24-bit integer.  Values greater than 2^14 (16,384) MUST NOT be
    %      sent unless the receiver has set a larger value for
    %      SETTINGS_MAX_FRAME_SIZE.
    %
    %      The 9 octets of the frame header are not included in this value.
    case Length of
        _ when Length > Max ->
            {error, frame_too_long};
        _ ->
            {ok, make_frame(Type, Flags, StreamId, Payload, Length)}
    end.

make_frame(Type, Flags, StreamId, Payload, Length) ->
    %   All frames begin with a fixed 9-octet header followed by a variable-
    %   length payload.
    %
    %    +-----------------------------------------------+
    %    |                 Length (24)                   |
    %    +---------------+---------------+---------------+
    %    |   Type (8)    |   Flags (8)   |
    %    +-+-------------+---------------+-------------------------------+
    %    |R|                 Stream Identifier (31)                      |
    %    +=+=============================================================+
    %    |                   Frame Payload (0...)                      ...
    %    +---------------------------------------------------------------+
    FlagsOctet = lists:sum(Flags),
    iolist_to_binary([<<Length:24, Type:8, FlagsOctet:8, 0:1, StreamId:31>>, Payload]).

send_goaway(#{last_stream := Last} = C, ErrNo, _Error) ->
    send(C, goaway_frame(Last, ErrNo)),
    {error, ErrNo}.

send(#{transport := Transport, socket := Socket}, Data) ->
    Transport:send(Socket, Data).

recv(#{transport := Transport,
       socket := Socket,
       timeout := Timeout}, NrOfBytes) ->
    Transport:recv(Socket, NrOfBytes, Timeout).

active_once(#{socket := Socket,
              transport := Transport}) ->
    case Transport of 
        gen_tcp ->
            ok = inet:setopts(Socket, [{active, once}]);
        _ ->
            Transport:setopts(Socket, [{active, once}])
    end.

close_connection(#{transport := Transport, socket := Socket} = C) ->
    Transport:close(Socket),
    C.

update_stream(Streams, #{id := Id} = NewStream) ->
    lists:keyreplace(Id, 1, Streams, {Id, NewStream}).

remove_stream(StreamId, Streams) ->
    lists:keydelete(StreamId, 1, Streams).

cleanup_streams_newer_than(StreamId, Streams, ErrorCode) ->
    [maybe_cleanup_stream(S, StreamId, ErrorCode) || S <- Streams].

maybe_cleanup_stream(#{id := Id} = S, LastStreamId, ErrorCode) 
  when Id > LastStreamId ->
    cleanup_stream(S, ErrorCode);
maybe_cleanup_stream(Stream, _, _) ->
    Stream.

end_streams(Streams, ErrorCode) ->
    [end_stream(S, ErrorCode) || {_, S} <- Streams].

cleanup_stream(Stream, ErrorCode) ->
    schedule_cleanup(Stream),
    end_stream(Stream, ErrorCode).

end_stream(#{id := StreamId, owner := Owner} = Stream, ErrorCode) ->
    Owner ! {'CLOSED_BY_PEER', StreamId, ErrorCode},
    Stream#{state => closed}.

find_stream(StreamId, Streams) ->
    case lists:keyfind(StreamId, 1, Streams) of
        false ->
            not_found;
        {_, Stream} ->
            Stream
    end.

schedule_cleanup(#{id := StreamId}) ->
    timer:send_after(?STREAM_COOL_OFF_PERIOD, {cleanup_stream, StreamId}).

map_transport(tcp) -> gen_tcp;
map_transport(T) -> T.

set_timer(infinity, _) -> ok;
set_timer(Timeout, Message) -> timer:send_after(Timeout, Message).

default_opts(T) when T == ssl;
                     T == gen_tcp ->
    [{packet, raw}, {active, false}, binary];
default_opts(_) -> [].

ping_time() -> erlang:system_time(microsecond).
