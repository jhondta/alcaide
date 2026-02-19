defmodule Alcaide.HealthCheck do
  @moduledoc """
  Verifies that a Phoenix application is responding inside a jail.

  Uses FreeBSD's `fetch` command (available in base system) to make HTTP
  requests from the host to the jail's internal IP.
  """

  alias Alcaide.{SSH, Output}

  @doc """
  Checks if the application is responding at the jail's IP and port.

  Retries up to `:retries` times (default 10) with `:interval` milliseconds
  between attempts (default 2000).

  ## Options

    * `:retries` - number of retry attempts (default: 10)
    * `:interval` - milliseconds between retries (default: 2000)
    * `:path` - HTTP path to check (default: "/")

  """
  @spec check(SSH.t(), Alcaide.Config.t(), Alcaide.Jail.slot(), keyword()) ::
          :ok | {:error, String.t()}
  def check(conn, config, slot, opts \\ []) do
    retries = Keyword.get(opts, :retries, 10)
    interval = Keyword.get(opts, :interval, 2_000)
    path = Keyword.get(opts, :path, "/")

    ip = Alcaide.Jail.slot_ip(slot)
    port = config.app_jail.port
    url = "http://#{ip}:#{port}#{path}"

    Output.info("Health check: #{url} (up to #{retries} attempts)")

    do_check(conn, url, retries, interval, 1)
  end

  defp do_check(_conn, url, 0, _interval, _attempt) do
    {:error,
     "Health check failed after all retries: #{url}. " <>
       "Check that the app starts correctly, PORT matches config, and the app binds to 0.0.0.0."}
  end

  defp do_check(conn, url, retries_left, interval, attempt) do
    case SSH.run(conn, "fetch -qo /dev/null #{url} 2>&1 && echo OK || echo FAIL") do
      {:ok, output, 0} ->
        if String.contains?(output, "OK") do
          Output.success("Health check passed (attempt #{attempt})")
          :ok
        else
          retry(conn, url, retries_left, interval, attempt)
        end

      _ ->
        retry(conn, url, retries_left, interval, attempt)
    end
  end

  defp retry(conn, url, retries_left, interval, attempt) do
    Output.info("Health check attempt #{attempt} failed, retrying in #{div(interval, 1000)}s...")
    Process.sleep(interval)
    do_check(conn, url, retries_left - 1, interval, attempt + 1)
  end
end
