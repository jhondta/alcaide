defmodule Alcaide.Pipeline.Steps.BuildRelease do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Build release"

  @impl true
  def run(context) do
    case Alcaide.Release.build(context.config) do
      {:ok, tarball_path} ->
        {:ok, Map.put(context, :tarball_path, tarball_path)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
