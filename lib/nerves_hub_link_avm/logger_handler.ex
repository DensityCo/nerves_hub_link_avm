defmodule NervesHubLinkAVM.LoggerHandler do
  @moduledoc false

  def log(%{level: level, msg: msg}, handler_config) do
    server = handler_server(handler_config)
    NervesHubLinkAVM.log(level, msg, server)
    :ok
  end

  defp handler_server(%{config: %{server: server}}), do: server
  defp handler_server(%{server: server}), do: server
  defp handler_server(_handler_config), do: NervesHubLinkAVM

  defdelegate format_message(msg), to: NervesHubLinkAVM.Extension.Logging
end
