defmodule NervesHubLinkAVM.Verifier.SHA256Test do
  use ExUnit.Case, async: true

  alias NervesHubLinkAVM.Verifier.SHA256

  describe "init/1" do
    test "returns ok with state" do
      assert {:ok, %{ctx: _, expected: "abc"}} = SHA256.init("abc")
    end
  end

  describe "update/2" do
    test "processes chunks" do
      {:ok, state} = SHA256.init("")
      {:ok, state} = SHA256.update("chunk1", state)
      {:ok, _state} = SHA256.update("chunk2", state)
    end
  end

  describe "finish/1" do
    test "passes with correct hash" do
      data = "verified firmware"
      expected = :crypto.hash(:sha256, data) |> :binary.encode_hex(:lowercase)

      {:ok, state} = SHA256.init(expected)
      {:ok, state} = SHA256.update(data, state)
      assert :ok = SHA256.finish(state)
    end

    test "passes with multi-chunk data" do
      chunks = ["chunk1", "chunk2", "chunk3"]
      full = Enum.join(chunks)
      expected = :crypto.hash(:sha256, full) |> :binary.encode_hex(:lowercase)

      {:ok, state} = SHA256.init(expected)

      state =
        Enum.reduce(chunks, state, fn chunk, acc ->
          {:ok, acc} = SHA256.update(chunk, acc)
          acc
        end)

      assert :ok = SHA256.finish(state)
    end

    test "fails with wrong hash" do
      {:ok, state} = SHA256.init("wrong")
      {:ok, state} = SHA256.update("data", state)
      assert {:error, :sha256_mismatch} = SHA256.finish(state)
    end

    test "skips verification when expected is empty" do
      {:ok, state} = SHA256.init("")
      {:ok, state} = SHA256.update("anything", state)
      assert :ok = SHA256.finish(state)
    end
  end
end
