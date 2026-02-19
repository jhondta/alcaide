defmodule Alcaide.Pipeline.Steps.UploadRelease do
  @moduledoc false
  use Alcaide.Pipeline.Step

  @impl true
  def name, do: "Upload release"

  @impl true
  def run(context) do
    %{conn: conn, tarball_path: tarball_path, config: config} = context

    case Alcaide.Upload.upload(conn, tarball_path, config) do
      {:ok, remote_path} ->
        {:ok, Map.put(context, :remote_tarball_path, remote_path)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def rollback(context) do
    if path = context[:remote_tarball_path] do
      Alcaide.SSH.run(context.conn, "rm -f #{path}")
    end

    :ok
  end
end
