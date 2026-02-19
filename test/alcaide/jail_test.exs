defmodule Alcaide.JailTest do
  use ExUnit.Case, async: true

  alias Alcaide.Jail

  @config %Alcaide.Config{
    app: :my_app,
    server: %{host: "192.168.1.1", user: "deploy", port: 22},
    domain: "myapp.com",
    app_jail: %{base_path: "/jails", freebsd_version: "14.1-RELEASE", port: 4000},
    env: [PHX_HOST: "myapp.com", PORT: "4000"]
  }

  describe "jail_name/2" do
    test "returns app_blue for blue slot" do
      assert Jail.jail_name(@config, :blue) == "my_app_blue"
    end

    test "returns app_green for green slot" do
      assert Jail.jail_name(@config, :green) == "my_app_green"
    end
  end

  describe "slot_ip/1" do
    test "returns 10.0.0.2 for blue" do
      assert Jail.slot_ip(:blue) == "10.0.0.2"
    end

    test "returns 10.0.0.3 for green" do
      assert Jail.slot_ip(:green) == "10.0.0.3"
    end
  end
end
