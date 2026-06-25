defmodule JidoClaw.FrontDoorTest do
  @moduledoc """
  AR-8 front door (Phase 3c/3d). Mirrors Alp River: assert the **routing decision
  + seeding contract**, never the LLM's judgment (triage is the deterministic
  `TriageStub`, the composer launch is behind the `FrontDoorComposerStub` seam).

  Non-async (`TenantCase`): mutates `:triage_*` / `:front_door_*` / `:ask_runtime`
  app env and runs a live session worker.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.FrontDoor
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Test.ForgeStub
  alias JidoClaw.Test.HandoffDispatchCapture
  alias JidoClaw.Triage.Verdict

  setup do
    tmp = Path.join(System.tmp_dir!(), "frontdoor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    %{tenant_id: tenant_id, workspace: workspace, session: session} =
      seed_full(tenant_label: "frontdoor", workspace: [path: tmp])

    rsid = session.external_id
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, rsid, actor: actor)
    :ok = SessionWorker.set_session_uuid(tenant_id, rsid, session.id)

    saved =
      Map.new(
        ~w(triage_impl triage_canned_verdict triage_capture front_door_composer
           front_door_create_mode front_door_ensure_mode ask_runtime
           dispatch_capture_target dispatch_capture_response recorder_flush_timeout
           triage_sensitive_deadline_ms)a,
        &{&1, Application.fetch_env(:jido_claw, &1)}
      )

    # Triage + composer launch are stubbed; the composer is NOT actually started
    # (ensure :noop) unless a test opts into :delegate, so no real wave workers run.
    Application.put_env(:jido_claw, :triage_impl, JidoClaw.Test.TriageStub)
    Application.put_env(:jido_claw, :front_door_composer, JidoClaw.Test.FrontDoorComposerStub)
    Application.put_env(:jido_claw, :front_door_create_mode, :delegate)
    Application.put_env(:jido_claw, :front_door_ensure_mode, :noop)
    Application.put_env(:jido_claw, :recorder_flush_timeout, 50)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, :error} -> Application.delete_env(:jido_claw, key)
        {key, {:ok, value}} -> Application.put_env(:jido_claw, key, value)
      end)

      File.rm_rf!(tmp)
    end)

    ctx = %{
      tenant_id: tenant_id,
      session_id: rsid,
      session_uuid: session.id,
      workspace_id: rsid,
      workspace_uuid: workspace.id,
      project_dir: tmp,
      user_id: nil,
      actor: actor,
      agent_id: "main",
      agent_template: "main"
    }

    {:ok, ctx: ctx, tenant_id: tenant_id, rsid: rsid, session: session, actor: actor, tmp: tmp}
  end

  defp canned(verdict_or_path),
    do: Application.put_env(:jido_claw, :triage_canned_verdict, verdict_or_path)

  defp composer_runs(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant_id, actor: ctx.actor)
    Enum.filter(runs, &(&1.workflow_type == "composer"))
  end

  defp reload(parent_id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(parent_id, tenant: ctx.tenant_id, actor: ctx.actor)
    parent
  end

  defp events(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant_id, actor: ctx.actor)
    events
  end

  defp event(parent_id, ctx, kind), do: Enum.find(events(parent_id, ctx), &(&1.kind == kind))

  # Resolve the seeded `intent` artifact value from the genesis artifacts_produced
  # event's ref (seed rows are stored :pending, resolvable by ref).
  defp seeded_intent(parent_id, ctx) do
    produced = event(parent_id, ctx, :artifacts_produced)
    triple = Enum.find(produced.payload["artifacts"], &(&1["name"] == "intent"))

    {:ok, value} =
      ComposerArtifact.resolve_value(triple["ref"], tenant: ctx.tenant_id, actor: ctx.actor)

    value
  end

  # ===========================================================================
  # decide/2 routing
  # ===========================================================================

  describe "decide/2 inline routing" do
    test "talk routes inline and creates no composer run", %{ctx: ctx} do
      canned(:talk)
      assert {:inline, %Verdict{path: :talk}} = FrontDoor.decide("how does X work?", ctx)
      assert composer_runs(ctx) == []
    end
  end

  describe "decide/2 sketch composer routing (AR-8b)" do
    test "sketch launches a composer in a per-prototype .prototypes/ sandbox", %{ctx: ctx} do
      canned(:sketch)

      assert {:composer, {:ok, %{path: :sketch, parent_run_id: id, message: msg}}} =
               FrontDoor.decide("sketch a throwaway rate-limiter prototype", ctx)

      assert is_binary(msg)
      parent = reload(id, ctx)
      assert parent.workflow_type == "composer"

      # The launch scope is the isolated per-prototype sandbox, not the real cwd.
      proto = parent.config["context"]["project_dir"]
      assert String.starts_with?(proto, Path.join(ctx.project_dir, ".prototypes"))
      assert File.dir?(proto)
      assert parent.config["context"]["workspace_id"] =~ ":proto:"

      # prototype_id rides premises for Phase C (AR-8b-2) graduation provenance.
      assert is_binary(parent.config["premises"]["prototype_id"])
      assert parent.config["premises"]["prototype_dir"] == proto

      # seeded live: path + the seed signal, but NO plan-gate (throwaway).
      live = event(id, ctx, :signals_published).payload["signals"]
      assert "sketch" in live
      assert "request-received" in live
      refute "plan-needed" in live
    end

    test "a sketch with no project_dir hard-fails (no inline fall-through)", %{ctx: ctx} do
      canned(:sketch)
      ctx = Map.delete(ctx, :project_dir)

      assert {:composer, {:error, %{path: :sketch}}} =
               FrontDoor.decide("sketch something", ctx)

      # Fail-closed: no parent created, never handed to the mutation-capable agent.
      assert composer_runs(ctx) == []
    end
  end

  # ===========================================================================
  # AR-8b-2 F2 — the must-execute exec sketch tier launch decision (D7)
  # ===========================================================================

  describe "decide/2 must-execute exec sketch (AR-8b-2 F2)" do
    setup do
      # The Forge facade is stubbed so the exec-launch decision runs without a
      # live microVM. Default outcome `:ok` (echo `{:ok, session_id}`).
      cleanup = ForgeStub.install([])
      on_exit(cleanup)
      :ok
    end

    test "a ready exec session seeds must-execute and threads forge_session_key", %{ctx: ctx} do
      canned(%Verdict{path: :sketch, signals: [:must_execute]})
      ForgeStub.set_start_ready_result(:ok)

      assert {:composer, {:ok, %{path: :sketch, parent_run_id: id}}} =
               FrontDoor.decide("sketch and RUN a rate limiter", ctx)

      # Seeded exactly the `must-execute` discriminator — NOT `sketch-plain`.
      live = event(id, ctx, :signals_published).payload["signals"]
      assert "sketch" in live
      assert "must-execute" in live
      refute "sketch-plain" in live

      # The forge_session_key is threaded into the persisted context (D5) and
      # equals the session start_session_ready was called with.
      forge_key = reload(id, ctx).config["context"]["forge_session_key"]
      assert is_binary(forge_key)
      assert [%{session_id: ^forge_key, spec: spec}] = ForgeStub.start_readies()
      # The spec is the no-egress, globally-unmounted Docker exec spec (5.2/1.6).
      assert spec.sandbox == :docker_sandbox
      assert spec.sandbox_spec.network == :none
      assert spec.sandbox_spec.isolate_global_config == true
      assert spec.sandbox_spec.workdir == "/proto"
      assert spec.workspace_uuid == ctx.workspace_uuid
    end

    test "a failed exec launch degrades to a file-only sketch (sketch-plain + notice)", %{
      ctx: ctx
    } do
      canned(%Verdict{path: :sketch, signals: [:must_execute]})
      ForgeStub.set_start_ready_result({:error, :egress_unavailable})

      assert {:composer, {:ok, %{path: :sketch, parent_run_id: id, message: msg}}} =
               FrontDoor.decide("sketch and run a rate limiter", ctx)

      # Degraded: seeded `sketch-plain`, NOT `must-execute` (pins no double-seed).
      live = event(id, ctx, :signals_published).payload["signals"]
      assert "sketch-plain" in live
      refute "must-execute" in live

      # The ack tells the user execution was unavailable, and no session key was
      # threaded (the exec session never came up).
      assert msg =~ "Execution wasn't available"
      refute Map.has_key?(reload(id, ctx).config["context"], "forge_session_key")
    end

    test "a missing workspace_uuid degrades (can't persist a Forge session)", %{ctx: ctx} do
      canned(%Verdict{path: :sketch, signals: [:must_execute]})
      ctx = Map.delete(ctx, :workspace_uuid)

      assert {:composer, {:ok, %{path: :sketch, parent_run_id: id, message: msg}}} =
               FrontDoor.decide("sketch and run it", ctx)

      assert msg =~ "Execution wasn't available"
      # Never even attempted a Forge session (no real UUID to persist one).
      assert ForgeStub.start_readies() == []
      live = event(id, ctx, :signals_published).payload["signals"]
      assert "sketch-plain" in live
    end

    test "Window 1b: a live exec session is torn down when the composer launch fails",
         %{ctx: ctx} do
      canned(%Verdict{path: :sketch, signals: [:must_execute]})
      ForgeStub.set_start_ready_result(:ok)
      # The session comes up, but the composer launch then fails (Window 1b).
      Application.put_env(:jido_claw, :front_door_create_mode, :error)

      assert {:composer, {:error, %{path: :sketch, message: msg}}} =
               FrontDoor.decide("sketch and run it", ctx)

      # Bounded error ack (NOT a degrade — the whole run failed to start)...
      assert msg =~ "couldn't start"
      assert composer_runs(ctx) == []
      # ...and the front door tore down the live exec session it owned.
      assert [%{session_id: forge_key}] = ForgeStub.start_readies()
      assert forge_key in ForgeStub.stops()
    end
  end

  describe "decide/2 composer routing (Option-A seed)" do
    test "code starts a :running composer with the seeded context/ran/live", %{ctx: ctx} do
      canned(%Verdict{path: :code, signals: [:auth_surface]})

      assert {:composer, {:ok, %{path: :code, parent_run_id: id, message: msg}}} =
               FrontDoor.decide("implement a foo/0 that returns :ok", ctx)

      assert is_binary(msg)
      parent = reload(id, ctx)
      assert parent.workflow_type == "composer"
      assert parent.status == :running

      # context persisted (incl workspace_id — the inline turn's session_id).
      assert parent.config["context"]["workspace_id"] == ctx.workspace_id
      assert parent.config["context"]["project_dir"] == ctx.project_dir

      # ran seeded via the genesis wave_completed(-1, ["triage"]).
      genesis = event(id, ctx, :wave_completed)
      assert genesis.payload["wave_index"] == -1
      assert genesis.payload["stages"] == ["triage"]

      # live seeded: path + plan-needed + the seed signal + the mapped early signal.
      live = event(id, ctx, :signals_published).payload["signals"]
      assert "code" in live
      assert "plan-needed" in live
      assert "request-received" in live
      assert "auth-surface" in live
    end

    test "system starts a composer the same way", %{ctx: ctx} do
      canned(:system)

      assert {:composer, {:ok, %{path: :system, parent_run_id: id}}} =
               FrontDoor.decide("upgrade the toolchain", ctx)

      assert "system" in event(id, ctx, :signals_published).payload["signals"]
      assert reload(id, ctx).status == :running
    end
  end

  describe "decide/2 P1 sensitive marking (the :secrets early signal)" do
    test "a :secrets verdict marks the run sensitive + bounded and the ack omits the intent",
         %{ctx: ctx} do
      canned(%Verdict{path: :code, signals: [:secrets]})

      assert {:composer, {:ok, %{parent_run_id: id, message: msg}}} =
               FrontDoor.decide("rotate SUPERSECRETTOKEN42 in config", ctx)

      # Marked + bounded together (a marked run REQUIRES a positive deadline).
      config = reload(id, ctx).config
      assert config["sanitize_sensitive_context"] == true
      assert is_integer(config["deadline_at_ms"])

      # The sensitive ack must NOT preview the (secret-bearing) intent — the ack
      # string bypasses the scrub pipeline and goes straight to the surface.
      assert msg =~ "sensitive"
      refute msg =~ "SUPERSECRETTOKEN42"
    end

    test "a non-secrets verdict is neither marked nor bounded and the ack previews the intent",
         %{ctx: ctx} do
      canned(%Verdict{path: :code, signals: [:auth_surface]})

      assert {:composer, {:ok, %{parent_run_id: id, message: msg}}} =
               FrontDoor.decide("implement a foo/0 helper", ctx)

      # No over-marking: an unmarked run sets no deadline (deadline_config/1 only
      # stamps deadline_at_ms for a positive ms).
      config = reload(id, ctx).config
      refute config["sanitize_sensitive_context"] == true
      refute Map.has_key?(config, "deadline_at_ms")

      # An unmarked run's ack still previews the intent.
      refute msg =~ "sensitive"
      assert msg =~ "implement a foo/0 helper"
    end
  end

  describe "decide/2 history window (stickiness inputs)" do
    test "triage sees recent history excluding the current turn", %{
      ctx: ctx,
      tenant_id: t,
      rsid: rsid
    } do
      canned(:talk)
      Application.put_env(:jido_claw, :triage_capture, self())

      # Prior turns + the current turn (the seam persists it before decide).
      SessionWorker.add_message(t, rsid, :user, "older question", nil)
      SessionWorker.add_message(t, rsid, :assistant, "older answer", nil)
      SessionWorker.add_message(t, rsid, :user, "do it", nil)

      assert {:inline, _} = FrontDoor.decide("do it", ctx)

      assert_receive {:triage_classify, "do it", opts}
      history = Keyword.fetch!(opts, :history)
      # The current "do it" turn is excluded; the two prior turns are present.
      refute Enum.any?(history, &(&1.content == "do it"))
      assert Enum.any?(history, &(&1.content == "older question"))
      assert Enum.any?(history, &(&1.content == "older answer"))
    end
  end

  describe "decide/2 P1 safety — a failed launch never falls through to the inline agent" do
    test "a code verdict whose create_parent_run fails returns a bounded error ack", %{ctx: ctx} do
      canned(:code)
      Application.put_env(:jido_claw, :front_door_create_mode, :error)

      assert {:composer, {:error, %{path: :code, message: msg}}} =
               FrontDoor.decide("implement it", ctx)

      # No parent created, and the ack is a short stable string — never inspect(reason).
      assert composer_runs(ctx) == []
      refute msg =~ "forced"
      refute msg =~ "{:"
      assert msg =~ "couldn't start"
    end

    test "R3-P1: a forced ensure_started failure leaves the orphan parent terminal, not :running",
         %{ctx: ctx} do
      canned(:code)
      # A real :running parent with a malformed config catalog: the REAL
      # ensure_started (delegate) fails closed and — because the front door passes
      # terminalize_on_failure?: true — terminalizes it.
      parent = malformed_catalog_parent(ctx)
      Application.put_env(:jido_claw, :front_door_create_mode, {:return, parent})
      Application.put_env(:jido_claw, :front_door_ensure_mode, :delegate)

      assert {:composer, {:error, %{path: :code}}} = FrontDoor.decide("implement it", ctx)
      assert reload(parent.id, ctx).status == :failed
    end
  end

  describe "decide/2 intent seeding (R2-P2 / R3-P2)" do
    test "a blank verdict intent is synthesized from the message; the ack is a capped preview",
         %{ctx: ctx} do
      canned(%Verdict{path: :code, intent: nil})
      long = String.duplicate("implement the very large feature ", 20)

      assert {:composer, {:ok, %{parent_run_id: id, message: msg}}} = FrontDoor.decide(long, ctx)

      # FULL intent (== the message) is stored in the artifact (non-empty)...
      assert seeded_intent(id, ctx) == long
      # ...but the ack shows only a capped preview (truncated, not the raw message).
      assert String.length(msg) < String.length(long)
      assert msg =~ "…"
    end
  end

  describe "decide/2 persists the path for observability" do
    test "the latest verdict path is stored as a string under last_triage_path", %{ctx: ctx} do
      canned(:talk)
      assert {:inline, _} = FrontDoor.decide("a question", ctx)

      {:ok, session} =
        ConversationsSession.by_id(ctx.session_uuid, tenant: ctx.tenant_id, actor: ctx.actor)

      assert session.metadata["last_triage_path"] == "talk"
    end
  end

  # ===========================================================================
  # chat/4 seam: the inline path is unchanged, the divert never invokes it
  # ===========================================================================

  describe "chat/4 turn seam" do
    setup %{tenant_id: t} do
      Application.put_env(:jido_claw, :ask_runtime, HandoffDispatchCapture)
      Application.put_env(:jido_claw, :dispatch_capture_target, self())
      Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "ECHO"})
      {:ok, t: t}
    end

    test "a talk turn reaches the inline agent unchanged (regression)", %{
      rsid: rsid,
      t: t,
      tmp: tmp,
      actor: actor
    } do
      canned(:talk)

      assert {:ok, "ECHO"} =
               JidoClaw.chat(t, rsid, "how does X work?",
                 kind: :api,
                 workspace_id: tmp,
                 external_id: rsid,
                 actor: actor
               )

      # The inline agent WAS invoked.
      assert_receive {:dispatch_capture, _pid, _query, _opts}, 5_000
    end

    test "a code divert that fails to launch returns the ack and never invokes the inline agent",
         %{rsid: rsid, t: t, tmp: tmp, actor: actor} do
      canned(:code)
      Application.put_env(:jido_claw, :front_door_create_mode, :error)

      assert {:ok, msg} =
               JidoClaw.chat(t, rsid, "implement it",
                 kind: :api,
                 workspace_id: tmp,
                 external_id: rsid,
                 actor: actor
               )

      assert msg =~ "couldn't start"
      # P1: the mutation-capable inline agent was NEVER invoked on the divert.
      refute_receive {:dispatch_capture, _pid, _query, _opts}, 300
    end

    test "a :secrets divert with an invalid deadline fails closed before any parent or inline agent",
         %{ctx: ctx, rsid: rsid, t: t, tmp: tmp, actor: actor} do
      canned(%Verdict{path: :code, signals: [:secrets]})
      # A non-positive deadline makes the mark-requires-deadline contract reject the
      # launch in the REAL create_parent_run (validate_sensitive_deadline(true, 0)) —
      # create_mode stays :delegate so the real validation runs, before any parent.
      Application.put_env(:jido_claw, :triage_sensitive_deadline_ms, 0)

      assert {:ok, msg} =
               JidoClaw.chat(t, rsid, "rotate the token",
                 kind: :api,
                 workspace_id: tmp,
                 external_id: rsid,
                 actor: actor
               )

      assert msg =~ "couldn't start"
      # Fail-closed: no parent was created, and the inline agent was NEVER invoked.
      assert composer_runs(ctx) == []
      refute_receive {:dispatch_capture, _pid, _query, _opts}, 300
    end
  end

  # A :running composer parent whose `config["catalog"]` is malformed (decodes
  # atom-safe but is not validator-clean) → the real ensure_started fails closed.
  defp malformed_catalog_parent(ctx) do
    {:ok, parent} =
      WorkflowRun.create(
        %{
          name: "frontdoor-malformed",
          workflow_type: "composer",
          config: %{"catalog" => %{"bad" => %{}}}
        },
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    {:ok, _} =
      WorkflowLog.append(parent, :run_started, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

    reload(parent.id, ctx)
  end
end
