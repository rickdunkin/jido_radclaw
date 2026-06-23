defmodule JidoClaw.FrontDoorGraduationTest do
  @moduledoc """
  AR-8b-2 C1 — prototype provenance via the durable `pending_prototype` candidate.
  Triage + composer + summarizer are all stubbed (the seam idiom); we assert the
  candidate lifecycle and the graduated seed (premises + intent), never LLM
  judgment.

  Non-async (`TenantCase`): mutates `:triage_*` / `:front_door_*` /
  `:prototype_summary_*` app env and runs a live session worker.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.FrontDoor
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Triage.Verdict

  setup do
    tmp = Path.join(System.tmp_dir!(), "frontdoor-grad-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    %{tenant_id: tenant_id, workspace: workspace, session: session} =
      seed_full(tenant_label: "frontdoor-grad", workspace: [path: tmp])

    rsid = session.external_id
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, rsid, actor: actor)
    :ok = SessionWorker.set_session_uuid(tenant_id, rsid, session.id)

    saved =
      Map.new(
        ~w(triage_impl triage_canned_verdict front_door_composer front_door_create_mode
           front_door_ensure_mode prototype_summary_generate prototype_summary_model
           front_door_clock graduation_candidate_ttl_ms triage_sensitive_deadline_ms)a,
        &{&1, Application.fetch_env(:jido_claw, &1)}
      )

    Application.put_env(:jido_claw, :triage_impl, JidoClaw.Test.TriageStub)
    Application.put_env(:jido_claw, :front_door_composer, JidoClaw.Test.FrontDoorComposerStub)
    Application.put_env(:jido_claw, :front_door_create_mode, :delegate)
    Application.put_env(:jido_claw, :front_door_ensure_mode, :noop)

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

    {:ok, ctx: ctx, tenant_id: tenant_id, actor: actor}
  end

  # --- helpers ---

  defp canned(verdict_or_path),
    do: Application.put_env(:jido_claw, :triage_canned_verdict, verdict_or_path)

  defp stub_summary(text) do
    parent = self()

    Application.put_env(:jido_claw, :prototype_summary_generate, fn _input, _schema, _opts ->
      send(parent, :summary_generated)
      {:ok, %ReqLLM.Response{id: "t", model: "t", context: nil, object: %{"summary" => text}}}
    end)
  end

  defp reload(id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(id, tenant: ctx.tenant_id, actor: ctx.actor)
    parent
  end

  defp session_metadata(ctx) do
    {:ok, session} =
      ConversationsSession.by_id(ctx.session_uuid, tenant: ctx.tenant_id, actor: ctx.actor)

    session.metadata
  end

  defp candidate(ctx), do: session_metadata(ctx)["pending_prototype"]

  defp seeded_intent(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant_id, actor: ctx.actor)
    produced = Enum.find(events, &(&1.kind == :artifacts_produced))
    triple = Enum.find(produced.payload["artifacts"], &(&1["name"] == "intent"))

    {:ok, value} =
      ComposerArtifact.resolve_value(triple["ref"], tenant: ctx.tenant_id, actor: ctx.actor)

    value
  end

  # Run a sketch turn and return {sketch_run_id, prototype_id, prototype_dir}.
  defp sketch!(message, ctx) do
    canned(:sketch)

    assert {:composer, {:ok, %{path: :sketch, parent_run_id: id}}} =
             FrontDoor.decide(message, ctx)

    parent = reload(id, ctx)
    {id, parent.config["premises"]["prototype_id"], parent.config["premises"]["prototype_dir"]}
  end

  defp seed_prototype_file(dir),
    do: File.write!(Path.join(dir, "limiter.ex"), "defmodule Limiter do\n  # token bucket\nend\n")

  # ===========================================================================
  # Candidate write + graduation
  # ===========================================================================

  describe "sketch launch writes the durable candidate" do
    test "a non-sensitive sketch stores a JSON-safe, redacted token candidate", %{ctx: ctx} do
      {sketch_id, proto_id, proto_dir} =
        sketch!(
          "sketch a rate limiter with sk-ant-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA bearer creds",
          ctx
        )

      cand = candidate(ctx)
      assert cand["prototype_id"] == proto_id
      assert cand["prototype_dir"] == proto_dir
      assert cand["run_id"] == sketch_id
      assert is_binary(cand["at"])

      tokens = cand["sketch_tokens"]
      assert is_list(tokens)
      assert Enum.all?(tokens, &is_binary/1)
      # Topic words survive; the secret and marker words never become anchors.
      assert "rate" in tokens
      assert "limiter" in tokens
      refute "bearer" in tokens
      refute "redacted" in tokens
      refute Enum.any?(tokens, &String.contains?(&1, "sk-ant"))

      # JSON-safe (SetMetadataKey runs Jason.encode!), and no secret in metadata.
      assert is_binary(Jason.encode!(cand))
      refute Jason.encode!(session_metadata(ctx)) =~ "sk-ant-AAAA"
    end
  end

  describe "graduation seeds the code run" do
    test "sketch → code carries the summary in intent + graduated_from (incl run_id)", %{ctx: ctx} do
      {sketch_id, proto_id, proto_dir} = sketch!("sketch a throwaway rate limiter prototype", ctx)
      seed_prototype_file(proto_dir)
      stub_summary("A token-bucket rate limiter sketch in limiter.ex.")

      canned(%Verdict{path: :code, intent: "build the rate limiter for real"})

      assert {:composer, {:ok, %{path: :code, parent_run_id: code_id}}} =
               FrontDoor.decide("ok build it for real", ctx)

      graduated = reload(code_id, ctx).config["premises"]["graduated_from"]
      assert graduated["prototype_id"] == proto_id
      assert graduated["prototype_dir"] == proto_dir
      assert graduated["run_id"] == sketch_id

      intent = seeded_intent(code_id, ctx)
      assert intent =~ "build the rate limiter for real"
      assert intent =~ "Prior exploration"
      assert intent =~ "A token-bucket rate limiter sketch in limiter.ex."

      # Single-use: consumed on the graduating launch.
      assert candidate(ctx) == nil
    end

    test "a non-adjacent sketch → talk → code still graduates", %{ctx: ctx} do
      {_sketch_id, proto_id, proto_dir} = sketch!("sketch a rate limiter prototype", ctx)
      seed_prototype_file(proto_dir)

      # An intervening talk turn must NOT erase the candidate.
      canned(:talk)
      assert {:inline, %Verdict{path: :talk}} = FrontDoor.decide("hm, how would that look?", ctx)
      assert candidate(ctx)["prototype_id"] == proto_id

      stub_summary("A token-bucket limiter.")
      canned(%Verdict{path: :code, intent: "implement the rate limiter properly"})

      assert {:composer, {:ok, %{parent_run_id: code_id}}} =
               FrontDoor.decide("ok, build the rate limiter", ctx)

      assert reload(code_id, ctx).config["premises"]["graduated_from"]["prototype_id"] == proto_id
    end

    test "an unrelated later code turn does NOT graduate (relevance gate)", %{ctx: ctx} do
      {_sketch_id, _proto_id, proto_dir} = sketch!("sketch a rate limiter prototype", ctx)
      seed_prototype_file(proto_dir)
      stub_summary("should not be used")

      canned(%Verdict{path: :code, intent: "implement user authentication login"})

      assert {:composer, {:ok, %{parent_run_id: code_id}}} =
               FrontDoor.decide("now build the auth system", ctx)

      # No graduated_from, no summarization, and the candidate survives for later.
      refute Map.has_key?(reload(code_id, ctx).config["premises"], "graduated_from")
      refute_received :summary_generated
      assert candidate(ctx) != nil
    end

    test "fail-open on a GC'd prototype dir: provenance stashed, no summary appended", %{ctx: ctx} do
      {sketch_id, proto_id, proto_dir} = sketch!("sketch a rate limiter prototype", ctx)
      File.rm_rf!(proto_dir)
      stub_summary("never reached")

      canned(%Verdict{path: :code, intent: "build the rate limiter"})

      assert {:composer, {:ok, %{parent_run_id: code_id}}} =
               FrontDoor.decide("build it", ctx)

      graduated = reload(code_id, ctx).config["premises"]["graduated_from"]
      assert graduated["prototype_id"] == proto_id
      assert graduated["run_id"] == sketch_id

      # Summary is independent of provenance: a GC'd dir ⇒ no summary appended.
      refute seeded_intent(code_id, ctx) =~ "Prior exploration"
    end
  end

  describe "sensitive sketches never graduate" do
    test "a :secrets sketch writes no candidate AND clears a stale non-sensitive one", %{ctx: ctx} do
      {_id, proto_id, _dir} = sketch!("sketch a rate limiter prototype", ctx)
      assert candidate(ctx)["prototype_id"] == proto_id

      # A subsequent sensitive sketch CLEARS the stale candidate.
      canned(%Verdict{path: :sketch, signals: [:secrets]})

      assert {:composer, {:ok, %{path: :sketch}}} =
               FrontDoor.decide("sketch something with SUPERSECRETTOKEN42", ctx)

      assert candidate(ctx) == nil

      # A later code turn topically matching the OLD prototype must not graduate.
      stub_summary("should not be used")
      canned(%Verdict{path: :code, intent: "build the rate limiter for real"})

      assert {:composer, {:ok, %{parent_run_id: code_id}}} =
               FrontDoor.decide("ok build the rate limiter", ctx)

      refute Map.has_key?(reload(code_id, ctx).config["premises"], "graduated_from")
      refute_received :summary_generated
    end

    test "a :secrets sketch clears a stale candidate even when its own launch FAILS", %{ctx: ctx} do
      {_id, proto_id, _dir} = sketch!("sketch a rate limiter prototype", ctx)
      assert candidate(ctx)["prototype_id"] == proto_id

      # The sensitive sketch's OWN launch fails, but the stale candidate must STILL be
      # cleared — the clear runs in decide/2 BEFORE the guard, not in the launch's
      # success branch, so a launch failure can't let the prior prototype survive.
      Application.put_env(:jido_claw, :front_door_create_mode, :error)
      canned(%Verdict{path: :sketch, signals: [:secrets]})

      assert {:composer, {:error, %{path: :sketch}}} =
               FrontDoor.decide("sketch something with SUPERSECRETTOKEN42", ctx)

      assert candidate(ctx) == nil
    end
  end

  describe "expired candidate (TTL backstop)" do
    test "a candidate older than the TTL does not graduate", %{ctx: ctx} do
      {_id, _proto_id, proto_dir} = sketch!("sketch a rate limiter prototype", ctx)
      seed_prototype_file(proto_dir)
      stub_summary("should not be used")
      # Shrink the TTL so the just-written candidate is already expired.
      Application.put_env(:jido_claw, :graduation_candidate_ttl_ms, -1)

      canned(%Verdict{path: :code, intent: "build the rate limiter for real"})

      assert {:composer, {:ok, %{parent_run_id: code_id}}} =
               FrontDoor.decide("ok build it", ctx)

      refute Map.has_key?(reload(code_id, ctx).config["premises"], "graduated_from")
      refute_received :summary_generated
    end
  end

  describe "transition log shape" do
    test "path_transitions entries carry path + at, never a run_id", %{ctx: ctx} do
      sketch!("sketch a rate limiter prototype", ctx)

      transitions = session_metadata(ctx)["path_transitions"]
      assert is_list(transitions)
      assert [%{"path" => "sketch", "at" => at} | _] = transitions
      assert is_binary(at)
      refute Enum.any?(transitions, &Map.has_key?(&1, "run_id"))
    end
  end
end
