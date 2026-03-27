defmodule NervesHubLinkAVM.HTTPClient do
  @moduledoc false

  @max_redirects 5

  @doc """
  Sends an HTTP HEAD request and returns the Content-Length.
  """
  def get_content_length(url) do
    {protocol, host, port, path} = parse_url(url)

    with {:ok, conn} <- :ahttp_client.connect(protocol, host, port, connect_opts()),
         {:ok, conn, ref} <- :ahttp_client.request(conn, "HEAD", path, [], :undefined) do
      result = recv_loop(conn, ref, %{status: nil, content_length: nil})
      :ahttp_client.close(conn)

      case result do
        {:ok, %{content_length: nil}} -> {:error, :no_content_length}
        {:ok, %{content_length: len}} -> {:ok, len}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Streams an HTTP GET response body in chunks, calling `fun.(chunk, acc)` for each.
  Returns `{:ok, final_acc}` or `{:error, reason}`.
  """
  def get_stream(url, acc, fun) do
    do_get_stream(url, acc, fun, 0)
  end

  defp do_get_stream(_url, _acc, _fun, redirects) when redirects >= @max_redirects do
    {:error, :too_many_redirects}
  end

  defp do_get_stream(url, acc, fun, redirects) do
    {protocol, host, port, path} = parse_url(url)

    with {:ok, conn} <- :ahttp_client.connect(protocol, host, port, connect_opts([:location])),
         {:ok, conn, ref} <- :ahttp_client.request(conn, "GET", path, [], :undefined) do
      result = stream_recv_loop(conn, ref, acc, fun, nil)
      :ahttp_client.close(conn)

      case result do
        {:redirect, location} ->
          do_get_stream(to_string(location), acc, fun, redirects + 1)

        other ->
          other
      end
    end
  end

  # -- URL parsing --

  @doc false
  def parse_url(url) when is_binary(url) do
    {scheme, rest} =
      cond do
        String.starts_with?(url, "https://") -> {:https, String.slice(url, 8..-1//1)}
        String.starts_with?(url, "http://") -> {:http, String.slice(url, 7..-1//1)}
        true -> {:https, url}
      end

    {host_port, path} =
      case String.split(rest, "/", parts: 2) do
        [hp] -> {hp, "/"}
        [hp, p] -> {hp, "/" <> p}
      end

    {host, port} =
      case String.split(host_port, ":") do
        [h] -> {h, if(scheme == :https, do: 443, else: 80)}
        [h, p] -> {h, String.to_integer(p)}
      end

    {scheme, String.to_charlist(host), port, String.to_charlist(path)}
  end

  def parse_url(url) when is_list(url), do: parse_url(IO.iodata_to_binary(url))

  # -- Connection options --

  defp connect_opts(extra_headers \\ []) do
    parse_headers = Enum.map(extra_headers, fn h -> to_string(h) end)

    [
      {:active, false},
      {:verify, :verify_none},
      {:parse_headers, parse_headers}
    ]
  end

  # -- Receive loop for HEAD (collect status + content-length) --

  defp recv_loop(conn, ref, result) do
    case :ahttp_client.recv(conn, 0) do
      {:ok, conn, responses} ->
        case process_head_responses(responses, ref, result) do
          {:done, result} -> {:ok, result}
          {:continue, result} -> recv_loop(conn, ref, result)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def process_head_responses([], _ref, result), do: {:continue, result}

  def process_head_responses([{:status, ref, status} | rest], ref, result) do
    process_head_responses(rest, ref, %{result | status: status})
  end

  def process_head_responses([{:done, ref} | _rest], ref, result) do
    {:done, result}
  end

  def process_head_responses([_ | rest], ref, result) do
    process_head_responses(rest, ref, result)
  end

  # -- Streaming receive loop for GET --

  defp stream_recv_loop(conn, ref, acc, fun, redirect) do
    case :ahttp_client.recv(conn, 0) do
      {:ok, _conn, :closed} ->
        {:ok, acc}

      {:ok, conn, responses} ->
        case process_stream_responses(responses, ref, acc, fun, redirect) do
          {:done, acc} -> {:ok, acc}
          {:redirect, location} -> {:redirect, location}
          {:continue, acc, redirect} -> stream_recv_loop(conn, ref, acc, fun, redirect)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def process_stream_responses([], _ref, acc, _fun, redirect), do: {:continue, acc, redirect}

  def process_stream_responses([{:status, ref, status} | rest], ref, acc, fun, _redirect)
       when status in [301, 302, 303, 307] do
    process_stream_responses(rest, ref, acc, fun, :pending_redirect)
  end

  def process_stream_responses([{:status, ref, _status} | rest], ref, acc, fun, redirect) do
    process_stream_responses(rest, ref, acc, fun, redirect)
  end

  def process_stream_responses(
         [{:header, ref, {"Location", location}} | _rest],
         ref,
         _acc,
         _fun,
         :pending_redirect
       ) do
    {:redirect, location}
  end

  def process_stream_responses(
         [{:header, ref, {"location", location}} | _rest],
         ref,
         _acc,
         _fun,
         :pending_redirect
       ) do
    {:redirect, location}
  end

  def process_stream_responses([{:data, ref, chunk} | rest], ref, acc, fun, redirect) do
    case fun.(chunk, acc) do
      {:ok, acc2} -> process_stream_responses(rest, ref, acc2, fun, redirect)
      {:error, _} = err -> err
    end
  end

  def process_stream_responses([{:done, ref} | _rest], ref, acc, _fun, _redirect) do
    {:done, acc}
  end

  def process_stream_responses([_ | rest], ref, acc, fun, redirect) do
    process_stream_responses(rest, ref, acc, fun, redirect)
  end
end
