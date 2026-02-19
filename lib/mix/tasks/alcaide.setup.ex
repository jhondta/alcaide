defmodule Mix.Tasks.Alcaide.Setup do
  @shortdoc "Set up the FreeBSD server for deployments"
  @moduledoc """
  Prepares a FreeBSD server for deployments with Alcaide.

  This command should be run once when setting up a new server. It will:

  1. Verify the server is running FreeBSD
  2. Enable the jail subsystem
  3. Configure networking (lo1 interface with IP aliases)
  4. Download the FreeBSD base system template
  5. Create the directory structure for jails

  ## Usage

      mix alcaide.setup [--config deploy.exs]

  ## Options

    * `--config`, `-c` - Path to the configuration file (default: `deploy.exs`)
    * `--verbose`, `-v` - Enable verbose output

  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:ssh)
    Application.ensure_all_started(:public_key)

    Alcaide.CLI.main(["setup" | args])
  end
end
