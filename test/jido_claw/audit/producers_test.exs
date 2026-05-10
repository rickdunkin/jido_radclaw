defmodule JidoClaw.Audit.ProducersTest do
  @moduledoc """
  Coverage for the inline `JidoClaw.Audit.Producers.*` change modules
  wired into producer actions.

  Locks in:

    * `Session.start` (`SessionStart` producer) writes a
      `:session_start` audit row in the same transaction.
    * `Session.close` (`SessionEnd` producer) writes a `:session_end`
      audit row.
    * `Memory.Block.write` (`MemoryWrite` producer) writes a
      `:memory_write` audit row with `target_kind: :memory_block`.
    * Solution `:store` with `sharing in [:shared, :public]` writes a
      `:solution_share` row; `:local` does NOT.
    * Each producer flows through `AsyncWriter.sync/1` so the audit
      row is durably visible after the action returns.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit.Event
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Memory.Block
  alias JidoClaw.Solutions.Solution

  describe "SessionStart producer" do
    test "Session.start writes a :session_start audit row in the same transaction" do
      tenant_id = seed_tenant("audit-session-start")
      {:ok, ws} = seed_workspace(tenant_id)

      external_id = "ext-#{System.unique_integer([:positive])}"

      {:ok, session} =
        Session.start(
          %{
            workspace_id: ws.id,
            kind: :api,
            external_id: external_id,
            started_at: DateTime.utc_now()
          },
          tenant: tenant_id
        )

      {:ok, rows} = Event.read(tenant: tenant_id)

      audit_row =
        Enum.find(rows, fn r ->
          r.event_kind == :session_start and r.target_kind == :session and
            r.target_id == to_string(session.id)
        end)

      assert audit_row, "expected one :session_start audit row for the new session"
      assert audit_row.actor_kind == :system
      payload = audit_row.payload
      assert (Map.get(payload, "external_id") || Map.get(payload, :external_id)) == external_id
    end
  end

  describe "SessionEnd producer" do
    test "Session.close writes a :session_end audit row" do
      tenant_id = seed_tenant("audit-session-end")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, session} =
        Session.start(
          %{
            workspace_id: ws.id,
            kind: :api,
            external_id: "ext-end-#{System.unique_integer([:positive])}",
            started_at: DateTime.utc_now()
          },
          tenant: tenant_id
        )

      {:ok, _closed} = Session.close(session, %{}, tenant: tenant_id)

      {:ok, rows} = Event.read(tenant: tenant_id)

      audit_row =
        Enum.find(rows, fn r ->
          r.event_kind == :session_end and r.target_id == to_string(session.id)
        end)

      assert audit_row, "expected one :session_end audit row for the closed session"
    end
  end

  describe "MemoryWrite producer" do
    test "Block.write writes a :memory_write audit row with target_kind :memory_block" do
      tenant_id = seed_tenant("audit-memory-write")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "audit_test",
            value: "v1",
            source: :user
          },
          tenant: tenant_id
        )

      {:ok, rows} = Event.read(tenant: tenant_id)

      audit_row =
        Enum.find(rows, fn r ->
          r.event_kind == :memory_write and r.target_kind == :memory_block and
            r.target_id == to_string(block.id)
        end)

      assert audit_row, "expected one :memory_write audit row for the new block"
    end
  end

  describe "SolutionShare producer" do
    test "Solution.store with sharing: :shared writes a :solution_share audit row" do
      tenant_id = seed_tenant("audit-share")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, sol} =
        Solution.store(
          %{
            problem_signature: "sig-shared-#{System.unique_integer([:positive])}",
            solution_content: "shared content",
            language: "elixir",
            sharing: :shared,
            workspace_id: ws.id,
            embedding_status: :disabled
          },
          tenant: tenant_id
        )

      {:ok, rows} = Event.read(tenant: tenant_id)

      audit_row =
        Enum.find(rows, fn r ->
          r.event_kind == :solution_share and r.target_kind == :solution and
            r.target_id == to_string(sol.id)
        end)

      assert audit_row, "expected one :solution_share audit row for the shared solution"
    end

    test "Solution.store with sharing: :local does NOT write a :solution_share audit row" do
      tenant_id = seed_tenant("audit-share-local")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, sol} =
        Solution.store(
          %{
            problem_signature: "sig-local-#{System.unique_integer([:positive])}",
            solution_content: "local content",
            language: "elixir",
            sharing: :local,
            workspace_id: ws.id,
            embedding_status: :disabled
          },
          tenant: tenant_id
        )

      {:ok, rows} = Event.read(tenant: tenant_id)

      assert Enum.all?(rows, fn r ->
               not (r.event_kind == :solution_share and r.target_id == to_string(sol.id))
             end),
             "did not expect a :solution_share audit row for a :local solution"
    end
  end
end
