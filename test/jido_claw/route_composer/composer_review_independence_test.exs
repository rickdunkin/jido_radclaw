defmodule JidoClaw.RouteComposer.ComposerReviewIndependenceTest do
  @moduledoc """
  Item 7 PR-3 (camus C1-1) — the cross-vendor review configuration through the
  REAL composer:

    * strict same-vendor config refuses at LAUNCH (`run_sync` surfaces
      `{:error, {:start_failed, {:review_independence_held, _}}}`, the front
      door terminalizes the parent) — never a wave, never a verdict;
    * a malformed `review:` section rides the same refusal with the distinct
      config reason;
    * `independence: degraded` starts, warns, and converges — the reviewer
      wave dispatching through the knob to the scripted codex vendor;
    * fresh session per re-review round: a findings → fix → approve loop
      drives TWO distinct vendor sessions (two `ScriptedDepositRunner`
      `:prompt` captures via `:deposit_rounds`).

  Non-async (`TenantCase`): mutates global app env and runs waves under a
  shared sandbox. Forge persistence disabled (the hermetic pattern).
  """

  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker

  setup do
    prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    prev_aliases = Application.get_env(:jido_ai, :model_aliases)
    prev_server = Application.get_env(:jido_claw, :step_agent_server)

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
      restore_env(:jido_ai, :model_aliases, prev_aliases)
      restore_env(:jido_claw, :step_agent_server, prev_server)
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :route_composer_stub_outputs)
      Application.delete_env(:jido_claw, :executor_vendor_runners)
      Application.delete_env(:jido_claw, :executor_fake_outputs)
      Application.delete_env(:jido_claw, :scripted_deposit_runner)
    end)

    project_dir =
      Path.join(System.tmp_dir!(), "jido_ri_composer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(project_dir, ".jido"))
    on_exit(fn -> File.rm_rf!(project_dir) end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "ripr3")

    context = %{
      tenant_id: tenant,
      session_id: "ripr3-sess",
      session_uuid: session.id,
      workspace_id: "ripr3-ws",
      workspace_uuid: workspace.id,
      project_dir: project_dir
    }

    {:ok, tenant: tenant, context: context, project_dir: project_dir}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp arm_review_config!(project_dir, yaml) do
    File.write!(Path.join([project_dir, ".jido", "config.yaml"]), yaml)
  end

  # implementer(coder) → quality-reviewer(reviewer). The reviewer is NOT in
  # the template override on the knob-driven tests, so the `review:` section
  # binds it; the coder stays in-process (real template on the refusal tests —
  # never dispatched — and the StubWorker on the degraded run).
  defp knob_catalog do
    %{
      "implementer" =>
        TestFixtures.stage(
          name: "implementer",
          unit: {:worker_template, "coder"},
          task: "Implement the request; emit code-written.",
          routes: ["code"],
          sub: ["request-received"],
          req: ["request"],
          out: ["diff"],
          pub: ["code-written", "scope-shift"]
        ),
      "quality-reviewer" =>
        TestFixtures.stage(
          name: "quality-reviewer",
          unit: {:worker_template, "reviewer"},
          lens: "quality",
          task: "Review the diff for quality; flag findings, else emit clean:quality.",
          routes: ["code"],
          sub: ["code-written"],
          req: ["diff"],
          out: ["findings"],
          pub: ["clean:quality", "findings:quality", "scope-shift"]
        )
    }
  end

  defp base_run_opts(ctx) do
    [
      catalog: knob_catalog(),
      live: ["request-received", "code"],
      artifacts: %{"request" => %{"seed" => "Build the feature"}},
      tenant: ctx.tenant,
      actor: actor_for(ctx.tenant),
      context: ctx.context,
      max_waves: 8,
      timeout: 60_000
    ]
  end

  # Best-effort drain so a late wave-executor durable write cannot cross the
  # sandbox teardown; never asserts.
  defp drain_run_registry(0), do: :ok

  defp drain_run_registry(tries) do
    if Registry.count(RunRegistry) == 0 do
      :ok
    else
      Process.sleep(10)
      drain_run_registry(tries - 1)
    end
  end

  test "strict same-vendor config refuses at launch — no wave, parent terminalized", ctx do
    Application.put_env(:jido_ai, :model_aliases, %{fast: "openai:gpt-4.1"})
    arm_review_config!(ctx.project_dir, "review:\n  executor: codex\n")

    opts = base_run_opts(ctx)

    # The run_sync surface: create_parent_run succeeds, start_composer's init
    # fence refuses, the with-chain surfaces the reason verbatim.
    assert {:error, {:start_failed, {:review_independence_held, details}}} =
             RouteComposer.run_sync(opts)

    assert details.scope == :catalog
    assert [%{stage: "quality-reviewer", producer: "implementer"}] = details.violations

    # The durable terminal on the SAME front-door path, held explicitly.
    {:ok, parent} = RouteComposer.create_parent_run(opts)

    assert {:error, {:start_failed, {:review_independence_held, _details}}} =
             RouteComposer.start_composer(opts, parent)

    {:ok, reloaded} =
      WorkflowRun.by_id(parent.id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    assert reloaded.status == :failed
    assert reloaded.error =~ "composer_start_failed"
    assert reloaded.error =~ "review_independence_held"
  end

  test "a malformed review section refuses the launch with the config reason", ctx do
    arm_review_config!(ctx.project_dir, "review:\n  executer: codex\n")

    assert {:error, {:start_failed, {:invalid_review_config, msg}}} =
             RouteComposer.run_sync(base_run_opts(ctx))

    assert msg =~ "executer"
  end

  test "PR-4: strict hold TRIGGERED by a producer stage override — no wave", ctx do
    # The in-process producer resolves openai — INDEPENDENT of the anthropic
    # reviewer knob; ONLY the producer stage's {:forge, :claude_code} override
    # manufactures the collision. (The executor-nil variants of this catalog
    # passing/holding exactly as before — the :139 strict test and the
    # degraded run below — are the nil-override preservation pin.)
    Application.put_env(:jido_ai, :model_aliases, %{fast: "openai:gpt-4.1"})
    arm_review_config!(ctx.project_dir, "review:\n  executor: claude_code\n")

    catalog =
      Map.update!(knob_catalog(), "implementer", &%{&1 | executor: {:forge, :claude_code}})

    opts = Keyword.put(base_run_opts(ctx), :catalog, catalog)

    assert {:error, {:start_failed, {:review_independence_held, details}}} =
             RouteComposer.run_sync(opts)

    assert [
             %{
               stage: "quality-reviewer",
               producer: "implementer",
               reviewer_provider: "anthropic",
               producer_provider: "anthropic"
             }
           ] = details.violations
  end

  test "PR-4: degraded pass with the vendor binding from a reviewer STAGE override", ctx do
    StubStore.setup()
    Application.put_env(:jido_ai, :model_aliases, %{fast: "openai:gpt-4.1"})

    # NO executor knob — the vendor binding comes from the STAGE override;
    # degraded accepts the openai/openai collision (in-process producer vs
    # the codex-overridden reviewer stage).
    arm_review_config!(ctx.project_dir, "review:\n  independence: degraded\n")

    Application.put_env(:jido_claw, :agent_templates_override, %{
      "coder" => %{
        module: StubWorker,
        description: "stage-override stub coder",
        model: :fast,
        max_iterations: 1
      }
    })

    Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)

    Application.put_env(:jido_claw, :route_composer_stub_outputs, %{
      "coder" => %{
        "signals" => ["code-written"],
        "diff" => "DIFF: +def feature(), do: :ok"
      }
    })

    Application.put_env(:jido_claw, :executor_vendor_runners, %{
      codex: JidoClaw.Test.ScriptedDepositRunner
    })

    Application.put_env(:jido_claw, :scripted_deposit_runner, %{
      deposits: [TestFixtures.phase1_clean_reviewer()],
      output: "stage-override vendor reviewer output",
      notify: self()
    })

    catalog =
      Map.update!(knob_catalog(), "quality-reviewer", &%{&1 | executor: {:forge, :codex}})

    opts = Keyword.put(base_run_opts(ctx), :catalog, catalog)

    log =
      capture_log(fn ->
        assert {:ok, summary} = RouteComposer.run_sync(opts)
        assert summary.terminal == :converged
        assert MapSet.member?(summary.ran, "quality-reviewer")
      end)

    assert log =~ "degraded independence accepted"

    # The reviewer wave really dispatched through the STAGE-override vendor
    # executor — the full wave-options → AgentStep → AgentRunner →
    # apply_executor/4 thread.
    assert_received {:scripted_deposit_runner, :prompt, prompt}
    assert prompt =~ "Review the diff for quality"

    drain_run_registry(200)
  end

  test "degraded independence starts, warns, and converges through the knob-bound vendor",
       ctx do
    StubStore.setup()
    Application.put_env(:jido_ai, :model_aliases, %{fast: "openai:gpt-4.1"})

    arm_review_config!(
      ctx.project_dir,
      "review:\n  executor: codex\n  independence: degraded\n"
    )

    # The producer runs as an in-process StubWorker (override authoritative —
    # still resolving :fast → openai, the collision); the reviewer is NOT
    # overridden, so the knob routes it to the scripted codex vendor.
    Application.put_env(:jido_claw, :agent_templates_override, %{
      "coder" => %{
        module: StubWorker,
        description: "degraded-run stub coder",
        model: :fast,
        max_iterations: 1
      }
    })

    Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)

    Application.put_env(:jido_claw, :route_composer_stub_outputs, %{
      "coder" => %{
        "signals" => ["code-written"],
        "diff" => "DIFF: +def feature(), do: :ok"
      }
    })

    Application.put_env(:jido_claw, :executor_vendor_runners, %{
      codex: JidoClaw.Test.ScriptedDepositRunner
    })

    Application.put_env(:jido_claw, :scripted_deposit_runner, %{
      deposits: [TestFixtures.phase1_clean_reviewer()],
      output: "degraded vendor reviewer output",
      notify: self()
    })

    log =
      capture_log(fn ->
        assert {:ok, summary} = RouteComposer.run_sync(base_run_opts(ctx))
        assert summary.terminal == :converged
        assert MapSet.member?(summary.ran, "quality-reviewer")
      end)

    assert log =~ "degraded independence accepted"

    # The reviewer wave really dispatched through the vendor executor.
    assert_received {:scripted_deposit_runner, :prompt, prompt}
    assert prompt =~ "Review the diff for quality"

    drain_run_registry(200)
  end

  test "fresh session per re-review round: findings → fix → approve runs TWO vendor sessions",
       ctx do
    # The vendor binding rides the override here (the PR-2 vendor-case shape —
    # executor-level behavior, knob-independent): implementer + fixer on
    # {:forge, :fake}, reviewer on scripted codex.
    Application.put_env(:jido_claw, :agent_templates_override, %{
      "coder" => %{
        module: JidoClaw.Agent.Workers.Coder,
        description: "forge-fake coder",
        model: :fast,
        executor: {:forge, :fake}
      },
      "fixer" => %{
        module: JidoClaw.Agent.Workers.Fixer,
        description: "forge-fake fixer",
        model: :fast,
        executor: {:forge, :fake}
      },
      "reviewer" => %{
        module: JidoClaw.Agent.Workers.Reviewer,
        description: "vendor-executed reviewer",
        model: :fast,
        executor: {:forge, :codex}
      }
    })

    Application.put_env(:jido_claw, :executor_vendor_runners, %{
      codex: JidoClaw.Test.ScriptedDepositRunner
    })

    Application.put_env(:jido_claw, :executor_fake_outputs, %{
      "coder" => %{
        "summary" => "DIFF (two-round): implemented the request.",
        "status" => "completed",
        "files_changed" => ["lib/feature.ex"],
        "notes" => "n/a",
        "artifacts" => %{}
      },
      "fixer" => %{
        "summary" => "FIX: added the nil check before the deref.",
        "status" => "completed",
        "files_changed" => ["lib/auth.ex"],
        "notes" => "n/a",
        "signals" => ["code-written"],
        "artifacts" => %{}
      }
    })

    # Round 1 flags a keyable finding; round 2 (a NEW session after the fix
    # wave) approves. The rounds advance on the test-owned atomics counter —
    # one bump per `run_iteration`, i.e. per vendor session.
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{
      deposit_rounds: [
        [TestFixtures.phase1_findings_reviewer()],
        [TestFixtures.phase1_clean_reviewer()]
      ],
      round_counter: :atomics.new(1, []),
      output: "two-round vendor reviewer output",
      notify: self()
    })

    catalog = %{
      "implementer" =>
        TestFixtures.stage(
          name: "implementer",
          unit: {:worker_template, "coder"},
          task: "Implement the request; emit code-written.",
          routes: ["code"],
          sub: ["request-received"],
          req: ["request"],
          out: ["diff"],
          pub: ["code-written", "scope-shift"]
        ),
      "quality-reviewer" =>
        TestFixtures.stage(
          name: "quality-reviewer",
          unit: {:worker_template, "reviewer"},
          lens: "quality",
          task: "Review the diff for quality; flag findings, else emit clean:quality.",
          routes: ["code"],
          sub: ["code-written"],
          req: ["diff"],
          opt: ["fix"],
          out: ["findings", "action_needed"],
          pub: ["clean:quality", "findings:quality", "scope-shift"]
        ),
      "fixer" =>
        TestFixtures.stage(
          name: "fixer",
          unit: {:worker_template, "fixer"},
          task: "Resolve the open review findings against the diff; emit code-written.",
          routes: ["code"],
          sub: ["findings"],
          req: ["diff"],
          opt: ["review-feedback", "review-action"],
          out: ["fix"],
          pub: ["code-written", "scope-shift"]
        )
    }

    opts = Keyword.put(base_run_opts(ctx), :catalog, catalog)

    assert {:ok, summary} = RouteComposer.run_sync(opts)
    assert summary.terminal == :converged
    assert MapSet.member?(summary.ran, "fixer")

    # TWO fresh vendor sessions — one per review round (the PR-3 pin).
    assert_received {:scripted_deposit_runner, :prompt, first_prompt}
    assert_received {:scripted_deposit_runner, :prompt, second_prompt}
    refute_received {:scripted_deposit_runner, :prompt, _third}

    assert first_prompt =~ "Review the diff for quality"
    assert second_prompt =~ "Review the diff for quality"

    drain_run_registry(200)
  end
end
