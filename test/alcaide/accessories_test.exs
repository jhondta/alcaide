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
end
