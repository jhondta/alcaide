defmodule Mix.Tasks.Alcaide.Logs do
  @shortdoc "Show application logs from the active jail"
  @moduledoc """
  Shows the application logs from the currently active jail.

  ## Usage

      mix alcaide.logs [--follow] [--lines 100] [--config deploy.exs]

  ## Options

    * `--follow`, `-f` - Follow logs in real time (Ctrl+C to stop)
    * `--lines`, `-n` - Number of lines to show (default: 100)
    * `--config`, `-c` - Path to the configuration file (default: `deploy.exs`)

  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:ssh)
    Application.ensure_all_started(:public_key)

    Alcaide.CLI.main(["logs" | args])
  end
end
