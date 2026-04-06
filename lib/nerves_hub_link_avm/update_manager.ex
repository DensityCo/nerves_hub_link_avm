defmodule NervesHubLinkAVM.UpdateManager do
  @moduledoc false

  # Orchestrates firmware updates by bridging Client (decisions/progress)
  # and FirmwareWriter (hardware writes) through Downloader (HTTP streaming).
  #
  # Called from the main GenServer via run/5. Runs in a spawned process.
  # Sends status updates back to the GenServer for channel delivery.

  alias NervesHubLinkAVM.Client
  alias NervesHubLinkAVM.Downloader

  @doc """
  Run the update pipeline. Called in a spawned process.

  `server` is the GenServer PID to send status updates to.
  """
  def run(fw_url, meta, config, server) do
    client = config.client
    writer = config.firmware_writer
    http = config.http_client
    expected_sha256 = Map.get(meta, "sha256", "")

    case Client.call_update_available(client, meta) do
      :apply ->
        apply_update(http, fw_url, expected_sha256, meta, writer, client, server)

      :ignore ->
        send_status(server, "ignored")

      {:reschedule, ms} ->
        send_status(server, "reschedule")
        Process.sleep(ms)
        run(fw_url, meta, config, server)
    end
  end

  defp apply_update(http, fw_url, expected_sha256, meta, writer, client, server) do
    with {:ok, writer_state} <- writer.firmware_begin(0, meta) do
      send_status(server, "downloading")

      progress_fn = fn percent ->
        Client.call_firmware_progress(client, percent)
        send_progress(server, percent)
      end

      case Downloader.download(http, fw_url, expected_sha256, writer, writer_state, progress_fn) do
        {:ok, writer_state} ->
          send_status(server, "updating")

          case writer.firmware_finish(writer_state) do
            :ok ->
              send_status(server, "fwup_complete")

            {:error, reason} ->
              writer.firmware_abort(writer_state)
              Client.call_firmware_error(client, reason)
              send_status(server, "update_failed")
          end

        {:error, reason} ->
          Client.call_firmware_error(client, reason)
          send_status(server, "update_failed")
      end
    else
      {:error, reason} ->
        Client.call_firmware_error(client, reason)
        send_status(server, "update_failed")
    end
  end

  defp send_status(server, status) do
    GenServer.cast(server, {:send_event, "status_update", %{"status" => status}})
  end

  defp send_progress(server, value) do
    GenServer.cast(server, {:send_event, "fwup_progress", %{"value" => value}})
  end
end
