defmodule Alcaide.Pipeline.Steps.InstallRelease do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Install release in jail"

  @impl true
  def run(context) do
    %{conn: conn, config: config, next_slot: slot, remote_tarball_path: tarball} = context

    case Alcaide.Jail.install_release(conn, config, slot, tarball) do
      :ok -> {:ok, context}
      {:error, reason} -> {:error, reason}
    end
  end
end
