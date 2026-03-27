defmodule NervesHubLinkAVM do
  @moduledoc false

  use GenServer

  alias NervesHubLinkAVM.Channel
  alias NervesHubLinkAVM.HTTPClient

  @heartbeat_interval 30_000
  @initial_backoff 1_000
  @max_backoff 30_000
  @device_api_version "2.0.0"

  # -- Public API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reconnect do
    GenServer.cast(__MODULE__, :reconnect)
  end

  def confirm_update do
    GenServer.call(__MODULE__, :confirm_update)
  end

  # AtomVM entry point
  def start do
    IO.puts("NervesHubLinkAVM: start/0 called — call start_link/1 with config to connect")
    :ok
  end

  # -- GenServer callbacks --

  defmodule State do
    @moduledoc false
    defstruct [
      :host,
      :port,
      :ssl,
      :device_cert,
      :device_key,
      :firmware_meta,
      :update_handler,
      :ws_pid,
      :heartbeat_ref,
      :reconnect_ref,
      :join_ref,
      :msg_ref,
      phase: :disconnected,
      backoff: 1_000
    ]
  end

  @impl true
  def init(opts) do
    state = %State{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, 443),
      ssl: Keyword.get(opts, :ssl, true),
      device_cert: Keyword.fetch!(opts, :device_cert),
      device_key: Keyword.fetch!(opts, :device_key),
      firmware_meta: Keyword.fetch!(opts, :firmware_meta),
      update_handler: Keyword.fetch!(opts, :update_handler),
      msg_ref: 0,
      backoff: @initial_backoff
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:confirm_update, _from, %State{update_handler: handler} = state) do
    result =
      if function_exported?(handler, :handle_confirm, 0) do
        handler.handle_confirm()
      else
        :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    state = disconnect(state)
    send(self(), :connect)
    {:noreply, %{state | backoff: @initial_backoff}}
  end

  def handle_cast({:send_event, event, payload}, state) do
    send_channel_message(state, event, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    state = %{state | phase: :connecting, reconnect_ref: nil}
    url = build_ws_url(state)

    IO.puts("NervesHubLinkAVM: connecting to #{url}")

    try do
      ws = :websocket.new(String.to_charlist(url))
      {:noreply, %{state | ws_pid: ws}}
    rescue
      e ->
        IO.puts("NervesHubLinkAVM: connection failed: #{inspect(e)}")
        {:noreply, schedule_reconnect(state)}
    catch
      kind, reason ->
        IO.puts("NervesHubLinkAVM: connection failed: #{inspect(kind)} #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info({:websocket_open, ws_pid}, %State{ws_pid: ws_pid} = state) do
    IO.puts("NervesHubLinkAVM: WebSocket connected")
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
    state = disconnect(state)
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info(:heartbeat, %State{phase: :joined} = state) do
    state = send_heartbeat(state)
    ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, %{state | heartbeat_ref: ref}}
  end

  def handle_info(:heartbeat, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Channel message handling --

  defp handle_channel_message({_join_ref, _ref, "device", "phx_reply", %{"status" => "ok"}}, state) do
    IO.puts("NervesHubLinkAVM: joined device channel")
    ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, %{state | phase: :joined, heartbeat_ref: ref}}
  end

  defp handle_channel_message({_join_ref, _ref, "device", "update", payload}, state) do
    case payload do
      %{"update_available" => true, "firmware_url" => fw_url} ->
        meta = Map.get(payload, "firmware_meta", %{})
        IO.puts("NervesHubLinkAVM: update available")
        state = %{state | phase: :updating}
        spawn_link(fn -> do_update(fw_url, meta, state) end)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_channel_message({_join_ref, _ref, "device", "reboot", _payload}, state) do
    IO.puts("NervesHubLinkAVM: reboot requested")
    send_channel_message(state, "rebooting", %{})
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

  # -- Update pipeline --

  defp do_update(fw_url, meta, state) do
    handler = state.update_handler
    parent = self()

    result =
      with {:ok, size} <- get_firmware_size(fw_url),
           {:ok, handler_state} <- handler.handle_begin(size, meta) do
        stream_firmware(fw_url, size, handler, handler_state, parent)
      end

    case result do
      {:ok, handler_state} ->
        sha256 = Map.get(meta, "sha256", <<>>)

        case handler.handle_finish(sha256, handler_state) do
          :ok ->
            IO.puts("NervesHubLinkAVM: update complete")

          {:error, reason} ->
            IO.puts("NervesHubLinkAVM: handle_finish failed: #{inspect(reason)}")
            send_status(parent, "update_failed")
        end

      {:error, reason, handler_state} ->
        IO.puts("NervesHubLinkAVM: update failed: #{inspect(reason)}")
        handler.handle_abort(handler_state)
        send_status(parent, "update_failed")

      {:error, reason} ->
        IO.puts("NervesHubLinkAVM: update failed: #{inspect(reason)}")
        send_status(parent, "update_failed")
    end
  end

  defp get_firmware_size(fw_url) do
    case HTTPClient.get_content_length(fw_url) do
      {:ok, size} -> {:ok, size}
      {:error, _} -> {:ok, 0}
    end
  end

  defp stream_firmware(fw_url, total_size, handler, handler_state, parent) do
    init_acc = %{
      handler: handler,
      handler_state: handler_state,
      bytes_received: 0,
      total_size: total_size,
      parent: parent,
      last_progress: -1
    }

    case HTTPClient.get_stream(fw_url, init_acc, &stream_chunk_callback/2) do
      {:ok, %{handler_state: hs}} -> {:ok, hs}
      {:error, reason} -> {:error, reason, handler_state}
    end
  end

  defp stream_chunk_callback(chunk, acc) do
    case acc.handler.handle_chunk(chunk, acc.handler_state) do
      {:ok, new_hs} ->
        bytes = acc.bytes_received + byte_size(chunk)

        progress =
          if acc.total_size > 0 do
            trunc(bytes / acc.total_size * 100)
          else
            0
          end

        if progress > acc.last_progress do
          send_progress(acc.parent, progress)
        end

        {:ok, %{acc | handler_state: new_hs, bytes_received: bytes, last_progress: progress}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_progress(parent, value) do
    GenServer.cast(parent, {:send_event, "fwup_progress", %{"value" => value}})
  end

  defp send_status(parent, status) do
    GenServer.cast(parent, {:send_event, "status_update", %{"status" => status}})
  end

  # -- Protocol helpers --

  defp build_ws_url(%State{host: host, port: port, ssl: ssl}) do
    scheme = if ssl, do: "wss", else: "ws"
    "#{scheme}://#{host}:#{port}/socket/websocket"
  end

  defp send_join(state) do
    {ref, state} = next_ref(state)
    join_ref = "join_#{ref}"
    payload = Map.merge(state.firmware_meta, %{"device_api_version" => @device_api_version})
    msg = Channel.encode_message(join_ref, "ref_#{ref}", "device", "phx_join", payload)
    :websocket.send_utf8(state.ws_pid, IO.iodata_to_binary(msg))
    %{state | join_ref: join_ref}
  end

  defp send_heartbeat(state) do
    {ref, state} = next_ref(state)
    msg = Channel.encode_message(nil, "hb_#{ref}", "phoenix", "heartbeat", %{})
    :websocket.send_utf8(state.ws_pid, IO.iodata_to_binary(msg))
    state
  end

  defp send_channel_message(state, event, payload) do
    {ref, _state} = next_ref(state)
    msg = Channel.encode_message(state.join_ref, "ref_#{ref}", "device", event, payload)
    :websocket.send_utf8(state.ws_pid, IO.iodata_to_binary(msg))
  end

  defp next_ref(%State{msg_ref: ref} = state) do
    {ref, %{state | msg_ref: ref + 1}}
  end

  # -- Connection management --

  defp disconnect(state) do
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
    if state.reconnect_ref, do: Process.cancel_timer(state.reconnect_ref)
    %{state | phase: :disconnected, heartbeat_ref: nil, reconnect_ref: nil, ws_pid: nil}
  end

  defp schedule_reconnect(state) do
    backoff = state.backoff
    IO.puts("NervesHubLinkAVM: reconnecting in #{backoff}ms")
    ref = Process.send_after(self(), :connect, backoff)
    new_backoff = min(backoff * 2, @max_backoff)
    %{state | phase: :disconnected, reconnect_ref: ref, backoff: new_backoff}
  end
end
