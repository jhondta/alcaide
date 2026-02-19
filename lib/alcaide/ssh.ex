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
        {:error, "SSH connection to #{user}@#{host}:#{port} failed: #{inspect(reason)}"}
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
        raise "Command failed (exit #{exit_code}): #{command}\nOutput: #{output}"
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
  Closes the SSH connection.
  """
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{connection: conn_ref}) do
    :ssh.close(conn_ref)
    :ok
  end

  # --- Private ---

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
end
