defmodule Mix.Tasks.Alcaide.Rollback do
  @shortdoc "Roll back to the previous deployment"
  @moduledoc """
  Rolls back to the previous deployment by reactivating the stopped jail.

  After a successful deploy, the previous jail is kept stopped on disk.
  This command starts it again, runs a health check, and switches the
  proxy to point to it.

  Rollback is only possible if the previous jail still exists. Once a
  new deploy succeeds, the stale jail from the cycle before is destroyed.

  ## Usage

      mix alcaide.rollback [--config deploy.exs]

  ## Options

    * `--config`, `-c` - Path to the configuration file (default: `deploy.exs`)
    * `--verbose`, `-v` - Enable verbose output

  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:ssh)
    Application.ensure_all_started(:public_key)

    Alcaide.CLI.main(["rollback" | args])
  end
end
