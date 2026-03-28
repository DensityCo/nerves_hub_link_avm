defmodule NervesHubLinkAVM.SharedSecretTest do
  use ExUnit.Case, async: true

  alias NervesHubLinkAVM.SharedSecret

  describe "build_headers/3" do
    test "returns 4 x-nh-* headers" do
      headers = SharedSecret.build_headers("nhp_key123", "secret456", "device-001")

      assert length(headers) == 4
      header_map = Map.new(headers)

      assert header_map[<<"x-nh-alg">>] == "NH1-HMAC-sha256-1000-32"
      assert header_map[<<"x-nh-key">>] == "nhp_key123"
      assert is_binary(header_map[<<"x-nh-time">>])
      assert is_binary(header_map[<<"x-nh-signature">>])
    end

    test "timestamp is current unix time" do
      headers = SharedSecret.build_headers("key", "secret", "device")
      header_map = Map.new(headers)

      time = String.to_integer(header_map[<<"x-nh-time">>])
      now = :erlang.system_time(:second)

      assert abs(now - time) < 2
    end

    test "signature is a JWT-like dot-separated string" do
      headers = SharedSecret.build_headers("key", "secret", "device")
      header_map = Map.new(headers)

      signature = header_map[<<"x-nh-signature">>]
      parts = String.split(signature, ".")

      assert length(parts) == 3
    end

    test "different secrets produce different signatures" do
      h1 = SharedSecret.build_headers("key", "secret1", "device") |> Map.new()
      h2 = SharedSecret.build_headers("key", "secret2", "device") |> Map.new()

      assert h1[<<"x-nh-signature">>] != h2[<<"x-nh-signature">>]
    end

    test "different identifiers produce different signatures" do
      h1 = SharedSecret.build_headers("key", "secret", "device-1") |> Map.new()
      h2 = SharedSecret.build_headers("key", "secret", "device-2") |> Map.new()

      assert h1[<<"x-nh-signature">>] != h2[<<"x-nh-signature">>]
    end
  end
end
