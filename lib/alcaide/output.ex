defmodule Alcaide.Output do
  @moduledoc """
  Terminal output formatting with ANSI colors.
  """

  def info(message) do
    IO.puts(:stderr, "#{IO.ANSI.cyan()}[alcaide]#{IO.ANSI.reset()} #{message}")
  end

  def success(message) do
    IO.puts(:stderr, "#{IO.ANSI.green()}[alcaide]#{IO.ANSI.reset()} #{message}")
  end

  def error(message) do
    IO.puts(:stderr, "#{IO.ANSI.red()}[alcaide]#{IO.ANSI.reset()} #{message}")
  end

  def step(message) do
    IO.puts(:stderr, "\n#{IO.ANSI.bright()}==> #{message}#{IO.ANSI.reset()}")
  end

  def remote(host, output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      IO.puts(:stderr, "#{IO.ANSI.light_black()}[#{host}]#{IO.ANSI.reset()} #{line}")
    end)
  end
end
