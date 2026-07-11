defmodule JidoClaw.Conversations.ContextRestoreTest do
  @moduledoc """
  Pins `JidoClaw.Conversations.ContextRestore`: the pure transcript→context
  fold (chat rows only, refs + system prompt carried) and the
  `ai.react.context.modify` delivery contract, captured via the shared
  `JidoClaw.Test.CapturingAgent`.
  """
  use JidoClaw.TenantCase, async: true

  alias Jido.AI.Context
  alias JidoClaw.Conversations.ContextRestore
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Test.CapturingAgent

  describe "build_context/2 (pure)" do
    test "only user/assistant rows with binary content survive, in order, with refs" do
      rows = [
        %{role: :user, content: "q1", request_id: "req-1"},
        %{role: :tool_call, content: "noise", request_id: "req-1"},
        %{role: :reasoning, content: "thinking", request_id: "req-1"},
        %{role: :assistant, content: "a1", request_id: "req-1"},
        %{role: :system, content: "sys row", request_id: nil},
        %{role: :assistant, content: nil, request_id: "req-2"},
        %{role: :user, content: "q2", request_id: nil}
      ]

      ctx = ContextRestore.build_context(rows, "PROMPT_BYTES")

      assert %Context{system_prompt: "PROMPT_BYTES"} = ctx

      # Entries are stored newest-first internally; reverse to chronological.
      entries = Enum.reverse(ctx.entries)

      assert Enum.map(entries, &{&1.role, &1.content}) == [
               {:user, "q1"},
               {:assistant, "a1"},
               {:user, "q2"}
             ]

      # refs.request_id preserved (the compaction transformer's filter key);
      # legacy rows without a request_id get nil refs (always kept).
      assert Enum.map(entries, & &1.refs) == [
               %{request_id: "req-1"},
               %{request_id: "req-1"},
               nil
             ]
    end

    test "empty rows build an entry-less context that still carries the prompt" do
      assert %Context{entries: [], system_prompt: "P"} = ContextRestore.build_context([], "P")
    end
  end

  describe "restore/4 delivery" do
    setup do
      %{tenant_id: tenant_id, session: session} =
        seed_full(
          tenant_label: "ctx-restore",
          session: [kind: :cli_run, metadata: %{"prompt_snapshot" => "SNAP_PROMPT"}]
        )

      {:ok, tenant_id: tenant_id, session: session, actor: actor_for(tenant_id)}
    end

    defp append!(ctx, role, content, request_id) do
      {:ok, _} =
        Message.append(
          %{session_id: ctx.session.id, role: role, content: content, request_id: request_id},
          tenant: ctx.tenant_id,
          actor: ctx.actor
        )

      :ok
    end

    test "delivers a :replace/:restore context.modify carrying transcript + prompt", ctx do
      append!(ctx, :user, "hello", "req-a")
      append!(ctx, :assistant, "hi there", "req-a")

      {:ok, pid} = CapturingAgent.start_link(self())

      assert :ok = ContextRestore.restore(pid, ctx.session, File.cwd!(), actor: ctx.actor)

      assert_receive {:context_modify, %{operation: op}}, 2_000
      assert op.type == :replace
      assert op.reason == :restore

      # The restored context MUST carry the snapshot bytes: at ask time the
      # strategy uses context.system_prompt with no config fallback.
      assert %Context{system_prompt: "SNAP_PROMPT"} = op.result_context

      entries = Enum.reverse(op.result_context.entries)

      assert Enum.map(entries, &{&1.role, &1.content}) == [
               {:user, "hello"},
               {:assistant, "hi there"}
             ]

      assert Enum.map(entries, & &1.refs) == [
               %{request_id: "req-a"},
               %{request_id: "req-a"}
             ]
    end

    test "a session with no chat rows sends no signal", ctx do
      append!(ctx, :system, "system note", nil)
      append!(ctx, :reasoning, "internal", "req-x")

      {:ok, pid} = CapturingAgent.start_link(self())

      assert :ok = ContextRestore.restore(pid, ctx.session, File.cwd!(), actor: ctx.actor)

      refute_receive {:context_modify, _}, 200
    end

    test "a dead target pid surfaces an error tuple, not an exit", ctx do
      append!(ctx, :user, "hello", "req-a")

      {:ok, pid} = CapturingAgent.start_link(self())
      GenServer.stop(pid)

      assert {:error, {:agent_call_exit, _}} =
               ContextRestore.restore(pid, ctx.session, File.cwd!(), actor: ctx.actor)
    end
  end
end
