# Alcaide

Deploy Phoenix applications to FreeBSD servers using Jails.

Alcaide provides a Kamal-like workflow for the Phoenix + FreeBSD ecosystem: one configuration file and a single command to deploy your app with blue/green rotation and zero downtime.

```
alcaide deploy
```

## Design principles

- **Simplicity over generality.** Optimized for the Phoenix + FreeBSD case. Not a general-purpose orchestrator.
- **No remote agent.** Everything runs via SSH from your local machine. The server needs nothing beyond base FreeBSD.
- **Blue/green from the start.** Two jails alternate on each deploy. The switch is atomic from the proxy's perspective.
- **Zero runtime dependencies.** Only Erlang/OTP modules: `:ssh`, `:crypto`, `:public_key`.
- **Fail loudly.** Any failed step stops the process and reports the error clearly.

## Installation

Add Alcaide to your Phoenix project as a dev dependency:

```elixir
# mix.exs
defp deps do
  [
    {:alcaide, github: "jhondta/alcaide", only: :dev}
  ]
end
```

Then fetch the dependency:

```bash
mix deps.get
```

## Quick start

### 1. Create the configuration file

Copy the example and edit it for your project:

```bash
cp deps/alcaide/deploy.exs.example deploy.exs
```

At minimum, set your app name, server host, and domain:

```elixir
import Config

config :alcaide,
  app: :my_app,
  server: [host: "192.168.1.100", user: "deploy"],
  domain: "myapp.example.com",
  app_jail: [
    base_path: "/jails",
    freebsd_version: "15.0-RELEASE",
    port: 4000
  ],
  env: [
    PHX_HOST: "myapp.example.com",
    PORT: "4000"
  ]
```

### 2. Set up encrypted secrets (optional)

```bash
mix alcaide.secrets.init
mix alcaide.secrets.edit
```

This creates an encrypted `deploy.secrets.exs` (safe to commit) and a master key at `.alcaide/master.key` (add to `.gitignore`).

### 3. Prepare the server

```bash
mix alcaide.setup
```

This connects via SSH and configures the FreeBSD server: enables jails, downloads the base system template, installs Caddy, and provisions any configured accessories (database, etc.).

### 4. Deploy

```bash
mix alcaide.deploy
```

Builds the release locally, uploads it, creates a jail, runs migrations, checks health, and switches the proxy. Done.

## Commands

All commands accept `-c PATH` to specify an alternate config file (default: `deploy.exs`).

### `alcaide setup`

Prepares the server for deployments. Run once per server (or when re-provisioning).

```bash
mix alcaide.setup
```

What it does:
1. Verifies the server is running FreeBSD and detects architecture.
2. Enables the jail subsystem and configures the `lo1` loopback interface.
3. Downloads and extracts the FreeBSD base system template.
4. Installs and configures Caddy as a reverse proxy.
5. Provisions accessory jails (PostgreSQL, etc.) if configured.

### `alcaide deploy`

Deploys a new version with blue/green rotation.

```bash
mix alcaide.deploy
```

The deploy pipeline:
1. Destroy any stale jail left from a previous deploy cycle.
2. Build the release locally with `MIX_ENV=prod mix release`.
3. Upload the release tarball to the server via SFTP.
4. Determine the next slot (blue or green).
5. Load encrypted secrets (if configured).
6. Create a new jail by cloning the base template.
7. Install the release inside the jail.
8. Start the jail and the application.
9. Run Ecto migrations.
10. Health check — verify the app responds on its internal IP.
11. Update the Caddy configuration to point to the new jail.
12. Stop the previous jail (preserved for rollback).

### `alcaide rollback`

Reverts to the previous deployment by reactivating the stopped jail.

```bash
mix alcaide.rollback
```

The previous jail is preserved after each deploy. Rollback starts it, verifies health, switches the proxy back, and stops the current jail. If the previous jail has already been destroyed (by a subsequent deploy), a new deploy is needed instead.

### `alcaide logs`

Shows application logs from the active jail.

```bash
# View the last 100 lines (default)
mix alcaide.logs

# Follow logs in real time
mix alcaide.logs -f

# Show the last N lines
mix alcaide.logs -n 50

# Combine options
mix alcaide.logs -f -n 200
```

### `alcaide run`

Executes a command inside the active jail.

```bash
# Open a remote console
mix alcaide.run "bin/my_app remote"

# Run an Elixir expression
mix alcaide.run "bin/my_app eval 'IO.inspect(MyApp.Repo.aggregate(MyApp.User, :count))'"

# Run a shell command
mix alcaide.run "uname -a"
```

### `alcaide secrets init`

Generates a master key and creates an encrypted secrets file.

```bash
mix alcaide.secrets.init
```

Creates:
- `.alcaide/master.key` — the encryption key (add to `.gitignore`, never commit)
- `deploy.secrets.exs` — encrypted file (safe to commit)

### `alcaide secrets edit`

Decrypts the secrets file, opens it in your editor, and re-encrypts on save.

```bash
mix alcaide.secrets.edit
```

Uses `$EDITOR`, falling back to `$VISUAL`, then `vi`.

The secrets file uses the same format as `deploy.exs`:

```elixir
import Config

config :alcaide,
  env: [
    SECRET_KEY_BASE: "your-secret-key-base-here",
    DATABASE_URL: "ecto://user:pass@10.0.0.4/my_app_prod"
  ]
```

Secret env vars override values with the same key in `deploy.exs`.

## Configuration reference

The `deploy.exs` file uses Elixir's `Config` module. All options are under the `:alcaide` key.

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `app` | atom | yes | — | Application name, must match your `mix.exs` `:app` |
| `server` | keyword | yes | — | SSH connection settings |
| `server.host` | string | yes | — | Server hostname or IP address |
| `server.user` | string | no | `"root"` | SSH user |
| `server.port` | integer | no | `22` | SSH port |
| `domain` | string | no | `nil` | Public domain for Caddy TLS. If omitted, serves HTTP on port 80 |
| `app_jail` | keyword | yes | — | Jail configuration |
| `app_jail.base_path` | string | yes | — | Directory on the server where jails are stored |
| `app_jail.freebsd_version` | string | yes | — | FreeBSD version for the base template (e.g., `"15.0-RELEASE"`) |
| `app_jail.port` | integer | no | `4000` | Internal port the Phoenix app listens on |
| `accessories` | keyword | no | `[]` | Auxiliary services, each in its own jail |
| `env` | keyword | no | `[]` | Environment variables injected into the app jail |

### Accessories

Each accessory runs in a persistent jail. Currently supported: `:postgresql`.

```elixir
accessories: [
  db: [
    type: :postgresql,
    version: "18",
    volume: "/data/postgres:/var/db/postgresql",
    port: 5432
  ]
]
```

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `type` | atom | yes | Service type (`:postgresql`) |
| `version` | string | yes | Package version to install |
| `volume` | string | yes | `host_path:jail_path` — data persists on the host via nullfs mount |
| `port` | integer | no | Service port (default: `5432`) |

The database jail gets IP `10.0.0.4` on the `lo1` interface. Use this IP in your `DATABASE_URL`:

```elixir
# In deploy.secrets.exs
DATABASE_URL: "ecto://my_app:password@10.0.0.4/my_app_prod"
```

## How it works

### Blue/green jail rotation

Application jails are named `{app}_blue` and `{app}_green`. Each deploy creates the opposite slot and switches traffic to it.

```
First deploy:
  my_app_blue  ←  created, receives traffic

Second deploy:
  my_app_blue  ←  was active, now stopped (kept for rollback)
  my_app_green ←  created, receives traffic

Third deploy:
  my_app_blue  ←  stale jail destroyed at start
  my_app_green ←  was active, now stopped (kept for rollback)
  my_app_blue  ←  created again, receives traffic
```

The previous jail is stopped (not destroyed) after each deploy, enabling rollback. It is destroyed at the start of the next deploy cycle.

### Jail networking

Each jail gets a fixed IP on the host's `lo1` loopback interface:

```
Host:           10.0.0.1  (lo1)
my_app_blue:    10.0.0.2:4000
my_app_green:   10.0.0.3:4000
db (postgres):  10.0.0.4:5432
```

### Reverse proxy (Caddy)

Caddy runs on the host and reverse-proxies to the active jail's internal IP. When a domain is configured, Caddy automatically provisions TLS certificates via Let's Encrypt. Without a domain, it serves HTTP on port 80.

On each deploy, Alcaide updates the Caddyfile and reloads Caddy without interrupting active connections.

### Migrations

Migrations run inside the new jail before switching the proxy:

```bash
jexec my_app_green bin/my_app eval "MyApp.Release.migrate()"
```

This requires the standard `MyApp.Release.migrate/0` function from the Phoenix deployment guide. Migrations must be backwards-compatible with the previous code version, since the old jail continues serving traffic until the proxy switches.

### Secrets

Secrets are encrypted with AES-256-GCM using a master key stored locally. The encrypted file can be committed to version control. During deployment, secrets are decrypted and merged with the env vars from `deploy.exs` — secret values override base values with the same key.

### SSH

All server communication uses Erlang/OTP's `:ssh` module directly. No external SSH client or library is required. Alcaide uses your default SSH key (`~/.ssh/id_rsa`, `~/.ssh/id_ed25519`, etc.).

## Requirements

- **Local machine:** Elixir 1.17+, Erlang/OTP 26+
- **Server:** FreeBSD 14.0+ with SSH access
- **Phoenix app:** Standard `mix release` setup with `MIX_ENV=prod`

## Project structure

```
lib/alcaide/
├── cli.ex              Entry point and argument parsing
├── config.ex           Loading and validation of deploy.exs
├── ssh.ex              SSH connection and command execution
├── release.ex          Building the release locally
├── upload.ex           Uploading via SFTP
├── jail.ex             Jail lifecycle and blue/green rotation
├── proxy.ex            Caddy configuration and reload
├── migrations.ex       Ecto migration execution
├── secrets.ex          AES-256-GCM encryption for secrets
├── accessories.ex      Auxiliary jail management (PostgreSQL)
├── health_check.ex     HTTP health checks
├── shell.ex            Shell argument escaping
├── output.ex           Terminal output formatting
└── pipeline/
    ├── pipeline.ex     Step runner with rollback support
    └── steps/          Individual deploy pipeline steps
```

## License

MIT
