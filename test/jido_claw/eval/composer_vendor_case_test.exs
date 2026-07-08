defmodule JidoClaw.Eval.ComposerVendorCaseTest do
  @moduledoc """
  Item 7 (camus C1-1) PR-2 — the eval payoff: a `:composer` eval case through
  `RouteComposer.run_sync/1` whose reviewer-lens stage runs on the
  `{:forge, :codex}` VENDOR executor, backed by the scripted deposit runner
  (`:executor_vendor_runners` + the runner's own `:scripted_deposit_runner`
  script — zero vendor CLIs). The producer stays `{:forge, :fake}` so the
  vendor lane under test is exactly one lens stage.

  Two lanes, end-to-end through the real `DefaultMapper`/`Verdict` flow:

    * verdict lane — a clean schema-valid deposit converges (`clean:quality`);
    * infra lane — a DRIFTED deposit (out-of-enum `overall`) is rejected by
      the deposit box (the Reviewer's Zoi enum), so the stage lands
      `typed_output: nil` ⇒ `normalize(:review, %{})` ⇒ `{:infra, _}` ⇒ the
      per-stage `infra_cap` retries exhaust ⇒ the `:review_infra_failed`
      summary terminal (durable event kind `:route_review_infra_failed`) —
      never a verdict, never `clean`.

  Non-async (`TenantCase`): mutates global app env and the step envelope's
  transcript/correlation rows hit the DB under a shared sandbox. Forge
  persistence is disabled (the hermetic `ready_start_test` pattern).
  """

  use JidoClaw.TenantCase, async: false

  @moduletag :capture_log

  alias JidoClaw.Eval
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.RouteComposer.TestFixtures

  setup do
    prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    Application.put_env(:jido_claw, :agent_templates_override, %{
      "coder" => %{
        module: JidoClaw.Agent.Workers.Coder,
        description: "forge-fake coder",
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
        "summary" => "DIFF (vendor case): implemented the request.",
        "status" => "completed",
        "files_changed" => ["lib/feature.ex"],
        "notes" => "n/a",
        "artifacts" => %{}
      }
    })

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :executor_vendor_runners)
      Application.delete_env(:jido_claw, :executor_fake_outputs)
      Application.delete_env(:jido_claw, :scripted_deposit_runner)
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "evalpr2")

    context = %{
      tenant_id: tenant,
      session_id: "evalpr2-sess",
      session_uuid: session.id,
      workspace_id: "evalpr2-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, context: context}
  end

  # One producer + one vendor-executed reviewer lens.
  defp vendor_catalog do
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

  defp run_vendor_case(ctx, id, assertions) do
    eval_case = %{
      id: id,
      kind: :composer,
      request: %{
        catalog: vendor_catalog(),
        live: ["request-received", "code"],
        artifacts: %{"request" => %{"seed" => "Build the feature"}},
        max_waves: 8
      },
      assertions: assertions
    }

    result =
      Eval.run_case(eval_case,
        tenant: ctx.tenant,
        actor: actor_for(ctx.tenant),
        context: ctx.context,
        timeout: 60_000
      )

    settle_run_registry(2_000)
    result
  end

  test "verdict lane: a clean vendor deposit converges through the real DefaultMapper/Verdict flow",
       ctx do
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{
      deposits: [TestFixtures.phase1_clean_reviewer()],
      output: "vendor reviewer raw output"
    })

    assert {:ok, run} =
             run_vendor_case(ctx, "pr2-vendor-composer-clean", %{
               terminal: :converged,
               ran: ["implementer", "quality-reviewer"],
               artifact_contains: [{"diff", "implementer", "DIFF (vendor case)"}]
             })

    assert run.status == :passed,
           "PR-2 vendor clean case failed: error=#{inspect(run.error)} " <>
             "assertions=#{inspect(Enum.reject(run.assertions, &(&1.status == :passed)), pretty: true)}"

    assert run.observations.terminal == :converged
  end

  test "item 9: seeded acceptance criteria render into the assembled reviewer prompt (AC ids + citation clause)",
       ctx do
    # The gepa "AC = labeled eval-task candidate" producer case: a run whose
    # premises carry criteria hands every worker wave the `### Acceptance
    # criteria` block, and the reviewer task carries the AC-citation clause.
    # The vendor runner captures the REAL assembled prompt (task +
    # extra_context) — the strongest available "criteria reached the
    # subagent" observation.
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{
      deposits: [TestFixtures.phase1_clean_reviewer()],
      output: "vendor reviewer raw output",
      notify: self()
    })

    citation_clause =
      "When the run premises carry acceptance criteria, verify each against " <>
        "the diff and cite the AC id (AC1, AC2, …) in any related finding."

    catalog =
      Map.update!(vendor_catalog(), "quality-reviewer", fn stage ->
        %{stage | task: stage.task <> " " <> citation_clause}
      end)

    eval_case = %{
      id: "item9-criteria-in-prompt",
      kind: :composer,
      request: %{
        catalog: catalog,
        live: ["request-received", "code"],
        artifacts: %{"request" => %{"seed" => "Build the feature"}},
        premises: %{
          "path" => "code",
          "acceptance_criteria" => ["`mix test` passes", "GET /health returns 200"]
        },
        max_waves: 8
      },
      assertions: %{terminal: :converged, ran: ["implementer", "quality-reviewer"]}
    }

    assert {:ok, run} =
             Eval.run_case(eval_case,
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant),
               context: ctx.context,
               timeout: 60_000
             )

    settle_run_registry(2_000)

    assert run.status == :passed,
           "item-9 criteria case failed: error=#{inspect(run.error)} " <>
             "assertions=#{inspect(Enum.reject(run.assertions, &(&1.status == :passed)), pretty: true)}"

    # The reviewer wave's ACTUAL prompt carried the rendered criteria section
    # with stable ids, and the task carried the citation clause.
    assert_received {:scripted_deposit_runner, :prompt, prompt}
    assert prompt =~ "### Acceptance criteria"
    assert prompt =~ "AC1. `mix test` passes"
    assert prompt =~ "AC2. GET /health returns 200"
    assert prompt =~ "cite the AC id"
  end

  test "infra lane: a drifted vendor deposit is box-rejected ⇒ infra exhaustion — never a verdict",
       ctx do
    # `overall: "maybe"` fails the Reviewer's Zoi enum AT THE BOX (isError to
    # the CLI, nothing stored) — the stage lands typed nil every attempt, so
    # the composer's infra_cap retries exhaust into the infra terminal.
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{
      deposits: [TestFixtures.phase1_infra_reviewer()],
      output: "vendor reviewer drifted output"
    })

    assert {:ok, run} =
             run_vendor_case(ctx, "pr2-vendor-composer-infra", %{
               terminal: :review_infra_failed,
               ran: ["implementer"]
             })

    assert run.status == :passed,
           "PR-2 vendor infra case failed: error=#{inspect(run.error)} " <>
             "assertions=#{inspect(Enum.reject(run.assertions, &(&1.status == :passed)), pretty: true)}"

    assert run.observations.terminal == :review_infra_failed
  end

  # Best-effort drain: give the orphaned wave executor time to deregister so a
  # late durable write cannot cross the sandbox teardown; never asserts.
  defp settle_run_registry(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(Stream.repeatedly(fn -> Registry.count(RunRegistry) end), :ok, fn count,
                                                                                        _ ->
      if count == 0 or System.monotonic_time(:millisecond) >= deadline do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, :ok}
      end
    end)
  end
end
