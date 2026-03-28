defmodule NervesHubLinkAVM.UpdateLifecycleTest do
  use ExUnit.Case

  alias NervesHubLinkAVM.Channel

  # -- Mock HTTP client using :httpc (standard OTP) --

  defmodule MockHTTP do
    def start_server(body) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      spawn_link(fn -> accept_loop(listen, body) end)
      port
    end

    defp accept_loop(listen, body) do
      case :gen_tcp.accept(listen, 5000) do
        {:ok, sock} ->
          {:ok, request} = :gen_tcp.recv(sock, 0, 5000)

          response =
            if String.starts_with?(request, "HEAD") do
              "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n"
            else
              "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
            end

          :gen_tcp.send(sock, response)
          :gen_tcp.close(sock)
          accept_loop(listen, body)

        _ ->
          :gen_tcp.close(listen)
      end
    end

    # HTTPClient-compatible API using :gen_tcp directly

    def get_content_length(url) do
      {host, port, path} = parse(url)

      with {:ok, sock} <- :gen_tcp.connect(host, port, [:binary, active: false], 5000),
           :ok <- :gen_tcp.send(sock, "HEAD #{path} HTTP/1.1\r\nHost: #{host}\r\n\r\n"),
           {:ok, response} <- :gen_tcp.recv(sock, 0, 5000) do
        :gen_tcp.close(sock)

        case Regex.run(~r/Content-Length: (\d+)/, response) do
          [_, len] -> {:ok, String.to_integer(len)}
          _ -> {:error, :no_content_length}
        end
      end
    end

    def get_stream(url, acc, fun) do
      {host, port, path} = parse(url)

      with {:ok, sock} <- :gen_tcp.connect(host, port, [:binary, active: false], 5000),
           :ok <- :gen_tcp.send(sock, "GET #{path} HTTP/1.1\r\nHost: #{host}\r\n\r\n"),
           {:ok, response} <- :gen_tcp.recv(sock, 0, 5000) do
        :gen_tcp.close(sock)

        [_headers, body] = String.split(response, "\r\n\r\n", parts: 2)
        fun.(body, acc)
      end
    end

    defp parse(url) do
      %URI{host: host, port: port, path: path} = URI.parse(url)
      {to_charlist(host), port, path || "/"}
    end
  end

  # -- Test handlers --

  defmodule TestHandler do
    @behaviour NervesHubLinkAVM.DeviceHandler

    def handle_begin(size, meta) do
      send(:lifecycle_test, {:begin, size, meta})
      {:ok, %{chunks: []}}
    end

    def handle_chunk(data, state), do: {:ok, %{state | chunks: state.chunks ++ [data]}}

    def handle_finish(state) do
      send(:lifecycle_test, {:finish, state})
      :ok
    end

    def handle_abort(state) do
      send(:lifecycle_test, {:abort, state})
      :ok
    end
  end

  defmodule FailBeginHandler do
    @behaviour NervesHubLinkAVM.DeviceHandler

    def handle_begin(_, _), do: {:error, :no_space}
    def handle_chunk(_, s), do: {:ok, s}
    def handle_finish(_), do: :ok
    def handle_abort(_), do: :ok
  end

  # -- Helpers --

  defp default_opts(handler \\ TestHandler) do
    [
      host: "hub.example.com",
      device_cert: "fake_cert",
      device_key: "fake_key",
      firmware_meta: %{
        "uuid" => "test-uuid",
        "product" => "test-product",
        "architecture" => "generic",
        "version" => "1.0.0",
        "platform" => "host"
      },
      device_handler: handler,
      http_client: MockHTTP
    ]
  end

  defp start_state(handler \\ TestHandler) do
    {:ok, state} = NervesHubLinkAVM.init(default_opts(handler))
    assert_receive :connect
    %{state | ws_pid: self(), phase: :joined, join_ref: "join_0"}
  end

  defp trigger_update(state, fw_url, opts \\ []) do
    sha256 = Keyword.get(opts, :sha256, "")
    meta = if sha256 != "", do: %{"sha256" => sha256}, else: %{}

    payload = %{
      "update_available" => true,
      "firmware_url" => fw_url,
      "firmware_meta" => meta
    }

    msg = Channel.encode_message("join_0", "ref_1", "device", "update", payload)
    NervesHubLinkAVM.handle_info({:websocket, self(), IO.iodata_to_binary(msg)}, state)
  end

  defp collect_statuses(timeout \\ 1000) do
    collect_statuses([], timeout)
  end

  defp collect_statuses(acc, timeout) do
    receive do
      {:"$gen_cast", {:send_event, "status_update", %{"status" => status}}} ->
        collect_statuses([status | acc], timeout)

      {:"$gen_cast", {:send_event, "fwup_progress", _}} ->
        collect_statuses(acc, timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  # -- Tests --

  describe "successful update" do
    setup do
      Process.register(self(), :lifecycle_test)
      :ok
    end

    test "reports downloading -> updating -> fwup_complete" do
      firmware = "hello firmware data"
      port = MockHTTP.start_server(firmware)
      state = start_state()

      {:noreply, _} = trigger_update(state, "http://localhost:#{port}/fw.bin")

      assert_receive {:begin, _, _}, 3000
      assert_receive {:finish, %{chunks: chunks}}, 3000
      assert Enum.join(chunks) == firmware

      statuses = collect_statuses()
      assert "downloading" in statuses
      assert "updating" in statuses
      assert "fwup_complete" in statuses
    end

    test "SHA256 verification passes with correct hash" do
      firmware = "verified firmware"
      sha256 = :crypto.hash(:sha256, firmware) |> :binary.encode_hex(:lowercase)
      port = MockHTTP.start_server(firmware)
      state = start_state()

      {:noreply, _} = trigger_update(state, "http://localhost:#{port}/fw.bin", sha256: sha256)

      assert_receive {:finish, _}, 3000

      statuses = collect_statuses()
      assert "fwup_complete" in statuses
      refute "update_failed" in statuses
    end
  end

  describe "failed update" do
    setup do
      Process.register(self(), :lifecycle_test)
      :ok
    end

    test "SHA256 mismatch triggers abort and update_failed" do
      firmware = "bad firmware"
      port = MockHTTP.start_server(firmware)
      state = start_state()

      {:noreply, _} = trigger_update(state, "http://localhost:#{port}/fw.bin", sha256: "wrong")

      assert_receive {:abort, _}, 3000

      statuses = collect_statuses()
      assert "update_failed" in statuses
      refute "fwup_complete" in statuses
    end

    test "handler begin failure reports update_failed" do
      firmware = "some data"
      port = MockHTTP.start_server(firmware)
      state = start_state(FailBeginHandler)

      {:noreply, _} = trigger_update(state, "http://localhost:#{port}/fw.bin")

      Process.sleep(500)

      statuses = collect_statuses()
      assert "update_failed" in statuses
    end
  end
end
