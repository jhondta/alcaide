defmodule Alcaide.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :alcaide,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      description: "Deploy Phoenix apps to FreeBSD servers using Jails",
      test_paths: ["test"],
      test_pattern: "*_test.exs"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh, :public_key, :crypto]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp escript do
    [main_module: Alcaide.CLI]
  end
end
