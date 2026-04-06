defmodule NervesHubLinkAVM.Configurator do
  @moduledoc false

  # Builds runtime configuration from start_link opts.
  # Handles auth method selection, SSL options, and WebSocket URL construction.

  alias NervesHubLinkAVM.Extensions
  alias NervesHubLinkAVM.SharedSecret

  defstruct [
    :url,
    :ws_opts,
    :auth,
    :firmware_meta,
    :client,
    :firmware_writer,
    :http_client,
    extensions: %{},
    firmware_validated: false
  ]

  @required_firmware_meta_keys [
    "uuid",
    "product",
    "architecture",
    "version",
    "platform"
  ]

  def build!(opts) do
    firmware_meta = Keyword.fetch!(opts, :firmware_meta)
    validate_firmware_meta!(firmware_meta)

    auth = build_auth(opts)
    ssl = Keyword.get(opts, :ssl, true)
    host = Keyword.fetch!(opts, :host)
    port = Keyword.get(opts, :port, 443)

    %__MODULE__{
      url: build_url(ssl, host, port),
      ws_opts: build_ws_opts(ssl, auth),
      auth: auth,
      firmware_meta: firmware_meta,
      client: Keyword.get(opts, :client, NervesHubLinkAVM.Client.Default),
      firmware_writer: Keyword.fetch!(opts, :firmware_writer),
      http_client: Keyword.get(opts, :http_client, NervesHubLinkAVM.HTTPClient),
      extensions: parse_and_init_extensions(Keyword.get(opts, :extensions, []))
    }
  end

  # -- Auth --

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

  # -- URL + WebSocket opts --

  defp build_url(ssl, host, port) do
    scheme = if ssl, do: "wss", else: "ws"
    "#{scheme}://#{host}:#{port}/device-socket/websocket?vsn=2.0.0"
  end

  defp build_ws_opts(ssl, auth) do
    [
      ssl_opts: build_ssl_opts(ssl, auth),
      extra_headers: build_auth_headers(auth)
    ]
    |> Enum.reject(fn {_k, v} -> v == [] end)
  end

  defp build_ssl_opts(false, _auth), do: []

  defp build_ssl_opts(true, {:certificate, cert, key}) do
    [{:certfile, to_charlist(cert)}, {:keyfile, to_charlist(key)}]
  end

  defp build_ssl_opts(true, _auth), do: []

  defp build_auth_headers({:shared_secret, key, secret, identifier}) do
    SharedSecret.build_headers(key, secret, identifier)
  end

  defp build_auth_headers(_auth), do: []

  # -- Extensions --

  @known_extensions %{
    health: NervesHubLinkAVM.Extension.Health
  }

  @marker_extensions %{
    logging: NervesHubLinkAVM.Extension.Logging
  }

  defp parse_and_init_extensions([]), do: %{}

  defp parse_and_init_extensions(config) do
    parsed =
      Enum.map(config, fn
        {key, {mod, opts}} ->
          {key, {mod, opts}}

        {key, true} ->
          case Map.get(@marker_extensions, key) do
            nil -> raise ArgumentError, "unknown extension shorthand: #{key}"
            mod -> {key, {mod, []}}
          end

        {key, provider} when is_atom(provider) and provider not in [true, false, nil] ->
          case Map.get(@known_extensions, key) do
            nil -> raise ArgumentError, "unknown extension shorthand: #{key}"
            mod -> {key, {mod, [provider: provider]}}
          end

        {key, value} ->
          raise ArgumentError, "invalid extension config for #{key}: #{inspect(value)}"
      end)

    Extensions.init(parsed)
  end

  # -- Validation --

  defp validate_firmware_meta!(meta) do
    missing = Enum.filter(@required_firmware_meta_keys, fn k -> not is_map_key(meta, k) end)

    if missing != [] do
      raise ArgumentError,
            "missing required firmware metadata keys: #{Enum.join(missing, ", ")}"
    end
  end
end
