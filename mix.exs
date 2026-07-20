defmodule Barograph.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      docs: docs(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [preferred_envs: [quality: :test, dialyzer: :test, credo: :test]]
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
      {:thousand_island, "~> 1.5", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        # hex.audit must run before compile — the Hex archive task
        # registry doesn't survive a `mix compile` within the same
        # alias/`mix do` chain.
        "hex.audit",
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "credo --strict",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
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
