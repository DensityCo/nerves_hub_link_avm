defmodule NervesHubLinkAVM.UpdateManager do
  @moduledoc false

  # Orchestrates firmware updates by composing pipeline steps:
  # begin → download (verify + write per chunk) → verify finish → write finish.
  #
  # Called from the main GenServer via run/4. Runs in a spawned process.
  # Sends status updates back to the GenServer for channel delivery.

  alias NervesHubLinkAVM.Client
  alias NervesHubLinkAVM.Downloader

  @doc """
  Run the update pipeline. Called in a spawned process.

  `server` is the GenServer PID to send status updates to.
  """
  def run(fw_url, meta, config, server) do
    case Client.call_update_available(config.client, meta) do
      :apply ->
        apply_update(config, fw_url, meta, server)

      :ignore ->
        send_status(server, "ignored")

      {:reschedule, ms} ->
        send_status(server, "reschedule")
        Process.sleep(ms)
        run(fw_url, meta, config, server)
    end
  end

  defp apply_update(config, fw_url, meta, server) do
    expected_sha256 = Map.get(meta, "sha256", "")

    with {:ok, ws} <- config.firmware_writer.firmware_begin(0, meta),
         {:ok, vs} <- config.verifier.init(expected_sha256) do
      send_status(server, "downloading")
      run_pipeline(config, fw_url, vs, ws, server)
    else
      {:error, reason} ->
        Client.call_firmware_error(config.client, reason)
        send_status(server, "update_failed")
    end
  end

  # After begin + init succeed, writer_state is available for abort on any failure.
  defp run_pipeline(config, fw_url, verify_state, writer_state, server) do
    chunk_fn = fn chunk, {vs, ws} ->
      with {:ok, vs} <- config.verifier.update(chunk, vs),
           {:ok, ws} <- config.firmware_writer.firmware_chunk(chunk, ws) do
        {:ok, {vs, ws}}
      end
    end

    progress_fn = fn percent ->
      Client.call_firmware_progress(config.client, percent)
      send_progress(server, percent)
    end

    with {:ok, {vs, ws}} <-
           Downloader.download(config.http_client, fw_url, chunk_fn, {verify_state, writer_state}, progress_fn),
         :ok <- config.verifier.finish(vs),
         :ok <- send_status(server, "updating"),
         :ok <- config.firmware_writer.firmware_finish(ws) do
      send_status(server, "fwup_complete")
    else
      {:error, reason} ->
        config.firmware_writer.firmware_abort(writer_state)
        Client.call_firmware_error(config.client, reason)
        send_status(server, "update_failed")
    end
  end

  defp send_status(server, status) do
    GenServer.cast(server, {:send_event, "status_update", %{"status" => status}})
    :ok
  end

  defp send_progress(server, value) do
    GenServer.cast(server, {:send_event, "fwup_progress", %{"value" => value}})
  end
end
