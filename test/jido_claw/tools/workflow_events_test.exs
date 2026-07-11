defmodule JidoClaw.Tools.WorkflowEventsTest do
  @moduledoc """
  G2-1a — the raw per-run event-feed tool (the `get_logs_on_task` analogue).
  Asserts the projected wire shape (atom top-level keys, string-keyed nested
  event maps), seq-ascending order, byte-aware seq pagination (including the +1
  sentinel exact-boundary case), tenant + not-found + cross-tenant refusals, the
  redaction pin, and the full `Jido.Exec.run` path so `output_schema` validation
  (and the undeclared `events` extra-key pass-through) is exercised.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Tools.WorkflowEvents

  setup do
    tenant = seed_tenant("workflow-events")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "run/2 (projected wire shape)" do
    test "returns events seq-ascending: atom top-level, string-keyed event maps", ctx do
      run = run_with_events!(ctx, 3)

      assert {:ok, output} = WorkflowEvents.run(%{run_id: run.id}, tool_ctx(ctx))

      # Top-level keys are ATOMS (output_schema splits on atoms).
      assert output.run_id == run.id
      # `run_status` (not `status`): a bare `status` would trip the shared
      # `Error.normalize_result/1` soft-fail promotion. Never-started ⇒ pending.
      assert output.run_status == "pending"
      assert output.count == 3

      # Events are STRING-keyed and seq-ascending.
      assert Enum.map(output.events, & &1["seq"]) == [1, 2, 3]
      first = hd(output.events)
      assert first["kind"] == "signals_published"
      assert is_map(first["payload"])
      assert is_binary(first["occurred_at"])

      # Only 3 events under the default 50 page target ⇒ no further page.
      refute Map.has_key?(output, :next_seq)
    end

    test "pagination: after_seq skips consumed events; next_seq advances then nils out", ctx do
      run = run_with_events!(ctx, 5)

      assert {:ok, page1} = WorkflowEvents.run(%{run_id: run.id, limit: 2}, tool_ctx(ctx))
      assert page1.count == 2
      assert Enum.map(page1.events, & &1["seq"]) == [1, 2]
      assert page1.next_seq == 2

      assert {:ok, page2} =
               WorkflowEvents.run(%{run_id: run.id, limit: 2, after_seq: 2}, tool_ctx(ctx))

      assert Enum.map(page2.events, & &1["seq"]) == [3, 4]
      assert page2.next_seq == 4

      # Final partial page: one event, no next cursor.
      assert {:ok, page3} =
               WorkflowEvents.run(%{run_id: run.id, limit: 2, after_seq: 4}, tool_ctx(ctx))

      assert Enum.map(page3.events, & &1["seq"]) == [5]
      assert page3.count == 1
      refute Map.has_key?(page3, :next_seq)
    end

    test "exact-boundary (+1 sentinel): exactly `limit` events and none beyond ⇒ next_seq nil",
         ctx do
      run = run_with_events!(ctx, 3)

      assert {:ok, output} = WorkflowEvents.run(%{run_id: run.id, limit: 3}, tool_ctx(ctx))
      assert output.count == 3
      assert Enum.map(output.events, & &1["seq"]) == [1, 2, 3]
      # No phantom empty page: the +1 sentinel row was absent, so no next cursor.
      refute Map.has_key?(output, :next_seq)
    end

    test "missing tenant in tool context is a tenant_required wire error", ctx do
      run = run_with_events!(ctx, 1)

      assert {:error, %{code: :tenant_required}} =
               WorkflowEvents.run(%{run_id: run.id}, %{tool_context: %{}})
    end

    test "an unknown run id is not_found", ctx do
      assert {:error, %{code: :not_found}} =
               WorkflowEvents.run(%{run_id: Ash.UUID.generate()}, tool_ctx(ctx))
    end

    test "a run in another tenant is not_found (cross-tenant isolation)", ctx do
      run = run_with_events!(ctx, 2)
      other = seed_tenant("workflow-events-other")

      assert {:error, %{code: :not_found}} =
               WorkflowEvents.run(%{run_id: run.id}, %{tool_context: %{tenant_id: other}})
    end

    test "a secret in an event payload never reaches MCP output (redacted)", ctx do
      secret = "sk-" <> String.duplicate("z", 24)

      {:ok, run} =
        WorkflowRun.create(%{name: "leaky", workflow_type: "composer"},
          tenant: ctx.tenant,
          actor: ctx.actor
        )

      append!(run, :signals_published, %{"topic" => "leak", "token" => secret}, ctx)

      assert {:ok, output} = WorkflowEvents.run(%{run_id: run.id}, tool_ctx(ctx))
      refute Jason.encode!(output) =~ secret
    end
  end

  describe "full Jido.Exec path (output_schema validation)" do
    test "validates output; the undeclared `events` extra key passes through", ctx do
      run = run_with_events!(ctx, 2)

      assert {:ok, output} =
               Jido.Exec.run(WorkflowEvents, %{run_id: run.id}, tool_ctx(ctx), log_level: :error)

      assert output.run_id == run.id
      assert output.count == 2
      # Exactly two events; pattern-match rather than length/1 vs a literal.
      assert [_, _] = output.events
    end
  end

  # -- helpers --

  defp tool_ctx(%{tenant: tenant}), do: %{tool_context: %{tenant_id: tenant}}

  # A run with `count` non-status-authority events (seq 1..count); the run stays
  # :pending so run_status is deterministic and seq counting is clean.
  defp run_with_events!(ctx, count) do
    {:ok, run} =
      WorkflowRun.create(%{name: "feed-run", workflow_type: "composer"},
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    for i <- 1..count//1, do: append!(run, :signals_published, %{"n" => i}, ctx)
    run
  end

  defp append!(run, kind, payload, ctx) do
    {:ok, _} = WorkflowLog.append(run, kind, payload, tenant: ctx.tenant, actor: ctx.actor)
  end
end
