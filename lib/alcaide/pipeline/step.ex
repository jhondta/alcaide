defmodule Alcaide.Pipeline.Step do
  @moduledoc """
  Behaviour for deployment pipeline steps.

  Each step implements `name/0`, `run/1`, and optionally `rollback/1`.
  The default rollback is a no-op.
  """

  @type context :: map()

  @callback name() :: String.t()
  @callback run(context()) :: {:ok, context()} | {:error, String.t()}
  @callback rollback(context()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour Alcaide.Pipeline.Step

      @impl true
      def rollback(_context), do: :ok

      defoverridable rollback: 1
    end
  end
end
