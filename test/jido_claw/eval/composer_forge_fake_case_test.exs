defmodule JidoClaw.Eval.ComposerForgeFakeCaseTest do
  @moduledoc """
  Item 7 (camus C1-1) PR-1 — the eval payoff: a `:composer` eval case through
  `RouteComposer.run_sync/1` whose stage workers run on the `{:forge, :fake}`
  executor. The arming is `:agent_templates_override` (real worker modules,
  template-level executor binding) + `:executor_fake_outputs` alone — neither
  `:route_composer_stub_outputs` nor `:step_agent_server` (contrast
  `composer_case_test.exs`), so the emissions flow through the REAL seam:
  ForgeExecutor session → Zoi-validated typed output → `DefaultMapper` /
  `Verdict` (clean signals) → fold → convergence. Per-STAGE output differences
  ride the `{:stage, template, step_name}` fixture keys (two concurrent
  reviewer stages over ONE template), never per-stage template overrides.

  Non-async (`TenantCase`): mutates global app env and the step envelope's
  transcript/correlation rows hit the DB under a shared sandbox. Forge
  persistence is disabled (the hermetic `ready_start_test` pattern) — the
  sessions themselves are ephemeral scaffolding, not the subject.
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
        description: "forge-fake reviewer",
        model: :fast,
        executor: {:forge, :fake}
      }
    })

    Application.put_env(:jido_claw, :executor_fake_outputs, %{
      # The producer: coder_result-shaped (Zoi-validated on the forge path —
      # `code-written` is loop-injected, `diff` resolves via the summary
      # fallback, the live-run path).
      "coder" => %{
        "summary" => "DIFF (forge-fake): implemented the request.",
        "status" => "completed",
        "files_changed" => ["lib/feature.ex"],
        "notes" => "n/a",
        "artifacts" => %{}
      },
      # Two concurrent reviewer STAGES over one template — told apart by the
      # {:stage, template, step_name} keys (tuple keys disable the plain
      # fallback, so a resolution miss would fail the wave loudly).
      {:stage, "reviewer", "quality-reviewer"} => TestFixtures.phase1_clean_reviewer(),
      {:stage, "reviewer", "security-reviewer"} => TestFixtures.phase1_clean_reviewer()
    })

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :executor_fake_outputs)
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "evalpr1")

    context = %{
      tenant_id: tenant,
      session_id: "evalpr1-sess",
      session_uuid: session.id,
      workspace_id: "evalpr1-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, context: context}
  end

  # A minimal validator-clean code-path catalog: one producer + two same-
  # template reviewer lenses (the concurrent-stage fixture-key scenario).
  defp forge_fake_catalog do
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
        ),
      "security-reviewer" =>
        TestFixtures.stage(
          name: "security-reviewer",
          unit: {:worker_template, "reviewer"},
          lens: "security",
          task: "Review the diff for security; flag findings, else emit clean:security.",
          routes: ["code"],
          sub: ["code-written"],
          req: ["diff"],
          out: ["findings"],
          pub: ["clean:security", "findings:security", "scope-shift"]
        )
    }
  end

  test "PR-1: a forge-fake-executed route converges through the real DefaultMapper/Verdict flow",
       ctx do
    eval_case = %{
      id: "pr1-forge-fake-composer",
      kind: :composer,
      request: %{
        catalog: forge_fake_catalog(),
        live: ["request-received", "code"],
        artifacts: %{"request" => %{"seed" => "Build the feature"}},
        max_waves: 6
      },
      assertions: %{
        terminal: :converged,
        ran: ["implementer", "quality-reviewer", "security-reviewer"],
        artifact_contains: [{"diff", "implementer", "DIFF (forge-fake)"}]
      }
    }

    assert {:ok, run} =
             Eval.run_case(eval_case,
               tenant: ctx.tenant,
               actor: actor_for(ctx.tenant),
               context: ctx.context,
               timeout: 30_000
             )

    settle_run_registry(2_000)

    assert run.status == :passed,
           "PR-1 composer case failed: error=#{inspect(run.error)} " <>
             "assertions=#{inspect(Enum.reject(run.assertions, &(&1.status == :passed)), pretty: true)}"

    assert run.observations.terminal == :converged
    assert "diff" in run.observations.artifact_names
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
