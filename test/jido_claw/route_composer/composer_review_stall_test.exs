defmodule JidoClaw.RouteComposer.ComposerReviewStallTest do
  @moduledoc """
  Camus C1-4 (next-ten #6) — the review-stall gate end-to-end through the real
  composer (stub workers + the hermetic verify stub): a fix-loop stop with a
  GREEN, CERTIFIED verify parks child-less on a run-bound `:review_stall` case
  (the parent stays `:running`), approve-all-waived completes the run
  `:route_done_with_findings`, reject keeps today's `fix_failed`, abandon takes
  `:route_abandoned` with NO `run_abandoned` event, the raise is idempotent by
  fingerprint across restarts, and the sensitive-run stall-park deadline
  auto-abandons.

  Non-async (`TenantCase`): mutates global app env + the singleton
  Registry/DynamicSupervisor, and runs async Reactor steps under a shared
  sandbox.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.SystemLoopWorker

  @supervisor JidoClaw.RouteComposer.Supervisor
  @registry JidoClaw.RouteComposer.Registry

  # The fixture reviewer's stable stuck finding (fixtures.ex
  # `phase1_findings_reviewer/1`) → its FindingKey identity, asserted by shape
  # only (64 hex chars) — the exact digest is FindingKey's contract, not ours.
  @hex64 ~r/^[0-9a-f]{64}$/

  setup do
    StubStore.setup()
    previous_server = Application.get_env(:jido_claw, :step_agent_server)

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      TestFixtures.phase1_template_override(SystemLoopWorker)
    )

    Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)

    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.self_heal_stub_outputs()
    )

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :route_composer_stub_outputs)
      Application.delete_env(:jido_claw, :route_composer_review_flag_on)
      Application.delete_env(:jido_claw, :route_composer_review_finding_on)
      Application.delete_env(:jido_claw, :route_composer_verify_stub)

      case previous_server do
        nil -> Application.delete_env(:jido_claw, :step_agent_server)
        mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
      end

      for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor) do
        DynamicSupervisor.terminate_child(@supervisor, pid)
      end
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "revstall")

    context = %{
      tenant_id: tenant,
      session_id: "revstall-sess",
      session_uuid: session.id,
      workspace_id: "revstall-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, actor: actor_for(tenant), context: context}
  end

  describe "stall + green certified verify → the review-stall gate" do
    test "parks run-bound (parent stays :running, no approval_requested); approve-all-waived → :route_done_with_findings",
         ctx do
      stall_quality()
      RunPubSub.subscribe_gates()
      task = run_task(ctx)

      # The raise broadcasts the PARENT's own id (child-less park).
      assert_receive {:gate_requested, parent_id, %{agent_case_id: case_id}}, 20_000

      # Park shape: the parent STAYS :running — no approval_requested, no
      # wave_paused; the pending case row is the durable park representation.
      assert reload(parent_id, ctx).status == :running
      ks = kinds(parent_id, ctx)
      refute :approval_requested in ks
      refute :wave_paused in ks

      {:ok, gate} = AgentCase.by_id(case_id, auth(ctx))
      assert gate.kind == :review_stall
      assert gate.status == :pending
      assert gate.workflow_run_id == parent_id
      assert gate.step_name == "review-stall"
      assert gate.fingerprint =~ @hex64

      # Details: gate presentation merged (this path bypasses GateStep) + the
      # pinned coupling — the top-level waive-required list IS the per-finding
      # keys, same open, same source.
      details = gate.details
      assert details["gate_title"] == "Review stalled — decide the surviving findings"
      assert is_binary(details["gate_description"])
      assert [%{"name" => "comment", "type" => "textarea"} | _] = details["fields"]
      assert is_binary(details["resume_hint"])
      assert details["lenses"] == ["quality"]
      assert details["certified_head"] == "verifystubhead"

      assert [%{"key" => key} = shown] = details["findings"]
      assert key =~ @hex64
      assert details["finding_keys"] == [key]
      assert shown["title"] == "missing nil check before deref"
      assert shown["severity"] == "error"
      assert shown["stage"] == "quality-reviewer"
      assert details["findings_deferred_count"] == 1
      assert details["findings_overflow_count"] == 0
      assert details["severity_counts"] == %{"error" => 1}
      assert [%{"lens" => "quality", "stuck" => [^key]}] = details["stall"]

      # Incomplete approve is refused loudly, never auto-converted to reject.
      assert {:error, :incomplete_waiver} =
               Cases.decide(case_id, :approve, %{}, auth(ctx))

      assert {:ok, %AgentCase{status: :pending}} = AgentCase.by_id(case_id, auth(ctx))

      # Approve with every finding waived: decide returns the CASE; the run
      # terminal is ASYNC (the parked composer wakes and terminalizes).
      waive = [%{key: key, severity: "error", note: "accepted as deferred debt"}]

      assert {:ok, %AgentCase{kind: :review_stall, status: :approved}} =
               Cases.decide(case_id, :approve, %{waive_records: waive}, auth(ctx))

      assert {:ok, summary} = Task.await(task, 30_000)
      assert summary.terminal == :done_with_findings

      # The durable terminal: completed-family with the disposition payload —
      # keys + counts only, never finding bodies.
      assert :route_done_with_findings in kinds(parent_id, ctx)
      parent = reload(parent_id, ctx)
      assert parent.status == :completed
      result = parent.result
      assert result["disposition"] == "done_with_findings"
      assert result["finding_keys"] == [key]
      assert result["findings_deferred_count"] == 1
      assert result["severity_counts"] == %{"error" => 1}
      assert result["lenses"] == ["quality"]
      assert result["certified_head"] == "verifystubhead"
      assert [%{"lens" => "quality", "stuck" => [^key]}] = result["stall"]
      # Steady trend: the fixture finding's confidence is "likely" both rounds.
      assert result["trend"] == %{key => "steady"}
      refute Map.has_key?(result, "findings")
      assert is_nil(parent.error)

      # The waive records landed on the case's :approved timeline event (the
      # BO2-6 ledger rows), and the ledger reads them back.
      {:ok, case_events} = AgentCaseEvent.for_case(case_id, auth(ctx))
      approved = Enum.find(case_events, &(&1.type == :approved))

      assert [%{"key" => ^key, "severity" => "error", "note" => "accepted as deferred debt"}] =
               approved.data["waive_records"]

      assert {:ok, ledger} = Cases.waived_findings_ledger(ctx.tenant, ctx.actor)
      assert ledger.total_waived == 1
      assert ledger.severity_counts == %{"error" => 1}
      assert [row] = ledger.cases
      assert row.case_id == case_id
      assert [%{"key" => ^key}] = row.waive_records
    end

    test "a FALLING confidence trend (likely → unsure across the stall) lands on result.trend",
         ctx do
      stall_quality()

      # Round 2 re-flags the SAME title/location (stuck key) with confidence
      # dropped to "unsure" — key_trends classifies it :falling.
      Application.put_env(:jido_claw, :route_composer_review_finding_on, %{
        "quality" => %{
          2 => %{
            "title" => "missing nil check before deref",
            "severity" => "error",
            "confidence" => "unsure",
            "location" => "lib/auth.ex:42",
            "description" => "probably stale — could not reproduce after the fix"
          }
        }
      })

      RunPubSub.subscribe_gates()
      task = run_task(ctx)

      assert_receive {:gate_requested, parent_id, %{agent_case_id: case_id}}, 20_000
      {:ok, gate} = AgentCase.by_id(case_id, auth(ctx))
      assert [key] = gate.details["finding_keys"]

      waive = [%{key: key, severity: "error", note: nil}]
      assert {:ok, _} = Cases.decide(case_id, :approve, %{waive_records: waive}, auth(ctx))

      assert {:ok, summary} = Task.await(task, 30_000)
      assert summary.terminal == :done_with_findings
      assert reload(parent_id, ctx).result["trend"] == %{key => "falling"}
    end

    test "reject → :route_fix_failed (parent :failed, never :cancelled)", ctx do
      stall_quality()
      RunPubSub.subscribe_gates()
      task = run_task(ctx)

      assert_receive {:gate_requested, parent_id, %{agent_case_id: case_id}}, 20_000

      assert {:ok, %AgentCase{kind: :review_stall, status: :rejected}} =
               Cases.decide(case_id, :reject, %{decision_comment: "fix these"}, auth(ctx))

      assert {:ok, summary} = Task.await(task, 30_000)
      assert summary.terminal == :fix_failed
      assert summary.reason == ["quality"]

      ks = kinds(parent_id, ctx)
      assert :route_fix_failed in ks
      refute :route_done_with_findings in ks
      refute :run_cancelled in ks

      parent = reload(parent_id, ctx)
      assert parent.status == :failed
      assert parent.result["disposition"] == "fix_failed"
    end

    test "abandon → :route_abandoned with NO run_abandoned event; abandon returns the case",
         ctx do
      stall_quality()
      RunPubSub.subscribe_gates()
      task = run_task(ctx)

      assert_receive {:gate_requested, parent_id, %{agent_case_id: case_id}}, 20_000

      # The kind-dispatched abandon returns the CASE (the run stays :running
      # until the composer wakes) and never appends run_abandoned — illegal
      # from :running; the composer writes its own :route_abandoned terminal.
      assert {:ok, %AgentCase{kind: :review_stall, status: :abandoned}} =
               Cases.abandon(case_id, %{}, auth(ctx))

      assert {:ok, summary} = Task.await(task, 30_000)
      assert summary.terminal == :abandoned

      ks = kinds(parent_id, ctx)
      assert :route_abandoned in ks
      refute :run_abandoned in ks

      parent = reload(parent_id, ctx)
      assert parent.status == :cancelled
      assert parent.result["disposition"] == "abandoned"
    end
  end

  describe "NOT gated (the fix-loop stop keeps today's terminals)" do
    test "a verify-less route's stall stays :route_fix_failed with no case opened", ctx do
      # The self-heal catalog has NO verify stage — the C1-5 stall early-halts
      # it exactly as Phase 1 shipped; the gate never fires.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => :always})

      assert {:ok, summary} =
               RouteComposer.run_sync(
                 catalog: TestFixtures.self_heal_fixture_catalog(),
                 live: TestFixtures.self_heal_seed_live(),
                 artifacts: TestFixtures.self_heal_seed_artifacts(),
                 tenant: ctx.tenant,
                 actor: ctx.actor,
                 context: ctx.context,
                 rerun_cap: 5,
                 max_waves: 30,
                 timeout: 30_000
               )

      assert summary.terminal == :fix_failed
      assert no_review_stall_case?(summary.parent_run_id, ctx)
      refute :route_done_with_findings in kinds(summary.parent_run_id, ctx)
    end

    test "a stall with a RED verify is NOT gated — the stop falls through to :route_fix_failed",
         ctx do
      # quality's stop suppresses the whole Hook R at its cap, so the route
      # runs dry with findings:verify still live and clean:verify never
      # published — `finish_fixish` sees the red (not green-certified) verify
      # and keeps today's fix_failed, opening no case.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => :always})

      Application.put_env(:jido_claw, :route_composer_verify_stub, %{
        results: [{1, "3 tests failed"}]
      })

      assert {:ok, summary} = run_verify(ctx, rerun_cap: 1)
      assert summary.terminal == :fix_failed
      assert MapSet.member?(summary.final_live, "findings:verify")
      refute MapSet.member?(summary.final_live, "clean:verify")
      assert no_review_stall_case?(summary.parent_run_id, ctx)
      refute :route_done_with_findings in kinds(summary.parent_run_id, ctx)
    end
  end

  describe "idempotent raise-or-resolve (restart)" do
    test "a pending case re-parks after a restart — no duplicate case (the fingerprint fence)",
         ctx do
      stall_quality()
      RunPubSub.subscribe_gates()
      parent = stall_recoverable_parent(ctx)

      # First supervised run: loops to the stall and parks.
      assert :ok = WorkflowRecovery.reconcile_all()
      assert_receive {:gate_requested, parent_id, %{agent_case_id: case_id}}, 20_000
      assert parent_id == parent.id
      {:ok, %AgentCase{fingerprint: fingerprint}} = AgentCase.by_id(case_id, auth(ctx))

      # Kill the parked composer; the parent stays :running (the durable park
      # is the pending case row).
      kill_composer(parent.id)
      assert reload(parent.id, ctx).status == :running

      # The relaunch rebuilds, re-derives the stall, finds the PENDING case by
      # fingerprint, and re-parks — no re-open, no duplicate row.
      assert :ok = WorkflowRecovery.reconcile_all()
      await_parked_composer(parent.id)
      {:ok, cases} = AgentCase.by_fingerprint(fingerprint, auth(ctx))
      assert [%AgentCase{id: ^case_id, status: :pending}] = cases

      # The re-parked composer resolves a live decision.
      assert {:ok, _} = Cases.decide(case_id, :reject, %{}, auth(ctx))
      assert :failed = await_status(parent.id, ctx, :failed, 30_000)
      assert reload(parent.id, ctx).result["disposition"] == "fix_failed"
    end

    test "a case decided while the composer was down terminalizes once on rebuild", ctx do
      stall_quality()
      RunPubSub.subscribe_gates()
      parent = stall_recoverable_parent(ctx)

      assert :ok = WorkflowRecovery.reconcile_all()
      assert_receive {:gate_requested, parent_id, %{agent_case_id: case_id}}, 20_000
      assert parent_id == parent.id

      kill_composer(parent.id)

      # Decide while nobody is listening — the broadcast is lost by design;
      # the decision is durable.
      {:ok, gate} = AgentCase.by_id(case_id, auth(ctx))
      waive = Enum.map(gate.details["finding_keys"], &%{key: &1, severity: "error", note: nil})

      assert {:ok, %AgentCase{status: :approved}} =
               Cases.decide(case_id, :approve, %{waive_records: waive}, auth(ctx))

      assert reload(parent.id, ctx).status == :running

      # Rebuild → tick → re-derive → resolve-by-fingerprint → terminal.
      assert :ok = WorkflowRecovery.reconcile_all()
      assert :completed = await_status(parent.id, ctx, :completed, 30_000)

      parent_final = reload(parent.id, ctx)
      assert parent_final.result["disposition"] == "done_with_findings"
      assert Enum.count(kinds(parent.id, ctx), &(&1 == :route_done_with_findings)) == 1

      # Still exactly one case for the fingerprint — decided, consumed once.
      {:ok, cases} = AgentCase.by_fingerprint(gate.fingerprint, auth(ctx))
      assert [%AgentCase{id: ^case_id, status: :approved}] = cases
    end
  end

  describe "sensitive-run stall-park deadline" do
    test "past-deadline fire abandons the pending case and terminalizes :route_abandoned (no run_abandoned)",
         ctx do
      {parent, gate, state, ref} = crafted_stall_park(ctx)

      assert {:stop, :normal, _final} =
               RouteComposer.handle_info({:stall_park_deadline, ref, gate.id}, state)

      assert reload_case(gate.id, ctx).status == :abandoned

      ks = kinds(parent.id, ctx)
      assert :route_abandoned in ks
      refute :run_abandoned in ks

      parent_final = reload(parent.id, ctx)
      assert parent_final.status == :cancelled
      assert parent_final.result["disposition"] == "abandoned"
    end

    test "a stale fire (mismatched ref) is ignored; a committed decision beats the deadline",
         ctx do
      {parent, gate, state, _ref} = crafted_stall_park(ctx)

      # Mismatched deadline_ref → no-op, case stays pending.
      assert {:noreply, ^state} =
               RouteComposer.handle_info({:stall_park_deadline, make_ref(), gate.id}, state)

      assert reload_case(gate.id, ctx).status == :pending

      # A decision committed before the (matching) fire wins: the disposal's
      # abandon reads :not_pending and routes through the normal resolver.
      waive = Enum.map(gate.details["finding_keys"], &%{key: &1, severity: "error", note: nil})

      assert {:ok, %AgentCase{status: :approved}} =
               Cases.decide(gate.id, :approve, %{waive_records: waive}, auth(ctx))

      ref = state.stall_deadline_ref

      assert {:stop, :normal, _final} =
               RouteComposer.handle_info({:stall_park_deadline, ref, gate.id}, state)

      parent_final = reload(parent.id, ctx)
      assert parent_final.status == :completed
      assert parent_final.result["disposition"] == "done_with_findings"
    end
  end

  describe "the :open_review_stall action contract" do
    test "refuses a nil AND a blank fingerprint (the idempotency-fence prerequisite)", ctx do
      parent = stall_recoverable_parent(ctx)

      base = %{workflow_run_id: parent.id, step_name: "review-stall", details: %{}}

      assert {:error, _} = AgentCase.open_review_stall(base, auth(ctx))
      assert {:error, _} = AgentCase.open_review_stall(Map.put(base, :fingerprint, ""), auth(ctx))

      assert {:error, _} =
               AgentCase.open_review_stall(Map.put(base, :fingerprint, "   "), auth(ctx))

      assert {:ok, %AgentCase{kind: :review_stall, gate_module: JidoClaw.Gates.ReviewStallGate}} =
               AgentCase.open_review_stall(Map.put(base, :fingerprint, "fp-1"), auth(ctx))
    end
  end

  # --- helpers ---

  # quality re-flags the identical titled finding every round; rerun_cap stays
  # HIGH so the round-2 STUCK key (not the budget) is what stops the loop.
  defp stall_quality do
    Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => :always})
  end

  defp run_task(ctx) do
    Task.async(fn -> run_verify(ctx, rerun_cap: 5, max_waves: 30) end)
  end

  defp run_verify(ctx, opts) do
    RouteComposer.run_sync(
      [
        catalog: TestFixtures.verify_fixture_catalog(),
        live: TestFixtures.verify_seed_live(),
        artifacts: TestFixtures.verify_seed_artifacts(),
        tenant: ctx.tenant,
        actor: ctx.actor,
        context: ctx.context,
        max_waves: Keyword.get(opts, :max_waves, 20),
        timeout: 30_000
      ] ++ Keyword.take(opts, [:rerun_cap, :infra_cap])
    )
  end

  # A durable parent over the verify catalog for the supervised restart flows.
  defp stall_recoverable_parent(ctx) do
    TestFixtures.recoverable_parent(ctx,
      catalog: TestFixtures.verify_fixture_catalog(),
      live: TestFixtures.verify_seed_live(),
      artifacts: TestFixtures.verify_seed_artifacts(),
      rerun_cap: 5,
      max_waves: 30
    )
  end

  defp kill_composer(parent_id) do
    [{pid, _}] = Registry.lookup(@registry, parent_id)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(@supervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  # A re-parked composer is registered and idle — it answers calls (the
  # parked-composer probe; a mid-wave composer blocks them).
  defp await_parked_composer(parent_id, tries \\ 200) do
    case Registry.lookup(@registry, parent_id) do
      [{pid, _}] ->
        GenServer.call(pid, :get_claim_token, 10_000)
        :ok

      [] when tries > 0 ->
        Process.sleep(50)
        await_parked_composer(parent_id, tries - 1)

      [] ->
        flunk("composer for #{parent_id} never re-registered")
    end
  end

  defp no_review_stall_case?(parent_id, ctx) do
    {:ok, cases} = AgentCase.pending_for_run(parent_id, auth(ctx))
    Enum.all?(cases, &(&1.kind != :review_stall))
  end

  # A real pending review-stall case + an init'd composer state parked on it,
  # sensitive-marked with a PAST durable deadline — the direct-handle_info
  # deadline harness (the O-M2 child-park test pattern).
  defp crafted_stall_park(ctx) do
    parent = stall_recoverable_parent(ctx)
    key = String.duplicate("a", 64)
    fingerprint = String.duplicate("b", 64)

    {:ok, gate} =
      WorkflowLog.case_open_runbound(
        parent,
        %{
          workflow_run_id: parent.id,
          step_name: "review-stall",
          fingerprint: fingerprint,
          details: %{"finding_keys" => [key], "findings" => []}
        },
        auth(ctx)
      )

    {:ok, state, _continue} =
      RouteComposer.init(
        catalog: TestFixtures.verify_fixture_catalog(),
        live: TestFixtures.verify_seed_live(),
        artifacts: TestFixtures.verify_seed_artifacts(),
        tenant: ctx.tenant,
        actor: ctx.actor,
        context: ctx.context,
        parent_run_id: parent.id,
        sanitize_sensitive_context: true,
        deadline_at_ms: System.os_time(:millisecond) - 1_000
      )

    ref = make_ref()

    park = %{
      case_id: gate.id,
      fingerprint: fingerprint,
      lenses: ["quality"],
      result: %{
        disposition: "done_with_findings",
        finding_keys: [key],
        findings_deferred_count: 1,
        severity_counts: %{"error" => 1},
        lenses: ["quality"],
        certified_head: "verifystubhead",
        stall: [],
        trend: %{}
      },
      details: gate.details
    }

    parked_state = %{state | parent: parent, stall_parked: park, stall_deadline_ref: ref}
    {parent, gate, parked_state, ref}
  end

  defp auth(ctx), do: [tenant: ctx.tenant, actor: ctx.actor]

  defp all_events(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, auth(ctx))
    events
  end

  defp kinds(parent_id, ctx), do: Enum.map(all_events(parent_id, ctx), & &1.kind)

  defp reload(parent_id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(parent_id, auth(ctx))
    parent
  end

  defp reload_case(case_id, ctx) do
    {:ok, gate} = AgentCase.by_id(case_id, auth(ctx))
    gate
  end

  defp await_status(parent_id, ctx, target, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_status_loop(parent_id, ctx, target, deadline)
  end

  defp await_status_loop(parent_id, ctx, target, deadline) do
    status = reload(parent_id, ctx).status

    cond do
      status == target ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        status

      true ->
        Process.sleep(50)
        await_status_loop(parent_id, ctx, target, deadline)
    end
  end
end
