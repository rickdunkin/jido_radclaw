defmodule JidoClaw.Conversations.SessionCompactionKeyingTest do
  @moduledoc """
  Atomic `metadata` writes on `JidoClaw.Conversations.Session`.

  Phase 5 spike: the per-key `jsonb_set` atomic update on
  `Session.set_compaction_snapshot/3`. Proves (a) the fragment typing is
  correct (path `::text[]`, snapshot `Jason.encode!`-ed + `::jsonb`),
  (b) two distinct keys coexist under `metadata["compactions"]`, and
  (c) concurrent distinct-key writes both survive — neither clobbers the
  other.

  Extended for code-review H12: `set_prompt_snapshot` and
  `set_current_agent_template` are also atomic single-key writes
  (`Changes.SetMetadataKey`), so a writer holding a stale record struct
  cannot clobber concurrently-written sibling keys — cross-writer
  coherence across all three metadata writers.
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Workspace

  setup do
    # Owner (non-shared) mode: every DB path here runs in the test process or
    # in `Task.async` children (which reach the owner via `$callers`), and the
    # tenant id is unique per test — no global visibility needed.
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: false)
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

  test "set_current_agent_template from a stale struct does not clobber compactions",
       %{tenant_id: t, session: session} do
    # Loaded BEFORE any compaction snapshot exists — the H12 scenario.
    {:ok, stale} = Session.by_id(session.id, tenant: t, actor: actor(t))

    {:ok, _} =
      Session.set_compaction_snapshot(session, "main::default", %{"summary" => "compacted"},
        tenant: t,
        actor: actor(t)
      )

    {:ok, _} = Session.set_current_agent_template(stale, "reviewer", tenant: t, actor: actor(t))

    {:ok, fresh} = Session.by_id(session.id, tenant: t, actor: actor(t))
    assert fresh.metadata["compactions"]["main::default"]["summary"] == "compacted"
    assert fresh.metadata["current_agent_template"] == "reviewer"
  end

  test "set_prompt_snapshot from a stale struct does not clobber compactions",
       %{tenant_id: t, session: session} do
    {:ok, stale} = Session.by_id(session.id, tenant: t, actor: actor(t))

    {:ok, _} =
      Session.set_compaction_snapshot(session, "main::default", %{"summary" => "compacted"},
        tenant: t,
        actor: actor(t)
      )

    {:ok, _} = Session.set_prompt_snapshot(stale, "snap text", tenant: t, actor: actor(t))

    {:ok, fresh} = Session.by_id(session.id, tenant: t, actor: actor(t))
    assert fresh.metadata["compactions"]["main::default"]["summary"] == "compacted"
    assert fresh.metadata["prompt_snapshot"] == "snap text"
  end

  test "nil template deletes the key without clobbering siblings",
       %{tenant_id: t, session: session} do
    {:ok, _} = Session.set_current_agent_template(session, "coder", tenant: t, actor: actor(t))

    # Stale struct: loaded before the sibling keys below are written.
    {:ok, stale} = Session.by_id(session.id, tenant: t, actor: actor(t))

    {:ok, _} =
      Session.set_compaction_snapshot(session, "main::default", %{"summary" => "kept"},
        tenant: t,
        actor: actor(t)
      )

    {:ok, _} = Session.set_prompt_snapshot(session, "kept snap", tenant: t, actor: actor(t))

    {:ok, _} = Session.set_current_agent_template(stale, nil, tenant: t, actor: actor(t))

    {:ok, fresh} = Session.by_id(session.id, tenant: t, actor: actor(t))
    refute Map.has_key?(fresh.metadata, "current_agent_template")
    assert fresh.metadata["compactions"]["main::default"]["summary"] == "kept"
    assert fresh.metadata["prompt_snapshot"] == "kept snap"
  end

  test "mixed concurrent writers all survive (cross-writer atomic proof)",
       %{tenant_id: t, session: session} do
    compaction_keys = for i <- 1..6, do: "agent_#{i}::default"
    templates = ["coder", "reviewer", "researcher"]
    snapshots = ["snap one", "snap two", "snap three"]

    writes =
      Enum.map(compaction_keys, fn key ->
        fn s ->
          Session.set_compaction_snapshot(s, key, %{"k" => key}, tenant: t, actor: actor(t))
        end
      end) ++
        Enum.map(templates, fn tpl ->
          fn s -> Session.set_current_agent_template(s, tpl, tenant: t, actor: actor(t)) end
        end) ++
        Enum.map(snapshots, fn snap ->
          fn s -> Session.set_prompt_snapshot(s, snap, tenant: t, actor: actor(t)) end
        end)

    # Preload one stale struct PER task before any task runs, so every write
    # provably starts from pre-write state — the atomicity, not a fresh
    # read, is what keeps siblings intact.
    staged =
      Enum.map(writes, fn write ->
        {:ok, s} = Session.by_id(session.id, tenant: t, actor: actor(t))
        {write, s}
      end)

    results =
      staged
      |> Enum.map(fn {write, s} -> Task.async(fn -> write.(s) end) end)
      |> Task.await_many(15_000)

    for result <- results, do: assert({:ok, _} = result)

    {:ok, fresh} = Session.by_id(session.id, tenant: t, actor: actor(t))

    # Distinct compaction subkeys: ALL must survive simultaneously.
    stored = Map.keys(fresh.metadata["compactions"])

    for key <- compaction_keys do
      assert key in stored, "expected #{key} to survive the concurrent writes"
    end

    # Single top-level keys: last-writer-wins, so assert presence and that
    # the survivor is one of the written values — not all of them.
    assert fresh.metadata["current_agent_template"] in templates
    assert fresh.metadata["prompt_snapshot"] in snapshots
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
