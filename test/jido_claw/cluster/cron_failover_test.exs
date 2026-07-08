defmodule JidoClaw.Cluster.CronFailoverTest do
  @moduledoc """
  WS6 Phase 3, Proof 4 — user-cron exactly-once failover across REAL BEAM
  nodes (WS4a): the leader's `Cron.Owner` owns every user job (the follower's
  post-reconcile worker set is EMPTY — a deliberate no-op, not merely unrun);
  killing the leader hands the job to the survivor WITHOUT any test-driven
  reconcile — the automatic `leader_changed`-telemetry → reconcile path (plus
  the 30s periodic tick as documented worst-case backstop) IS the WS4a
  failover claim. Closes the IOUs at `cron/owner_test.exs` / `owner.ex`.

  Every fire is a durable node-attributed probe row
  (`JidoClaw.Cluster.CronProbeRunner` on the `:cron_workflow_runner` dispatch
  seam) under a per-fire UNIQUE key — the real `cron:<job>:<window>` key's
  unique index would dedupe cross-node and MASK a double-fire. No-double-fire
  is asserted by node-partition set arithmetic, never window grouping: each
  worker computes its `:every` window from its own clock, so two wrongly-live
  workers would fire one real interval under DIFFERENT window stamps.

  EXACTLY ONE test: it kills the leader peer, and peers live for the whole
  module.
  """

  use JidoClaw.ClusterCase,
    async: false,
    peer_overrides: [
      cron_owner: [enabled?: true],
      cron_workflow_runner: JidoClaw.Cluster.CronProbeRunner
    ]

  # Local imports REPLACE the using-quote's import of the same module (last
  # directive wins), so this list carries everything this module uses.
  import JidoClaw.Cluster.PeerHarness, only: [await: 2, call: 4, call: 5, kill_peer: 1]

  alias JidoClaw.Cluster
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Owner
  alias JidoClaw.Cron.Scheduler

  test "the leader alone fires a user job; on its death the survivor takes over, no double-fire",
       ctx do
    %{nodes: nodes, peers: peers} = ctx

    # Establish the leader (dynamically — never hardcode which peer wins).
    assert :ok =
             await(
               fn ->
                 leaders = Enum.map(nodes, &call(&1, Cluster, :leader, []))
                 Enum.all?(leaders, &(&1 != nil)) and match?([_], Enum.uniq(leaders))
               end,
               30_000
             )

    leader = call(hd(nodes), Cluster, :leader, [])
    survivor = Enum.find(nodes, &(&1 != leader))
    leader_peer = Enum.find(peers, &(&1.node == leader))
    leader_str = to_string(leader)
    survivor_str = to_string(survivor)

    # Seed a fast user job from the test node (`:every` takes ms — crontab
    # granularity is minutes). The workflow_name is inert: the probe runner
    # replaces WorkflowRunner wholesale and never resolves a skill.
    job_id = "probe-#{System.unique_integer([:positive])}"

    assert {:ok, _job} =
             Job.upsert(
               %{
                 job_id: job_id,
                 task: "cron failover probe",
                 mode: :main,
                 target: :workflow,
                 workflow_name: "cron-probe",
                 schedule_kind: :every,
                 schedule_value: "1000"
               },
               tenant: ctx.tenant,
               actor: ctx.actor
             )

    # Drive the INITIAL load explicitly on both peers: `leader_changed` never
    # fires for the initial election, and the periodic tick is 30s out.
    assert :ok = call(leader, Owner, :reconcile, [], 30_000)
    assert :ok = call(survivor, Owner, :reconcile, [], 30_000)

    # Ownership: the leader schedules the worker; the follower's empty set is
    # a post-reconcile DECISION (drop_local_user_workers ran), not inaction.
    assert Enum.any?(call(leader, Scheduler, :list_jobs, [ctx.tenant]), &(&1.id == job_id))
    assert [] == call(survivor, Scheduler, :list_jobs, [ctx.tenant])

    # The leader fires on the 1s cadence; every row is attributed to it.
    assert :ok = await(fn -> match?([_, _ | _], probe_rows(ctx)) end, 30_000)

    # Kill the leader, then snapshot: `kill_peer/1` blocks until nodedown, and
    # a halted BEAM can never commit again, so the post-nodedown read is the
    # complete leader-era population (a pre-kill read would race the last
    # fire's commit). Zero follower-attributed rows = the WS4a single-owner
    # claim held while both nodes were alive.
    kill_peer(leader_peer)
    at_kill = probe_rows(ctx)
    assert at_kill != []
    assert [] == Enum.reject(at_kill, &(&1.metadata["node"] == leader_str))

    # Failover, UNDRIVEN: election flips on the :pg leave, the Owner's
    # telemetry handler reconciles (30s periodic tick as backstop), the
    # survivor schedules the worker, and a survivor-attributed row lands.
    assert :ok = await(fn -> call(survivor, Cluster, :leader?, []) end, 30_000)

    assert :ok =
             await(
               fn ->
                 Enum.any?(
                   call(survivor, Scheduler, :list_jobs, [ctx.tenant]),
                   &(&1.id == job_id)
                 )
               end,
               45_000
             )

    assert :ok = await(fn -> ids_by_node(ctx, survivor_str) != [] end, 45_000)

    # No-double-fire, by node partition: once the survivor's first row is
    # visible, every dead-node commit (all pre-halt by definition) is long
    # visible — the leader-attributed id-set is frozen. It must not grow
    # across one more full survivor fire, and nothing may carry a third
    # attribution.
    leader_ids = ids_by_node(ctx, leader_str)
    survivor_count = length(ids_by_node(ctx, survivor_str))

    assert :ok = await(fn -> length(ids_by_node(ctx, survivor_str)) > survivor_count end, 30_000)

    assert ids_by_node(ctx, leader_str) == leader_ids

    assert [] ==
             Enum.reject(probe_rows(ctx), &(&1.metadata["node"] in [leader_str, survivor_str]))
  end

  # Every probe row for this test's tenant, read from the shared DB (the only
  # cross-BEAM evidence channel).
  defp probe_rows(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant, actor: ctx.actor)
    Enum.filter(runs, &(&1.workflow_type == "cron-probe"))
  end

  defp ids_by_node(ctx, node_str) do
    ctx
    |> probe_rows()
    |> Enum.filter(&(&1.metadata["node"] == node_str))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end
end
