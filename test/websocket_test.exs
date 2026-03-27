defmodule WebsocketTest do
  use ExUnit.Case

  @moduletag :websocket

  describe "websocket client with TCP echo server" do
    test "connects and completes handshake" do
      {port, server_ref} = start_ws_server()
      pid = :websocket.new(~c"ws://localhost:#{port}/test")

      assert is_pid(pid)
      assert_receive {:websocket_open, ^pid}, 2000

      # Clean up
      stop_ws_server(server_ref)
    end

    test "sends and receives utf8 messages" do
      {port, server_ref} = start_ws_server()
      pid = :websocket.new(~c"ws://localhost:#{port}/test")
      assert_receive {:websocket_open, ^pid}, 2000

      :websocket.send_utf8(pid, <<"hello websocket">>)

      # The echo server sends back what it receives
      assert_receive {:websocket, ^pid, <<"hello websocket">>}, 2000

      stop_ws_server(server_ref)
    end

    test "sends and receives binary messages" do
      {port, server_ref} = start_ws_server()
      pid = :websocket.new(~c"ws://localhost:#{port}/test")
      assert_receive {:websocket_open, ^pid}, 2000

      :websocket.send_binary(pid, <<1, 2, 3, 4, 5>>)

      assert_receive {:websocket, ^pid, <<1, 2, 3, 4, 5>>}, 2000

      stop_ws_server(server_ref)
    end

    test "sends and receives multiple messages" do
      {port, server_ref} = start_ws_server()
      pid = :websocket.new(~c"ws://localhost:#{port}/test")
      assert_receive {:websocket_open, ^pid}, 2000

      for i <- 1..5 do
        msg = "message_#{i}"
        :websocket.send_utf8(pid, msg)
        assert_receive {:websocket, ^pid, ^msg}, 2000
      end

      stop_ws_server(server_ref)
    end

    test "handles server-initiated close" do
      {port, server_ref} = start_ws_server()
      pid = :websocket.new(~c"ws://localhost:#{port}/test")
      assert_receive {:websocket_open, ^pid}, 2000

      # Tell server to send close frame
      send(server_ref, {:send_close, 1000, <<"normal closure">>})

      assert_receive {:websocket_close, ^pid, {true, 1000, <<"normal closure">>}}, 2000

      stop_ws_server(server_ref)
    end

    test "responds to pings with pongs" do
      {port, server_ref} = start_ws_server()
      pid = :websocket.new(~c"ws://localhost:#{port}/test")
      assert_receive {:websocket_open, ^pid}, 2000

      # Tell server to send a ping
      send(server_ref, {:send_ping, <<"ping_data">>})

      # Server should receive pong back
      assert_receive {:pong_received, <<"ping_data">>}, 2000

      stop_ws_server(server_ref)
    end

    test "controlling_process transfers message delivery" do
      {port, server_ref} = start_ws_server()
      pid = :websocket.new(~c"ws://localhost:#{port}/test")
      assert_receive {:websocket_open, ^pid}, 2000

      test_pid = self()

      new_owner =
        spawn(fn ->
          receive do
            {:websocket, ws_pid, msg} ->
              send(test_pid, {:forwarded, ws_pid, msg})
          after
            2000 -> send(test_pid, :timeout)
          end
        end)

      :ok = :websocket.controlling_process(pid, new_owner)
      :websocket.send_utf8(pid, <<"after transfer">>)

      assert_receive {:forwarded, ^pid, <<"after transfer">>}, 2000

      stop_ws_server(server_ref)
    end
  end

  # -- Minimal WebSocket echo server --

  defp start_ws_server do
    test_pid = self()

    {:ok, listen_socket} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.setopt(listen_socket, {:socket, :reuseaddr}, true)
    :ok = :socket.bind(listen_socket, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    :ok = :socket.listen(listen_socket, 1)
    {:ok, %{port: port}} = :socket.sockname(listen_socket)

    # Signal that we're listening before accepting (accept blocks until client connects)
    server_pid =
      spawn_link(fn ->
        send(test_pid, {:listening, self()})
        {:ok, client} = :socket.accept(listen_socket, 5000)
        handshake_server(client)
        echo_loop(client, test_pid)
      end)

    receive do
      {:listening, ^server_pid} -> :ok
    after
      2000 -> raise "Server failed to start"
    end

    {port, server_pid}
  end

  defp stop_ws_server(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp handshake_server(socket) do
    {:ok, request} = recv_http(socket, <<>>)
    key = extract_ws_key(request)
    accept = compute_accept(key)

    response = [
      "HTTP/1.1 101 Switching Protocols\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Accept: ",
      accept,
      "\r\n\r\n"
    ]

    :ok = :socket.send(socket, IO.iodata_to_binary(response))
  end

  defp recv_http(socket, acc) do
    case :socket.recv(socket, 0, 5000) do
      {:ok, data} ->
        buf = <<acc::binary, data::binary>>

        if String.contains?(buf, "\r\n\r\n") do
          {:ok, buf}
        else
          recv_http(socket, buf)
        end

      {:error, _} = err ->
        err
    end
  end

  defp extract_ws_key(request) do
    request
    |> String.split("\r\n")
    |> Enum.find_value(fn
      "Sec-WebSocket-Key: " <> key -> String.trim(key)
      _ -> nil
    end)
  end

  defp compute_accept(key) do
    magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    :base64.encode(:crypto.hash(:sha, key <> magic))
  end

  defp echo_loop(socket, test_pid) do
    receive do
      {:send_close, code, reason} ->
        payload = <<code::16, reason::binary>>
        frame = <<1::1, 0::3, 8::4, 0::1, byte_size(payload)::7, payload::binary>>
        :socket.send(socket, frame)
        echo_loop(socket, test_pid)

      {:send_ping, data} ->
        frame = <<1::1, 0::3, 9::4, 0::1, byte_size(data)::7, data::binary>>
        :socket.send(socket, frame)
        echo_loop(socket, test_pid)
    after
      0 ->
        case :socket.recv(socket, 0, 100) do
          {:ok, data} ->
            handle_ws_frames(socket, test_pid, data)
            echo_loop(socket, test_pid)

          {:error, :timeout} ->
            echo_loop(socket, test_pid)

          {:error, _} ->
            :ok
        end
    end
  end

  defp handle_ws_frames(socket, test_pid, data) do
    case data do
      <<_fin::1, 0::3, opcode::4, 1::1, len::7, mask::4-binary, payload::size(len)-binary,
        _rest::binary>>
      when len < 126 ->
        unmasked = unmask(mask, payload)

        case opcode do
          10 ->
            # Pong received
            send(test_pid, {:pong_received, unmasked})

          _ ->
            # Echo back (server frames are unmasked)
            reply = <<1::1, 0::3, opcode::4, 0::1, len::7, unmasked::binary>>
            :socket.send(socket, reply)
        end

      _ ->
        :ok
    end
  end

  defp unmask(mask, payload) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, Enum.at(mask_bytes, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end
end
