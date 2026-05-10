defmodule JidoClaw.Reasoning.OutcomeTest do
  @moduledoc """
  v0.6.4 deprecates the `workspace_id` and `agent_id` string columns on
  `Reasoning.Outcome`. They remain on the schema (and indexes) for
  replay/audit access through the v0.6 line, but `:record`'s accept
  list no longer includes them and `Reasoning.Telemetry.persist/9`
  stops populating them. A v0.7 migration will drop the columns; the
  `@tag :deprecated_outcome_columns` markers below let us delete the
  associated assertions in one sweep at that time.

  See the moduledoc on `lib/jido_claw/reasoning/resources/outcome.ex`
  for the deprecation contract.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Reasoning.Resources.Outcome

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
      assert row.metadata == %{"extra" => "value"}
    end

    @tag :deprecated_outcome_columns
    test "deprecated workspace_id stays nil after :record (no longer in accept list)" do
      now = DateTime.utc_now()

      attrs = %{
        strategy: "cot",
        execution_kind: :strategy_run,
        task_type: :qa,
        complexity: :simple,
        prompt_length: 42,
        status: :ok,
        started_at: now,
        completed_at: now
      }

      assert {:ok, row} = Outcome.record(attrs)
      # Deprecated string column — see Outcome moduledoc.
      assert row.workspace_id == nil
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

    @tag :deprecated_outcome_columns
    test "deprecated agent_id stays nil after :record; forge_session_key still persists" do
      now = DateTime.utc_now()

      attrs = %{
        strategy: "cot",
        execution_kind: :strategy_run,
        task_type: :qa,
        complexity: :simple,
        prompt_length: 10,
        status: :ok,
        started_at: now,
        forge_session_key: "forge-abc123"
      }

      assert {:ok, row} = Outcome.record(attrs)
      # Deprecated string column — see Outcome moduledoc.
      assert row.agent_id == nil
      assert row.forge_session_key == "forge-abc123"
    end

    test "persists workspace_uuid and session_uuid (Phase 0 sibling FKs)" do
      tenant_id = seed_tenant("outcome-fk")
      {:ok, ws} = seed_workspace(tenant_id, name: "ws")

      {:ok, session} =
        seed_session(tenant_id, ws.id,
          kind: :api,
          external_id: "sess-fk-#{System.unique_integer([:positive])}"
        )

      attrs = %{
        strategy: "cot",
        execution_kind: :strategy_run,
        task_type: :qa,
        complexity: :simple,
        prompt_length: 10,
        status: :ok,
        started_at: DateTime.utc_now(),
        workspace_uuid: ws.id,
        session_uuid: session.id
      }

      assert {:ok, row} = Outcome.record(attrs)
      assert row.workspace_uuid == ws.id
      assert row.session_uuid == session.id
    end
  end

  describe "indexes" do
    test "workspace_uuid and session_uuid indexes exist" do
      {:ok, %{rows: rows}} =
        JidoClaw.Repo.query("""
          SELECT indexname FROM pg_indexes
          WHERE tablename = 'reasoning_outcomes' AND indexname LIKE '%uuid%'
        """)

      names = Enum.map(rows, &List.first/1)
      assert "reasoning_outcomes_workspace_uuid_started_at_index" in names
      assert "reasoning_outcomes_session_uuid_started_at_index" in names
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
