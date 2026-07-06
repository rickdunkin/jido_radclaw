defmodule JidoClaw.RouteComposer.ComposerSelfHealLoopTest do
  @moduledoc """
  AR-4 — the self-heal fixer loop end-to-end through the real composer (stub
  workers, no LLM): a flagged review wave loops review → fix → re-review,
  re-running the touched lenses, SUMMONING a never-run lens the fix wandered into,
  and converging once every lens is clean. The exhaustion → `:route_fix_failed`
  terminal (when the reviewer keeps rejecting past the rerun cap) is covered by
  the "exhaustion" describe block below.

  Non-async (`TenantCase`): mutates global app env + runs async Reactor steps
  under a shared sandbox.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.SystemLoopWorker

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
      Application.delete_env(:jido_claw, :route_composer_review_infra_on)
      Application.delete_env(:jido_claw, :route_composer_review_error_on)
      Application.delete_env(:jido_claw, :route_composer_review_finding_on)
      Application.delete_env(:jido_claw, :route_composer_fixer_signals)

      case previous_server do
        nil -> Application.delete_env(:jido_claw, :step_agent_server)
        mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
      end
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "selfheal")

    context = %{
      tenant_id: tenant,
      session_id: "selfheal-sess",
      session_uuid: session.id,
      workspace_id: "selfheal-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, context: context}
  end

  describe "review → fix → re-review → converge" do
    test "a quality finding once, then clean → re-review the touched lenses, then converge",
         ctx do
      # quality flags on its first review, then passes; correctness/security are clean.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => [1]})

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      # The lens cleared: clean:quality ended live, findings:quality retracted.
      assert MapSet.member?(summary.final_live, "clean:quality")
      refute MapSet.member?(summary.final_live, "findings:quality")

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_converged in ks
      assert reload(summary.parent_run_id, ctx).status == :completed

      # Exactly one stages_invalidated (Hook F): the flagged quality lens PLUS the
      # domain-touched correctness lens (both subscribe code-written) — a generic
      # completed-wave rerun, so NO closed_wave_index.
      [inv] = events(summary.parent_run_id, ctx, :stages_invalidated)
      assert Enum.sort(inv.payload["stages"]) == ["correctness-reviewer", "quality-reviewer"]
      refute Map.has_key?(inv.payload, "closed_wave_index")
    end

    test "the fixer's auth-surface SUMMONS the never-run security lens after the fix", ctx do
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => [1]})

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      # security-reviewer never ran on the first review wave (auth-surface was not
      # live); it is summoned only AFTER the fixer emits auth-surface, and the run
      # converges only once it is clean.
      assert MapSet.member?(summary.ran, "security-reviewer")
      assert MapSet.member?(summary.final_live, "clean:security")

      fixer_wave = first_wave_with(summary.parent_run_id, ctx, "fixer")
      security_wave = first_wave_with(summary.parent_run_id, ctx, "security-reviewer")
      assert is_integer(fixer_wave) and is_integer(security_wave)
      assert security_wave > fixer_wave, "security-reviewer should first run AFTER the fixer wave"
    end

    test "stale feedback is dropped: a since-cleaned lens's feedback is invalidated", ctx do
      # quality flags round 1 then cleans; correctness is clean round 1 then flags
      # round 2 — so the fixer's 2nd run must see ONLY correctness's feedback, not
      # quality's stale feedback. High rerun_cap so the extra domain-touched
      # re-runs don't trip the oscillation guard.
      Application.put_env(
        :jido_claw,
        :route_composer_review_flag_on,
        %{"quality" => [1], "correctness" => [2]}
      )

      assert {:ok, summary} = run(ctx, rerun_cap: 5, max_waves: 30)
      assert summary.terminal == :converged

      # The round-2 Hook R artifacts_invalidated quality's now-stale review-feedback
      # (and review-action) before producing correctness's — so the fixer's later
      # feed carries only the round's open producers.
      invalidated = invalidated_feedback_producers(summary.parent_run_id, ctx)
      assert {"review-feedback", "quality-reviewer"} in invalidated
      assert {"review-action", "quality-reviewer"} in invalidated
    end
  end

  describe "completion-signal injection (the silent-converge guarantee)" do
    test "[P1] a fixer that OMITS code-written still re-invalidates the clean baseline lens",
         ctx do
      # The review P1: the fixer self-reports ONLY `auth-surface`, omitting the
      # mandatory `code-written`. `enforce_completion_signals/2` injects it before the
      # fold, so the fix still re-invalidates the clean `correctness` baseline (which
      # subscribes `code-written`), not just the flagged `quality` lens. WITHOUT
      # injection (on `main`) only `quality-reviewer` re-runs and the run converges
      # with `correctness` un-re-reviewed against the fix — a fix-introduced
      # regression there would go undetected.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => [1]})
      Application.put_env(:jido_claw, :route_composer_fixer_signals, ["auth-surface"])

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      [inv] = events(summary.parent_run_id, ctx, :stages_invalidated)
      # The injection proof: correctness-reviewer is re-invalidated even though the
      # fixer never emitted code-written and correctness never flagged.
      assert "correctness-reviewer" in inv.payload["stages"]
      assert Enum.sort(inv.payload["stages"]) == ["correctness-reviewer", "quality-reviewer"]
    end

    test "an implementer that OMITS code-written still triggers the baseline reviewers", ctx do
      # The implementer (coder) self-reports NO signals. Injection adds `code-written`
      # before the fold, so the two code-domain reviewers (which subscribe it) still
      # run. WITHOUT injection the implementer is not held and no lens fires → a
      # VACUOUS `:converged` with zero review (the worst silent-converge case).
      outputs =
        Map.put(TestFixtures.self_heal_stub_outputs(), "coder", %{
          "signals" => [],
          "diff" => "DIFF: +def authenticate(user)"
        })

      Application.put_env(:jido_claw, :route_composer_stub_outputs, outputs)

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged
      assert MapSet.member?(summary.ran, "quality-reviewer")
      assert MapSet.member?(summary.ran, "correctness-reviewer")
    end

    test "a planner that OMITS plan-ready still advances past planning", ctx do
      # The planner (researcher) self-reports NO signals. Injection adds `plan-ready`
      # before the fold, so the implementer (which subscribes it) still fires —
      # correcting the AR-4 overclaim that a real run self-reports. WITHOUT injection
      # `plan-ready` never goes live, the implementer never runs, and the route
      # converges vacuously at the planner.
      outputs =
        Map.put(TestFixtures.self_heal_stub_outputs(), "researcher", %{
          "signals" => [],
          "plan" => "PLAN: build the auth feature"
        })

      Application.put_env(:jido_claw, :route_composer_stub_outputs, outputs)

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged
      assert MapSet.member?(summary.ran, "implementer")
    end
  end

  describe "route/stage scoping (the correctness lens lives on both code and sketch)" do
    test "a code-run fix loop touches only the code reviewers, never the off-route sketch lens",
         ctx do
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => [1]})

      # The self-heal fixture + a sketch-path reviewer that REUSES the `correctness`
      # lens (the real catalog reuses it on code + sketch). On a CODE run it is
      # route-filtered (never dispatched); the AR-4 helpers key off the stage name +
      # the live route, so the fix loop must invalidate the code `correctness-reviewer`
      # but NEVER this off-route sketch stage (a bare-lens helper would).
      sketch_correctness =
        TestFixtures.stage(
          name: "sketch-correctness-reviewer",
          unit: {:worker_template, "reviewer"},
          lens: "correctness",
          task:
            "Review the sketch prototype for correctness; flag findings, else emit clean:correctness.",
          routes: ["sketch"],
          sub: ["request-received"],
          req: ["request"],
          out: ["findings", "action_needed"],
          pub: ["clean:correctness", "findings:correctness", "scope-shift"]
        )

      catalog =
        Map.put(
          TestFixtures.self_heal_fixture_catalog(),
          "sketch-correctness-reviewer",
          sketch_correctness
        )

      assert {:ok, summary} =
               RouteComposer.run_sync(
                 catalog: catalog,
                 live: TestFixtures.self_heal_seed_live(),
                 artifacts: TestFixtures.self_heal_seed_artifacts(),
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant),
                 context: ctx.context,
                 max_waves: 20,
                 timeout: 30_000
               )

      assert summary.terminal == :converged
      # The off-route sketch stage never ran and was never invalidated.
      refute MapSet.member?(summary.ran, "sketch-correctness-reviewer")

      all_invalidated =
        summary.parent_run_id
        |> events(ctx, :stages_invalidated)
        |> Enum.flat_map(fn e -> e.payload["stages"] || [] end)

      refute "sketch-correctness-reviewer" in all_invalidated
      assert "correctness-reviewer" in all_invalidated
    end
  end

  describe "camus C1-3 Lane A: a judge's unusable verdict rides the infra budget" do
    test "infra × 2 then clean → :converged; infra never consumed the fix budget", ctx do
      # quality's overall drifts out of enum on its first two calls, then a
      # clean approve on the third. Default infra_cap 2 → 3 attempts, camus's
      # INFRA_RETRIES. Pre-fix, the drifted verdict fell through as a silent
      # empty emission: the lens never went clean and the run mis-terminalized
      # :not_converged.
      Application.put_env(:jido_claw, :route_composer_review_infra_on, %{"quality" => [1, 2]})

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged
      assert MapSet.member?(summary.final_live, "clean:quality")

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_converged in ks

      # Two stage_infra events (one per unusable verdict), each naming ONLY the
      # infra'd stage, with NO closed_wave_index (Lane A — the wave itself
      # completed) and NO reason in the durable payload (redaction posture).
      infra_events = events(summary.parent_run_id, ctx, :stage_infra)
      assert [_, _] = infra_events

      for e <- infra_events do
        assert e.payload["stages"] == ["quality-reviewer"]
        refute Map.has_key?(e.payload, "closed_wave_index")
        refute Map.has_key?(e.payload, "reason")
      end

      # rerun_counts untouched: no findings ever emitted, so the fix loop's
      # budget never moved (no stages_invalidated markers at all).
      refute :stages_invalidated in ks
    end

    test "infra :always at infra_cap: 1 → :review_infra_failed (never :fix_failed)", ctx do
      Application.put_env(:jido_claw, :route_composer_review_infra_on, %{"quality" => :always})

      assert {:ok, summary} = run(ctx, infra_cap: 1)
      assert summary.terminal == :review_infra_failed

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_review_infra_failed in ks
      refute :route_fix_failed in ks
      refute :route_budget_exhausted in ks

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert parent.result["disposition"] == "review_infra_failed"
      assert String.starts_with?(parent.error, "review_infra_failed: stages=quality-reviewer")
    end
  end

  describe "camus C1-3 Lane B: a lens-only wave execution error rides the infra budget" do
    test "one failed lens wave → infra retry (fresh key) → :converged", ctx do
      # quality's FIRST call sinks the whole reviewer wave (no canned output →
      # the wave reactor fails); the retry wave re-offers both reviewers and
      # both come back clean.
      Application.put_env(:jido_claw, :route_composer_review_error_on, %{"quality" => [1]})

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged
      assert MapSet.member?(summary.final_live, "clean:quality")
      assert MapSet.member?(summary.final_live, "clean:correctness")

      # ONE stage_infra event for the failed wave, naming the WHOLE dispatched
      # cohort, WITH closed_wave_index (the failed wave never wrote
      # wave_completed — without it a restart would dedupe onto the failed
      # child). Convergence past it proves the retry ran under a fresh
      # idempotency key rather than deduping onto the failed child.
      assert [infra] = events(summary.parent_run_id, ctx, :stage_infra)

      assert Enum.sort(infra.payload["stages"]) == [
               "correctness-reviewer",
               "quality-reviewer"
             ]

      assert is_integer(infra.payload["closed_wave_index"])
    end

    test "lens-only wave errors past infra_cap → :review_infra_failed", ctx do
      Application.put_env(:jido_claw, :route_composer_review_error_on, %{"quality" => :always})

      assert {:ok, summary} = run(ctx, infra_cap: 1)
      assert summary.terminal == :review_infra_failed

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_review_infra_failed in ks
      refute :route_failed in ks

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert parent.result["disposition"] == "review_infra_failed"
      assert String.starts_with?(parent.error, "review_infra_failed: stages=")
    end

    test "a mixed (lens + producer) cohort's wave error keeps today's :route_failed", ctx do
      # An early reviewer that subscribes plan-ready lands in the SAME Kahn
      # level as the implementer → a genuinely mixed cohort. The implementer's
      # :wave_error sinks that wave; the infra lane must NOT claim it.
      early_reviewer =
        TestFixtures.stage(
          name: "architecture-reviewer",
          unit: {:worker_template, "reviewer"},
          lens: "architecture",
          task: "Review the plan early; flag findings, else emit clean:architecture.",
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          out: ["findings", "action_needed"],
          pub: ["clean:architecture", "findings:architecture", "scope-shift"]
        )

      catalog =
        Map.put(TestFixtures.self_heal_fixture_catalog(), "architecture-reviewer", early_reviewer)

      outputs = Map.put(TestFixtures.self_heal_stub_outputs(), "coder", :wave_error)
      Application.put_env(:jido_claw, :route_composer_stub_outputs, outputs)

      assert {:ok, summary} =
               RouteComposer.run_sync(
                 catalog: catalog,
                 live: TestFixtures.self_heal_seed_live(),
                 artifacts: TestFixtures.self_heal_seed_artifacts(),
                 tenant: ctx.tenant,
                 actor: actor_for(ctx.tenant),
                 context: ctx.context,
                 max_waves: 20,
                 timeout: 30_000
               )

      assert summary.terminal == :failed

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_failed in ks
      refute :stage_infra in ks
      refute :route_review_infra_failed in ks
    end
  end

  describe "exhaustion → :route_fix_failed (the reviewers keep rejecting the fix)" do
    test "a reviewer that always rejects past the rerun cap → :route_fix_failed (NOT budget_exhausted)",
         ctx do
      # quality always rejects; a low rerun_cap so the self-heal loop stops. Item 6
      # moved the stop EARLIER (the stall/no-re-review suppression at Hook R — the
      # fixture finding is title-stable, so round 2 is STUCK and the re-review
      # budget is at its cap), but the terminal contract is unchanged: fix_failed
      # with the exhausted lens, never a generic budget stop — the disjoint forward
      # twin of AR-8c's verify_failed.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => :always})

      assert {:ok, summary} = run(ctx, rerun_cap: 1)
      assert summary.terminal == :fix_failed

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_fix_failed in ks
      refute :route_budget_exhausted in ks
      refute :route_verify_failed in ks

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert parent.result["disposition"] == "fix_failed"
      assert String.starts_with?(parent.error, "fix_failed: lenses=quality")
    end
  end

  describe "camus C1-5 stall detection (next-ten #6)" do
    test "a STUCK finding (same key round over round) stops after ONE fixer wave → :fix_failed",
         ctx do
      # quality re-flags the identical titled finding every round. rerun_cap is
      # HIGH (5), so the old exhaustion path would burn ~6 fixer waves before the
      # budget tripped — the round-2 STUCK key is what stops the loop now, and it
      # stops it before a second (wasted, unreviewed-destined) fixer wave.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => :always})

      assert {:ok, summary} = run(ctx, rerun_cap: 5, max_waves: 30)
      assert summary.terminal == :fix_failed
      assert summary.reason == ["quality"]

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_fix_failed in ks
      refute :route_budget_exhausted in ks
      refute :route_not_converged in ks

      # No wasted fixer wave: exactly ONE fixer dispatch (the suppressed Hook R
      # never recorded a re-invalidation — no `stages_invalidated` names the
      # fixer at all).
      assert fixer_wave_count(summary.parent_run_id, ctx) == 1

      fixer_invalidations =
        summary.parent_run_id
        |> events(ctx, :stages_invalidated)
        |> Enum.filter(fn e -> "fixer" in (e.payload["stages"] || []) end)

      assert fixer_invalidations == []

      # The durable finding_keys evidence: two quality rounds, SAME key both
      # times (the stuck identity), keys only — never titles/bodies.
      quality_rounds = finding_key_events(summary.parent_run_id, ctx, "quality")
      assert [round1, round2] = Enum.map(quality_rounds, & &1.payload["keys"])
      assert round1 == round2
      assert [key] = round1
      assert key =~ ~r/^[0-9a-f]{64}$/

      for e <- quality_rounds do
        refute Map.has_key?(e.payload, "title")
        assert [%{"key" => _, "severity" => _, "confidence" => _}] = e.payload["marks"]
      end
    end

    test "an OSCILLATING finding (A → B → A) stops the loop → :fix_failed", ctx do
      # Round 2 flags a DIFFERENT titled finding (B), so the loop legitimately
      # continues; round 3 re-flags A — now in `seen_prior \ prior`, the
      # oscillation set — and the loop stops with exactly TWO fixer waves.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => :always})

      Application.put_env(:jido_claw, :route_composer_review_finding_on, %{
        "quality" => %{
          2 => %{
            "title" => "unbounded recursion",
            "severity" => "error",
            "confidence" => "likely",
            "location" => "lib/auth.ex:90",
            "description" => "the retry loop never terminates"
          }
        }
      })

      assert {:ok, summary} = run(ctx, rerun_cap: 5, max_waves: 30)
      assert summary.terminal == :fix_failed
      assert summary.reason == ["quality"]
      assert fixer_wave_count(summary.parent_run_id, ctx) == 2

      # Three quality rounds durable: A, B, A — round 3's key equals round 1's.
      assert [r1, r2, r3] =
               summary.parent_run_id
               |> finding_key_events(ctx, "quality")
               |> Enum.map(& &1.payload["keys"])

      assert r1 == r3
      assert r2 != r1
    end

    test "an un-keyable (title-less) finding never stall-matches; the re-review budget stop catches it",
         ctx do
      # The camus fail-safe: no title → no key → excluded from stall detection.
      # The stop still happens — the (a) no-fix-without-re-review-budget rule
      # suppresses the re-fire once the reviewer's rerun count reaches the cap.
      untitled = %{
        "severity" => "error",
        "confidence" => "likely",
        "location" => "lib/auth.ex:42",
        "description" => "missing nil check"
      }

      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => :always})

      Application.put_env(:jido_claw, :route_composer_review_finding_on, %{
        "quality" => %{1 => untitled, 2 => untitled}
      })

      assert {:ok, summary} = run(ctx, rerun_cap: 1)
      assert summary.terminal == :fix_failed
      assert fixer_wave_count(summary.parent_run_id, ctx) == 1

      # Both flagged rounds folded with EMPTY keys — no fabricated identity.
      for e <- finding_key_events(summary.parent_run_id, ctx, "quality") do
        assert e.payload["keys"] == []
        assert e.payload["marks"] == []
      end
    end

    test "clean rounds weld the explicit empty finding_keys marker (the round still advances)",
         ctx do
      # quality flags once then cleans: its round-2 CLEAN emission must still
      # weld a finding_keys marker with keys: [] — oscillation detection needs
      # the round to advance through clean rounds.
      Application.put_env(:jido_claw, :route_composer_review_flag_on, %{"quality" => [1]})

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      assert [flagged, clean] =
               summary.parent_run_id
               |> finding_key_events(ctx, "quality")
               |> Enum.map(& &1.payload["keys"])

      assert [_key] = flagged
      assert clean == []
    end
  end

  # --- helpers ---

  defp run(ctx, opts \\ []) do
    RouteComposer.run_sync(
      [
        catalog: TestFixtures.self_heal_fixture_catalog(),
        live: TestFixtures.self_heal_seed_live(),
        artifacts: TestFixtures.self_heal_seed_artifacts(),
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant),
        context: ctx.context,
        max_waves: Keyword.get(opts, :max_waves, 20),
        timeout: 30_000
      ] ++ Keyword.take(opts, [:rerun_cap, :infra_cap])
    )
  end

  defp all_events(parent_id, ctx) do
    {:ok, events} =
      WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    events
  end

  defp kinds(parent_id, ctx), do: Enum.map(all_events(parent_id, ctx), & &1.kind)

  defp events(parent_id, ctx, kind),
    do: Enum.filter(all_events(parent_id, ctx), &(&1.kind == kind))

  # The wave_index of the first wave_started whose stages include `stage`.
  defp first_wave_with(parent_id, ctx, stage) do
    parent_id
    |> events(ctx, :wave_started)
    |> Enum.filter(fn e -> stage in (e.payload["stages"] || []) end)
    |> Enum.map(& &1.payload["wave_index"])
    |> Enum.min(fn -> nil end)
  end

  # How many waves dispatched the fixer (item 6: the stall stop must not burn
  # extra fixer waves).
  defp fixer_wave_count(parent_id, ctx) do
    parent_id
    |> events(ctx, :wave_started)
    |> Enum.count(fn e -> "fixer" in (e.payload["stages"] || []) end)
  end

  # The lens's durable finding_keys markers, in seq order.
  defp finding_key_events(parent_id, ctx, lens) do
    parent_id
    |> events(ctx, :finding_keys)
    |> Enum.filter(&(&1.payload["lens"] == lens))
    |> Enum.sort_by(& &1.seq)
  end

  # Every {name, producer} pair any artifacts_invalidated event deleted.
  defp invalidated_feedback_producers(parent_id, ctx) do
    parent_id
    |> events(ctx, :artifacts_invalidated)
    |> Enum.flat_map(fn e -> e.payload["artifacts"] || [] end)
    |> Enum.map(fn a -> {a["name"], a["producer"]} end)
    |> MapSet.new()
  end

  defp reload(parent_id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(parent_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))
    parent
  end
end
