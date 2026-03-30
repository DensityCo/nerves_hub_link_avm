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
    time = unix_time()
    time_str = :erlang.integer_to_binary(time)

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
    <<"NH1:device-socket:shared-secret:connect\n\nx-nh-alg=", @alg, "\nx-nh-key=",
      product_key::binary, "\nx-nh-time=", time_str::binary, "\n">>
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

  defp url_encode64(data) when is_list(data), do: url_encode64(:erlang.iolist_to_binary(data))

  defp strip_padding(<<>>, acc), do: acc
  defp strip_padding(<<"=", rest::binary>>, acc), do: strip_padding(rest, acc)
  defp strip_padding(<<"+", rest::binary>>, acc), do: strip_padding(rest, <<acc::binary, "-">>)
  defp strip_padding(<<"/", rest::binary>>, acc), do: strip_padding(rest, <<acc::binary, "_">>)
  defp strip_padding(<<c, rest::binary>>, acc), do: strip_padding(rest, <<acc::binary, c>>)

  defp unix_time do
    {{y, mo, d}, {h, mi, s}} = :erlang.universaltime()
    days = days_since_epoch(y, mo, d)
    days * 86400 + h * 3600 + mi * 60 + s
  end

  defp days_since_epoch(year, month, day) do
    y1 = year - 1
    days_y = y1 * 365 + div(y1, 4) - div(y1, 100) + div(y1, 400)
    epoch_days = 1969 * 365 + div(1969, 4) - div(1969, 100) + div(1969, 400)
    days_m = days_in_months(year, month)
    days_y - epoch_days + days_m + day - 1
  end

  defp days_in_months(_year, 1), do: 0
  defp days_in_months(_year, 2), do: 31

  defp days_in_months(year, m) when m > 2 do
    leap = if rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0), do: 1, else: 0
    month_days = {31, 28 + leap, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    Enum.reduce(1..(m - 1), 0, fn i, acc -> acc + :erlang.element(i, month_days) end)
  end
end
