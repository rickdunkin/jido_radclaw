defmodule JidoClaw.Reasoning.Compactor.AgentSliceTest do
  @moduledoc """
  Phase 4: the Compactor reads its source slice keyed by the durable
  compaction identity, so each agent compacts only its own transcript.
  """

  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Message
  alias JidoClaw.Reasoning.Compactor
  alias JidoClaw.Reasoning.Compactor.Config

  defmodule FixedBackend do
    @behaviour JidoClaw.Reasoning.Compactor.Summarizer

    @impl JidoClaw.Reasoning.Compactor.Summarizer
    def summarize(_prompt, _opts), do: {:ok, "SUMMARY"}
  end

  setup do
    original = Application.get_env(:jido_claw, :compaction_summarizer)
    Application.put_env(:jido_claw, :compaction_summarizer, FixedBackend)
    on_exit(fn -> Application.put_env(:jido_claw, :compaction_summarizer, original) end)

    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "slice")
    {:ok, tenant_id: tenant_id, session: session, actor: actor_for(tenant_id)}
  end

  defp append(ctx, agent_id, subagent, role, content, request_id) do
    {:ok, msg} =
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

    msg
  end

  describe "for_session_agent/3" do
    test "returns only the rows stamped with that compaction identity", ctx do
      handoff_id = "handoff:#{ctx.session.id}:reviewer"

      append(ctx, "main", false, :user, "m1", "req_m1")
      append(ctx, "main", false, :assistant, "m2", "req_m1")
      append(ctx, handoff_id, false, :user, "h1", "req_h1")
      append(ctx, "coder_1", true, :user, "c1", "req_c1")

      assert {:ok, main} =
               Message.for_session_agent(ctx.session.id, "main",
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert Enum.map(main, & &1.content) == ["m1", "m2"]

      assert {:ok, handoff} =
               Message.for_session_agent(ctx.session.id, handoff_id,
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert Enum.map(handoff, & &1.content) == ["h1"]

      assert {:ok, sub} =
               Message.for_session_agent(ctx.session.id, "coder_1",
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert Enum.map(sub, & &1.content) == ["c1"]
    end
  end

  describe "since_watermark_for_agent/4" do
    test "filters by BOTH agent identity and the per-session sequence watermark", ctx do
      m1 = append(ctx, "main", false, :user, "m1", "req_m1")
      # interleave a sub-agent row at a higher sequence
      append(ctx, "coder_1", true, :user, "c1", "req_c1")
      _m2 = append(ctx, "main", false, :assistant, "m2", "req_m1")

      assert {:ok, rows} =
               Message.since_watermark_for_agent(ctx.session.id, "main", m1.sequence,
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      # Only the later main row — the interleaved sub-agent row is excluded.
      assert Enum.map(rows, & &1.content) == ["m2"]
    end
  end

  describe "Compactor.compact/3 — per-agent slice" do
    test "a sub-agent compacts under its OWN identity, never folding in main rows", ctx do
      for i <- 1..4, do: append(ctx, "main", false, :user, "m#{i}", "req_m#{i}")
      for i <- 1..4, do: append(ctx, "coder_1", true, :user, "c#{i}", "req_c#{i}")

      cfg = Config.new!(max_messages: 4, keep_last_turns: 1, protect_first_n_turns: 0)

      assert {:ok, snap} =
               Compactor.compact(ctx.session.id, ctx.tenant_id,
                 actor: ctx.actor,
                 config: cfg,
                 compaction_id: "coder_1"
               )

      assert snap.status == :summarized
      assert snap.summarized_request_ids != []
      # Every summarized request id is a coder turn — no main turns leaked in.
      assert Enum.all?(snap.summarized_request_ids, &String.starts_with?(&1, "req_c"))
      refute Enum.any?(snap.summarized_request_ids, &String.starts_with?(&1, "req_m"))
    end

    test "the main slice excludes handoff + sub-agent rows", ctx do
      handoff_id = "handoff:#{ctx.session.id}:reviewer"

      for i <- 1..4, do: append(ctx, "main", false, :user, "m#{i}", "req_m#{i}")
      append(ctx, handoff_id, false, :user, "h1", "req_h1")
      append(ctx, "coder_1", true, :user, "c1", "req_c1")

      cfg = Config.new!(max_messages: 4, keep_last_turns: 1, protect_first_n_turns: 0)

      assert {:ok, snap} =
               Compactor.compact(ctx.session.id, ctx.tenant_id,
                 actor: ctx.actor,
                 config: cfg,
                 compaction_id: "main"
               )

      assert snap.status == :summarized
      assert Enum.all?(snap.summarized_request_ids, &String.starts_with?(&1, "req_m"))
      refute Enum.any?(snap.summarized_request_ids, &(&1 in ["req_h1", "req_c1"]))
    end
  end
end
