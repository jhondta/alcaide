defmodule Alcaide.Pipeline.Steps.DetermineSlot do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Determine deployment slot"

  @impl true
  def run(context) do
    %{conn: conn, config: config} = context

    {:ok, next_slot, current_slot} = Alcaide.Jail.determine_next_slot(conn, config)

    {:ok,
     context
     |> Map.put(:next_slot, next_slot)
     |> Map.put(:current_slot, current_slot)}
  end
end
