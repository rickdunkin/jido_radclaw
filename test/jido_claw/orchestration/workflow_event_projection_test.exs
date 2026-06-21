defmodule JidoClaw.Orchestration.WorkflowEventProjectionTest do
  @moduledoc """
  AR-2 Phase 2c — the composer `route_*` parent-terminal kinds in the status
  projection: the pure `next_status/2` transitions + `status_attrs/3` attribute
  lifts (incl. `route_rejected`/`route_abandoned` lifting `result.disposition`,
  unlike `run_cancelled` which drops its payload), and the reloaded JSONB
  string-keyed payload path through the real append transaction.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  @failed_kinds [:route_not_converged, :route_deadlocked, :route_budget_exhausted, :route_failed]
  @cancelled_kinds [:route_rejected, :route_abandoned]

  describe "next_status/2 (pure)" do
    test "route_converged: :running -> :completed only" do
      assert Projection.next_status(:running, :route_converged) == {:ok, :completed}
      assert Projection.next_status(:pending, :route_converged) == :illegal
      assert Projection.next_status(:completed, :route_converged) == :illegal
    end

    test "the four failure kinds: any non-terminal -> :failed" do
      for kind <- @failed_kinds, status <- [:pending, :running, :awaiting_approval] do
        assert Projection.next_status(status, kind) == {:ok, :failed},
               "expected #{status} -> #{kind} == :failed"
      end

      for kind <- @failed_kinds, status <- [:completed, :failed, :cancelled, :abandoned] do
        assert Projection.next_status(status, kind) == :illegal
      end
    end

    test "route_rejected/route_abandoned: any non-terminal -> :cancelled" do
      for kind <- @cancelled_kinds, status <- [:pending, :running, :awaiting_approval] do
        assert Projection.next_status(status, kind) == {:ok, :cancelled}
      end

      for kind <- @cancelled_kinds do
        assert Projection.next_status(:completed, kind) == :illegal
      end
    end

    test "all seven route terminals are status-authority kinds" do
      for kind <- [:route_converged | @failed_kinds] ++ @cancelled_kinds do
        assert Projection.status_authority?(kind), "#{kind} must be status-authority"
      end

      # The additive/subtractive wave deltas are NOT authority — the parent stays
      # :running across a wave.
      for kind <- [:route_composed, :wave_started, :wave_completed, :signals_published] do
        refute Projection.status_authority?(kind)
      end
    end
  end

  describe "status_attrs/3 (pure)" do
    setup do
      {:ok, occurred_at: DateTime.utc_now()}
    end

    test "route_converged lifts result and clears the checkpoint", %{occurred_at: at} do
      attrs =
        Projection.status_attrs(:route_converged, %{result: %{"terminal" => "converged"}}, at)

      assert attrs == %{
               status: :completed,
               completed_at: at,
               result: %{"terminal" => "converged"},
               clear_checkpoint: true
             }
    end

    test "the four failure kinds lift error and clear the checkpoint", %{occurred_at: at} do
      for kind <- @failed_kinds do
        attrs = Projection.status_attrs(kind, %{error: "boom"}, at)

        assert attrs == %{
                 status: :failed,
                 completed_at: at,
                 error: "boom",
                 clear_checkpoint: true
               }
      end
    end

    test "route_rejected/route_abandoned lift result (disposition survives), not dropped", %{
      occurred_at: at
    } do
      for kind <- @cancelled_kinds do
        attrs = Projection.status_attrs(kind, %{result: %{disposition: "operator_cancel"}}, at)

        assert attrs == %{
                 status: :cancelled,
                 completed_at: at,
                 result: %{disposition: "operator_cancel"},
                 clear_checkpoint: true
               }
      end
    end

    test "status_attrs tolerates string-keyed (JSONB-reloaded) payloads", %{occurred_at: at} do
      assert %{result: %{"ok" => true}} =
               Projection.status_attrs(:route_converged, %{"result" => %{"ok" => true}}, at)

      assert %{error: "boom"} = Projection.status_attrs(:route_failed, %{"error" => "boom"}, at)
    end
  end

  describe "reloaded JSONB string-keyed payload path (the real append txn)" do
    setup do
      tenant = seed_tenant("wfproj")
      actor = actor_for(tenant)

      {:ok, parent} =
        WorkflowRun.create(%{name: "composer", workflow_type: "composer"},
          tenant: tenant,
          actor: actor
        )

      {:ok, _} = WorkflowLog.append(parent, :run_started, %{}, tenant: tenant, actor: actor)
      {:ok, running} = WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor)
      {:ok, tenant: tenant, actor: actor, running: running}
    end

    test "route_converged -> :completed, result column kept, column == fold", ctx do
      {:ok, _} =
        WorkflowLog.append(ctx.running, :route_converged, %{result: %{"terminal" => "converged"}},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      {:ok, done} = WorkflowRun.by_id(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)
      {:ok, events} = WorkflowEvent.for_run(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)

      assert done.status == :completed
      assert done.result["terminal"] == "converged"
      assert Projection.project_status(events) == :completed
    end

    test "route_failed -> :failed, error column kept", ctx do
      {:ok, _} =
        WorkflowLog.append(ctx.running, :route_failed, %{error: "wave blew up"},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      {:ok, failed} = WorkflowRun.by_id(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)
      assert failed.status == :failed
      assert failed.error == "wave blew up"
    end

    test "route_rejected -> :cancelled and the disposition survives onto result", ctx do
      {:ok, _} =
        WorkflowLog.append(
          ctx.running,
          :route_rejected,
          %{result: %{disposition: "rejected_by_operator"}},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      {:ok, cancelled} = WorkflowRun.by_id(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)

      assert cancelled.status == :cancelled
      # The disposition is NOT dropped (unlike a plain run_cancelled) — it survives
      # the JSONB round-trip as a string key.
      assert cancelled.result["disposition"] == "rejected_by_operator"
    end

    test "route_abandoned -> :cancelled with its disposition", ctx do
      {:ok, _} =
        WorkflowLog.append(
          ctx.running,
          :route_abandoned,
          %{result: %{disposition: "abandoned_at_gate"}},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      {:ok, cancelled} = WorkflowRun.by_id(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)
      assert cancelled.status == :cancelled
      assert cancelled.result["disposition"] == "abandoned_at_gate"
    end
  end
end
