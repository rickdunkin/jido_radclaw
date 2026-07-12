defmodule JidoClaw.Audit.SessionStartIdempotencyTest do
  @moduledoc """
  Pins the `Session.:start` insert-only + resolver-fallback contract.

  Exactly one `:session_start` audit row exists per session, even when
  multiple callers race for the same `(tenant, workspace, kind,
  external_id)` tuple. The fallback path uses `:touch` (no audit hook),
  and the `:start` after-action only fires on insert success.
  """
  # Deliberately sync: the concurrent test below fans 5 tasks over this
  # test's ONE shared sandbox connection, and inside the async cohort of a
  # partitioned run the CPU contention inflated per-transaction time enough
  # that queued waiters outlived DBConnection's default drop horizon
  # (~200ms) — two consecutive precommit runs dropped a waiter mid-test
  # while the file passed isolated. Serial scheduling bounds the queue
  # tail; the interleaving under test survives (see the comment in the
  # concurrent test).
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit.Event
  alias JidoClaw.Conversations.Resolver
  alias JidoClaw.Conversations.Session

  test "exactly one :session_start audit per session, idempotent reuse" do
    %{tenant_id: tenant, workspace: ws} = seed_full(tenant_label: "idempotency")

    {:ok, sess1} = Resolver.ensure_session(tenant, ws.id, :web_rpc, "sess-1", [])
    {:ok, sess2} = Resolver.ensure_session(tenant, ws.id, :web_rpc, "sess-1", [])

    assert sess1.id == sess2.id

    {:ok, events} = Event.for_target(:session, sess1.id, tenant: tenant, actor: actor_for(tenant))
    starts = Enum.filter(events, &(&1.event_kind == :session_start))
    assert [_] = starts
  end

  test "concurrent first-callers still yield exactly one :session_start" do
    %{tenant_id: tenant, workspace: ws} = seed_full(tenant_label: "concurrent")

    # All tasks share this test's one sandbox connection (shared mode), so
    # DB calls serialize regardless of concurrency — the contested
    # read-miss → insert vs unique-violation → :touch interleaving needs
    # only >= 2 overlapping callers. Depth 5 keeps the first wave contested
    # while bounding the per-operation queue on the shared connection
    # (depth 10 in the async cohort hit DBConnection's queue-drop horizon
    # under partitioned saturation; see the module comment).
    results =
      1..50
      |> Task.async_stream(
        fn _ ->
          Resolver.ensure_session(tenant, ws.id, :web_rpc, "race-1", [])
        end,
        max_concurrency: 5,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # Every attempt must actually complete (insert winner or :touch
    # fallback) — otherwise "exactly one :session_start" could pass
    # vacuously with most attempts never reaching the resolver.
    assert Enum.all?(results, &match?({:ok, _}, &1))

    {:ok, sess} =
      Session.by_external(ws.id, :web_rpc, "race-1", tenant: tenant, actor: actor_for(tenant))

    {:ok, events} = Event.for_target(:session, sess.id, tenant: tenant, actor: actor_for(tenant))
    starts = Enum.filter(events, &(&1.event_kind == :session_start))
    assert [_] = starts
  end
end
