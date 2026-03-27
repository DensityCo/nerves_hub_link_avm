defmodule NervesHubLinkAVM.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_hub_link_avm,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      description: "NervesHub client for AtomVM devices",
      package: package(),
      deps: deps(),
      atomvm_opts: [start: NervesHubLinkAVM],
      xref: [exclude: [:ahttp_client, :ssl]]
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp package do
    [
      maintainers: ["Eliel A. Gordon"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/DensityCo/nerves_hub_link_avm"}
    ]
  end

  defp deps do
    []
  end
end
