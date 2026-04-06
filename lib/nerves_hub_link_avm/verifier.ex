defmodule NervesHubLinkAVM.Verifier do
  @moduledoc """
  Behaviour for firmware integrity verification.

  Called incrementally during download — `init/1` before streaming,
  `update/2` per chunk, `finish/1` after all chunks received.

  The default implementation (`NervesHubLinkAVM.Verifier.SHA256`) checks
  the firmware SHA256 hash. Implement this behaviour to use a different
  verification scheme (e.g., signature verification, CRC32).
  """

  @doc "Initialize verification state. `expected` is the reference value from firmware metadata."
  @callback init(expected :: String.t()) :: {:ok, state :: term()}

  @doc "Process a chunk of firmware data. Called once per downloaded chunk."
  @callback update(data :: binary(), state :: term()) :: {:ok, state :: term()}

  @doc "Finalize verification. Return `:ok` if the firmware is valid."
  @callback finish(state :: term()) :: :ok | {:error, reason :: term()}
end
