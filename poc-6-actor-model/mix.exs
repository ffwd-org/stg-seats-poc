defmodule StgSeats.MixProject do
  use Mix.Project

  def project do
    [
      app: :stg_seats,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {StgSeats.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry_poller, "~> 1.0"},
      {:websockex, "~> 0.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
