defmodule JidoClaw.FrontDoorOscillationTest do
  @moduledoc """
  AR-8b-2 C2 — the cross-run oscillation guard. We seed the durable
  `path_transitions` / `oscillation_prompted_at` / `pending_prototype` state
  directly (via the public Session actions) so the flip-count + window logic is
  driven deterministically, then assert `decide/2`'s proceed/debounce decision.

  Non-async (`TenantCase`): mutates `:triage_*` / `:front_door_*` app env and a
  live session worker.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.FrontDoor
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Triage.Verdict

  setup do
    tmp = Path.join(System.tmp_dir!(), "frontdoor-osc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    %{tenant_id: tenant_id, workspace: workspace, session: session} =
      seed_full(tenant_label: "frontdoor-osc", workspace: [path: tmp])

    rsid = session.external_id
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, rsid, actor: actor)
    :ok = SessionWorker.set_session_uuid(tenant_id, rsid, session.id)

    saved =
      Map.new(
        ~w(triage_impl triage_canned_verdict front_door_composer front_door_create_mode
           front_door_ensure_mode prototype_summary_generate front_door_clock
           graduation_candidate_ttl_ms triage_sensitive_deadline_ms)a,
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

  defp iso(seconds_ago) do
    DateTime.utc_now()
    |> DateTime.add(-seconds_ago, :second)
    |> DateTime.to_iso8601()
  end

  defp session(ctx) do
    {:ok, session} =
      ConversationsSession.by_id(ctx.session_uuid, tenant: ctx.tenant_id, actor: ctx.actor)

    session
  end

  defp write_opts(ctx), do: [tenant: ctx.tenant_id, actor: ctx.actor]

  # entries: [{path, seconds_ago}, ...], newest first.
  defp seed_transitions(ctx, entries) do
    list = Enum.map(entries, fn {path, ago} -> %{"path" => path, "at" => iso(ago)} end)
    {:ok, _} = ConversationsSession.set_path_transitions(session(ctx), list, write_opts(ctx))
  end

  defp seed_marker(ctx, seconds_ago),
    do:
      {:ok, _} =
        ConversationsSession.set_oscillation_marker(
          session(ctx),
          iso(seconds_ago),
          write_opts(ctx)
        )

  defp seed_candidate(ctx, tokens, seconds_ago) do
    cand = %{
      "prototype_id" => "p-#{System.unique_integer([:positive])}",
      "prototype_dir" => "/nonexistent",
      "run_id" => "r-1",
      "sketch_tokens" => tokens,
      "at" => iso(seconds_ago)
    }

    {:ok, _} = ConversationsSession.set_pending_prototype(session(ctx), cand, write_opts(ctx))
  end

  defp metadata(ctx), do: session(ctx).metadata

  defp composer_runs(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant_id, actor: ctx.actor)
    Enum.filter(runs, &(&1.workflow_type == "composer"))
  end

  # ===========================================================================
  # Flip counting (window-filtered) → proceed / debounce
  # ===========================================================================

  describe "flip counting" do
    test "a single sketch → code flip (a normal graduation) proceeds", %{ctx: ctx} do
      seed_transitions(ctx, [{"sketch", 1}])
      canned(:code)

      assert {:composer, {:ok, %{path: :code}}} = FrontDoor.decide("build it", ctx)
    end

    test "the second flip (sketch → code → sketch) debounces and mints no run", %{ctx: ctx} do
      before = length(composer_runs(ctx))
      seed_transitions(ctx, [{"code", 1}, {"sketch", 2}])
      canned(:sketch)

      assert {:composer, {:error, %{path: :sketch, message: msg}}} =
               FrontDoor.decide("actually just sketch it", ctx)

      assert msg =~ "Re-send"
      assert length(composer_runs(ctx)) == before
      # The "ask once" marker is set.
      assert is_binary(metadata(ctx)["oscillation_prompted_at"])
    end

    test "transitions older than the window do not count (proceed)", %{ctx: ctx} do
      # Two flips, but both 2 minutes ago — outside the 60s window.
      seed_transitions(ctx, [{"code", 120}, {"sketch", 121}])
      canned(:sketch)

      assert {:composer, {:ok, %{path: :sketch}}} = FrontDoor.decide("sketch it", ctx)
    end

    test "a missing transition log proceeds (fail-open first launch)", %{ctx: ctx} do
      canned(:code)
      assert {:composer, {:ok, %{path: :code}}} = FrontDoor.decide("build it", ctx)
    end

    test "an unloadable session proceeds (fail-open)", %{ctx: ctx} do
      bogus = Map.put(ctx, :session_uuid, Ash.UUID.generate())
      canned(:code)
      assert {:composer, {:ok, %{path: :code}}} = FrontDoor.decide("build it", bogus)
    end
  end

  # ===========================================================================
  # Ask-once-then-proceed + marker lifecycle
  # ===========================================================================

  describe "ask once, then proceed" do
    test "a recent marker makes the next thrashing turn proceed and consumes the marker", %{
      ctx: ctx
    } do
      seed_marker(ctx, 1)
      # Thrashy state that would otherwise debounce — the marker overrides it.
      seed_transitions(ctx, [{"code", 1}, {"sketch", 2}])
      canned(:sketch)

      assert {:composer, {:ok, %{path: :sketch}}} = FrontDoor.decide("yes, sketch it", ctx)
      refute Map.has_key?(metadata(ctx), "oscillation_prompted_at")
    end

    test "a talk turn clears the marker", %{ctx: ctx} do
      seed_marker(ctx, 1)
      canned(:talk)

      assert {:inline, %Verdict{path: :talk}} = FrontDoor.decide("wait, explain first", ctx)
      refute Map.has_key?(metadata(ctx), "oscillation_prompted_at")
    end
  end

  # ===========================================================================
  # Debounce does not summarize and preserves the candidate
  # ===========================================================================

  describe "debounce + C1 interaction" do
    test "a debounced code turn neither summarizes nor consumes the relevant candidate", %{
      ctx: ctx
    } do
      parent = self()

      Application.put_env(:jido_claw, :prototype_summary_generate, fn _i, _s, _o ->
        send(parent, :summary_generated)
        {:ok, %ReqLLM.Response{id: "t", model: "t", context: nil, object: %{"summary" => "x"}}}
      end)

      # Thrashy for a CODE turn: in-window [sketch, code] → [code|...] = 2 flips.
      seed_transitions(ctx, [{"sketch", 1}, {"code", 2}])
      seed_candidate(ctx, ["rate", "limiter"], 1)
      canned(%Verdict{path: :code, intent: "build the rate limiter"})

      assert {:composer, {:error, %{path: :code}}} =
               FrontDoor.decide("build the rate limiter", ctx)

      # No summary (hydrate happens only on :proceed) and the candidate survives.
      refute_received :summary_generated
      assert metadata(ctx)["pending_prototype"]["sketch_tokens"] == ["rate", "limiter"]
    end

    test "a debounced :secrets sketch still clears a stale candidate", %{ctx: ctx} do
      # Thrashy for a SKETCH turn: in-window [code, sketch] → [sketch|...] = 2 flips.
      seed_transitions(ctx, [{"code", 1}, {"sketch", 2}])
      seed_candidate(ctx, ["rate", "limiter"], 1)
      canned(%Verdict{path: :sketch, signals: [:secrets]})

      assert {:composer, {:error, %{path: :sketch}}} =
               FrontDoor.decide("sketch something with a secret", ctx)

      # The clear runs in decide/2 BEFORE the oscillation guard, so even a debounced
      # sensitive sketch walls off the prior non-sensitive prototype.
      assert metadata(ctx)["pending_prototype"] == nil
    end
  end

  # ===========================================================================
  # Telemetry — no silent suppression
  # ===========================================================================

  describe "telemetry" do
    setup do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:jido_claw, :triage, :oscillation_guard],
        fn _event, measurements, meta, _config ->
          send(parent, {:osc_telemetry, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      :ok
    end

    test "a debounce emits an oscillation_guard event with path/prior/reason", %{ctx: ctx} do
      seed_transitions(ctx, [{"code", 1}, {"sketch", 2}])
      canned(:sketch)

      assert {:composer, {:error, _}} = FrontDoor.decide("sketch it", ctx)

      assert_receive {:osc_telemetry, %{count: 1},
                      %{path: :sketch, prior: "code", reason: :debounce}}
    end
  end
end
