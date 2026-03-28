defmodule NervesHubLinkAVM.HealthProvider do
  @moduledoc false

  @doc "Return a map of device metrics (e.g., cpu_temp, mem_used_percent, disk_used_percentage)."
  @callback health_check() :: map()
end
