defmodule Alcaide.Config do
  @moduledoc """
  Loads and validates the `deploy.exs` configuration file.
  """

  @type accessory :: %{
          name: atom(),
          type: atom(),
          version: String.t(),
          volume: String.t(),
          port: non_neg_integer()
        }

  @type t :: %__MODULE__{
          app: atom(),
          server: %{host: String.t(), user: String.t(), port: non_neg_integer()},
          domain: String.t() | nil,
          app_jail: %{
            base_path: String.t(),
            freebsd_version: String.t(),
            port: non_neg_integer()
          },
          accessories: [accessory()],
          env: keyword()
        }

  defstruct [:app, :server, :domain, :app_jail, accessories: [], env: []]

  @doc """
  Loads and validates the configuration from the given file path.

  Returns `{:ok, config}` on success or `{:error, message}` on failure.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, raw} <- read_config(path),
         {:ok, alcaide_config} <- extract_alcaide_key(raw),
         {:ok, config} <- build_config(alcaide_config) do
      {:ok, config}
    end
  end

  @doc """
  Same as `load/1` but raises on error.
  """
  @spec load!(String.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, config} -> config
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp read_config(path) do
    if File.exists?(path) do
      {:ok, Config.Reader.read!(path)}
    else
      {:error, "Configuration file not found: #{path}"}
    end
  rescue
    e -> {:error, "Failed to read configuration file: #{Exception.message(e)}"}
  end

  defp extract_alcaide_key(raw) do
    case Keyword.get(raw, :alcaide) do
      nil -> {:error, "No :alcaide configuration found in deploy.exs"}
      config -> {:ok, config}
    end
  end

  defp build_config(raw) do
    with {:ok, app} <- require_key(raw, :app),
         {:ok, server} <- build_server(raw),
         {:ok, app_jail} <- build_app_jail(raw),
         {:ok, accessories} <- build_accessories(raw) do
      {:ok,
       %__MODULE__{
         app: app,
         server: server,
         domain: Keyword.get(raw, :domain),
         app_jail: app_jail,
         accessories: accessories,
         env: Keyword.get(raw, :env, [])
       }}
    end
  end

  defp build_server(raw) do
    case Keyword.get(raw, :server) do
      nil ->
        {:error, "Missing required key :server in deploy.exs"}

      server_opts ->
        with {:ok, host} <- require_nested_key(server_opts, :host, :server) do
          {:ok,
           %{
             host: host,
             user: Keyword.get(server_opts, :user, "root"),
             port: Keyword.get(server_opts, :port, 22)
           }}
        end
    end
  end

  defp build_app_jail(raw) do
    case Keyword.get(raw, :app_jail) do
      nil ->
        {:error, "Missing required key :app_jail in deploy.exs"}

      jail_opts ->
        with {:ok, base_path} <- require_nested_key(jail_opts, :base_path, :app_jail),
             {:ok, version} <- require_nested_key(jail_opts, :freebsd_version, :app_jail) do
          {:ok,
           %{
             base_path: base_path,
             freebsd_version: version,
             port: Keyword.get(jail_opts, :port, 4000)
           }}
        end
    end
  end

  @doc """
  Returns the first accessory of type `:postgresql`, or `nil`.
  """
  @spec postgresql_accessory(t()) :: accessory() | nil
  def postgresql_accessory(%__MODULE__{accessories: accessories}) do
    Enum.find(accessories, &(&1.type == :postgresql))
  end

  defp build_accessories(raw) do
    case Keyword.get(raw, :accessories) do
      nil ->
        {:ok, []}

      accessories when is_list(accessories) ->
        accessories
        |> Enum.reduce_while({:ok, []}, fn {name, opts}, {:ok, acc} ->
          case build_accessory(name, opts) do
            {:ok, accessory} -> {:cont, {:ok, [accessory | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          error -> error
        end
    end
  end

  defp build_accessory(name, opts) do
    with {:ok, type} <- require_nested_key(opts, :type, "accessories.#{name}"),
         {:ok, version} <- require_nested_key(opts, :version, "accessories.#{name}"),
         {:ok, volume} <- require_nested_key(opts, :volume, "accessories.#{name}") do
      {:ok,
       %{
         name: name,
         type: type,
         version: version,
         volume: volume,
         port: Keyword.get(opts, :port, 5432)
       }}
    end
  end

  defp require_key(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, "Missing required key :#{key} in deploy.exs"}
      value -> {:ok, value}
    end
  end

  defp require_nested_key(opts, key, parent) do
    case Keyword.get(opts, key) do
      nil -> {:error, "Missing required key :#{key} in :#{parent} configuration"}
      value -> {:ok, value}
    end
  end
end
