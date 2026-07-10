defmodule JidoClaw.RouteComposer.ComposerTtlContractTest do
  @moduledoc """
  AR-2 Phase 2b Theme C — the TTL/deadline + marked-registration contracts:

    * C1: `create_parent_run/1` is the SOLE wall-clock read; the durable
      `config["deadline_at_ms"]` is an **integer** that survives the JSONB reload.
    * C2: a marked run MUST carry a bounded `:deadline_ms` (else rejected).
    * C4: a marked `register_child_correlation/1` ABORTS on a missing scope and
      on a durable-write failure (tuple-returning); unmarked stays infallible.
    * C5: `register_correlation/6` threads a supplied `expires_at` + the marker
      into the durable row.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.ToolContext

  describe "C1 — durable wall-clock deadline" do
    test "create_parent_run writes an integer deadline_at_ms that survives reload" do
      tenant = seed_tenant("ttl-c1")
      actor = actor_for(tenant)

      before_ms = System.os_time(:millisecond)

      {:ok, parent} =
        RouteComposer.create_parent_run(tenant: tenant, actor: actor, deadline_ms: 60_000)

      after_ms = System.os_time(:millisecond)

      {:ok, reloaded} = WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor)
      deadline_at = reloaded.config["deadline_at_ms"]

      assert is_integer(deadline_at)
      assert deadline_at >= before_ms + 60_000
      assert deadline_at <= after_ms + 60_000
    end

    test "an unbounded run carries no deadline_at_ms" do
      tenant = seed_tenant("ttl-c1-unbounded")
      actor = actor_for(tenant)

      {:ok, parent} = RouteComposer.create_parent_run(tenant: tenant, actor: actor)
      {:ok, reloaded} = WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor)

      assert reloaded.config["deadline_at_ms"] == nil
    end
  end

  describe "C2 — marked run requires a bounded deadline" do
    test "a marked run without :deadline_ms is rejected at launch" do
      tenant = seed_tenant("ttl-c2-reject")
      actor = actor_for(tenant)

      assert {:error, {:start_failed, :deadline_required_for_sensitive_run}} =
               RouteComposer.create_parent_run(
                 tenant: tenant,
                 actor: actor,
                 sanitize_sensitive_context: true
               )
    end

    test "a marked run WITH a bounded :deadline_ms is accepted" do
      tenant = seed_tenant("ttl-c2-accept")
      actor = actor_for(tenant)

      assert {:ok, %WorkflowRun{}} =
               RouteComposer.create_parent_run(
                 tenant: tenant,
                 actor: actor,
                 sanitize_sensitive_context: true,
                 deadline_ms: 60_000
               )
    end
  end

  describe "C4 — marked register_child_correlation aborts" do
    test "missing scope: marked aborts, unmarked still returns an id" do
      assert {:error, :missing_correlation_scope} =
               JidoClaw.register_child_correlation(%{sanitize_sensitive_context: true})

      assert {:ok, id} = JidoClaw.register_child_correlation(%{})
      assert is_binary(id)
    end

    test "durable-write failure: marked aborts, unmarked falls back to cache-only :ok" do
      # Deterministic seam: a session from tenant A under tenant B fails the
      # cross-tenant FK validation in `RequestCorrelation.:register`.
      %{tenant_id: _tenant_a, session: session_a} = seed_full(tenant_label: "ttl-c4-a")
      tenant_b = seed_tenant("ttl-c4-b")

      marked = %{
        session_uuid: session_a.id,
        tenant_id: tenant_b,
        sanitize_sensitive_context: true
      }

      assert {:error, _reason} = JidoClaw.register_child_correlation(marked)

      unmarked = %{session_uuid: session_a.id, tenant_id: tenant_b}
      assert {:ok, id} = JidoClaw.register_child_correlation(unmarked)
      assert is_binary(id)
    end
  end

  describe "C5 — register_correlation threads expires_at + marker" do
    test "a supplied expires_at + marker land on the durable row" do
      %{tenant_id: tenant, session: session} = seed_full(tenant_label: "ttl-c5")
      request_id = Ecto.UUID.generate()

      expires =
        DateTime.utc_now()
        |> DateTime.add(960, :second)
        |> DateTime.truncate(:microsecond)

      assert :ok =
               JidoClaw.register_correlation(request_id, session.id, tenant, nil, nil,
                 sanitize_sensitive_context: true,
                 expires_at: expires
               )

      assert {:ok, row} = RequestCorrelation.lookup(request_id, authorize?: false)
      assert row.sanitize_sensitive_context == true
      assert DateTime.compare(row.expires_at, expires) == :eq
    end
  end

  describe "P1 regression — present-nil marker coerced to false" do
    test "register_child_correlation through build/child coerces a present-nil marker" do
      # Drive the ACTUAL canonical builders (not a hand-rolled nil shape): both
      # `build/1` and `child/2` write `:sanitize_sensitive_context` present-as-nil
      # for an unmarked context, which `register_child_correlation/1` previously
      # forwarded into the `allow_nil?: false` durable field, then into
      # `register_failure/4` (true/false-only) → FunctionClauseError crash.
      %{tenant_id: tenant, session: session} = seed_full(tenant_label: "ttl-p1-nil")

      parent = ToolContext.build(%{tenant_id: tenant, session_uuid: session.id})
      ctx = ToolContext.child(parent, "child")
      # Precondition: the canonical builders really do emit a present-nil marker.
      assert ctx.sanitize_sensitive_context == nil

      assert {:ok, request_id} = JidoClaw.register_child_correlation(ctx)
      assert {:ok, row} = RequestCorrelation.lookup(request_id, authorize?: false)
      assert row.sanitize_sensitive_context == false
    end

    test "register_correlation coerces a present-nil :sanitize_sensitive_context opt" do
      # Isolates boundary 2: a direct caller passing the marker opt as nil
      # (positional-arg shape, distinct from the map-driven test above and the
      # C5 test) must still land a strict `false` on the durable row.
      %{tenant_id: tenant, session: session} = seed_full(tenant_label: "ttl-p1-nil-direct")
      request_id = Ecto.UUID.generate()

      assert :ok =
               JidoClaw.register_correlation(request_id, session.id, tenant, nil, nil,
                 sanitize_sensitive_context: nil
               )

      assert {:ok, row} = RequestCorrelation.lookup(request_id, authorize?: false)
      assert row.sanitize_sensitive_context == false
    end
  end
end
