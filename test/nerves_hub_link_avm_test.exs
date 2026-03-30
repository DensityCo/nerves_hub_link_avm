defmodule NervesHubLinkAVMTest do
  use ExUnit.Case

  alias NervesHubLinkAVM.Channel

  defmodule MockWriter do
    @behaviour NervesHubLinkAVM.FwupWriter

    @impl true
    def fwup_begin(size, meta) do
      send(:test_proc, {:begin, size, meta})
      {:ok, %{chunks: []}}
    end

    @impl true
    def fwup_chunk(data, state) do
      {:ok, %{state | chunks: state.chunks ++ [data]}}
    end

    @impl true
    def fwup_finish(_state) do
      send(:test_proc, :finish)
      :ok
    end

    @impl true
    def fwup_confirm do
      send(:test_proc, :confirm)
      :ok
    end

    @impl true
    def fwup_abort(state) do
      send(:test_proc, {:abort, state})
      :ok
    end
  end

  defmodule MockClient do
    @behaviour NervesHubLinkAVM.Client

    @impl true
    def identify do
      send(:test_proc, :identify)
      :ok
    end

    @impl true
    def reboot do
      send(:test_proc, :reboot)
      :ok
    end

    @impl true
    def handle_connected, do: :ok
    @impl true
    def handle_disconnected, do: :ok
  end

  defp default_opts do
    [
      host: "hub.example.com",
      device_cert: "fake_cert",
      device_key: "fake_key",
      firmware_meta: %{
        "uuid" => "test-uuid",
        "product" => "test-product",
        "architecture" => "generic",
        "version" => "1.0.0",
        "platform" => "host"
      },
      fwup_writer: MockWriter,
      client: MockClient
    ]
  end

  describe "init/1" do
    test "initializes state from opts" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())

      assert state.config.auth == {:certificate, "fake_cert", "fake_key"}
      assert state.config.firmware_meta["uuid"] == "test-uuid"
      assert state.config.firmware_meta["platform"] == "host"
      assert state.config.fwup_writer == MockWriter
      assert state.config.client == MockClient
      assert state.msg_ref == 0
      assert state.phase == :disconnected
      assert state.backoff == 1_000

      assert_receive :connect
    end

    test "raises on missing required opts" do
      assert_raise KeyError, fn ->
        NervesHubLinkAVM.init(host: "example.com")
      end
    end

    test "raises on missing required firmware_meta keys" do
      opts = Keyword.put(default_opts(), :firmware_meta, %{"uuid" => "x"})

      assert_raise ArgumentError, ~r/missing required firmware metadata/, fn ->
        NervesHubLinkAVM.init(opts)
      end
    end

    test "defaults client to Client.Default" do
      opts = Keyword.delete(default_opts(), :client)
      {:ok, state} = NervesHubLinkAVM.init(opts)
      assert_receive :connect
      assert state.config.client == NervesHubLinkAVM.Client.Default
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
      {:noreply, state} = NervesHubLinkAVM.handle_info({:websocket_open, ws}, state)

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

    test "malformed JSON raises", %{state: state, ws: ws} do
      assert_raise MatchError, fn ->
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

    test "identify calls client's identify", %{state: state, ws: ws} do
      msg = Channel.encode_message("join_0", "ref_1", "device", "identify", %{})

      {:noreply, ^state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert_receive :identify
    end

    test "reboot calls client's reboot", %{state: state, ws: ws} do
      msg = Channel.encode_message("join_0", "ref_1", "device", "reboot", %{})

      {:noreply, ^state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert_receive :reboot
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
    test "calls writer's fwup_confirm when implemented" do
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

    test "does not set firmware_validated on writer error" do
      defmodule FailConfirmWriter do
        @behaviour NervesHubLinkAVM.FwupWriter
        def fwup_begin(_, _), do: {:ok, %{}}
        def fwup_chunk(_, s), do: {:ok, s}
        def fwup_finish(_), do: :ok
        def fwup_confirm, do: {:error, :nope}
        def fwup_abort(_), do: :ok
      end

      opts = Keyword.put(default_opts(), :fwup_writer, FailConfirmWriter)
      {:ok, state} = NervesHubLinkAVM.init(opts)
      assert_receive :connect
      state = %{state | ws_pid: self(), phase: :joined, join_ref: "join_0"}

      {:reply, {:error, :nope}, new_state} =
        NervesHubLinkAVM.handle_call(:confirm_update, {self(), make_ref()}, state)

      assert new_state.firmware_validated == false
    end

    test "sets firmware_validated when disconnected without crash" do
      Process.register(self(), :test_proc)
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect

      {:reply, :ok, new_state} =
        NervesHubLinkAVM.handle_call(:confirm_update, {self(), make_ref()}, state)

      assert new_state.firmware_validated == true
      assert_receive :confirm
    end
  end

  describe "firmware_validated default" do
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

    test "update with update_available transitions to updating", %{state: state, ws: ws} do
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

  describe "auth configuration" do
    test "certificate auth from opts" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      assert state.config.auth == {:certificate, "fake_cert", "fake_key"}
    end

    test "shared secret auth from opts" do
      opts = [
        host: "hub.example.com",
        product_key: "nhp_test123",
        product_secret: "secret456",
        identifier: "device-001",
        firmware_meta: %{
          "uuid" => "test-uuid",
          "product" => "test-product",
          "architecture" => "generic",
          "version" => "1.0.0",
          "platform" => "host"
        },
        fwup_writer: MockWriter
      ]

      {:ok, state} = NervesHubLinkAVM.init(opts)
      assert_receive :connect
      assert {:shared_secret, "nhp_test123", "secret456", "device-001"} = state.config.auth
    end

    test "raises when no auth method provided" do
      opts = [
        host: "hub.example.com",
        firmware_meta: %{
          "uuid" => "test-uuid",
          "product" => "test-product",
          "architecture" => "generic",
          "version" => "1.0.0",
          "platform" => "host"
        },
        fwup_writer: MockWriter
      ]

      assert_raise ArgumentError, ~r/must provide either/, fn ->
        NervesHubLinkAVM.init(opts)
      end
    end
  end

  describe "send_event while disconnected" do
    test "send_event cast is dropped when ws_pid is nil" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect

      {:noreply, ^state} =
        NervesHubLinkAVM.handle_cast({:send_event, "status_update", %{"status" => "test"}}, state)
    end

    test "send_event cast works when connected" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      state = %{state | ws_pid: self(), phase: :joined, join_ref: "join_0"}

      {:noreply, _state} =
        NervesHubLinkAVM.handle_cast({:send_event, "status_update", %{"status" => "test"}}, state)

      assert_receive {:"$gen_cast", {:send, 1, _data}}
    end
  end

  describe "disconnect clears extensions_join_ref" do
    test "extensions_join_ref is nil after disconnect" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      state = %{state | ws_pid: self(), phase: :joined, join_ref: "join_0", extensions_join_ref: "ext_0"}

      {:noreply, new_state} =
        NervesHubLinkAVM.handle_info({:websocket_close, self(), {true, 1000, "bye"}}, state)

      assert new_state.extensions_join_ref == nil
      assert new_state.phase == :disconnected
    end
  end

  describe "update process monitoring" do
    setup do
      Process.register(self(), :test_proc)
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      fake_ws = self()
      state = %{state | ws_pid: fake_ws, phase: :joined, join_ref: "join_0"}
      {:ok, state: state, ws: fake_ws}
    end

    test "phase returns to joined after update process exits", %{state: state, ws: ws} do
      payload = %{
        "update_available" => true,
        "firmware_url" => "https://example.com/fw.bin",
        "firmware_meta" => %{}
      }

      msg = Channel.encode_message("join_0", "ref_1", "device", "update", payload)
      {:noreply, new_state} = NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)
      assert new_state.phase == :updating

      assert_receive {:DOWN, _ref, :process, _pid, _reason}, 1000

      {:noreply, final_state} =
        NervesHubLinkAVM.handle_info({:DOWN, make_ref(), :process, self(), :normal}, new_state)

      assert final_state.phase == :joined
    end

    test "DOWN in non-updating phase is ignored" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      state = %{state | phase: :joined}

      {:noreply, ^state} =
        NervesHubLinkAVM.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)
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

  defmodule MockHealthProvider do
    @behaviour NervesHubLinkAVM.HealthProvider

    @impl true
    def health_check do
      %{"cpu_temp" => 42.5, "mem_used_percent" => 65}
    end
  end

  describe "extensions - init" do
    test "extensions default to empty map" do
      {:ok, state} = NervesHubLinkAVM.init(default_opts())
      assert_receive :connect
      assert state.config.extensions == %{}
    end

    test "extensions stored from opts" do
      opts = Keyword.put(default_opts(), :extensions, health: MockHealthProvider)
      {:ok, state} = NervesHubLinkAVM.init(opts)
      assert_receive :connect
      assert state.config.extensions == %{health: MockHealthProvider}
    end
  end

  describe "extensions - protocol" do
    setup do
      opts = Keyword.put(default_opts(), :extensions, health: MockHealthProvider)
      {:ok, state} = NervesHubLinkAVM.init(opts)
      assert_receive :connect
      fake_ws = self()
      state = %{state | ws_pid: fake_ws, phase: :joined, join_ref: "join_0"}
      {:ok, state: state, ws: fake_ws}
    end

    test "extensions:get triggers extensions join", %{state: state, ws: ws} do
      msg = Channel.encode_message("join_0", "ref_1", "device", "extensions:get", %{})

      {:noreply, new_state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert new_state.extensions_join_ref =~ "ext_"
    end

    test "extensions:get ignored when no extensions configured", %{state: state, ws: ws} do
      config = %{state.config | extensions: %{}}
      state = %{state | config: config}
      msg = Channel.encode_message("join_0", "ref_1", "device", "extensions:get", %{})

      {:noreply, new_state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert new_state.extensions_join_ref == nil
    end

    test "health:check calls provider and responds", %{state: state, ws: ws} do
      state = %{state | extensions_join_ref: "ext_0"}
      msg = Channel.encode_message("ext_0", "ref_1", "extensions", "health:check", %{})

      {:noreply, _state} =
        NervesHubLinkAVM.handle_info({:websocket, ws, IO.iodata_to_binary(msg)}, state)

      assert_receive {:"$gen_cast", {:send, 1, _data}}
    end
  end
end
