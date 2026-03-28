defmodule NervesHubLinkAVM.DeviceHandler do
  # -- Firmware update callbacks --

  @doc "Called once before firmware streaming. size = total bytes, meta = firmware_meta map."
  @callback fwup_begin(size :: non_neg_integer(), meta :: map()) ::
              {:ok, state :: term()} | {:error, reason :: term()}

  @doc "Called for each downloaded firmware chunk."
  @callback fwup_chunk(data :: binary(), state :: term()) ::
              {:ok, new_state :: term()} | {:error, reason :: term()}

  @doc "Called after all chunks have been streamed and SHA256 verified by the client."
  @callback fwup_finish(state :: term()) ::
              :ok | {:error, reason :: term()}

  @doc "Called on any firmware update error — clean up partial write."
  @callback fwup_abort(state :: term()) :: :ok

  @doc "Called on first boot of new firmware to commit and prevent rollback."
  @callback fwup_confirm() :: :ok | {:error, reason :: term()}

  # -- Device callbacks --

  @doc "Called when the server requests device identification (e.g., blink an LED)."
  @callback handle_identify() :: :ok

  @optional_callbacks [fwup_confirm: 0, handle_identify: 0]
end
