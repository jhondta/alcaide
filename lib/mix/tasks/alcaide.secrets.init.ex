defmodule Mix.Tasks.Alcaide.Secrets.Init do
  @shortdoc "Generate master key and encrypted secrets file"
  @moduledoc """
  Creates the encrypted `deploy.secrets.exs` file with a master key.

  The master key is saved to `.alcaide/master.key` and must be excluded
  from version control (add it to `.gitignore`). The encrypted secrets
  file can be safely committed to the repository.

  ## Usage

      mix alcaide.secrets.init

  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Alcaide.CLI.main(["secrets", "init"])
  end
end
