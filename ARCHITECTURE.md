# Alcaide — Deployment tool for Phoenix on FreeBSD with Jails

## Overview

Alcaide is a command-line tool written in Elixir that deploys Phoenix applications to FreeBSD servers using Jails as the isolation unit, with a workflow similar to Kamal: one configuration file and a single command.

```
alcaide deploy
```

---

## Design principles

- **Simplicity over generality.** The tool is optimized for the Phoenix + FreeBSD case. It does not attempt to be a general-purpose orchestrator.
- **No remote agent.** Everything is executed via SSH from the local machine. The server needs nothing beyond base FreeBSD.
- **Zero runtime dependencies.** Only Erlang/OTP is required on the developer machine. All operations (SSH, file upload, encryption) use OTP standard libraries.
- **Reproducibility.** The configuration file describes the complete desired state of the server.
- **Blue/green deployment from the start.** There is always an active jail and an incoming new jail. The switch is atomic from the proxy's perspective. Rotation is part of the fundamental model, not an afterthought.
- **Fail loudly.** Any failed step stops the process and reports the error clearly.

---

## Project structure

```
alcaide/
├── mix.exs
├── lib/
│   ├── alcaide/
│   │   ├── cli.ex              # Entry point, argument parsing
│   │   ├── config.ex           # Loading and validation of deploy.exs
│   │   ├── ssh.ex              # SSH connection, command execution, file upload
│   │   ├── build_jail.ex       # Persistent build jail (compile releases on FreeBSD)
│   │   ├── jail.ex             # App jail lifecycle (blue/green rotation)
│   │   ├── proxy.ex            # Caddy configuration and reload
│   │   ├── migrations.ex       # Ecto migration execution
│   │   ├── secrets.ex          # Encryption and decryption of the secrets file
│   │   ├── accessories.ex      # Auxiliary jail management (database, etc.)
│   │   ├── health_check.ex     # HTTP health checks for deployed apps
│   │   ├── shell.ex            # Shell argument escaping
│   │   ├── output.ex           # Terminal output formatting
│   │   ├── pipeline.ex         # Step runner with rollback support
│   │   └── pipeline/
│   │       ├── step.ex         # Step behaviour definition
│   │       └── steps/          # Individual deploy pipeline steps
│   └── mix/
│       └── tasks/              # Mix tasks (alcaide.deploy, alcaide.setup, etc.)
├── test/
└── deploy.exs.example          # Example configuration file
```

---

## Configuration file

The `deploy.exs` file lives at the root of the Phoenix project.

```elixir
# deploy.exs
import Config

config :alcaide,
  # Application name (must match mix.exs)
  app: :my_app,

  # Target server
  server: [
    host: "192.168.1.1",
    user: "deploy",
    port: 22
  ],

  # Public domain (used for TLS with Let's Encrypt)
  domain: "myapp.com",

  # Application jail configuration
  app_jail: [
    # Base directory on the server where jails will live
    base_path: "/jails",
    # FreeBSD version used to download the base system
    freebsd_version: "15.0-RELEASE",
    # Internal port exposed by Phoenix
    port: 4000
  ],

  # Auxiliary services (each runs in its own jail)
  accessories: [
    db: [
      type: :postgresql,
      version: "18",
      # Host server directory mounted inside the jail for persistence
      volume: "/data/postgres:/var/db/postgresql",
      port: 5432
    ]
  ],

  # Environment variables injected into the application jail
  # Secret values go in deploy.secrets.exs (encrypted)
  env: [
    DATABASE_URL: "ecto://app:app@db_jail/my_app_prod",
    PHX_HOST: "myapp.com",
    PORT: "4000"
  ]
```

---

## Commands

### `alcaide setup`

Prepares the server from scratch. Only run once (or when re-provisioning).

Steps:
1. Connect to the server via SSH and verify it is FreeBSD.
2. Enable the jail subsystem in `/etc/rc.conf`.
3. Create the `lo1` loopback interface with IP aliases for the jails.
4. Configure NAT via PF (packet filter) so jails on `lo1` can reach the internet. Auto-detects the public interface, enables IP forwarding, and adds a NAT rule to `/etc/pf.conf`.
5. Download the FreeBSD base system (`base.txz`) on the server from the official mirrors via `fetch`, and extract it as a reusable template.
6. Install Caddy on the host server via `pkg install caddy`.
7. Write the base Caddy configuration (`/usr/local/etc/caddy/Caddyfile`).
8. Start and enable Caddy as an rc service.
9. Provision accessory jails (database, etc.).
10. Provision the build jail — a persistent jail (`{app}_build`) with Elixir, Erlang, and Node.js installed for compiling releases natively on FreeBSD.

### `alcaide deploy`

Deploys a new version of the application. This is the main command. Includes blue/green rotation from the first deployment.

```
Developer machine                    FreeBSD server
─────────────────                    ──────────────
git archive → tar (~5MB)  ──SSH──→   build jail (10.0.0.5)
                                       ├── mix deps.get
                                       ├── mix assets.deploy
                                       └── mix release
                                            ↓
                                     release tarball (server disk)
                                            ↓
                                     cp local → app jail /app
```

Steps (see Pipeline section below):
1. Ensure the build jail is running.
2. Create a source tarball via `git archive` and upload it to the build jail via SSH channel.
3. Build the release inside the build jail (`mix deps.get`, `mix assets.deploy`, `mix release`). The build jail caches `deps/` and `_build/` between deploys for fast incremental builds.
4. Determine which jail comes next (blue or green). If this is the first deploy, there is no previous jail.
5. Create the new app jail by cloning the base system template.
6. Extract the release tarball (built in step 3) into the app jail. This is a local copy on the server — no network transfer needed.
7. Start the new jail.
8. Run migrations from the new jail.
9. Verify the application responds (health check).
10. Update the Caddy configuration to point to the new jail.
11. Reload Caddy (zero downtime).
12. Stop and destroy the previous jail (if it exists).

The release is self-contained (includes ERTS), so the app jail does not need Erlang installed.

### `alcaide rollback`

Reverts to the previous deployment if the previous jail still exists. If it has already been destroyed, rollback is not possible without a new deployment.

### `alcaide run CMD`

Executes an arbitrary command inside the active jail. Useful for maintenance tasks.

```bash
alcaide run "bin/my_app rpc 'IO.inspect(Node.self())'"
```

### `alcaide logs`

Shows the application logs from the active jail. Supports real-time follow mode.

```bash
# View recent logs
alcaide logs

# Follow logs in real time (equivalent to tail -f)
alcaide logs -f

# View the last N lines
alcaide logs -n 100
```

Internally executes `jexec {active_jail} /bin/sh -c "cat /var/log/{app}.log"` or reads the application process stdout, depending on how Phoenix is configured to emit logs inside the jail.

### `alcaide secrets init`

Creates the encrypted `deploy.secrets.exs` file with a master key. The key is saved in `.alcaide/master.key` (excluded via `.gitignore`).

### `alcaide secrets edit`

Opens the decrypted secrets file in the system text editor for editing.

---

## Deployment pipeline with rollback support

The `Pipeline` module executes a list of steps in order. Each step defines a `run/1` function and optionally a `rollback/1` function. If any step fails, the `rollback` functions of completed steps are executed in reverse order.

```elixir
# Conceptual step structure
defmodule Alcaide.Pipeline.Step do
  @callback run(context :: map()) :: {:ok, map()} | {:error, String.t()}
  @callback rollback(context :: map()) :: :ok
end
```

The context is a map that gets enriched with information as steps progress. For example, the jail creation step adds the new jail name to the context, and subsequent steps use that data.

---

## Jail management

### Blue/green naming

Application jails are named following the pattern `{app}_blue` and `{app}_green`. The `Jail` module checks which one is currently active and creates the other. On the first deployment, `{app}_blue` is created and there is no previous jail to destroy.

```
First deploy:
  my_app_blue  ←  created, no previous jail

Second deploy:
  my_app_blue  ←  currently active (will be destroyed at the end)
  my_app_green ←  created, receives traffic

Third deploy:
  my_app_green ←  currently active (will be destroyed at the end)
  my_app_blue  ←  created again, receives traffic
```

### Base image (template)

During `alcaide setup`, the FreeBSD base system is downloaded on the server:

```bash
# Download base.txz from the official FreeBSD mirrors
fetch https://download.freebsd.org/releases/amd64/15.0-RELEASE/base.txz \
  -o /jails/.templates/base.txz

# Extract as reusable template
mkdir -p /jails/.templates/base
tar -xf /jails/.templates/base.txz -C /jails/.templates/base
```

Each new jail is created by cloning this template (via `cp -a` or ZFS clone if available), which avoids downloading the base system on every deployment.

### FreeBSD commands used

The `Jail` module executes these commands on the server via SSH:

```bash
# Create a jail by cloning the template
cp -a /jails/.templates/base /jails/my_app_blue

# Configure and create the jail
jail -c name=my_app_blue path=/jails/my_app_blue \
  ip4.addr="lo1|10.0.0.2/32" \
  host.hostname=my_app_blue \
  allow.raw_sockets \
  exec.start="/bin/sh /etc/rc" \
  exec.stop="/bin/sh /etc/rc.shutdown"

# Start/stop
service jail start my_app_blue
service jail stop my_app_blue

# Execute a command inside the jail
jexec my_app_blue /bin/sh -c "bin/my_app start"

# List active jails
jls -q name

# Destroy a jail (stop + remove directory)
service jail stop my_app_blue
rm -rf /jails/my_app_blue
```

### Jail networking

IP aliases on the host's `lo1` loopback interface are used. Each jail gets a fixed IP on the internal network and Caddy reverse-proxies to that IP.

```
Host:           10.0.0.1  (lo1 interface)
my_app_blue:    10.0.0.2:4000
my_app_green:   10.0.0.3:4000
db_jail:        10.0.0.4:5432
my_app_build:   10.0.0.5       (build jail, no exposed port)
```

The `lo1` interface and its aliases are configured during `alcaide setup` in `/etc/rc.conf`:

```
cloned_interfaces="lo1"
ifconfig_lo1_alias0="inet 10.0.0.1/24"
```

---

## Build jail

The `BuildJail` module manages a persistent jail (`{app}_build`) that compiles Phoenix releases natively on FreeBSD. This eliminates cross-compilation issues: NIFs compile for the correct platform, ERTS is bundled in the release, and OTP versions match automatically.

### Why a build jail?

Building locally on Linux and deploying to FreeBSD causes fundamental incompatibilities:
- NIFs (argon2, bcrypt, rustler, etc.) compiled on Linux fail on FreeBSD
- OTP library version mismatches require fragile symlink hacks
- `include_erts: false` forces users to audit dependencies manually

### Lifecycle

The build jail is provisioned once during `alcaide setup` and persists between deploys:

1. Clone the FreeBSD base template
2. Install Elixir, Erlang, and Node.js via `pkg install`
3. Configure hex and rebar

During each deploy:
1. Source code is tarball'd via `git archive` (respects `.gitignore`, ~5MB)
2. Uploaded to the server via SSH channel
3. Extracted into the build jail, preserving cached `deps/` and `_build/`
4. `mix deps.get` + `mix assets.deploy` + `mix release` run inside the jail
5. The release tarball is copied locally into the app jail (no network transfer)

### Build caching

The `deps/` and `_build/` directories persist in the build jail between deploys. Only source files are replaced on each deploy, making subsequent builds incremental and fast.

---

## Reverse proxy (Caddy)

Caddy is installed on the host server via `pkg install caddy` and manages TLS certificates automatically with Let's Encrypt.

The `Proxy` module generates and updates the `Caddyfile` based on the active jail:

```
myapp.com {
    reverse_proxy 10.0.0.2:4000
}
```

When rotating jails, the module updates the IP in the `Caddyfile` and executes `service caddy reload`, which reloads the configuration without interrupting active connections.

---

## Migrations

Migrations are run from the new jail before activating it in the proxy, using the command:

```bash
jexec my_app_green bin/my_app eval "MyApp.Release.migrate()"
```

This requires the Phoenix project to have a `MyApp.Release` module with a `migrate/0` function, which is a standard convention documented in the official Phoenix guide. The tool verifies its existence during `setup` and warns if missing.

**Important convention:** migrations must be backwards-compatible with the previous code version, because during the time between the migration and the proxy rotation, the previous jail continues serving traffic with the previous version.

---

## Secrets management

The `Secrets` module uses AES-256-GCM (available in the Erlang/OTP standard library via `:crypto`) to encrypt the `deploy.secrets.exs` file.

Flow:
1. `alcaide secrets init` generates a random key and saves it in `.alcaide/master.key`.
2. The `deploy.secrets.exs` file is encrypted and can be versioned in the repository.
3. During deployment, `Secrets.load/1` decrypts the file and merges the environment variables with those defined in `deploy.exs`.
4. Variables are injected into the jail as environment variables when starting it.

---

## SSH module

The `SSH` module is the foundation of the entire tool. It wraps connection, remote command execution, and file upload using the Erlang/OTP `:ssh` and `:ssh_connection` libraries (no external dependencies).

```elixir
# Conceptual public interface
SSH.connect(host, user, port, key_path) :: {:ok, conn} | {:error, reason}
SSH.run(conn, command, opts) :: {:ok, output, exit_code}
SSH.run!(conn, command, opts) :: output  # raises on non-zero exit
SSH.upload!(conn, local_path, remote_path) :: :ok
SSH.disconnect(conn) :: :ok
```

Commands support a configurable `:timeout` option (default 60s, build commands use up to 5 minutes). File uploads use SSH channel pipes (`cat > path`), sending data in 32KB chunks — suitable for source tarballs up to ~10MB.

All commands are executed with real-time output visible in the user's terminal, prefixed with the server name for clarity.

---

## Distribution

The tool can be used in two ways:

**As a Mix dependency** (recommended for Phoenix projects):

```elixir
# mix.exs
{:alcaide, github: "jhondta/alcaide", only: :dev}
```

Used as a Mix task: `mix alcaide.deploy`

**As a self-contained binary** (using Burrito):

```bash
curl -L https://github.com/.../releases/latest/alcaide -o alcaide
chmod +x alcaide
./alcaide deploy
```

---

## Staged build plan

### Stage 1 — Minimum happy path with blue/green rotation (done)

- Modules: `Config`, `SSH`, `Jail` (blue/green rotation), `Pipeline`.

### Stage 2 — Proxy and TLS (done)

- Modules: `Proxy` (Caddy with automatic TLS).

### Stage 3 — Database and migrations (done)

- Modules: `Accessories`, `Migrations`.

### Stage 4 — Secrets and rollback (done)

- Modules: `Secrets`.

### Stage 5 — Logs and remote commands (done)

- Integrated into `CLI`.

### Stage 6 — Polish and distribution (done)

- Error messages, documentation, packaging.

### Stage 7 — Build jail (done)

Goal: compile releases natively on FreeBSD, eliminating all cross-compilation issues.

- Modules: `BuildJail`, pipeline steps `EnsureBuildJail`, `UploadSource`, `RemoteBuild`.
- Removed: `Release` (local build), `Upload` (scp-based), `InstallRuntime` (no longer needed).
- The SSH module now uses native Erlang channels for file upload (no `scp` dependency).
- Success criteria: `alcaide deploy` uploads source code, builds in the build jail, and deploys the release with full NIF support.

---

## Resolved design decisions

- **Jail networking:** IP aliases on the `lo1` loopback interface. Simple and sufficient for a single server.
- **Base image:** `base.txz` is downloaded on the server from the official FreeBSD mirrors during `alcaide setup`. Stored as a template and cloned for each new jail.
- **Servers:** Single target server. Multi-server support is left for a future version.
- **Caddy:** Installed via `pkg install caddy`.
- **No BastilleBSD.** Alcaide manages jails directly with native FreeBSD commands (`jail`, `jexec`, `jls`). This preserves the "only base FreeBSD + SSH" principle and avoids a significant dependency. Declarative configuration is provided by `deploy.exs`.
