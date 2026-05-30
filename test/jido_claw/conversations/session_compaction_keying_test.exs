defmodule JidoClaw.Conversations.SessionCompactionKeyingTest do
  @moduledoc """
  Phase 5 spike: the per-key `jsonb_set` atomic update on
  `Session.set_compaction_snapshot/3`.

  Proves (a) the fragment typing is correct (path `::text[]`, snapshot
  `Jason.encode!`-ed + `::jsonb`), (b) two distinct keys coexist under
  `metadata["compactions"]`, and (c) concurrent distinct-key writes both
  survive — neither clobbers the other.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Workspace

  setup do
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    seed()
  end

  test "two keys coexist under metadata['compactions']", %{tenant_id: t, session: session} do
    {:ok, _} =
      Session.set_compaction_snapshot(session, "main::default", %{"summary" => "main one"},
        tenant: t,
        actor: actor(t)
      )

    {:ok, _} =
      Session.set_compaction_snapshot(session, "coder_1::default", %{"summary" => "coder one"},
        tenant: t,
        actor: actor(t)
      )

    {:ok, fresh} = Session.by_id(session.id, tenant: t, actor: actor(t))
    compactions = fresh.metadata["compactions"]

    assert compactions["main::default"]["summary"] == "main one"
    assert compactions["coder_1::default"]["summary"] == "coder one"
  end

  test "re-writing one key leaves the other intact", %{tenant_id: t, session: session} do
    {:ok, _} =
      Session.set_compaction_snapshot(session, "main::default", %{"v" => 1},
        tenant: t,
        actor: actor(t)
      )

    {:ok, _} =
      Session.set_compaction_snapshot(session, "coder_1::default", %{"v" => 9},
        tenant: t,
        actor: actor(t)
      )

    # Overwrite main only.
    {:ok, _} =
      Session.set_compaction_snapshot(session, "main::default", %{"v" => 2},
        tenant: t,
        actor: actor(t)
      )

    {:ok, fresh} = Session.by_id(session.id, tenant: t, actor: actor(t))
    assert fresh.metadata["compactions"]["main::default"]["v"] == 2
    assert fresh.metadata["compactions"]["coder_1::default"]["v"] == 9
  end

  test "concurrent distinct-key writes both survive (atomic proof)",
       %{tenant_id: t, session: session} do
    keys = for i <- 1..12, do: "agent_#{i}::default"

    keys
    |> Enum.map(fn key ->
      Task.async(fn ->
        # Each task fetches its own session struct (the update is atomic on
        # the row, so a stale base struct can't clobber a sibling key).
        {:ok, s} = Session.by_id(session.id, tenant: t, actor: actor(t))

        Session.set_compaction_snapshot(s, key, %{"k" => key}, tenant: t, actor: actor(t))
      end)
    end)
    |> Task.await_many(15_000)

    {:ok, fresh} = Session.by_id(session.id, tenant: t, actor: actor(t))
    stored = Map.keys(fresh.metadata["compactions"])

    for key <- keys do
      assert key in stored, "expected #{key} to survive the concurrent writes"
    end
  end

  defp seed do
    tenant_id = "tenant-keying-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.ensure(tenant_id)
    a = actor(tenant_id)

    {:ok, ws} =
      Workspace.register(
        %{path: "/tmp/keying-#{System.unique_integer([:positive])}", name: "keying"},
        tenant: tenant_id,
        actor: a
      )

    {:ok, session} =
      Session.start(
        %{
          workspace_id: ws.id,
          kind: :api,
          external_id: "ext-keying-#{System.unique_integer([:positive])}",
          started_at: DateTime.utc_now()
        },
        tenant: tenant_id,
        actor: a
      )

    {:ok, tenant_id: tenant_id, session: session}
  end

  defp actor(tenant_id), do: %{user_id: tenant_id, tenant_id: tenant_id}
end
