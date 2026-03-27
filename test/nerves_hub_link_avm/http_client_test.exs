defmodule NervesHubLinkAVM.HTTPClientTest do
  use ExUnit.Case, async: true

  alias NervesHubLinkAVM.HTTPClient

  describe "parse_url/1" do
    test "parses https URL with default port" do
      assert {:https, ~c"example.com", 443, ~c"/firmware/latest.bin"} =
               HTTPClient.parse_url("https://example.com/firmware/latest.bin")
    end

    test "parses http URL with default port" do
      assert {:http, ~c"example.com", 80, ~c"/path"} =
               HTTPClient.parse_url("http://example.com/path")
    end

    test "parses URL with explicit port" do
      assert {:https, ~c"example.com", 8443, ~c"/fw"} =
               HTTPClient.parse_url("https://example.com:8443/fw")
    end

    test "parses http URL with explicit port" do
      assert {:http, ~c"localhost", 4000, ~c"/api/firmware"} =
               HTTPClient.parse_url("http://localhost:4000/api/firmware")
    end

    test "defaults to / path when no path given" do
      assert {:https, ~c"example.com", 443, ~c"/"} =
               HTTPClient.parse_url("https://example.com")
    end

    test "defaults to https for bare URLs" do
      assert {:https, ~c"example.com", 443, ~c"/path"} =
               HTTPClient.parse_url("example.com/path")
    end

    test "handles charlist input" do
      assert {:https, ~c"example.com", 443, ~c"/fw"} =
               HTTPClient.parse_url(~c"https://example.com/fw")
    end

    test "handles deep path" do
      assert {:https, ~c"hub.example.com", 443, ~c"/api/v1/devices/fw/download"} =
               HTTPClient.parse_url("https://hub.example.com/api/v1/devices/fw/download")
    end
  end

  describe "process_head_responses/3" do
    test "returns continue on empty responses" do
      result = %{status: nil, content_length: nil}
      assert {:continue, ^result} = HTTPClient.process_head_responses([], make_ref(), result)
    end

    test "captures status code" do
      ref = make_ref()
      responses = [{:status, ref, 200}]
      result = %{status: nil, content_length: nil}
      assert {:continue, %{status: 200}} = HTTPClient.process_head_responses(responses, ref, result)
    end

    test "returns done when done response received" do
      ref = make_ref()
      responses = [{:done, ref}]
      result = %{status: 200, content_length: 1024}
      assert {:done, ^result} = HTTPClient.process_head_responses(responses, ref, result)
    end

    test "processes status then done in sequence" do
      ref = make_ref()
      responses = [{:status, ref, 200}, {:done, ref}]
      result = %{status: nil, content_length: nil}
      assert {:done, %{status: 200}} = HTTPClient.process_head_responses(responses, ref, result)
    end

    test "skips unrecognized responses" do
      ref = make_ref()
      responses = [{:something_else, ref, "ignored"}, {:status, ref, 200}]
      result = %{status: nil, content_length: nil}
      assert {:continue, %{status: 200}} = HTTPClient.process_head_responses(responses, ref, result)
    end

    test "ignores responses for different ref" do
      ref = make_ref()
      other_ref = make_ref()
      responses = [{:status, other_ref, 404}, {:status, ref, 200}]
      result = %{status: nil, content_length: nil}
      assert {:continue, %{status: 200}} = HTTPClient.process_head_responses(responses, ref, result)
    end
  end

  describe "process_stream_responses/5" do
    test "returns continue on empty responses" do
      ref = make_ref()
      assert {:continue, [], nil} = HTTPClient.process_stream_responses([], ref, [], &noop/2, nil)
    end

    test "processes data chunks through callback" do
      ref = make_ref()
      responses = [{:data, ref, "chunk1"}, {:data, ref, "chunk2"}]
      fun = fn chunk, acc -> {:ok, acc ++ [chunk]} end

      assert {:continue, ["chunk1", "chunk2"], nil} =
               HTTPClient.process_stream_responses(responses, ref, [], fun, nil)
    end

    test "returns done when response complete" do
      ref = make_ref()
      responses = [{:data, ref, "data"}, {:done, ref}]
      fun = fn chunk, acc -> {:ok, acc <> chunk} end

      assert {:done, "data"} =
               HTTPClient.process_stream_responses(responses, ref, "", fun, nil)
    end

    test "detects redirect with Location header" do
      ref = make_ref()
      responses = [{:status, ref, 302}, {:header, ref, {"Location", "https://new.example.com/fw"}}]

      assert {:redirect, "https://new.example.com/fw"} =
               HTTPClient.process_stream_responses(responses, ref, "", &noop/2, nil)
    end

    test "detects redirect with lowercase location header" do
      ref = make_ref()
      responses = [{:status, ref, 301}, {:header, ref, {"location", "https://new.example.com/fw"}}]

      assert {:redirect, "https://new.example.com/fw"} =
               HTTPClient.process_stream_responses(responses, ref, "", &noop/2, nil)
    end

    test "handles all redirect status codes" do
      for status <- [301, 302, 303, 307] do
        ref = make_ref()
        responses = [{:status, ref, status}, {:header, ref, {"Location", "/new"}}]

        assert {:redirect, "/new"} =
                 HTTPClient.process_stream_responses(responses, ref, "", &noop/2, nil),
               "failed for status #{status}"
      end
    end

    test "non-redirect status does not trigger redirect" do
      ref = make_ref()
      responses = [{:status, ref, 200}, {:header, ref, {"Location", "/ignored"}}]
      fun = fn _chunk, acc -> {:ok, acc} end

      assert {:continue, "", nil} =
               HTTPClient.process_stream_responses(responses, ref, "", fun, nil)
    end

    test "propagates callback errors" do
      ref = make_ref()
      responses = [{:data, ref, "data"}]
      fun = fn _chunk, _acc -> {:error, :write_failed} end

      assert {:error, :write_failed} =
               HTTPClient.process_stream_responses(responses, ref, "", fun, nil)
    end

    test "stops processing after callback error" do
      ref = make_ref()
      responses = [{:data, ref, "a"}, {:data, ref, "b"}]

      called = :counters.new(1, [:atomics])
      fun = fn _chunk, _acc ->
        :counters.add(called, 1, 1)
        {:error, :fail}
      end

      assert {:error, :fail} =
               HTTPClient.process_stream_responses(responses, ref, "", fun, nil)

      assert :counters.get(called, 1) == 1
    end
  end

  defp noop(_chunk, acc), do: {:ok, acc}
end
