defmodule Alcaide.Pipeline.Steps.DestroyStaleJail do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Destroy stale jail from previous cycle"

  @impl true
  def run(context) do
    %{conn: conn, config: config} = context

    {:ok, output, _} = Alcaide.SSH.run(conn, "jls -q name 2>/dev/null || true")

    active_jails =
      output
      |> String.trim()
      |> String.split("\n", trim: true)

    Enum.each([:blue, :green], fn slot ->
      name = Alcaide.Jail.jail_name(config, slot)
      jail_path = "#{config.app_jail.base_path}/#{name}"

      # Destroy if directory exists on disk but jail is NOT running
      if name not in active_jails do
        case Alcaide.SSH.run(conn, "test -d #{jail_path} && echo exists || echo missing") do
          {:ok, result, 0} ->
            if String.trim(result) == "exists" do
              Alcaide.Output.info("Destroying stale jail #{name}...")
              Alcaide.Jail.destroy(conn, config, slot)
            end

          _ ->
            :ok
        end
      end
    end)

    {:ok, context}
  rescue
    e -> {:error, "Failed to clean stale jails: #{Exception.message(e)}"}
  end
end
