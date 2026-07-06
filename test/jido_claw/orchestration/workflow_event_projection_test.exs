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

    test "all route terminals (incl. AR-8c verify_failed + AR-4 fix_failed) are status-authority kinds" do
      for kind <-
            [:route_converged, :route_verify_failed, :route_fix_failed | @failed_kinds] ++
              @cancelled_kinds do
        assert Projection.status_authority?(kind), "#{kind} must be status-authority"
      end

      # The additive/subtractive wave deltas are NOT authority — the parent stays
      # :running across a wave.
      for kind <- [:route_composed, :wave_started, :wave_completed, :signals_published] do
        refute Projection.status_authority?(kind)
      end
    end

    test "AR-8c route_verify_failed: any non-terminal -> :failed, terminal -> :illegal" do
      for status <- [:pending, :running, :awaiting_approval] do
        assert Projection.next_status(status, :route_verify_failed) == {:ok, :failed}
      end

      for status <- [:completed, :failed, :cancelled, :abandoned] do
        assert Projection.next_status(status, :route_verify_failed) == :illegal
      end
    end

    test "AR-4 route_fix_failed: any non-terminal -> :failed, terminal -> :illegal" do
      for status <- [:pending, :running, :awaiting_approval] do
        assert Projection.next_status(status, :route_fix_failed) == {:ok, :failed}
      end

      for status <- [:completed, :failed, :cancelled, :abandoned] do
        assert Projection.next_status(status, :route_fix_failed) == :illegal
      end
    end

    test "camus C1-3 route_review_infra_failed: any non-terminal -> :failed, terminal -> :illegal" do
      assert Projection.status_authority?(:route_review_infra_failed)

      for status <- [:pending, :running, :awaiting_approval] do
        assert Projection.next_status(status, :route_review_infra_failed) == {:ok, :failed}
      end

      for status <- [:completed, :failed, :cancelled, :abandoned] do
        assert Projection.next_status(status, :route_review_infra_failed) == :illegal
      end
    end

    test "camus C1-4 route_done_with_findings: :running -> :completed ONLY (the route_converged shape)" do
      assert Projection.status_authority?(:route_done_with_findings)
      assert Projection.next_status(:running, :route_done_with_findings) == {:ok, :completed}

      # The composer parent stays :running for the whole route INCLUDING the
      # stall park — there is no :awaiting_approval leg on this axis, and
      # :pending never composed anything worth releasing.
      for status <- [:pending, :awaiting_approval, :completed, :failed, :cancelled, :abandoned] do
        assert Projection.next_status(status, :route_done_with_findings) == :illegal
      end
    end
  end

  describe "OH1-3: terminals are absorbing (exhaustive transition table)" do
    # Every status-authority kind, enumerated here as the test's own drift
    # guard: each entry is asserted status-authority (an entry that stops
    # being one fails loudly), and `Projection.status_authority?/1` over this
    # grid is what the append path consults — so a NEW authority kind that
    # forgets its next_status clause still can never revive a terminal run
    # (the catch-all is :illegal), and this table documents that invariant.
    @authority_kinds [
      :run_started,
      :run_resumed,
      :run_completed,
      :run_failed,
      :run_cancelled,
      :run_abandoned,
      :approval_requested,
      :approval_resolved,
      :route_converged,
      :route_done_with_findings,
      :route_not_converged,
      :route_deadlocked,
      :route_budget_exhausted,
      :route_failed,
      :route_verify_failed,
      :route_fix_failed,
      :route_review_infra_failed,
      :route_verify_tampered,
      :route_rejected,
      :route_abandoned
    ]

    test "every terminal status × every status-authority kind is :illegal" do
      for kind <- @authority_kinds do
        assert Projection.status_authority?(kind), "#{kind} must be status-authority"
      end

      for terminal <- Projection.terminal_statuses(), kind <- @authority_kinds do
        assert Projection.next_status(terminal, kind) == :illegal,
               "terminal #{terminal} must absorb #{kind}"
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

    test "camus C1-4 route_done_with_findings lifts result — the first completed-with-disposition",
         %{occurred_at: at} do
      result = %{
        "disposition" => "done_with_findings",
        "finding_keys" => ["abc"],
        "findings_deferred_count" => 1
      }

      attrs = Projection.status_attrs(:route_done_with_findings, %{result: result}, at)

      assert attrs == %{
               status: :completed,
               completed_at: at,
               result: result,
               clear_checkpoint: true
             }
    end

    test "AR-8c route_verify_failed lifts BOTH error and result (atom-keyed)", %{occurred_at: at} do
      attrs =
        Projection.status_attrs(
          :route_verify_failed,
          %{error: "verify_failed: lenses=system", result: %{disposition: "verify_failed"}},
          at
        )

      assert attrs == %{
               status: :failed,
               completed_at: at,
               error: "verify_failed: lenses=system",
               result: %{disposition: "verify_failed"},
               clear_checkpoint: true
             }
    end

    test "AR-8c route_verify_failed tolerates string-keyed (JSONB-reloaded) payload", %{
      occurred_at: at
    } do
      attrs =
        Projection.status_attrs(
          :route_verify_failed,
          %{"error" => "boom", "result" => %{"disposition" => "verify_failed"}},
          at
        )

      assert attrs.status == :failed
      assert attrs.error == "boom"
      assert attrs.result == %{"disposition" => "verify_failed"}
    end

    test "AR-4 route_fix_failed lifts BOTH error and result (atom-keyed)", %{occurred_at: at} do
      attrs =
        Projection.status_attrs(
          :route_fix_failed,
          %{error: "fix_failed: lenses=quality", result: %{disposition: "fix_failed"}},
          at
        )

      assert attrs == %{
               status: :failed,
               completed_at: at,
               error: "fix_failed: lenses=quality",
               result: %{disposition: "fix_failed"},
               clear_checkpoint: true
             }
    end

    test "AR-4 route_fix_failed tolerates string-keyed (JSONB-reloaded) payload", %{
      occurred_at: at
    } do
      attrs =
        Projection.status_attrs(
          :route_fix_failed,
          %{"error" => "boom", "result" => %{"disposition" => "fix_failed"}},
          at
        )

      assert attrs.status == :failed
      assert attrs.error == "boom"
      assert attrs.result == %{"disposition" => "fix_failed"}
    end

    # Camus C1-3 — the exact spot where verify/fix_failed needed careful clause
    # ordering vs `@route_failed_kinds`: the explicit clause must lift BOTH
    # `error` and `result.disposition` (the error-only family clause would
    # shadow it if the kind ever joined `@route_failed_kinds`).
    test "camus C1-3 route_review_infra_failed lifts BOTH error and result (atom-keyed)", %{
      occurred_at: at
    } do
      attrs =
        Projection.status_attrs(
          :route_review_infra_failed,
          %{
            error: "review_infra_failed: stages=quality-reviewer",
            result: %{disposition: "review_infra_failed"}
          },
          at
        )

      assert attrs == %{
               status: :failed,
               completed_at: at,
               error: "review_infra_failed: stages=quality-reviewer",
               result: %{disposition: "review_infra_failed"},
               clear_checkpoint: true
             }
    end

    test "camus C1-3 route_review_infra_failed tolerates string-keyed (JSONB-reloaded) payload",
         %{occurred_at: at} do
      attrs =
        Projection.status_attrs(
          :route_review_infra_failed,
          %{"error" => "boom", "result" => %{"disposition" => "review_infra_failed"}},
          at
        )

      assert attrs.status == :failed
      assert attrs.error == "boom"
      assert attrs.result == %{"disposition" => "review_infra_failed"}
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

    test "AR-8c route_verify_failed -> :failed AND result.disposition survives", ctx do
      {:ok, _} =
        WorkflowLog.append(
          ctx.running,
          :route_verify_failed,
          %{
            error: "verify_failed: lenses=system",
            result: %{disposition: "verify_failed"}
          },
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      {:ok, failed} = WorkflowRun.by_id(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)
      {:ok, events} = WorkflowEvent.for_run(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)

      # The novel `:failed`-WITH-disposition combination: status is :failed (like a
      # generic failure) but the operator query keys on the surviving disposition.
      assert failed.status == :failed
      assert failed.error == "verify_failed: lenses=system"
      assert failed.result["disposition"] == "verify_failed"
      assert Projection.project_status(events) == :failed
    end

    test "AR-4 route_fix_failed -> :failed AND result.disposition survives", ctx do
      {:ok, _} =
        WorkflowLog.append(
          ctx.running,
          :route_fix_failed,
          %{
            error: "fix_failed: lenses=quality",
            result: %{disposition: "fix_failed"}
          },
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      {:ok, failed} = WorkflowRun.by_id(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)
      {:ok, events} = WorkflowEvent.for_run(ctx.running.id, tenant: ctx.tenant, actor: ctx.actor)

      # The self-heal twin of verify_failed: :failed status, but the disposition
      # `"fix_failed"` survives so the operator tells the two apart.
      assert failed.status == :failed
      assert failed.error == "fix_failed: lenses=quality"
      assert failed.result["disposition"] == "fix_failed"
      assert Projection.project_status(events) == :failed
    end
  end
end
