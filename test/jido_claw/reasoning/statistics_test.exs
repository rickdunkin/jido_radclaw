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
end
