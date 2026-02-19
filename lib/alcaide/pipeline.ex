defmodule Alcaide.Pipeline do
  @moduledoc """
  Executes a list of pipeline steps in order with rollback support.

  If any step fails, the `rollback/1` functions of completed steps are
  executed in reverse order.
  """

  alias Alcaide.Output

  @doc """
  Runs a list of step modules with the given initial context.

  Returns `{:ok, final_context}` on success or `{:error, reason, context}`
  on failure (after rollback).
  """
  @spec run([module()], map()) :: {:ok, map()} | {:error, String.t(), map()}
  def run(steps, initial_context) do
    do_run(steps, initial_context, _completed = [])
  end

  defp do_run([], context, _completed) do
    {:ok, context}
  end

  defp do_run([step | rest], context, completed) do
    Output.step(step.name())

    case step.run(context) do
      {:ok, new_context} ->
        do_run(rest, new_context, [step | completed])

      {:error, reason} ->
        Output.error("#{step.name()} failed: #{reason}")

        if completed != [] do
          Output.info("Rolling back #{length(completed)} completed step(s)...")
          rollback(completed, context)
        end

        {:error, reason, context}
    end
  end

  defp rollback([], _context), do: :ok

  defp rollback([step | rest], context) do
    Output.info("Rolling back: #{step.name()}")

    try do
      step.rollback(context)
    rescue
      e -> Output.error("Rollback of #{step.name()} failed: #{Exception.message(e)}")
    end

    rollback(rest, context)
  end
end
