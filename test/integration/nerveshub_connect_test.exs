defmodule NervesHubLinkAVM.Integration.ConnectTest do
  use ExUnit.Case

  @moduletag :integration

  alias NervesHubLinkAVM.Channel

  # Integration test that connects to a local NervesHub server over WebSocket,
  # joins the device channel, and exchanges heartbeats.
  #
  # Configure via environment variables:
  #   NERVESHUB_HOST  (default: localhost)
  #   NERVESHUB_PORT  (default: 4001 — NervesHub device channel)
  #   NERVESHUB_SSL   (default: true)
  #
  # Requires test/integration/local-device.pem and local-device-key.pem
  #
  # Run with:
  #   mix test --include integration
  #   mix test.integration

  @cert_path Path.expand("test-device-chain.pem", __DIR__)
  @key_path Path.expand("test-device-key.pem", __DIR__)
  @ca_path Path.expand("test-ca.pem", __DIR__)

  defp config do
    host = System.get_env("NERVESHUB_HOST", "localhost")
    port = String.to_integer(System.get_env("NERVESHUB_PORT", "4001"))
    ssl = System.get_env("NERVESHUB_SSL", "true") == "true"
    scheme = if ssl, do: "wss", else: "ws"
    {host, port, ssl, scheme}
  end

  defp ws_url do
    {host, port, _ssl, scheme} = config()
    "#{scheme}://#{host}:#{port}/socket/websocket?vsn=2.0.0"
  end

  defp ws_opts do
    {_host, _port, ssl, _scheme} = config()

    if ssl do
      [
        ssl_opts: [
          {:certfile, String.to_charlist(@cert_path)},
          {:keyfile, String.to_charlist(@key_path)},
          {:cacertfile, String.to_charlist(@ca_path)},
          {:versions, [:"tlsv1.2"]}
        ]
      ]
    else
      []
    end
  end

  defp connect do
    url = ws_url()
    pid = :websocket.new(String.to_charlist(url), ws_opts())
    {url, pid}
  end

  describe "NervesHub WebSocket connection" do
    test "connects to the server" do
      {url, pid} = connect()
      IO.puts("\n  Connecting to #{url}")

      assert is_pid(pid), "websocket.new should return a pid"

      assert_receive {:websocket_open, ^pid}, 5000,
        "Expected websocket_open within 5s — is NervesHub running at #{url}?"

      IO.puts("  Connected successfully")
    end

    test "joins the device channel and receives reply" do
      {_url, pid} = connect()
      assert_receive {:websocket_open, ^pid}, 5000

      # Send a Phoenix channel join
      join_ref = "join_1"
      ref = "ref_1"
      payload = %{
        "device_api_version" => "2.0.0",
        "nerves_fw_uuid" => "test-integration-uuid",
        "nerves_fw_product" => "SmartKiosk",
        "nerves_fw_architecture" => "generic",
        "nerves_fw_version" => "0.0.1",
        "nerves_fw_platform" => "host"
      }

      msg = Channel.encode_message(join_ref, ref, "device", "phx_join", payload)
      :websocket.send_utf8(pid, IO.iodata_to_binary(msg))

      # Wait for the join reply
      receive do
        {:websocket, ^pid, raw} ->
          IO.puts("  Received: #{raw}")

          case Channel.decode_message(raw) do
            {:ok, {^join_ref, ^ref, "device", "phx_reply", reply_payload}} ->
              IO.puts("  Join reply status: #{inspect(reply_payload["status"])}")
              assert is_map(reply_payload), "Expected a map payload in reply"

            {:ok, {_jr, _r, topic, event, payload}} ->
              IO.puts("  Got #{topic}:#{event} -> #{inspect(payload)}")

            {:error, reason} ->
              flunk("Failed to decode reply: #{inspect(reason)}")
          end

        {:websocket_close, ^pid, reason} ->
          flunk("WebSocket closed before join reply: #{inspect(reason)}")
      after
        5000 ->
          flunk("No reply received within 5s after join")
      end
    end

    test "sends heartbeat and receives reply" do
      {_url, pid} = connect()
      assert_receive {:websocket_open, ^pid}, 5000

      ref = "hb_1"
      msg = Channel.encode_message(nil, ref, "phoenix", "heartbeat", %{})
      :websocket.send_utf8(pid, IO.iodata_to_binary(msg))

      receive do
        {:websocket, ^pid, raw} ->
          IO.puts("  Heartbeat reply: #{raw}")
          {:ok, {_jr, ^ref, "phoenix", "phx_reply", payload}} = Channel.decode_message(raw)
          assert payload["status"] == "ok", "Expected heartbeat reply with status ok"
          IO.puts("  Heartbeat acknowledged")

        {:websocket_close, ^pid, reason} ->
          flunk("WebSocket closed before heartbeat reply: #{inspect(reason)}")
      after
        5000 ->
          flunk("No heartbeat reply within 5s")
      end
    end

    test "full lifecycle: connect -> join -> heartbeat -> disconnect" do
      {url, pid} = connect()
      IO.puts("\n  Full lifecycle test against #{url}")

      # 1. Connect
      assert_receive {:websocket_open, ^pid}, 5000
      IO.puts("  [1/4] Connected")

      # 2. Join
      join_payload = %{
        "device_api_version" => "2.0.0",
        "nerves_fw_uuid" => "lifecycle-test-uuid",
        "nerves_fw_product" => "SmartKiosk",
        "nerves_fw_architecture" => "generic",
        "nerves_fw_version" => "0.0.1",
        "nerves_fw_platform" => "host"
      }

      join_msg = Channel.encode_message("join_1", "ref_1", "device", "phx_join", join_payload)
      :websocket.send_utf8(pid, IO.iodata_to_binary(join_msg))

      join_reply = receive_ws_message(pid, 5000)
      IO.puts("  [2/4] Join reply: #{inspect(elem(join_reply, 3))} -> #{inspect(elem(join_reply, 4))}")

      # 3. Heartbeat
      hb_msg = Channel.encode_message(nil, "hb_1", "phoenix", "heartbeat", %{})
      :websocket.send_utf8(pid, IO.iodata_to_binary(hb_msg))

      hb_reply = receive_ws_message(pid, 5000)
      IO.puts("  [3/4] Heartbeat reply: #{inspect(elem(hb_reply, 4))}")

      # 4. Disconnect
      :websocket.send_binary(pid, <<3::16, "bye">>)
      IO.puts("  [4/4] Disconnected")
    end
  end

  defp receive_ws_message(pid, timeout) do
    receive do
      {:websocket, ^pid, raw} ->
        case Channel.decode_message(raw) do
          {:ok, msg} -> msg
          {:error, reason} -> flunk("Decode error: #{inspect(reason)}")
        end

      {:websocket_close, ^pid, reason} ->
        flunk("WebSocket closed unexpectedly: #{inspect(reason)}")
    after
      timeout -> flunk("No message received within #{timeout}ms")
    end
  end
end
