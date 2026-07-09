defmodule JidoClaw.Eval.ComposerACAssertionsCaseTest do
  @moduledoc """
  Slice 2 of the evidence floor (OB1-3) — the eval payoff: a `:composer`
  eval case through `RouteComposer.run_sync/1` whose launch premises carry
  acceptance criteria, with the AC extractor stubbed at its
  `:ac_extract_generate` seam (the `composer_vendor_case_test.exs` shape —
  zero real LLMs).

  Two lanes:

    * violated lane — a T1 assertion whose pattern misses the real tree ⇒
      the engine finding appears and rides Hook R (the `action_needed`
      artifact under producer `"evidence"` carries the finding's location —
      the extractor's file_hint, stable across waves since assertions are
      launch-cached) and the run honestly refuses to converge;
    * fail-open lane — the extractor seam failing ⇒ slice 2 off for the
      run, which converges with no evidence artifacts.

  Non-async (`TenantCase`): mutates global app env and the runs hit the DB
  under a shared sandbox. Forge persistence disabled (the hermetic
  `ready_start_test` pattern).
  """

  use JidoClaw.TenantCase, async: false

  @moduletag :capture_log

  alias JidoClaw.Eval
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowEvent
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
      }
    })

    Application.put_env(:jido_claw, :executor_fake_outputs, %{
      "coder" => %{
        "summary" => "DIFF (ac case): implemented the request.",
        "status" => "completed",
        "files_changed" => ["lib/feature.ex"],
        "notes" => "n/a",
        "artifacts" => %{}
      }
    })

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :executor_fake_outputs)
      Application.delete_env(:jido_claw, :ac_extract_generate)
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "evalac")

    context = %{
      tenant_id: tenant,
      session_id: "evalac-sess",
      session_uuid: session.id,
      workspace_id: "evalac-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, context: context}
  end

  # One completing producer — the AC assertion violation, not a worker claim,
  # drives the evidence lane.
  defp catalog do
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
        )
    }
  end

  defp stub_extractor(assertions) do
    Application.put_env(:jido_claw, :ac_extract_generate, fn _input, _schema, _opts ->
      {:ok,
       %ReqLLM.Response{
         id: "test",
         model: "test",
         context: nil,
         object: %{"assertions" => assertions}
       }}
    end)
  end

  defp run_case(ctx, id, premises, assertions) do
    eval_case = %{
      id: id,
      kind: :composer,
      request: %{
        catalog: catalog(),
        live: ["request-received", "code"],
        artifacts: %{"request" => %{"seed" => "Build the feature"}},
        premises: premises,
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

  test "a violated T1 assertion becomes an engine finding riding Hook R — never a plain green",
       ctx do
    # Scans exactly mix.exs (bounded); the pattern misses ⇒ :contradicted.
    stub_extractor([
      %{
        "ac_id" => "AC1",
        "assertion" => "the sentinel constant is defined",
        "tier" => "T1_CONSTANT",
        "file_hint" => "mix.exs",
        "pattern" => "THIS_SENTINEL_CONSTANT_DOES_NOT_EXIST_ANYWHERE_9f3c"
      }
    ])

    assert {:ok, run} =
             run_case(
               ctx,
               "ob1-3-ac-violated",
               %{"path" => "code", "acceptance_criteria" => ["the sentinel constant is defined"]},
               %{
                 # No fixer on the route: the report-only stop — a live
                 # `findings:evidence` is never converged (loop.ex's
                 # fixer-less-route guard). The action directive carries the
                 # finding's location (the file_hint — a violation always has
                 # one: contradiction requires scanned files), and the
                 # encrypted evidence-report carries the AC section.
                 terminal: :not_converged,
                 ran: ["implementer"],
                 artifact_contains: [
                   {"action_needed", "evidence", "(mix.exs)"},
                   {"evidence-report", "evidence", "AC1"}
                 ]
               }
             )

    assert run.status == :passed,
           "AC-violated case failed: error=#{inspect(run.error)} " <>
             "assertions=#{inspect(Enum.reject(run.assertions, &(&1.status == :passed)), pretty: true)}"

    assert run.observations.terminal == :not_converged

    # Review P2 — the durable breach ledger: the AC violation counts under
    # the validator-reserved "evidence:ac" key. In-memory summary because
    # `:not_converged` is failure-family (its durable result carries
    # disposition+error); the event stream is the durable authority (the
    # established fix_failed pattern).
    assert run.result.summary.evidence_breaches == %{"evidence:ac" => 1}

    parent_id = run.result.summary.parent_run_id

    {:ok, events} =
      WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    assert [classified] = Enum.filter(events, &(&1.kind == :evidence_classified))
    assert classified.payload["ac"] == %{"total" => 1, "violated" => ["AC1"]}

    # The worker's own claims are clean — the AC violation alone drives the
    # breach (per-stage attribution stays honest).
    refute Enum.any?(classified.payload["classifications"], & &1["breach"])
  end

  test "extractor-seam failure fails open: slice 2 off, the run converges, no finding", ctx do
    Application.put_env(:jido_claw, :ac_extract_generate, fn _input, _schema, _opts ->
      {:error, :provider_down}
    end)

    assert {:ok, run} =
             run_case(
               ctx,
               "ob1-3-ac-fail-open",
               %{"path" => "code", "acceptance_criteria" => ["the sentinel constant is defined"]},
               %{terminal: :converged, ran: ["implementer"]}
             )

    assert run.status == :passed,
           "AC fail-open case failed: error=#{inspect(run.error)} " <>
             "assertions=#{inspect(Enum.reject(run.assertions, &(&1.status == :passed)), pretty: true)}"

    # No evidence artifacts were produced anywhere in the run.
    refute Map.has_key?(run.result.summary.artifacts, "action_needed")
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
