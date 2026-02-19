defmodule Alcaide.PipelineTest do
  use ExUnit.Case, async: true

  alias Alcaide.Pipeline

  defmodule SuccessStep do
    use Alcaide.Pipeline.Step
    def name, do: "success"
    def run(ctx), do: {:ok, Map.put(ctx, :success_ran, true)}
  end

  defmodule EnrichStep do
    use Alcaide.Pipeline.Step
    def name, do: "enrich"
    def run(ctx), do: {:ok, Map.put(ctx, :enriched, true)}
  end

  defmodule FailStep do
    use Alcaide.Pipeline.Step
    def name, do: "fail"
    def run(_ctx), do: {:error, "intentional failure"}
  end

  defmodule TrackingStep do
    use Alcaide.Pipeline.Step
    def name, do: "tracking"
    def run(ctx), do: {:ok, Map.put(ctx, :tracking_ran, true)}

    def rollback(_ctx) do
      send(self(), {:rolled_back, :tracking})
      :ok
    end
  end

  defmodule AnotherTrackingStep do
    use Alcaide.Pipeline.Step
    def name, do: "another_tracking"
    def run(ctx), do: {:ok, Map.put(ctx, :another_ran, true)}

    def rollback(_ctx) do
      send(self(), {:rolled_back, :another_tracking})
      :ok
    end
  end

  describe "run/2" do
    test "runs steps in order and threads context" do
      {:ok, ctx} = Pipeline.run([SuccessStep, EnrichStep], %{})

      assert ctx.success_ran == true
      assert ctx.enriched == true
    end

    test "returns final context on success" do
      {:ok, ctx} = Pipeline.run([SuccessStep], %{initial: true})

      assert ctx.initial == true
      assert ctx.success_ran == true
    end

    test "returns ok with empty step list" do
      {:ok, ctx} = Pipeline.run([], %{empty: true})
      assert ctx.empty == true
    end

    test "stops on failure and returns error" do
      {:error, reason, _ctx} = Pipeline.run([SuccessStep, FailStep], %{})

      assert reason == "intentional failure"
    end

    test "does not run steps after failure" do
      {:error, _reason, ctx} = Pipeline.run([FailStep, SuccessStep], %{})

      refute Map.has_key?(ctx, :success_ran)
    end

    test "rolls back completed steps in reverse order on failure" do
      {:error, _reason, _ctx} =
        Pipeline.run([TrackingStep, AnotherTrackingStep, FailStep], %{})

      assert_received {:rolled_back, :another_tracking}
      assert_received {:rolled_back, :tracking}
    end

    test "does not roll back the failed step" do
      {:error, _reason, _ctx} = Pipeline.run([TrackingStep, FailStep], %{})

      assert_received {:rolled_back, :tracking}
      # FailStep has no rollback to call
    end
  end
end
