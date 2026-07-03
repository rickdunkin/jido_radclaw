defmodule JidoClaw.RouteComposer.ComposerLoopTest do
  @moduledoc """
  End-to-end: drive the single-run composer loop over the Phase-1 fixture
  catalog with stub workers, asserting the headline §14 behaviors — a code-path
  route composes and runs across multiple waves, passing `plan` /
  `approved-plan` / `diff` across waves, growing the route from an emitted signal
  (`security-reviewer` joins only because `auth-surface` was emitted), releasing
  a held (locked) stage, and converging on clean review verdicts.

  Non-async (`TenantCase`): it mutates global app env (`:agent_templates_override`,
  `:step_agent_server`, `:route_composer_stub_outputs`) and runs async Reactor
  steps under a shared sandbox so spawned step workers see seeded rows.
  """
  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Reasoning.Compactor.RequestTransformer
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.BlockingAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker
  alias JidoClaw.RouteComposer.TestSupport.SystemLoopWorker
  alias JidoClaw.Test.ForgeStub

  @all_stages ~w(planner approver implementer quality-reviewer security-reviewer)

  setup do
    StubStore.setup()
    previous_server = Application.get_env(:jido_claw, :step_agent_server)

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      TestFixtures.phase1_template_override(StubWorker)
    )

    Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :route_composer_stub_outputs)

      case previous_server do
        nil -> Application.delete_env(:jido_claw, :step_agent_server)
        mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
      end
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "composer")

    context = %{
      tenant_id: tenant,
      session_id: "composer-sess",
      session_uuid: session.id,
      workspace_id: "composer-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, context: context}
  end

  defp run(ctx, opts \\ []) do
    RouteComposer.run_sync(
      catalog: TestFixtures.phase1_catalog(),
      live: TestFixtures.phase1_seed_live(),
      artifacts: TestFixtures.phase1_seed_artifacts(),
      tenant: ctx.tenant,
      actor: actor_for(ctx.tenant),
      context: ctx.context,
      max_waves: Keyword.get(opts, :max_waves, 10),
      timeout: Keyword.get(opts, :timeout, 30_000)
    )
  end

  # AR-8b-2 F1 sketch-path helpers. Stub `sketch_build` + `sketch_reviewer` (plain
  # StubWorker templates — no `sandbox` enforcement in the loop test, so they run
  # without a real `.prototypes/` root) and serve the supplied reviewer verdict.
  defp put_sketch_env(_ctx, reviewer_output) do
    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      Map.merge(
        TestFixtures.phase1_template_override(StubWorker),
        %{
          "sketch_build" => %{
            module: StubWorker,
            description: "sketch stub",
            model: :fast,
            max_iterations: 1
          },
          # AR-8b-2 F2: the exec builder shares the loop-test StubWorker (no
          # `sandbox` enforcement in the loop test), so a `must-execute` seed can
          # dispatch `sketch-build-exec` without a real Docker session.
          "sketch_build_exec" => %{
            module: StubWorker,
            description: "sketch exec stub",
            model: :fast,
            max_iterations: 1
          },
          "sketch_reviewer" => %{
            module: StubWorker,
            description: "sketch review stub",
            model: :fast,
            max_iterations: 1
          }
        }
      )
    )

    Application.put_env(:jido_claw, :route_composer_stub_outputs, %{
      "sketch_build" => %{"prototype" => "PROTO: a tracer-bullet rate limiter"},
      "sketch_build_exec" => %{"prototype" => "PROTO: a tracer-bullet rate limiter (ran)"},
      "sketch_reviewer" => reviewer_output
    })
  end

  # AR-8b-2 F2 (D4-B): the front door seeds exactly ONE discriminator alongside
  # `["request-received", "sketch"]` — `"sketch-plain"` (→ `sketch-build`) or
  # `"must-execute"` (→ `sketch-build-exec`). The two builders are mutually
  # exclusive by construction.
  defp run_sketch(ctx, discriminator \\ "sketch-plain") do
    RouteComposer.run_sync(
      catalog: Catalog.all(),
      live: ["request-received", "sketch", discriminator],
      artifacts: %{"request" => %{"seed" => "sketch a rate limiter"}},
      ran: ["triage"],
      tenant: ctx.tenant,
      actor: actor_for(ctx.tenant),
      context: ctx.context,
      max_waves: 5,
      timeout: 30_000
    )
  end

  # AR-2 Phase 3b — the Option-A front-door seed (`triage ∈ ran`) on the gate-free
  # triage-seeded fixture catalog.
  defp run_triage_seeded(ctx, opts \\ []) do
    RouteComposer.run_sync(
      catalog: TestFixtures.triage_seeded_fixture_catalog(),
      live: TestFixtures.triage_seed_live(),
      artifacts: TestFixtures.triage_seed_artifacts(),
      ran: TestFixtures.triage_seed_ran(),
      tenant: ctx.tenant,
      actor: actor_for(ctx.tenant),
      context: ctx.context,
      max_waves: Keyword.get(opts, :max_waves, 10),
      timeout: Keyword.get(opts, :timeout, 30_000)
    )
  end

  test "Option-A seed: triage ∈ ran, converges, and triage is never dispatched", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    assert {:ok, summary} = run_triage_seeded(ctx)
    assert summary.terminal == :converged

    # triage is in `ran` (the genesis seed), but never appears in a dispatched wave.
    assert MapSet.member?(summary.ran, "triage")
    refute Enum.any?(summary.history, &("triage" in &1.stages))

    # Wave 0 == [planner] proves intent/plan-needed were seeded correctly (planner
    # requires `intent` + subscribes `plan-needed`, both triage's declared outputs).
    assert hd(summary.history).stages == ["planner"]

    # The genesis wave_completed(wave_index: -1, stages: ["triage"]) is in the log.
    {:ok, events} =
      WorkflowEvent.for_run(summary.parent_run_id,
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant)
      )

    genesis =
      Enum.find(events, fn e ->
        e.kind == :wave_completed and e.payload["wave_index"] == -1
      end)

    assert genesis, "expected a genesis wave_completed(-1) event"
    assert genesis.payload["stages"] == ["triage"]
  end

  test "AR-8b-2 F1 sketch path: a clean reviewer converges with clean:correctness", ctx do
    # AR-8b-2 F1: the sketch path is now lens-gated. sketch-build (wave 1) →
    # sketch-review (wave 2). A clean correctness verdict converges the run.
    put_sketch_env(ctx, TestFixtures.phase1_clean_reviewer())

    assert {:ok, summary} = run_sketch(ctx)

    assert summary.terminal == :converged
    assert summary.ran == MapSet.new(["triage", "sketch-build", "sketch-review"])
    # D4-B mutual exclusion (the plain direction): the exec builder never runs.
    refute MapSet.member?(summary.ran, "sketch-build-exec")
    assert MapSet.member?(summary.final_live, "clean:correctness")
    refute MapSet.member?(summary.final_live, "findings:correctness")

    # triage is seeded-as-run; never dispatched. Two sequential dispatches:
    # sketch-build, then sketch-review (ordered by the prototype data edge).
    refute Enum.any?(summary.history, &("triage" in &1.stages))
    assert Enum.map(summary.history, & &1.stages) == [["sketch-build"], ["sketch-review"]]
  end

  test "AR-8b-2 F1 sketch path: a request_changes reviewer ends :not_converged with findings",
       ctx do
    put_sketch_env(ctx, TestFixtures.phase1_findings_reviewer())

    assert {:ok, summary} = run_sketch(ctx)

    # report-only: no fixer on the sketch path, so findings surface and the run
    # ends :not_converged (not a spin) with every stage having run once.
    assert summary.terminal == :not_converged
    assert summary.ran == MapSet.new(["triage", "sketch-build", "sketch-review"])
    assert MapSet.member?(summary.final_live, "findings:correctness")
    refute MapSet.member?(summary.final_live, "clean:correctness")
    # the findings artifact is present, produced by sketch-review.
    assert get_in(summary.artifacts, ["findings", "sketch-review"])
    assert Enum.map(summary.history, & &1.stages) == [["sketch-build"], ["sketch-review"]]
  end

  test "AR-8b-2 F2 sketch path: a must-execute seed runs sketch-build-exec, not sketch-build",
       ctx do
    # D4-B mutual exclusion (the exec direction): seeding `must-execute` dispatches
    # `sketch-build-exec` (← `must-execute`) INSTEAD OF `sketch-build` (←
    # `sketch-plain`), then `sketch-review` (← `request-received`). Both produce
    # `prototype`, so the reviewer orders into wave 2 either way.
    put_sketch_env(ctx, TestFixtures.phase1_clean_reviewer())

    assert {:ok, summary} = run_sketch(ctx, "must-execute")

    assert summary.terminal == :converged
    assert summary.ran == MapSet.new(["triage", "sketch-build-exec", "sketch-review"])
    refute MapSet.member?(summary.ran, "sketch-build")
    assert MapSet.member?(summary.final_live, "clean:correctness")
    assert Enum.map(summary.history, & &1.stages) == [["sketch-build-exec"], ["sketch-review"]]
  end

  # AR-8b-2 F2 (5.6 / D3): teardown must run for EVERY terminal, keyed on the
  # `forge_session_key` in the composer's persisted context — `:converged` →
  # `complete_session` (`:completed`); every other terminal → `stop_session`
  # (`:cancelled`). The `:not_converged` case is the headline gap the review
  # caught (a normal "ran but the reviewer requested changes" sketch would
  # otherwise leave the microVM alive). Driven via the `ForgeStub` facade.
  describe "AR-8b-2 F2 composer Forge-session teardown (every terminal)" do
    setup do
      cleanup = ForgeStub.install([])
      on_exit(cleanup)
      :ok
    end

    defp run_sketch_with_forge_key(ctx, reviewer_output, key) do
      put_sketch_env(ctx, reviewer_output)
      context = Map.put(ctx.context, :forge_session_key, key)

      RouteComposer.run_sync(
        catalog: Catalog.all(),
        live: ["request-received", "sketch", "must-execute"],
        artifacts: %{"request" => %{"seed" => "sketch a rate limiter"}},
        ran: ["triage"],
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant),
        context: context,
        max_waves: 5,
        timeout: 30_000
      )
    end

    test "a converged run COMPLETES the Forge session (:completed), never stops it", ctx do
      key = "fk_converge_#{:erlang.unique_integer([:positive])}"

      assert {:ok, summary} =
               run_sketch_with_forge_key(ctx, TestFixtures.phase1_clean_reviewer(), key)

      assert summary.terminal == :converged
      assert key in ForgeStub.completes()
      refute key in ForgeStub.stops()
    end

    test "a :not_converged run STOPS the Forge session (:cancelled) — the leak the review caught",
         ctx do
      key = "fk_notconv_#{:erlang.unique_integer([:positive])}"

      assert {:ok, summary} =
               run_sketch_with_forge_key(ctx, TestFixtures.phase1_findings_reviewer(), key)

      # Reviewer requested changes → :not_converged, yet the microVM is NOT left alive.
      assert summary.terminal == :not_converged
      assert key in ForgeStub.stops()
      refute key in ForgeStub.completes()
    end

    test "a facade cleanup failure does NOT flip a converged run to :terminalize_failed", ctx do
      # The composer `best_effort`-swallows the facade error; the teardown result
      # never reaches `notify_payload/2`.
      ForgeStub.set_complete_result(:raise)
      key = "fk_raise_#{:erlang.unique_integer([:positive])}"

      assert {:ok, summary} =
               run_sketch_with_forge_key(ctx, TestFixtures.phase1_clean_reviewer(), key)

      assert summary.terminal == :converged
      assert key in ForgeStub.completes()
    end
  end

  test "built-in catalog: the triage seed reconciles, planner runs, then the plan-gate PARKS",
       ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    # Phase 4: the real catalog's `{:gate, "plan"}` stage now BUILDS + PARKS (vs
    # the old `{:unsupported_unit,...}` failure). Drive it via run_sync in a task;
    # subscribe to gates first so we catch the park, then ABANDON it so the route
    # takes a clean terminal (no operator approval needed for this boundary pin).
    RunPubSub.subscribe_gates()

    task =
      Task.async(fn ->
        RouteComposer.run_sync(
          catalog: Catalog.all(),
          live: ["request-received", "code", "plan-needed"],
          artifacts: %{
            "request" => %{"seed" => "Build it"},
            "intent" => %{"triage" => "Build it"}
          },
          ran: ["triage"],
          tenant: ctx.tenant,
          actor: actor_for(ctx.tenant),
          context: ctx.context,
          max_waves: 10,
          timeout: 30_000
        )
      end)

    # The gate built + parked (reconciliation worked, planner ran, gate halted).
    assert_receive {:gate_requested, child_id, %{agent_case_id: case_id}}, 15_000
    parent_id = parent_of(child_id, ctx)
    # Wait for the durable park so the composer has subscribed before we decide.
    await_wave_paused(parent_id, ctx)

    assert {:ok, _} =
             Cases.abandon(case_id, %{}, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    assert {:ok, summary} = Task.await(task, 30_000)
    assert summary.terminal == :abandoned
    assert MapSet.member?(summary.ran, "planner")

    ks = event_kinds(parent_id, ctx)
    assert :wave_paused in ks
    assert :route_abandoned in ks
    drain_run_registry(2_000)
  end

  test "gate fixture: planner → plan-gate parks → approve → implementer runs → converges", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.gate_fixture_stub_outputs()
    )

    RunPubSub.subscribe_gates()

    task =
      Task.async(fn ->
        RouteComposer.run_sync(
          catalog: TestFixtures.gate_fixture_catalog(),
          live: TestFixtures.gate_fixture_seed_live(),
          artifacts: TestFixtures.gate_fixture_seed_artifacts(),
          tenant: ctx.tenant,
          actor: actor_for(ctx.tenant),
          context: ctx.context,
          max_waves: 10,
          timeout: 30_000
        )
      end)

    assert_receive {:gate_requested, child_id, %{agent_case_id: case_id}}, 15_000
    parent_id = parent_of(child_id, ctx)
    await_wave_paused(parent_id, ctx)

    # Approve → GateResume emits plan-approved + approved-plan, the composer wakes,
    # folds, and releases the held implementer.
    assert {:ok, _} =
             Cases.decide(case_id, :approve, %{},
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant)
             )

    assert {:ok, summary} = Task.await(task, 30_000)
    assert summary.terminal == :converged

    # The held implementer released and ran; the gate's approved-plan crossed waves.
    assert MapSet.member?(summary.ran, "plan-gate")
    assert MapSet.member?(summary.ran, "implementer")
    assert MapSet.member?(summary.final_live, "plan-approved")
    assert get_in(summary.artifacts, ["approved-plan", "plan-gate"])
    assert get_in(summary.artifacts, ["diff", "implementer"])

    ks = event_kinds(parent_id, ctx)
    assert :wave_paused in ks
    assert :wave_resumed in ks
    assert :route_converged in ks
    drain_run_registry(2_000)
  end

  # ===========================================================================
  # AR-9 (PR-3/PR-4) — the armed multi-plan wave on the REAL catalog.
  # ===========================================================================

  describe "AR-9 armed multi-plan wave (e2e, real catalog)" do
    # Every stub map is FULLY schema-shaped and signal-less (the stub path
    # stamps :validated, bypassing Zoi): artifacts resolve via the summary
    # fallback, `plan-ready`/`code-written` are loop-injected, and a canned
    # `scope-shift` would trigger real rescope behavior — so none exists.
    defp put_armed_env(arbiter) do
      Application.put_env(
        :jido_claw,
        :agent_templates_override,
        TestFixtures.armed_template_override(StubWorker)
      )

      Application.put_env(
        :jido_claw,
        :route_composer_stub_outputs,
        TestFixtures.armed_stub_outputs(arbiter)
      )
    end

    # Drive an armed run to terminal: seed → 4 planning waves → the plan-gate
    # parks → approve → implementer + reviewers → terminal summary.
    defp run_armed(ctx) do
      RunPubSub.subscribe_gates()

      task =
        Task.async(fn ->
          RouteComposer.run_sync(
            catalog: Catalog.all(),
            live: TestFixtures.armed_seed_live(),
            artifacts: TestFixtures.armed_seed_artifacts(),
            ran: ["triage"],
            tenant: ctx.tenant,
            actor: actor_for(ctx.tenant),
            context: ctx.context,
            max_waves: 15,
            timeout: 30_000
          )
        end)

      assert_receive {:gate_requested, child_id, %{agent_case_id: case_id}}, 15_000
      parent_id = parent_of(child_id, ctx)
      await_wave_paused(parent_id, ctx)

      assert {:ok, _} =
               Cases.decide(case_id, :approve, %{},
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant)
               )

      assert {:ok, summary} = Task.await(task, 30_000)
      drain_run_registry(2_000)
      summary
    end

    # `summary.artifacts` holds refs — resolve to the stored value so the
    # assertions pin VALUES (the summary-fallback path), not mere presence.
    defp resolve_artifact(summary, name, producer, ctx) do
      ref = get_in(summary.artifacts, [name, producer])
      assert is_binary(ref), "expected #{name} produced by #{producer}"

      {:ok, value} =
        ComposerArtifact.resolve_value(ref, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

      value
    end

    @planning_waves [
      ["planner-reuse-first", "planner-risk-first", "planner-smallest-shippable"],
      ["challenger-reuse-first", "challenger-risk-first", "challenger-smallest-shippable"],
      ["plan-arbiter"],
      ["planner"]
    ]

    test "armed adopt: 4 planning waves → gate → implementer → reviewers → converged", ctx do
      put_armed_env(TestFixtures.armed_adopt_arbiter())
      summary = run_armed(ctx)

      assert summary.terminal == :converged
      assert Enum.take(Enum.map(summary.history, & &1.stages), 4) == @planning_waves

      # Every plan-wave artifact carries the right producer AND equals its
      # producing stage's canned summary — the three plans DISTINCT.
      assert resolve_artifact(
               summary,
               "plan:smallest-shippable",
               "planner-smallest-shippable",
               ctx
             ) == "PLAN A: minimal viable slice."

      assert resolve_artifact(summary, "plan:risk-first", "planner-risk-first", ctx) ==
               "PLAN B: de-risk the hard part first."

      assert resolve_artifact(summary, "plan:reuse-first", "planner-reuse-first", ctx) ==
               "PLAN C: reuse the existing pipeline."

      for lens <- ~w(smallest-shippable risk-first reuse-first) do
        assert resolve_artifact(summary, "critique:#{lens}", "challenger-#{lens}", ctx) ==
                 "CRITIQUE: blockers/concerns/strengths."
      end

      assert resolve_artifact(summary, "decision-memo", "plan-arbiter", ctx) =~ "verdict: adopt"

      # The planner stays the SOLE producer of `plan` — the finalizer summary.
      assert Map.keys(summary.artifacts["plan"]) == ["planner"]

      assert resolve_artifact(summary, "plan", "planner", ctx) ==
               "PLAN (final): adopt Plan A, smallest-shippable."

      # Post-gate half: implementer ran; the three live-lens reviewers all clean
      # (architecture joined off the armed seed's significant-build).
      assert MapSet.member?(summary.ran, "implementer")
      assert MapSet.member?(summary.final_live, "clean:quality")
      assert MapSet.member?(summary.final_live, "clean:correctness")
      assert MapSet.member?(summary.final_live, "clean:architecture")
    end

    test "the finalizer's assembled task carries the memo + all three DISTINCT plans + critiques",
         ctx do
      put_armed_env(TestFixtures.armed_adopt_arbiter())
      Application.put_env(:jido_claw, :route_composer_capture_task, self())
      on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_capture_task) end)

      summary = run_armed(ctx)
      assert summary.terminal == :converged

      # The single researcher dispatch is the finalizer (wave 3) — its assembled
      # task carries the decision-memo section plus all three distinct competing
      # plans and the critiques (`ArtifactContext` forwards the named optional
      # inputs), so "redraft per the critiques" is honest.
      assert_receive {:wave_task, "researcher", final_task}
      assert final_task =~ "decision-memo"
      assert final_task =~ "verdict: adopt"
      assert final_task =~ "PLAN A: minimal viable slice."
      assert final_task =~ "PLAN B: de-risk the hard part first."
      assert final_task =~ "PLAN C: reuse the existing pipeline."
      assert final_task =~ "CRITIQUE: blockers/concerns/strengths."
    end

    test "revise_first routes IDENTICALLY to adopt (no verdict-driven routing)", ctx do
      # Decision 1: the verdict lives INSIDE the memo; hybrid/revise_first do
      # NOT ride plan-rejected. Only the arbiter map differs — the route must not.
      put_armed_env(TestFixtures.armed_revise_first_arbiter())
      summary = run_armed(ctx)

      assert summary.terminal == :converged
      assert Enum.take(Enum.map(summary.history, & &1.stages), 4) == @planning_waves

      assert resolve_artifact(summary, "decision-memo", "plan-arbiter", ctx) =~
               "verdict: revise_first"

      assert Map.keys(summary.artifacts["plan"]) == ["planner"]
    end

    test "a blocked lens planner route-fails the wave loudly", ctx do
      put_armed_env(TestFixtures.armed_adopt_arbiter())

      blocked =
        Map.update!(
          TestFixtures.armed_stub_outputs(),
          {"plan_drafter", "risk-first"},
          &Map.put(&1, "status", "blocked")
        )

      Application.put_env(:jido_claw, :route_composer_stub_outputs, blocked)

      # No gate is ever reached — wave 0 fails on the blocked-producer refusal
      # (`refuse_blocked_producer` applies to the lens-nil drafter exactly as to
      # the finalizer), so run_sync directly.
      assert {:ok, summary} =
               RouteComposer.run_sync(
                 catalog: Catalog.all(),
                 live: TestFixtures.armed_seed_live(),
                 artifacts: TestFixtures.armed_seed_artifacts(),
                 ran: ["triage"],
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant),
                 context: ctx.context,
                 max_waves: 15,
                 timeout: 30_000
               )

      assert summary.terminal == :failed
      assert [entry] = summary.history
      assert entry.failed
      assert entry.stages == hd(@planning_waves)
      assert :route_failed in event_kinds(summary.parent_run_id, ctx)
    end
  end

  test "composes a code-path route end-to-end and converges clean", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    assert {:ok, summary} = run(ctx)
    assert summary.terminal == :converged

    # plan / approved-plan / diff each crossed waves — present with the right producers.
    assert get_in(summary.artifacts, ["plan", "planner"])
    assert get_in(summary.artifacts, ["approved-plan", "approver"])
    assert get_in(summary.artifacts, ["diff", "implementer"])

    # every stage ran, and convergence carries both clean verdicts.
    assert MapSet.equal?(summary.ran, MapSet.new(@all_stages))
    assert MapSet.member?(summary.final_live, "clean:quality")
    assert MapSet.member?(summary.final_live, "clean:security")

    # four waves: planner, approver (implementer held), implementer, both reviewers.
    assert summary.wave_index == 4
    assert match?([_, _, _, _], summary.history)

    # Phase 2a: the run is a first-class composer parent (root, terminal
    # :completed at convergence), and every wave is a child linked by
    # parent_run_id + the deterministic composer:<parent>:<wave_index> key.
    parent_id = summary.parent_run_id
    assert is_binary(parent_id)

    assert {:ok, parent} =
             WorkflowRun.by_id(parent_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    assert parent.workflow_type == "composer"
    assert parent.status == :completed
    refute is_nil(parent.started_at)
    assert is_nil(parent.parent_run_id)

    for entry <- summary.history do
      assert {:ok, child} =
               WorkflowRun.by_id(entry.child_run_id,
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant)
               )

      assert child.parent_run_id == parent_id
      assert child.idempotency_key == "composer:#{parent_id}:#{entry.index}"
    end
  end

  test "AR-9: a tiered catalog stage's worker gets the tier map; untiered stages don't", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    Application.put_env(:jido_claw, :route_composer_capture_context, self())
    on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_capture_context) end)

    tiered_catalog =
      Map.update!(TestFixtures.phase1_catalog(), "planner", fn stage ->
        %{stage | model: :capable, effort: :high}
      end)

    assert {:ok, summary} =
             RouteComposer.run_sync(
               catalog: tiered_catalog,
               live: TestFixtures.phase1_seed_live(),
               artifacts: TestFixtures.phase1_seed_artifacts(),
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant),
               context: ctx.context,
               max_waves: 10,
               timeout: 30_000
             )

    assert summary.terminal == :converged

    tier_key = RequestTransformer.stage_tier_key()

    # The tiered planner (template "researcher", wave 0) carries the tier map
    # end-to-end: catalog → WaveBuilder options → AgentStep → AgentRunner →
    # the worker's tool_context (which the transformer reads per turn).
    assert_receive {:wave_context, "researcher", planner_tc}
    assert Map.get(planner_tc, tier_key) == %{model: :capable, effort: :high}

    # An untiered stage's worker context has NO tier key (byte-identity guard).
    assert_receive {:wave_context, "verifier", approver_tc}
    refute Map.has_key?(approver_tc, tier_key)
  end

  test "AR-9: seeded premises render into a worker wave's task (with the scope-shift line)",
       ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    Application.put_env(:jido_claw, :route_composer_capture_task, self())
    on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_capture_task) end)

    assert {:ok, summary} =
             RouteComposer.run_sync(
               catalog: TestFixtures.phase1_catalog(),
               live: TestFixtures.phase1_seed_live(),
               artifacts: TestFixtures.phase1_seed_artifacts(),
               premises: %{"risk" => "low"},
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant),
               context: ctx.context,
               max_waves: 10,
               timeout: 30_000
             )

    assert summary.terminal == :converged

    # Wave 0's planner task opens with the rendered premises block — threaded
    # launch → durable config → state.premises → compose_extra_context →
    # ContextBuilder.build_task → the worker's assembled task.
    assert_receive {:wave_task, "researcher", task}
    assert task =~ "### Premises"
    assert task =~ "- **risk**: low"
    assert task =~ "scope-shift"
  end

  test "AR-9: a default (premises-less) run's task carries NO premises block (byte-identity)",
       ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    Application.put_env(:jido_claw, :route_composer_capture_task, self())
    on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_capture_task) end)

    assert {:ok, summary} = run(ctx)
    assert summary.terminal == :converged

    assert_receive {:wave_task, "researcher", task}
    refute task =~ "### Premises"
  end

  test "the implementer is held while the approver runs, then released", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    assert {:ok, summary} = run(ctx)

    [w0, w1, w2, w3] = summary.history

    assert w0.stages == ["planner"]

    # W1: approver runs while implementer is held on its `until: plan-approved`.
    assert w1.stages == ["approver"]
    assert Map.has_key?(w1.held_before, "implementer")
    assert "plan-approved" in w1.held_before["implementer"]

    # W2: the lock released, implementer now runs.
    assert w2.stages == ["implementer"]

    # W3: both reviewers in one parallel wave — security-reviewer joined ONLY
    # because implementer emitted auth-surface (route growth from a signal).
    assert Enum.sort(w3.stages) == ["quality-reviewer", "security-reviewer"]
  end

  test "each wave's child WorkflowRun.result holds the json-safe emission map", ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    assert {:ok, summary} = run(ctx)

    for entry <- summary.history do
      assert {:ok, child} =
               WorkflowRun.by_id(entry.child_run_id,
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant)
               )

      assert is_map(child.result)
      assert child.result["wave_index"] == entry.index
      assert is_list(child.result["emissions"])
    end
  end

  test "a flagged review wave loops review → fix → re-review and converges (AR-4 self-heal)",
       ctx do
    # AR-4 inverts the old forward-only behavior: an open finding on a fixer-bearing
    # CODE path no longer terminates :not_converged — it loops review → fix →
    # re-review to :converged. (The surviving :not_converged-on-findings case is the
    # fixer-less sketch-review path; exhaustion → :route_fix_failed is covered by
    # composer_self_heal_loop_test.) Re-point to the self-heal fixture + the driven
    # worker (quality flags once, then cleans after the fix).
    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      TestFixtures.phase1_template_override(SystemLoopWorker)
    )

    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.self_heal_stub_outputs()
    )

    Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => [1]})
    on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_review_flag_on) end)

    assert {:ok, summary} =
             RouteComposer.run_sync(
               catalog: TestFixtures.self_heal_fixture_catalog(),
               live: TestFixtures.self_heal_seed_live(),
               artifacts: TestFixtures.self_heal_seed_artifacts(),
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant),
               context: ctx.context,
               max_waves: 20,
               timeout: 30_000
             )

    assert summary.terminal == :converged
    # The flagged lens cleared and the fixer ran on the path.
    assert MapSet.member?(summary.final_live, "clean:quality")
    refute MapSet.member?(summary.final_live, "findings:quality")
    assert MapSet.member?(summary.ran, "fixer")

    assert {:ok, parent} =
             WorkflowRun.by_id(summary.parent_run_id,
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant)
             )

    assert parent.status == :completed
  end

  test "a wave failure records a failed history entry surfacing child_run_id", ctx do
    # An undeclared signal (∉ planner.publishes) fails DefaultMapper.map →
    # WaveCollect → ReactorRunner returns {:error, reason, run}: a deterministic
    # wave failure that still produced a child WorkflowRun.
    bad = put_in(TestFixtures.phase1_stub_outputs(), ["researcher", "signals"], ["bogus-signal"])
    Application.put_env(:jido_claw, :route_composer_stub_outputs, bad)

    assert {:ok, summary} = run(ctx)
    assert summary.terminal == :failed
    assert [entry] = summary.history
    assert entry.failed
    assert entry.stages == ["planner"]
    # the wave's reactor ran; its child run id is surfaced for actionability.
    assert entry.child_run_id

    # Phase 2a: a :failed terminal takes the parent to :failed, error prefixed.
    assert {:ok, parent} =
             WorkflowRun.by_id(summary.parent_run_id,
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant)
             )

    assert parent.status == :failed
    assert String.starts_with?(parent.error, "failed:")
  end

  test "run_sync times out, kills the unlinked composer, and terminalizes the parent to :failed",
       ctx do
    Application.put_env(
      :jido_claw,
      :route_composer_stub_outputs,
      TestFixtures.phase1_stub_outputs()
    )

    Application.put_env(:jido_claw, :step_agent_server, BlockingAgentServer)

    test_pid = self()
    task = Task.async(fn -> send(test_pid, {:run_sync, run(ctx, timeout: 400)}) end)

    # The composer is now UNLINKED (run_sync uses GenServer.start + monitor), so
    # capture it by its $initial_call — not the task's link set — and monitor it
    # to observe the kill.
    composer = await_composer_process()
    cref = Process.monitor(composer)

    # Core: the timeout fires (wave blocked 600ms > 400ms) and the composer is
    # *killed*, not left turning the crank.
    assert_receive {:run_sync, {:error, :timeout}}, 3_000
    assert_receive {:DOWN, ^cref, :process, ^composer, :killed}, 3_000
    Task.await(task)

    # Phase 2a: the now-ownerless :running parent is terminalized live to :failed
    # with the STORED STRING (error is a :string column, so it is "composer_timeout",
    # never the inspected ":composer_timeout") — not left :running.
    parent = composer_parent_run(ctx)
    assert parent.status == :failed
    assert parent.error == "composer_timeout"

    # Hygiene: the in-flight wave runs under async_nolink and outlives the
    # composer; wait for its durable write so nothing writes under a torn-down
    # sandbox after the test returns.
    drain_run_registry(2_000)
  end

  test "run_sync surfaces a start failure and terminalizes the parent to :failed", ctx do
    # No :catalog → the composer's init/1 raises → GenServer.start returns
    # {:error, _} → start_composer terminalizes the just-created :running parent.
    # (capture_log swallows the deliberate proc_lib crash report.)
    capture_log(fn ->
      assert {:error, {:start_failed, _reason}} =
               RouteComposer.run_sync(
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant),
                 timeout: 1_000
               )
    end)

    parent = composer_parent_run(ctx)
    assert parent.status == :failed
  end

  # Bounded poll of the live process table for the freshly-started composer (its
  # `$initial_call` is `{RouteComposer, :init, 1}`). run_sync/1 now starts it
  # UNLINKED (GenServer.start), so it is no longer in the caller's link set — but
  # it is a live process from just after `create_parent_run/1` commits until the
  # 400ms kill, and async:false means it is the only composer alive, so scanning
  # by initial call is deterministic.
  defp await_composer_process(tries \\ 200) do
    case Enum.find(Process.list(), &composer?/1) do
      nil when tries > 0 ->
        Process.sleep(5)
        await_composer_process(tries - 1)

      nil ->
        flunk("composer process not found within poll window")

      pid ->
        pid
    end
  end

  # The single composer parent run in this test's (per-test) tenant — the
  # `workflow_type: "composer"` root run. async:false + a fresh tenant per test
  # means there is exactly one.
  defp composer_parent_run(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant, actor: actor_for(ctx.tenant))
    Enum.find(runs, &(&1.workflow_type == "composer"))
  end

  defp composer?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$initial_call") == {RouteComposer, :init, 1}
      _ -> false
    end
  end

  # The composer parent id of a gate child run.
  defp parent_of(child_id, ctx) do
    {:ok, child} = WorkflowRun.by_id(child_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))
    child.parent_run_id
  end

  defp event_kinds(parent_id, ctx) do
    {:ok, events} =
      WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    Enum.map(events, & &1.kind)
  end

  # Bounded poll until the parent's durable `wave_paused` marker lands — the
  # composer subscribes to the gates topic BEFORE appending it, so once it is
  # durable the composer is subscribed and a decision broadcast cannot be missed
  # (closes the subscribe-before-decision race in these run_sync-driven tests).
  defp await_wave_paused(parent_id, ctx, tries \\ 500) do
    cond do
      :wave_paused in event_kinds(parent_id, ctx) ->
        :ok

      tries > 0 ->
        Process.sleep(20)
        await_wave_paused(parent_id, ctx, tries - 1)

      true ->
        flunk("wave_paused never appeared for parent #{parent_id}")
    end
  end

  # Best-effort bounded poll until the orphaned wave executor deregisters from
  # RunRegistry (count → 0), i.e. its durable write landed. async:false means
  # the composer's wave is the only live run, so count == 0 ⟺ the write is done.
  # Best-effort: returns after the bound without asserting, so this hygiene drain
  # can never itself flake the test.
  defp drain_run_registry(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    drain_loop(deadline)
  end

  defp drain_loop(deadline) do
    cond do
      Registry.count(RunRegistry) == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        drain_loop(deadline)
    end
  end
end
