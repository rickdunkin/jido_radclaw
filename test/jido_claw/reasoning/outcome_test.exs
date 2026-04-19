defmodule JidoClaw.Reasoning.OutcomeTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Reasoning.Resources.Outcome

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  describe "record/1" do
    test "persists all enum fields and free-form metadata" do
      now = DateTime.utc_now()

      attrs = %{
        strategy: "cot",
        execution_kind: :strategy_run,
        task_type: :qa,
        complexity: :simple,
        domain: "testing",
        target: "unit_test",
        prompt_length: 42,
        status: :ok,
        duration_ms: 1200,
        tokens_in: 100,
        tokens_out: 50,
        workspace_id: "ws-1",
        project_dir: "/tmp/proj",
        metadata: %{"extra" => "value"},
        started_at: now,
        completed_at: now
      }

      assert {:ok, row} = Outcome.record(attrs)
      assert row.strategy == "cot"
      assert row.execution_kind == :strategy_run
      assert row.task_type == :qa
      assert row.complexity == :simple
      assert row.status == :ok
      assert row.workspace_id == "ws-1"
      assert row.metadata == %{"extra" => "value"}
    end

    test "accepts :certificate_verification execution_kind (0.4.2 placeholder)" do
      now = DateTime.utc_now()

      attrs = %{
        strategy: "cot",
        execution_kind: :certificate_verification,
        task_type: :verification,
        complexity: :moderate,
        prompt_length: 80,
        status: :ok,
        started_at: now
      }

      assert {:ok, row} = Outcome.record(attrs)
      assert row.execution_kind == :certificate_verification
    end

    test "requires strategy, execution_kind, task_type, complexity, status, started_at, prompt_length" do
      assert {:error, _} = Outcome.record(%{strategy: "cot"})
    end

    test "persists agent_id and forge_session_key" do
      now = DateTime.utc_now()

      attrs = %{
        strategy: "cot",
        execution_kind: :strategy_run,
        task_type: :qa,
        complexity: :simple,
        prompt_length: 10,
        status: :ok,
        started_at: now,
        agent_id: "main",
        forge_session_key: "forge-abc123"
      }

      assert {:ok, row} = Outcome.record(attrs)
      assert row.agent_id == "main"
      assert row.forge_session_key == "forge-abc123"
    end
  end

  describe "list_by_task_type/2" do
    test "defaults to strategy_run rows only" do
      now = DateTime.utc_now()

      {:ok, _} =
        Outcome.record(%{
          strategy: "cot",
          execution_kind: :strategy_run,
          task_type: :qa,
          complexity: :simple,
          prompt_length: 10,
          status: :ok,
          started_at: now
        })

      {:ok, _} =
        Outcome.record(%{
          strategy: "cot",
          execution_kind: :certificate_verification,
          task_type: :qa,
          complexity: :simple,
          prompt_length: 10,
          status: :ok,
          started_at: now
        })

      {:ok, rows} = Outcome.list_by_task_type(:qa)
      assert length(rows) == 1
      assert hd(rows).execution_kind == :strategy_run
    end

    test "can filter by specific execution_kind" do
      now = DateTime.utc_now()

      {:ok, _} =
        Outcome.record(%{
          strategy: "cot",
          execution_kind: :certificate_verification,
          task_type: :verification,
          complexity: :moderate,
          prompt_length: 10,
          status: :ok,
          started_at: now
        })

      {:ok, rows} = Outcome.list_by_task_type(:verification, :certificate_verification)
      assert length(rows) == 1
    end
  end
end
