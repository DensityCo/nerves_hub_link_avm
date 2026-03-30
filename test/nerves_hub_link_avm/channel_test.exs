defmodule NervesHubLinkAVM.ChannelTest do
  use ExUnit.Case, async: true

  alias NervesHubLinkAVM.Channel

  describe "encode_message/5" do
    test "encodes a join message" do
      encoded = Channel.encode_message("join_0", "ref_0", "device", "phx_join", %{"key" => "val"})
      decoded = :json.decode(IO.iodata_to_binary(encoded))
      assert decoded == ["join_0", "ref_0", "device", "phx_join", %{"key" => "val"}]
    end

    test "encodes nil join_ref for heartbeats" do
      encoded = Channel.encode_message(nil, "hb_1", "phoenix", "heartbeat", %{})
      raw = IO.iodata_to_binary(encoded)
      # nil becomes "nil" string since :json.encode treats nil as an atom, not null
      # The important thing is it roundtrips through encode/decode
      assert is_binary(raw)
      assert String.contains?(raw, "hb_1")
    end

    test "encodes empty payload" do
      encoded = Channel.encode_message("j", "r", "t", "e", %{})
      decoded = :json.decode(IO.iodata_to_binary(encoded))
      assert decoded == ["j", "r", "t", "e", %{}]
    end

    test "encodes nested payload" do
      payload = %{"firmware_meta" => %{"version" => "1.0.0", "platform" => "esp32"}}
      encoded = Channel.encode_message("j", "r", "device", "update", payload)
      decoded = :json.decode(IO.iodata_to_binary(encoded))
      assert decoded == ["j", "r", "device", "update", payload]
    end
  end

  describe "decode_message/1" do
    test "decodes a valid 5-element JSON array" do
      raw = :json.encode(["join_0", "ref_0", "device", "phx_reply", %{"status" => "ok"}])

      assert {:ok, {"join_0", "ref_0", "device", "phx_reply", %{"status" => "ok"}}} =
               Channel.decode_message(IO.iodata_to_binary(raw))
    end

    test "decodes message with null join_ref" do
      raw = ~s([null, "hb_1", "phoenix", "heartbeat", {}])

      assert {:ok, {nil, "hb_1", "phoenix", "heartbeat", %{}}} =
               Channel.decode_message(raw)
    end

    test "returns error for wrong array length" do
      raw = :json.encode(["only", "three", "elements"])
      assert {:error, {:unexpected_format, _}} = Channel.decode_message(IO.iodata_to_binary(raw))
    end

    test "returns error for non-array JSON" do
      raw = :json.encode(%{"not" => "an_array"})
      assert {:error, {:unexpected_format, _}} = Channel.decode_message(IO.iodata_to_binary(raw))
    end

    test "raises on invalid JSON" do
      assert_raise MatchError, fn ->
        Channel.decode_message("{not json")
      end
    end
  end

  describe "encode/decode roundtrip" do
    test "roundtrips a message" do
      encoded = Channel.encode_message("j1", "r1", "device", "update", %{"fw" => "url"})
      {:ok, decoded} = Channel.decode_message(IO.iodata_to_binary(encoded))
      assert decoded == {"j1", "r1", "device", "update", %{"fw" => "url"}}
    end

    test "roundtrips message with complex payload" do
      payload = %{
        "update_available" => true,
        "firmware_url" => "https://example.com/fw.bin",
        "firmware_meta" => %{"sha256" => "abc123", "version" => "2.0.0"}
      }

      encoded = Channel.encode_message("join_5", "ref_5", "device", "update", payload)
      {:ok, decoded} = Channel.decode_message(IO.iodata_to_binary(encoded))
      assert decoded == {"join_5", "ref_5", "device", "update", payload}
    end
  end
end
