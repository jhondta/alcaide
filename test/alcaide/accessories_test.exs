defmodule Alcaide.AccessoriesTest do
  use ExUnit.Case, async: true

  alias Alcaide.Accessories

  @config %Alcaide.Config{
    app: :my_app,
    server: %{host: "192.168.1.1", user: "deploy", port: 22},
    app_jail: %{base_path: "/jails", freebsd_version: "14.1-RELEASE", port: 4000},
    accessories: [],
    env: []
  }

  describe "db_ip/0" do
    test "returns 10.0.0.4" do
      assert Accessories.db_ip() == "10.0.0.4"
    end
  end

  describe "db_jail_name/1" do
    test "returns app_db" do
      assert Accessories.db_jail_name(@config) == "my_app_db"
    end
  end

  describe "credential resolution" do
    test "custom credentials are available from config" do
      {:ok, config} = Alcaide.Config.load("test/fixtures/deploy_with_db.exs")
      db = Alcaide.Config.postgresql_accessory(config)

      assert db.user == "test_user"
      assert db.password == "test_pass"
      assert db.database == "test_app_production"
    end

    test "credentials default to nil when not provided" do
      {:ok, config} = Alcaide.Config.load("test/fixtures/deploy_with_db_defaults.exs")
      db = Alcaide.Config.postgresql_accessory(config)

      assert db.user == nil
      assert db.password == nil
      assert db.database == nil
    end
  end
end
