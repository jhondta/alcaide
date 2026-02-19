defmodule Alcaide.Accessories do
  @moduledoc """
  Manages accessory jails (databases, caches, etc.).

  Currently supports PostgreSQL running in a dedicated FreeBSD jail
  with data persisted via nullfs mount from the host.
  """

  alias Alcaide.{SSH, Config, Output}

  @db_ip "10.0.0.4"

  @doc """
  Returns the IP address for the database jail.
  """
  @spec db_ip() :: String.t()
  def db_ip, do: @db_ip

  @doc """
  Returns the jail name for the database accessory.

      iex> Alcaide.Accessories.db_jail_name(%Alcaide.Config{app: :my_app})
      "my_app_db"
  """
  @spec db_jail_name(Config.t()) :: String.t()
  def db_jail_name(config), do: "#{config.app}_db"

  @doc """
  Provisions the PostgreSQL accessory during `alcaide setup`.

  Creates the database jail, installs PostgreSQL, initializes the
  data cluster, configures network access, and creates the application
  database and user. All operations are idempotent.
  """
  @spec setup_postgresql(SSH.t(), Config.t(), Config.accessory()) :: :ok
  def setup_postgresql(conn, config, accessory) do
    name = db_jail_name(config)
    base_path = config.app_jail.base_path
    jail_path = "#{base_path}/#{name}"
    template_path = "#{base_path}/.templates/base"
    {host_volume, jail_volume} = parse_volume(accessory.volume)
    pg_version = accessory.version

    Output.step("Provisioning PostgreSQL accessory (#{name})")

    # 1. Create host data directory
    Output.info("Creating host data directory #{host_volume}...")
    SSH.run!(conn, "mkdir -p #{host_volume}")

    # 2. Clone base template (skip if jail already exists)
    Output.info("Creating database jail #{name}...")

    SSH.run!(conn, """
    if [ ! -d #{jail_path} ]; then
      cp -a #{template_path} #{jail_path}
      echo "Database jail created"
    else
      echo "Database jail already exists, skipping"
    fi
    """)

    # 3. Stop jail if running (so it picks up fresh resolv.conf on restart)
    SSH.run(conn, "umount #{jail_path}/dev 2>/dev/null || true")
    SSH.run(conn, "umount #{jail_path}#{jail_volume} 2>/dev/null || true")
    SSH.run(conn, "jail -r #{name} 2>/dev/null || true")

    # Always refresh resolv.conf so DNS works even on re-runs
    SSH.run!(conn, "cp /etc/resolv.conf #{jail_path}/etc/resolv.conf")

    # 4. Create the mount point inside the jail
    SSH.run!(conn, "mkdir -p #{jail_path}#{jail_volume}")

    # 5. Start jail with persist mode
    start_jail(conn, config, accessory)

    # 6. Install PostgreSQL inside the jail
    Output.info("Installing postgresql#{pg_version}-server in jail...")
    SSH.run!(conn, "jexec #{name} pkg install -y postgresql#{pg_version}-server postgresql#{pg_version}-contrib")

    # 7. Initialize database cluster (idempotent)
    data_dir = "#{jail_volume}/data#{pg_version}"

    Output.info("Initializing PostgreSQL database cluster...")

    SSH.run!(conn, """
    jexec #{name} /bin/sh -c '
      if [ ! -f #{data_dir}/PG_VERSION ]; then
        mkdir -p #{data_dir}
        chown postgres:postgres #{data_dir}
        su -m postgres -c "/usr/local/bin/initdb -D #{data_dir}"
        echo "Database cluster initialized"
      else
        echo "Database cluster already exists, skipping"
      fi
    '
    """)

    # 8. Configure PostgreSQL for network access
    configure_postgresql(conn, name, data_dir)

    # 9. Start PostgreSQL
    start_postgresql(conn, name, data_dir)

    # 10. Create application database and user
    create_app_db_and_user(conn, config, name, accessory)

    Output.success("PostgreSQL accessory provisioned successfully")
    :ok
  end

  @doc """
  Ensures the database jail and PostgreSQL are running.

  Called before each deploy. If the jail is already running, this is a no-op.
  """
  @spec ensure_running(SSH.t(), Config.t(), Config.accessory()) :: :ok
  def ensure_running(conn, config, accessory) do
    name = db_jail_name(config)

    {:ok, output, _} = SSH.run(conn, "jls -q name 2>/dev/null || true")

    active_jails =
      output
      |> String.trim()
      |> String.split("\n", trim: true)

    if name in active_jails do
      Output.info("Database jail #{name} already running")
      :ok
    else
      Output.info("Database jail #{name} not running, starting...")
      {_host_volume, jail_volume} = parse_volume(accessory.volume)
      data_dir = "#{jail_volume}/data#{accessory.version}"

      start_jail(conn, config, accessory)
      start_postgresql(conn, name, data_dir)
      :ok
    end
  end

  # --- Private functions ---

  defp start_jail(conn, config, accessory) do
    name = db_jail_name(config)
    base_path = config.app_jail.base_path
    jail_path = "#{base_path}/#{name}"
    {host_volume, jail_volume} = parse_volume(accessory.volume)

    Output.info("Starting database jail #{name} with IP #{@db_ip}...")

    # Start the jail (skip if already running)
    SSH.run!(conn, """
    if ! jls -q name 2>/dev/null | grep -q '^#{name}$'; then
      jail -c name=#{name} \
        path=#{jail_path} \
        ip4.addr="lo1|#{@db_ip}/32" \
        host.hostname=#{name} \
        allow.raw_sockets \
        allow.sysvipc \
        persist
      echo "Jail started"
    else
      echo "Jail already running"
    fi
    """)

    # Mount devfs so the jail has /dev/null, /dev/random, etc.
    SSH.run!(conn, """
    if ! mount | grep -q '#{jail_path}/dev'; then
      mount -t devfs devfs #{jail_path}/dev
      echo "devfs mounted"
    else
      echo "devfs already mounted"
    fi
    """)

    # Mount host volume via nullfs (idempotent)
    Output.info("Mounting #{host_volume} -> #{jail_path}#{jail_volume} via nullfs...")

    SSH.run!(conn, """
    if ! mount | grep -q '#{jail_path}#{jail_volume}'; then
      mount_nullfs #{host_volume} #{jail_path}#{jail_volume}
      echo "Volume mounted"
    else
      echo "Volume already mounted"
    fi
    """)

    Output.success("Database jail #{name} started")
  end

  defp configure_postgresql(conn, jail_name, data_dir) do
    Output.info("Configuring PostgreSQL to listen on #{@db_ip}...")

    # Set listen_addresses in postgresql.conf
    SSH.run!(conn, """
    jexec #{jail_name} /bin/sh -c '
      if grep -q "^listen_addresses" #{data_dir}/postgresql.conf; then
        echo "listen_addresses already configured"
      else
        sed -i "" "s/#listen_addresses = .*/listen_addresses = \\x27*\\x27/" #{data_dir}/postgresql.conf
        echo "listen_addresses set to *"
      fi
    '
    """)

    # Configure pg_hba.conf for jail network access
    SSH.run!(conn, """
    jexec #{jail_name} /bin/sh -c '
      if ! grep -q "10.0.0.0/24" #{data_dir}/pg_hba.conf; then
        echo "host all all 10.0.0.0/24 md5" >> #{data_dir}/pg_hba.conf
        echo "pg_hba.conf updated for jail network access"
      else
        echo "pg_hba.conf already configured"
      fi
    '
    """)
  end

  defp start_postgresql(conn, jail_name, data_dir) do
    Output.info("Starting PostgreSQL...")

    SSH.run!(conn, """
    jexec #{jail_name} /bin/sh -c '
      if su -m postgres -c "/usr/local/bin/pg_ctl -D #{data_dir} status" >/dev/null 2>&1; then
        echo "PostgreSQL already running"
      else
        su -m postgres -c "/usr/local/bin/pg_ctl -D #{data_dir} -l #{data_dir}/postgresql.log start"
        sleep 2
        echo "PostgreSQL started"
      fi
    '
    """)

    Output.success("PostgreSQL running")
  end

  defp create_app_db_and_user(conn, config, jail_name, accessory) do
    app = Atom.to_string(config.app)
    db_name = accessory.database || "#{app}_prod"
    db_user = accessory.user || "app"
    db_password = accessory.password || "app"

    Output.info("Creating database user '#{db_user}' and database '#{db_name}'...")

    # Create user (idempotent)
    SSH.run!(
      conn,
      "jexec #{jail_name} su -m postgres -c 'createuser #{db_user} 2>/dev/null || true'"
    )

    # Set password
    SSH.run!(
      conn,
      "jexec #{jail_name} su -m postgres -c " <>
        "\"psql -c \\\"ALTER ROLE #{db_user} WITH PASSWORD '#{db_password}';\\\"\""
    )

    # Create database (idempotent)
    SSH.run!(
      conn,
      "jexec #{jail_name} su -m postgres -c 'createdb -O #{db_user} #{db_name} 2>/dev/null || true'"
    )

    Output.success("Database #{db_name} ready")
  end

  defp parse_volume(volume_string) do
    case String.split(volume_string, ":", parts: 2) do
      [host_path, jail_path] -> {host_path, jail_path}
      _ -> raise "Invalid volume format: #{volume_string}. Expected 'host_path:jail_path'"
    end
  end
end
