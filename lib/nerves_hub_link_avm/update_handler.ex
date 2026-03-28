defmodule NervesHubLinkAVM.UpdateHandler do
  @doc "Called once before streaming. size = total bytes, meta = firmware_meta map."
  @callback handle_begin(size :: non_neg_integer(), meta :: map()) ::
              {:ok, state :: term()} | {:error, reason :: term()}

  @doc "Called for each downloaded chunk."
  @callback handle_chunk(data :: binary(), state :: term()) ::
              {:ok, new_state :: term()} | {:error, reason :: term()}

  @doc "Called after all chunks have been streamed and SHA256 verified by the client."
  @callback handle_finish(state :: term()) ::
              :ok | {:error, reason :: term()}

  @doc "Called on first boot of new firmware to commit and prevent rollback."
  @callback handle_confirm() :: :ok | {:error, reason :: term()}

  @doc "Called on any error — clean up partial write."
  @callback handle_abort(state :: term()) :: :ok

  @optional_callbacks [handle_confirm: 0]
end
