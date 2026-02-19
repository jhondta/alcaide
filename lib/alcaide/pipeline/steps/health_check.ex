defmodule Alcaide.Pipeline.Steps.HealthCheck do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Health check"

  @impl true
  def run(context) do
    %{conn: conn, config: config, next_slot: slot} = context

    case Alcaide.HealthCheck.check(conn, config, slot) do
      :ok -> {:ok, context}
      {:error, reason} -> {:error, reason}
    end
  end
end
