# Alcaide

Deploy Phoenix applications to FreeBSD servers using Jails.

Alcaide provides a Kamal-like workflow: one configuration file and a single command to deploy your app with blue/green rotation and zero downtime.

```
alcaide deploy
```

## Status

Under active development. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## Quick start

Add Alcaide to your Phoenix project:

```elixir
# mix.exs
{:alcaide, "~> 0.1", only: :dev}
```

Create a `deploy.exs` in your project root (see [deploy.exs.example](deploy.exs.example)).

Prepare your FreeBSD server:

```bash
mix alcaide.setup
```

Deploy:

```bash
mix alcaide.deploy
```

## How it works

- **No remote agent** — everything runs via SSH from your local machine
- **Blue/green jails** — two jails alternate on each deploy for zero downtime
- **Native FreeBSD** — uses `jail`, `jexec`, and `jls` directly, no extra software on the server
- **Zero runtime dependencies** — only Erlang/OTP's `:ssh` and `:crypto` modules

## License

MIT
