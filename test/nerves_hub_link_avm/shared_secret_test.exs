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

  describe "server-compatible verification" do
    test "signature is verifiable with server-side logic" do
      key = "nhp_test"
      secret = "mysecret"
      identifier = "device-001"

      headers = SharedSecret.build_headers(key, secret, identifier) |> Map.new()
      time = headers[<<"x-nh-time">>]
      alg = headers[<<"x-nh-alg">>]

      # Reconstruct salt exactly as server does
      salt =
        "NH1:device-socket:shared-secret:connect\n\nx-nh-alg=#{alg}\nx-nh-key=#{key}\nx-nh-time=#{time}\n"

      # Derive PBKDF2 key
      derived = :crypto.pbkdf2_hmac(:sha256, secret, salt, 1000, 32)

      # Split token: protected.payload.mac
      [protected, payload, mac] = String.split(headers[<<"x-nh-signature">>], ".")

      # Verify HMAC
      message = "#{protected}.#{payload}"
      expected_mac = :crypto.mac(:hmac, :sha256, derived, message)
      assert url_decode64(mac) == expected_mac

      # Verify payload contains the identifier
      {^identifier, signed_at_ms, max_age} =
        url_decode64(payload) |> :erlang.binary_to_term()

      assert is_integer(signed_at_ms)
      assert max_age == 86400
    end

    test "signature fails verification with wrong secret" do
      headers = SharedSecret.build_headers("key", "real_secret", "device") |> Map.new()
      time = headers[<<"x-nh-time">>]
      alg = headers[<<"x-nh-alg">>]

      salt =
        "NH1:device-socket:shared-secret:connect\n\nx-nh-alg=#{alg}\nx-nh-key=key\nx-nh-time=#{time}\n"

      wrong_derived = :crypto.pbkdf2_hmac(:sha256, "wrong_secret", salt, 1000, 32)

      [protected, payload, mac] = String.split(headers[<<"x-nh-signature">>], ".")
      message = "#{protected}.#{payload}"
      wrong_mac = :crypto.mac(:hmac, :sha256, wrong_derived, message)

      refute url_decode64(mac) == wrong_mac
    end
  end

  defp url_decode64(data) do
    padded =
      case rem(byte_size(data), 4) do
        2 -> <<data::binary, "==">>
        3 -> <<data::binary, "=">>
        _ -> data
      end

    padded
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> Base.decode64!()
  end
end
