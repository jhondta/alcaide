defmodule Alcaide.ProxyTest do
  use ExUnit.Case, async: true

  alias Alcaide.Proxy

  @config_with_domain %Alcaide.Config{
    app: :my_app,
    server: %{host: "192.168.1.1", user: "deploy", port: 22},
    domain: "myapp.com",
    app_jail: %{base_path: "/jails", freebsd_version: "14.1-RELEASE", port: 4000},
    env: []
  }

  @config_without_domain %Alcaide.Config{
    app: :my_app,
    server: %{host: "192.168.1.1", user: "deploy", port: 22},
    domain: nil,
    app_jail: %{base_path: "/jails", freebsd_version: "14.1-RELEASE", port: 4000},
    env: []
  }

  describe "generate_caddyfile/2" do
    test "generates Caddyfile with domain and blue slot" do
      result = Proxy.generate_caddyfile(@config_with_domain, :blue)

      assert result =~ "myapp.com {"
      assert result =~ "reverse_proxy 10.0.0.2:4000"
      assert result =~ "}"
    end

    test "generates Caddyfile with domain and green slot" do
      result = Proxy.generate_caddyfile(@config_with_domain, :green)

      assert result =~ "myapp.com {"
      assert result =~ "reverse_proxy 10.0.0.3:4000"
    end

    test "generates HTTP-only Caddyfile when domain is nil" do
      result = Proxy.generate_caddyfile(@config_without_domain, :blue)

      assert result =~ ":80 {"
      assert result =~ "reverse_proxy 10.0.0.2:4000"
      refute result =~ "myapp.com"
    end

    test "uses correct port from config" do
      config = %{@config_with_domain | app_jail: %{@config_with_domain.app_jail | port: 8080}}
      result = Proxy.generate_caddyfile(config, :blue)

      assert result =~ "reverse_proxy 10.0.0.2:8080"
    end
  end
end
