defmodule NervesHubLinkAVM.Extensions do
  @moduledoc false

  # Routes extension events to the correct extension module.
  # Protocol-free — no knowledge of channels, websockets, or encoding.

  @doc "Initialize all configured extensions. Returns a map of key => %{mod, state}."
  def init(config) do
    Enum.reduce(config, %{}, fn {key, {mod, opts}}, acc ->
      {:ok, state} = mod.init(opts)
      Map.put(acc, key, %{mod: mod, state: state})
    end)
  end

  @doc "Are any extensions configured?"
  def any?(extensions), do: extensions != %{}

  @doc "Build version map for the extensions channel join payload."
  def versions(extensions) do
    Enum.reduce(extensions, %{}, fn {key, %{mod: mod}}, acc ->
      Map.put(acc, :erlang.atom_to_binary(key), mod.version())
    end)
  end

  @doc "Filter server's attach list to extensions we actually have configured."
  def attachable(attach_list, extensions) do
    configured = Enum.map(Map.keys(extensions), &:erlang.atom_to_binary/1)
    Enum.filter(attach_list, fn ext -> ext in configured end)
  end

  @doc """
  Route a scoped event (e.g., "health:check") to the correct extension.
  Returns {:reply, event, payload, updated_extensions} or {:noreply, updated_extensions}.
  """
  def handle_event(scoped_event, payload, extensions) do
    case split_event(scoped_event) do
      {key_str, event} ->
        case find_extension(key_str, extensions) do
          {key, %{mod: mod, state: ext_state}} ->
            case mod.handle_event(event, payload, ext_state) do
              {:reply, reply_event, reply_payload, new_state} ->
                {:reply, "#{key_str}:#{reply_event}", reply_payload,
                 put_state(extensions, key, new_state)}

              {:noreply, new_state} ->
                {:noreply, put_state(extensions, key, new_state)}
            end

          nil ->
            {:noreply, extensions}
        end

      :error ->
        {:noreply, extensions}
    end
  end

  defp find_extension(key_str, extensions) do
    Enum.find_value(extensions, fn {key, entry} ->
      if :erlang.atom_to_binary(key) == key_str, do: {key, entry}
    end)
  end

  defp split_event(scoped) do
    case :binary.split(scoped, <<":">>) do
      [key, event] -> {key, event}
      _ -> :error
    end
  end

  defp put_state(extensions, key, new_state) do
    Map.update!(extensions, key, fn entry -> %{entry | state: new_state} end)
  end
end
