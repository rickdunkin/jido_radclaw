defmodule JidoClaw.Orchestration.HumanGatesTest do
  @moduledoc """
  The Phase 2 "done" matrix: durable halt → persist → restart → resume for one
  gate kind (`:irreversible_write`), end to end.

  Drives the keystone `GatedTestReactor` (pure pre-gate step → `GateStep` →
  post-gate `Workspace` create) through `ReactorRunner`, then exercises
  approve/reject via `Cases.decide/4` and the boot-recovery branches via
  `WorkflowRecovery.reconcile_all/0` (boot recovery is disabled in test, so it
  is driven directly inside the sandbox).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    TestIrreversibleWrite.reset()
    tenant = seed_tenant("gates")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "happy path: halt → approve → resume → complete" do
    test "pauses with a durable checkpoint, then resumes to completion", ctx do
      %{tenant: tenant, actor: actor} = ctx
      {result, inputs} = run_gated(tenant, actor)

      assert {:ok, {:paused, case_id}, run} = result
      assert run.status == :awaiting_approval
      assert is_binary(run.encrypted_resume_checkpoint)

      # The pre-decision timeline, in seq order.
      kinds = kinds(run, ctx)
      assert List.first(kinds) == :run_started
      assert Enum.count(kinds, &(&1 == :run_started)) == 1
      assert :approval_requested in kinds
      # run_halted is the final pre-decision event (last index).
      assert index_of(kinds, :run_halted) == length(kinds) - 1
      assert index_of(kinds, :approval_requested) < index_of(kinds, :run_halted)
      assert Enum.any?(kinds, &(&1 in [:step_started, :step_completed]))

      # Approve → resume runs the durable downstream write.
      assert {:ok, completed} = Cases.decide(case_id, :approve, %{}, scope(ctx))
      assert completed.status == :completed
      assert is_nil(completed.encrypted_resume_checkpoint)

      after_kinds = kinds(completed, ctx)
      assert :run_resumed in after_kinds
      assert :approval_resolved in after_kinds
      # Resume appends run_resumed, NOT a second run_started.
      assert Enum.count(after_kinds, &(&1 == :run_started)) == 1
      assert index_of(after_kinds, :run_completed) == length(after_kinds) - 1

      assert workspace_exists?(inputs.workspace_path, ctx)
      # The hook now runs on an isolated supervised task, so the marker is set
      # asynchronously — poll rather than read immediately after decide returns.
      assert eventually(fn -> TestIrreversibleWrite.approved?(case_id) end)
    end
  end

  describe "async hook isolation (Fix 1): a misbehaving hook never strands the decision" do
    # The hook crashes (an `exit`), so its supervised task logs/dies — capture
    # that noise; the load-bearing assertion is that resume still completes.
    @tag :capture_log
    test "a crashing after_approved hook still completes the resume", ctx do
      {result, inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      # `:exit` (NOT `:raise`): the old bare `rescue` already caught a raise, so
      # a raising hook passed before this fix and proved nothing. An `exit`
      # propagated out of the *synchronous* old path and skipped resume; the new
      # async path captures it off the critical path.
      TestIrreversibleWrite.set_behavior(:exit)

      assert {:ok, completed} = Cases.decide(case_id, :approve, %{}, scope(ctx))
      assert completed.status == :completed
      assert is_nil(completed.encrypted_resume_checkpoint)
      assert workspace_exists?(inputs.workspace_path, ctx)
    end

    @tag :capture_log
    test "a hung after_approved hook never blocks the decision", ctx do
      # Shrink the bounded timeout so the hung hook task is reaped fast, not 30s.
      put_gate_hook_timeout(100)

      {result, inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      TestIrreversibleWrite.set_behavior(:hang)

      # decide returns on the synchronous resume; it never waits on the hook.
      assert {:ok, completed} = Cases.decide(case_id, :approve, %{}, scope(ctx))
      assert completed.status == :completed
      assert is_nil(completed.encrypted_resume_checkpoint)
      assert workspace_exists?(inputs.workspace_path, ctx)
    end
  end

  describe "reject: cancels the run, no downstream write" do
    test "rejecting cancels and leaves nothing orphaned", ctx do
      {result, inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      assert {:ok, cancelled} = Cases.decide(case_id, :reject, %{}, scope(ctx))
      assert cancelled.status == :cancelled
      assert is_nil(cancelled.encrypted_resume_checkpoint)

      kinds = kinds(cancelled, ctx)
      assert :run_cancelled in kinds
      refute :approval_resolved in kinds

      refute workspace_exists?(inputs.workspace_path, ctx)
      assert eventually(fn -> TestIrreversibleWrite.rejected?(case_id) end)
    end
  end

  describe "recovery branches" do
    test "parked gate (awaiting + checkpoint) survives recovery untouched", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, run} = result
      kinds_before = kinds(run, ctx)

      assert :ok = WorkflowRecovery.reconcile_all()

      reloaded = reload(run, ctx)
      assert reloaded.status == :awaiting_approval
      assert is_binary(reloaded.encrypted_resume_checkpoint)
      assert {:ok, %AgentCase{status: :pending}} = AgentCase.by_id(case_id, scope(ctx))

      # Negative invariants: recovery must not have touched the parked run's
      # log — no new run_failed / approval_resolved (or any event at all).
      kinds_after = kinds(reloaded, ctx)
      assert kinds_after == kinds_before
      refute :run_failed in kinds_after
      refute :approval_resolved in kinds_after
    end

    test "parked gate with a missing pending case is cancelled on recovery", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, run} = result

      # The run stays :awaiting_approval + checkpoint, but its inbox row is gone
      # — it can never be decided, so the parked branch must reap it (Fix 2).
      {:ok, agent_case} = AgentCase.by_id(case_id, scope(ctx))
      destroy_case!(agent_case, ctx.tenant)

      assert :ok = WorkflowRecovery.reconcile_all()

      cancelled = reload(run, ctx)
      assert cancelled.status == :cancelled
      assert :run_cancelled in kinds(cancelled, ctx)
      assert is_nil(cancelled.encrypted_resume_checkpoint)
    end

    test "dangling gate (awaiting + no checkpoint) fails with full audit on recovery", ctx do
      %{tenant: tenant, actor: actor} = ctx
      {run, gate} = open_gate_without_checkpoint(tenant, actor)

      assert reload(run, ctx).status == :awaiting_approval
      assert is_nil(reload(run, ctx).encrypted_resume_checkpoint)

      assert :ok = WorkflowRecovery.reconcile_all()

      # Decision 3: a crash-reaped gate is a FAILURE with the full recovery
      # audit pair — not an operator-style cancel.
      failed = reload(run, ctx)
      assert failed.status == :failed
      failed_kinds = kinds(failed, ctx)
      assert :run_recovered in failed_kinds
      assert :run_failed in failed_kinds
      refute :run_cancelled in failed_kinds

      assert {:ok, %AgentCase{status: :cancelled, cancellation_reason: reason}} =
               AgentCase.by_id(gate.id, scope(ctx))

      assert reason =~ "dangling gate"

      # The case timeline records the cancel in the same transaction.
      assert {:ok, case_events} = AgentCaseEvent.for_case(gate.id, scope(ctx))
      assert Enum.any?(case_events, &(&1.type == :cancelled))
    end

    test "decision-already-recorded resumes on boot (hook NOT re-run)", ctx do
      %{tenant: tenant, actor: actor} = ctx
      {result, inputs} = run_gated(tenant, actor)
      assert {:ok, {:paused, case_id}, run} = result

      # Drive approve to the approval_resolved commit, but skip the resume —
      # the commit-only seam (resume: false).
      assert {:ok, _run} =
               Cases.decide(case_id, :approve, %{}, Keyword.put(scope(ctx), :resume, false))

      running = reload(run, ctx)
      assert running.status == :running
      assert is_binary(running.encrypted_resume_checkpoint)

      assert :ok = WorkflowRecovery.reconcile_all()

      completed = reload(run, ctx)
      assert completed.status == :completed
      assert is_nil(completed.encrypted_resume_checkpoint)
      assert :run_resumed in kinds(completed, ctx)
      assert workspace_exists?(inputs.workspace_path, ctx)
    end

    test "forbidden :running + checkpoint + NO decision fails with audit, never resumes", ctx do
      %{tenant: tenant, actor: actor} = ctx
      {result, inputs} = run_gated(tenant, actor)
      assert {:ok, {:paused, _case_id}, run} = result

      # Corrupt the pair by hand: flip the run to :running with NO
      # approval_resolved in the log (bypassing the projection guard via the
      # private :set_status action, exactly what a bug/corruption would do).
      {:ok, parked} = WorkflowRun.by_id(run.id, scope(ctx))

      {:ok, _} =
        parked
        |> Ash.Changeset.for_update(:set_status, %{status: :running},
          tenant: tenant,
          authorize?: false
        )
        |> Ash.update()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = WorkflowRecovery.reconcile_all()
        end)

      assert log =~ "no approval_resolved"

      failed = reload(run, ctx)
      assert failed.status == :failed
      failed_kinds = kinds(failed, ctx)
      assert :run_recovered in failed_kinds
      assert :run_failed in failed_kinds
      # Never blind-resumed past the gate: no resume event, no downstream write.
      refute :run_resumed in failed_kinds
      refute workspace_exists?(inputs.workspace_path, ctx)
    end

    test "a non-gate halt (run not :awaiting_approval) fails with audit", ctx do
      %{tenant: tenant, actor: actor} = ctx

      {:ok, run} =
        WorkflowRun.create(%{name: "halt-#{System.unique_integer([:positive])}"},
          tenant: tenant,
          actor: actor
        )

      {:ok, _} = WorkflowLog.append(run, :run_started, %{}, scope(ctx))

      result =
        ReactorRunner.finalize({:halted, %{stub: true}}, run,
          tenant: tenant,
          actor: actor,
          inputs: %{},
          reactor_module: GatedTestReactor
        )

      assert {:error, :unexpected_halt, failed} = result
      assert failed.status == :failed
      assert :run_failed in kinds(failed, ctx)
    end
  end

  describe "gate-pause failure cleanup (Fix 3)" do
    test "terminate_cancelling_cases fails the run and cancels its pending case atomically",
         ctx do
      %{tenant: tenant, actor: actor} = ctx
      {run, gate} = open_gate_without_checkpoint(tenant, actor)

      assert {:ok, _event} =
               WorkflowLog.terminate_cancelling_cases(
                 run,
                 [{:run_failed, %{error: "boom"}}],
                 "gate pause failed",
                 scope(ctx)
               )

      failed = reload(run, ctx)
      assert failed.status == :failed
      assert is_nil(failed.encrypted_resume_checkpoint)

      assert {:ok, %AgentCase{status: :cancelled, cancellation_reason: "gate pause failed"}} =
               AgentCase.by_id(gate.id, scope(ctx))
    end

    test "a gate pause that loses its pending case fails the run with no stale inbox row", ctx do
      %{tenant: tenant, actor: actor} = ctx
      {run, gate} = open_gate_without_checkpoint(tenant, actor)

      # The pending case vanishes before finalize captures it.
      {:ok, agent_case} = AgentCase.by_id(gate.id, scope(ctx))
      destroy_case!(agent_case, tenant)

      result =
        ReactorRunner.finalize({:halted, %{stub: true}}, run,
          tenant: tenant,
          actor: actor,
          inputs: %{},
          reactor_module: GatedTestReactor
        )

      assert {:error, {:gate_pause_failed, :pending_case_missing}, failed} = result
      assert failed.status == :failed
      assert is_nil(failed.encrypted_resume_checkpoint)
      # No stale :pending row left behind in the operator inbox.
      assert {:ok, []} = AgentCase.pending_for_run(run.id, scope(ctx))
    end
  end

  describe "guards and invariants" do
    test "approve before the checkpoint exists is rejected (case stays pending)", ctx do
      %{tenant: tenant, actor: actor} = ctx
      {_run, gate} = open_gate_without_checkpoint(tenant, actor)

      assert {:error, :not_yet_resumable} = Cases.decide(gate.id, :approve, %{}, scope(ctx))
      assert {:ok, %AgentCase{status: :pending}} = AgentCase.by_id(gate.id, scope(ctx))
    end

    test "the persisted halted reactor round-trips through term_to_binary/[:safe]", ctx do
      {result, inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, _id}, run} = result

      # The stored column is ciphertext (WS9): the raw bytes must NOT decode
      # as the envelope. Only the AshCloak calculation decrypts to the blob.
      assert is_binary(run.encrypted_resume_checkpoint)

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_term(run.encrypted_resume_checkpoint, [:safe])
      end

      {:ok, loaded} = Ash.load(run, :resume_checkpoint, scope(ctx))
      blob = loaded.resume_checkpoint
      assert is_binary(blob)

      # Two-stage decode of the real checkpoint envelope (see GateResume).
      assert {1, module_string, inner} = :erlang.binary_to_term(blob, [:safe])
      assert module_string == "Elixir.JidoClaw.Orchestration.Reactors.GatedTestReactor"
      assert Code.ensure_loaded?(String.to_existing_atom(module_string))

      assert {reactor, decoded_inputs} = :erlang.binary_to_term(inner, [:safe])
      assert reactor.state == :halted
      assert decoded_inputs == inputs
      # CAVEAT: a same-VM round-trip does not prove cross-boot atom/module
      # availability; the real guard is the versioned envelope +
      # Code.ensure_loaded? in GateResume. A separate-BEAM resume is a follow-up.
    end

    test "tenant B cannot read tenant A's pending case", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, case_id}, _run} = result

      tenant_b = seed_tenant("gates-b")
      actor_b = actor_for(tenant_b)

      assert {:ok, []} = AgentCase.pending_for_tenant(tenant: tenant_b, actor: actor_b)
      # A cross-tenant by_id is filtered out → NotFound (not visible to B).
      assert {:error, _not_found} = AgentCase.by_id(case_id, tenant: tenant_b, actor: actor_b)
    end

    test "run_completed from :awaiting_approval is an illegal move", ctx do
      {result, _inputs} = run_gated(ctx.tenant, ctx.actor)
      assert {:ok, {:paused, _id}, run} = result

      assert {:error, _reason} =
               WorkflowLog.append(run, :run_completed, %{}, scope(ctx))

      assert reload(run, ctx).status == :awaiting_approval
    end

    test "a duplicate/concurrent decision loses cleanly (no second status event)", ctx do
      %{tenant: tenant, actor: actor} = ctx
      {result, _inputs} = run_gated(tenant, actor)
      assert {:ok, {:paused, case_id}, run} = result

      assert {:ok, _completed} = Cases.decide(case_id, :approve, %{}, scope(ctx))
      events_after_first = event_count(run, ctx)

      # A second decide (approve OR reject) loses cleanly: post-resume the run's
      # checkpoint is cleared, so `guard_resumable` refuses it before any
      # commit. (The concurrent stale-load race — two deciders both seeing
      # :pending — is fenced separately by the FOR UPDATE reload-and-recheck in
      # `Cases`; see the concurrent test below.)
      assert {:error, _} = Cases.decide(case_id, :reject, %{}, scope(ctx))
      assert {:ok, %AgentCase{status: :approved}} = AgentCase.by_id(case_id, scope(ctx))
      assert event_count(run, ctx) == events_after_first
    end

    test "concurrent approve (no resume) vs reject resolves to one winner, one decision event",
         ctx do
      %{tenant: tenant, actor: actor} = ctx

      # Race two stale-loaded deciders on one gated run's pending case. Approve
      # runs with `resume: false` to isolate the decision fence from GateResume:
      # both deciders load the case `:pending` + the run `:awaiting_approval`
      # with a checkpoint, pass `guard_resumable`, then collide in the commit.
      # The run -> case lock order (lock_run before lock_case) is exercised here.
      # Loop so the stale-load interleaving is reliably hit at least once.
      for _ <- 1..8 do
        {result, _inputs} = run_gated(tenant, actor)
        assert {:ok, {:paused, case_id}, run} = result

        approve_opts = Keyword.put(scope(ctx), :resume, false)

        results =
          Task.await_many([
            Task.async(fn -> Cases.decide(case_id, :approve, %{}, approve_opts) end),
            Task.async(fn -> Cases.decide(case_id, :reject, %{}, scope(ctx)) end)
          ])

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1,
               "expected exactly one {:ok}, got: #{inspect(results)}"

        assert Enum.count(results, &match?({:error, _}, &1)) == 1,
               "expected exactly one {:error}, got: #{inspect(results)}"

        # The AgentCase reflects the winner.
        {:ok, decided} = AgentCase.by_id(case_id, scope(ctx))
        assert decided.status in [:approved, :rejected]

        # Exactly one new decision WorkflowEvent — approval_resolved XOR
        # run_cancelled — matching the winner (never both, as a lost race would
        # append).
        decision_kinds =
          Enum.filter(kinds(run, ctx), &(&1 in [:approval_resolved, :run_cancelled]))

        expected_kind = %{approved: :approval_resolved, rejected: :run_cancelled}[decided.status]
        assert decision_kinds == [expected_kind]
      end
    end
  end

  # -- Helpers --

  defp run_gated(tenant, actor) do
    uniq = System.unique_integer([:positive])
    inputs = %{workspace_name: "gated-ws-#{uniq}", workspace_path: "/tmp/gated-ws-#{uniq}"}
    {ReactorRunner.run(GatedTestReactor, inputs, tenant: tenant, actor: actor), inputs}
  end

  # Open a gate directly (no reactor, no checkpoint) to simulate a crash between
  # the gate_open commit and checkpoint persist.
  defp open_gate_without_checkpoint(tenant, actor) do
    {:ok, run} =
      WorkflowRun.create(%{name: "dangling-#{System.unique_integer([:positive])}"},
        tenant: tenant,
        actor: actor
      )

    {:ok, _} = WorkflowLog.append(run, :run_started, %{}, tenant: tenant, actor: actor)
    {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor)

    {:ok, gate} =
      WorkflowLog.gate_open(
        running,
        %{
          workflow_run_id: running.id,
          step_name: "approval_gate",
          kind: :irreversible_write,
          gate_module: TestIrreversibleWrite,
          details: %{}
        },
        tenant: tenant,
        actor: actor
      )

    {running, gate}
  end

  # Poll `fun` until it returns truthy or `timeout` ms elapse. Used for the
  # async gate hook, whose marker is set off the decision/resume critical path.
  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        poll(fun, deadline)
    end
  end

  # Override the gate hook timeout for the duration of one test, restoring it
  # (or clearing it) afterward.
  defp put_gate_hook_timeout(ms) do
    prev = Application.get_env(:jido_claw, :gate_hook_timeout)
    Application.put_env(:jido_claw, :gate_hook_timeout, ms)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:jido_claw, :gate_hook_timeout)
        _ -> Application.put_env(:jido_claw, :gate_hook_timeout, prev)
      end
    end)
  end

  # Simulate a vanished/corrupt inbox row. The append-only AgentCaseEvent has
  # no destroy action by design, so its rows (FK children) are removed with a
  # raw delete before the case row itself.
  defp destroy_case!(agent_case, tenant) do
    import Ecto.Query

    JidoClaw.Repo.delete_all(
      from(e in JidoClaw.Orchestration.AgentCaseEvent, where: e.agent_case_id == ^agent_case.id)
    )

    Ash.destroy!(agent_case, tenant: tenant, authorize?: false)
  end

  defp scope(%{tenant: tenant, actor: actor}), do: [tenant: tenant, actor: actor]

  defp reload(run, ctx) do
    {:ok, reloaded} = WorkflowRun.by_id(run.id, scope(ctx))
    reloaded
  end

  defp kinds(run, ctx) do
    {:ok, events} = WorkflowEvent.for_run(run.id, scope(ctx))
    Enum.map(events, & &1.kind)
  end

  defp event_count(run, ctx) do
    {:ok, events} = WorkflowEvent.for_run(run.id, scope(ctx))
    length(events)
  end

  defp index_of(list, value), do: Enum.find_index(list, &(&1 == value))

  defp workspace_exists?(path, ctx) do
    case Workspace.by_path(nil, path, scope(ctx)) do
      {:ok, %Workspace{}} -> true
      _ -> false
    end
  end
end
