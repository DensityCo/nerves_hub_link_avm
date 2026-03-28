defmodule NervesHubLinkAVM.JSON do
  @moduledoc false

  # -- Encoder --

  def encode(nil), do: "null"
  def encode(v) when is_binary(v), do: <<"\"", escape_string(v)::binary, "\"">>
  def encode(v) when is_integer(v), do: :erlang.integer_to_binary(v)
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(v) when is_atom(v), do: <<"\"", :erlang.atom_to_binary(v)::binary, "\"">>
  def encode(v) when is_map(v), do: encode_map(v)
  def encode(v) when is_list(v), do: encode_list(v)

  defp encode_map(map) when map_size(map) == 0, do: "{}"
  defp encode_map(map) do
    pairs = Enum.map(Map.to_list(map), fn {k, v} ->
      key = if is_atom(k), do: :erlang.atom_to_binary(k), else: k
      <<"\"", key::binary, "\":", encode(v)::binary>>
    end)
    <<"{", join_binaries(pairs, ",")::binary, "}">>
  end

  defp encode_list([]), do: "[]"
  defp encode_list(list) do
    items = Enum.map(list, &encode/1)
    <<"[", join_binaries(items, ",")::binary, "]">>
  end

  defp join_binaries([single], _sep), do: single
  defp join_binaries([h | t], sep) do
    Enum.reduce(t, h, fn item, acc -> <<acc::binary, sep::binary, item::binary>> end)
  end

  defp escape_string(bin), do: escape_string(bin, <<>>)
  defp escape_string(<<>>, acc), do: acc
  defp escape_string(<<"\"", rest::binary>>, acc), do: escape_string(rest, <<acc::binary, "\\\"">>)
  defp escape_string(<<"\\", rest::binary>>, acc), do: escape_string(rest, <<acc::binary, "\\\\">>)
  defp escape_string(<<"\n", rest::binary>>, acc), do: escape_string(rest, <<acc::binary, "\\n">>)
  defp escape_string(<<"\r", rest::binary>>, acc), do: escape_string(rest, <<acc::binary, "\\r">>)
  defp escape_string(<<"\t", rest::binary>>, acc), do: escape_string(rest, <<acc::binary, "\\t">>)
  defp escape_string(<<c, rest::binary>>, acc) when c < 0x20, do: escape_string(rest, acc)
  defp escape_string(<<c, rest::binary>>, acc), do: escape_string(rest, <<acc::binary, c>>)

  # -- Decoder --

  def decode(bin) when is_binary(bin) do
    {val, _rest} = decode_value(skip_ws(bin))
    val
  end

  defp decode_value(<<"\"", rest::binary>>), do: decode_string(rest, <<>>)
  defp decode_value(<<"[", rest::binary>>), do: decode_array(skip_ws(rest), [])
  defp decode_value(<<"{", rest::binary>>), do: decode_object(skip_ws(rest), %{})
  defp decode_value(<<"null", rest::binary>>), do: {nil, rest}
  defp decode_value(<<"true", rest::binary>>), do: {true, rest}
  defp decode_value(<<"false", rest::binary>>), do: {false, rest}
  defp decode_value(<<c, _::binary>> = bin) when c == ?- or (c >= ?0 and c <= ?9), do: decode_number(bin, <<>>)
  defp decode_value(bin), do: {:error, bin}

  defp decode_string(<<"\\\"", rest::binary>>, acc), do: decode_string(rest, <<acc::binary, "\"">>)
  defp decode_string(<<"\\\\", rest::binary>>, acc), do: decode_string(rest, <<acc::binary, "\\">>)
  defp decode_string(<<"\\n", rest::binary>>, acc), do: decode_string(rest, <<acc::binary, "\n">>)
  defp decode_string(<<"\\r", rest::binary>>, acc), do: decode_string(rest, <<acc::binary, "\r">>)
  defp decode_string(<<"\\t", rest::binary>>, acc), do: decode_string(rest, <<acc::binary, "\t">>)
  defp decode_string(<<"\\u", _::binary-size(4), rest::binary>>, acc), do: decode_string(rest, acc)
  defp decode_string(<<"\"", rest::binary>>, acc), do: {acc, rest}
  defp decode_string(<<c, rest::binary>>, acc), do: decode_string(rest, <<acc::binary, c>>)

  defp decode_array(<<"]", rest::binary>>, acc), do: {Enum.reverse(acc), rest}
  defp decode_array(bin, acc) do
    {val, rest} = decode_value(skip_ws(bin))
    rest2 = skip_ws(rest)
    case rest2 do
      <<",", rest3::binary>> -> decode_array(skip_ws(rest3), [val | acc])
      <<"]", rest3::binary>> -> {Enum.reverse([val | acc]), rest3}
    end
  end

  defp decode_object(<<"}", rest::binary>>, acc), do: {acc, rest}
  defp decode_object(bin, acc) do
    {key, rest} = decode_value(skip_ws(bin))
    <<":", rest2::binary>> = skip_ws(rest)
    {val, rest3} = decode_value(skip_ws(rest2))
    new_acc = Map.put(acc, key, val)
    rest4 = skip_ws(rest3)
    case rest4 do
      <<",", rest5::binary>> -> decode_object(skip_ws(rest5), new_acc)
      <<"}", rest5::binary>> -> {new_acc, rest5}
    end
  end

  defp decode_number(<<c, rest::binary>>, acc) when c == ?- or c == ?. or (c >= ?0 and c <= ?9) do
    decode_number(rest, <<acc::binary, c>>)
  end
  defp decode_number(rest, acc) do
    {:erlang.binary_to_integer(acc), rest}
  end

  defp skip_ws(<<" ", rest::binary>>), do: skip_ws(rest)
  defp skip_ws(<<"\t", rest::binary>>), do: skip_ws(rest)
  defp skip_ws(<<"\n", rest::binary>>), do: skip_ws(rest)
  defp skip_ws(<<"\r", rest::binary>>), do: skip_ws(rest)
  defp skip_ws(bin), do: bin
end
