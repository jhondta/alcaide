defmodule Alcaide.MigrationsTest do
  use ExUnit.Case, async: true

  alias Alcaide.Migrations

  describe "app_module_name/1" do
    test "converts simple app name" do
      assert Migrations.app_module_name(:my_app) == "MyApp"
    end

    test "converts single-word app name" do
      assert Migrations.app_module_name(:blog) == "Blog"
    end

    test "converts multi-word app name" do
      assert Migrations.app_module_name(:phoenix_live_blog) == "PhoenixLiveBlog"
    end
  end
end
