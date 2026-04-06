defmodule NervesHubLinkAVM.Client do
  @moduledoc """
  Behaviour for device lifecycle hooks.

  Controls update decisions, progress reporting, and device actions.
  All callbacks are required — see `NervesHubLinkAVM.Client.Default`
  for a starting point that auto-applies updates and logs to stdout.

  ## Callbacks

  * `update_available/1` - decide whether to apply an update
  * `firmware_progress/1` - called with download/apply progress percentage
  * `firmware_error/1` - called when a firmware update fails
  * `reboot/0` - called when the server requests a reboot
  * `identify/0` - called when the server requests device identification
  * `handle_connected/0` - called when the device channel is joined
  * `handle_disconnected/0` - called when the device channel is disconnected
  """

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
end
