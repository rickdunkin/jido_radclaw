defmodule JidoClaw.Conversations.ResolverTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.Resolver, as: ConvResolver
  alias JidoClaw.Workspaces.Resolver, as: WsResolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  describe "ensure_session/5 — cross-workspace identity" do
    test "two workspaces in one tenant get distinct sessions for the same (kind, external_id)" do
      tenant = "default"

      {:ok, ws1} =
        WsResolver.ensure_workspace(
          tenant,
          "/tmp/cross-ws-a-#{System.unique_integer([:positive])}"
        )

      {:ok, ws2} =
        WsResolver.ensure_workspace(
          tenant,
          "/tmp/cross-ws-b-#{System.unique_integer([:positive])}"
        )

      assert ws1.id != ws2.id

      external_id = "shared-agent-id"
      kind = :cron

      {:ok, sess1} = ConvResolver.ensure_session(tenant, ws1.id, kind, external_id)
      {:ok, sess2} = ConvResolver.ensure_session(tenant, ws2.id, kind, external_id)

      assert sess1.id != sess2.id
      assert sess1.workspace_id == ws1.id
      assert sess2.workspace_id == ws2.id
      assert sess1.external_id == sess2.external_id
      assert sess1.kind == sess2.kind
    end

    test "idempotent reuse within (tenant, workspace, kind, external_id) returns the same id" do
      tenant = "default"

      {:ok, ws} =
        WsResolver.ensure_workspace(
          tenant,
          "/tmp/idempotent-sess-#{System.unique_integer([:positive])}"
        )

      {:ok, first} = ConvResolver.ensure_session(tenant, ws.id, :web_rpc, "sess-1")
      {:ok, second} = ConvResolver.ensure_session(tenant, ws.id, :web_rpc, "sess-1")

      assert first.id == second.id
      # last_active_at should advance on the second call (the only field
      # in upsert_fields besides updated_at).
      assert DateTime.compare(second.last_active_at, first.last_active_at) in [:gt, :eq]
    end

    test "preserves started_at and metadata across idempotent calls (Decision 10)" do
      tenant = "default"

      {:ok, ws} =
        WsResolver.ensure_workspace(
          tenant,
          "/tmp/preserve-sess-#{System.unique_integer([:positive])}"
        )

      first_started = ~U[2026-01-01 00:00:00.000000Z]

      {:ok, first} =
        ConvResolver.ensure_session(tenant, ws.id, :api, "sess-2",
          started_at: first_started,
          metadata: %{"first" => true}
        )

      assert first.started_at == first_started
      assert first.metadata == %{"first" => true}

      {:ok, second} =
        ConvResolver.ensure_session(tenant, ws.id, :api, "sess-2",
          started_at: DateTime.utc_now(),
          metadata: %{"second" => true}
        )

      assert second.id == first.id
      # started_at + metadata are preserved because they are NOT in upsert_fields.
      assert second.started_at == first_started
      assert second.metadata == %{"first" => true}
    end
  end
end
