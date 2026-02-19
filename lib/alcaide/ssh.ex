defmodule Alcaide.SSH do
  @moduledoc """
  SSH connection, command execution, and file upload using Erlang/OTP's
  `:ssh`, `:ssh_connection`, and `:ssh_sftp` modules.
  """

  defstruct [:connection, :host, :user, :port]

  @type t :: %__MODULE__{
          connection: :ssh.connection_ref(),
          host: String.t(),
          user: String.t(),
          port: non_neg_integer()
        }

  @doc """
  Connects to a remote server via SSH.

  Accepts a map with `:host`, `:user`, and `:port` keys (matching the
  server configuration from `Alcaide.Config`).
  """
  @spec connect(map()) :: {:ok, t()} | {:error, String.t()}
  def connect(%{host: host, user: user, port: port}) do
    :ssh.start()

    ssh_opts = [
      user: to_charlist(user),
      silently_accept_hosts: true,
      user_interaction: false,
      user_dir: to_charlist(Path.expand("~/.ssh"))
    ]

    case :ssh.connect(to_charlist(host), port, ssh_opts, 15_000) do
      {:ok, conn_ref} ->
        {:ok, %__MODULE__{connection: conn_ref, host: host, user: user, port: port}}

      {:error, reason} ->
        {:error, "SSH connection to #{user}@#{host}:#{port} failed: #{format_ssh_error(reason)}"}
    end
  end

  @doc """
  Executes a command on the remote server via SSH.

  Returns `{:ok, output, exit_code}` on completion. Output is streamed
  to the terminal in real-time.
  """
  @spec run(t(), String.t()) :: {:ok, String.t(), non_neg_integer()}
  def run(%__MODULE__{connection: conn_ref, host: host}, command) do
    {:ok, channel} = :ssh_connection.session_channel(conn_ref, :infinity)
    :success = :ssh_connection.exec(conn_ref, channel, to_charlist(command), :infinity)

    collect_output(conn_ref, channel, host, _acc = "", _exit_code = nil)
  end

  @doc """
  Same as `run/2` but raises on non-zero exit code.
  """
  @spec run!(t(), String.t()) :: String.t()
  def run!(conn, command) do
    case run(conn, command) do
      {:ok, output, 0} ->
        output

      {:ok, output, exit_code} ->
        truncated = String.slice(output, 0, 500)
        suffix = if String.length(output) > 500, do: "\n... (output truncated)", else: ""
        raise "Command failed (exit #{exit_code}): #{command}\nOutput: #{truncated}#{suffix}"
    end
  end

  @doc """
  Uploads a local file to a remote path via SFTP.

  Uses chunked upload (1MB chunks) to handle large release tarballs.
  """
  @spec upload!(t(), String.t(), String.t()) :: :ok
  def upload!(%__MODULE__{connection: conn_ref, host: host}, local_path, remote_path) do
    {:ok, sftp} = :ssh_sftp.start_channel(conn_ref)

    Alcaide.Output.info("Uploading #{Path.basename(local_path)} to #{host}:#{remote_path}")

    remote_charlist = to_charlist(remote_path)

    {:ok, handle} =
      case :ssh_sftp.open(sftp, remote_charlist, [:write, :creat, :trunc]) do
        {:ok, handle} ->
          {:ok, handle}

        {:error, reason} ->
          :ssh_sftp.stop_channel(sftp)
          raise "SFTP upload failed for #{remote_path}: #{inspect(reason)}"
      end

    chunk_size = 1_048_576
    file_size = File.stat!(local_path).size

    local_path
    |> File.stream!(chunk_size)
    |> Stream.with_index()
    |> Enum.each(fn {chunk, index} ->
      :ok = :ssh_sftp.write(sftp, handle, chunk, :infinity)
      uploaded = min((index + 1) * chunk_size, file_size)
      percent = trunc(uploaded / file_size * 100)

      IO.write(
        :stderr,
        "\r#{IO.ANSI.cyan()}[alcaide]#{IO.ANSI.reset()} Progress: #{percent}%"
      )
    end)

    IO.puts(:stderr, "")
    :ok = :ssh_sftp.close(sftp, handle)
    :ssh_sftp.stop_channel(sftp)
    :ok
  end

  @doc """
  Executes a long-running command, streaming output to the terminal.

  Unlike `run/2`, this function does not accumulate output and blocks
  until the remote process exits or the caller is interrupted (e.g.
  Ctrl+C for `tail -f`). Returns `:ok` when the channel closes.
  """
  @spec run_stream(t(), String.t()) :: :ok
  def run_stream(%__MODULE__{connection: conn_ref, host: host}, command) do
    {:ok, channel} = :ssh_connection.session_channel(conn_ref, :infinity)
    :success = :ssh_connection.exec(conn_ref, channel, to_charlist(command), :infinity)

    stream_output(conn_ref, channel, host)
  end

  @doc """
  Closes the SSH connection.
  """
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{connection: conn_ref}) do
    :ssh.close(conn_ref)
    :ok
  end

  # --- Private ---

  defp format_ssh_error(:econnrefused),
    do: "Connection refused. Check that SSH is running on the server."

  defp format_ssh_error(:timeout),
    do: "Connection timed out. Check the host address and network connectivity."

  defp format_ssh_error(:nxdomain),
    do: "Host not found. Check the hostname in your deploy.exs."

  defp format_ssh_error(reason) when is_atom(reason),
    do: "#{reason}. Check your SSH configuration and server accessibility."

  defp format_ssh_error(reason),
    do: "#{inspect(reason)}. Check your SSH key at ~/.ssh/ and server configuration."

  defp collect_output(conn_ref, channel, host, acc, exit_code) do
    receive do
      {:ssh_cm, ^conn_ref, {:data, ^channel, _type, data}} ->
        output = IO.chardata_to_string(data)
        Alcaide.Output.remote(host, output)
        collect_output(conn_ref, channel, host, acc <> output, exit_code)

      {:ssh_cm, ^conn_ref, {:eof, ^channel}} ->
        collect_output(conn_ref, channel, host, acc, exit_code)

      {:ssh_cm, ^conn_ref, {:exit_status, ^channel, code}} ->
        collect_output(conn_ref, channel, host, acc, code)

      {:ssh_cm, ^conn_ref, {:closed, ^channel}} ->
        {:ok, acc, exit_code || 0}
    after
      60_000 ->
        {:ok, acc, exit_code || -1}
    end
  end

  defp stream_output(conn_ref, channel, host) do
    receive do
      {:ssh_cm, ^conn_ref, {:data, ^channel, _type, data}} ->
        IO.write(IO.chardata_to_string(data))
        stream_output(conn_ref, channel, host)

      {:ssh_cm, ^conn_ref, {:eof, ^channel}} ->
        stream_output(conn_ref, channel, host)

      {:ssh_cm, ^conn_ref, {:exit_status, ^channel, _code}} ->
        stream_output(conn_ref, channel, host)

      {:ssh_cm, ^conn_ref, {:closed, ^channel}} ->
        :ok
    end
  end
end
