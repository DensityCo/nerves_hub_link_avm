defmodule NervesHubLinkAVM.Downloader do
  @moduledoc false

  # Streams firmware via HTTP, calling a caller-provided chunk callback
  # and reporting download progress. Pure module — no GenServer, no state
  # beyond the download. Does not know about writers or verifiers.

  @doc """
  Download firmware and pipe chunks through `chunk_fn`.

  * `chunk_fn` — `fn chunk, acc -> {:ok, acc} | {:error, reason}`, called per chunk
  * `initial_acc` — starting accumulator for `chunk_fn`
  * `progress_fn` — `fn percent -> :ok`, called when progress changes

  Returns `{:ok, final_acc}` or `{:error, reason}`.
  """
  def download(http, url, chunk_fn, initial_acc, progress_fn) do
    with {:ok, size} <- get_size(http, url) do
      stream(http, url, size, chunk_fn, initial_acc, progress_fn)
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

  defp stream(http, url, total_size, chunk_fn, initial_acc, progress_fn) do
    acc = %{
      user_acc: initial_acc,
      chunk_fn: chunk_fn,
      bytes_received: 0,
      total_size: total_size,
      progress_fn: progress_fn,
      last_progress: -1
    }

    case http.get_stream(url, acc, &chunk_callback/2) do
      {:ok, %{user_acc: final_acc}} -> {:ok, final_acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunk_callback(chunk, acc) do
    case acc.chunk_fn.(chunk, acc.user_acc) do
      {:ok, new_user_acc} ->
        bytes = acc.bytes_received + byte_size(chunk)
        progress = calc_progress(bytes, acc.total_size)

        if progress > acc.last_progress do
          acc.progress_fn.(progress)
        end

        {:ok,
         %{
           acc
           | user_acc: new_user_acc,
             bytes_received: bytes,
             last_progress: max(progress, acc.last_progress)
         }}

      {:error, _} = err ->
        err
    end
  end

  defp calc_progress(_bytes, 0), do: 0
  defp calc_progress(bytes, total), do: trunc(bytes / total * 100)
end
