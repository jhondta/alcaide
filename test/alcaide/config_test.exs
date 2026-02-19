defmodule Alcaide.ConfigTest do
  use ExUnit.Case, async: true

  alias Alcaide.Config

  describe "load/1" do
    test "loads a valid deploy.exs with all fields" do
      {:ok, config} = Config.load("test/fixtures/deploy.exs")

      assert config.app == :test_app
      assert config.server.host == "192.168.1.1"
      assert config.server.user == "deploy"
      assert config.server.port == 22
      assert config.domain == "testapp.com"
      assert config.app_jail.base_path == "/jails"
      assert config.app_jail.freebsd_version == "14.1-RELEASE"
      assert config.app_jail.port == 4000
      assert config.env == [PHX_HOST: "testapp.com", PORT: "4000"]
    end

    test "loads a minimal deploy.exs and applies defaults" do
      {:ok, config} = Config.load("test/fixtures/deploy_minimal.exs")

      assert config.app == :minimal_app
      assert config.server.host == "10.0.0.1"
      assert config.server.user == "root"
      assert config.server.port == 22
      assert config.domain == nil
      assert config.app_jail.base_path == "/jails"
      assert config.app_jail.freebsd_version == "14.2-RELEASE"
      assert config.app_jail.port == 4000
      assert config.env == []
    end

    test "returns error for missing :app key" do
      {:error, msg} = Config.load("test/fixtures/deploy_invalid.exs")
      assert msg =~ "Missing required key :app"
    end

    test "returns error for non-existent file" do
      {:error, msg} = Config.load("test/fixtures/nonexistent.exs")
      assert msg =~ "Configuration file not found"
    end

    test "loads config with accessories" do
      {:ok, config} = Config.load("test/fixtures/deploy_with_db.exs")

      assert length(config.accessories) == 1
      [db] = config.accessories
      assert db.name == :db
      assert db.type == :postgresql
      assert db.version == "16"
      assert db.volume == "/data/postgres:/var/db/postgresql"
      assert db.port == 5432
      assert db.user == "test_user"
      assert db.password == "test_pass"
      assert db.database == "test_app_production"
    end

    test "loads config with accessories using default credentials" do
      {:ok, config} = Config.load("test/fixtures/deploy_with_db_defaults.exs")

      [db] = config.accessories
      assert db.type == :postgresql
      assert db.user == nil
      assert db.password == nil
      assert db.database == nil
    end

    test "loads config without accessories (defaults to empty list)" do
      {:ok, config} = Config.load("test/fixtures/deploy.exs")
      assert config.accessories == []
    end

    test "returns error for invalid accessory (missing required keys)" do
      {:error, msg} = Config.load("test/fixtures/deploy_invalid_accessory.exs")
      assert msg =~ "Missing required key :version"
    end
  end

  describe "load!/1" do
    test "returns config on success" do
      config = Config.load!("test/fixtures/deploy.exs")
      assert config.app == :test_app
    end

    test "raises on error" do
      assert_raise ArgumentError, ~r/Missing required key/, fn ->
        Config.load!("test/fixtures/deploy_invalid.exs")
      end
    end
  end

  describe "postgresql_accessory/1" do
    test "returns the postgresql accessory when configured" do
      {:ok, config} = Config.load("test/fixtures/deploy_with_db.exs")

      accessory = Config.postgresql_accessory(config)
      assert accessory != nil
      assert accessory.type == :postgresql
      assert accessory.name == :db
    end

    test "returns nil when no accessories" do
      {:ok, config} = Config.load("test/fixtures/deploy.exs")

      assert Config.postgresql_accessory(config) == nil
    end
  end
end
