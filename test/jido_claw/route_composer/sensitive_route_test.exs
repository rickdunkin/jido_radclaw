defmodule JidoClaw.RouteComposer.SensitiveRouteTest do
  @moduledoc """
  AR-2 Phase 2b — the P1 payoff. Routes a composer with `sanitize_sensitive_context:
  true` over fixtures carrying a unique secret in the `diff`/`approved-plan`/`plan`
  artifacts, and asserts the secret is:

    * encrypted at rest in `ComposerArtifact` (ciphertext column) but decryptable
      via `resolve_value/2`;
    * absent **plaintext** from every durable inline sink the stub flow reaches —
      `messages` (SubagentTranscript task/terminal), `workflow_steps.output`,
      `workflow_runs.result`/`error` (ReactorMiddleware); and
    * never copied into any child wave's `replay_inputs` (omitted, A3).

  (The async tool-signal sinks — Recorder tool rows, Audit, Trace, OutputShaper —
  require real tool calls the typed-output stub never makes, so they are covered
  by `JidoClaw.Security.SensitiveScrubSinksTest`.)

  Non-async (`TenantCase`): mutates global app env + runs async Reactor steps
  under a shared sandbox.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit.AsyncWriter
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker

  @secret "ZZSECRETDIFFZZ-#{System.unique_integer([:positive])}"

  setup do
    StubStore.setup()
    previous_server = Application.get_env(:jido_claw, :step_agent_server)

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      TestFixtures.phase1_template_override(StubWorker)
    )

    Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)

    # Sensitive fixture outputs — the secret rides every artifact.
    Application.put_env(:jido_claw, :route_composer_stub_outputs, %{
      "researcher" => %{"signals" => ["plan-ready"], "plan" => "PLAN #{@secret}"},
      "verifier" => %{"signals" => ["plan-approved"], "approved-plan" => "APPROVED #{@secret}"},
      "coder" => %{"signals" => ["code-written", "auth-surface"], "diff" => "DIFF #{@secret}"},
      "reviewer" => TestFixtures.phase1_clean_reviewer()
    })

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :route_composer_stub_outputs)

      case previous_server do
        nil -> Application.delete_env(:jido_claw, :step_agent_server)
        mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
      end
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "sensitive")

    context = %{
      tenant_id: tenant,
      session_id: "sensitive-sess",
      session_uuid: session.id,
      workspace_id: "sensitive-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, actor: actor_for(tenant), context: context}
  end

  defp run_sensitive(ctx) do
    RouteComposer.run_sync(
      catalog: TestFixtures.phase1_catalog(),
      live: TestFixtures.phase1_seed_live(),
      artifacts: TestFixtures.phase1_seed_artifacts(),
      tenant: ctx.tenant,
      actor: ctx.actor,
      context: ctx.context,
      sanitize_sensitive_context: true,
      deadline_ms: 60_000,
      max_waves: 10,
      timeout: 30_000
    )
  end

  test "a sensitive diff/approved-plan is encrypted at rest and leaks nowhere plaintext", ctx do
    assert {:ok, summary} = run_sensitive(ctx)
    assert summary.terminal == :converged

    # Drain the async transcript/recorder writers so durable rows are committed.
    AsyncWriter.flush()

    # --- Encrypted at rest, but decryptable (A / P1) ---
    diff_ref = get_in(summary.artifacts, ["diff", "implementer"])
    assert is_binary(diff_ref) and String.starts_with?(diff_ref, "art_")

    %{rows: rows} =
      JidoClaw.Repo.query!("SELECT encrypted_value FROM composer_artifacts WHERE ref = $1", [
        diff_ref
      ])

    assert [[ciphertext]] = rows
    assert is_binary(ciphertext)
    refute ciphertext =~ @secret

    assert {:ok, value} =
             ComposerArtifact.resolve_value(diff_ref, tenant: ctx.tenant, actor: ctx.actor)

    assert value =~ @secret

    # --- No plaintext in any inline durable sink the stub flow reaches ---
    assert leak_count("messages", ["content", "metadata"]) == 0
    assert leak_count("workflow_steps", ["output"]) == 0
    assert leak_count("workflow_runs", ["result", "error"]) == 0
    assert leak_count("trace_events", ["metadata", "measurements"]) == 0

    # --- No encrypted second copy in any child wave's replay_inputs (A3) ---
    %{rows: [[orphans]]} =
      JidoClaw.Repo.query!(
        "SELECT count(*) FROM workflow_runs WHERE parent_run_id = $1 AND encrypted_replay_inputs IS NOT NULL",
        [Ecto.UUID.dump!(summary.parent_run_id)]
      )

    assert orphans == 0
  end

  test "a marked composer wave that fails redacts the parent terminal error (P1b)", ctx do
    # Override the happy-path stub with an undeclared signal so the first wave
    # fails deterministically (DefaultMapper.map → WaveCollect → {:error, _}),
    # exercising the parent-terminal :run_failed write under a marked run.
    bad =
      :jido_claw
      |> Application.get_env(:route_composer_stub_outputs)
      |> put_in(["researcher", "signals"], ["bogus-signal-#{System.unique_integer([:positive])}"])

    Application.put_env(:jido_claw, :route_composer_stub_outputs, bad)

    assert {:ok, summary} = run_sensitive(ctx)
    assert summary.terminal == :failed

    {:ok, parent} = WorkflowRun.by_id(summary.parent_run_id, tenant: ctx.tenant, actor: ctx.actor)

    # Genesis stamped the durable marker (P1b) — the live GenServer marker never
    # reaches a reloaded-parent terminal write, so the flag is the source of truth.
    assert parent.config["sanitize_sensitive_context"] == true

    # The terminal failure reason is the placeholder, NOT the formatted reason
    # (which an unmarked run keeps with a "failed:" prefix — composer_loop_test).
    assert parent.status == :failed
    assert parent.error == "[composer-sensitive:redacted]"
    refute String.starts_with?(parent.error, "failed:")

    # The scrub is at the append chokepoint, so the durable terminal event payload
    # carries the placeholder too (not a read-time mask). Phase 2c: a loop `:failed`
    # terminal is the `route_failed` kind (not the abnormal-path `:run_failed`).
    {:ok, events} = WorkflowEvent.for_run(parent.id, tenant: ctx.tenant, actor: ctx.actor)
    route_failed = Enum.find(events, &(&1.kind == :route_failed))
    assert route_failed.payload["error"] == "[composer-sensitive:redacted]"
  end

  # The secret is globally unique, so any row anywhere holding it (in any of the
  # given jsonb/text columns) is a leak.
  defp leak_count(table, columns) do
    pattern = "%" <> @secret <> "%"
    where = Enum.map_join(columns, " OR ", &"#{&1}::text LIKE $1")

    %{rows: [[n]]} =
      JidoClaw.Repo.query!("SELECT count(*) FROM #{table} WHERE #{where}", [pattern])

    n
  end
end
