defmodule NervesHubLinkAVM.UpdateManager do
  @moduledoc false

  # Orchestrates firmware updates by composing pipeline steps:
  # begin → download (verify + write per chunk) → verify finish → write finish.
  #
  # Called from the main GenServer via run/4. Runs in a spawned process.
  # Sends status updates back to the GenServer for channel delivery.

  alias NervesHubLinkAVM.Downloader

  defmodule Update do
    @moduledoc false
    defstruct [:writer_state, :verify_state]
  end

  @doc """
  Run the update pipeline. Called in a spawned process.

  `server` is the GenServer PID to send status updates to.
  """
  def run(fw_url, meta, config, server) do
    expected_sha256 = Map.get(meta, "sha256", "")

    with :apply <- config.client.update_available(meta),
         {:ok, writer_state} <- config.firmware_writer.firmware_begin(0, meta),
         {:ok, verify_state} <- config.verifier.init(expected_sha256),
         update = %Update{writer_state: writer_state, verify_state: verify_state},
         :ok <- send_status(server, "downloading"),
         {:ok, update} <- download_chunks(config, fw_url, update, server),
         :ok <- finish_verify(config, update),
         :ok <- send_status(server, "updating"),
         :ok <- finish_write(config, update) do
      send_status(server, "fwup_complete")
    else
      :ignore ->
        send_status(server, "ignored")

      {:reschedule, ms} ->
        send_status(server, "reschedule")
        Process.sleep(ms)
        run(fw_url, meta, config, server)

      {:error, reason} ->
        config.client.firmware_error(reason)
        send_status(server, "update_failed")

      {:error, reason, %Update{} = update} ->
        config.firmware_writer.firmware_abort(update.writer_state)
        config.client.firmware_error(reason)
        send_status(server, "update_failed")
    end
  end

  defp download_chunks(config, fw_url, update, server) do
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

    acc = {update.verify_state, update.writer_state}

    case Downloader.download(config.http_client, fw_url, chunk_fn, acc, progress_fn) do
      {:ok, {verify_state, writer_state}} ->
        {:ok, %Update{verify_state: verify_state, writer_state: writer_state}}

      {:error, reason} ->
        {:error, reason, update}
    end
  end

  defp finish_verify(config, update) do
    case config.verifier.finish(update.verify_state) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, update}
    end
  end

  defp finish_write(config, update) do
    case config.firmware_writer.firmware_finish(update.writer_state) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, update}
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
