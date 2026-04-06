defmodule NervesHubLinkAVM.Client.Default do
  @moduledoc """
  Default `NervesHubLinkAVM.Client` implementation.

  Auto-applies all updates and logs progress to stdout.
  Used when no `:client` option is provided to `NervesHubLinkAVM.start_link/1`.
  """
  @behaviour NervesHubLinkAVM.Client

  # Auto-applies all updates. Logs progress. Good starting point.

  @impl true
  def update_available(_meta), do: :apply

  @impl true
  def firmware_progress(percent) do
    IO.puts("NervesHubLinkAVM: firmware progress #{percent}%")
    :ok
  end

  @impl true
  def firmware_error(error) do
    IO.puts("NervesHubLinkAVM: firmware error: #{inspect(error)}")
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
