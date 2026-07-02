defmodule JidoClaw.Orchestration.GateDispositionTest do
  @moduledoc """
  The fenced gate-disposition primitive: run-lock-first (the global run → case
  → events order), status re-check on the LOCKED row, case cancellations +
  child terminal in one transaction, classified outcomes — so the composer's
  deadline/teardown paths and recovery's janitor branches never hand-roll
  reload/re-check logic and never bulldoze a fenced operator decision.

  Non-async (`TenantCase`): drives real multi-resource transactions in the
  shared sandbox.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.GateDisposition
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    tenant = seed_tenant("gate-dispo")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "deadline_abandon_parked_child/3" do
    test "abandons a parked pair atomically and broadcasts operator-parity resolution", ctx do
      {run, gate} = parked_pair(ctx)
      RunPubSub.subscribe_gates()

      assert {:ok, :disposed} =
               GateDisposition.deadline_abandon_parked_child(run.id, "deadline", scope(ctx))

      assert reload(run.id, ctx).status == :abandoned
      assert :run_abandoned in kinds(run.id, ctx)
      assert case_status(gate.id, ctx) == :cancelled
      assert {:ok, []} = AgentCase.pending_for_run(run.id, tenant: ctx.tenant, actor: ctx.actor)

      # The Cases.abandon-parity broadcast: gate_resolved names the cancelled case.
      run_id = run.id
      gate_id = gate.id

      assert_receive {:gate_resolved, ^run_id, %{agent_case_id: ^gate_id, decision: :abandon}}
    end

    test "a genuinely case-less park still gets its child terminal", ctx do
      run = caseless_parked_run(ctx)

      assert {:ok, :disposed} =
               GateDisposition.deadline_abandon_parked_child(run.id, "deadline", scope(ctx))

      assert reload(run.id, ctx).status == :abandoned
    end

    test "a committed decision wins: classified refusal, nothing written", ctx do
      {run, gate} = parked_pair(ctx)

      assert {:ok, _} = Cases.decide(gate.id, :reject, %{}, scope(ctx))
      assert reload(run.id, ctx).status == :cancelled

      assert {:error, {:decided, :cancelled}} =
               GateDisposition.deadline_abandon_parked_child(run.id, "deadline", scope(ctx))

      # The decision stands untouched — no run_abandoned, case stays decided.
      assert reload(run.id, ctx).status == :cancelled
      refute :run_abandoned in kinds(run.id, ctx)
      assert case_status(gate.id, ctx) == :rejected
    end

    test "an unknown child refuses :not_found", ctx do
      assert {:error, :not_found} =
               GateDisposition.deadline_abandon_parked_child(
                 Ash.UUID.generate(),
                 "deadline",
                 scope(ctx)
               )
    end
  end

  describe "fail_orphaned_parked_child/3" do
    test "fails a parked pair with the run_recovered + run_failed audit trail", ctx do
      {run, gate} = parked_pair(ctx)

      assert {:ok, :disposed} =
               GateDisposition.fail_orphaned_parked_child(run.id, "orphaned", scope(ctx))

      assert reload(run.id, ctx).status == :failed
      ks = kinds(run.id, ctx)
      assert :run_recovered in ks
      assert :run_failed in ks
      assert case_status(gate.id, ctx) == :cancelled
    end

    test "a committed APPROVAL wins: refusal on the post-decision status, case untouched", ctx do
      {run, gate} = parked_pair(ctx)

      # Craft the committed approval durably (a dummy checkpoint can't truly
      # resume): case :approved, child :awaiting_approval → :running.
      {:ok, _} = AgentCase.approve(gate, %{}, scope(ctx))

      {:ok, _} =
        WorkflowLog.append(
          reload(run.id, ctx),
          :approval_resolved,
          %{agent_case_id: gate.id, decision: :approve},
          scope(ctx)
        )

      assert {:error, {:decided, :running}} =
               GateDisposition.fail_orphaned_parked_child(run.id, "orphaned", scope(ctx))

      assert reload(run.id, ctx).status == :running
      refute :run_failed in kinds(run.id, ctx)
      assert case_status(gate.id, ctx) == :approved
    end
  end

  describe "cancel_dangling_gate/3" do
    test "closes a checkpoint-less dangling gate (case + child, atomically)", ctx do
      {run, gate} = dangling_pair(ctx)

      assert {:ok, :disposed} =
               GateDisposition.cancel_dangling_gate(run.id, "dangling", scope(ctx))

      assert reload(run.id, ctx).status == :failed
      assert case_status(gate.id, ctx) == :cancelled
    end
  end

  describe "terminal_composer_parent/3" do
    test ":terminal under a terminal composer parent", ctx do
      parent = composer_parent(ctx)
      {child, _gate} = parked_pair_under(parent, ctx)

      assert GateDisposition.terminal_composer_parent(child, ctx.tenant, ctx.actor) == :terminal
    end

    test ":not_terminal for a nil parent, a live composer parent, and a non-composer parent",
         ctx do
      {parentless, _gate} = parked_pair(ctx)

      assert GateDisposition.terminal_composer_parent(parentless, ctx.tenant, ctx.actor) ==
               :not_terminal

      live = composer_parent(ctx, terminal?: false)
      {under_live, _gate} = parked_pair_under(live, ctx)

      assert GateDisposition.terminal_composer_parent(under_live, ctx.tenant, ctx.actor) ==
               :not_terminal

      # A TERMINAL non-composer parent stays :not_terminal — the predicate
      # discriminates on workflow_type, not status alone.
      reactor_parent = started_run(ctx)
      {:ok, _} = WorkflowLog.append(reactor_parent, :run_failed, %{error: "boom"}, scope(ctx))
      {under_reactor, _gate} = parked_pair_under(reload(reactor_parent.id, ctx), ctx)

      assert GateDisposition.terminal_composer_parent(under_reactor, ctx.tenant, ctx.actor) ==
               :not_terminal
    end

    test "{:error, _} (uncertain, never :not_terminal) when the parent ref is unreadable", ctx do
      {child, _gate} = parked_pair(ctx)

      # In-memory override: the helper only reads by parent_run_id, and the FK
      # (workflow_runs_parent_run_id_fkey) makes a PERSISTED dangling ref
      # impossible — this is the deterministic error-arm seam (`by_id` surfaces
      # a NotFound error). It also covers approve's fail-closed mapping's
      # end-to-end-unreachable-with-real-rows case (Cases maps any {:error, _}
      # to :parent_state_unknown).
      dangling = %{child | parent_run_id: Ash.UUID.generate()}

      assert {:error, _reason} =
               GateDisposition.terminal_composer_parent(dangling, ctx.tenant, ctx.actor)
    end
  end

  describe "Cases.decide(:approve) refusal under a terminal composer parent" do
    test "approve refuses :parent_terminal untouched; reject still converges the pair", ctx do
      parent = composer_parent(ctx)
      {child, gate} = parked_pair_under(parent, ctx)

      assert {:error, :parent_terminal} = Cases.decide(gate.id, :approve, %{}, scope(ctx))

      # Nothing moved: the pair is still parked + pending, nothing resumed.
      assert reload(child.id, ctx).status == :awaiting_approval
      assert case_status(gate.id, ctx) == :pending
      refute :approval_resolved in kinds(child.id, ctx)

      # Converging decisions stay allowed: reject closes the pair.
      assert {:ok, _run} = Cases.decide(gate.id, :reject, %{}, scope(ctx))
      assert reload(child.id, ctx).status == :cancelled
      assert case_status(gate.id, ctx) == :rejected
    end
  end

  defp scope(ctx), do: [tenant: ctx.tenant, actor: ctx.actor]

  # A parked gate pair: an `:awaiting_approval` child (dummy checkpoint, so
  # `Cases.decide`'s guard_resumable passes) with a pending `:plan` case — the
  # composer's craft_gate_child shape, standalone. `extra_attrs` merge into the
  # child's create (e.g. `parent_run_id`).
  defp parked_pair(ctx, extra_attrs \\ %{}) do
    {run, gate} = dangling_pair(ctx, extra_attrs)

    {:ok, _} =
      WorkflowRun.set_checkpoint(
        run,
        %{resume_checkpoint: :erlang.term_to_binary(:cp)},
        scope(ctx)
      )

    {reload(run.id, ctx), gate}
  end

  # `parked_pair/2` with the child linked under `parent` — the composer's
  # parent-child lineage, for the terminal-parent predicate + approve refusal.
  defp parked_pair_under(parent, ctx), do: parked_pair(ctx, %{parent_run_id: parent.id})

  # A composer parent, `:running` by default or terminal (`route_abandoned` →
  # `:cancelled`) unless `terminal?: false`.
  defp composer_parent(ctx, opts \\ []) do
    {:ok, parent} = WorkflowRun.create(%{name: "route", workflow_type: "composer"}, scope(ctx))
    {:ok, _} = WorkflowLog.append(parent, :run_started, %{}, scope(ctx))

    if Keyword.get(opts, :terminal?, true) do
      {:ok, _} =
        WorkflowLog.append(reload(parent.id, ctx), :route_abandoned, %{reason: "ttl"}, scope(ctx))
    end

    reload(parent.id, ctx)
  end

  # The dangling shape: `:awaiting_approval` + pending case, NO checkpoint.
  defp dangling_pair(ctx, extra_attrs \\ %{}) do
    run = started_run(ctx, extra_attrs)

    {:ok, gate} =
      WorkflowLog.gate_open(
        run,
        %{
          workflow_run_id: run.id,
          step_name: "plan-gate",
          kind: :plan,
          gate_module: JidoClaw.Gates.PlanGate,
          details: %{}
        },
        scope(ctx)
      )

    {reload(run.id, ctx), gate}
  end

  # The recovered case-less edge: `:awaiting_approval` via approval_requested
  # alone — no case row ever existed.
  defp caseless_parked_run(ctx) do
    run = started_run(ctx)
    {:ok, _} = WorkflowLog.append(run, :approval_requested, %{}, scope(ctx))
    reload(run.id, ctx)
  end

  defp started_run(ctx, extra_attrs \\ %{}) do
    attrs = Map.merge(%{name: "gated", workflow_type: "reactor"}, extra_attrs)
    {:ok, run} = WorkflowRun.create(attrs, scope(ctx))
    {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))
    reload(run.id, ctx)
  end

  defp reload(id, ctx) do
    {:ok, run} = WorkflowRun.by_id(id, scope(ctx))
    run
  end

  defp case_status(case_id, ctx) do
    {:ok, agent_case} = AgentCase.by_id(case_id, scope(ctx))
    agent_case.status
  end

  defp kinds(run_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(run_id, scope(ctx))
    Enum.map(events, & &1.kind)
  end
end
