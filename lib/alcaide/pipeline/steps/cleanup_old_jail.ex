defmodule Alcaide.Pipeline.Steps.CleanupOldJail do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Stop previous jail"

  @impl true
  def run(context) do
    case context[:current_slot] do
      nil ->
        Alcaide.Output.info("No previous jail to stop (first deploy)")
        {:ok, context}

      slot ->
        %{conn: conn, config: config} = context
        Alcaide.Jail.stop(conn, config, slot)
        {:ok, context}
    end
  end
end
