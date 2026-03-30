defmodule NervesHubLinkAVM.ExtensionsTest do
  use ExUnit.Case, async: true

  alias NervesHubLinkAVM.Extensions

  defmodule FakeExtension do
    @behaviour NervesHubLinkAVM.Extension

    def version, do: "1.2.3"

    def init(opts) do
      {:ok, %{name: Keyword.get(opts, :name, "fake")}}
    end

    def handle_event("ping", _payload, state) do
      {:reply, "pong", %{"from" => state.name}, state}
    end

    def handle_event("count", _payload, state) do
      new_state = Map.update(state, :count, 1, &(&1 + 1))
      {:noreply, new_state}
    end

    def handle_event(_, _, state), do: {:noreply, state}
  end

  defp init_extensions do
    Extensions.init([{:test, {FakeExtension, [name: "tester"]}}])
  end

  describe "init/1" do
    test "initializes extensions from config" do
      exts = init_extensions()
      assert %{test: %{mod: FakeExtension, state: %{name: "tester"}}} = exts
    end

    test "returns empty map for empty config" do
      assert %{} = Extensions.init([])
    end
  end

  describe "any?/1" do
    test "true when extensions configured" do
      assert Extensions.any?(init_extensions())
    end

    test "false when empty" do
      refute Extensions.any?(%{})
    end
  end

  describe "versions/1" do
    test "builds version map from extensions" do
      exts = init_extensions()
      assert %{"test" => "1.2.3"} = Extensions.versions(exts)
    end

    test "empty map for no extensions" do
      assert %{} = Extensions.versions(%{})
    end
  end

  describe "attachable/2" do
    test "filters attach list to configured extensions" do
      exts = init_extensions()
      assert ["test"] = Extensions.attachable(["test", "unknown"], exts)
    end

    test "returns empty for no matches" do
      exts = init_extensions()
      assert [] = Extensions.attachable(["geo", "shell"], exts)
    end
  end

  describe "handle_event/3" do
    test "routes event to correct extension and returns reply" do
      exts = init_extensions()

      assert {:reply, "test:pong", %{"from" => "tester"}, _updated} =
               Extensions.handle_event("test:ping", %{}, exts)
    end

    test "routes event and returns noreply with updated state" do
      exts = init_extensions()

      {:noreply, updated} = Extensions.handle_event("test:count", %{}, exts)
      assert updated.test.state.count == 1

      {:noreply, updated2} = Extensions.handle_event("test:count", %{}, updated)
      assert updated2.test.state.count == 2
    end

    test "unknown extension returns noreply" do
      exts = init_extensions()
      assert {:noreply, ^exts} = Extensions.handle_event("bogus:event", %{}, exts)
    end

    test "unknown event on known extension returns noreply" do
      exts = init_extensions()
      assert {:noreply, _} = Extensions.handle_event("test:unknown", %{}, exts)
    end

    test "malformed event (no colon) returns noreply" do
      exts = init_extensions()
      assert {:noreply, ^exts} = Extensions.handle_event("nocolon", %{}, exts)
    end
  end
end
