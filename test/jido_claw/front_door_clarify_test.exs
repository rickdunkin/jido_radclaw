defmodule JidoClaw.FrontDoorClarifyTest do
  @moduledoc """
  Queue item 8 (OB1-1 + OR2-5) — the ambiguity clarify loop through the real
  front door: trigger gating, the multi-turn score→ask→fold→re-score flow,
  override/cap/pivot/TTL exits, infra failures (scorer, persist, launch),
  lane-entry redaction + sticky sensitivity, graduation composition, and the
  `:one_shot` surface. Triage + composer launch are the deterministic stubs;
  the scorer is a canned `:clarify_generate` sequence.

  Non-async (`TenantCase`): mutates `:triage_*` / `:front_door_*` /
  `:clarify_*` app env and runs a live session worker.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.FrontDoor
  alias JidoClaw.FrontDoor.Clarify.State, as: ClarifyState
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Triage.Verdict

  @secret "sk-ant-abcdefghijklmnopqrstuvwx1234"

  setup do
    tmp = Path.join(System.tmp_dir!(), "frontdoor-clarify-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    %{tenant_id: tenant_id, workspace: workspace, session: session} =
      seed_full(tenant_label: "fd-clarify", workspace: [path: tmp])

    rsid = session.external_id
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, rsid, actor: actor)
    :ok = SessionWorker.set_session_uuid(tenant_id, rsid, session.id)

    saved =
      Map.new(
        ~w(triage_impl triage_canned_verdict front_door_composer front_door_create_mode
           front_door_ensure_mode clarify_generate clarify_round_cap clarify_ttl_ms
           clarify_model prototype_summary_generate graduation_candidate_ttl_ms
           triage_sensitive_deadline_ms front_door_clock)a,
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

    {:ok, ctx: ctx, tenant_id: tenant_id, session: session, actor: actor, tmp: tmp}
  end

  # --- arming helpers -------------------------------------------------------

  defp canned(verdict_or_path),
    do: Application.put_env(:jido_claw, :triage_canned_verdict, verdict_or_path)

  defp ambiguous_verdict(path) do
    %Verdict{path: path, signals: [:ambiguous], est_size: :m, intent: "make it faster"}
  end

  # Arm the scorer with a SEQUENCE: each entry is a canned object (wrapped in
  # a ReqLLM response), an `{:error, _}`, or a fun/1 receiving the rendered
  # input (side effects + echo tests). An exhausted sequence raises — a test
  # that expects N scorer calls fails loudly on the N+1th.
  defp arm_scorer(entries) when is_list(entries) do
    {:ok, agent} = Agent.start_link(fn -> entries end)

    Application.put_env(:jido_claw, :clarify_generate, fn input, _schema, _opts ->
      step =
        Agent.get_and_update(agent, fn
          [] -> {:exhausted, []}
          [head | tail] -> {head, tail}
        end)

      case step do
        :exhausted -> raise "clarify scorer sequence exhausted"
        fun when is_function(fun, 1) -> fun.(input)
        {:error, _reason} = err -> err
        object -> {:ok, resp(object)}
      end
    end)

    agent
  end

  defp resp(object),
    do: %ReqLLM.Response{id: "test", model: "test", context: nil, object: object}

  defp attach_clarify_telemetry do
    handler_id = "clarify-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:jido_claw, :clarify],
      fn _event, _measure, meta, pid -> send(pid, {:clarify_tele, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @low_clarity %{"goal" => 0.5, "constraints" => 0.4, "success_criteria" => 0.4, "context" => 0.6}
  # Weighted 0.8475 ⇒ computed ambiguity 0.1525 (≤ 0.2, all floors met).
  @high_clarity %{
    "goal" => 0.9,
    "constraints" => 0.8,
    "success_criteria" => 0.85,
    "context" => 0.8
  }

  defp open_item(question, opts \\ []) do
    %{
      "question" => question,
      "why_it_matters" => "it shapes the build",
      "risk_if_unanswered" => "wrong target",
      "recommended_default_assumption" => "default: #{question}",
      "user_input_required" => Keyword.get(opts, :required, true),
      "status" => "open",
      "user_answer" => nil
    }
  end

  defp answered_item(question, answer) do
    question
    |> open_item()
    |> Map.merge(%{"status" => "answered", "user_answer" => answer})
  end

  defp low_object(ledger) do
    %{
      "classification" => "answers",
      "clarity" => @low_clarity,
      "ambiguity" => 0.6,
      "updated_intent" => nil,
      "ledger" => ledger
    }
  end

  defp pass_object(ledger, intent, classification \\ "answers") do
    %{
      "classification" => classification,
      "clarity" => @high_clarity,
      "ambiguity" => 0.15,
      "updated_intent" => intent,
      "ledger" => ledger
    }
  end

  # --- read-back helpers ----------------------------------------------------

  defp composer_runs(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant_id, actor: ctx.actor)
    Enum.filter(runs, &(&1.workflow_type == "composer"))
  end

  defp reload_run(parent_id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(parent_id, tenant: ctx.tenant_id, actor: ctx.actor)
    parent
  end

  defp reload_session(ctx) do
    {:ok, session} =
      ConversationsSession.by_id(ctx.session_uuid, tenant: ctx.tenant_id, actor: ctx.actor)

    session
  end

  defp pending_state(ctx) do
    case reload_session(ctx).metadata do
      %{"pending_clarify" => %{} = raw} ->
        {:ok, state} = ClarifyState.from_metadata(raw)
        state

      _absent ->
        nil
    end
  end

  defp live_topics(parent_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant_id, actor: ctx.actor)
    Enum.find(events, &(&1.kind == :signals_published)).payload["signals"]
  end

  defp artifact(parent_id, ctx, name) do
    {:ok, events} = WorkflowEvent.for_run(parent_id, tenant: ctx.tenant_id, actor: ctx.actor)
    produced = Enum.find(events, &(&1.kind == :artifacts_produced))
    triple = Enum.find(produced.payload["artifacts"], &(&1["name"] == name))

    {:ok, value} =
      ComposerArtifact.resolve_value(triple["ref"], tenant: ctx.tenant_id, actor: ctx.actor)

    value
  end

  defp write_opts(ctx), do: [tenant: ctx.tenant_id, actor: ctx.actor]

  # ===========================================================================
  # Trigger gating
  # ===========================================================================

  describe "trigger gating" do
    test "ambiguous + code enters the clarify lane: questions, state, NO run", %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      arm_scorer([low_object([open_item("faster at what?"), open_item("which endpoint?")])])

      assert {:clarify, %{path: :code, message: msg}} = FrontDoor.decide("make it faster", ctx)

      assert msg =~ "round 1/12"
      assert msg =~ "faster at what?"
      assert msg =~ "proceed with defaults"
      assert composer_runs(ctx) == []

      state = pending_state(ctx)
      assert state.rounds_shown == 1
      assert [_first, _second] = state.ledger
      # The open turn ran triage, so stickiness observability persisted too.
      assert reload_session(ctx).metadata["last_triage_path"] == "code"
    end

    test "ambiguous + system enters the clarify lane too", %{ctx: ctx} do
      canned(%Verdict{path: :system, signals: [:ambiguous], intent: "fix the box"})
      arm_scorer([low_object([open_item("which box?")])])

      assert {:clarify, %{path: :system}} = FrontDoor.decide("fix the box", ctx)
      assert composer_runs(ctx) == []
    end

    test "ambiguous + sketch is NEVER gated (clarify-by-doing lane)", %{ctx: ctx} do
      canned(%Verdict{path: :sketch, signals: [:ambiguous], intent: "sketch something"})
      arm_scorer([])

      assert {:composer, {:ok, %{path: :sketch}}} =
               FrontDoor.decide("sketch a vague thing", ctx)
    end

    test "code WITHOUT ambiguous takes the standard composer with identical seeding", %{ctx: ctx} do
      canned(%Verdict{path: :code, signals: [], est_size: :s, intent: "add a test"})
      arm_scorer([])

      assert {:composer, {:ok, %{path: :code, parent_run_id: id}}} =
               FrontDoor.decide("add a test for X", ctx)

      # Byte-identical standard seeding: no clarify premises, today's topics.
      parent = reload_run(id, ctx)
      assert parent.config["premises"] == %{"path" => "code", "est_size" => "s"}

      assert Enum.sort(live_topics(id, ctx)) ==
               Enum.sort(["request-received", "code", "plan-needed"])
    end

    test "talk stays inline", %{ctx: ctx} do
      canned(:talk)
      arm_scorer([])
      assert {:inline, %Verdict{path: :talk}} = FrontDoor.decide("how does X work?", ctx)
    end
  end

  # ===========================================================================
  # The multi-turn pass flow (answers → recap → confirm → compose)
  # ===========================================================================

  describe "multi-turn pass flow" do
    test "two qualifying rounds compose clean with enriched seed/premises", %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      attach_clarify_telemetry()

      answered = [answered_item("faster at what?", "p95 latency on /search")]
      intent = "cut /search p95 latency"

      arm_scorer([
        low_object([open_item("faster at what?")]),
        pass_object(answered, intent),
        pass_object(answered, intent)
      ])

      # Turn 1: open → questions.
      assert {:clarify, %{message: q_msg}} = FrontDoor.decide("make it faster", ctx)
      assert q_msg =~ "faster at what?"
      assert_receive {:clarify_tele, %{event: :open, outcome: :ok}}

      # Turn 2: qualifying answer → streak 1 → the recap-confirm round.
      assert {:clarify, %{message: recap_msg}} =
               FrontDoor.decide("p95 latency on /search", ctx)

      assert recap_msg =~ "confirm"
      assert recap_msg =~ intent
      assert pending_state(ctx).streak == 1
      assert_receive {:clarify_tele, %{event: :round, outcome: :ok}}

      # A stale "ask once" marker from some earlier debounce: the clarified
      # compose must clear it even though it bypasses the oscillation guard.
      session = reload_session(ctx)

      {:ok, _} =
        ConversationsSession.set_oscillation_marker(
          session,
          DateTime.to_iso8601(DateTime.utc_now()),
          write_opts(ctx)
        )

      # Turn 3: confirm → streak 2 → compose.
      assert {:composer, {:ok, %{path: :code, parent_run_id: id, message: ack}}} =
               FrontDoor.decide("yes, exactly", ctx)

      assert ack =~ "Starting a code run"
      assert_receive {:clarify_tele, %{event: :compose, outcome: :clean}}

      run = reload_run(id, ctx)
      premises = run.config["premises"]
      assert premises["readiness"] == "ready_for_tasks"
      assert premises["ambiguity_score"] == 0.1525
      assert premises["clarifications"] =~ "faster at what? => p95 latency on /search"
      refute Map.has_key?(premises, "degraded")
      refute Map.has_key?(premises, "unresolved_slots")

      # `:ambiguous` resolved ⇒ dropped from the seeded topics.
      refute "ambiguous" in live_topics(id, ctx)
      assert "plan-needed" in live_topics(id, ctx)

      # Intent = the clarified updated_intent; seed = original + transcript.
      assert artifact(id, ctx, "intent") == intent
      seed = artifact(id, ctx, "request")
      assert seed =~ "make it faster"
      assert seed =~ "Clarification Q/A"
      assert seed =~ "p95 latency on /search"

      # Loop state consumed; the stale marker cleared.
      metadata = reload_session(ctx).metadata
      refute Map.has_key?(metadata, "pending_clarify")
      refute Map.has_key?(metadata, "oscillation_prompted_at")
    end

    test "a non-qualifying answer resets the streak and asks again", %{ctx: ctx} do
      canned(ambiguous_verdict(:code))

      arm_scorer([
        low_object([open_item("q1?")]),
        pass_object([answered_item("q1?", "a1")], "clearer"),
        low_object([open_item("q2?"), answered_item("q1?", "a1")])
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)
      assert {:clarify, %{message: recap}} = FrontDoor.decide("a1", ctx)
      assert recap =~ "confirm"
      assert pending_state(ctx).streak == 1

      # The would-be confirm turn scores badly ⇒ streak resets, questions again.
      assert {:clarify, %{message: q2}} = FrontDoor.decide("actually also handle Y", ctx)
      assert q2 =~ "q2?"
      assert pending_state(ctx).streak == 0
      assert composer_runs(ctx) == []
    end
  end

  # ===========================================================================
  # Override (deterministic + scorer-classified)
  # ===========================================================================

  describe "override" do
    test "the deterministic phrase composes degraded with unresolved slots — no scorer call",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      arm_scorer([low_object([open_item("q1?"), open_item("q2?", required: false)])])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)

      # The sequence has NO second entry: a scorer call here would raise.
      assert {:composer, {:ok, %{parent_run_id: id}}} =
               FrontDoor.decide("ok, proceed with defaults", ctx)

      premises = reload_run(id, ctx).config["premises"]
      assert premises["degraded"] == true
      assert premises["unresolved_slots"] == ["q1?", "q2?"]
      assert premises["readiness"] == "blocked_needs_user_input"

      # Degraded keeps `:ambiguous` in the seeded topics (honest).
      assert "ambiguous" in live_topics(id, ctx)
      refute Map.has_key?(reload_session(ctx).metadata, "pending_clarify")
    end

    test "a scorer-classified override with everything resolved composes CLEAN", %{ctx: ctx} do
      canned(ambiguous_verdict(:code))

      arm_scorer([
        low_object([open_item("q1?")]),
        pass_object([answered_item("q1?", "a1")], "crisp intent", "override")
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)

      assert {:composer, {:ok, %{parent_run_id: id}}} =
               FrontDoor.decide("just build it with a1", ctx)

      premises = reload_run(id, ctx).config["premises"]
      refute Map.has_key?(premises, "degraded")
      refute "ambiguous" in live_topics(id, ctx)
      assert artifact(id, ctx, "intent") == "crisp intent"
    end

    test "a scorer-classified override with open items composes degraded", %{ctx: ctx} do
      canned(ambiguous_verdict(:code))

      arm_scorer([
        low_object([open_item("q1?")]),
        %{low_object([open_item("q1?")]) | "classification" => "override"}
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)
      assert {:composer, {:ok, %{parent_run_id: id}}} = FrontDoor.decide("go anyway", ctx)

      premises = reload_run(id, ctx).config["premises"]
      assert premises["degraded"] == true
      assert premises["unresolved_slots"] == ["q1?"]
    end

    test "a NEGATED override phrase never composes deterministically — the scorer decides",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))

      arm_scorer([
        low_object([open_item("q1?")]),
        # The negation reaches the scorer (this entry is consumed) and folds
        # as a plain answer ⇒ another question round, no run.
        low_object([open_item("q1?")]),
        # Scorer down on the next negated turn ⇒ bounded failure ack, no run.
        {:error, :timeout}
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)

      assert {:clarify, %{message: round2}} =
               FrontDoor.decide("do not proceed with defaults", ctx)

      assert round2 =~ "q1?"
      assert composer_runs(ctx) == []

      assert {:clarify, %{message: ack}} = FrontDoor.decide("don't proceed with defaults", ctx)
      assert ack =~ "Re-send"
      assert pending_state(ctx).scorer_failures == 1
      assert composer_runs(ctx) == []
    end
  end

  # ===========================================================================
  # Round cap (hold-for-accept vs degraded compose)
  # ===========================================================================

  describe "round cap" do
    test "at the cap a required unknown HOLDS; the accept phrase then composes degraded",
         %{ctx: ctx} do
      Application.put_env(:jido_claw, :clarify_round_cap, 1)
      canned(ambiguous_verdict(:code))

      arm_scorer([
        low_object([open_item("required q?", required: true)]),
        low_object([open_item("required q?", required: true)])
      ])

      assert {:clarify, %{message: q}} = FrontDoor.decide("vague ask", ctx)
      assert q =~ "round 1/1"

      # Still non-qualifying at the cap with a required unknown ⇒ HOLD.
      assert {:clarify, %{message: hold_msg}} = FrontDoor.decide("partial answer", ctx)
      assert hold_msg =~ "round cap"
      assert hold_msg =~ "required q?"
      assert hold_msg =~ "proceed with defaults"
      assert composer_runs(ctx) == []

      # The explicit accept-assumptions ack composes degraded.
      assert {:composer, {:ok, %{parent_run_id: id}}} =
               FrontDoor.decide("proceed with defaults", ctx)

      assert reload_run(id, ctx).config["premises"]["degraded"] == true
    end

    test "at the cap with ONLY assumable items open it auto-composes degraded", %{ctx: ctx} do
      Application.put_env(:jido_claw, :clarify_round_cap, 1)
      canned(ambiguous_verdict(:code))

      arm_scorer([
        low_object([open_item("assumable?", required: false)]),
        low_object([open_item("assumable?", required: false)])
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)

      assert {:composer, {:ok, %{parent_run_id: id}}} = FrontDoor.decide("an answer", ctx)

      premises = reload_run(id, ctx).config["premises"]
      assert premises["degraded"] == true
      assert premises["unresolved_slots"] == ["assumable?"]
      assert premises["readiness"] == "ready_with_assumptions"
    end
  end

  # ===========================================================================
  # Pivot, TTL, infra failures
  # ===========================================================================

  describe "exits and failures" do
    test "new_ask clears the loop and falls through to fresh triage", %{ctx: ctx} do
      canned(fn message ->
        if message =~ "how do I", do: %Verdict{path: :talk}, else: ambiguous_verdict(:code)
      end)

      arm_scorer([
        low_object([open_item("q1?")]),
        %{low_object([open_item("q1?")]) | "classification" => "new_ask"}
      ])

      assert {:clarify, _} = FrontDoor.decide("vague build ask", ctx)

      assert {:inline, %Verdict{path: :talk}} =
               FrontDoor.decide("actually, how do I list sessions?", ctx)

      refute Map.has_key?(reload_session(ctx).metadata, "pending_clarify")
    end

    test "expired pending state lazily clears into normal triage", %{ctx: ctx} do
      canned(fn message ->
        if message =~ "hello", do: %Verdict{path: :talk}, else: ambiguous_verdict(:code)
      end)

      arm_scorer([low_object([open_item("q1?")])])
      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)
      assert pending_state(ctx)

      # Everything is instantly expired from here.
      Application.put_env(:jido_claw, :clarify_ttl_ms, -1)

      assert {:inline, %Verdict{path: :talk}} = FrontDoor.decide("hello again", ctx)
      refute Map.has_key?(reload_session(ctx).metadata, "pending_clarify")
    end

    test "scorer failure mid-loop holds state; the 2nd failure goes override-only; the phrase still works",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))

      arm_scorer([
        low_object([open_item("q1?")]),
        {:error, :timeout},
        {:error, :timeout}
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)

      # 1st failure: bounded re-send ack; nothing composed, state kept.
      assert {:clarify, %{message: first}} = FrontDoor.decide("an answer", ctx)
      assert first =~ "Re-send"
      assert pending_state(ctx).scorer_failures == 1
      assert composer_runs(ctx) == []

      # 2nd consecutive failure: override-only ack.
      assert {:clarify, %{message: second}} = FrontDoor.decide("an answer again", ctx)
      refute second =~ "Re-send"
      assert second =~ "proceed with defaults"
      assert pending_state(ctx).scorer_failures == 2

      # The deterministic override needs no scorer (sequence is exhausted).
      assert {:composer, {:ok, _}} = FrontDoor.decide("proceed with defaults", ctx)
    end

    test "open-turn scorer failure fails open to the standard composer", %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      arm_scorer([{:error, :boom}])

      assert {:composer, {:ok, %{path: :code}}} = FrontDoor.decide("vague ask", ctx)
      refute Map.has_key?(reload_session(ctx).metadata, "pending_clarify")
    end

    test "an open-turn non-qualifying score with NO open questions fails open to the standard composer",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      attach_clarify_telemetry()
      arm_scorer([low_object([])])

      assert {:composer, {:ok, %{path: :code, parent_run_id: id}}} =
               FrontDoor.decide("vague ask", ctx)

      # Standard seeding — no clarify premises, no pending loop, and the
      # distinct telemetry outcome (a contract violation, not a transport
      # failure).
      assert reload_run(id, ctx).config["premises"] == %{"path" => "code", "est_size" => "m"}
      refute Map.has_key?(reload_session(ctx).metadata, "pending_clarify")
      assert_receive {:clarify_tele, %{event: :open, outcome: :empty_ledger}}
    end

    test "a continue-turn result with nothing left to ask is infra: ledger preserved, failures escalate, override exits",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))

      # Both continue results carry ONLY resolved items (zero open) while
      # still non-qualifying — the contract violation the guard refuses to
      # serve as a question-less round or fold over the real ledger.
      arm_scorer([
        low_object([open_item("q1?")]),
        low_object([answered_item("q1?", "a1")]),
        low_object([answered_item("q1?", "a1")])
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)

      # 1st: bounded failure ack, NOT folded — the prior ledger keeps q1 OPEN.
      assert {:clarify, %{message: first}} = FrontDoor.decide("a1", ctx)
      assert first =~ "Re-send"
      state = pending_state(ctx)
      assert state.scorer_failures == 1
      assert [%{"question" => "q1?", "status" => "open"}] = state.ledger
      assert composer_runs(ctx) == []

      # 2nd consecutive: override-only ack, escalation intact.
      assert {:clarify, %{message: second}} = FrontDoor.decide("a1 again", ctx)
      refute second =~ "Re-send"
      assert pending_state(ctx).scorer_failures == 2

      # The deterministic override then composes degraded from the ORIGINAL
      # ledger — its open question survives as the unresolved slot.
      assert {:composer, {:ok, %{parent_run_id: id}}} =
               FrontDoor.decide("proceed with defaults", ctx)

      premises = reload_run(id, ctx).config["premises"]
      assert premises["degraded"] == true
      assert premises["unresolved_slots"] == ["q1?"]
    end

    test "a result that DROPS prior ledger items folds merged — the accumulated Q/A survives",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))

      arm_scorer([
        low_object([open_item("q1?"), open_item("q2?")]),
        # Folds q1's answer, keeps q2 open.
        low_object([answered_item("q1?", "a1"), open_item("q2?")]),
        # Returns ONLY a new open item — q1's answer and open q2 are dropped.
        low_object([open_item("q3?")])
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)
      assert {:clarify, _} = FrontDoor.decide("a1", ctx)

      # The dropped items are preserved through the fold; the scorer's own
      # ordering still decides the next question (q3 leads the merged ledger).
      assert {:clarify, %{message: round3}} = FrontDoor.decide("some detail", ctx)
      assert round3 =~ "q3?"

      state = pending_state(ctx)
      assert Enum.map(state.ledger, & &1["question"]) == ["q3?", "q1?", "q2?"]
      assert Enum.at(state.ledger, 1)["user_answer"] == "a1"

      # Compose via override: the preserved Q/A rides digest, slots, and seed.
      assert {:composer, {:ok, %{parent_run_id: id}}} =
               FrontDoor.decide("proceed with defaults", ctx)

      premises = reload_run(id, ctx).config["premises"]
      assert premises["clarifications"] =~ "q1? => a1"
      assert premises["unresolved_slots"] == ["q3?", "q2?"]

      assert artifact(id, ctx, "request") =~ "Q: q1?\nA: a1"
    end

    test "open-turn persist failure fails open to the standard composer (no orphan questions)",
         %{ctx: ctx, session: session, actor: actor, tenant_id: tenant_id} do
      canned(ambiguous_verdict(:code))

      # The canned scorer destroys the session row mid-turn, so the pending
      # write that follows it fails — deterministically, with no prod seam.
      arm_scorer([
        fn _input ->
          :ok = Ash.destroy(session, tenant: tenant_id, actor: actor)
          {:ok, resp(low_object([open_item("q1?")]))}
        end
      ])

      assert {:composer, {:ok, %{path: :code}}} = FrontDoor.decide("vague ask", ctx)
    end

    test "a compose launch failure keeps the loop live; the re-send retries and composes",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      answered = [answered_item("q1?", "a1")]

      arm_scorer([
        low_object([open_item("q1?")]),
        pass_object(answered, "crisp"),
        pass_object(answered, "crisp"),
        pass_object(answered, "crisp")
      ])

      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)
      assert {:clarify, _} = FrontDoor.decide("a1", ctx)

      # Streak 2 → compose — but the launch is forced to fail.
      Application.put_env(:jido_claw, :front_door_create_mode, :error)
      assert {:composer, {:error, %{message: err}}} = FrontDoor.decide("yes", ctx)
      assert err =~ "retry"

      # The loop is still live (streak preserved from the last persisted round).
      state = pending_state(ctx)
      assert state
      assert state.streak == 1

      # The re-send re-enters the loop, re-qualifies, and the compose succeeds.
      Application.put_env(:jido_claw, :front_door_create_mode, :delegate)
      assert {:composer, {:ok, %{parent_run_id: _id}}} = FrontDoor.decide("yes", ctx)
      refute Map.has_key?(reload_session(ctx).metadata, "pending_clarify")
    end
  end

  # ===========================================================================
  # Redaction + sticky sensitivity
  # ===========================================================================

  describe "redaction and sensitivity" do
    test "a secret in an answer is redacted before scoring/persist and the launch is marked sensitive",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))

      # The continue-turn scorer ECHOES its rendered input into the folded
      # answer (a faithful model can only echo what it was shown), so the
      # persisted ledger/seed carry whatever reached the model.
      echo = fn input ->
        [%{role: :user, content: content}] = input
        {:ok, resp(pass_object([answered_item("which store?", content)], "crisp intent"))}
      end

      arm_scorer([
        low_object([open_item("which store?")]),
        echo,
        echo
      ])

      assert {:clarify, _} = FrontDoor.decide("wire up the token store", ctx)

      assert {:clarify, _} = FrontDoor.decide("use redis, the key is #{@secret}", ctx)

      # Persisted ledger is built from redacted material + the sticky bit set.
      state = pending_state(ctx)
      assert state.sensitive
      [item] = state.ledger
      refute item["user_answer"] =~ @secret
      assert item["user_answer"] =~ "[REDACTED:ANTHROPIC_KEY]"

      # Compose: the run launches SENSITIVE (ack shape omits the intent) even
      # though the original verdict carried no `:secrets` signal.
      assert {:composer, {:ok, %{parent_run_id: id, message: ack}}} =
               FrontDoor.decide("yes", ctx)

      assert ack =~ "sensitive code run"
      # The turn-3 echo folds its rendered input (which serializes the prior
      # ledger) into the final answer, so the seed transcript carries exactly
      # what the model could see — redacted, never the raw key.
      seed = artifact(id, ctx, "request")
      refute seed =~ @secret
      assert seed =~ "[REDACTED:ANTHROPIC_KEY]"
    end

    test "the one-shot path redacts before scoring and marks the launch sensitive too",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      parent = self()

      arm_scorer([
        fn input ->
          [%{role: :user, content: content}] = input
          send(parent, {:scored, content})
          {:ok, resp(low_object([open_item("q1?")]))}
        end
      ])

      one_shot_ctx = Map.put(ctx, :clarify_surface, :one_shot)

      assert {:composer, {:ok, %{message: ack}}} =
               FrontDoor.decide("build it, key #{@secret}", one_shot_ctx)

      assert ack =~ "sensitive code run"
      assert_receive {:scored, content}
      refute content =~ @secret
      assert content =~ "[REDACTED:ANTHROPIC_KEY]"
    end
  end

  # ===========================================================================
  # Graduation composition (pending_prototype × clarify)
  # ===========================================================================

  describe "graduation composition" do
    test "a clarified compose still graduates a relevant prototype — relevance from the CLARIFIED intent",
         %{ctx: ctx, session: session} do
      canned(ambiguous_verdict(:code))
      # No real prototype dir: summarize fails ⇒ provenance-only graduation.
      Application.put_env(:jido_claw, :prototype_summary_generate, fn _i, _s, _o ->
        {:error, :nope}
      end)

      candidate = %{
        "prototype_id" => "proto-1",
        "prototype_dir" => "/nonexistent/proto-1",
        "run_id" => "run-1",
        "sketch_tokens" => ["limiter"],
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      {:ok, _} = ConversationsSession.set_pending_prototype(session, candidate, write_opts(ctx))

      answered = [answered_item("scope?", "the API layer")]
      intent = "add the rate limiter properly"

      arm_scorer([
        low_object([open_item("scope?")]),
        pass_object(answered, intent),
        pass_object(answered, intent)
      ])

      assert {:clarify, _} = FrontDoor.decide("make it real", ctx)
      assert {:clarify, _} = FrontDoor.decide("the API layer", ctx)

      # The confirm-turn message has NO topic overlap with the candidate —
      # only the clarified intent ("...limiter...") does.
      assert {:composer, {:ok, %{parent_run_id: id}}} = FrontDoor.decide("yes, exactly", ctx)

      premises = reload_run(id, ctx).config["premises"]
      assert premises["graduated_from"]["prototype_id"] == "proto-1"

      metadata = reload_session(ctx).metadata
      refute Map.has_key?(metadata, "pending_prototype")
      refute Map.has_key?(metadata, "pending_clarify")
    end
  end

  # ===========================================================================
  # Surfaces
  # ===========================================================================

  describe "surfaces" do
    test "a one-shot surface composes immediately with degraded labeling", %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      arm_scorer([low_object([open_item("q1?"), open_item("q2?", required: false)])])

      one_shot_ctx = Map.put(ctx, :clarify_surface, :one_shot)

      assert {:composer, {:ok, %{parent_run_id: id}}} =
               FrontDoor.decide("vague scheduled ask", one_shot_ctx)

      premises = reload_run(id, ctx).config["premises"]
      assert premises["degraded"] == true
      assert premises["unresolved_slots"] == ["q1?", "q2?"]
      assert "ambiguous" in live_topics(id, ctx)
      refute Map.has_key?(reload_session(ctx).metadata, "pending_clarify")
    end

    test "a one-shot non-qualifying empty-ledger score falls to the standard composer — never a degraded-empty compose",
         %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      attach_clarify_telemetry()
      arm_scorer([low_object([])])

      one_shot_ctx = Map.put(ctx, :clarify_surface, :one_shot)

      assert {:composer, {:ok, %{parent_run_id: id}}} =
               FrontDoor.decide("vague scheduled ask", one_shot_ctx)

      # Standard seeding: no degraded/readiness/ambiguity_score keys from the
      # same scorer-failure class that produced nothing to report.
      assert reload_run(id, ctx).config["premises"] == %{"path" => "code", "est_size" => "m"}
      assert_receive {:clarify_tele, %{event: :open, outcome: :empty_ledger}}
    end

    test "a live pending loop on a one-shot turn is CLEARED, never continued (main cron)",
         %{ctx: ctx} do
      canned(fn message ->
        if message =~ "scheduled", do: %Verdict{path: :talk}, else: ambiguous_verdict(:code)
      end)

      arm_scorer([low_object([open_item("q1?")])])
      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)
      assert pending_state(ctx)

      # The next scheduled task must NOT read as an answer: cleared + normal
      # triage (the exhausted scorer sequence would raise on any continue).
      one_shot_ctx = Map.put(ctx, :clarify_surface, :one_shot)

      assert {:inline, %Verdict{path: :talk}} =
               FrontDoor.decide("the scheduled task text", one_shot_ctx)

      refute Map.has_key?(reload_session(ctx).metadata, "pending_clarify")
    end

    test "a nil session fails open to the standard composer", %{ctx: ctx} do
      canned(ambiguous_verdict(:code))
      arm_scorer([])

      assert {:composer, {:ok, %{path: :code}}} =
               FrontDoor.decide("vague ask", %{ctx | session_uuid: nil})
    end
  end

  # ===========================================================================
  # Oscillation-marker hygiene
  # ===========================================================================

  describe "oscillation marker" do
    test "a clarified compose clears the marker, so a later REAL thrash still debounces",
         %{ctx: ctx, session: session} do
      canned(ambiguous_verdict(:code))
      arm_scorer([low_object([open_item("q1?")])])

      # A recent "ask once" marker exists (some earlier debounce prompted).
      {:ok, _} =
        ConversationsSession.set_oscillation_marker(
          session,
          DateTime.to_iso8601(DateTime.utc_now()),
          write_opts(ctx)
        )

      # Clarified (override) compose bypasses the guard but clears the marker.
      assert {:clarify, _} = FrontDoor.decide("vague ask", ctx)
      assert {:composer, {:ok, _}} = FrontDoor.decide("proceed with defaults", ctx)
      refute Map.has_key?(reload_session(ctx).metadata, "oscillation_prompted_at")

      # Now a real sketch⇄code thrash: with the stale marker gone the guard
      # DEBOUNCES instead of treating the flip as a confirming re-send.
      now_iso = DateTime.to_iso8601(DateTime.utc_now())

      {:ok, _} =
        ConversationsSession.set_path_transitions(
          reload_session(ctx),
          [%{"path" => "code", "at" => now_iso}, %{"path" => "sketch", "at" => now_iso}],
          write_opts(ctx)
        )

      canned(%Verdict{path: :sketch, signals: [], intent: "sketch it"})

      assert {:composer, {:error, %{message: msg}}} = FrontDoor.decide("sketch it again", ctx)
      assert msg =~ "flipped between sketch"
    end
  end
end
