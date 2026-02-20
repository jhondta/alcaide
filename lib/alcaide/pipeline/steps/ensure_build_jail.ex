defmodule Alcaide.Pipeline.Steps.EnsureBuildJail do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Ensure build jail is running"

  @impl true
  def run(context) do
    %{conn: conn, config: config} = context

    Alcaide.BuildJail.ensure_running(conn, config)
    {:ok, context}
  rescue
    e -> {:error, "Build jail check failed: #{Exception.message(e)}"}
  end
end
