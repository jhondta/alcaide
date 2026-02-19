defmodule Alcaide.Proxy do
  @moduledoc """
  Manages the Caddy reverse proxy configuration on the host server.

  Generates and updates the Caddyfile to point to the active jail's
  internal IP address. Caddy handles TLS certificates automatically
  via Let's Encrypt when a domain is configured.
  """

  alias Alcaide.{SSH, Jail, Shell, Output}

  @caddyfile_path "/usr/local/etc/caddy/Caddyfile"

  @doc """
  Generates the Caddyfile content for the given config and slot.

  When `config.domain` is set, generates a domain-based server block
  that triggers automatic TLS. When domain is nil, listens on `:80`
  for HTTP-only access.
  """
  @spec generate_caddyfile(Alcaide.Config.t(), Jail.slot()) :: String.t()
  def generate_caddyfile(config, slot) do
    ip = Jail.slot_ip(slot)
    port = config.app_jail.port
    address = config.domain || ":80"

    """
    #{address} {
        reverse_proxy #{ip}:#{port}
    }
    """
  end

  @doc """
  Reads the current Caddyfile from the server.

  Returns `{:ok, content}` if the file exists, or `{:ok, nil}` if not.
  """
  @spec read_caddyfile(SSH.t()) :: {:ok, String.t() | nil}
  def read_caddyfile(conn) do
    case SSH.run(conn, "cat #{@caddyfile_path} 2>/dev/null || echo __ALCAIDE_NO_FILE__") do
      {:ok, output, 0} ->
        if String.contains?(output, "__ALCAIDE_NO_FILE__") do
          {:ok, nil}
        else
          {:ok, output}
        end

      _ ->
        {:ok, nil}
    end
  end

  @doc """
  Writes the Caddyfile to the server and reloads Caddy.
  """
  @spec write_and_reload!(SSH.t(), String.t()) :: :ok
  def write_and_reload!(conn, caddyfile_content) do
    Output.info("Writing Caddyfile to #{@caddyfile_path}...")

    escaped = Shell.escape(caddyfile_content)
    SSH.run!(conn, "printf '%s' #{escaped} > #{@caddyfile_path}")

    Output.info("Reloading Caddy...")
    SSH.run!(conn, "service caddy reload")

    Output.success("Caddy reloaded with new configuration")
    :ok
  end

  @doc """
  Restores a previous Caddyfile and reloads Caddy.

  Used as rollback when the UpdateProxy step fails.
  """
  @spec restore!(SSH.t(), String.t()) :: :ok
  def restore!(conn, previous_content) do
    Output.info("Restoring previous Caddyfile...")

    escaped = Shell.escape(previous_content)
    SSH.run!(conn, "printf '%s' #{escaped} > #{@caddyfile_path}")
    SSH.run!(conn, "service caddy reload")

    Output.success("Previous Caddy configuration restored")
    :ok
  end

end
