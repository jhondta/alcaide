defmodule Alcaide.Shell do
  @moduledoc """
  Shell utility functions shared across modules.
  """

  @doc """
  Escapes a value for safe use in shell commands using single quotes.

      iex> Alcaide.Shell.escape("hello world")
      "'hello world'"

      iex> Alcaide.Shell.escape("it's")
      "'it'\\\\''s'"
  """
  @spec escape(String.t()) :: String.t()
  def escape(value) do
    escaped = String.replace(to_string(value), "'", "'\\''")
    "'#{escaped}'"
  end
end
