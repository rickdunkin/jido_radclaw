defmodule JidoClaw.RouteComposer.CommitTest do
  @moduledoc """
  AR-2 Phase 2c — `Commit.commit_wave/4` welds the `wave_completed` marker, the
  content deltas, and the `ComposerArtifact` `:pending → :active` flip into one
  atomic transaction: refs go `:active` iff `wave_completed` landed, an
  empty-emission wave still marks `wave_completed` (promoting zero rows), a forced
  leg failure rolls back **all**, and an already-terminal parent is refused
  (`{:error, :parent_terminal}`) before any write via the FOR UPDATE reload guard.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer.Commit

  defp ref, do: JidoClaw.Refs.mint("art_")

  setup do
    tenant = seed_tenant("commit")
    actor = actor_for(tenant)

    {:ok, parent} =
      WorkflowRun.create(%{name: "composer", workflow_type: "composer"},
        tenant: tenant,
        actor: actor
      )

    {:ok, _} = WorkflowLog.append(parent, :run_started, %{}, tenant: tenant, actor: actor)
    {:ok, running} = WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor)

    {:ok, child} =
      WorkflowRun.create(%{name: "wave-0", workflow_type: "reactor", parent_run_id: parent.id},
        tenant: tenant,
        actor: actor
      )

    {:ok, tenant: tenant, actor: actor, parent: running, child: child}
  end

  defp opts(ctx), do: [tenant: ctx.tenant, actor: ctx.actor]

  defp store_pending(ctx, attrs) do
    ComposerArtifact.store_pending(
      Map.merge(
        %{
          term: "v",
          child_run_id: ctx.child.id,
          wave_index: 0,
          parent_run_id: ctx.parent.id
        },
        attrs
      ),
      opts(ctx)
    )
  end

  defp kinds(ctx) do
    {:ok, events} = WorkflowEvent.for_run(ctx.parent.id, opts(ctx))
    Enum.map(events, & &1.kind)
  end

  defp state_of(ctx, the_ref) do
    {:ok, row} = ComposerArtifact.resolve_ref(the_ref, opts(ctx))
    row.state
  end

  test "commits wave_completed + content atomically and flips the wave's refs :active", ctx do
    r = ref()
    assert {:ok, _} = store_pending(ctx, %{ref: r, name: "plan", producer: "planner"})

    deltas = %{
      stages: ["planner"],
      signals_published: ["plan-ready"],
      signals_retracted: [],
      artifacts_produced: [%{name: "plan", producer: "planner", ref: r}]
    }

    assert :ok = Commit.commit_wave(ctx.parent, 0, deltas, opts(ctx))

    assert :wave_completed in kinds(ctx)
    assert :signals_published in kinds(ctx)
    assert :artifacts_produced in kinds(ctx)
    # The ref is :active IFF wave_completed landed.
    assert state_of(ctx, r) == :active

    # The wave_completed payload carries the index + stages (string-keyed reload).
    {:ok, events} = WorkflowEvent.for_run(ctx.parent.id, opts(ctx))
    wc = Enum.find(events, &(&1.kind == :wave_completed))
    assert wc.payload["wave_index"] == 0
    assert wc.payload["stages"] == ["planner"]
  end

  test "an empty-emission wave still writes wave_completed and promotes zero rows", ctx do
    deltas = %{
      stages: ["noop-stage"],
      signals_published: [],
      signals_retracted: [],
      artifacts_produced: []
    }

    assert :ok = Commit.commit_wave(ctx.parent, 0, deltas, opts(ctx))

    ks = kinds(ctx)
    assert :wave_completed in ks
    # No content events for an empty-emission wave.
    refute :signals_published in ks
    refute :signals_retracted in ks
    refute :artifacts_produced in ks
  end

  test "a forced leg failure (activate violates the active-key index) rolls back ALL", ctx do
    # Two pendings sharing {name, producer, wave} make activate_for_wave promote
    # both to :active, violating the partial-unique index → the whole commit rolls
    # back: no wave_completed, both rows stay :pending.
    r1 = ref()
    r2 = ref()
    assert {:ok, _} = store_pending(ctx, %{ref: r1, name: "plan", producer: "planner"})
    assert {:ok, _} = store_pending(ctx, %{ref: r2, name: "plan", producer: "planner"})

    deltas = %{
      stages: ["planner"],
      signals_published: ["plan-ready"],
      signals_retracted: [],
      artifacts_produced: []
    }

    assert {:error, _reason} = Commit.commit_wave(ctx.parent, 0, deltas, opts(ctx))

    refute :wave_completed in kinds(ctx)
    refute :signals_published in kinds(ctx)
    assert state_of(ctx, r1) == :pending
    assert state_of(ctx, r2) == :pending
  end

  test "AR-4: welds the hook_markers into the same commit, after wave_completed + content", ctx do
    r = ref()

    assert {:ok, _} =
             store_pending(ctx, %{ref: r, name: "findings", producer: "quality-reviewer"})

    deltas = %{
      stages: ["quality-reviewer"],
      signals_published: ["findings:quality"],
      signals_retracted: [],
      artifacts_produced: [%{name: "findings", producer: "quality-reviewer", ref: r}]
    }

    # The Hook R welded batch: a feedback ref-pointer to the wave's OWN findings
    # (no new row) + a fixer re-fire.
    hook_markers = [
      {:artifacts_produced,
       %{artifacts: [%{name: "review-feedback", producer: "quality-reviewer", ref: r}]}},
      {:stages_invalidated, %{stages: ["fixer"]}}
    ]

    assert :ok = Commit.commit_wave(ctx.parent, 0, deltas, hook_markers, opts(ctx))

    {:ok, events} = WorkflowEvent.for_run(ctx.parent.id, opts(ctx))

    ordered =
      events
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(& &1.kind)

    assert :wave_completed in ordered
    assert :stages_invalidated in ordered
    # Canonical fold order: wave_completed → content → hook markers (stages_invalidated last).
    assert Enum.find_index(ordered, &(&1 == :stages_invalidated)) >
             Enum.find_index(ordered, &(&1 == :wave_completed))

    # The wave's own findings ref is :active; the feedback ref-pointer created no row.
    assert state_of(ctx, r) == :active
  end

  test "AR-4: a forced leg failure rolls back the welded hook_markers too (atomic)", ctx do
    r1 = ref()
    r2 = ref()
    assert {:ok, _} = store_pending(ctx, %{ref: r1, name: "plan", producer: "planner"})
    assert {:ok, _} = store_pending(ctx, %{ref: r2, name: "plan", producer: "planner"})

    deltas = %{
      stages: ["planner"],
      signals_published: [],
      signals_retracted: [],
      artifacts_produced: []
    }

    hook_markers = [{:stages_invalidated, %{stages: ["fixer"]}}]

    # The duplicate {plan, planner, wave 0} pendings make activate_for_wave violate
    # the active-key index → the whole txn (incl. the welded markers) rolls back.
    assert {:error, _reason} = Commit.commit_wave(ctx.parent, 0, deltas, hook_markers, opts(ctx))

    refute :wave_completed in kinds(ctx)
    refute :stages_invalidated in kinds(ctx)
  end

  test "an already-terminal parent is refused before any write (FOR UPDATE guard)", ctx do
    r = ref()
    assert {:ok, _} = store_pending(ctx, %{ref: r, name: "plan", producer: "planner"})

    # Drive the parent terminal out-of-band (an operator cancel landing while a
    # child wave returns is the real race).
    {:ok, _} = WorkflowLog.append(ctx.parent, :route_converged, %{result: %{}}, opts(ctx))
    {:ok, terminal} = WorkflowRun.by_id(ctx.parent.id, opts(ctx))
    assert terminal.status == :completed

    deltas = %{
      stages: ["planner"],
      signals_published: ["plan-ready"],
      signals_retracted: [],
      artifacts_produced: []
    }

    assert {:error, :parent_terminal} = Commit.commit_wave(terminal, 0, deltas, opts(ctx))

    # No wave_completed appended, the ref never promoted.
    refute :wave_completed in kinds(ctx)
    assert state_of(ctx, r) == :pending
  end
end
