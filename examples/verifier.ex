# Example: No-op verifier that skips integrity checking.
# Useful during development when firmware images are unsigned.
#
# Usage:
#   NervesHubLinkAVM.start_link(
#     ...,
#     verifier: MyApp.NoOpVerifier
#   )

defmodule MyApp.NoOpVerifier do
  @behaviour NervesHubLinkAVM.Verifier

  @impl true
  def init(_expected), do: {:ok, :none}

  @impl true
  def update(_data, state), do: {:ok, state}

  @impl true
  def finish(_state), do: :ok
end
