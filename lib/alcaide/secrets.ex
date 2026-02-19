defmodule Alcaide.Secrets do
  @moduledoc """
  Encryption and decryption of the `deploy.secrets.exs` file using
  AES-256-GCM from Erlang/OTP's `:crypto` module.

  Secrets are encrypted with a master key stored in `.alcaide/master.key`
  (excluded from version control). The encrypted `deploy.secrets.exs` file
  can be safely committed to the repository.

  ## File format

  The encrypted file is a raw binary:

      <<iv::128, tag::128, ciphertext::binary>>

  - `iv` — 16-byte random initialization vector (unique per encryption)
  - `tag` — 16-byte GCM authentication tag
  - `ciphertext` — AES-256-GCM encrypted payload
  """

  alias Alcaide.Output

  @key_length 32
  @iv_length 16
  @tag_length 16
  @aad "alcaide-secrets"

  @master_key_path ".alcaide/master.key"
  @secrets_path "deploy.secrets.exs"

  @doc """
  Returns the default master key file path.
  """
  @spec master_key_path() :: String.t()
  def master_key_path, do: @master_key_path

  @doc """
  Returns the default secrets file path.
  """
  @spec secrets_path() :: String.t()
  def secrets_path, do: @secrets_path

  @doc """
  Generates a random master key and saves it to `.alcaide/master.key`.

  Creates a starter `deploy.secrets.exs` template, encrypts it, and
  saves the encrypted version. Raises if the master key already exists.
  """
  @spec init!() :: :ok
  def init! do
    if File.exists?(@master_key_path) do
      raise "Master key already exists at #{@master_key_path}. Delete it first to re-initialize."
    end

    key = :crypto.strong_rand_bytes(@key_length)

    File.mkdir_p!(Path.dirname(@master_key_path))
    File.write!(@master_key_path, Base.encode64(key))
    File.chmod!(@master_key_path, 0o600)

    Output.success("Master key generated at #{@master_key_path}")
    Output.info("Add #{@master_key_path} to .gitignore!")

    template = """
    import Config

    config :alcaide,
      env: [
        SECRET_KEY_BASE: "change-me-run-mix-phx-gen-secret"
      ]
    """

    save_encrypted!(@secrets_path, template, key)

    Output.success("Encrypted secrets file created at #{@secrets_path}")
    Output.info("Run `alcaide secrets edit` to add your secret values.")
    :ok
  end

  @doc """
  Opens the decrypted secrets file in the system editor for editing.

  Decrypts the file to a temporary location, opens `$EDITOR` (falling
  back to `$VISUAL`, then `vi`), and re-encrypts when the editor exits.
  """
  @spec edit!(String.t(), String.t()) :: :ok
  def edit!(secrets_path \\ @secrets_path, key_path \\ @master_key_path) do
    key = read_master_key!(key_path)
    plaintext = load_encrypted!(secrets_path, key)

    tmp_path = Path.join(System.tmp_dir!(), "alcaide_secrets_#{:rand.uniform(100_000)}.exs")

    try do
      File.write!(tmp_path, plaintext)
      File.chmod!(tmp_path, 0o600)

      editor = System.get_env("EDITOR") || System.get_env("VISUAL") || "vi"

      # :nouse_stdio lets the editor inherit the parent terminal's stdin/stdout,
      # and :exit_status sends us {port, {:exit_status, code}} when it finishes
      port = Port.open({:spawn, "#{editor} #{tmp_path}"}, [:nouse_stdio, :exit_status])

      receive do
        {^port, {:exit_status, 0}} -> :ok
        {^port, {:exit_status, code}} -> raise "Editor exited with code #{code}"
      end

      updated = File.read!(tmp_path)

      if updated != plaintext do
        save_encrypted!(secrets_path, updated, key)
        Output.success("Secrets updated and re-encrypted.")
      else
        Output.info("No changes detected.")
      end

      :ok
    after
      File.rm(tmp_path)
    end
  end

  @doc """
  Encrypts plaintext using AES-256-GCM.

  Returns `{iv, ciphertext, tag}`.
  """
  @spec encrypt(String.t(), binary()) :: {binary(), binary(), binary()}
  def encrypt(plaintext, key) when byte_size(key) == @key_length do
    iv = :crypto.strong_rand_bytes(@iv_length)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)
    {iv, ciphertext, tag}
  end

  @doc """
  Decrypts ciphertext using AES-256-GCM.

  Returns the plaintext string or raises on authentication failure.
  """
  @spec decrypt(binary(), binary(), binary(), binary()) :: String.t()
  def decrypt(iv, ciphertext, tag, key)
      when byte_size(key) == @key_length and byte_size(iv) == @iv_length and
             byte_size(tag) == @tag_length do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      :error ->
        raise "Decryption failed: invalid key or corrupted file"

      plaintext ->
        plaintext
    end
  end

  @doc """
  Encrypts plaintext and writes it to a file.

  The file format is: `<<iv::16-bytes, tag::16-bytes, ciphertext::rest>>`.
  """
  @spec save_encrypted!(String.t(), String.t(), binary()) :: :ok
  def save_encrypted!(path, plaintext, key) do
    {iv, ciphertext, tag} = encrypt(plaintext, key)
    File.write!(path, iv <> tag <> ciphertext)
    :ok
  end

  @doc """
  Reads and decrypts an encrypted file.

  Returns the plaintext string.
  """
  @spec load_encrypted!(String.t(), binary()) :: String.t()
  def load_encrypted!(path, key) do
    data = File.read!(path)

    if byte_size(data) < @iv_length + @tag_length do
      raise "Encrypted file #{path} is too small to be valid"
    end

    <<iv::binary-size(@iv_length), tag::binary-size(@tag_length), ciphertext::binary>> = data
    decrypt(iv, ciphertext, tag, key)
  end

  @doc """
  Reads the master key from the key file.

  Returns the raw 32-byte binary key.
  """
  @spec read_master_key!(String.t()) :: binary()
  def read_master_key!(path \\ @master_key_path) do
    unless File.exists?(path) do
      raise "Master key not found at #{path}. Run `alcaide secrets init` first."
    end

    path
    |> File.read!()
    |> String.trim()
    |> Base.decode64!()
  end

  @doc """
  Loads encrypted secrets and merges their env vars with the given config.

  If neither the secrets file nor the master key exist, returns the
  config unchanged (secrets are optional). If only one exists, raises
  an error.

  Returns a new config struct with merged env vars (secrets override base).
  """
  @spec load_and_merge_env(Alcaide.Config.t(), String.t(), String.t()) ::
          {:ok, Alcaide.Config.t()} | {:skip, Alcaide.Config.t()} | {:error, String.t()}
  def load_and_merge_env(config, secrets_path \\ @secrets_path, key_path \\ @master_key_path) do
    secrets_exist = File.exists?(secrets_path)
    key_exists = File.exists?(key_path)

    cond do
      secrets_exist and key_exists ->
        merge_secrets(config, secrets_path, key_path)

      !secrets_exist and !key_exists ->
        {:skip, config}

      secrets_exist and !key_exists ->
        {:error,
         "Found #{secrets_path} but no master key at #{key_path}. " <>
           "Restore your master key or run `alcaide secrets init` to create a new one."}

      !secrets_exist and key_exists ->
        {:error,
         "Found master key at #{key_path} but no secrets file at #{secrets_path}. " <>
           "Run `alcaide secrets init` to create the secrets file."}
    end
  end

  defp merge_secrets(config, secrets_path, key_path) do
    key = read_master_key!(key_path)
    plaintext = load_encrypted!(secrets_path, key)

    # Write to temp file so Config.Reader.read!/1 can parse it
    tmp_path = Path.join(System.tmp_dir!(), "alcaide_secrets_parse_#{:rand.uniform(100_000)}.exs")

    try do
      File.write!(tmp_path, plaintext)
      secret_config = Config.Reader.read!(tmp_path)

      secret_env =
        secret_config
        |> Keyword.get(:alcaide, [])
        |> Keyword.get(:env, [])

      merged_env = Keyword.merge(config.env, secret_env)
      {:ok, %{config | env: merged_env}}
    after
      File.rm(tmp_path)
    end
  rescue
    e -> {:error, "Failed to load secrets: #{Exception.message(e)}"}
  end
end
