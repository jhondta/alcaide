defmodule Alcaide.Pipeline.Steps.RemoteBuild do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Build release in build jail"

  @impl true
  def run(context) do
    %{conn: conn, config: config} = context

    case Alcaide.BuildJail.build_release(conn, config) do
      {:ok, release_path} ->
        {:ok, Map.put(context, :release_tarball_path, release_path)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
