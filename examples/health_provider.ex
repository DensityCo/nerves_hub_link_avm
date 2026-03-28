defmodule MyApp.HealthProvider do
  @behaviour NervesHubLinkAVM.HealthProvider

  # Called periodically by the NervesHub server via the health extension.
  # Return a map of device metrics. The client wraps this in the
  # expected payload format automatically.
  #
  # Common metrics the NervesHub dashboard understands:
  #   cpu_temp, cpu_usage_percent,
  #   mem_size_mb, mem_used_mb, mem_used_percent,
  #   disk_total_kb, disk_available_kb, disk_used_percentage,
  #   load_1min, load_5min, load_15min

  @impl true
  def health_check do
    %{
      "mem_used_percent" => memory_used_percent(),
      "disk_used_percentage" => disk_used_percentage()
    }
  end

  defp memory_used_percent do
    # Example using AtomVM's :erlang.memory/0
    try do
      mem = :erlang.memory()
      total = Keyword.get(mem, :total, 0)
      used = Keyword.get(mem, :processes_used, 0) + Keyword.get(mem, :system, 0)
      if total > 0, do: Float.round(used / total * 100, 1), else: 0.0
    rescue
      _ -> 0.0
    end
  end

  defp disk_used_percentage do
    # Replace with actual flash/partition usage for your platform
    0.0
  end
end
