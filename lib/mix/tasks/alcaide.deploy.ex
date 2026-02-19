defmodule Mix.Tasks.Alcaide.Deploy do
  @shortdoc "Deploy the application to FreeBSD"
  @moduledoc """
  Deploys the Phoenix application to a FreeBSD server using Jails.

  Executes the full deployment pipeline: build release, upload, create jail,
  install, start, health check, and clean up the previous jail.

  ## Usage

      mix alcaide.deploy [--config deploy.exs]

  ## Options

    * `--config`, `-c` - Path to the configuration file (default: `deploy.exs`)
    * `--verbose`, `-v` - Enable verbose output

  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:ssh)
    Application.ensure_all_started(:public_key)

    Alcaide.CLI.main(["deploy" | args])
  end
end
