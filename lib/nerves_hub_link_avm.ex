defmodule NervesHubLinkAVM do
  @moduledoc """
  NervesHub client for AtomVM devices.

  Manages a WebSocket connection to a NervesHub server, handles the Phoenix
  channel protocol, and orchestrates firmware updates via `Client` and `FwupWriter`.

  ## Starting

      NervesHubLinkAVM.start_link(
        host: "your-nerveshub-server.com",
        device_cert: "/path/to/cert.pem",
        device_key: "/path/to/key.pem",
        firmware_meta: %{
          "uuid" => "...",
          "product" => "my-product",
          "architecture" => "esp32",
          "version" => "1.0.0",
          "platform" => "esp32"
        },
        client: MyApp.Client,
        fwup_writer: MyApp.ESP32Writer
      )

  ## Options

  * `:host` - NervesHub server hostname (required)
  * `:port` - server port (default: `443`)
  * `:ssl` - enable TLS (default: `true`)
  * `:device_cert` / `:device_key` - paths for mTLS authentication
  * `:product_key` / `:product_secret` / `:identifier` - shared secret authentication
  * `:firmware_meta` - map with keys: `uuid`, `product`, `architecture`, `version`, `platform`
  * `:client` - module implementing `NervesHubLinkAVM.Client` (default: `Client.Default`)
  * `:fwup_writer` - module implementing `NervesHubLinkAVM.FwupWriter` (required)
  * `:extensions` - keyword list of extensions, e.g. `[health: MyApp.HealthProvider]`
  * `:name` - GenServer name (default: `NervesHubLinkAVM`)
  """

  use GenServer

  alias NervesHubLinkAVM.Channel
  alias NervesHubLinkAVM.Client
  alias NervesHubLinkAVM.Configurator
  alias NervesHubLinkAVM.Extensions
  alias NervesHubLinkAVM.UpdateManager

  @heartbeat_interval 30_000
  @initial_backoff 1_000
  @max_backoff 30_000
  @device_api_version "2.2.0"

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

  def log(level, message, server \\ __MODULE__) do
    GenServer.cast(server, {:log, level, message})
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

  @impl true
  def handle_cast({:log, level, message}, state) do
    if Extensions.attached?(state.config.extensions, :logging) do
      send_extensions_message(state, "logging:send", build_log_payload(level, message))
    end

    {:noreply, state}
  end

  # -- Connection lifecycle --

  @impl true
  def handle_info(:connect, state) do
    config = state.config
    state = %{state | phase: :connecting, reconnect_ref: nil}

    IO.puts("NervesHubLinkAVM: connecting to #{config.url}")

    case :websocket.new(:erlang.binary_to_list(config.url), config.ws_opts) do
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
      {:ok, msg} ->
        handle_channel_message(msg, state)

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
    {:noreply, maybe_join_extensions(state)}
  end

  defp handle_channel_message(
         {_join_ref, _ref, "extensions", "phx_reply",
          %{"status" => "ok", "response" => attach_list}},
         state
       )
       when is_list(attach_list) do
    IO.puts("NervesHubLinkAVM: extensions joined, attaching: #{inspect(attach_list)}")

    updated_extensions = Extensions.mark_attached(attach_list, state.config.extensions)
    state = update_extensions(state, updated_extensions)

    Enum.each(Extensions.attachable(attach_list, state.config.extensions), fn ext ->
      send_extensions_message(state, "#{ext}:attached", %{})
    end)

    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, "extensions", scoped_event, payload}, state) do
    case Extensions.handle_event(scoped_event, payload, state.config.extensions) do
      {:reply, event, reply_payload, updated_extensions} ->
        send_extensions_message(state, event, reply_payload)
        {:noreply, update_extensions(state, updated_extensions)}

      {:noreply, updated_extensions} ->
        {:noreply, update_extensions(state, updated_extensions)}
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
      prefix_firmware_meta(state.config.firmware_meta)
      |> Map.merge(%{
        "device_api_version" => @device_api_version,
        "meta" => %{
          "firmware_validated" => state.firmware_validated,
          "firmware_auto_revert_detected" => false
        }
      })

    send_ws(state, join_ref, "device", "phx_join", payload)
    %{state | join_ref: join_ref}
  end

  defp prefix_firmware_meta(meta) do
    Enum.reduce(meta, %{}, fn {k, v}, acc ->
      Map.put(acc, "nerves_fw_" <> k, v)
    end)
  end

  defp send_heartbeat(state) do
    {ref, state} = next_ref(state)
    send_ws(state, nil, "phoenix", "heartbeat", %{}, "hb_#{ref}")
    state
  end

  defp send_channel_message(state, event, payload) do
    send_ws(state, state.join_ref, "device", event, payload)
  end

  defp maybe_join_extensions(state) do
    if Extensions.any?(state.config.extensions) and is_nil(state.extensions_join_ref),
      do: join_extensions(state),
      else: state
  end

  defp join_extensions(state) do
    {ref, state} = next_ref(state)
    join_ref = "ext_#{ref}"
    versions = Extensions.versions(state.config.extensions)
    send_ws(state, join_ref, "extensions", "phx_join", versions)
    %{state | extensions_join_ref: join_ref}
  end

  defp send_extensions_message(state, event, payload) do
    send_ws(state, state.extensions_join_ref, "extensions", event, payload)
  end

  defp build_log_payload(level, message) do
    %{
      "level" => normalize_log_level(level),
      "message" => NervesHubLinkAVM.LoggerHandler.format_message(message),
      "meta" => %{"time" => Integer.to_string(:erlang.system_time(:microsecond))}
    }
  end

  defp normalize_log_level(level) when is_atom(level), do: :erlang.atom_to_binary(level)
  defp normalize_log_level(level) when is_binary(level), do: level
  defp normalize_log_level(level), do: IO.iodata_to_binary(:io_lib.format("~p", [level]))

  defp update_extensions(state, updated) do
    %{state | config: %{state.config | extensions: updated}}
  end

  defp send_ws(state, join_ref, topic, event, payload, ref_str \\ nil) do
    {ref, _state} = next_ref(state)
    ref_str = ref_str || "ref_#{ref}"
    msg = Channel.encode_message(join_ref, ref_str, topic, event, payload)
    :websocket.send_utf8(state.ws_pid, :erlang.iolist_to_binary(msg))
  end

  defp next_ref(%State{msg_ref: ref} = state) do
    {ref, %{state | msg_ref: ref + 1}}
  end

  # -- Connection management --

  defp disconnect(state) do
    cancel_timer(state.heartbeat_ref)
    cancel_timer(state.reconnect_ref)
    config = %{state.config | extensions: Extensions.reset_attached(state.config.extensions)}

    %{
      state
      | phase: :disconnected,
        config: config,
        heartbeat_ref: nil,
        reconnect_ref: nil,
        ws_pid: nil,
        extensions_join_ref: nil
    }
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
end
