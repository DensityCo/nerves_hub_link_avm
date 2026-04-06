-module(websocket).

-export([
    transport_accept/1,
    is_supported/0,
    new/1,
    new/2,
    send_utf8/2,
    send_binary/2,
    controlling_process/2
]).

-behavior(gen_server).

% gen_server interface
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(OPCODE_UTF8, 1).
-define(OPCODE_BINARY, 2).
-define(OPCODE_CLOSE, 8).
-define(OPCODE_PING, 9).
-define(OPCODE_PONG, 10).

-define(SSL_POLL_INTERVAL, 100).

-type ready_state() :: connecting | open | closing | closed.

% websocket implementation using socket (ws) or ssl (wss)
transport_accept(CSock) ->
    {ok, Request} = get_http_message({tcp, CSock}),
    {ok, WebSocketKey} = process_handshake_open(Request),
    ReplyToken = compute_socket_accept(WebSocketKey),
    Response = [
        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Accept: ">>, ReplyToken, <<"\r\n">>,
        <<"\r\n">>
    ],
    socket:send(CSock, Response),
    ControllingProcess = self(),
    gen_server:start_link(?MODULE, {accept, ControllingProcess, {tcp, CSock}}, []).

is_supported() ->
    true.

controlling_process(Socket, Pid) ->
    gen_server:call(Socket, {controlling_process, self(), Pid}).

new(URL) ->
    new(URL, []).

new(URL, Opts) ->
    ControllingProcess = self(),
    case gen_server:start_link(?MODULE, {connect, ControllingProcess, URL, Opts}, []) of
        {ok, Pid} -> {ok, Pid};
        {error, _} = Err -> Err
    end.

send_binary(WebSocket, Data) ->
    gen_server:cast(WebSocket, {send, ?OPCODE_BINARY, Data}).

send_utf8(WebSocket, Data) ->
    gen_server:cast(WebSocket, {send, ?OPCODE_UTF8, Data}).

-record(state, {
    controlling_process :: pid(),
    transport :: {tcp, socket:socket()} | {ssl, ssl:sslsocket()},
    ready_state :: ready_state(),
    is_server :: boolean(),
    buffer :: binary(),
    frames :: undefined | {integer(), binary()},
    select_handle = undefined,
    poll_timer = undefined,
    ssl_reader = undefined
}).

init({accept, ControllingProcess, Transport}) ->
    State0 = #state{
        controlling_process = ControllingProcess,
        transport = Transport,
        ready_state = open,
        is_server = true,
        buffer = <<>>,
        frames = undefined
    },
    State1 = start_recv(State0),
    {ok, State1};
init({connect, ControllingProcess, URL, Opts}) ->
    case websocket_open(URL, Opts) of
        {ok, Transport} ->
            ControllingProcess ! {websocket_open, self()},
            State0 = #state{
                controlling_process = ControllingProcess,
                transport = Transport,
                ready_state = open,
                is_server = false,
                buffer = <<>>,
                frames = undefined
            },
            State1 = start_recv(State0),
            {ok, State1};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(ready_state, _From, #state{ready_state = ReadyState} = State) ->
    {reply, ReadyState, State};
handle_call({controlling_process, Caller, ControllingProcess}, _From, #state{controlling_process = PreviousControllingProcess} = State) ->
    if
        Caller =/= PreviousControllingProcess ->
            {reply, {error, not_owner}, State};
        true ->
            {reply, ok, State#state{controlling_process = ControllingProcess}}
    end.

handle_cast({send, OpCode, Data}, #state{is_server = IsServer, transport = Transport} = State) ->
    {MaskBit, MaskingKey, MaskedData} = case IsServer of
        true -> {0, <<>>, Data};
        false ->
            MaskingKey0 = crypto:strong_rand_bytes(4),
            MaskedData0 = unmask(MaskingKey0, Data),
            {1, MaskingKey0, MaskedData0}
    end,
    % We don't fragment for now
    DataSize = byte_size(MaskedData),
    Packet = if
        DataSize < 126 ->
            <<1:1, 0:3, OpCode:4, MaskBit:1, DataSize:7, MaskingKey/binary, MaskedData/binary>>;
        DataSize < 16#FFFF ->
            <<1:1, 0:3, OpCode:4, MaskBit:1, 126:7, DataSize:16, MaskingKey/binary, MaskedData/binary>>;
        true ->
            <<1:1, 0:3, OpCode:4, MaskBit:1, 127:7, DataSize:32, MaskingKey/binary, MaskedData/binary>>
    end,
    ok = transport_send(Transport, Packet),
    {noreply, State}.

% TCP: async select notification
handle_info(
    {'$socket', Socket, select, SelectHandle},
    #state{transport = {tcp, Socket}, select_handle = SelectHandle} = State0
) ->
    State1 = recv_data_loop_tcp(State0),
    {noreply, State1};

% SSL: data from reader process
handle_info(
    {ssl_data, Data},
    #state{buffer = Buffer} = State0
) ->
    State1 = State0#state{buffer = <<Buffer/binary, Data/binary>>},
    State2 = process_recv_buffer(State1),
    {noreply, State2};

% SSL: connection closed
handle_info(
    ssl_closed,
    #state{controlling_process = CP} = State0
) ->
    CP ! {websocket_close, self(), {normal, closed}},
    {noreply, State0#state{ready_state = closed}};

% SSL reader exited (linked process)
handle_info(
    {'EXIT', Pid, _Reason},
    #state{ssl_reader = Pid, controlling_process = CP} = State0
) ->
    CP ! {websocket_close, self(), {normal, reader_exit}},
    {noreply, State0#state{ready_state = closed, ssl_reader = undefined}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{transport = {ssl, SslSocket}}) ->
    catch ssl:close(SslSocket),
    ok;
terminate(_Reason, #state{transport = {tcp, Socket}}) ->
    catch socket:close(Socket),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% -- Transport abstraction --

transport_send({tcp, Socket}, Data) ->
    socket:send(Socket, Data);
transport_send({ssl, Socket}, Data) ->
    ssl:send(Socket, Data).

transport_recv_blocking({tcp, Socket}, Timeout) ->
    socket:recv(Socket, 0, Timeout);
transport_recv_blocking({ssl, Socket}, _Timeout) ->
    ssl:recv(Socket, 0).

%% -- Recv entry point --

start_recv(#state{transport = {tcp, _}} = State) ->
    recv_data_loop_tcp(State);
start_recv(#state{transport = {ssl, SslSocket}} = State) ->
    %% Spawn a dedicated reader so gen_server stays responsive for sends
    Owner = self(),
    Reader = spawn(fun() -> ssl_reader_loop(Owner, SslSocket) end),
    State#state{ssl_reader = Reader}.

%% -- TCP recv (async select) --

recv_data_loop_tcp(
    #state{transport = {tcp, Socket}, buffer = Buffer} = State0
) ->
    case socket:recv(Socket, 0, nowait) of
        {ok, Data} ->
            State1 = State0#state{buffer = <<Buffer/binary, Data/binary>>},
            State2 = process_recv_buffer(State1),
            recv_data_loop_tcp(State2);
        {select, {{select_info, recv, SelectHandle}, Data}} when is_reference(SelectHandle) ->
            State1 = State0#state{buffer = <<Buffer/binary, Data/binary>>},
            State2 = process_recv_buffer(State1),
            State2#state{select_handle = SelectHandle};
        {select, {select_info, recv, SelectHandle}} when is_reference(SelectHandle) ->
            State0#state{select_handle = SelectHandle}
    end.

%% -- SSL reader process (runs in separate process, sends data to gen_server) --

ssl_reader_loop(Owner, SslSocket) ->
    case ssl:recv(SslSocket, 0) of
        {ok, Data} ->
            Owner ! {ssl_data, Data},
            ssl_reader_loop(Owner, SslSocket);
        {error, closed} ->
            Owner ! ssl_closed;
        {error, _Reason} ->
            Owner ! ssl_closed
    end.

%% -- URL parsing and connection --

websocket_open(URL, Opts) ->
    URLBin = list_to_binary(URL),
    {Scheme, Tail} = case URLBin of
        <<"wss://", T/binary>> -> {wss, T};
        <<"ws://", T/binary>> -> {ws, T}
    end,
    [HostPort | PathParts] = binary:split(Tail, <<"/">>),
    Path = case PathParts of
        [] -> <<>>;
        [P] -> P
    end,
    {Host, Port} = case binary:split(HostPort, <<":">>) of
        [Host0, Port0] -> {Host0, binary_to_integer(Port0)};
        [Host0] ->
            DefaultPort = case Scheme of
                wss -> 443;
                ws -> 80
            end,
            {Host0, DefaultPort}
    end,
    SslOpts = proplists:get_value(ssl_opts, Opts, []),
    ExtraHeaders = proplists:get_value(extra_headers, Opts, []),
    case case Scheme of
        ws -> connect_tcp(Host, Port);
        wss -> connect_ssl(Host, Port, SslOpts)
    end of
        {error, _} = ConnErr -> ConnErr;
        {ok, Sock} ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    HeaderLines = lists:map(fun({Name, Value}) ->
        [Name, <<": ">>, Value, <<"\r\n">>]
    end, ExtraHeaders),
    Request = [
        <<"GET /">>, Path, <<" HTTP/1.1\r\n">>,
        <<"Host: ">>, Host, <<"\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
        <<"Sec-WebSocket-Version: 13\r\n">>,
        HeaderLines,
        <<"\r\n">>
    ],
    ok = transport_send(Sock, Request),
    ReplyToken = compute_socket_accept(Key),
    {ok, Reply} = get_http_message(Sock),
    ok = process_handshake_open_reply(Reply, ReplyToken),
    {ok, Sock}
    end.

connect_tcp(Host, Port) ->
    {ok, IPv4} = inet:getaddr(binary_to_list(Host), inet),
    {ok, Socket} = socket:open(inet, stream, tcp),
    ok = socket:connect(Socket, #{family => inet, addr => IPv4, port => Port}),
    {ok, {tcp, Socket}}.

connect_ssl(Host, Port, ExtraSslOpts) ->
    ok = ssl:start(),
    HostStr = binary_to_list(Host),
    DefaultOpts = [{verify, verify_none}, {active, false}, {binary, true}],
    MergedOpts = DefaultOpts ++ ExtraSslOpts,
    case ssl:connect(HostStr, Port, MergedOpts) of
        {ok, SslSocket} -> {ok, {ssl, SslSocket}};
        {error, _} = Err -> Err
    end.

%% -- HTTP message reading (used during handshake) --

get_http_message(Transport) ->
    get_http_message(Transport, <<>>).

get_http_message(Transport, Acc) ->
    ByteSize = byte_size(Acc),
    Finished = if
        ByteSize > 4 ->
            {_, Tail} = split_binary(Acc, ByteSize - 4),
            Tail =:= <<"\r\n\r\n">>;
        true -> false
    end,
    if
        Finished -> {ok, Acc};
        true ->
            case transport_recv_blocking(Transport, 5000) of
                {ok, Data} ->
                    get_http_message(Transport, <<Acc/binary, Data/binary>>);
                {error, _} = ErrT ->
                    ErrT
            end
    end.

%% -- WebSocket handshake --

compute_socket_accept(WebSocketKey) ->
    MagicKey = <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>,
    PreImage = <<WebSocketKey/binary, MagicKey/binary>>,
    base64:encode(crypto:hash(sha, PreImage)).

header_name_lower(Header) ->
    case binary:split(Header, <<": ">>) of
        [Name, Value] -> {bin_lowercase(Name), Value};
        _ -> {Header, <<>>}
    end.

bin_lowercase(Bin) -> bin_lowercase(Bin, <<>>).
bin_lowercase(<<>>, Acc) -> Acc;
bin_lowercase(<<C, Rest/binary>>, Acc) when C >= $A, C =< $Z ->
    bin_lowercase(Rest, <<Acc/binary, (C + 32)>>);
bin_lowercase(<<C, Rest/binary>>, Acc) ->
    bin_lowercase(Rest, <<Acc/binary, C>>).

process_handshake_open(Request) ->
    RequestLines = binary:split(Request, <<"\r\n">>, [global]),
    process_handshake_open(RequestLines, request).

process_handshake_open([<<"GET ", _GetTail/binary>> | Tail], request) ->
    process_handshake_open(Tail, {headers, false, false, false, undefined});
process_handshake_open([<<"Upgrade: websocket">> | Tail], {headers, false, Conn, Version, Key}) ->
        process_handshake_open(Tail, {headers, true, Conn, Version, Key});
process_handshake_open([<<"Connection: Upgrade">> | Tail], {headers, Upgrade, false, Version, Key}) ->
        process_handshake_open(Tail, {headers, Upgrade, true, Version, Key});
process_handshake_open([<<"Sec-WebSocket-Version: 13">> | Tail], {headers, Upgrade, Conn, false, Key}) ->
        process_handshake_open(Tail, {headers, Upgrade, Conn, true, Key});
process_handshake_open([<<"Sec-WebSocket-Key: ", Key/binary>> | Tail], {headers, Upgrade, Conn, Version, undefined}) ->
        process_handshake_open(Tail, {headers, Upgrade, Conn, Version, Key});
process_handshake_open([_OtherHeader | Tail], {headers, Upgrade, Conn, Version, Key}) ->
        process_handshake_open(Tail, {headers, Upgrade, Conn, Version, Key});
process_handshake_open([], {headers, true, true, true, Key}) ->
        {ok, Key};
process_handshake_open(Lines, State) ->
        {error, {protocol, Lines, State}}.

process_handshake_open_reply(Reply, AcceptToken) ->
    ReplyLines = binary:split(Reply, <<"\r\n">>, [global]),
    process_handshake_open_reply0(ReplyLines, {request, AcceptToken}).

process_handshake_open_reply0([<<"HTTP/1.1 101", _/binary>> | Tail], {request, AcceptToken}) ->
        process_handshake_open_reply0(Tail, {headers, false, false, AcceptToken});
process_handshake_open_reply0([Header | Tail], {headers, Upgrade, Conn, Key}) ->
        case header_name_lower(Header) of
            {<<"upgrade">>, <<"websocket">>} ->
                process_handshake_open_reply0(Tail, {headers, true, Conn, Key});
            {<<"connection">>, Val} ->
                case bin_lowercase(Val) of
                    <<"upgrade">> ->
                        process_handshake_open_reply0(Tail, {headers, Upgrade, true, Key});
                    _ ->
                        process_handshake_open_reply0(Tail, {headers, Upgrade, Conn, Key})
                end;
            {<<"sec-websocket-accept">>, AcceptVal} when is_binary(Key) ->
                case AcceptVal =:= Key of
                    true -> process_handshake_open_reply0(Tail, {headers, Upgrade, Conn, true});
                    false -> process_handshake_open_reply0(Tail, {headers, Upgrade, Conn, Key})
                end;
            _ ->
                process_handshake_open_reply0(Tail, {headers, Upgrade, Conn, Key})
        end;
process_handshake_open_reply0([], {headers, true, true, true}) ->
        ok;
process_handshake_open_reply0(Lines, State) ->
        {error, {protocol, Lines, State}}.

%% -- Frame parsing --

process_recv_buffer(#state{buffer = <<Fin:1, 0:3, Opcode:4, 0:1, 0:7, Rest/binary>>} = State0) ->
    State1 = process_frame(<<>>, Fin, Opcode, State0#state{buffer = Rest}),
    process_recv_buffer(State1);
process_recv_buffer(#state{buffer = <<Fin:1, 0:3, Opcode:4, 1:1, 0:7, _MakingKey:4/binary, Rest/binary>>} = State0) ->
    State1 = process_frame(<<>>, Fin, Opcode, State0#state{buffer = Rest}),
    process_recv_buffer(State1);
process_recv_buffer(#state{buffer = <<Fin:1, 0:3, Opcode:4, 1:1, 126:7, PayloadLen:16, MaskingKey:4/binary, MaskedPayload:PayloadLen/binary, Rest/binary>>} = State0) ->
    Payload = unmask(MaskingKey, MaskedPayload),
    State1 = process_frame(Payload, Fin, Opcode, State0#state{buffer = Rest}),
    process_recv_buffer(State1);
process_recv_buffer(#state{buffer = <<Fin:1, 0:3, Opcode:4, 1:1, 127:7, PayloadLen:32, MaskingKey:4/binary, MaskedPayload:PayloadLen/binary, Rest/binary>>} = State0) ->
    Payload = unmask(MaskingKey, MaskedPayload),
    State1 = process_frame(Payload, Fin, Opcode, State0#state{buffer = Rest}),
    process_recv_buffer(State1);
process_recv_buffer(#state{buffer = <<Fin:1, 0:3, Opcode:4, 1:1, PayloadLen:7, MaskingKey:4/binary, MaskedPayload:PayloadLen/binary, Rest/binary>>} = State0) ->
    Payload = unmask(MaskingKey, MaskedPayload),
    State1 = process_frame(Payload, Fin, Opcode, State0#state{buffer = Rest}),
    process_recv_buffer(State1);
process_recv_buffer(#state{buffer = <<Fin:1, 0:3, Opcode:4, 0:1, 126:7, PayloadLen:16, Payload:PayloadLen/binary, Rest/binary>>} = State0) ->
    State1 = process_frame(Payload, Fin, Opcode, State0#state{buffer = Rest}),
    process_recv_buffer(State1);
process_recv_buffer(#state{buffer = <<Fin:1, 0:3, Opcode:4, 0:1, 127:7, PayloadLen:32, Payload:PayloadLen/binary, Rest/binary>>} = State0) ->
    State1 = process_frame(Payload, Fin, Opcode, State0#state{buffer = Rest}),
    process_recv_buffer(State1);
process_recv_buffer(#state{buffer = <<Fin:1, 0:3, Opcode:4, 0:1, PayloadLen:7, Payload:PayloadLen/binary, Rest/binary>>} = State0) ->
    State1 = process_frame(Payload, Fin, Opcode, State0#state{buffer = Rest}),
    process_recv_buffer(State1);
process_recv_buffer(State0) ->
    State0.

%% @private
unmask(MaskingKey, MaskedPayload) ->
    unmask(MaskingKey, MaskedPayload, 0, []).

unmask(_MaskingKey, <<>>, _I, Accum) ->
    list_to_binary(lists:reverse(Accum));
unmask(MaskingKey, <<H:8, T/binary>>, I, Accum) ->
    MaskingOctet = octet(MaskingKey, I rem 4),
    unmask(MaskingKey, T, I + 1, [MaskingOctet bxor H | Accum]).

%% @private
octet(<<First:8, _/binary>>, 0) ->
    First;
octet(<<_:1/binary, Second:8, _/binary>>, 1) ->
    Second;
octet(<<_:2/binary, Third:8, _/binary>>, 2) ->
    Third;
octet(<<_:3/binary, Fourth:8, _/binary>>, 3) ->
    Fourth.

%% -- Frame assembly --

process_frame(Payload, 1, 0, #state{frames = {Opcode, Frames}} = State) ->
    process_message(Opcode, <<Frames/binary, Payload/binary>>, State#state{frames = undefined});
process_frame(Payload, 0, 0, #state{frames = {Opcode, Frames}} = State) ->
    State#state{frames = {Opcode, <<Frames/binary, Payload/binary>>}};
process_frame(Payload, 0, Opcode, #state{frames = undefined} = State) ->
    State#state{frames = {Opcode, Payload}};
process_frame(Payload, 1, Opcode, #state{frames = undefined} = State) ->
    process_message(Opcode, Payload, State).

%% -- Message dispatch --

process_message(?OPCODE_UTF8, Message, #state{controlling_process = ControllingProcess} = State) ->
    ControllingProcess ! {websocket, self(), Message},
    State;
process_message(?OPCODE_BINARY, Message, #state{controlling_process = ControllingProcess} = State) ->
    ControllingProcess ! {websocket, self(), Message},
    State;
process_message(?OPCODE_CLOSE, Payload, #state{controlling_process = ControllingProcess} = State) ->
    Message = case Payload of
        <<>> -> {true, 1000, <<>>};
        <<ReasonCode:16, ReasonMessage/binary>> -> {true, ReasonCode, ReasonMessage}
    end,
    ControllingProcess ! {websocket_close, self(), Message},
    State;
process_message(?OPCODE_PING, Message, #state{transport = Transport, is_server = IsServer} = State) ->
    PongMessage = case IsServer of
        true -> <<1:1, 0:3, ?OPCODE_PONG:4, 0:1, (byte_size(Message)):7, Message/binary>>;
        false ->
            MaskingKey = crypto:strong_rand_bytes(4),
            MaskedMsg = unmask(MaskingKey, Message),
            <<1:1, 0:3, ?OPCODE_PONG:4, 1:1, (byte_size(MaskedMsg)):7, MaskingKey/binary, MaskedMsg/binary>>
    end,
    ok = transport_send(Transport, PongMessage),
    State;
process_message(?OPCODE_PONG, _Message, #state{} = State) ->
    State.
