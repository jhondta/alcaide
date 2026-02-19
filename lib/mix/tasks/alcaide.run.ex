defmodule Mix.Tasks.Alcaide.Run do
  @shortdoc "Run a command inside the active jail"
  @moduledoc """
  Executes an arbitrary command inside the currently active jail.

  Useful for maintenance tasks like running IEx, checking processes,
  or invoking release commands.

  ## Usage

      mix alcaide.run "<command>" [--config deploy.exs]

  ## Examples

      mix alcaide.run "bin/my_app rpc 'IO.inspect(Node.self())'"
      mix alcaide.run "bin/my_app eval 'MyApp.Release.migrate()'"

  ## Options

    * `--config`, `-c` - Path to the configuration file (default: `deploy.exs`)

  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:ssh)
    Application.ensure_all_started(:public_key)

    Alcaide.CLI.main(["run" | args])
  end
end
