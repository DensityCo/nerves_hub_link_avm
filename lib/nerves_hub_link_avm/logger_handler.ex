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

  def format_message({:report, report}),
    do: IO.iodata_to_binary(:io_lib.format("~p", [report]))

  def format_message({format, args}) when (is_list(format) or is_binary(format)) and is_list(args),
    do: IO.iodata_to_binary(:io_lib.format(to_charlist(format), args))

  def format_message(msg) when is_binary(msg), do: msg
  def format_message(msg) when is_list(msg), do: IO.iodata_to_binary(msg)
  def format_message(msg), do: IO.iodata_to_binary(:io_lib.format("~p", [msg]))
end
