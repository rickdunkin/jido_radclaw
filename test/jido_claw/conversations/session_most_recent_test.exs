defmodule JidoClaw.Conversations.SessionMostRecentTest do
  @moduledoc """
  Pins the `:most_recent_for_workspace` read — the CLI `--continue` selector:
  newest OPEN session on the workspace whose kind is CLI-resumable
  (`:repl` / `:cli_run`), never a web `:api` (or any other) kind, never a
  closed row, never another workspace's row.
  """
  use JidoClaw.TenantCase, async: false

  setup do
    tenant_id = seed_tenant("most-recent")
    {:ok, ws} = seed_workspace(tenant_id)
    {:ok, tenant_id: tenant_id, ws: ws, actor: actor_for(tenant_id)}
  end

  test "returns the newest open CLI-resumable session; touch re-orders", ctx do
    {:ok, older} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)
    {:ok, newer} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :cli_run)

    assert {:ok, found} =
             Session.most_recent_for_workspace(ctx.ws.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )

    assert found.id == newer.id

    # Touching the older session bumps its last_active_at past the newer one.
    {:ok, _} = Session.touch(older, tenant: ctx.tenant_id, actor: ctx.actor)

    assert {:ok, refound} =
             Session.most_recent_for_workspace(ctx.ws.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )

    assert refound.id == older.id
  end

  test "closed sessions are skipped", ctx do
    {:ok, older} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)
    {:ok, newest} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)
    {:ok, _} = Session.close(newest, tenant: ctx.tenant_id, actor: ctx.actor)

    assert {:ok, found} =
             Session.most_recent_for_workspace(ctx.ws.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )

    assert found.id == older.id
  end

  test "non-CLI kinds (e.g. web :api) are never selected", ctx do
    {:ok, repl} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)
    {:ok, _api_newer} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :api)

    assert {:ok, found} =
             Session.most_recent_for_workspace(ctx.ws.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )

    assert found.id == repl.id
  end

  test "sessions from another workspace are excluded", ctx do
    {:ok, other_ws} = seed_workspace(ctx.tenant_id)
    {:ok, _other} = seed_session(ctx.tenant_id, other_ws.id, kind: :repl)
    {:ok, mine} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)

    assert {:ok, found} =
             Session.most_recent_for_workspace(ctx.ws.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )

    assert found.id == mine.id
  end

  test "sessions from another tenant are invisible", ctx do
    other_tenant = seed_tenant("most-recent-other")
    {:ok, _mine} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)

    assert {:error, _} =
             Session.most_recent_for_workspace(ctx.ws.id,
               tenant: other_tenant,
               actor: actor_for(other_tenant)
             )
  end

  test "empty workspace yields a not-found error", ctx do
    assert {:error, _} =
             Session.most_recent_for_workspace(ctx.ws.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )
  end
end
