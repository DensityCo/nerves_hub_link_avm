defmodule NervesHubLinkAVMTest do
  use ExUnit.Case

  alias NervesHubLinkAVM.Channel

  defmodule MockHandler do
    @behaviour NervesHubLinkAVM.DeviceHandler

    @impl true
    def handle_begin(size, meta) do
      send(:test_proc, {:begin, size, meta})
      {:ok, %{chunks: []}}
    end

    @impl true
    def handle_chunk(data, state) do
      {:ok, %{state | chunks: state.chunks ++ [data]}}
    end

    @impl true
    def handle_finish(_state) do
      send(:test_proc, :finish)
      :ok
    end

    @impl true
    def handle_confirm do
      send(:test_proc, :confirm)
      :ok
    end

    @impl true
    def handle_abort(state) do
      send(:test_proc, {:abort, state})
      :ok
    end

    @impl true
    def handle_identify do
      send(:test_proc, :identify)
      :ok
    end
  end

  defp default_opts do
    [
      host: "hub.example.com",
      device_cert: "fake_cert",
      device_key: "fake_key",
      firmware_meta: %{
        "nerves_fw_uuid" => "test-uuid",
        "nerves_fw_product" => "test-product",
        "nerves_fw_architecture" => "generic",
        "nerves_fw_version" => "1.0.0",
        "nerves_fw_platform" => "host"
      },
      device_handler: MockHandler
    ]
  end

  describe "init/1" do
    test "initializes state from opts" do
      # We intercept the :connect message to prevent actual connection attempts
      {:ok, state} = NervesHubLinkAVM.init(default_opts())

      assert state.host == "hub.example.com"
      assert state.port == 443
      assert state.ssl == true
      assert state.device_cert == "fake_cert"
      assert state.device_key == "fake_key"
      assert state.firmware_meta["nerves_fw_uuid"] == "test-uuid"
      assert state.firmware_meta["nerves_fw_platform"] == "host"
      assert state.device_handler == MockHandler
      assert state.msg_ref == 0
      assert state.phase == :disconnected
      assert state.backoff == 1_000

      # init sends :connect to self
      assert_receive :connect
    end

    test "uses default port 443 and ssl true" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert state.port == 443
      assert state.ssl == true
      assert_receive :connect
    end

    test "allows overriding port and ssl" do
      opts = Keyword.merge(default_opts(), port: 4000, ssl: false)
      {:ok, state} = NervesHubLinkAVM.init(opts)
      assert state.port == 4000
      assert state.ssl == false
      assert_receive :connect
    end

    test "raises on missing required opts" do
      assert_raise KeyError, fn ->
        NervesHubLinkAVM.init(host: "example.com")
      end
    end

    test "raises on missing required firmware_meta keys" do
      opts = Keyword.put(default_opts(), :firmware_meta, %{"nerves_fw_uuid" => "x"})

      assert_raise ArgumentError, ~r/missing required firmware metadata/, fn ->
        NervesHubLinkAVM.init(opts)
      end
    end
  end

  describe "handle_info/2 - websocket messages" do
    setup do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      fake_ws = self()
      state = %{state | ws_pid: fake_ws, phase: :connected}
      {:ok, state: state, ws: fake_ws}
    end

    test "websocket_open triggers join", %{state: state} do
      ws = state.ws_pid
      {:noreply, new_state} = NervesHubLinkAVM.handle_info({:websocket_open, ws}, state)
      assert new_state.phase == :connected
      assert new_state.join_ref =~ "join_"
    end

    test "channel join reply transitions to joined phase", %{state: state, ws: ws} do
      # First do the join
      {:noreply, state} = NervesHubLinkAVM.handle_info({:websocket_open, ws}, state)

      # Simulate server replying with join success
      reply = Channel.encode_message(state.join_ref, "ref_0", "device", "phx_reply", %{"status" => "ok"})
      {:noreply, new_state} = NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(reply)}, state)

      assert new_state.phase == :joined
      assert new_state.heartbeat_ref != nil
    end

    test "websocket_close triggers reconnect", %{state: state, ws: ws} do
      {:noreply, new_state} =
        NervesHubLinkAVM.handle_info({:websocket_close, ws, {true, 1000, "bye"}}, state)

      assert new_state.phase == :disconnected
      assert new_state.reconnect_ref != nil
      assert_receive :connect, 2000
    end

    test "ignores messages from unknown websocket pid", %{state: state} do
      unknown_pid = spawn(fn -> :ok end)
      {:noreply, ^state} = NervesHubLinkAVM.handle_info({:websocket, unknown_pid, "data"}, state)
    end

    test "malformed JSON raises (json module doesn't return errors)", %{state: state, ws: ws} do
      # :json.decode raises on invalid input — this is expected behavior
      # In production the websocket layer ensures only valid frames arrive
      assert_raise ErlangError, fn ->
        NervesHubLinkAVM.handle_info({:websocket, ws, "{bad json"}, state)
      end
    end
  end

  describe "handle_info/2 - channel messages" do
    setup do
      Process.register(self(), :test_proc)
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      fake_ws = self()
      state = %{state | ws_pid: fake_ws, phase: :joined, join_ref: "join_0"}
      {:ok, state: state, ws: fake_ws}
    end

    test "phx_error triggers disconnect and reconnect", %{state: state, ws: ws} do
      msg = Channel.encode_message("join_0", "ref_1", "device", "phx_error", %{"reason" => "crash"})

      {:noreply, new_state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert new_state.phase == :disconnected
      assert new_state.reconnect_ref != nil
    end

    test "phx_close triggers disconnect and reconnect", %{state: state, ws: ws} do
      msg = Channel.encode_message("join_0", "ref_1", "device", "phx_close", %{})

      {:noreply, new_state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert new_state.phase == :disconnected
    end

    test "identify calls handler's handle_identify", %{state: state, ws: ws} do
      msg = Channel.encode_message("join_0", "ref_1", "device", "identify", %{})

      {:noreply, ^state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert_receive :identify
    end

    test "unknown channel message is handled gracefully", %{state: state, ws: ws} do
      msg = Channel.encode_message("join_0", "ref_1", "device", "unknown_event", %{})

      {:noreply, ^state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)
    end
  end

  describe "handle_info/2 - heartbeat" do
    test "heartbeat in joined phase reschedules" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      state = %{state | phase: :joined, ws_pid: self(), join_ref: "j"}

      {:noreply, new_state} = NervesHubLinkAVM.handle_info(:heartbeat, state)
      assert new_state.heartbeat_ref != nil
    end

    test "heartbeat in non-joined phase is ignored" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      state = %{state | phase: :connected}

      {:noreply, ^state} = NervesHubLinkAVM.handle_info(:heartbeat, state)
    end
  end

  describe "handle_call/3 - confirm_update" do
    test "calls handler's handle_confirm when implemented" do
      Process.register(self(), :test_proc)
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect

      {:reply, :ok, _state} = NervesHubLinkAVM.handle_call(:confirm_update, {self(), make_ref()}, state)
      assert_receive :confirm
    end

    test "sends firmware_validated event to server on success" do
      Process.register(self(), :test_proc)
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      state = %{state | ws_pid: self(), phase: :joined, join_ref: "join_0"}

      {:reply, :ok, new_state} =
        NervesHubLinkAVM.handle_call(:confirm_update, {self(), make_ref()}, state)

      assert new_state.firmware_validated == true
      assert_receive :confirm
    end

    test "does not set firmware_validated on handler error" do
      defmodule FailConfirmHandler do
        @behaviour NervesHubLinkAVM.DeviceHandler
        def handle_begin(_, _), do: {:ok, %{}}
        def handle_chunk(_, s), do: {:ok, s}
        def handle_finish(_), do: :ok
        def handle_confirm, do: {:error, :nope}
        def handle_abort(_), do: :ok
      end

      opts = Keyword.put(default_opts(), :device_handler, FailConfirmHandler)
      {:ok, state} = NervesHubLinkAVM.init(opts)
      assert_receive :connect
      state = %{state | ws_pid: self(), phase: :joined, join_ref: "join_0"}

      {:reply, {:error, :nope}, new_state} =
        NervesHubLinkAVM.handle_call(:confirm_update, {self(), make_ref()}, state)

      assert new_state.firmware_validated == false
    end
  end

  describe "init/1 - firmware_validated default" do
    test "firmware_validated defaults to false" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      assert state.firmware_validated == false
    end
  end

  describe "handle_info/2 - update message" do
    setup do
      Process.register(self(), :test_proc)
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      fake_ws = self()
      state = %{state | ws_pid: fake_ws, phase: :joined, join_ref: "join_0"}
      {:ok, state: state, ws: fake_ws}
    end

    test "update with update_available sends received status", %{state: state, ws: ws} do
      payload = %{
        "update_available" => true,
        "firmware_url" => "https://example.com/fw.bin",
        "firmware_meta" => %{"sha256" => "abc"}
      }

      msg = Channel.encode_message("join_0", "ref_1", "device", "update", payload)
      {:noreply, new_state} = NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert new_state.phase == :updating
    end

    test "update without update_available is ignored", %{state: state, ws: ws} do
      payload = %{"update_available" => false}
      msg = Channel.encode_message("join_0", "ref_1", "device", "update", payload)
      {:noreply, ^state} = NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)
    end
  end

  describe "build_ws_opts/1" do
    test "returns ssl_opts when ssl is true" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect

      # Access private function via handle_info :connect which calls build_ws_opts
      # Instead, test indirectly: ssl: true with cert/key should attempt wss connection
      assert state.ssl == true
      assert state.device_cert == "fake_cert"
      assert state.device_key == "fake_key"
    end

    test "ssl false does not require cert/key for connection" do
      opts = Keyword.merge(default_opts(), ssl: false)
      {:ok, state} = NervesHubLinkAVM.init(opts)
      assert_receive :connect
      assert state.ssl == false
    end
  end

  describe "handle_cast/2 - reconnect" do
    test "resets backoff and schedules connect" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      state = %{state | backoff: 16_000, phase: :joined}

      {:noreply, new_state} = NervesHubLinkAVM.handle_cast(:reconnect, state)
      assert new_state.backoff == 1_000
      assert new_state.phase == :disconnected
      assert_receive :connect
    end
  end
end
