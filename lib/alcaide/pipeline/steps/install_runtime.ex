defmodule Alcaide.Pipeline.Steps.InstallRuntime do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Install Erlang runtime"

  @impl true
  def run(context) do
    %{conn: conn, config: config, next_slot: slot} = context

    case Alcaide.Jail.install_runtime(conn, config, slot) do
      :ok -> {:ok, context}
      {:error, reason} -> {:error, reason}
    end
  end
end
