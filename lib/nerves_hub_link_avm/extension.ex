defmodule NervesHubLinkAVM.Extension do
  @moduledoc """
  Behaviour for NervesHub extensions (health, geo, local shell, etc.).

  Each extension module implements this behaviour. The `Extensions` router
  splits scoped events (e.g., `"health:check"`) and dispatches to the correct
  extension's `handle_event/3`.

  ## Callbacks

  * `version/0` - protocol version string for this extension
  * `init/1` - initialize extension state from user-provided opts
  * `handle_event/3` - handle an event, return `{:reply, event, payload, state}` or `{:noreply, state}`

  ## Built-in extensions

  * `NervesHubLinkAVM.Extension.Health` - health metrics reporting
  * `NervesHubLinkAVM.Extension.Logging` - device log forwarding to NervesHub

  ## Custom extensions

  Implement this behaviour and pass it in the extensions config:

      extensions: [
        my_ext: {MyApp.MyExtension, some_opt: "value"}
      ]
  """

  # Behaviour for NervesHub extensions (health, geo, local shell, etc.).
  # Each extension module implements this behaviour.

  @doc "Protocol version string for this extension."
  @callback version() :: String.t()

  @doc "Initialize extension state from user-provided opts."
  @callback init(opts :: keyword()) :: {:ok, state :: term()}

  @doc "Handle an event routed to this extension. Return a reply or noop."
  @callback handle_event(event :: String.t(), payload :: map(), state :: term()) ::
              {:reply, String.t(), map(), new_state :: term()}
              | {:noreply, new_state :: term()}
end
