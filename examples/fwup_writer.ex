defmodule MyApp.ESP32Writer do
  @behaviour NervesHubLinkAVM.FwupWriter

  # Prepare for firmware write.
  # Erase the inactive partition, allocate buffers, etc.
  @impl true
  def fwup_begin(size, _meta) do
    IO.puts("Starting firmware update: #{size} bytes")
    # Example: erase the inactive partition
    # :partition_nif.erase(:inactive)
    {:ok, %{offset: 0, size: size}}
  end

  # Write a chunk of firmware data at the current position.
  @impl true
  def fwup_chunk(data, state) do
    # Example: write chunk to flash partition
    # :partition_nif.write(:inactive, state.offset, data)
    new_offset = state.offset + byte_size(data)
    {:ok, %{state | offset: new_offset}}
  end

  # Finalize the write. Activate the new firmware slot and reboot.
  @impl true
  def fwup_finish(_state) do
    IO.puts("Firmware verified, activating and rebooting")
    # Example: swap to the new partition and restart
    # :boot_env_nif.swap()
    # :esp.restart()
    :ok
  end

  # Clean up after a failed update. Roll back partial writes.
  @impl true
  def fwup_abort(_state) do
    IO.puts("Firmware update aborted, cleaning up")
    :ok
  end

  # Optional: confirm firmware on first boot.
  # Called via NervesHubLinkAVM.confirm_update/0.
  # Prevents automatic rollback.
  @impl true
  def fwup_confirm do
    IO.puts("Firmware confirmed, marking as valid")
    # Example: mark the current slot as valid
    # :boot_env_nif.mark_valid()
    :ok
  end
end
