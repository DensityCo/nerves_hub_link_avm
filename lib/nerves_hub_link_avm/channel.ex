defmodule NervesHubLinkAVM.Channel do
  @moduledoc false

  def encode_message(join_ref, ref, topic, event, payload) do
    JSON.encode!([join_ref, ref, topic, event, payload])
  end

  def decode_message(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, [join_ref, ref, topic, event, payload]} ->
        {:ok, {join_ref, ref, topic, event, payload}}

      {:ok, other} ->
        {:error, {:unexpected_format, other}}

      {:error, _} = err ->
        err
    end
  end
end
