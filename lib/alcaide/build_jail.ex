defmodule Alcaide.BuildJail do
  @moduledoc """
  Manages the persistent build jail for compiling Phoenix releases
  natively on FreeBSD.

  The build jail is created during `alcaide setup` and persists between
  deploys, caching `deps/` and `_build/` for fast incremental builds.
  """

  alias Alcaide.{SSH, Config, Output}

  @build_ip "10.0.0.5"

  @doc """
  Returns the IP address for the build jail.
  """
  @spec build_ip() :: String.t()
  def build_ip, do: @build_ip

  @doc """
  Returns the jail name for the build jail.

      iex> Alcaide.BuildJail.build_jail_name(%Alcaide.Config{app: :my_app})
      "my_app_build"
  """
  @spec build_jail_name(Config.t()) :: String.t()
  def build_jail_name(config), do: "#{config.app}_build"

  @doc """
  Provisions the build jail during `alcaide setup`.

  Creates the jail, installs Elixir, Erlang, Node.js, and configures
  hex/rebar. All operations are idempotent.
  """
  @spec setup(SSH.t(), Config.t()) :: :ok
  def setup(conn, config) do
    name = build_jail_name(config)
    base_path = config.app_jail.base_path
    jail_path = "#{base_path}/#{name}"
    template_path = "#{base_path}/.templates/base"

    Output.step("Provisioning build jail (#{name})")

    # 1. Clone base template (idempotent)
    Output.info("Creating build jail #{name}...")

    SSH.run!(conn, """
    if [ ! -d #{jail_path} ]; then
      cp -a #{template_path} #{jail_path}
      echo "Build jail created"
    else
      echo "Build jail already exists, skipping"
    fi
    """)

    # 2. Stop jail if running (so it picks up fresh resolv.conf on restart)
    SSH.run(conn, "umount #{jail_path}/compat/linux/sys 2>/dev/null || true")
    SSH.run(conn, "umount #{jail_path}/compat/linux/proc 2>/dev/null || true")
    SSH.run(conn, "umount #{jail_path}/dev 2>/dev/null || true")
    SSH.run(conn, "jail -r #{name} 2>/dev/null || true")

    # Always refresh resolv.conf so DNS works even on re-runs
    SSH.run!(conn, "cp /etc/resolv.conf #{jail_path}/etc/resolv.conf")

    # 3. Start jail with persist mode
    start_jail(conn, config)

    # 4. Install build tools
    Output.info("Installing Elixir, Erlang, Node.js, and git in build jail...")
    SSH.run!(conn, "jexec #{name} pkg install -y elixir node24 npm-node24 git",
      timeout: 300_000
    )

    # 5. Install hex and rebar
    Output.info("Installing hex and rebar...")
    SSH.run!(conn, "jexec #{name} mix local.hex --force", timeout: 60_000)
    SSH.run!(conn, "jexec #{name} mix local.rebar --force", timeout: 60_000)

    # 6. Create build directories
    SSH.run!(conn, "jexec #{name} mkdir -p /build/src /build/out")

    Output.success("Build jail #{name} provisioned successfully")
    :ok
  end

  @doc """
  Ensures the build jail is running before a deploy.

  If the jail is already running, this is a no-op. If the jail
  directory exists but the jail is not running, it starts it.
  Raises if the build jail does not exist.
  """
  @spec ensure_running(SSH.t(), Config.t()) :: :ok
  def ensure_running(conn, config) do
    name = build_jail_name(config)
    jail_path = "#{config.app_jail.base_path}/#{name}"

    {:ok, output, _} = SSH.run(conn, "jls -q name 2>/dev/null || true")

    active_jails =
      output
      |> String.trim()
      |> String.split("\n", trim: true)

    if name in active_jails do
      Output.info("Build jail #{name} already running")
      :ok
    else
      # Check if jail directory exists
      case SSH.run(conn, "test -d #{jail_path} && echo yes || echo no") do
        {:ok, result, 0} when result != "" ->
          if String.trim(result) == "yes" do
            Output.info("Build jail #{name} not running, starting...")
            start_jail(conn, config)
            :ok
          else
            raise "Build jail not found. Run `alcaide setup` first."
          end

        _ ->
          raise "Build jail not found. Run `alcaide setup` first."
      end
    end
  end

  @doc """
  Creates a source tarball via `git archive` and uploads it to the
  build jail, preserving cached `deps/` and `_build/` directories.
  """
  @spec upload_source(SSH.t(), Config.t()) :: :ok | {:error, String.t()}
  def upload_source(conn, config) do
    name = build_jail_name(config)
    base_path = config.app_jail.base_path
    jail_path = "#{base_path}/#{name}"
    staging_path = "#{base_path}/.releases/#{config.app}-source.tar.gz"

    Output.info("Creating source tarball...")

    # 1. Create source tarball locally via git archive
    tarball_path = Path.join(System.tmp_dir!(), "#{config.app}-source.tar.gz")

    case System.cmd("git", ["archive", "--format=tar.gz", "-o", tarball_path, "HEAD"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        size_kb = File.stat!(tarball_path).size / 1024
        Output.success("Source tarball created (#{:erlang.float_to_binary(size_kb, decimals: 1)} KB)")

        upload_and_extract_source(conn, config, tarball_path, staging_path, name, jail_path)

      {output, code} ->
        File.rm(tarball_path)
        {:error, "git archive failed (exit #{code}): #{String.trim(output)}. Is this a git repository?"}
    end
  rescue
    e -> {:error, "Failed to upload source: #{Exception.message(e)}"}
  end

  @doc """
  Builds the Phoenix release inside the build jail.

  Runs `mix deps.get`, `mix assets.deploy`, and `mix release` inside
  the jail. Returns the host-filesystem path to the release tarball.
  """
  @spec build_release(SSH.t(), Config.t()) :: {:ok, String.t()} | {:error, String.t()}
  def build_release(conn, config) do
    name = build_jail_name(config)
    app = Atom.to_string(config.app)
    jail_path = "#{config.app_jail.base_path}/#{name}"

    Output.step("Building release in build jail #{name}")

    # 1. Fetch dependencies
    Output.info("Fetching dependencies...")
    SSH.run!(conn, "jexec #{name} /bin/sh -c 'cd /build/src && MIX_ENV=prod mix deps.get'",
      timeout: 180_000
    )

    # 2. Place wrapper script so the Elixir tailwind package finds the
    #    native binary installed by pkg (see preseed_asset_binaries/2).
    preseed_asset_binaries(conn, name)

    # 3. Compile assets (skip if no assets.deploy task defined)
    Output.info("Compiling assets...")

    # First check if the assets.deploy alias exists in the project
    case SSH.run(conn, "jexec #{name} /bin/sh -c 'cd /build/src && MIX_ENV=prod mix help assets.deploy 2>&1'") do
      {:ok, _, 0} ->
        # Task exists — run it and fail loudly if it errors.
        # NODE_PATH lets Tailwind v4's resolver find the `tailwindcss` package
        # installed by pkg at /usr/local/lib/node_modules (for @import "tailwindcss").
        SSH.run!(conn, "jexec #{name} /bin/sh -c 'cd /build/src && MIX_ENV=prod NODE_PATH=/usr/local/lib/node_modules mix assets.deploy 2>&1'",
          timeout: 300_000
        )
        Output.success("Assets compiled")

      {:ok, _, _} ->
        Output.info("No assets.deploy task found, skipping")
    end

    # 4. Build release
    Output.info("Building release...")
    SSH.run!(conn, "jexec #{name} /bin/sh -c 'cd /build/src && MIX_ENV=prod mix release --overwrite'",
      timeout: 300_000
    )

    # 4b. Verify ERTS is included in the release
    case SSH.run(conn,
           "jexec #{name} /bin/sh -c 'ls -d /build/src/_build/prod/rel/#{app}/erts-* 2>/dev/null'"
         ) do
      {:ok, output, 0} ->
        if String.trim(output) != "" do
          Output.success("Release includes ERTS")
        else
          raise "Release does not include ERTS. Add `include_erts: true` to your release config in mix.exs."
        end

      _ ->
        raise "Release does not include ERTS. Add `include_erts: true` to your release config in mix.exs."
    end

    # 5. Create release tarball
    Output.info("Creating release tarball...")

    SSH.run!(conn, """
    jexec #{name} /bin/sh -c '
      tar -czf /build/out/#{app}.tar.gz \
        -C /build/src/_build/prod/rel/#{app} .
    '
    """)

    release_path = "#{jail_path}/build/out/#{app}.tar.gz"

    Output.success("Release built successfully")
    {:ok, release_path}
  rescue
    e -> {:error, "Build failed: #{Exception.message(e)}"}
  end

  @doc """
  Destroys the build jail: stops it and removes its directory.
  """
  @spec destroy(SSH.t(), Config.t()) :: :ok
  def destroy(conn, config) do
    name = build_jail_name(config)
    jail_path = "#{config.app_jail.base_path}/#{name}"

    Output.info("Destroying build jail #{name}...")
    SSH.run(conn, "umount #{jail_path}/compat/linux/sys 2>/dev/null || true")
    SSH.run(conn, "umount #{jail_path}/compat/linux/proc 2>/dev/null || true")
    SSH.run(conn, "umount #{jail_path}/dev 2>/dev/null || true")
    SSH.run(conn, "jail -r #{name} 2>/dev/null || true")
    SSH.run(conn, "chflags -R noschg #{jail_path} 2>/dev/null || true")
    SSH.run!(conn, "rm -rf #{jail_path}")
    Output.success("Build jail #{name} destroyed")
    :ok
  end

  # --- Private ---

  defp upload_and_extract_source(conn, _config, tarball_path, staging_path, name, jail_path) do
    # 2. Upload via SSH channel
    Output.info("Uploading source code to build jail...")
    SSH.upload!(conn, tarball_path, staging_path)

    # 3. Clean old source but preserve build cache
    Output.info("Syncing source code (preserving build cache)...")

    SSH.run!(conn, """
    jexec #{name} /bin/sh -c '
      cd /build/src && \
      find . -maxdepth 1 ! -name . ! -name deps ! -name _build ! -name .hex ! -name .mix \
        -exec rm -rf {} +
    '
    """)

    # 4. Extract new source into build jail
    SSH.run!(conn, "tar -xzf #{staging_path} -C #{jail_path}/build/src")

    # 5. Clean up staging tarball
    SSH.run(conn, "rm -f #{staging_path}")
    File.rm(tarball_path)

    Output.success("Source code uploaded to build jail")
    :ok
  end

  # Installs the exact Tailwind CSS version from the app's config via npm
  # and places a wrapper script at _build/tailwind-freebsd-x64 so the Elixir
  # tailwind package finds it and skips its own download (which would fail —
  # there's no standalone FreeBSD binary on GitHub releases).
  #
  # We use npm instead of the FreeBSD tailwindcss4 pkg because:
  # - The pkg version may lag behind the app's configured version
  # - Version mismatches can cause breakage (e.g., @plugin options support)
  defp preseed_asset_binaries(conn, name) do
    detect_cmd = ~s(jexec #{name} /bin/sh -c 'grep -A5 ":tailwind" /build/src/config/*.exs 2>/dev/null | grep -oE "[0-9]+[.][0-9]+[.][0-9]+" | head -1')

    case SSH.run(conn, detect_cmd) do
      {:ok, version, 0} ->
        version = String.trim(version)

        if version != "" do
          Output.info("Installing Tailwind CSS v#{version} via npm...")

          # Install @tailwindcss/cli globally at the exact version.
          # This also installs tailwindcss and @tailwindcss/oxide-freebsd-x64.
          SSH.run!(conn,
            "jexec #{name} npm install -g @tailwindcss/cli@#{version}",
            timeout: 120_000
          )

          # Place a wrapper script at the path the Elixir package expects.
          # Using a real file (not a symlink) so File.exists? always passes.
          SSH.run!(conn, """
          jexec #{name} /bin/sh -c '
            cd /build/src
            mkdir -p _build
            target_path="_build/tailwind-freebsd-x64"
            rm -f "$target_path"
            printf "#!/bin/sh\\nexec /usr/local/bin/tailwindcss \\"\\$@\\"\\n" > "$target_path"
            chmod +x "$target_path"
            echo "Tailwind wrapper installed"
          '
          """)
        else
          Output.info("Tailwind not configured, skipping")
        end

      _ ->
        Output.info("Tailwind not configured, skipping")
    end
  end

  defp start_jail(conn, config) do
    name = build_jail_name(config)
    base_path = config.app_jail.base_path
    jail_path = "#{base_path}/#{name}"

    Output.info("Starting build jail #{name} with IP #{@build_ip}...")

    SSH.run!(conn, """
    if ! jls -q name 2>/dev/null | grep -q '^#{name}$'; then
      jail -c name=#{name} \
        path=#{jail_path} \
        ip4.addr="lo1|#{@build_ip}/32" \
        host.hostname=#{name} \
        allow.raw_sockets \
        persist
      echo "Jail started"
    else
      echo "Jail already running"
    fi
    """)

    # Mount devfs
    SSH.run!(conn, """
    if ! mount | grep -q '#{jail_path}/dev'; then
      mount -t devfs devfs #{jail_path}/dev
      echo "devfs mounted"
    else
      echo "devfs already mounted"
    fi
    """)

    # Mount Linux compatibility filesystems (linuxulator)
    SSH.run!(conn, """
    mkdir -p #{jail_path}/compat/linux/proc #{jail_path}/compat/linux/sys
    if ! mount | grep -q '#{jail_path}/compat/linux/proc'; then
      mount -t linprocfs linprocfs #{jail_path}/compat/linux/proc
      echo "linprocfs mounted"
    else
      echo "linprocfs already mounted"
    fi
    if ! mount | grep -q '#{jail_path}/compat/linux/sys'; then
      mount -t linsysfs linsysfs #{jail_path}/compat/linux/sys
      echo "linsysfs mounted"
    else
      echo "linsysfs already mounted"
    fi
    """)

    Output.success("Build jail #{name} started")
  end
end
