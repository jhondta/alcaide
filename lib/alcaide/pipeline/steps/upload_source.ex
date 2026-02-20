defmodule Alcaide.Pipeline.Steps.UploadSource do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Upload source code"

  @impl true
  def run(context) do
    %{conn: conn, config: config} = context

    case Alcaide.BuildJail.upload_source(conn, config) do
      :ok -> {:ok, context}
      {:error, reason} -> {:error, reason}
    end
  end
end
