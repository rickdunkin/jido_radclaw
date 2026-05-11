defmodule JidoClaw.Audit.SessionStartIdempotencyTest do
  @moduledoc """
  Pins the `Session.:start` insert-only + resolver-fallback contract.

  Exactly one `:session_start` audit row exists per session, even when
  multiple callers race for the same `(tenant, workspace, kind,
  external_id)` tuple. The fallback path uses `:touch` (no audit hook),
  and the `:start` after-action only fires on insert success.
  """
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
    assert length(starts) == 1
  end

  test "concurrent first-callers still yield exactly one :session_start" do
    %{tenant_id: tenant, workspace: ws} = seed_full(tenant_label: "concurrent")

    1..50
    |> Task.async_stream(
      fn _ ->
        Resolver.ensure_session(tenant, ws.id, :web_rpc, "race-1", [])
      end,
      max_concurrency: 10
    )
    |> Stream.run()

    {:ok, sess} =
      Session.by_external(ws.id, :web_rpc, "race-1", tenant: tenant, actor: actor_for(tenant))

    {:ok, events} = Event.for_target(:session, sess.id, tenant: tenant, actor: actor_for(tenant))
    starts = Enum.filter(events, &(&1.event_kind == :session_start))
    assert length(starts) == 1
  end
end
