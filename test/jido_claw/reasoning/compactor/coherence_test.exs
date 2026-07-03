defmodule JidoClaw.Reasoning.Compactor.CoherenceTest do
  @moduledoc """
  T1-2 coherence proof (Phase 6).

  One session running three agents over the compaction threshold — the main
  agent, a `handoff → reviewer` worker, and a spawned sub-agent — must
  compact into three INDEPENDENT, non-clobbering snapshots, each summarizing
  only its own durable slice. Plus: the reviewer's handoff context lands in
  its system prompt (via the real router injection path) and survives
  compaction in the post-transform LLM messages; and the sub-agent's
  task/terminal turns are complete yet excluded from the primary view.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Handoff.Router, as: HandoffRouter
  alias JidoClaw.Conversations.{Message, Session, SubagentTranscript}
  alias JidoClaw.Reasoning.Compactor
  alias JidoClaw.Reasoning.Compactor.{Config, RequestTransformer, Snapshot}
  alias JidoClaw.Test.TerminalSignal

  # Records the prompt each summarizer call receives, so we can prove a
  # given agent's summarizer saw only its own slice.
  defmodule RecordingBackend do
    @behaviour JidoClaw.Reasoning.Compactor.Summarizer

    @impl JidoClaw.Reasoning.Compactor.Summarizer
    def summarize(prompt, _opts) do
      case Application.get_env(:jido_claw, :coherence_test_pid) do
        pid when is_pid(pid) -> send(pid, {:summarizer_prompt, prompt})
        _ -> :ok
      end

      {:ok, "SUMMARY"}
    end
  end

  # A minimal agent that records the system prompt the router injects.
  # `Jido.AI.set_system_prompt/2` → `Jido.AgentServer.call(pid, signal)` →
  # `GenServer.call(pid, {:signal, signal})`, replying `{:ok, agent}`.
  defmodule CapturingAgent do
    use GenServer

    @spec start_link(pid()) :: GenServer.on_start()
    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl GenServer
    def init(test_pid), do: {:ok, test_pid}

    @impl GenServer
    def handle_call(
          {:signal, %{type: "ai.react.set_system_prompt", data: %{system_prompt: prompt}}},
          _from,
          test_pid
        ) do
      send(test_pid, {:injected_prompt, prompt})
      {:reply, {:ok, %{}}, test_pid}
    end

    def handle_call({:signal, _signal}, _from, state), do: {:reply, {:ok, %{}}, state}
  end

  defmodule FakeRuntime do
    @spec whereis(term()) :: nil
    def whereis(_id), do: nil

    # The handoff router starts workers via start_subagent/2.
    @spec start_subagent(module(), keyword()) :: {:ok, pid()}
    def start_subagent(_module, _opts) do
      {:ok, Application.fetch_env!(:jido_claw, :coherence_capturing_pid)}
    end
  end

  setup do
    orig_backend = Application.get_env(:jido_claw, :compaction_summarizer)
    Application.put_env(:jido_claw, :compaction_summarizer, RecordingBackend)
    Application.put_env(:jido_claw, :coherence_test_pid, self())

    on_exit(fn ->
      Application.put_env(:jido_claw, :compaction_summarizer, orig_backend)
      Application.delete_env(:jido_claw, :coherence_test_pid)
    end)

    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "coherence")
    {:ok, tenant_id: tenant_id, session: session, actor: actor_for(tenant_id)}
  end

  # Force-compaction config: keep the last turn verbatim, summarize the rest.
  defp force_cfg, do: Config.new!(max_messages: 4, keep_last_turns: 1, protect_first_n_turns: 0)

  defp append(ctx, agent_id, subagent, role, content, request_id) do
    {:ok, _} =
      Message.append(
        %{
          session_id: ctx.session.id,
          request_id: request_id,
          role: role,
          content: content,
          agent_id: agent_id,
          subagent: subagent
        },
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )
  end

  defp compact(ctx, identity) do
    {:ok, snap} =
      Compactor.compact(ctx.session.id, ctx.tenant_id,
        actor: ctx.actor,
        config: force_cfg(),
        compaction_id: identity
      )

    snap
  end

  defp drain_prompts(acc \\ []) do
    receive do
      {:summarizer_prompt, p} -> drain_prompts([p | acc])
    after
      0 -> acc
    end
  end

  describe "per-agent compaction coherence" do
    test "three agents → three independent snapshots, each summarizer sees only its own slice",
         ctx do
      reviewer_id = "handoff:#{ctx.session.id}:reviewer"
      coder_id = "coder_#{System.unique_integer([:positive])}"

      # main slice
      for i <- 1..3, do: append(ctx, "main", false, :user, "main-turn-#{i}", "req_m#{i}")
      # handoff/reviewer slice (incl. the enriched :system row)
      append(
        ctx,
        reviewer_id,
        false,
        :system,
        "[HANDOFF main → reviewer] review-context",
        "req_hs"
      )

      for i <- 1..3, do: append(ctx, reviewer_id, false, :user, "reviewer-turn-#{i}", "req_h#{i}")
      # sub-agent slice
      for i <- 1..3, do: append(ctx, coder_id, true, :user, "coder-turn-#{i}", "req_c#{i}")

      # Compact main, drain its summarizer prompt.
      _ = drain_prompts()
      main_snap = compact(ctx, "main")
      [main_prompt] = drain_prompts()

      reviewer_snap = compact(ctx, reviewer_id)
      [reviewer_prompt] = drain_prompts()

      coder_snap = compact(ctx, coder_id)
      [coder_prompt] = drain_prompts()

      # (a) three independent snapshots, none clobbered.
      {:ok, fresh} =
        Session.by_id(ctx.session.id, tenant: ctx.tenant_id, actor: ctx.actor)

      compactions = fresh.metadata["compactions"]
      assert Map.has_key?(compactions, "main::default")
      assert Map.has_key?(compactions, "#{reviewer_id}::default")
      assert Map.has_key?(compactions, "#{coder_id}::default")

      # Each snapshot summarized only its own request ids.
      assert Enum.all?(main_snap.summarized_request_ids, &String.starts_with?(&1, "req_m"))

      assert Enum.all?(
               reviewer_snap.summarized_request_ids,
               &(&1 in ["req_hs", "req_h1", "req_h2", "req_h3"])
             )

      assert Enum.all?(coder_snap.summarized_request_ids, &String.starts_with?(&1, "req_c"))

      # (b) each summarizer's transcript contained only its own rows.
      assert main_prompt =~ "main-turn"
      refute main_prompt =~ "reviewer-turn"
      refute main_prompt =~ "coder-turn"

      assert reviewer_prompt =~ "reviewer-turn"
      assert reviewer_prompt =~ "review-context"
      refute reviewer_prompt =~ "main-turn"
      refute reviewer_prompt =~ "coder-turn"

      assert coder_prompt =~ "coder-turn"
      refute coder_prompt =~ "main-turn"
      refute coder_prompt =~ "reviewer-turn"
    end

    test "(d) sub-agent slice is complete (task+terminal) yet excluded from others + primary view",
         ctx do
      coder_id = "coder_#{System.unique_integer([:positive])}"

      child_ctx = %{
        session_uuid: ctx.session.id,
        tenant_id: ctx.tenant_id,
        agent_id: coder_id,
        subagent: true,
        actor: ctx.actor
      }

      # main owns a turn; the sub-agent writes a complete task → terminal slice.
      append(ctx, "main", false, :user, "main asks", "req_m1")
      :ok = SubagentTranscript.record_task(child_ctx, "req_c1", "do the sub task")
      # record_result flushes the Recorder; no stub in this loop, so emit the
      # terminal signal directly to release the flush barrier.
      TerminalSignal.emit_completed("req_c1")
      :done = SubagentTranscript.record_result(child_ctx, "req_c1", {:ok, "sub done"})

      # Sub-agent slice has both the task and the terminal turn.
      {:ok, sub_slice} =
        Message.for_session_agent(ctx.session.id, coder_id,
          tenant: ctx.tenant_id,
          actor: ctx.actor
        )

      roles = Enum.map(sub_slice, & &1.role)
      assert :user in roles and :assistant in roles
      assert Enum.all?(sub_slice, & &1.subagent)

      # Excluded from main's slice.
      {:ok, main_slice} =
        Message.for_session_agent(ctx.session.id, "main", tenant: ctx.tenant_id, actor: ctx.actor)

      refute Enum.any?(main_slice, &(&1.agent_id == coder_id))

      # Excluded from the primary (chat-visible) view.
      {:ok, primary} =
        Message.for_session_primary(ctx.session.id, tenant: ctx.tenant_id, actor: ctx.actor)

      refute Enum.any?(primary, & &1.subagent)
      assert Enum.any?(primary, &(&1.content == "main asks"))
    end
  end

  describe "(c) handoff context survives in the reviewer's LLM-facing messages" do
    test "router injects base + handoff into the system prompt, and it survives compaction",
         ctx do
      {:ok, capturing} = CapturingAgent.start_link(self())
      Application.put_env(:jido_claw, :coherence_capturing_pid, capturing)
      orig_runtime = Application.get_env(:jido_claw, :jido_runtime)
      Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)

      rsid = ctx.session.external_id

      on_exit(fn ->
        if orig_runtime,
          do: Application.put_env(:jido_claw, :jido_runtime, orig_runtime),
          else: Application.delete_env(:jido_claw, :jido_runtime)

        Application.delete_env(:jido_claw, :coherence_capturing_pid)
        HandoffRegistry.clear(ctx.tenant_id, rsid)
      end)

      handoff =
        Handoff.new(%{
          tenant_id: ctx.tenant_id,
          runtime_session_id: rsid,
          session_uuid: ctx.session.id,
          from_template: "main",
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: "Please review",
          reason: "REASON_MARKER_correctness",
          summary: "SUMMARY_MARKER_recent_diff"
        })

      :ok = HandoffRegistry.put_owner(ctx.tenant_id, rsid, handoff)

      # Exercise the REAL router path → maybe_inject_prompt → inject_handoff_prompt.
      {_pid, "reviewer", _agent_id, _first?, _fresh?, _owner} =
        HandoffRouter.resolve_session_owner(
          ctx.tenant_id,
          rsid,
          ctx.session.id,
          self(),
          ctx.actor,
          project_dir: File.cwd!(),
          session_record: ctx.session,
          default_agent_id: rsid
        )

      assert_receive {:injected_prompt, system_prompt}, 2_000
      # Additive: the handoff reason + summary are present...
      assert system_prompt =~ "REASON_MARKER_correctness"
      assert system_prompt =~ "SUMMARY_MARKER_recent_diff"
      # ...and the base worker prompt is NOT replaced — it is still present.
      assert system_prompt =~ "HANDOFF CONTEXT"
      assert byte_size(system_prompt) > byte_size("[HANDOFF CONTEXT ...]")

      # The transformer keeps system messages across BOTH first compaction and
      # re-compaction, so the injected handoff context survives every pass.
      projection = [
        %{role: :system, content: system_prompt},
        %{role: :user, content: "summarized turn", refs: %{request_id: "req_old"}},
        %{role: :user, content: "live turn", refs: %{request_id: "req_new"}}
      ]

      for {summarized, last} <- [
            {["req_old"], "req_old"},
            {["req_old", "req_extra"], "req_extra"}
          ] do
        out = run_transformer(projection, summarized, last)

        # Base + handoff context survive.
        system = Enum.find(out, &(&1.role == :system))
        assert system, "system message must survive compaction"
        assert system.content =~ "REASON_MARKER_correctness"
        assert system.content =~ "SUMMARY_MARKER_recent_diff"

        # Summarized turn dropped, live turn kept.
        refute Enum.any?(out, &(Map.get(&1, :content) == "summarized turn"))
        assert Enum.any?(out, &(Map.get(&1, :content) == "live turn"))
      end
    end

    test "message-only handoff: the message lands in the system prompt and survives compaction",
         ctx do
      {:ok, capturing} = CapturingAgent.start_link(self())
      Application.put_env(:jido_claw, :coherence_capturing_pid, capturing)
      orig_runtime = Application.get_env(:jido_claw, :jido_runtime)
      Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)

      rsid = ctx.session.external_id

      on_exit(fn ->
        if orig_runtime,
          do: Application.put_env(:jido_claw, :jido_runtime, orig_runtime),
          else: Application.delete_env(:jido_claw, :jido_runtime)

        Application.delete_env(:jido_claw, :coherence_capturing_pid)
        HandoffRegistry.clear(ctx.tenant_id, rsid)
      end)

      # A NORMAL handoff: required :message only, no reason/summary — exactly
      # the shape that previously got NO handoff context in the kept prompt.
      handoff =
        Handoff.new(%{
          tenant_id: ctx.tenant_id,
          runtime_session_id: rsid,
          session_uuid: ctx.session.id,
          from_template: "main",
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: "MESSAGE_ONLY_MARKER_please_review_the_diff"
        })

      :ok = HandoffRegistry.put_owner(ctx.tenant_id, rsid, handoff)

      {_pid, "reviewer", _agent_id, _first?, _fresh?, _owner} =
        HandoffRouter.resolve_session_owner(
          ctx.tenant_id,
          rsid,
          ctx.session.id,
          self(),
          ctx.actor,
          project_dir: File.cwd!(),
          session_record: ctx.session,
          default_agent_id: rsid
        )

      assert_receive {:injected_prompt, system_prompt}, 2_000
      # The message-only handoff now lands additively in the system prompt...
      assert system_prompt =~ "MESSAGE_ONLY_MARKER_please_review_the_diff"
      assert system_prompt =~ "HANDOFF CONTEXT"
      # ...and the base worker prompt is still present (appended-to, not replaced).
      assert byte_size(system_prompt) > byte_size("[HANDOFF CONTEXT ...]")

      # System rows are never dropped → the injected message survives compaction.
      projection = [
        %{role: :system, content: system_prompt},
        %{role: :user, content: "summarized turn", refs: %{request_id: "req_old"}},
        %{role: :user, content: "live turn", refs: %{request_id: "req_new"}}
      ]

      out = run_transformer(projection, ["req_old"], "req_old")
      system = Enum.find(out, &(&1.role == :system))
      assert system, "system message must survive compaction"
      assert system.content =~ "MESSAGE_ONLY_MARKER_please_review_the_diff"
      refute Enum.any?(out, &(Map.get(&1, :content) == "summarized turn"))
      assert Enum.any?(out, &(Map.get(&1, :content) == "live turn"))
    end

    test "rehydrated owner injects the base prompt only — sentinel never surfaces as context",
         ctx do
      {:ok, capturing} = CapturingAgent.start_link(self())
      Application.put_env(:jido_claw, :coherence_capturing_pid, capturing)
      orig_runtime = Application.get_env(:jido_claw, :jido_runtime)
      Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)

      rsid = ctx.session.external_id
      # Freeze the base prompt so "no HANDOFF CONTEXT block" is a clean refute.
      session_record = %{ctx.session | metadata: %{"prompt_snapshot" => "BASE_ONLY_MARKER"}}

      on_exit(fn ->
        if orig_runtime,
          do: Application.put_env(:jido_claw, :jido_runtime, orig_runtime),
          else: Application.delete_env(:jido_claw, :jido_runtime)

        Application.delete_env(:jido_claw, :coherence_capturing_pid)
        HandoffRegistry.clear(ctx.tenant_id, rsid)
      end)

      # Rehydration placeholder — both placeholder sites
      # (Router.synthesize_owner/5 + Session.Worker.seed_handoff_from_metadata/4)
      # stamp Handoff.rehydrated_marker/0 on :from_template AND :message. The
      # guard must keep this on base-only despite the non-empty :message.
      handoff =
        Handoff.new(%{
          tenant_id: ctx.tenant_id,
          runtime_session_id: rsid,
          session_uuid: ctx.session.id,
          from_template: Handoff.rehydrated_marker(),
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: Handoff.rehydrated_marker()
        })

      :ok = HandoffRegistry.put_owner(ctx.tenant_id, rsid, handoff)

      {_pid, "reviewer", _agent_id, _first?, _fresh?, _owner} =
        HandoffRouter.resolve_session_owner(
          ctx.tenant_id,
          rsid,
          ctx.session.id,
          self(),
          ctx.actor,
          project_dir: File.cwd!(),
          session_record: session_record,
          default_agent_id: rsid
        )

      assert_receive {:injected_prompt, system_prompt}, 2_000
      # Base-prompt-only injection: no handoff block appended, sentinel absent.
      assert system_prompt == "BASE_ONLY_MARKER"
      refute system_prompt =~ "HANDOFF CONTEXT"
      refute system_prompt =~ Handoff.rehydrated_marker()
    end
  end

  defp run_transformer(projection, summarized_request_ids, last_request_id) do
    snapshot = %Snapshot{
      id: "cpct_#{System.unique_integer([:positive])}",
      session_id: "s",
      tenant_id: "t",
      agent_id: "handoff:x:reviewer",
      status: :summarized,
      strategy: :summary,
      summary: "earlier reviewer context",
      summary_preview: "earlier",
      source_message_count: length(summarized_request_ids),
      retained_message_count: 1,
      protected_message_count: 0,
      protected_turn_count: 0,
      last_summarized_sequence: 5,
      summarized_request_ids: summarized_request_ids,
      last_summarized_request_id: last_request_id,
      last_summarized_at_ms: 1,
      started_at_ms: 1,
      completed_at_ms: 2,
      metadata: %{}
    }

    runtime_context = %{
      RequestTransformer.runtime_context_key() => snapshot,
      RequestTransformer.test_capture_key() => self()
    }

    {:ok, _} =
      RequestTransformer.transform_request(%{messages: projection}, %{}, %{}, runtime_context)

    assert_receive {:compactor_transformer_messages, out}
    out
  end
end
