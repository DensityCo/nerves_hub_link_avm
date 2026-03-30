defmodule NervesHubLinkAVM.Extension.HealthTest do
  use ExUnit.Case, async: true

  alias NervesHubLinkAVM.Extension.Health

  defmodule TestProvider do
    @behaviour NervesHubLinkAVM.HealthProvider

    def health_check do
      %{"cpu_temp" => 55.0, "mem_used_percent" => 72}
    end
  end

  defmodule EmptyProvider do
    @behaviour NervesHubLinkAVM.HealthProvider

    def health_check, do: %{}
  end

  describe "version/0" do
    test "returns a version string" do
      assert is_binary(Health.version())
    end
  end

  describe "init/1" do
    test "stores provider in state" do
      {:ok, state} = Health.init(provider: TestProvider)
      assert state.provider == TestProvider
    end

    test "raises on missing provider" do
      assert_raise KeyError, fn ->
        Health.init([])
      end
    end
  end

  describe "handle_event/3" do
    test "check event returns health report with metrics and timestamp" do
      {:ok, state} = Health.init(provider: TestProvider)

      {:reply, "report", payload, ^state} = Health.handle_event("check", %{}, state)

      assert %{"value" => %{"metrics" => metrics, "timestamp" => ts}} = payload
      assert metrics["cpu_temp"] == 55.0
      assert metrics["mem_used_percent"] == 72
      assert is_binary(ts)
      assert String.ends_with?(ts, "Z")
    end

    test "check event works with empty metrics" do
      {:ok, state} = Health.init(provider: EmptyProvider)

      {:reply, "report", payload, ^state} = Health.handle_event("check", %{}, state)
      assert payload["value"]["metrics"] == %{}
    end

    test "unknown event returns noreply" do
      {:ok, state} = Health.init(provider: TestProvider)
      assert {:noreply, ^state} = Health.handle_event("unknown", %{}, state)
    end

    test "state is preserved across calls" do
      {:ok, state} = Health.init(provider: TestProvider)
      {:reply, _, _, state2} = Health.handle_event("check", %{}, state)
      {:reply, _, _, state3} = Health.handle_event("check", %{}, state2)
      assert state == state2
      assert state2 == state3
    end
  end
end
