defmodule NervesHubLinkAVM.Extension.Health do
  @moduledoc """
  Built-in health extension.

  Wraps a `NervesHubLinkAVM.HealthProvider` module and responds to
  `"check"` events with a health report containing device metrics.

  Automatically used when you configure:

      extensions: [health: MyApp.HealthProvider]
  """
  @behaviour NervesHubLinkAVM.Extension

  # Wraps a user-provided HealthProvider module.
  # Responds to "check" events with a health report.

  @impl true
  def version, do: "0.0.1"

  @impl true
  def init(opts) do
    {:ok, %{provider: Keyword.fetch!(opts, :provider)}}
  end

  @impl true
  def handle_event("check", _payload, state) do
    metrics = state.provider.health_check()
    payload = %{"value" => %{"metrics" => metrics, "timestamp" => iso8601_now()}}
    {:reply, "report", payload, state}
  end

  def handle_event(_, _, state), do: {:noreply, state}

  defp iso8601_now do
    seconds = :erlang.system_time(:second)
    {{y, mo, d}, {h, mi, s}} = :calendar.system_time_to_universal_time(seconds, :second)

    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [y, mo, d, h, mi, s])
    |> :erlang.iolist_to_binary()
  end
end
