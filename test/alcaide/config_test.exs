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
end
