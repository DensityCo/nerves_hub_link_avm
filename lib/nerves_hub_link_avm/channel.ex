defmodule NervesHubLinkAVM.Channel do
  @moduledoc false

  def encode_message(join_ref, ref, topic, event, payload) do
    msg = [join_ref, ref, topic, event, payload]
    :json.encode(msg)
  end

  def decode_message(raw) when is_binary(raw) do
    case :json.decode(raw) do
      [join_ref, ref, topic, event, payload] ->
        {:ok, {join_ref, ref, topic, event, payload}}

      other ->
        {:error, {:unexpected_format, other}}
    end
  end
end
