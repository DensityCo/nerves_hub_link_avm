defmodule NervesHubLinkAVM.Extension.Logging do
  @moduledoc false
  @behaviour NervesHubLinkAVM.Extension

  @impl true
  def version, do: "0.0.1"

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_event("send", %{"level" => level, "message" => message}, state) do
    payload = %{
      "level" => normalize_level(level),
      "message" => format_message(message),
      "meta" => %{"time" => :erlang.integer_to_binary(:erlang.system_time(:microsecond))}
    }

    {:reply, "send", payload, state}
  end

  def handle_event(_event, _payload, state), do: {:noreply, state}

  # -- Helpers --

  defp normalize_level(level) when is_atom(level), do: :erlang.atom_to_binary(level)
  defp normalize_level(level) when is_binary(level), do: level
  defp normalize_level(level), do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [level]))

  def format_message({:report, report}),
    do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [report]))

  def format_message({format, args}) when is_list(format) and is_list(args),
    do: :erlang.iolist_to_binary(:io_lib.format(format, args))

  def format_message({format, args}) when is_binary(format) and is_list(args),
    do: :erlang.iolist_to_binary(:io_lib.format(:erlang.binary_to_list(format), args))

  def format_message(msg) when is_binary(msg), do: msg
  def format_message(msg) when is_list(msg), do: :erlang.iolist_to_binary(msg)
  def format_message(msg), do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [msg]))
end
