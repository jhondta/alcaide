defmodule Alcaide.CLI do
  @moduledoc """
  Command-line interface for Alcaide.

  Parses arguments and dispatches to the appropriate command.
  """

  alias Alcaide.{Config, SSH, Output, Pipeline, Jail, Proxy, Secrets, HealthCheck}

  @deploy_steps [
    Pipeline.Steps.DestroyStaleJail,
    Pipeline.Steps.BuildRelease,
    Pipeline.Steps.UploadRelease,
    Pipeline.Steps.DetermineSlot,
    Pipeline.Steps.LoadSecrets,
    Pipeline.Steps.CreateJail,
    Pipeline.Steps.InstallRelease,
    Pipeline.Steps.StartJail,
    Pipeline.Steps.RunMigrations,
    Pipeline.Steps.HealthCheck,
    Pipeline.Steps.UpdateProxy,
    Pipeline.Steps.CleanupOldJail
  ]

  @doc """
  Entry point for CLI invocation.
  """
  @spec main([String.t()]) :: :ok
  def main(args) do
    {opts, commands, _invalid} =
      OptionParser.parse(args,
        strict: [config: :string, verbose: :boolean],
        aliases: [c: :config, v: :verbose]
      )

    config_path = Keyword.get(opts, :config, "deploy.exs")

    case commands do
      ["deploy"] -> deploy(config_path)
      ["setup"] -> setup(config_path)
      ["rollback"] -> rollback(config_path)
      ["secrets", "init"] -> secrets_init()
      ["secrets", "edit"] -> secrets_edit()
      _ -> usage()
    end
  end

  defp deploy(config_path) do
    config = Config.load!(config_path)
    {:ok, conn} = SSH.connect(config.server)

    Output.step("Deploying #{config.app}")

    ensure_accessories_running(conn, config)

    context = %{config: config, conn: conn}

    case Pipeline.run(@deploy_steps, context) do
      {:ok, _ctx} ->
        Output.success("Deploy complete!")
        SSH.disconnect(conn)

      {:error, reason, _ctx} ->
        Output.error("Deploy failed: #{reason}")
        SSH.disconnect(conn)
        System.halt(1)
    end
  end

  defp setup(config_path) do
    config = Config.load!(config_path)
    {:ok, conn} = SSH.connect(config.server)

    Output.step("Setting up server #{config.server.host}")

    run_setup(conn, config)

    Output.success("Server setup complete!")
    SSH.disconnect(conn)
  rescue
    e ->
      Output.error("Setup failed: #{Exception.message(e)}")
      System.halt(1)
  end

  defp rollback(config_path) do
    config = Config.load!(config_path)
    {:ok, conn} = SSH.connect(config.server)

    Output.step("Rolling back #{config.app}")

    run_rollback(conn, config)

    SSH.disconnect(conn)
  rescue
    e ->
      Output.error("Rollback failed: #{Exception.message(e)}")
      System.halt(1)
  end

  defp run_rollback(conn, config) do
    # 1. Find currently active jail
    current = Jail.current_slot(conn, config)

    unless current do
      raise "No active jail found. Nothing to roll back to."
    end

    # 2. Determine the other slot
    target = Jail.other_slot(current)

    # 3. Verify the target jail exists on disk
    unless Jail.jail_exists?(conn, config, target) do
      raise "Previous jail (#{Jail.jail_name(config, target)}) does not exist. " <>
              "Rollback is only possible if the previous jail was preserved."
    end

    Output.info(
      "Rolling back from #{Jail.jail_name(config, current)} " <>
        "to #{Jail.jail_name(config, target)}"
    )

    # 4. Load secrets if configured (merge env vars)
    config = load_secrets_for_rollback(config)

    # 5. Start the target jail and application
    Output.info("Starting target jail...")
    :ok = Jail.start(conn, config, target)
    :ok = Jail.start_app(conn, config, target)

    # 6. Health check
    Output.info("Running health check...")
    :ok = HealthCheck.check(conn, config, target)

    # 7. Update proxy
    Output.info("Updating reverse proxy...")
    new_caddyfile = Proxy.generate_caddyfile(config, target)
    Proxy.write_and_reload!(conn, new_caddyfile)

    # 8. Stop the previously active jail
    Output.info("Stopping previous jail...")
    Jail.stop(conn, config, current)

    Output.success("Rollback complete! #{Jail.jail_name(config, target)} is now active.")
  end

  defp load_secrets_for_rollback(config) do
    case Secrets.load_and_merge_env(config) do
      {:ok, merged_config} -> merged_config
      {:skip, config} -> config
      {:error, reason} -> raise reason
    end
  end

  defp secrets_init do
    Secrets.init!()
  rescue
    e ->
      Output.error("Secrets init failed: #{Exception.message(e)}")
      System.halt(1)
  end

  defp secrets_edit do
    Secrets.edit!()
  rescue
    e ->
      Output.error("Secrets edit failed: #{Exception.message(e)}")
      System.halt(1)
  end

  defp run_setup(conn, config) do
    # 1. Verify FreeBSD
    Output.info("Verifying server is running FreeBSD...")
    {:ok, os_output, _} = SSH.run(conn, "uname -s")

    unless String.trim(os_output) == "FreeBSD" do
      raise "Server is not running FreeBSD (got: #{String.trim(os_output)})"
    end

    # 2. Auto-detect architecture
    Output.info("Detecting architecture...")
    {:ok, arch_output, _} = SSH.run(conn, "uname -m")
    arch = String.trim(arch_output)
    Output.info("Architecture: #{arch}")

    # 3. Enable jail subsystem
    Output.info("Enabling jail subsystem...")

    SSH.run!(conn, """
    sysrc jail_enable=YES
    sysrc cloned_interfaces+=lo1
    sysrc ifconfig_lo1_alias0="inet 10.0.0.1/24"
    """)

    # 4. Create lo1 interface
    Output.info("Configuring loopback interface lo1...")
    SSH.run!(conn, "ifconfig lo1 create 2>/dev/null || true")
    SSH.run!(conn, "ifconfig lo1 alias 10.0.0.1/24 2>/dev/null || true")

    # 5. Create directory structure
    base_path = config.app_jail.base_path
    Output.info("Creating directory structure at #{base_path}...")
    SSH.run!(conn, "mkdir -p #{base_path}/.templates #{base_path}/.releases")

    # 6. Download and extract base system template
    version = config.app_jail.freebsd_version
    url = "https://download.freebsd.org/releases/#{arch}/#{version}/base.txz"

    Output.info("Downloading FreeBSD #{version} base system (#{arch})...")

    SSH.run!(conn, """
    if [ ! -d #{base_path}/.templates/base/bin ]; then
      fetch #{url} -o #{base_path}/.templates/base.txz
      mkdir -p #{base_path}/.templates/base
      tar -xf #{base_path}/.templates/base.txz -C #{base_path}/.templates/base
      rm #{base_path}/.templates/base.txz
      echo "Base template downloaded and extracted"
    else
      echo "Base template already exists, skipping download"
    fi
    """)

    # 7. Install and configure Caddy reverse proxy
    Output.info("Installing Caddy reverse proxy...")
    SSH.run!(conn, "pkg install -y caddy")

    Output.info("Writing initial Caddyfile...")
    initial_caddyfile = Proxy.generate_caddyfile(config, :blue)
    Proxy.write_and_reload!(conn, initial_caddyfile)

    Output.info("Enabling Caddy service...")
    SSH.run!(conn, "sysrc caddy_enable=YES")
    SSH.run!(conn, "service caddy start 2>/dev/null || service caddy reload")

    # 8. Provision accessories (database, etc.)
    provision_accessories(conn, config)
  end

  defp ensure_accessories_running(conn, config) do
    case Config.postgresql_accessory(config) do
      nil -> :ok
      accessory -> Alcaide.Accessories.ensure_running(conn, config, accessory)
    end
  end

  defp provision_accessories(conn, config) do
    case Config.postgresql_accessory(config) do
      nil -> Output.info("No accessories configured, skipping")
      accessory -> Alcaide.Accessories.setup_postgresql(conn, config, accessory)
    end
  end

  defp usage do
    IO.puts("""
    Alcaide - Deploy Phoenix apps to FreeBSD with Jails

    Usage:
      alcaide setup  [options]    Prepare the server for deployments
      alcaide deploy [options]    Deploy the application
      alcaide rollback [options]  Roll back to the previous deployment

      alcaide secrets init        Generate master key and encrypted secrets file
      alcaide secrets edit        Edit secrets in $EDITOR and re-encrypt

    Options:
      -c, --config PATH    Path to config file (default: deploy.exs)
      -v, --verbose        Verbose output
    """)
  end
end
