defmodule JidoClaw.Cluster.GatedResumeAcrossNodesTest do
  @moduledoc """
  WS6 Phase 2, Proof C — gated resume across REAL BEAM nodes (WS3): a gated
  run checkpoints on peer A; A is killed abruptly; the approval is recorded
  commit-only from the test node (operators decide from any node); peer B
  reclaims, decrypts A's checkpoint via `GateResume` (identical Vault cipher
  rides the env snapshot), and re-runs the downstream Ash create to
  completion — B resumes a checkpoint whose author BEAM no longer exists.

  Closes the `human_gates_test.exs` IOU: "a same-VM round-trip does not prove
  cross-boot atom/module availability … a separate-BEAM resume is a
  follow-up".

  EXACTLY ONE test: it kills peer A, and peers live for the whole module.
  """

  use JidoClaw.ClusterCase,
    async: false,
    peer_overrides: [
      workflow_lease: [lease_seconds: 5, renew_seconds: 1, pending_grace_seconds: 60]
    ]

  # Local imports REPLACE the using-quote's import of the same module (last
  # directive wins), so each list carries everything this module uses.
  import JidoClaw.Cluster.PeerHarness, only: [call: 5, kill_peer: 1]
  import JidoClaw.Cluster.PollHelpers, only: [await_reclaim!: 2, await_run!: 2]
  import JidoClaw.Orchestration.LeaseHelpers, only: [kinds: 2, reload_global: 1]

  alias JidoClaw.Cluster.RunFixtures
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Workspaces.Workspace

  test "peer B resumes a checkpoint whose author BEAM is dead, to completion", ctx do
    %{node_a: node_a, node_b: node_b, peers: [peer_a, _peer_b]} = ctx

    assert {:ok, %{run_id: run_id, case_id: case_id, workspace_path: ws_path}} =
             call(node_a, RunFixtures, :launch_gated, [ctx.ctx], 30_000)

    # The durable park: encrypted checkpoint persisted, gate case open, and
    # :awaiting_approval — unclaimable by any reclaim in the meantime. The
    # executor ended at the halt, so A's lease stopped renewing at park and
    # expires ~lease_seconds later on the DB clock.
    parked = reload_global(run_id)
    assert parked.status == :awaiting_approval
    assert is_binary(parked.encrypted_resume_checkpoint)
    assert :approval_requested in kinds(run_id, ctx.ctx)

    # The checkpoint's author BEAM is dead before any decision lands
    # (mechanically inert — A holds no executor post-park — but it makes the
    # headline exact).
    kill_peer(peer_a)

    # Record the decision from the test node, commit-only for reactor resume
    # (`resume: false` skips GateResume; the gate hook + broadcast still
    # dispatch post-commit on the deciding node — harmless here, just not
    # side-effect-free): approval_resolved appended, status → :running,
    # checkpoint RETAINED — the exact input to reclaim's decision-recorded
    # branch.
    assert {:ok, _run} =
             Cases.decide(case_id, :approve, %{},
               resume: false,
               tenant: ctx.tenant,
               actor: ctx.actor
             )

    decided = reload_global(run_id)
    assert decided.status == :running
    assert is_binary(decided.encrypted_resume_checkpoint)
    assert :approval_resolved in kinds(run_id, ctx.ctx)

    # B reclaims after real expiry: recovery classifies decision-recorded and
    # runs GateResume.resume(recovered: true) — decrypts A's checkpoint,
    # re-arms the lease middleware (fresh token, 1s-renewing sidecar), and
    # re-runs the downstream Ash create ON B.
    await_reclaim!(node_b, run_id)
    await_run!(run_id, &(&1.status == :completed))

    # The cross-BEAM resume, pinned: checkpoint cleared, exactly one resume
    # and one terminal (the no-rerun proof), B holds the claim.
    completed = reload_global(run_id)
    assert is_nil(completed.encrypted_resume_checkpoint)
    assert completed.claimed_by == to_string(node_b)

    final_kinds = kinds(run_id, ctx.ctx)
    assert Enum.count(final_kinds, &(&1 == :run_resumed)) == 1
    assert Enum.count(final_kinds, &(&1 == :run_completed)) == 1
    refute :run_failed in final_kinds

    # The irreversible downstream write LANDED, asserted by the resource's
    # real tenant/path identity (at-most-one row) from the test node on the
    # shared DB.
    assert {:ok, %Workspace{}} =
             Workspace.by_path(nil, ws_path, tenant: ctx.tenant, actor: ctx.actor)
  end
end
