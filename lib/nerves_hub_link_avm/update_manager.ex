defmodule NervesHubLinkAVM.UpdateManager do
  @moduledoc false

  # Orchestrates firmware updates by composing pipeline steps:
  # begin → download (verify + write per chunk) → verify finish → write finish.
  #
  # Called from the main GenServer via run/4. Runs in a dedicated spawned process.
  # Sends status updates back to the GenServer for channel delivery.

  alias NervesHubLinkAVM.Downloader

  @doc """
  Run the update pipeline. Called in a spawned process.

  `server` is the GenServer PID to send status updates to.
  """
  def run(fw_url, meta, config, server) do
    expected_sha256 = Map.get(meta, "sha256", "")

    with :apply <- config.client.update_available(meta),
         {:ok, writer_state} <- begin_write(config, meta),
         {:ok, verify_state} <- config.verifier.init(expected_sha256),
         :ok <- send_status(server, "downloading"),
         {:ok, {verify_state, writer_state}} <- download_chunks(config, fw_url, verify_state, writer_state, server),
         :ok <- config.verifier.finish(verify_state),
         :ok <- send_status(server, "updating"),
         :ok <- config.firmware_writer.firmware_finish(writer_state) do
      send_status(server, "fwup_complete")
    else
      :ignore ->
        send_status(server, "ignored")

      {:reschedule, ms} ->
        send_status(server, "reschedule")
        Process.sleep(ms)
        run(fw_url, meta, config, server)

      {:error, reason} ->
        abort_write(config)
        config.client.firmware_error(reason)
        send_status(server, "update_failed")
    end
  end

  # Stash writer_state in the process dictionary so abort_write can access it
  # from the else block. Safe because run/4 always executes in a dedicated process.
  defp begin_write(config, meta) do
    case config.firmware_writer.firmware_begin(0, meta) do
      {:ok, writer_state} ->
        Process.put(:writer_state, writer_state)
        {:ok, writer_state}

      error ->
        error
    end
  end

  defp abort_write(config) do
    case Process.get(:writer_state) do
      nil -> :ok
      writer_state -> config.firmware_writer.firmware_abort(writer_state)
    end
  end

  defp download_chunks(config, fw_url, verify_state, writer_state, server) do
    chunk_fn = fn chunk, {verify_state, writer_state} ->
      with {:ok, verify_state} <- config.verifier.update(chunk, verify_state),
           {:ok, writer_state} <- config.firmware_writer.firmware_chunk(chunk, writer_state) do
        {:ok, {verify_state, writer_state}}
      end
    end

    progress_fn = fn percent ->
      config.client.firmware_progress(percent)
      send_progress(server, percent)
    end

    Downloader.download(config.http_client, fw_url, chunk_fn, {verify_state, writer_state}, progress_fn)
  end

  defp send_status(server, status) do
    GenServer.cast(server, {:send_event, "status_update", %{"status" => status}})
    :ok
  end

  defp send_progress(server, value) do
    GenServer.cast(server, {:send_event, "fwup_progress", %{"value" => value}})
  end
end
