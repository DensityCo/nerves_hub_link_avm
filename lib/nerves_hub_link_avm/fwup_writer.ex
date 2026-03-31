defmodule NervesHubLinkAVM.FwupWriter do
  @moduledoc """
  Behaviour for hardware-specific firmware write operations.

  Implement this for your target platform (ESP32, STM32, etc.).
  The client library handles downloading, SHA256 verification, and progress
  reporting — this behaviour only needs to deal with writing bytes to flash.

  ## Callbacks

  * `fwup_begin/2` - prepare for firmware write (erase partition, allocate buffers)
  * `fwup_chunk/2` - write a chunk of firmware data
  * `fwup_finish/1` - finalize the write (activate new slot, reboot)
  * `fwup_abort/1` - clean up after a failed update
  * `fwup_confirm/0` - (optional) confirm firmware on first boot to prevent rollback
  """

  # Hardware-specific firmware write operations.
  # Implement this behaviour for your target platform (ESP32, STM32, etc.).

  @doc "Prepare for firmware write. Erase partition, allocate buffers, etc."
  @callback fwup_begin(size :: non_neg_integer(), meta :: map()) ::
              {:ok, state :: term()} | {:error, reason :: term()}

  @doc "Write a chunk of firmware data at the current position."
  @callback fwup_chunk(data :: binary(), state :: term()) ::
              {:ok, new_state :: term()} | {:error, reason :: term()}

  @doc "Finalize the write. Activate the new firmware slot."
  @callback fwup_finish(state :: term()) ::
              :ok | {:error, reason :: term()}

  @doc "Clean up after a failed update. Roll back partial writes."
  @callback fwup_abort(state :: term()) :: :ok

  @doc "Confirm firmware on first boot. Prevents automatic rollback."
  @callback fwup_confirm() :: :ok | {:error, reason :: term()}

  @optional_callbacks [fwup_confirm: 0]
end
