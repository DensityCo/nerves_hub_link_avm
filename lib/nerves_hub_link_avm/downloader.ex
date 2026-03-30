defmodule NervesHubLinkAVM.Downloader do
  @moduledoc false

  # Downloads firmware via HTTP, streams chunks through FwupWriter,
  # computes SHA256 incrementally, and reports progress.
  # Pure module — no GenServer, no state beyond the download.

  @doc """
  Download firmware and pipe through the writer.

  Returns `{:ok, writer_state}` on success or `{:error, reason}` / `{:error, reason, writer_state}` on failure.
  """
  def download(http, url, expected_sha256, writer, writer_state, progress_fn) do
    with {:ok, size} <- get_size(http, url),
         {:ok, writer_state, hash_ctx} <- stream(http, url, size, writer, writer_state, progress_fn),
         :ok <- verify_sha256(hash_ctx, expected_sha256) do
      {:ok, writer_state}
    else
      {:error, reason, writer_state} ->
        writer.fwup_abort(writer_state)
        {:error, reason}

      {:error, reason} ->
        writer.fwup_abort(writer_state)
        {:error, reason}
    end
  end

  # -- Size --

  defp get_size(http, url) do
    case http.get_content_length(url) do
      {:ok, size} -> {:ok, size}
      {:error, _} -> {:ok, 0}
    end
  end

  # -- Streaming --

  defp stream(http, url, total_size, writer, writer_state, progress_fn) do
    acc = %{
      writer: writer,
      writer_state: writer_state,
      hash_ctx: :crypto.hash_init(:sha256),
      bytes_received: 0,
      total_size: total_size,
      progress_fn: progress_fn,
      last_progress: -1
    }

    case http.get_stream(url, acc, &chunk_callback/2) do
      {:ok, %{writer_state: ws, hash_ctx: ctx}} -> {:ok, ws, ctx}
      {:error, reason} -> {:error, reason, writer_state}
    end
  end

  defp chunk_callback(chunk, acc) do
    with {:ok, new_ws} <- acc.writer.fwup_chunk(chunk, acc.writer_state) do
      bytes = acc.bytes_received + byte_size(chunk)
      progress = calc_progress(bytes, acc.total_size)

      if progress > acc.last_progress do
        acc.progress_fn.(progress)
      end

      {:ok,
       %{
         acc
         | writer_state: new_ws,
           hash_ctx: :crypto.hash_update(acc.hash_ctx, chunk),
           bytes_received: bytes,
           last_progress: max(progress, acc.last_progress)
       }}
    end
  end

  defp calc_progress(_bytes, 0), do: 0
  defp calc_progress(bytes, total), do: trunc(bytes / total * 100)

  defp verify_sha256(_hash_ctx, ""), do: :ok

  defp verify_sha256(hash_ctx, expected) do
    computed =
      :crypto.hash_final(hash_ctx)
      |> :binary.encode_hex(:lowercase)

    if computed == expected, do: :ok, else: {:error, :sha256_mismatch}
  end
end
