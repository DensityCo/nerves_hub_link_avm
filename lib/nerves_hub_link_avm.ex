defmodule NervesHubLinkAVM do
  @moduledoc false

  use GenServer

  alias NervesHubLinkAVM.Channel
  alias NervesHubLinkAVM.HTTPClient

  @heartbeat_interval 30_000
  @initial_backoff 1_000
  @max_backoff 30_000
  @device_api_version "2.0.0"
  @required_firmware_meta_keys [
    "uuid",
    "product",
    "architecture",
    "version",
    "platform"
  ]

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

  # -- GenServer callbacks --

  defmodule State do
    @moduledoc false
    defstruct [
      :host,
      :port,
      :ssl,
      :auth,
      :firmware_meta,
      :device_handler,
      :ws_pid,
      :heartbeat_ref,
      :reconnect_ref,
      :join_ref,
      :extensions_join_ref,
      :msg_ref,
      :http_client,
      extensions: %{},
      phase: :disconnected,
      backoff: 1_000,
      firmware_validated: false
    ]
  end

  @impl true
  def init(opts) do
    firmware_meta = Keyword.fetch!(opts, :firmware_meta)
    validate_firmware_meta!(firmware_meta)

    state = %State{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, 443),
      ssl: Keyword.get(opts, :ssl, true),
      auth: build_auth(opts),
      firmware_meta: firmware_meta,
      device_handler: Keyword.fetch!(opts, :device_handler),
      extensions: Map.new(Keyword.get(opts, :extensions, [])),
      http_client: Keyword.get(opts, :http_client, HTTPClient),
      msg_ref: 0,
      backoff: @initial_backoff
    }

    send(self(), :connect)
    {:ok, state}
  end

  defp build_auth(opts) do
    cond do
      Keyword.has_key?(opts, :device_cert) ->
        {:certificate, Keyword.fetch!(opts, :device_cert), Keyword.fetch!(opts, :device_key)}

      Keyword.has_key?(opts, :product_key) ->
        {:shared_secret, Keyword.fetch!(opts, :product_key),
         Keyword.fetch!(opts, :product_secret), Keyword.fetch!(opts, :identifier)}

      true ->
        raise ArgumentError,
          "must provide either :device_cert/:device_key (mTLS) or :product_key/:product_secret/:identifier (shared secret)"
    end
  end

  @impl true
  def handle_call(:confirm_update, _from, %State{device_handler: handler} = state) do
    with :ok <- do_confirm(handler) do
      if state.phase == :joined, do: send_channel_message(state, "firmware_validated", %{})
      {:reply, :ok, %{state | firmware_validated: true}}
    else
      error -> {:reply, error, state}
    end
  end

  defp do_confirm(handler) do
    if function_exported?(handler, :handle_confirm, 0),
      do: handler.handle_confirm(),
      else: :ok
  end

  @impl true
  def handle_cast(:reconnect, state) do
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
  def handle_info(:connect, state) do
    state = %{state | phase: :connecting, reconnect_ref: nil}
    url = build_ws_url(state)

    IO.puts("NervesHubLinkAVM: connecting to #{url}")

    case open_websocket(url, build_ws_opts(state)) do
      {:ok, ws} ->
        {:noreply, %{state | ws_pid: ws}}

      {:error, reason} ->
        IO.puts("NervesHubLinkAVM: connection failed: #{inspect(reason)}")
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
      {:ok, msg} ->
        handle_channel_message(msg, state)

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

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{phase: :updating} = state) do
    {:noreply, %{state | phase: :joined}}
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

  defp handle_channel_message(
         {_join_ref, _ref, "device", "phx_reply", %{"status" => "ok"}},
         state
       ) do
    IO.puts("NervesHubLinkAVM: joined device channel")
    ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, %{state | phase: :joined, heartbeat_ref: ref}}
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
    state = %{state | phase: :updating}
    spawn(fn -> do_update(fw_url, meta, state, server) end) |> Process.monitor()
    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, "device", "update", _payload}, state) do
    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, "device", "reboot", _payload}, state) do
    IO.puts("NervesHubLinkAVM: reboot requested")
    send_channel_message(state, "rebooting", %{})
    {:noreply, state}
  end

  defp handle_channel_message({_join_ref, _ref, "device", "identify", _payload}, state) do
    IO.puts("NervesHubLinkAVM: identify requested")

    if function_exported?(state.device_handler, :handle_identify, 0) do
      state.device_handler.handle_identify()
    end

    {:noreply, state}
  end

  # -- Extensions protocol --

  defp handle_channel_message({_join_ref, _ref, "device", "extensions:get", _payload}, state) do
    if state.extensions != %{} do
      state = join_extensions(state)
      {:noreply, state}
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
    case Map.get(state.extensions, :health) do
      nil ->
        {:noreply, state}

      provider ->
        metrics = provider.health_check()
        payload = %{"value" => %{"metrics" => metrics, "timestamp" => iso8601_now()}}
        send_extensions_message(state, "health:report", payload)
        {:noreply, state}
    end
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

  defp do_update(fw_url, meta, state, server) do
    handler = state.device_handler
    http = state.http_client
    expected_sha256 = Map.get(meta, "sha256", "")

    with {:ok, size} <- get_firmware_size(http, fw_url),
         {:ok, handler_state} <- handler.handle_begin(size, meta),
         _ = send_status(server, "downloading"),
         {:ok, handler_state, hash_ctx} <-
           stream_firmware(http, fw_url, size, handler, handler_state, server) do
      finish_update(handler, handler_state, hash_ctx, expected_sha256, server)
    else
      {:error, reason, handler_state} ->
        IO.puts("NervesHubLinkAVM: update failed: #{inspect(reason)}")
        handler.handle_abort(handler_state)
        send_status(server, "update_failed")

      {:error, reason} ->
        IO.puts("NervesHubLinkAVM: update failed: #{inspect(reason)}")
        send_status(server, "update_failed")
    end
  end

  defp finish_update(handler, handler_state, hash_ctx, expected_sha256, server) do
    with :ok <- verify_sha256(hash_ctx, expected_sha256),
         _ = send_status(server, "updating"),
         :ok <- handler.handle_finish(handler_state) do
      send_status(server, "fwup_complete")
    else
      {:error, reason} ->
        IO.puts("NervesHubLinkAVM: update failed: #{inspect(reason)}")
        handler.handle_abort(handler_state)
        send_status(server, "update_failed")
    end
  end

  defp verify_sha256(_hash_ctx, ""), do: :ok

  defp verify_sha256(hash_ctx, expected) do
    computed =
      :crypto.hash_final(hash_ctx)
      |> :binary.encode_hex(:lowercase)

    if computed == expected, do: :ok, else: {:error, :sha256_mismatch}
  end

  defp get_firmware_size(http, fw_url) do
    case http.get_content_length(fw_url) do
      {:ok, size} -> {:ok, size}
      {:error, _} -> {:ok, 0}
    end
  end

  defp stream_firmware(http, fw_url, total_size, handler, handler_state, server) do
    init_acc = %{
      handler: handler,
      handler_state: handler_state,
      hash_ctx: :crypto.hash_init(:sha256),
      bytes_received: 0,
      total_size: total_size,
      server: server,
      last_progress: -1
    }

    case http.get_stream(fw_url, init_acc, &stream_chunk_callback/2) do
      {:ok, %{handler_state: hs, hash_ctx: ctx}} -> {:ok, hs, ctx}
      {:error, reason} -> {:error, reason, handler_state}
    end
  end

  defp stream_chunk_callback(chunk, acc) do
    with {:ok, new_hs} <- acc.handler.handle_chunk(chunk, acc.handler_state) do
      bytes = acc.bytes_received + byte_size(chunk)
      progress = calc_progress(bytes, acc.total_size)
      maybe_report_progress(acc.server, progress, acc.last_progress)

      {:ok,
       %{
         acc
         | handler_state: new_hs,
           hash_ctx: :crypto.hash_update(acc.hash_ctx, chunk),
           bytes_received: bytes,
           last_progress: max(progress, acc.last_progress)
       }}
    end
  end

  defp calc_progress(_bytes, 0), do: 0
  defp calc_progress(bytes, total), do: trunc(bytes / total * 100)

  defp maybe_report_progress(_server, progress, last) when progress <= last, do: :ok
  defp maybe_report_progress(server, progress, _last), do: send_progress(server, progress)

  defp send_progress(server, value) do
    GenServer.cast(server, {:send_event, "fwup_progress", %{"value" => value}})
  end

  defp send_status(server, status) do
    GenServer.cast(server, {:send_event, "status_update", %{"status" => status}})
  end

  # -- Protocol helpers --

  defp build_ws_url(%State{host: host, port: port, ssl: ssl}) do
    scheme = if ssl, do: "wss", else: "ws"
    "#{scheme}://#{host}:#{port}/socket/websocket?vsn=2.0.0"
  end

  defp build_ws_opts(%State{ssl: ssl, auth: auth}) do
    [
      ssl_opts: build_ssl_opts(ssl, auth),
      extra_headers: build_auth_headers(auth)
    ]
    |> Enum.reject(fn {_k, v} -> v == [] end)
  end

  defp build_ssl_opts(false, _auth), do: []
  defp build_ssl_opts(true, {:certificate, cert, key}) do
    [{:certfile, to_charlist(cert)}, {:keyfile, to_charlist(key)}, {:versions, [:"tlsv1.2"]}]
  end
  defp build_ssl_opts(true, _auth), do: [{:versions, [:"tlsv1.2"]}]

  defp build_auth_headers({:shared_secret, key, secret, identifier}) do
    NervesHubLinkAVM.SharedSecret.build_headers(key, secret, identifier)
  end
  defp build_auth_headers(_auth), do: []

  defp send_join(state) do
    {ref, state} = next_ref(state)
    join_ref = "join_#{ref}"

    payload =
      state.firmware_meta
      |> Map.merge(%{
        "device_api_version" => @device_api_version,
        "meta" => %{
          "firmware_validated" => state.firmware_validated,
          "firmware_auto_revert_detected" => false
        }
      })

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

  defp join_extensions(state) do
    {ref, state} = next_ref(state)
    join_ref = "ext_#{ref}"

    versions =
      state.extensions
      |> Map.keys()
      |> Map.new(fn key -> {Atom.to_string(key), "0.0.1"} end)

    msg = Channel.encode_message(join_ref, "ref_#{ref}", "extensions", "phx_join", versions)
    :websocket.send_utf8(state.ws_pid, IO.iodata_to_binary(msg))
    %{state | extensions_join_ref: join_ref}
  end

  defp send_extensions_message(state, event, payload) do
    {ref, _state} = next_ref(state)
    msg = Channel.encode_message(state.extensions_join_ref, "ref_#{ref}", "extensions", event, payload)
    :websocket.send_utf8(state.ws_pid, IO.iodata_to_binary(msg))
  end

  defp next_ref(%State{msg_ref: ref} = state) do
    {ref, %{state | msg_ref: ref + 1}}
  end

  defp open_websocket(url, opts) do
    {:ok, :websocket.new(String.to_charlist(url), opts)}
  rescue
    e -> {:error, e}
  catch
    _, reason -> {:error, reason}
  end

  # -- Connection management --

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
    |> IO.iodata_to_binary()
  end

  defp validate_firmware_meta!(meta) do
    missing = Enum.filter(@required_firmware_meta_keys, fn k -> not is_map_key(meta, k) end)

    if missing != [] do
      raise ArgumentError,
            "missing required firmware metadata keys: #{Enum.join(missing, ", ")}"
    end
  end
end
