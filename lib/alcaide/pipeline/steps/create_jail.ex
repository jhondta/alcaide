defmodule Alcaide.Pipeline.Steps.CreateJail do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Create jail"

  @impl true
  def run(context) do
    %{conn: conn, config: config, next_slot: slot} = context

    case Alcaide.Jail.create(conn, config, slot) do
      :ok -> {:ok, context}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def rollback(context) do
    if slot = context[:next_slot] do
      Alcaide.Jail.destroy(context.conn, context.config, slot)
    end

    :ok
  end
end
