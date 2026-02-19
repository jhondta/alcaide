defmodule Mix.Tasks.Alcaide.Secrets.Edit do
  @shortdoc "Edit secrets in $EDITOR and re-encrypt"
  @moduledoc """
  Opens the decrypted secrets file in the system text editor for editing.

  The file is decrypted to a temporary location, opened in `$EDITOR`
  (falling back to `$VISUAL`, then `vi`), and re-encrypted when the
  editor exits.

  ## Usage

      mix alcaide.secrets.edit

  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Alcaide.CLI.main(["secrets", "edit"])
  end
end
