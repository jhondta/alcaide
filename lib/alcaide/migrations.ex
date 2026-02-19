defmodule Alcaide.Migrations do
  @moduledoc """
  Runs Ecto migrations from within a deployed application jail.

  Requires the Phoenix project to have a `MyApp.Release.migrate/0` function,
  which is the standard convention from the Phoenix deployment guide.
  """

  alias Alcaide.{SSH, Jail, Config, Output}

  @doc """
  Runs Ecto migrations in the given jail slot.

  Executes the app's `Release.migrate/0` function via `jexec ... eval`.
  Environment variables from config are injected into the process.
  """
  @spec run(SSH.t(), Config.t(), Jail.slot()) :: :ok | {:error, String.t()}
  def run(conn, config, slot) do
    name = Jail.jail_name(config, slot)
    app_name = Atom.to_string(config.app)
    module_name = app_module_name(config.app)

    Output.info("Running migrations in jail #{name}...")

    env_str = build_env_string(config)

    cmd =
      if env_str == "" do
        "jexec #{name} /bin/sh -c 'cd /app && bin/#{app_name} eval \"#{module_name}.Release.migrate()\"'"
      else
        "jexec #{name} /bin/sh -c 'cd /app && #{env_str} bin/#{app_name} eval \"#{module_name}.Release.migrate()\"'"
      end

    SSH.run!(conn, cmd)

    Output.success("Migrations completed successfully")
    :ok
  rescue
    e -> {:error, "Migration failed: #{Exception.message(e)}"}
  end

  @doc """
  Converts an app atom to its module name (CamelCase).

  ## Examples

      iex> Alcaide.Migrations.app_module_name(:my_app)
      "MyApp"

      iex> Alcaide.Migrations.app_module_name(:blog)
      "Blog"

      iex> Alcaide.Migrations.app_module_name(:phoenix_live_blog)
      "PhoenixLiveBlog"
  """
  @spec app_module_name(atom()) :: String.t()
  def app_module_name(app) when is_atom(app) do
    app
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  defp build_env_string(config) do
    config.env
    |> Enum.map(fn {key, value} ->
      "#{key}=#{shell_escape(value)}"
    end)
    |> Enum.join(" ")
  end

  defp shell_escape(value) do
    escaped = String.replace(to_string(value), "'", "'\\''")
    "'#{escaped}'"
  end
end
