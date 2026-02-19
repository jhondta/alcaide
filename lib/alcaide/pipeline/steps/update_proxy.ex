defmodule Alcaide.Pipeline.Steps.UpdateProxy do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Update reverse proxy"

  @impl true
  def run(context) do
    %{conn: conn, config: config, next_slot: slot} = context

    {:ok, previous_caddyfile} = Alcaide.Proxy.read_caddyfile(conn)

    new_caddyfile = Alcaide.Proxy.generate_caddyfile(config, slot)
    Alcaide.Proxy.write_and_reload!(conn, new_caddyfile)

    {:ok, Map.put(context, :previous_caddyfile, previous_caddyfile)}
  rescue
    e -> {:error, "Failed to update proxy: #{Exception.message(e)}"}
  end

  @impl true
  def rollback(context) do
    case context[:previous_caddyfile] do
      nil -> :ok
      previous -> Alcaide.Proxy.restore!(context.conn, previous)
    end

    :ok
  rescue
    _ -> :ok
  end
end
