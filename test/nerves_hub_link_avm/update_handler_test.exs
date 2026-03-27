defmodule NervesHubLinkAVM.UpdateHandlerTest do
  use ExUnit.Case, async: true

  defmodule TestHandler do
    @behaviour NervesHubLinkAVM.UpdateHandler

    @impl true
    def handle_begin(size, meta) do
      {:ok, %{size: size, meta: meta, chunks: [], finished: false}}
    end

    @impl true
    def handle_chunk(data, state) do
      {:ok, %{state | chunks: state.chunks ++ [data]}}
    end

    @impl true
    def handle_finish(_sha256, state) do
      send(self(), {:finish_called, %{state | finished: true}})
      :ok
    end

    @impl true
    def handle_confirm do
      send(self(), :confirm_called)
      :ok
    end

    @impl true
    def handle_abort(state) do
      send(self(), {:abort_called, state})
      :ok
    end
  end

  defmodule FailingHandler do
    @behaviour NervesHubLinkAVM.UpdateHandler

    @impl true
    def handle_begin(_size, _meta), do: {:error, :no_space}

    @impl true
    def handle_chunk(_data, _state), do: {:error, :write_failed}

    @impl true
    def handle_finish(_sha256, _state), do: {:error, :bad_hash}

    @impl true
    def handle_abort(_state), do: :ok
  end

  describe "TestHandler" do
    test "handle_begin returns initial state with size and meta" do
      assert {:ok, state} = TestHandler.handle_begin(1024, %{"version" => "1.0"})
      assert state.size == 1024
      assert state.meta == %{"version" => "1.0"}
      assert state.chunks == []
      assert state.finished == false
    end

    test "handle_chunk accumulates data" do
      {:ok, state} = TestHandler.handle_begin(100, %{})
      {:ok, state} = TestHandler.handle_chunk("chunk1", state)
      {:ok, state} = TestHandler.handle_chunk("chunk2", state)
      assert state.chunks == ["chunk1", "chunk2"]
    end

    test "handle_finish signals completion" do
      {:ok, state} = TestHandler.handle_begin(100, %{})
      {:ok, state} = TestHandler.handle_chunk("data", state)
      assert :ok = TestHandler.handle_finish("sha256hash", state)
      assert_receive {:finish_called, %{finished: true, chunks: ["data"]}}
    end

    test "handle_confirm sends message" do
      assert :ok = TestHandler.handle_confirm()
      assert_receive :confirm_called
    end

    test "handle_abort sends message with state" do
      {:ok, state} = TestHandler.handle_begin(100, %{})
      assert :ok = TestHandler.handle_abort(state)
      assert_receive {:abort_called, ^state}
    end
  end

  describe "FailingHandler" do
    test "handle_begin returns error" do
      assert {:error, :no_space} = FailingHandler.handle_begin(1024, %{})
    end

    test "handle_chunk returns error" do
      assert {:error, :write_failed} = FailingHandler.handle_chunk("data", %{})
    end

    test "handle_finish returns error" do
      assert {:error, :bad_hash} = FailingHandler.handle_finish("hash", %{})
    end
  end

  describe "full update flow" do
    test "simulates a complete firmware update cycle" do
      {:ok, state} = TestHandler.handle_begin(30, %{"version" => "2.0"})

      chunks = ["0123456789", "abcdefghij", "ABCDEFGHIJ"]

      state =
        Enum.reduce(chunks, state, fn chunk, acc ->
          {:ok, new_acc} = TestHandler.handle_chunk(chunk, acc)
          new_acc
        end)

      assert length(state.chunks) == 3
      assert Enum.join(state.chunks) == "0123456789abcdefghijABCDEFGHIJ"

      assert :ok = TestHandler.handle_finish("expected_sha", state)
      assert_receive {:finish_called, %{finished: true}}
    end

    test "simulates an aborted update" do
      {:ok, state} = TestHandler.handle_begin(1000, %{})
      {:ok, state} = TestHandler.handle_chunk("partial", state)

      assert :ok = TestHandler.handle_abort(state)
      assert_receive {:abort_called, %{chunks: ["partial"]}}
    end
  end
end
