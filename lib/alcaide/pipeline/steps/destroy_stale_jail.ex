defmodule Alcaide.Pipeline.Steps.DestroyStaleJail do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Destroy stale jail from previous cycle"

  @impl true
  def run(context) do
    %{conn: conn, config: config} = context

    active_jails = Alcaide.Jail.list_active(conn)

    Enum.each([:blue, :green], fn slot ->
      name = Alcaide.Jail.jail_name(config, slot)

      # Destroy if directory exists on disk but jail is NOT running
      if name not in active_jails and Alcaide.Jail.jail_exists?(conn, config, slot) do
        Alcaide.Output.info("Destroying stale jail #{name}...")
        Alcaide.Jail.destroy(conn, config, slot)
      end
    end)

    {:ok, context}
  rescue
    e -> {:error, "Failed to clean stale jails: #{Exception.message(e)}"}
  end
end
