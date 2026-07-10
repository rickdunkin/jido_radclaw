defmodule JidoClaw.Tools.InspectAgentTest do
  use JidoClaw.TenantCase, async: false

  import JidoClaw.TraceTestHelpers, only: [sync_collector: 0]

  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Memory.Block
  alias JidoClaw.Tools.InspectAgent

  setup do
    %{tenant_id: tenant_id, session: session, workspace: workspace} =
      seed_full(tenant_label: "inspect_tool")

    {:ok,
     tenant_id: tenant_id, session: session, workspace: workspace, actor: actor_for(tenant_id)}
  end

  defp ctx(tenant_id) do
    %{tool_context: %{tenant_id: tenant_id}}
  end

  describe "run/2" do
    test "kind: module with target JidoClaw.Agent works", %{tenant_id: tid} do
      assert {:ok, output} =
               InspectAgent.run(
                 %{target: "JidoClaw.Agent", kind: "module"},
                 ctx(tid)
               )

      assert output.input_kind == "module"
      assert "read_file" in output.tool_names
    end

    test "kind: request routes through inspect_request and surfaces tenant_required when missing",
         %{tenant_id: _tid} do
      assert {:error, %{code: :tenant_required}} =
               InspectAgent.run(
                 %{target: "req-1", kind: "request"},
                 %{tool_context: %{}}
               )
    end

    test "output is JSON-safe (atoms stringified, no DateTime leafs)", %{
      tenant_id: tid,
      session: session
    } do
      assert {:ok, output} =
               InspectAgent.run(
                 %{target: session.external_id, kind: "session"},
                 ctx(tid)
               )

      assert output.input_kind == "session"

      # Top-level keys stay atoms (output_schema contract); the nested
      # `usage` map is string-keyed (output.usage["input_tokens"], NOT
      # output.usage.input_tokens).
      assert output.usage["input_tokens"] == 0
      assert output.usage["output_tokens"] == 0

      # New fields. `model` is the resolved module's configured alias,
      # stringified by the nil-preserving helper (→ "fast", never "nil").
      # `status`/`user_message` are absent on the session_map path and must
      # stay `nil` — proving stringify_nilable(nil) does NOT emit the string
      # "nil" at the boundary.
      assert output.model == "fast"
      assert is_nil(output.status) or is_binary(output.status)
      assert is_nil(output.user_message) or is_binary(output.user_message)
      assert output.status == nil
      assert output.user_message == nil

      # handoffs is nil for plain session — but if present, values are stringified
      if output.handoffs do
        Enum.each(output.handoffs, fn {k, _} -> assert is_binary(k) end)
      end
    end

    test "compaction is JSON-normalized: string keys, stringified values, no leaf atoms", %{
      tenant_id: tid,
      session: session,
      workspace: workspace,
      actor: actor
    } do
      # Compaction is only populated on the request-inspection path
      # (`session` dispatch skips it), so seed a snapshot on the session,
      # correlate a request to it, and inspect by request id.
      # The correlation below registers with no agent_id, so inspection
      # resolves the snapshot under the main agent's key.
      {:ok, _} =
        Session.set_compaction_snapshot(
          session,
          "main::default",
          %{"summary" => "rolled up", "summarized_request_ids" => [], "version" => 1},
          tenant: tid,
          actor: actor
        )

      request_id = Ecto.UUID.generate()

      {:ok, _} =
        RequestCorrelation.register(
          %{
            request_id: request_id,
            session_id: session.id,
            tenant_id: tid,
            workspace_id: workspace.id,
            user_id: nil
          },
          authorize?: false
        )

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{
          agent_id: session.external_id,
          request_id: request_id,
          tenant_id: tid,
          run_id: request_id
        }
      )

      :ok = sync_collector()

      assert {:ok, output} =
               InspectAgent.run(%{target: request_id, kind: "request"}, ctx(tid))

      assert is_map(output.compaction)
      # `Map.from_struct/1` leaves atom keys + atom values (status:
      # :summarized, strategy: :summary); the shared normalizer stringifies
      # both, and string-keys the map.
      refute leaf_violates?(output.compaction)
      assert output.compaction["status"] == "summarized"
      assert output.compaction["strategy"] == "summary"
    end

    test "memory is exposed slimmed to {scope_kind, blocks_count} — no raw scope/namespace", %{
      tenant_id: tid,
      session: session,
      workspace: workspace,
      actor: actor
    } do
      # `kind: "session"` (map path) stays nil by design, so prove the
      # non-nil path via `kind: "request"` (mirrors the compaction test
      # setup). Seed one session-scoped block so blocks_count is known.
      {:ok, _} =
        Block.write(
          %{
            scope_kind: :session,
            session_id: session.id,
            label: "req_pref",
            value: "session-scoped block",
            source: :user
          },
          tenant: tid,
          actor: actor
        )

      request_id = Ecto.UUID.generate()

      {:ok, _} =
        RequestCorrelation.register(
          %{
            request_id: request_id,
            session_id: session.id,
            tenant_id: tid,
            workspace_id: workspace.id,
            user_id: nil
          },
          authorize?: false
        )

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{
          agent_id: session.external_id,
          request_id: request_id,
          tenant_id: tid,
          run_id: request_id
        }
      )

      :ok = sync_collector()

      assert {:ok, output} =
               InspectAgent.run(%{target: request_id, kind: "request"}, ctx(tid))

      # String-keyed (routed through JsonSafe), slimmed to kind + count.
      assert output.memory == %{"scope_kind" => "session", "blocks_count" => 1}
      # The raw-UUID scope sub-map and the FK-bearing namespace are dropped.
      refute Map.has_key?(output.memory, "scope")
      refute Map.has_key?(output.memory, "namespace")
    end
  end

  describe "run/2 — removed kinds are no longer dispatchable" do
    test "calling run/2 directly with removed kinds falls through to :unknown_kind", %{
      tenant_id: tid
    } do
      # Direct run/2 bypasses Jido schema validation, so this exercises the
      # removed dispatch clauses → catch-all → normalized.
      for kind <- ["auto", "agent_id", "workflow"] do
        assert {:error, %{code: :unknown_kind}} =
                 InspectAgent.run(%{target: "anything", kind: kind}, ctx(tid))
      end
    end

    test "validate_params rejects removed kinds at the schema enum layer" do
      for kind <- ["auto", "agent_id", "workflow"] do
        assert {:error, _} = InspectAgent.validate_params(%{target: "anything", kind: kind})
      end
    end
  end

  # Mirrors agent_view_test.exs's recursive JSON-safety walker: any leaf
  # atom (besides nil/true/false), non-binary map key, or DateTime is a
  # violation.
  defp leaf_violates?(value) when is_map(value) do
    Enum.any?(value, fn {k, v} -> not is_binary(k) or leaf_violates?(v) end)
  end

  defp leaf_violates?(value) when is_list(value), do: Enum.any?(value, &leaf_violates?/1)
  defp leaf_violates?(nil), do: false
  defp leaf_violates?(true), do: false
  defp leaf_violates?(false), do: false
  defp leaf_violates?(value) when is_atom(value), do: true
  defp leaf_violates?(%DateTime{}), do: true
  defp leaf_violates?(%NaiveDateTime{}), do: true
  defp leaf_violates?(_), do: false
end
