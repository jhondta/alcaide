defmodule Alcaide.Pipeline.Steps.StartJail do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Start jail and application"

  @impl true
  def run(context) do
    %{conn: conn, config: config, next_slot: slot} = context

    with :ok <- Alcaide.Jail.start(conn, config, slot),
         :ok <- Alcaide.Jail.start_app(conn, config, slot) do
      {:ok, context}
    end
  end

  @impl true
  def rollback(context) do
    if slot = context[:next_slot] do
      Alcaide.Jail.stop(context.conn, context.config, slot)
    end

    :ok
  end
end
