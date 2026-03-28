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
      xref: [exclude: [:ahttp_client, :ssl]],
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: ["test.integration": :test]]
  end

  def application do
    [
      extra_applications: [:crypto, :ssl]
    ]
  end

  defp package do
    [
      maintainers: ["Eliel A. Gordon"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/DensityCo/nerves_hub_link_avm"}
    ]
  end

  defp aliases do
    [
      "test.integration": ["test --include integration"]
    ]
  end

  defp deps do
    []
  end
end
