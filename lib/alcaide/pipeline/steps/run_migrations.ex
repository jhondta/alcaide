defmodule Alcaide.Pipeline.Steps.RunMigrations do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Run database migrations"

  @impl true
  def run(context) do
    %{config: config} = context

    case Alcaide.Config.postgresql_accessory(config) do
      nil ->
        Alcaide.Output.info("No database configured, skipping migrations")
        {:ok, context}

      _accessory ->
        %{conn: conn, next_slot: slot} = context

        case Alcaide.Migrations.run(conn, config, slot) do
          :ok -> {:ok, context}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
