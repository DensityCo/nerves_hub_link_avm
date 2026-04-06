defmodule NervesHubLinkAVM.Client do
  @moduledoc """
  Behaviour for device lifecycle hooks.

  Controls update decisions, progress reporting, and device actions.
  All callbacks are optional with sensible defaults — implement only what you need.

  ## Callbacks

  * `update_available/1` - decide whether to apply an update (default: `:apply`)
  * `firmware_progress/1` - called with download/apply progress percentage
  * `firmware_error/1` - called when a firmware update fails
  * `reboot/0` - called when the server requests a reboot
  * `identify/0` - called when the server requests device identification
  * `handle_connected/0` - called when the device channel is joined
  * `handle_disconnected/0` - called when the device channel is disconnected

  See `NervesHubLinkAVM.Client.Default` for an implementation that auto-applies all updates.
  """

  # Universal device lifecycle hooks.
  # Controls update decisions, progress reporting, and device actions.
  # All callbacks are optional with sensible defaults.

  @doc "Decide whether to apply an available update."
  @callback update_available(meta :: map()) ::
              :apply | :ignore | {:reschedule, pos_integer()}

  @doc "Called with firmware download/apply progress (0-100)."
  @callback firmware_progress(percent :: 0..100) :: :ok

  @doc "Called when a firmware update fails."
  @callback firmware_error(error :: term()) :: :ok

  @doc "Called when the server requests a reboot."
  @callback reboot() :: :ok

  @doc "Called when the server requests device identification."
  @callback identify() :: :ok

  @doc "Called when the device channel is joined."
  @callback handle_connected() :: :ok

  @doc "Called when the device channel is disconnected."
  @callback handle_disconnected() :: :ok

  @optional_callbacks [
    update_available: 1,
    firmware_progress: 1,
    firmware_error: 1,
    reboot: 0,
    identify: 0,
    handle_connected: 0,
    handle_disconnected: 0
  ]

  # -- Default implementations --

  def call_update_available(client, meta) do
    if function_exported?(client, :update_available, 1),
      do: client.update_available(meta),
      else: :apply
  end

  def call_firmware_progress(client, percent) do
    if function_exported?(client, :firmware_progress, 1),
      do: client.firmware_progress(percent),
      else: :ok
  end

  def call_firmware_error(client, error) do
    if function_exported?(client, :firmware_error, 1),
      do: client.firmware_error(error),
      else: :ok
  end

  def call_reboot(client) do
    if function_exported?(client, :reboot, 0),
      do: client.reboot(),
      else: :ok
  end

  def call_identify(client) do
    if function_exported?(client, :identify, 0),
      do: client.identify(),
      else: :ok
  end

  def call_connected(client) do
    if function_exported?(client, :handle_connected, 0),
      do: client.handle_connected(),
      else: :ok
  end

  def call_disconnected(client) do
    if function_exported?(client, :handle_disconnected, 0),
      do: client.handle_disconnected(),
      else: :ok
  end
end
