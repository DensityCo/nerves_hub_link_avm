defmodule NervesHubLinkAVM.Extension.Logging do
  @moduledoc false
  @behaviour NervesHubLinkAVM.Extension

  @impl true
  def version, do: "0.0.1"

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_event(_event, _payload, state), do: {:noreply, state}
end
