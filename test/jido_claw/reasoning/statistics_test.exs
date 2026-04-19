defmodule JidoClaw.Reasoning.StatisticsTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Reasoning.{Resources.Outcome, Statistics}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  defp insert(attrs) do
    now = DateTime.utc_now()

    defaults = %{
      strategy: "cot",
      execution_kind: :strategy_run,
      task_type: :qa,
      complexity: :simple,
      prompt_length: 10,
      status: :ok,
      started_at: now
    }

    {:ok, _} = Outcome.record(Map.merge(defaults, attrs))
  end

  describe "best_strategies_for/2" do
    test "defaults to strategy_run rows only" do
      insert(%{strategy: "cot", execution_kind: :strategy_run, task_type: :qa})
      insert(%{strategy: "cot", execution_kind: :strategy_run, task_type: :qa})

      insert(%{
        strategy: "cot",
        execution_kind: :certificate_verification,
        task_type: :qa,
        status: :error
      })

      stats = Statistics.best_strategies_for(:qa)
      assert [%{strategy: "cot", samples: 2, success_rate: 1.0}] = stats
    end

    test "respects :all to include every execution_kind" do
      insert(%{strategy: "cot", execution_kind: :strategy_run, task_type: :qa})

      insert(%{
        strategy: "cot",
        execution_kind: :certificate_verification,
        task_type: :qa,
        status: :error
      })

      stats = Statistics.best_strategies_for(:qa, execution_kind: :all)
      assert [%{strategy: "cot", samples: 2}] = stats
    end

    test "orders by success rate then sample count" do
      # "cot" 3/3 ok, "tot" 1/2 ok — cot should come first
      insert(%{strategy: "cot", task_type: :planning, status: :ok})
      insert(%{strategy: "cot", task_type: :planning, status: :ok})
      insert(%{strategy: "cot", task_type: :planning, status: :ok})
      insert(%{strategy: "tot", task_type: :planning, status: :ok})
      insert(%{strategy: "tot", task_type: :planning, status: :error})

      [first, second] = Statistics.best_strategies_for(:planning)
      assert first.strategy == "cot"
      assert second.strategy == "tot"
    end

    test "returns [] when no rows match" do
      assert Statistics.best_strategies_for(:debugging) == []
    end
  end

  describe "summary/0" do
    test "enriches per-strategy rows with success_rate and avg_duration_ms" do
      insert(%{strategy: "cot", task_type: :qa, status: :ok, duration_ms: 100})
      insert(%{strategy: "cot", task_type: :qa, status: :ok, duration_ms: 300})
      insert(%{strategy: "tot", task_type: :planning, status: :error, duration_ms: 200})
      insert(%{strategy: "tot", task_type: :planning, status: :ok, duration_ms: 400})

      summary = Statistics.summary()

      cot = Enum.find(summary.strategies, &(&1.strategy == "cot"))
      assert cot.samples == 2
      assert cot.success_rate == 1.0
      assert_in_delta cot.avg_duration_ms, 200.0, 0.01

      tot = Enum.find(summary.strategies, &(&1.strategy == "tot"))
      assert tot.samples == 2
      assert tot.success_rate == 0.5
    end

    test "orders strategies by success_rate desc then samples desc" do
      insert(%{strategy: "cot", task_type: :qa, status: :ok})
      insert(%{strategy: "tot", task_type: :qa, status: :error})

      summary = Statistics.summary()

      [first | _] = summary.strategies
      assert first.strategy == "cot"
    end

    test "includes per-task-type rows with success_rate" do
      insert(%{strategy: "cot", task_type: :qa, status: :ok})
      insert(%{strategy: "cot", task_type: :qa, status: :ok})
      insert(%{strategy: "cot", task_type: :planning, status: :error})

      summary = Statistics.summary()

      qa = Enum.find(summary.task_types, &(&1.task_type == "qa"))
      assert qa.samples == 2
      assert qa.success_rate == 1.0

      plan = Enum.find(summary.task_types, &(&1.task_type == "planning"))
      assert plan.samples == 1
      assert plan.success_rate == 0.0
    end

    test "returns empty lists when no rows" do
      assert %{strategies: [], task_types: []} = Statistics.summary()
    end
  end
end
