defmodule NervesHubLinkAVM.Extension do
  @moduledoc false

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
