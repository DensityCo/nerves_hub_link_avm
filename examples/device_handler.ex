defmodule MyApp.DeviceHandler do
  @behaviour NervesHubLinkAVM.DeviceHandler

  # -- Firmware update callbacks --

  # Called before firmware streaming starts.
  # Initialize whatever state you need for writing to flash.
  @impl true
  def fwup_begin(size, _meta) do
    IO.puts("Starting firmware update: #{size} bytes")
    # Example: erase the inactive partition
    # :partition_nif.erase(:inactive)
    {:ok, %{offset: 0, size: size}}
  end

  # Called for each downloaded chunk.
  # Write the chunk to flash at the current offset.
  @impl true
  def fwup_chunk(data, state) do
    # Example: write chunk to flash partition
    # :partition_nif.write(:inactive, state.offset, data)
    new_offset = state.offset + byte_size(data)
    {:ok, %{state | offset: new_offset}}
  end

  # Called after all chunks have been streamed and SHA256 verified.
  # Activate the new firmware slot and reboot.
  @impl true
  def fwup_finish(_state) do
    IO.puts("Firmware verified, activating and rebooting")
    # Example: swap to the new partition and restart
    # :boot_env_nif.swap()
    # :esp.restart()
    :ok
  end

  # Called on any error (download failure, SHA256 mismatch, etc).
  # Clean up any partial writes.
  @impl true
  def fwup_abort(_state) do
    IO.puts("Firmware update aborted, cleaning up")
    :ok
  end

  # Optional: called via NervesHubLinkAVM.confirm_update/0
  # on first boot after an update. Prevents automatic rollback.
  @impl true
  def fwup_confirm do
    IO.puts("Firmware confirmed, marking as valid")
    # Example: mark the current slot as valid
    # :boot_env_nif.mark_valid()
    :ok
  end

  # -- Device callbacks --

  # Optional: called when the server requests device identification.
  # Do something observable like blink an LED.
  @impl true
  def handle_identify do
    IO.puts("Identify requested!")
    # Example: blink the status LED
    # MyApp.Led.blink(:identify)
    :ok
  end
end
