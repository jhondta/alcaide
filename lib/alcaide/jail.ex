defmodule Alcaide.Jail do
  @moduledoc """
  Manages FreeBSD jail lifecycle including blue/green slot rotation.

  Each application has two jail slots (blue and green). Deployments
  alternate between them, ensuring zero-downtime rotation.
  """

  alias Alcaide.{SSH, Output}

  @type slot :: :blue | :green

  @slot_ips %{blue: "10.0.0.2", green: "10.0.0.3"}

  @doc """
  Returns the jail name for the given config and slot.

      iex> Alcaide.Jail.jail_name(%Alcaide.Config{app: :my_app}, :blue)
      "my_app_blue"
  """
  @spec jail_name(Alcaide.Config.t(), slot()) :: String.t()
  def jail_name(config, slot) do
    "#{config.app}_#{slot}"
  end

  @doc """
  Returns the internal IP address for a slot.

      iex> Alcaide.Jail.slot_ip(:blue)
      "10.0.0.2"

      iex> Alcaide.Jail.slot_ip(:green)
      "10.0.0.3"
  """
  @spec slot_ip(slot()) :: String.t()
  def slot_ip(slot), do: Map.fetch!(@slot_ips, slot)

  @doc """
  Determines the next deployment slot based on currently running jails.

  Returns `{:ok, next_slot, current_slot_or_nil}`.

  - If no jails exist: `{:ok, :blue, nil}` (first deploy)
  - If blue is running: `{:ok, :green, :blue}`
  - If green is running: `{:ok, :blue, :green}`
  """
  @spec determine_next_slot(SSH.t(), Alcaide.Config.t()) ::
          {:ok, slot(), slot() | nil}
  def determine_next_slot(conn, config) do
    {:ok, output, _} = SSH.run(conn, "jls -q name 2>/dev/null || true")

    active_jails =
      output
      |> String.trim()
      |> String.split("\n", trim: true)

    app = Atom.to_string(config.app)
    blue_name = "#{app}_blue"
    green_name = "#{app}_green"

    blue_active = blue_name in active_jails
    green_active = green_name in active_jails

    cond do
      !blue_active and !green_active ->
        Output.info("No active jails found. First deployment will use blue slot.")
        {:ok, :blue, nil}

      blue_active and !green_active ->
        Output.info("Blue slot active. Next deployment will use green slot.")
        {:ok, :green, :blue}

      !blue_active and green_active ->
        Output.info("Green slot active. Next deployment will use blue slot.")
        {:ok, :blue, :green}

      blue_active and green_active ->
        Output.info("Both slots active (anomaly). Will replace blue slot.")
        {:ok, :blue, :green}
    end
  end

  @doc """
  Creates a new jail by cloning the base template.
  """
  @spec create(SSH.t(), Alcaide.Config.t(), slot()) :: :ok | {:error, String.t()}
  def create(conn, config, slot) do
    name = jail_name(config, slot)
    base_path = config.app_jail.base_path
    jail_path = "#{base_path}/#{name}"
    template_path = "#{base_path}/.templates/base"

    Output.info("Creating jail #{name}...")

    SSH.run!(conn, "cp -a #{template_path} #{jail_path}")
    SSH.run!(conn, "mkdir -p #{jail_path}/app")
    SSH.run!(conn, "cp /etc/resolv.conf #{jail_path}/etc/resolv.conf")

    Output.success("Jail #{name} created")
    :ok
  rescue
    e -> {:error, "Failed to create jail: #{Exception.message(e)}"}
  end

  @doc """
  Starts a jail with the given slot's IP address.
  """
  @spec start(SSH.t(), Alcaide.Config.t(), slot()) :: :ok | {:error, String.t()}
  def start(conn, config, slot) do
    name = jail_name(config, slot)
    ip = slot_ip(slot)
    path = "#{config.app_jail.base_path}/#{name}"

    Output.info("Starting jail #{name} with IP #{ip}...")

    SSH.run!(conn, """
    jail -c name=#{name} \
      path=#{path} \
      ip4.addr="lo1|#{ip}/32" \
      host.hostname=#{name} \
      allow.raw_sockets \
      persist
    """)

    Output.success("Jail #{name} started")
    :ok
  rescue
    e -> {:error, "Failed to start jail: #{Exception.message(e)}"}
  end

  @doc """
  Extracts the uploaded release tarball into the jail's `/app` directory.
  """
  @spec install_release(SSH.t(), Alcaide.Config.t(), slot(), String.t()) ::
          :ok | {:error, String.t()}
  def install_release(conn, config, slot, remote_tarball) do
    name = jail_name(config, slot)
    app_dir = "#{config.app_jail.base_path}/#{name}/app"

    Output.info("Installing release in jail #{name}...")

    SSH.run!(conn, "tar -xzf #{remote_tarball} -C #{app_dir}")

    Output.success("Release installed in #{name}")
    :ok
  rescue
    e -> {:error, "Failed to install release: #{Exception.message(e)}"}
  end

  @doc """
  Starts the Phoenix application inside the jail.

  Environment variables from the config are injected into the process.
  """
  @spec start_app(SSH.t(), Alcaide.Config.t(), slot()) :: :ok | {:error, String.t()}
  def start_app(conn, config, slot) do
    name = jail_name(config, slot)
    app_name = Atom.to_string(config.app)

    Output.info("Starting application in jail #{name}...")

    env_str =
      config.env
      |> Enum.map(fn {key, value} ->
        "#{key}=#{shell_escape(value)}"
      end)
      |> Enum.join(" ")

    cmd =
      if env_str == "" do
        "jexec #{name} /bin/sh -c 'cd /app && bin/#{app_name} daemon'"
      else
        "jexec #{name} /bin/sh -c 'cd /app && #{env_str} bin/#{app_name} daemon'"
      end

    SSH.run!(conn, cmd)

    Output.success("Application started in #{name}")
    :ok
  rescue
    e -> {:error, "Failed to start application: #{Exception.message(e)}"}
  end

  @doc """
  Stops a running jail.
  """
  @spec stop(SSH.t(), Alcaide.Config.t(), slot()) :: :ok
  def stop(conn, config, slot) do
    name = jail_name(config, slot)
    Output.info("Stopping jail #{name}...")
    SSH.run(conn, "jail -r #{name} 2>/dev/null || true")
    :ok
  end

  @doc """
  Destroys a jail: stops it and removes its directory.
  """
  @spec destroy(SSH.t(), Alcaide.Config.t(), slot()) :: :ok
  def destroy(conn, config, slot) do
    name = jail_name(config, slot)
    jail_path = "#{config.app_jail.base_path}/#{name}"

    Output.info("Destroying jail #{name}...")
    SSH.run(conn, "jail -r #{name} 2>/dev/null || true")
    SSH.run!(conn, "rm -rf #{jail_path}")
    Output.success("Jail #{name} destroyed")
    :ok
  end

  # Escapes a value for safe use in shell commands using single quotes.
  defp shell_escape(value) do
    escaped = String.replace(to_string(value), "'", "'\\''")
    "'#{escaped}'"
  end
end
