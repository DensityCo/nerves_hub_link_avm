defmodule NervesHubLinkAVM.HealthProvider do
  @moduledoc """
  Behaviour for providing device health metrics.

  Implement `health_check/0` to return a map of metrics. The server
  periodically requests health data via the extensions channel.

  ## Common metrics

  The NervesHub dashboard understands these keys:

  * `cpu_temp` - CPU temperature
  * `cpu_usage_percent` - CPU usage percentage
  * `mem_size_mb` / `mem_used_mb` / `mem_used_percent` - memory stats
  * `disk_total_kb` / `disk_available_kb` / `disk_used_percentage` - disk stats
  * `load_1min` / `load_5min` / `load_15min` - load averages

  ## Example

      defmodule MyApp.HealthProvider do
        @behaviour NervesHubLinkAVM.HealthProvider

        @impl true
        def health_check do
          %{"cpu_temp" => 42.5, "mem_used_percent" => 65}
        end
      end

  Configure via extensions:

      NervesHubLinkAVM.start_link(
        ...,
        extensions: [health: MyApp.HealthProvider]
      )
  """

  @doc "Return a map of device metrics (e.g., cpu_temp, mem_used_percent, disk_used_percentage)."
  @callback health_check() :: map()
end
