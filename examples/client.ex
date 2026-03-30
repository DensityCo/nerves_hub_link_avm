defmodule MyApp.Client do
  @behaviour NervesHubLinkAVM.Client

  # Decide whether to apply an available update.
  # Return :apply, :ignore, or {:reschedule, milliseconds}
  @impl true
  def update_available(_meta), do: :apply

  # Called with download/apply progress percentage.
  @impl true
  def fwup_progress(percent) do
    IO.puts("Update progress: #{percent}%")
    :ok
  end

  # Called when a firmware update fails.
  @impl true
  def fwup_error(error) do
    IO.puts("Update failed: #{inspect(error)}")
    :ok
  end

  # Called when the server requests a reboot.
  @impl true
  def reboot do
    IO.puts("Reboot requested")
    # :esp.restart()
    :ok
  end

  # Called when the server requests device identification.
  # Do something observable like blink an LED.
  @impl true
  def identify do
    IO.puts("Identify requested!")
    # MyApp.Led.blink(:identify)
    :ok
  end

  # Called when the device channel is joined.
  @impl true
  def handle_connected do
    IO.puts("Connected to NervesHub")
    :ok
  end

  # Called when the device channel is disconnected.
  @impl true
  def handle_disconnected do
    IO.puts("Disconnected from NervesHub")
    :ok
  end
end
