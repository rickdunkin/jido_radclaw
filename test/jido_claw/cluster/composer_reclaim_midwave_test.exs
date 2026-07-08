defmodule JidoClaw.Cluster.ComposerReclaimMidwaveTest do
  @moduledoc """
  WS6 Phase 3, Proof 6 — composer reclaim across REAL BEAM nodes, mid-WORKER-
  wave variant (WS2+WS3): peer A's composer completes wave 0 (planner) and is
  killed while wave 1's implementer child is IN FLIGHT — held open by
  `TemplateBlockingAgentServer`, which lets the planner through and blocks
  only the `"coder"` template's request (neither existing blocker can produce
  this window: the gated one blocks wave 0's planner, the plain one blocks
  everything). Peer B then reclaims BOTH stale leases: the corpse child is
  token-rotated + failed (`reclaim_children`), the rebuilt composer folds wave
  0, dedupe-hits the failed child at its own key, and re-dispatches the wave
  under a FRESH index (`handle_wave_result` rule 2) — which B's plain stub
  completes, converging the route on B. The single-BEAM template is
  `reclaim_pooler_test.exs` "node-death: an expired corpse wave child…".

  Reclaim is driven with a tailored poll, not `await_reclaim!/2`: TWO
  claimable rows exist (parent + corpse child) and claim order is not
  guaranteed — parent-first fails the child inside `reclaim_children/3`
  (drain count 1), child-first fails it via `reconcile_one/1` and the same
  drain claims the parent next (count 2). Both orders are correct; the poll
  keys on the parent landing with B. The driving is PRE-GATED on both leases
  having expired on the DB clock: the two sidecars renew on independent 1s
  phases, so a claim landing in the sub-second window where only the parent
  has expired takes the (correct, but slow) production DEFER path — live-
  lease child ⇒ `release_on_defer` parks the parent on a `poll_interval`
  cooldown for a later poll. The gate keeps the choreography single-pass;
  the short `poll_interval_ms` override keeps any residual defer's cooldown
  inside the awaits' budget.

  EXACTLY ONE test: it kills peer A, and peers live for the whole module.
  """

  use JidoClaw.ClusterCase,
    async: false,
    peer_overrides: [
      workflow_lease: [lease_seconds: 5, renew_seconds: 1, pending_grace_seconds: 60],
      reclaim_pooler: [enabled?: false, poll_interval_ms: 500, initial_delay_ms: 0]
    ]

  # Local imports REPLACE the using-quote's import of the same module (last
  # directive wins), so each list carries everything this module uses.
  import JidoClaw.Cluster.PeerHarness, only: [await: 2, call: 4, call: 5, kill_peer: 1]

  import JidoClaw.Cluster.PollHelpers,
    only: [await_db_clock_past!: 1, await_kind!: 3, await_run!: 2]

  import JidoClaw.Orchestration.LeaseHelpers, only: [kinds: 2, reload_global: 1]

  alias JidoClaw.Cluster.RunFixtures
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.TemplateBlockingAgentServer

  test "B reclaims a mid-wave kill: corpse child fenced + failed, wave re-runs fresh on B",
       ctx do
    %{node_a: node_a, node_b: node_b, peers: [peer_a, _peer_b]} = ctx

    # Divergent stub env: A holds the coder wave in flight forever (the
    # blocked process dies with A's BEAM); B completes everything, so the
    # re-dispatched wave can converge there.
    assert :ok =
             call(node_a, TestFixtures, :install_cluster_stub_env, [
               [agent_server: TemplateBlockingAgentServer, blocked_template: "coder"]
             ])

    assert :ok =
             call(node_b, TestFixtures, :install_cluster_stub_env, [
               [agent_server: StubAgentServer]
             ])

    assert {:ok, parent_id} =
             call(node_a, RunFixtures, :launch_composer, [ctx.ctx, :linear_worker], 30_000)

    # The durable in-flight state: wave 0 folded; wave 1 started; its child
    # exists at the deterministic key, `:running` and claimed by A (the
    # blocked await holds it there indefinitely — no timing window).
    await_kind!(parent_id, :wave_completed, ctx.ctx)

    assert :ok = await(fn -> match?({:ok, _child}, child_at(parent_id, 1, ctx)) end, 20_000)
    {:ok, corpse} = child_at(parent_id, 1, ctx)
    await_run!(corpse.id, &(&1.claimed_by == to_string(node_a) and &1.status == :running))

    assert Enum.count(kinds(parent_id, ctx.ctx), &(&1 == :wave_started)) == 2
    corpse_token = reload_global(corpse.id).claim_token
    parent_before = reload_global(parent_id)

    kill_peer(peer_a)

    # BOTH leases survived the death stale — nothing released, no terminal.
    survived_parent = reload_global(parent_id)
    assert survived_parent.status == :running
    assert survived_parent.claimed_by == to_string(node_a)
    assert survived_parent.claim_token == parent_before.claim_token

    survived_child = reload_global(corpse.id)
    assert survived_child.status == :running
    assert survived_child.claimed_by == to_string(node_a)
    assert survived_child.claim_token == corpse_token

    # Pre-gate on BOTH leases having expired on the DB clock (see moduledoc:
    # claiming inside the partial-expiry window defers on the live child).
    [survived_parent.claim_expires_at, survived_child.claim_expires_at]
    |> Enum.max(DateTime)
    |> DateTime.add(1, :second)
    |> await_db_clock_past!()

    # Drive reclaim on B until the PARENT lands with B (tolerating any
    # per-pass drain count — see the moduledoc on the two claim orders).
    assert :ok =
             await(
               fn ->
                 call(node_b, ReclaimPooler, :reclaim_once, [], 30_000)
                 reload_global(parent_id).claimed_by == to_string(node_b)
               end,
               30_000
             )

    # B's rebuilt composer folds wave 0, dedupe-hits the failed corpse,
    # re-dispatches under a fresh index, and B's plain stub converges it.
    # Reclaim keeps being driven while we wait: a no-op against a healthy
    # restarted composer, and the retry that picks the parent back up should
    # a residual defer/fail-closed stop have released it for a later poll.
    assert :ok =
             await(
               fn ->
                 call(node_b, ReclaimPooler, :reclaim_once, [], 30_000)
                 reload_global(parent_id).status == :completed
               end,
               45_000
             )

    # The corpse: terminal `:failed`, token rotated (a reconnecting zombie is
    # fenced), claimed by the reclaimer. Its exact audit kinds are NOT pinned
    # — the two claim orders leave different trails.
    failed_corpse = reload_global(corpse.id)
    assert failed_corpse.status == :failed
    assert failed_corpse.claim_token != corpse_token
    assert failed_corpse.claimed_by == to_string(node_b)

    # Wave 0 ran exactly once (folded, never re-executed): one wave_started
    # and one wave_completed for index 0, one child at key :0. The re-run rode
    # a FRESH wave index — a completed child at key :2, executed on B.
    assert 1 == Enum.count(wave_indexes(parent_id, :wave_started, ctx.ctx), &(&1 == 0))
    assert 1 == Enum.count(wave_indexes(parent_id, :wave_completed, ctx.ctx), &(&1 == 0))
    assert {:ok, _planner_child} = child_at(parent_id, 0, ctx)

    assert {:ok, fresh_child} = child_at(parent_id, 2, ctx)
    assert fresh_child.status == :completed
    assert fresh_child.claimed_by == to_string(node_b)

    final_kinds = kinds(parent_id, ctx.ctx)
    assert Enum.count(final_kinds, &(&1 == :route_converged)) == 1
    refute :route_failed in final_kinds
    assert reload_global(parent_id).claimed_by == to_string(node_b)
  end

  defp wave_indexes(run_id, kind, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run_id, tenant: tenant, actor: actor)

    events
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.payload["wave_index"])
  end

  defp child_at(parent_id, wave_index, ctx) do
    WorkflowRun.by_idempotency_key("composer:#{parent_id}:#{wave_index}",
      tenant: ctx.tenant,
      actor: ctx.actor
    )
  end
end
