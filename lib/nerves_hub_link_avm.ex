defmodule NervesHubLinkAVM do
  @moduledoc false

  use GenServer

  alias NervesHubLinkAVM.Channel
  alias NervesHubLinkAVM.Client
  alias NervesHubLinkAVM.Configurator
  alias NervesHubLinkAVM.UpdateManager

  @heartbeat_interval 30_000
  @initial_backoff 1_000
  @max_backoff 30_000
  @device_api_version "2.0.0"

  # -- Public API --

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def reconnect(server \\ __MODULE__) do
    GenServer.cast(server, :reconnect)
  end

  def confirm_update(server \\ __MODULE__) do
    GenServer.call(server, :confirm_update)
  end

  # AtomVM entry point
  def start do
    IO.puts("NervesHubLinkAVM: start/0 called — call start_link/1 with config to connect")
    :ok
  end

  # -- State --

  defmodule State do
    @moduledoc false
    defstruct [
      :config,
      :ws_pid,
      :heartbeat_ref,
      :reconnect_ref,
      :join_ref,
      :extensions_join_ref,
      :msg_ref,
      phase: :disconnected,
      backoff: 1_000,
      firmware_validated: false
    ]
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    config = Configurator.build!(opts)

    state = %State{
      config: config,
      msg_ref: 0,
      backoff: @initial_backoff
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:confirm_update, _from, state) do
    writer = state.config.fwup_writer

    with :ok <- do_confirm(writer) do
      if state.phase == :joined, do: send_channel_message(state, "firmware_validated", %{})
      {:reply, :ok, %{state | firmware_validated: true}}
    else
      error -> {:reply, error, state}
    end
  end

  defp do_confirm(writer) do
    if function_exported?(writer, :fwup_confirm, 0),
      do: writer.fwup_confirm(),
      else: :ok
  end

  @impl true
  def handle_cast(:reconnect, state) do
    Client.call_disconnected(state.config.client)
    state = disconnect(state)
    send(self(), :connect)
    {:noreply, %{state | backoff: @initial_backoff}}
  end

  @impl true
  def handle_cast({:send_event, _event, _payload}, %State{ws_pid: nil} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_event, event, payload}, state) do
    send_channel_message(state, event, payload)
    {:noreply, state}
  end

  # -- Connection lifecycle --

  @impl true
  def handle_info(:connect, state) do
    config = state.config
    state = %{state | phase: :connecting, reconnect_ref: nil}

    IO.puts("NervesHubLinkAVM: connecting to #{config.url}")

    case open_websocket(config.url, config.ws_opts) do
      {:ok, ws} ->
        {:noreply, %{state | ws_pid: ws}}

      {:error, reason} ->
        IO.puts("NervesHubLinkAVM: connection failed: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info({:websocket_open, ws_pid}, %State{ws_pid: ws_pid} = state) do
    IO.puts("NervesHubLinkAVM: WebSocket connected")
    Client.call_connected(state.config.client)
    state = %{state | phase: :connected, backoff: @initial_backoff}
    state = send_join(state)
    {:noreply, state}
  end

  def handle_info({:websocket, ws_pid, raw}, %State{ws_pid: ws_pid} = state) do
    case Channel.decode_message(raw) do
      {:ok, msg} -> handle_channel_message(msg, state)
      {:error, reason} ->
        IO.puts("NervesHubLinkAVM: decode error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:websocket_close, ws_pid, _reason}, %State{ws_pid: ws_pid} = state) do
    IO.puts("NervesHubLinkAVM: WebSocket closed")
    Client.call_disconnected(state.config.client)
    state = disconnect(state)
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{phase: :updating} = state) do
    {:noreply, %{state | phase: :joined}}
  end

  def handle_info(:heartbeat, %State{phase: :joined} = state) do
    state = send_heartbeat(state)
    ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, %{state | heartbeat_ref: ref}}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Channel message handling --

  defp handle_channel_message(
         {_join_ref, _ref, "device", "phx_reply", %{"status" => "ok"}},
         state
       ) do
    IO.puts("NervesHubLinkAVM: joined device channel")
    ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)
    state = %{state | phase: :joined, heartbeat_ref: ref}

    state =
      if state.config.extensions != %{},
        do: join_extensions(state),
        else: state

    {:noreply, state}
  end

  defp handle_channel_message(
         {_join_ref, _ref, "device", "update",
          %{"update_available" => true, "firmware_url" => fw_url} = payload},
         state
       ) do
    meta = Map.get(payload, "firmware_meta", %{})
    IO.puts("NervesHubLinkAVM: update available")
    send_channel_message(state, "status_update", %{"status" => "received"})
    server = self()
    config = state.config
    state = %{state | phase: :updating}
    spawn(fn -> UpdateManager.run(fw_url, meta, config, server) end) |> Process.monitor()
    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, "device", "update", _payload}, state) do
    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, "device", "reboot", _payload}, state) do
    IO.puts("NervesHubLinkAVM: reboot requested")
    Client.call_reboot(state.config.client)
    send_channel_message(state, "rebooting", %{})
    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, "device", "identify", _payload}, state) do
    IO.puts("NervesHubLinkAVM: identify requested")
    Client.call_identify(state.config.client)
    {:noreply, state}
  end

  # -- Extensions --

  defp handle_channel_message({_join_ref, _ref, "device", "extensions:get", _payload}, state) do
    if state.config.extensions != %{} do
      {:noreply, join_extensions(state)}
    else
      {:noreply, state}
    end
  end

  defp handle_channel_message(
         {_join_ref, _ref, "extensions", "phx_reply", %{"status" => "ok", "response" => attach_list}},
         state
       )
       when is_list(attach_list) do
    IO.puts("NervesHubLinkAVM: extensions joined, attaching: #{inspect(attach_list)}")

    Enum.each(attach_list, fn ext ->
      send_extensions_message(state, "#{ext}:attached", %{})
    end)

    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, "extensions", "health:check", _payload}, state) do
    case Map.get(state.config.extensions, :health) do
      nil ->
        {:noreply, state}

      provider ->
        metrics = provider.health_check()
        payload = %{"value" => %{"metrics" => metrics, "timestamp" => iso8601_now()}}
        send_extensions_message(state, "health:report", payload)
        {:noreply, state}
    end
  end

  # -- Protocol fallbacks --

  defp handle_channel_message({nil, <<"hb_", _::binary>>, <<"phoenix">>, "phx_reply", _}, state) do
    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, _topic, "phx_error", payload}, state) do
    IO.puts("NervesHubLinkAVM: channel error: #{inspect(payload)}")
    state = disconnect(state)
    {:noreply, schedule_reconnect(state)}
  end

  defp handle_channel_message({_join_ref, _ref, _topic, "phx_close", _payload}, state) do
    IO.puts("NervesHubLinkAVM: channel closed")
    state = disconnect(state)
    {:noreply, schedule_reconnect(state)}
  end

  defp handle_channel_message(_msg, state) do
    {:noreply, state}
  end

  # -- Protocol helpers --

  defp send_join(state) do
    {ref, state} = next_ref(state)
    join_ref = "join_#{ref}"

    payload =
      state.config.firmware_meta
      |> Map.merge(%{
        "device_api_version" => @device_api_version,
        "meta" => %{
          "firmware_validated" => state.firmware_validated,
          "firmware_auto_revert_detected" => false
        }
      })

    msg = Channel.encode_message(join_ref, "ref_#{ref}", "device", "phx_join", payload)
    :websocket.send_utf8(state.ws_pid, :erlang.iolist_to_binary(msg))
    %{state | join_ref: join_ref}
  end

  defp send_heartbeat(state) do
    {ref, state} = next_ref(state)
    msg = Channel.encode_message(nil, "hb_#{ref}", "phoenix", "heartbeat", %{})
    :websocket.send_utf8(state.ws_pid, :erlang.iolist_to_binary(msg))
    state
  end

  defp send_channel_message(state, event, payload) do
    {ref, _state} = next_ref(state)
    msg = Channel.encode_message(state.join_ref, "ref_#{ref}", "device", event, payload)
    :websocket.send_utf8(state.ws_pid, :erlang.iolist_to_binary(msg))
  end

  defp join_extensions(state) do
    {ref, state} = next_ref(state)
    join_ref = "ext_#{ref}"

    versions =
      state.config.extensions
      |> Map.keys()
      |> Enum.reduce(%{}, fn key, acc -> Map.put(acc, :erlang.atom_to_binary(key), "0.0.1") end)

    msg = Channel.encode_message(join_ref, "ref_#{ref}", "extensions", "phx_join", versions)
    :websocket.send_utf8(state.ws_pid, :erlang.iolist_to_binary(msg))
    %{state | extensions_join_ref: join_ref}
  end

  defp send_extensions_message(state, event, payload) do
    {ref, _state} = next_ref(state)
    msg = Channel.encode_message(state.extensions_join_ref, "ref_#{ref}", "extensions", event, payload)
    :websocket.send_utf8(state.ws_pid, :erlang.iolist_to_binary(msg))
  end

  defp next_ref(%State{msg_ref: ref} = state) do
    {ref, %{state | msg_ref: ref + 1}}
  end

  # -- Connection management --

  defp open_websocket(url, opts) do
    {:ok, :websocket.new(:erlang.binary_to_list(url), opts)}
  rescue
    e -> {:error, e}
  catch
    _, reason -> {:error, reason}
  end

  defp disconnect(state) do
    cancel_timer(state.heartbeat_ref)
    cancel_timer(state.reconnect_ref)
    %{state | phase: :disconnected, heartbeat_ref: nil, reconnect_ref: nil, ws_pid: nil, extensions_join_ref: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp schedule_reconnect(state) do
    backoff = state.backoff
    IO.puts("NervesHubLinkAVM: reconnecting in #{backoff}ms")
    ref = Process.send_after(self(), :connect, backoff)
    new_backoff = min(backoff * 2, @max_backoff)
    %{state | phase: :disconnected, reconnect_ref: ref, backoff: new_backoff}
  end

  defp iso8601_now do
    seconds = :erlang.system_time(:second)
    {{y, mo, d}, {h, mi, s}} = :calendar.system_time_to_universal_time(seconds, :second)

    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [y, mo, d, h, mi, s])
    |> :erlang.iolist_to_binary()
  end
end
