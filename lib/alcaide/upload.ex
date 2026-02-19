defmodule Alcaide.Upload do
  @moduledoc """
  Uploads the release tarball to the remote server via SFTP.
  """

  alias Alcaide.{SSH, Output}

  @doc """
  Uploads the local tarball to a staging directory on the server.

  Creates `{base_path}/.releases/` if it doesn't exist, then uploads
  the tarball with a timestamped name.

  Returns `{:ok, remote_path}` on success.
  """
  @spec upload(SSH.t(), String.t(), Alcaide.Config.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def upload(conn, local_tarball_path, config) do
    app = Atom.to_string(config.app)
    base_path = config.app_jail.base_path
    releases_dir = "#{base_path}/.releases"
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
    remote_filename = "#{app}-#{timestamp}.tar.gz"
    remote_path = "#{releases_dir}/#{remote_filename}"

    Output.info("Uploading release to #{remote_path}...")

    case SSH.run(conn, "mkdir -p #{releases_dir}") do
      {:ok, _, 0} ->
        SSH.upload!(conn, local_tarball_path, remote_path)
        Output.success("Release uploaded")
        {:ok, remote_path}

      {:ok, output, exit_code} ->
        {:error, "Failed to create releases directory (exit #{exit_code}): #{output}"}
    end
  end
end
