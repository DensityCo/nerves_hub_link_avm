defmodule NervesHubLinkAVM.SharedSecret do
  @moduledoc false

  @alg "NH1-HMAC-sha256-1000-32"
  @iterations 1000
  @key_length 32
  @max_age 86400

  @doc """
  Builds the x-nh-* headers for shared secret authentication.

  Returns a list of `{name, value}` tuples suitable for websocket extra_headers.
  """
  def build_headers(product_key, product_secret, device_identifier) do
    time = :erlang.system_time(:second)
    time_str = Integer.to_string(time)

    salt = build_salt(product_key, time_str)
    signature = sign(product_secret, salt, device_identifier, time)

    [
      {<<"x-nh-alg">>, @alg},
      {<<"x-nh-key">>, product_key},
      {<<"x-nh-time">>, time_str},
      {<<"x-nh-signature">>, signature}
    ]
  end

  defp build_salt(product_key, time_str) do
    <<"NH1:device-socket:shared-secret:connect\n\nx-nh-alg=", @alg,
      "\nx-nh-key=", product_key::binary, "\nx-nh-time=", time_str::binary, "\n">>
  end

  defp sign(secret, salt, data, signed_at) do
    key = :crypto.pbkdf2_hmac(:sha256, secret, salt, @iterations, @key_length)

    signed_at_ms = signed_at * 1000
    protected = url_encode64("HS256")
    payload = url_encode64(:erlang.term_to_binary({data, signed_at_ms, @max_age}))
    message = <<protected::binary, ".", payload::binary>>
    signature = url_encode64(:crypto.mac(:hmac, :sha256, key, message))

    <<message::binary, ".", signature::binary>>
  end

  defp url_encode64(data) when is_binary(data) do
    :base64.encode(data) |> strip_padding(<<>>)
  end

  defp url_encode64(data) when is_list(data), do: url_encode64(IO.iodata_to_binary(data))

  defp strip_padding(<<>>, acc), do: acc
  defp strip_padding(<<"=", rest::binary>>, acc), do: strip_padding(rest, acc)
  defp strip_padding(<<"+", rest::binary>>, acc), do: strip_padding(rest, <<acc::binary, "-">>)
  defp strip_padding(<<"/", rest::binary>>, acc), do: strip_padding(rest, <<acc::binary, "_">>)
  defp strip_padding(<<c, rest::binary>>, acc), do: strip_padding(rest, <<acc::binary, c>>)
end
