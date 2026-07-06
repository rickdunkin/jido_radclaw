defmodule JidoClaw.Tools.InspectWorkflowTest do
  @moduledoc """
  AR-2 Phase 5 (§10.2) — the single-run composer observe tool. Asserts the
  POST-projection wire shape: atom top-level keys with a string-keyed nested
  `composer` (the `JsonSafe.encode/1` atom→string flip the snapshot test does
  not see), the present/absent optional-`composer` discipline, tenant + not-found
  refusals, and the operator-scope redaction pin. Includes a `Jido.Exec.run`
  execution-path test so `output_schema` validation is exercised on both the
  composer-present and composer-absent shapes.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Tools.InspectWorkflow

  setup do
    tenant = seed_tenant("inspect-workflow")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "run/2 (projected wire shape)" do
    test "a composer run: atom top-level keys + a string-keyed nested composer", ctx do
      run = composer_run!(ctx)

      assert {:ok, output} = InspectWorkflow.run(%{run_id: run.id}, tool_ctx(ctx))

      # Top-level keys are ATOMS (output_schema splits on atoms).
      assert output.run_id == run.id
      assert output.workflow_type == "composer"
      # `run_status` (not `status`): a bare `status` would trip the shared
      # `Error.normalize_result/1` soft-fail promotion on a :failed run.
      assert output.run_status == "running"

      # The nested composer is STRING-keyed (JsonSafe.encode flipped it).
      composer = output.composer
      assert composer["available"] == true
      assert composer["route"] == ["planner"]
      assert composer["ran"] == ["planner"]
      # A nested boolean marker survives the encode.
      assert composer["awaiting_approval"] == false
    end

    test "a not-yet-composed composer run shows reason as a STRING (the JsonSafe flip)", ctx do
      {:ok, run} =
        WorkflowRun.create(%{name: "fresh", workflow_type: "composer"},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      append!(run, :run_started, %{}, ctx)

      assert {:ok, output} = InspectWorkflow.run(%{run_id: run.id}, tool_ctx(ctx))
      assert output.composer["available"] == false
      assert output.composer["reason"] == "not_yet_composed"
    end

    test "a done_with_findings run carries disposition + findings_deferred_count (camus C1-4)",
         ctx do
      run = composer_run!(ctx)

      append!(
        run,
        :route_done_with_findings,
        %{
          result: %{
            "disposition" => "done_with_findings",
            "finding_keys" => ["k1"],
            "findings_deferred_count" => 1
          }
        },
        ctx
      )

      assert {:ok, output} = InspectWorkflow.run(%{run_id: run.id}, tool_ctx(ctx))
      assert output.run_status == "completed"
      assert output.disposition == "done_with_findings"
      assert output.findings_deferred_count == 1
      # Never a `status` key — the Tools.Error promotion hazard.
      refute Map.has_key?(output, :status)
    end

    test "a run without a disposition OMITS both C1-4 keys (no present-with-nil)", ctx do
      run = composer_run!(ctx)

      assert {:ok, output} = InspectWorkflow.run(%{run_id: run.id}, tool_ctx(ctx))
      refute Map.has_key?(output, :disposition)
      refute Map.has_key?(output, :findings_deferred_count)
    end

    test "a non-composer run's output OMITS the composer key (no present-with-nil)", ctx do
      {:ok, run} =
        WorkflowRun.create(%{name: "plain", workflow_type: "reactor"},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      assert {:ok, output} = InspectWorkflow.run(%{run_id: run.id}, tool_ctx(ctx))
      refute Map.has_key?(output, :composer)
    end

    test "missing tenant in tool context is a tenant_required wire error", ctx do
      run = composer_run!(ctx)

      assert {:error, %{code: :tenant_required}} =
               InspectWorkflow.run(%{run_id: run.id}, %{tool_context: %{}})
    end

    test "an unknown run id is not_found", ctx do
      assert {:error, %{code: :not_found}} =
               InspectWorkflow.run(%{run_id: Ash.UUID.generate()}, tool_ctx(ctx))
    end

    test "a secret in the run error is redacted (operator-scope inherited, T2-2)", ctx do
      secret = "sk-" <> String.duplicate("z", 24)

      {:ok, run} =
        WorkflowRun.create(%{name: "leaky", workflow_type: "composer"},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      # WorkflowRun.error stores RAW values — corruption-sim a failed terminal.
      {:ok, _} =
        run
        |> Ash.Changeset.for_update(
          :set_status,
          %{
            status: :failed,
            started_at: DateTime.add(DateTime.utc_now(), -60, :second),
            completed_at: DateTime.utc_now(),
            error: "boom #{secret}"
          },
          tenant: ctx.tenant,
          authorize?: false
        )
        |> Ash.update()

      # A :failed run reads back as a SUCCESSFUL inspection — never promoted to
      # an `{:error, _}` by the wrapper's status soft-fail convention.
      assert {:ok, output} = InspectWorkflow.run(%{run_id: run.id}, tool_ctx(ctx))
      assert output.run_status == "failed"

      refute Jason.encode!(output) =~ secret
      assert output.error =~ "[REDACTED"
    end
  end

  describe "full Jido.Exec path (output_schema validation)" do
    test "validates output for a composer run (composer present)", ctx do
      run = composer_run!(ctx)

      assert {:ok, output} =
               Jido.Exec.run(InspectWorkflow, %{run_id: run.id}, tool_ctx(ctx), log_level: :error)

      assert output.run_id == run.id
      assert is_map(output.composer)
    end

    test "validates output for a non-composer run (composer absent)", ctx do
      {:ok, run} =
        WorkflowRun.create(%{name: "plain", workflow_type: "reactor"},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      assert {:ok, output} =
               Jido.Exec.run(InspectWorkflow, %{run_id: run.id}, tool_ctx(ctx), log_level: :error)

      assert output.run_id == run.id
      refute Map.has_key?(output, :composer)
    end
  end

  # -- helpers --

  defp tool_ctx(%{tenant: tenant}), do: %{tool_context: %{tenant_id: tenant}}

  # A :running composer run with one composed + completed wave, so `composer`
  # is present with route/ran content.
  defp composer_run!(ctx) do
    {:ok, run} =
      WorkflowRun.create(%{name: "composer-run", workflow_type: "composer"},
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    append!(run, :run_started, %{}, ctx)

    append!(
      run,
      :route_composed,
      %{
        route: ["planner"],
        waves: [["planner"]],
        held: %{},
        dropped: %{},
        triggered_by: %{},
        size: 1,
        live: ["code"],
        available: [],
        premises: %{}
      },
      ctx
    )

    append!(run, :wave_started, %{wave_index: 0, stages: ["planner"]}, ctx)
    append!(run, :wave_completed, %{wave_index: 0, stages: ["planner"]}, ctx)
    run
  end

  defp append!(run, kind, payload, ctx) do
    {:ok, _} = WorkflowLog.append(run, kind, payload, tenant: ctx.tenant, actor: ctx.actor)
  end
end
