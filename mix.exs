defmodule Barograph.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/barograph"

  def project do
    [
      app: :barograph,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Barograph.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.39.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Time-series and event analytics for Elixir, stored in SQLite. " <>
      "One file. No server. Full SQL."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Website" => "https://beamla.eu/libraries/barograph"
      },
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Barograph",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
