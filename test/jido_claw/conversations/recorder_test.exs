defmodule JidoClaw.Conversations.RecorderTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.{Message, Recorder, Session}
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Workspaces.Workspace

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "flush/2" do
    test "returns {:error, :timeout} (does NOT exit caller) when terminal signal never arrives" do
      # The Recorder is started under InfraSupervisor in test mode. If for
      # some reason it isn't running, flush returns {:error, :timeout} via
      # the :noproc catch — which is also acceptable for the contract:
      # the dispatcher must not crash.
      result = Recorder.flush("nonexistent-request-id-#{System.unique_integer([:positive])}", 100)

      assert result == {:error, :timeout}
    end
  end

  # Regression for the P2 parent-resolution fix in `recorder.ex`.
  # `:tool_result` rows must link to the matching `:tool_call` parent of
  # the *same request*, never a stale or sibling row keyed only by
  # `(session_id, tool_call_id)`.
  describe "tool_result parent resolution" do
    test "links to the same-request parent across sessions sharing a tool_call_id" do
      %{tenant_id: tenant_a, session: session_a} = seed_session("recA")
      %{tenant_id: tenant_b, session: session_b} = seed_session("recB")

      r_a = "req-#{System.unique_integer([:positive])}"
      r_b = "req-#{System.unique_integer([:positive])}"

      register(r_a, session_a.id, tenant_a)
      register(r_b, session_b.id, tenant_b)

      tool_call_id = "shared-call-#{System.unique_integer([:positive])}"

      {:ok, parent_a} =
        Message.append(%{
          session_id: session_a.id,
          request_id: r_a,
          role: :tool_call,
          content: "tool_a()",
          tool_call_id: tool_call_id
        })

      {:ok, parent_b} =
        Message.append(%{
          session_id: session_b.id,
          request_id: r_b,
          role: :tool_call,
          content: "tool_b()",
          tool_call_id: tool_call_id
        })

      emit_tool_result(r_a, tool_call_id, "tool_a", {:ok, "ok-a"})
      finalize_and_flush(r_a)

      [tr_a] = tool_results_for(session_a.id)

      assert tr_a.parent_message_id == parent_a.id,
             "expected the :tool_result for r_a to link to session A's parent (#{parent_a.id}), got #{inspect(tr_a.parent_message_id)} (B's parent is #{parent_b.id})"

      # Sanity: nothing slipped into session B yet.
      assert tool_results_for(session_b.id) == []
    end

    test "two requests in the same session with overlapping tool_call_ids each resolve their own parent" do
      %{tenant_id: tenant, session: session} = seed_session("recSame")

      r1 = "req-1-#{System.unique_integer([:positive])}"
      r2 = "req-2-#{System.unique_integer([:positive])}"

      register(r1, session.id, tenant)
      register(r2, session.id, tenant)

      tool_call_id = "dup-#{System.unique_integer([:positive])}"

      {:ok, parent_1} =
        Message.append(%{
          session_id: session.id,
          request_id: r1,
          role: :tool_call,
          content: "first",
          tool_call_id: tool_call_id
        })

      {:ok, parent_2} =
        Message.append(%{
          session_id: session.id,
          request_id: r2,
          role: :tool_call,
          content: "second",
          tool_call_id: tool_call_id
        })

      emit_tool_result(r2, tool_call_id, "second", {:ok, "ok-2"})
      finalize_and_flush(r2)

      [tr_2] = tool_results_for(session.id)

      assert tr_2.parent_message_id == parent_2.id,
             "expected r2 result to link to parent_2 (#{parent_2.id}), got #{inspect(tr_2.parent_message_id)} (parent_1 is #{parent_1.id})"
    end

    test "registered scope but no parent row → :tool_result row is written with parent_message_id: nil" do
      %{tenant_id: tenant, session: session} = seed_session("recOrphan")

      r3 = "req-3-#{System.unique_integer([:positive])}"
      register(r3, session.id, tenant)

      emit_tool_result(r3, "orphan_call", "orphan_tool", {:error, :nope})
      finalize_and_flush(r3)

      [tr_3] = tool_results_for(session.id)

      assert tr_3.parent_message_id == nil
      assert tr_3.tool_call_id == "orphan_call"
    end

    test "unregistered request_id → no :tool_result row is written" do
      %{session: session} = seed_session("recUnregistered")

      orphan_request = "unregistered-#{System.unique_integer([:positive])}"

      # Drain the recorder's mailbox via a known-completed sentinel before
      # the unregistered emit, then again after. Without a terminal signal
      # for the unregistered request_id, there's nothing to flush against,
      # so we use a sentinel we DO control to confirm the queue has drained
      # past our orphan emit.
      sentinel_request = "sentinel-#{System.unique_integer([:positive])}"
      sentinel_session = session

      %{tenant_id: tenant} = seed_session_for(sentinel_session)
      register(sentinel_request, sentinel_session.id, tenant)

      emit_tool_result(orphan_request, "ghost", "ghost_tool", {:ok, "x"})
      emit_tool_result(sentinel_request, "real", "real_tool", {:ok, "y"})
      finalize_and_flush(sentinel_request)

      results = tool_results_for(sentinel_session.id)
      tool_call_ids = Enum.map(results, & &1.tool_call_id) |> MapSet.new()

      assert MapSet.member?(tool_call_ids, "real")
      refute MapSet.member?(tool_call_ids, "ghost")
    end
  end

  describe "scope resolution via Postgres fallback" do
    test "Recorder rehydrates scope from RequestCorrelation when ETS cache misses" do
      %{tenant_id: tenant, session: session} = seed_session("durable")

      request_id = "req-durable-#{System.unique_integer([:positive])}"

      # Go through the public dispatcher API — writes both the ETS Cache
      # and the durable RequestCorrelation row.
      :ok = JidoClaw.register_correlation(request_id, session.id, tenant, nil, nil)

      # Force the cache miss so the Recorder hits the Postgres fallback path.
      Cache.delete(request_id)

      tool_call_id = "call-durable-#{System.unique_integer([:positive])}"

      {:ok, parent} =
        Message.append(%{
          session_id: session.id,
          request_id: request_id,
          role: :tool_call,
          content: "tool()",
          tool_call_id: tool_call_id
        })

      emit_tool_result(request_id, tool_call_id, "tool", {:ok, "ok"})
      finalize_and_flush(request_id)

      [tr] = tool_results_for(session.id)

      assert tr.parent_message_id == parent.id,
             "expected the :tool_result to link to the durable-path parent (#{parent.id}), got #{inspect(tr.parent_message_id)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_session(label) do
    tenant_id = "tenant-rec-#{label}-#{System.unique_integer([:positive])}"

    {:ok, ws} =
      Workspace.register(%{
        tenant_id: tenant_id,
        path: "/tmp/rec-#{label}-#{System.unique_integer([:positive])}",
        name: label
      })

    {:ok, session} =
      Session.start(%{
        workspace_id: ws.id,
        tenant_id: tenant_id,
        kind: :api,
        external_id: "ext-#{label}-#{System.unique_integer([:positive])}",
        started_at: DateTime.utc_now()
      })

    %{tenant_id: tenant_id, workspace: ws, session: session}
  end

  defp seed_session_for(session) do
    %{tenant_id: session.tenant_id}
  end

  defp register(request_id, session_id, tenant_id) do
    # Cache.put alone is enough for the Recorder's resolve_scope/1 path —
    # `RequestCorrelation.lookup` is the fallback after a cache miss, so
    # populating the cache directly skips the changeset bug surfaced by
    # the missing `expires_at` default and keeps these tests focused on
    # parent-resolution behavior.
    Cache.put(request_id, %{
      session_id: session_id,
      tenant_id: tenant_id,
      workspace_id: nil,
      user_id: nil
    })
  end

  defp emit_tool_result(request_id, call_id, tool_name, result) do
    {:ok, signal} =
      Jido.Signal.new(
        "ai.tool.result",
        %{
          tool_name: tool_name,
          call_id: call_id,
          result: result,
          metadata: %{request_id: request_id}
        },
        source: "/test"
      )

    Jido.Signal.Bus.publish(JidoClaw.SignalBus, [signal])
  end

  defp finalize_and_flush(request_id) do
    {:ok, terminal} =
      Jido.Signal.new(
        "ai.request.completed",
        %{request_id: request_id},
        source: "/test"
      )

    Jido.Signal.Bus.publish(JidoClaw.SignalBus, [terminal])

    case Recorder.flush(request_id, 5_000) do
      :ok ->
        :ok

      other ->
        flunk("Recorder.flush(#{request_id}) returned #{inspect(other)}")
    end
  end

  defp tool_results_for(session_id) do
    {:ok, rows} = Message.for_session(session_id)
    Enum.filter(rows, &(&1.role == :tool_result))
  end
end
