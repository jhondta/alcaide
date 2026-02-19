defmodule Alcaide.Release do
  @moduledoc """
  Builds a Phoenix release locally and creates a tarball for deployment.
  """

  alias Alcaide.Output

  @doc """
  Builds the release and creates a tarball.

  Runs `MIX_ENV=prod mix release --overwrite` in the current directory,
  then creates a `.tar.gz` of the release directory.

  Returns `{:ok, tarball_path}` on success.
  """
  @spec build(Alcaide.Config.t()) :: {:ok, String.t()} | {:error, String.t()}
  def build(config) do
    app = Atom.to_string(config.app)

    Output.info("Building release for #{app}...")

    # Build and digest static assets (CSS, JS) before creating the release.
    # This is a no-op if the project has no assets.deploy alias defined.
    case System.cmd("mix", ["assets.deploy"],
           env: [{"MIX_ENV", "prod"}],
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_, 0} -> Output.success("Assets built")
      {_, _} -> Output.info("No assets.deploy task found, skipping")
    end

    case System.cmd("mix", ["release", "--overwrite"],
           env: [{"MIX_ENV", "prod"}],
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_, 0} ->
        create_tarball(app)

      {_, exit_code} ->
        {:error,
         "mix release failed with exit code #{exit_code}. " <>
           "Check that `MIX_ENV=prod mix release` works locally."}
    end
  end

  defp create_tarball(app) do
    release_dir = Path.join(["_build", "prod", "rel", app])

    unless File.dir?(release_dir) do
      {:error, "Release directory not found at #{release_dir}"}
    else
      tarball_path = Path.join(["_build", "prod", "#{app}.tar.gz"])

      Output.info("Creating tarball at #{tarball_path}...")

      case System.cmd("tar", ["-czf", tarball_path, "-C", release_dir, "."]) do
        {_, 0} ->
          size_mb = File.stat!(tarball_path).size / 1_048_576
          Output.success("Tarball created (#{:erlang.float_to_binary(size_mb, decimals: 1)} MB)")
          {:ok, tarball_path}

        {output, exit_code} ->
          {:error, "tar failed (exit #{exit_code}): #{output}"}
      end
    end
  end
end
