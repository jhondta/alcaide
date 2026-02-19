defmodule Alcaide.Pipeline.Steps.CleanupOldJail do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Clean up previous jail"

  @impl true
  def run(context) do
    case context[:current_slot] do
      nil ->
        Alcaide.Output.info("No previous jail to clean up (first deploy)")
        {:ok, context}

      slot ->
        %{conn: conn, config: config} = context
        Alcaide.Jail.destroy(conn, config, slot)
        {:ok, context}
    end
  end
end
