defmodule NervesHubLinkAVM.Client.Default do
  @moduledoc false
  @behaviour NervesHubLinkAVM.Client

  # Auto-applies all updates. Logs progress. Good starting point.

  @impl true
  def update_available(_meta), do: :apply

  @impl true
  def fwup_progress(percent) do
    IO.puts("NervesHubLinkAVM: fwup progress #{percent}%")
    :ok
  end

  @impl true
  def fwup_error(error) do
    IO.puts("NervesHubLinkAVM: fwup error: #{inspect(error)}")
    :ok
  end

  @impl true
  def reboot do
    IO.puts("NervesHubLinkAVM: reboot requested")
    :ok
  end

  @impl true
  def identify do
    IO.puts("NervesHubLinkAVM: identify requested")
    :ok
  end

  @impl true
  def handle_connected do
    IO.puts("NervesHubLinkAVM: connected")
    :ok
  end

  @impl true
  def handle_disconnected do
    IO.puts("NervesHubLinkAVM: disconnected")
    :ok
  end
end
