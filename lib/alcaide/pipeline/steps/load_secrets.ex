defmodule Alcaide.Pipeline.Steps.LoadSecrets do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Load secrets"

  @impl true
  def run(context) do
    %{config: config} = context

    case Alcaide.Secrets.load_and_merge_env(config) do
      {:ok, merged_config} ->
        Alcaide.Output.success("Secrets loaded and merged")
        {:ok, %{context | config: merged_config}}

      {:skip, _config} ->
        Alcaide.Output.info("No secrets configured, skipping")
        {:ok, context}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
