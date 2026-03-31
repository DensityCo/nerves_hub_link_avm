defmodule NervesHubLinkAVM.MixProject do
  use Mix.Project

  @source_url "https://github.com/DensityCo/nerves_hub_link_avm"
  @version "0.1.0"

  def project do
    [
      app: :nerves_hub_link_avm,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      description: "NervesHub client for AtomVM devices",
      source_url: @source_url,
      package: package(),
      deps: deps(),
      docs: docs(),
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
      links: %{
        "GitHub" => @source_url,
        "Hex" => "https://hex.pm/packages/nerves_hub_link_avm"
      },
      files: ~w(lib src mix.exs .formatter.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"]
    ]
  end

  defp aliases do
    [
      "test.integration": ["test --include integration"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
