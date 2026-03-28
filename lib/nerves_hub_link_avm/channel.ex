defmodule NervesHubLinkAVM.Channel do
  @moduledoc false

  alias NervesHubLinkAVM.JSON

  def encode_message(join_ref, ref, topic, event, payload) when is_map(payload) do
    JSON.encode([join_ref, ref, topic, event, payload])
  end

  def encode_message(join_ref, ref, topic, event, payload) when is_binary(payload) do
    jr = JSON.encode(join_ref)
    r = JSON.encode(ref)
    t = JSON.encode(topic)
    e = JSON.encode(event)
    <<"[", jr::binary, ",", r::binary, ",", t::binary, ",", e::binary, ",", payload::binary, "]">>
  end

  def decode_message(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      [join_ref, ref, topic, event, payload] ->
        {:ok, {join_ref, ref, topic, event, payload}}
      other ->
        {:error, {:unexpected_format, other}}
    end
  end
end
