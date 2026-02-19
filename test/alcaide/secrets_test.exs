defmodule Alcaide.SecretsTest do
  use ExUnit.Case, async: true

  alias Alcaide.Secrets

  @test_key :crypto.strong_rand_bytes(32)

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "alcaide_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "encrypt/2 and decrypt/4" do
    test "round-trip encrypts and decrypts plaintext" do
      plaintext = "hello, secrets!"
      {iv, ciphertext, tag} = Secrets.encrypt(plaintext, @test_key)

      assert byte_size(iv) == 16
      assert byte_size(tag) == 16
      assert ciphertext != plaintext

      decrypted = Secrets.decrypt(iv, ciphertext, tag, @test_key)
      assert decrypted == plaintext
    end

    test "different encryptions produce different IVs" do
      plaintext = "same text"
      {iv1, _, _} = Secrets.encrypt(plaintext, @test_key)
      {iv2, _, _} = Secrets.encrypt(plaintext, @test_key)

      assert iv1 != iv2
    end

    test "decryption with wrong key raises" do
      plaintext = "secret data"
      {iv, ciphertext, tag} = Secrets.encrypt(plaintext, @test_key)

      wrong_key = :crypto.strong_rand_bytes(32)

      assert_raise RuntimeError, ~r/Decryption failed/, fn ->
        Secrets.decrypt(iv, ciphertext, tag, wrong_key)
      end
    end
  end

  describe "save_encrypted!/3 and load_encrypted!/2" do
    test "round-trip saves and loads encrypted file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.secrets")
      plaintext = "import Config\n\nconfig :alcaide, env: [SECRET: \"value\"]\n"

      Secrets.save_encrypted!(path, plaintext, @test_key)

      assert File.exists?(path)

      # Encrypted file should not contain plaintext
      raw = File.read!(path)
      refute String.contains?(raw, "SECRET")

      loaded = Secrets.load_encrypted!(path, @test_key)
      assert loaded == plaintext
    end

    test "load_encrypted! raises for corrupted file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "corrupt.secrets")
      File.write!(path, "too short")

      assert_raise RuntimeError, ~r/too small/, fn ->
        Secrets.load_encrypted!(path, @test_key)
      end
    end

    test "load_encrypted! raises for non-existent file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nonexistent.secrets")

      assert_raise File.Error, fn ->
        Secrets.load_encrypted!(path, @test_key)
      end
    end
  end

  describe "init!/0" do
    test "creates master key and encrypted secrets file", %{tmp_dir: tmp_dir} do
      key_path = Path.join(tmp_dir, ".alcaide/master.key")
      secrets_path = Path.join(tmp_dir, "deploy.secrets.exs")

      # Temporarily override the module's default paths
      # We test via the lower-level functions since init! uses hardcoded paths
      key = :crypto.strong_rand_bytes(32)
      File.mkdir_p!(Path.dirname(key_path))
      File.write!(key_path, Base.encode64(key))

      template = """
      import Config

      config :alcaide,
        env: [
          SECRET_KEY_BASE: "change-me-run-mix-phx-gen-secret"
        ]
      """

      Secrets.save_encrypted!(secrets_path, template, key)

      assert File.exists?(secrets_path)

      loaded_key = Secrets.read_master_key!(key_path)
      assert byte_size(loaded_key) == 32

      plaintext = Secrets.load_encrypted!(secrets_path, loaded_key)
      assert plaintext =~ "SECRET_KEY_BASE"
    end
  end

  describe "read_master_key!/1" do
    test "reads and decodes base64 key", %{tmp_dir: tmp_dir} do
      key = :crypto.strong_rand_bytes(32)
      path = Path.join(tmp_dir, "master.key")
      File.write!(path, Base.encode64(key))

      loaded = Secrets.read_master_key!(path)
      assert loaded == key
      assert byte_size(loaded) == 32
    end

    test "raises for missing key file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.key")

      assert_raise RuntimeError, ~r/Master key not found/, fn ->
        Secrets.read_master_key!(path)
      end
    end
  end

  describe "load_and_merge_env/3" do
    test "merges secret env vars with config env", %{tmp_dir: tmp_dir} do
      key = :crypto.strong_rand_bytes(32)
      key_path = Path.join(tmp_dir, "master.key")
      secrets_path = Path.join(tmp_dir, "deploy.secrets.exs")

      File.write!(key_path, Base.encode64(key))

      plaintext = File.read!("test/fixtures/deploy_secrets.exs")
      Secrets.save_encrypted!(secrets_path, plaintext, key)

      config = %Alcaide.Config{
        app: :test_app,
        server: %{host: "localhost", user: "deploy", port: 22},
        app_jail: %{base_path: "/jails", freebsd_version: "14.1-RELEASE", port: 4000},
        env: [PHX_HOST: "testapp.com", PORT: "4000", SECRET_KEY_BASE: "old-value"]
      }

      {:ok, merged_config} = Secrets.load_and_merge_env(config, secrets_path, key_path)

      # Secrets override base env
      assert Keyword.get(merged_config.env, :SECRET_KEY_BASE) == "test-secret-key-base-value"
      assert Keyword.get(merged_config.env, :DATABASE_URL) ==
               "ecto://secret_user:secret_pass@10.0.0.4/my_app_prod"

      # Base env vars not in secrets are preserved
      assert Keyword.get(merged_config.env, :PHX_HOST) == "testapp.com"
      assert Keyword.get(merged_config.env, :PORT) == "4000"
    end

    test "skips when neither secrets nor key exist", %{tmp_dir: tmp_dir} do
      config = %Alcaide.Config{
        app: :test_app,
        server: %{host: "localhost", user: "deploy", port: 22},
        app_jail: %{base_path: "/jails", freebsd_version: "14.1-RELEASE", port: 4000},
        env: [PHX_HOST: "testapp.com"]
      }

      secrets_path = Path.join(tmp_dir, "nonexistent.secrets")
      key_path = Path.join(tmp_dir, "nonexistent.key")

      {:skip, returned_config} = Secrets.load_and_merge_env(config, secrets_path, key_path)
      assert returned_config == config
    end

    test "errors when secrets exist but key is missing", %{tmp_dir: tmp_dir} do
      secrets_path = Path.join(tmp_dir, "deploy.secrets.exs")
      key_path = Path.join(tmp_dir, "missing.key")
      File.write!(secrets_path, "encrypted data")

      config = %Alcaide.Config{
        app: :test_app,
        server: %{host: "localhost", user: "deploy", port: 22},
        app_jail: %{base_path: "/jails", freebsd_version: "14.1-RELEASE", port: 4000},
        env: []
      }

      {:error, msg} = Secrets.load_and_merge_env(config, secrets_path, key_path)
      assert msg =~ "no master key"
    end

    test "errors when key exists but secrets file is missing", %{tmp_dir: tmp_dir} do
      secrets_path = Path.join(tmp_dir, "missing.secrets")
      key_path = Path.join(tmp_dir, "master.key")
      key = :crypto.strong_rand_bytes(32)
      File.write!(key_path, Base.encode64(key))

      config = %Alcaide.Config{
        app: :test_app,
        server: %{host: "localhost", user: "deploy", port: 22},
        app_jail: %{base_path: "/jails", freebsd_version: "14.1-RELEASE", port: 4000},
        env: []
      }

      {:error, msg} = Secrets.load_and_merge_env(config, secrets_path, key_path)
      assert msg =~ "no secrets file"
    end
  end
end
