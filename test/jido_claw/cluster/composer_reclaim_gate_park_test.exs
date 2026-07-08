defmodule JidoClaw.Cluster.ComposerReclaimGateParkTest do
  @moduledoc """
  WS6 Phase 3, Proof 5 — composer reclaim across REAL BEAM nodes, gate-park
  variant (WS2+WS3): peer A's composer runs wave 0 (planner) and parks durably
  at the plan gate; A dies abruptly; after real lease expiry peer B reclaims
  the parent (`WorkflowRecovery.reclaim_composer/1` — the parked gate child is
  leaseless/`:awaiting_approval`, so it neither blocks `restartable?` nor
  shows up claimable), rebuilds from the log (wave 0 FOLDS, never re-runs),
  and RE-PARKS on the SAME gate case. The decision then lands ON B (decision
  broadcasts are node-local — the parked composer lives there now), releasing
  the held implementer to run on B and converge.

  Deterministic: the park is a durable DB state — no timing window, no
  blocking fixture needed (the Phase 2 deviation log predicted a releasable
  flag-row fixture for composer choreography; the gate IS the checkpoint).

  EXACTLY ONE test: it kills peer A, and peers live for the whole module.
  """

  use JidoClaw.ClusterCase,
    async: false,
    peer_overrides: [
      workflow_lease: [lease_seconds: 5, renew_seconds: 1, pending_grace_seconds: 60]
    ]

  # Local imports REPLACE the using-quote's import of the same module (last
  # directive wins), so each list carries everything this module uses.
  import JidoClaw.Cluster.PeerHarness, only: [await: 2, call: 4, call: 5, kill_peer: 1]
  import JidoClaw.Cluster.PollHelpers, only: [await_kind!: 3, await_reclaim!: 2, await_run!: 2]
  import JidoClaw.Orchestration.LeaseHelpers, only: [kinds: 2, reload_global: 1]

  alias JidoClaw.Cluster.RunFixtures
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer

  test "B reclaims a gate-parked composer: wave 0 folds, same gate re-parks, decides on B",
       ctx do
    %{node_a: node_a, node_b: node_b, peers: [peer_a, _peer_b]} = ctx

    # Stub env on BOTH peers (plain servers): per-test `put_env` on the origin
    # never reaches a peer, and B especially needs it — its post-reclaim waves
    # run StubWorker against B's node-local StubStore ETS.
    for node <- ctx.nodes do
      assert :ok =
               call(node, TestFixtures, :install_cluster_stub_env, [
                 [agent_server: StubAgentServer]
               ])
    end

    assert {:ok, parent_id} =
             call(node_a, RunFixtures, :launch_composer, [ctx.ctx, :gate_fixture], 30_000)

    # The durable mid-route state: wave 0 committed, the gate wave parked.
    await_kind!(parent_id, :wave_completed, ctx.ctx)
    await_kind!(parent_id, :wave_paused, ctx.ctx)
    await_run!(parent_id, &(&1.claimed_by == to_string(node_a) and &1.status == :running))

    # The gate `AgentCase` is opened on the gate CHILD run, not the parent —
    # read both ids from the durable `wave_paused` payload (the only channel
    # that crosses BEAMs; the `{:gate_requested, …}` broadcast is node-local).
    assert [%{"agent_case_id" => case_id, "child_run_id" => gate_child_id}] =
             wave_paused_payloads(parent_id, ctx.ctx)

    assert reload_global(gate_child_id).status == :awaiting_approval
    parked = reload_global(parent_id)

    kill_peer(peer_a)

    # The stale parent lease survived the death: no terminal, claim columns
    # exactly as A last stamped them.
    survived = reload_global(parent_id)
    assert survived.status == :running
    assert survived.claimed_by == to_string(node_a)
    assert survived.claim_token == parked.claim_token

    # Real expiry + reclaim on B — exactly one claimable row (the parent; the
    # parked gate child is `:awaiting_approval`, which `:claimable` excludes,
    # so only the PARENT lease drives reclaim timing).
    await_reclaim!(node_b, parent_id)

    # The re-park: B's rebuilt composer folds wave 0 into `ran`, re-derives
    # the gate wave, dedupe-hits the SAME parked child, and appends a second
    # `wave_paused` — for the same case and child (a duplicated gate child
    # could not hide: waves are idempotency-keyed, asserted below).
    await_run!(parent_id, &(&1.claimed_by == to_string(node_b)))

    assert :ok =
             await(fn -> match?([_, _ | _], wave_paused_payloads(parent_id, ctx.ctx)) end, 30_000)

    paused = wave_paused_payloads(parent_id, ctx.ctx)
    assert [_, _] = paused

    park_identities =
      paused
      |> Enum.map(&{&1["agent_case_id"], &1["child_run_id"]})
      |> Enum.uniq()

    assert park_identities == [{case_id, gate_child_id}]

    # Decide ON node B: `Cases.decide` broadcasts post-commit on the deciding
    # node, and the parked composer now lives on B.
    assert {:ok, _run} =
             call(
               node_b,
               Cases,
               :decide,
               [case_id, :approve, %{}, [tenant: ctx.tenant, actor: ctx.actor]],
               30_000
             )

    # The released implementer runs on B and the route converges.
    await_run!(parent_id, &(&1.status == :completed))

    # RESUME-not-RESTART, pinned on the durable log + the idempotency keys.
    final_kinds = kinds(parent_id, ctx.ctx)
    assert Enum.count(final_kinds, &(&1 == :run_started)) == 1
    assert Enum.count(final_kinds, &(&1 == :route_converged)) == 1
    refute :route_failed in final_kinds
    assert 1 == Enum.count(wave_completed_indexes(parent_id, ctx.ctx), &(&1 == 0))

    # Exactly one child per wave key (the unique idempotency identity makes
    # the `{:ok, _}` read itself the at-most-one proof): wave 0 the planner,
    # wave 1 the SAME gate child that parked on A, wave 2 the post-gate
    # implementer — completed on B, the child-level cross-node resume proof.
    assert {:ok, _planner_child} = child_at(parent_id, 0, ctx)
    assert {:ok, gate_row} = child_at(parent_id, 1, ctx)
    assert gate_row.id == gate_child_id
    assert {:ok, impl_child} = child_at(parent_id, 2, ctx)
    assert impl_child.status == :completed
    assert impl_child.claimed_by == to_string(node_b)

    assert reload_global(parent_id).claimed_by == to_string(node_b)
  end

  defp wave_paused_payloads(run_id, ctx) do
    run_id
    |> events(ctx)
    |> Enum.filter(&(&1.kind == :wave_paused))
    |> Enum.map(& &1.payload)
  end

  defp wave_completed_indexes(run_id, ctx) do
    run_id
    |> events(ctx)
    |> Enum.filter(&(&1.kind == :wave_completed))
    |> Enum.map(& &1.payload["wave_index"])
  end

  defp events(run_id, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run_id, tenant: tenant, actor: actor)
    events
  end

  defp child_at(parent_id, wave_index, ctx) do
    WorkflowRun.by_idempotency_key("composer:#{parent_id}:#{wave_index}",
      tenant: ctx.tenant,
      actor: ctx.actor
    )
  end
end
