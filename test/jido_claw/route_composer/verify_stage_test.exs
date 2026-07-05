defmodule JidoClaw.RouteComposer.VerifyStageTest do
  @moduledoc """
  Item 5 — the deterministic verify authority end-to-end through the real
  composer (stub workers + the hermetic `JidoClaw.Test.VerifyStub` runner/git
  seams — no subprocess, no real git): green certification, the defer-to-last
  peel, red → Hook R fixer feedback → re-verify, exhaustion → `:verify_failed`,
  inconclusive → the infra lane, tampered → the evidence-preserving
  `:verify_tampered` terminal, the uncertified-green reclassification, and the
  Phase-2 sealed-head/convergence-re-check laws.

  Non-async (`TenantCase`): mutates global app env + the singleton
  Registry/DynamicSupervisor, and runs async Reactor steps under a shared
  sandbox.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Projection, as: ComposerProjection
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.SystemLoopWorker

  @supervisor JidoClaw.RouteComposer.Supervisor

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
      seed_full(tenant_label: "verifystage")

    context = %{
      tenant_id: tenant,
      session_id: "verify-sess",
      session_uuid: session.id,
      workspace_id: "verify-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, actor: actor_for(tenant), context: context}
  end

  describe "green converge + certification" do
    test "an exit-0 verify certifies {head, tree_digest} and converges", ctx do
      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      assert MapSet.member?(summary.final_live, "clean:verify")
      assert MapSet.member?(summary.ran, "verify")

      # The green welded its certificate into the SAME commit as the publish:
      # every clean:verify publish has a matching verify_certified.
      certs = events(summary.parent_run_id, ctx, :verify_certified)
      assert [cert] = certs
      assert cert.payload["stage"] == "verify"
      assert cert.payload["head"] == "verifystubhead"
      assert cert.payload["tree_digest"] == "verifystubdigest"
      assert cert.payload["mode"] == "working_tree"
      assert clean_verify_publish_count(summary.parent_run_id, ctx) == length(certs)

      # The engine observed the HEAD baseline durably (C1-6b).
      assert [baseline | _rest] = events(summary.parent_run_id, ctx, :head_observed)
      assert baseline.payload["head"] == "verifystubhead"

      # A GREEN report is a usable verdict: routable + active.
      assert %{"verify-report" => %{"verify" => ref}} =
               Map.take(summary.artifacts, ["verify-report"])

      assert {:ok, rows} = ComposerArtifact.active_for_run(summary.parent_run_id, auth(ctx))
      assert Enum.any?(rows, &(&1.ref == ref and &1.name == "verify-report"))
    end

    test "defer-order: a mixed reviewer+verify cohort dispatches the reviewers first, verify solo after",
         ctx do
      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      reviewer_wave = first_wave_with(summary.parent_run_id, ctx, "quality-reviewer")
      verify_wave = first_wave_with(summary.parent_run_id, ctx, "verify")
      assert is_integer(reviewer_wave) and is_integer(verify_wave)
      assert verify_wave > reviewer_wave, "verify must run AFTER the reviewers in its Kahn level"

      # Every verify dispatch is solo (never beside another stage).
      for event <- events(summary.parent_run_id, ctx, :wave_started),
          "verify" in (event.payload["stages"] || []) do
        assert event.payload["stages"] == ["verify"]
      end
    end
  end

  describe "red → Hook R fixer feedback → deferred solo re-verify → green" do
    test "a red verify feeds the fixer its findings, then the re-verify certifies green", ctx do
      script(%{results: [{1, "3 tests failed"}, {0, ""}]})

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      # The paired verdict flipped: the red's findings:verify is retracted.
      assert MapSet.member?(summary.final_live, "clean:verify")
      refute MapSet.member?(summary.final_live, "findings:verify")

      # Hook R fed the fixer the VERIFY stage's findings out-of-band.
      produced = produced_artifact_pairs(summary.parent_run_id, ctx)
      assert {"review-feedback", "verify"} in produced
      assert {"review-action", "verify"} in produced

      fixer_wave = first_wave_with(summary.parent_run_id, ctx, "fixer")
      reverify_wave = last_wave_with(summary.parent_run_id, ctx, "verify")
      assert is_integer(fixer_wave)
      assert reverify_wave > fixer_wave, "the re-verify must run after the fixer wave"

      # Only the GREEN certifies.
      assert [_one] = events(summary.parent_run_id, ctx, :verify_certified)
    end

    test "red exhaustion past the rerun cap → :verify_failed (never :fix_failed)", ctx do
      script(%{results: [{1, "still failing"}]})

      assert {:ok, summary} = run(ctx, rerun_cap: 1)
      assert summary.terminal == :verify_failed

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_verify_failed in ks
      refute :route_fix_failed in ks
      refute :route_budget_exhausted in ks

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert parent.result["disposition"] == "verify_failed"
      assert String.starts_with?(parent.error, "verify_failed: lenses=verify")
    end
  end

  describe "inconclusive rides the infra lane" do
    test "missing_tool past infra_cap → :review_infra_failed, and NO report is ever stored",
         ctx do
      script(%{results: [{127, "command not found: mix"}]})

      assert {:ok, summary} = run(ctx, infra_cap: 1)
      assert summary.terminal == :review_infra_failed

      infra_events = events(summary.parent_run_id, ctx, :stage_infra)
      assert infra_events != []
      for event <- infra_events, do: assert(event.payload["stages"] == ["verify"])

      # The no-orphan invariant, refusal half: an inconclusive stores NOTHING —
      # no report row, no routable artifact.
      assert {:ok, rows} = ComposerArtifact.active_for_run(summary.parent_run_id, auth(ctx))
      refute Enum.any?(rows, &(&1.name == "verify-report"))
      refute {"verify-report", "verify"} in produced_artifact_pairs(summary.parent_run_id, ctx)

      parent = reload(summary.parent_run_id, ctx)
      assert parent.result["disposition"] == "review_infra_failed"
    end

    test "a config error (shell-syntax override) rides the infra lane, never Lane-B route_failed",
         ctx do
      assert {:ok, summary} = run(ctx, verify_override: "mix test | tail -5", infra_cap: 0)
      assert summary.terminal == :review_infra_failed

      ks = kinds(summary.parent_run_id, ctx)
      assert :stage_infra in ks
      assert :route_review_infra_failed in ks
      refute :route_failed in ks
    end
  end

  describe "tampered → :verify_tampered (evidence-preserving, no fixer)" do
    test "a tracked mutation during verify terminalizes with the report reachable via the marker",
         ctx do
      # The tree digest changes between the before/after captures — a check
      # edited tracked content mid-verify.
      script(%{results: [{0, ""}], diff_digest: ["digest-before", "digest-after"]})

      # Pin the documented one-count-per-engine-verify telemetry contract
      # (telemetry.ex): the reactor's `emit_verify(:tampered)` is the single
      # bump — the composer's post-commit observability keeps its Trace but
      # must not re-emit the counter.
      handler = "verify-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:jido_claw, :verify],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:verify_telemetry, metadata.result})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      drain_verify_telemetry()

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :verify_tampered

      assert_receive {:verify_telemetry, :tampered}, 5_000
      refute_receive {:verify_telemetry, _result}, 500

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert parent.result["disposition"] == "verify_tampered"
      assert is_binary(parent.result["report_ref"])
      report_ref = parent.result["report_ref"]

      # The durable tamper record names the stage + bounded reason + the ref.
      assert [tampered] = events(summary.parent_run_id, ctx, :stage_tampered)
      assert tampered.payload["stage"] == "verify"
      assert tampered.payload["reason"] =~ "tracked_mutation"
      assert tampered.payload["report_ref"] == report_ref

      # Evidence intact: the report row is ACTIVE and decrypts to the tampered
      # envelope…
      assert {:ok, rows} = ComposerArtifact.active_for_run(summary.parent_run_id, auth(ctx))
      assert Enum.any?(rows, &(&1.ref == report_ref and &1.name == "verify-report"))
      assert {:ok, report} = ComposerArtifact.resolve_value(report_ref, auth(ctx))
      assert report["tampered"] == true

      # …but it is NEVER routable: not in artifacts_produced, not in the fold
      # store, and the tampered stage never folded into ran.
      refute {"verify-report", "verify"} in produced_artifact_pairs(summary.parent_run_id, ctx)
      refute Map.has_key?(summary.artifacts, "verify-report")
      refute MapSet.member?(rebuilt_state(summary.parent_run_id, ctx).ran, "verify")

      # VERIFY_OATH: no remediation — the fixer never fires.
      refute first_wave_with(summary.parent_run_id, ctx, "fixer")
    end

    test "tamper precedence: tampered outranks a simultaneous budget exhaustion", ctx do
      script(%{results: [{0, ""}], diff_digest: ["digest-before", "digest-after"]})

      # max_waves == the tampered wave count, so over_budget? is true at the
      # same tick the tamper terminal fires.
      assert {:ok, summary} = run(ctx, max_waves: 4)
      assert summary.terminal == :verify_tampered

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_verify_tampered in ks
      refute :route_budget_exhausted in ks
    end

    test "restart after the tampered wave commit but before the terminal re-terminalizes from parent events alone",
         ctx do
      # Craft the crash window durably: a parent whose log holds the welded
      # stage_tampered marker but NO terminal (the composer died in between).
      parent =
        create_verified_shape_parent(ctx, ran: ["planner", "implementer", "quality-reviewer"])

      report_ref = "art_" <> String.duplicate("ab", 12)

      append!(
        parent,
        :stage_tampered,
        %{
          stage: "verify",
          reason: "tampered: kinds=tracked_mutation checks=mix:precommit",
          report_ref: report_ref
        },
        ctx
      )

      {:ok, _pid} = RouteComposer.ensure_started(recovery_opts(ctx), parent)
      assert :failed = await_status(parent.id, ctx, :failed, 15_000)

      reloaded = reload(parent.id, ctx)
      assert reloaded.result["disposition"] == "verify_tampered"
      assert reloaded.result["report_ref"] == report_ref
      assert reloaded.error =~ "verify_tampered: stage=verify"

      # The rebuild never consulted a child result and never re-dispatched:
      # the tick terminalized ahead of any wave.
      refute :wave_started in kinds(parent.id, ctx)
    end
  end

  describe "the uncertified-green guard (fail closed BEFORE the durable green)" do
    test "a dedupe-bound clean:verify with no certification is reclassified inconclusive, never folded",
         ctx do
      parent =
        create_verified_shape_parent(ctx, ran: ["planner", "implementer", "quality-reviewer"])

      # A restart re-dispatch will bind this crafted completed child (the
      # composer:<parent>:0 key): a green claim WITHOUT a certificate.
      report_ref = "art_" <> String.duplicate("cd", 12)

      craft_completed_child(parent, 0, ctx, %{
        "wave_index" => 0,
        "emissions" => [
          %{
            "stage" => "verify",
            "signals" => ["clean:verify"],
            "artifacts" => %{"verify-report" => report_ref}
          }
        ]
      })

      {:ok, _pid} = RouteComposer.ensure_started(recovery_opts(ctx), parent)
      assert :completed = await_status(parent.id, ctx, :completed, 15_000)

      # The uncertified green was reclassified to the infra lane (stage_infra),
      # its report preserved via the NON-ROUTING marker…
      assert Enum.any?(
               events(parent.id, ctx, :stage_infra),
               &(&1.payload["stages"] == ["verify"])
             )

      assert [recorded] = events(parent.id, ctx, :verify_report_recorded)
      assert recorded.payload["stage"] == "verify"
      assert recorded.payload["report_ref"] == report_ref
      assert recorded.payload["reason"] == "uncertified_green"

      # The UNCERTIFIED report ref never entered artifacts_produced (the
      # RETRY's real green report routes normally — that one may).
      refute report_ref in produced_artifact_refs(parent.id, ctx)

      # …and the committed invariant holds: every clean:verify publish has its
      # same-commit certificate (the crafted claim published nothing).
      assert clean_verify_publish_count(parent.id, ctx) ==
               length(events(parent.id, ctx, :verify_certified))

      # The retry (a fresh wave past the crafted child) certified for real.
      assert [cert] = events(parent.id, ctx, :verify_certified)
      assert cert.payload["head"] == "verifystubhead"
    end
  end

  describe "laundered-green guards (Hook F + the convergence-time re-check)" do
    test "a fixer wave retracts a live clean:verify in the same welded batch (Hook F)", ctx do
      # Seed verify as already-run-and-green (the shape a stale green would
      # have), then flag quality so the fixer fires.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => [1]})

      assert {:ok, summary} =
               run(ctx,
                 live: ["clean:verify" | TestFixtures.verify_seed_live()],
                 ran: ["verify"]
               )

      assert summary.terminal == :converged

      # The welded Hook F batch: the stale green retracted + verify invalidated
      # alongside the domain-touched reviewer.
      assert Enum.any?(
               events(summary.parent_run_id, ctx, :signals_retracted),
               &("clean:verify" in (&1.payload["signals"] || []))
             )

      assert Enum.any?(
               events(summary.parent_run_id, ctx, :stages_invalidated),
               &("verify" in (&1.payload["stages"] || []))
             )

      # The re-verify ran and certified; convergence waited for it.
      assert last_wave_with(summary.parent_run_id, ctx, "verify") >
               first_wave_with(summary.parent_run_id, ctx, "fixer")

      assert [_cert] = events(summary.parent_run_id, ctx, :verify_certified)
    end

    test "a live clean:verify with NO certificate fails the convergence re-check closed", ctx do
      # Seeded green, everything else clean → the would-be :converged tick must
      # retract + re-verify instead (no verified_integrity to hold against).
      assert {:ok, summary} =
               run(ctx,
                 live: ["clean:verify" | TestFixtures.verify_seed_live()],
                 ran: ["verify"]
               )

      assert summary.terminal == :converged

      assert Enum.any?(
               events(summary.parent_run_id, ctx, :signals_retracted),
               &("clean:verify" in (&1.payload["signals"] || []))
             )

      # The re-verify happened and certified — only then did the run converge.
      assert is_integer(first_wave_with(summary.parent_run_id, ctx, "verify"))
      assert [_cert] = events(summary.parent_run_id, ctx, :verify_certified)
    end
  end

  describe "Phase 2 — sealed heads + the convergence-time integrity re-check" do
    test "an external HEAD move during downtime is caught by the durable baseline: retract, re-verify sealed, converge",
         ctx do
      parent = create_certified_parent(ctx)

      # The external move lands while the composer is down.
      script(%{head: "movedhead"})

      {:ok, _pid} = RouteComposer.ensure_started(recovery_opts(ctx), parent)
      assert :completed = await_status(parent.id, ctx, :completed, 15_000)

      # The stale green was retracted (never converged on the laundered green)…
      assert Enum.any?(
               events(parent.id, ctx, :signals_retracted),
               &("clean:verify" in (&1.payload["signals"] || []))
             )

      # …the re-verify ran, and the durable head record now names the move.
      assert is_integer(first_wave_with(parent.id, ctx, "verify"))
      heads = Enum.map(events(parent.id, ctx, :head_observed), & &1.payload["head"])
      assert "movedhead" in heads

      # The observed change derived a seal: the final certificate is SEALED at
      # the moved head.
      assert cert = Enum.max_by(events(parent.id, ctx, :verify_certified), & &1.seq)
      assert cert.payload["mode"] == "sealed"
      assert cert.payload["head"] == "movedhead"
    end

    test "an external tracked EDIT with HEAD unchanged fails the working-tree tuple re-check",
         ctx do
      parent = create_certified_parent(ctx)

      # HEAD unchanged; the tracked-tree digest moved (the P1 tuple case a
      # HEAD-only compare would miss).
      script(%{diff_digest: "editeddigest"})

      {:ok, _pid} = RouteComposer.ensure_started(recovery_opts(ctx), parent)
      assert :completed = await_status(parent.id, ctx, :completed, 15_000)

      assert Enum.any?(
               events(parent.id, ctx, :signals_retracted),
               &("clean:verify" in (&1.payload["signals"] || []))
             )

      assert is_integer(first_wave_with(parent.id, ctx, "verify"))

      # The re-verify re-certified against the NEW digest.
      assert cert = Enum.max_by(events(parent.id, ctx, :verify_certified), & &1.seq)
      assert cert.payload["tree_digest"] == "editeddigest"
    end

    test "an UNREADABLE capture at the re-check refuses convergence and rides the infra lane",
         ctx do
      parent = create_certified_parent(ctx, infra_cap: 1)

      # git is unreadable at resume: the re-check must not converge, and the
      # re-verify's own capture failure is integrity_unavailable → infra.
      script(%{head: nil})

      {:ok, _pid} = RouteComposer.ensure_started(recovery_opts(ctx), parent)
      assert :failed = await_status(parent.id, ctx, :failed, 15_000)

      reloaded = reload(parent.id, ctx)
      assert reloaded.result["disposition"] == "review_infra_failed"
      refute :route_converged in kinds(parent.id, ctx)
    end

    test "invalidating the verify stage clears the durable certificate (projection + mirror agree)",
         ctx do
      parent = create_certified_parent(ctx)
      script(%{head: "movedhead"})

      {:ok, _pid} = RouteComposer.ensure_started(recovery_opts(ctx), parent)
      assert :completed = await_status(parent.id, ctx, :completed, 15_000)

      log = all_events(parent.id, ctx)
      invalidation_seq = Enum.find(log, &(&1.kind == :stages_invalidated)).seq

      # Projected THROUGH the invalidation: the crafted certificate is cleared
      # (no stale-certificate reuse); the FULL log re-certifies.
      prefix = Enum.filter(log, &(&1.seq <= invalidation_seq))
      assert ComposerProjection.project(seed_state(), prefix).verified_integrity == nil

      full = ComposerProjection.project(seed_state(), log)
      assert %{stage: "verify", head: "movedhead"} = full.verified_integrity
    end
  end

  # --- helpers ---

  defp run(ctx, opts \\ []) do
    RouteComposer.run_sync(
      [
        catalog: TestFixtures.verify_fixture_catalog(),
        live: Keyword.get(opts, :live, TestFixtures.verify_seed_live()),
        artifacts: TestFixtures.verify_seed_artifacts(),
        tenant: ctx.tenant,
        actor: ctx.actor,
        context: ctx.context,
        max_waves: Keyword.get(opts, :max_waves, 20),
        timeout: 30_000
      ] ++ Keyword.take(opts, [:rerun_cap, :infra_cap, :verify_override, :ran])
    )
  end

  defp script(map), do: Application.put_env(:jido_claw, :route_composer_verify_stub, map)

  # A prior in-file test's verify emission could still be in the mailbox —
  # drain before pinning an exact count.
  defp drain_verify_telemetry do
    receive do
      {:verify_telemetry, _result} -> drain_verify_telemetry()
    after
      0 -> :ok
    end
  end

  defp auth(ctx), do: [tenant: ctx.tenant, actor: ctx.actor]

  # A parent whose durable log already holds a fully-converged-but-unterminated
  # shape MINUS verify (`create_verified_shape_parent`) or INCLUDING a
  # certified green verify (`create_certified_parent`) — the crash-window
  # crafting pattern (only non-status-authority kinds are appended).
  defp create_verified_shape_parent(ctx, opts) do
    {:ok, parent} =
      RouteComposer.create_parent_run(
        catalog: TestFixtures.verify_fixture_catalog(),
        live:
          TestFixtures.verify_seed_live() ++
            ["plan-ready", "code-written", "clean:quality"],
        artifacts: TestFixtures.verify_seed_artifacts(),
        ran: Keyword.fetch!(opts, :ran),
        tenant: ctx.tenant,
        actor: ctx.actor,
        context: ctx.context,
        max_waves: 10,
        infra_cap: Keyword.get(opts, :infra_cap)
      )

    parent
  end

  defp create_certified_parent(ctx, opts \\ []) do
    parent =
      create_verified_shape_parent(
        ctx,
        Keyword.merge([ran: ["planner", "implementer", "quality-reviewer"]], opts)
      )

    append!(parent, :wave_completed, %{wave_index: 0, stages: ["verify"]}, ctx)
    append!(parent, :signals_published, %{signals: ["clean:verify"]}, ctx)
    append!(parent, :head_observed, %{head: "verifystubhead"}, ctx)

    append!(
      parent,
      :verify_certified,
      %{
        stage: "verify",
        head: "verifystubhead",
        tree_digest: "verifystubdigest",
        mode: "working_tree"
      },
      ctx
    )

    parent
  end

  defp append!(parent, kind, payload, ctx) do
    {:ok, _event} = WorkflowLog.append(parent, kind, payload, auth(ctx))
  end

  # A crafted completed wave child under the deterministic launch key, carrying
  # an explicit result (the dedupe-hit shape).
  defp craft_completed_child(parent, wave_index, ctx, result) do
    {:ok, child} =
      WorkflowRun.create(
        %{
          name: "wave-#{wave_index}",
          workflow_type: "reactor",
          parent_run_id: parent.id,
          idempotency_key: "composer:#{parent.id}:#{wave_index}"
        },
        auth(ctx)
      )

    append!(child, :run_started, %{}, ctx)
    append!(child, :run_completed, %{result: result}, ctx)
    child
  end

  defp recovery_opts(ctx), do: [tenant: ctx.tenant, actor: ctx.actor]

  # The minimal projection seed (the composer init fields the fold touches).
  defp seed_state do
    %{
      live: MapSet.new(),
      artifacts: %{},
      ran: MapSet.new(),
      premises: %{},
      prev_route: [],
      wave_index: 0,
      rerun_counts: %{},
      infra_counts: %{},
      tampered_stages: %{},
      observed_head: nil,
      sealed_head: nil,
      verified_integrity: nil
    }
  end

  defp rebuilt_state(parent_id, ctx),
    do: ComposerProjection.project(seed_state(), all_events(parent_id, ctx))

  defp all_events(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, auth(ctx))
    events
  end

  defp kinds(parent_id, ctx), do: Enum.map(all_events(parent_id, ctx), & &1.kind)

  defp events(parent_id, ctx, kind),
    do: Enum.filter(all_events(parent_id, ctx), &(&1.kind == kind))

  defp clean_verify_publish_count(parent_id, ctx) do
    parent_id
    |> events(ctx, :signals_published)
    |> Enum.count(&("clean:verify" in (&1.payload["signals"] || [])))
  end

  defp produced_artifact_pairs(parent_id, ctx) do
    parent_id
    |> produced_artifact_entries(ctx)
    |> Enum.map(fn entry -> {entry["name"], entry["producer"]} end)
    |> MapSet.new()
  end

  defp produced_artifact_refs(parent_id, ctx) do
    parent_id
    |> produced_artifact_entries(ctx)
    |> Enum.map(fn entry -> entry["ref"] end)
    |> MapSet.new()
  end

  defp produced_artifact_entries(parent_id, ctx) do
    parent_id
    |> events(ctx, :artifacts_produced)
    |> Enum.flat_map(fn event -> event.payload["artifacts"] || [] end)
  end

  defp first_wave_with(parent_id, ctx, stage) do
    parent_id
    |> wave_indexes_with(ctx, stage)
    |> Enum.min(fn -> nil end)
  end

  defp last_wave_with(parent_id, ctx, stage) do
    parent_id
    |> wave_indexes_with(ctx, stage)
    |> Enum.max(fn -> nil end)
  end

  defp wave_indexes_with(parent_id, ctx, stage) do
    parent_id
    |> events(ctx, :wave_started)
    |> Enum.filter(fn event -> stage in (event.payload["stages"] || []) end)
    |> Enum.map(& &1.payload["wave_index"])
  end

  defp reload(parent_id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(parent_id, auth(ctx))
    parent
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
