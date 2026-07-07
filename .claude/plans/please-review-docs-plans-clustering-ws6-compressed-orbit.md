# WS6 Phase 2 — lease lifecycle proofs (kill + expiry machinery)

## Context

WS6 (`docs/plans/clustering/WS6-testing-and-ops.md`) closes the clustering
program. Phase 1 shipped the `:peer` multi-node harness proven by the fence
race (commit `9e485107`) — but no peer has ever actually *executed* a run
(the fence race is decided at claim time). Phase 2 adds the machinery the
harness deliberately deferred — **abrupt node kills, real short lease windows
pushed to peers, and DB-polling helpers** — and produces the lease-lifecycle
proofs across real BEAM nodes:

- **Proof A — reclaim across nodes** (WS1+WS3): peer A launches a run and is
  mid-step; kill A abruptly; the stale lease row survives; after **real**
  lease expiry peer B reclaims and disposes it per shipped WS3 semantics.
- **Proof B — stale-fence halt across nodes** (WS1): peer B is actively
  executing; its fence token is rotated out from under it; B's sidecar's next
  **real** renew sees 0 rows and kills the executor with **no terminal**; a
  follow-up reclaim on peer A writes the single terminal.
- **Proof C — gated resume across nodes** (WS3, operator-added scope): a gated
  run checkpoints on peer A; A is killed; approval is recorded commit-only;
  peer B reclaims, decrypts A's checkpoint via `GateResume`, and re-runs the
  downstream to completion cross-BEAM. Closes the `human_gates_test.exs:355`
  IOU ("A separate-BEAM resume is a follow-up").

Operator decisions taken at plan review:

1. **Proof A asserts fail-with-audit** — shipped WS3 never re-executes a plain
   reactor on reclaim: it terminalizes `:failed` with the `run_recovered` +
   `run_failed` audit pair (boot-parity Q1, `workflow_recovery.ex:186-198`).
   True resume is proven by Proof C now and the composer proof in Phase 3.
2. **Proof C added** as extra Phase 2 scope.
3. **Reclaim is driven**: tests erpc-call `ReclaimPooler.reclaim_once/0` on the
   reclaiming peer in an await loop (fence-race precedent), not via arming the
   pooler's live loop.

No production (`lib/`) changes: everything lands in `test/support/`,
`test/jido_claw/cluster/`, plus doc/comment updates — so no `docs/system/`,
`JIDO.md`, or `system_prompt.md` churn.

## Verified mechanics the design rests on

- **Lease knobs are read at call time** via
  `Application.get_env(:jido_claw, :workflow_lease, [])`
  (`workflow_lease.ex:129-131`): `lease_seconds` (60), `renew_seconds` (15;
  test.exs parks it at 86_400), `pending_grace_seconds` (defaults to
  `lease_seconds`). Peer boot overrides are **whole-key replace**
  (`peer_harness.ex:128-130`) — an override must set all three keys.
- **Peers inherit the origin's full app env** (snapshot push,
  `peer_harness.ex:268-272`) — including `reclaim_pooler [enabled?: false]`
  and `workflow_recovery [enabled?: false]`; boot recovery additionally
  self-disables under `cluster_enabled: true` (`workflow_recovery.ex:780-784`).
  **Nothing reclaims except our explicit `reclaim_once` calls** — the pooler's
  `enabled?` gate only stops the GenServer loop (`reclaim_pooler.ex:59-67`);
  `reclaim_once/0` is a stateless function returning the drained **count**.
- **`:peer.stop/1` is abrupt for these peers** (OTP 29): default shutdown is
  `{halt, 5000}`, and with `connection: :standard_io` its `terminate/2`
  **closes the stdio control port**, upon which the peer **self-halts via
  `erlang:halt()`** — no `Application.stop`, nothing releases the lease —
  then blocks until real `nodedown` (peer.erl:405-416, 762-764). Invariant to
  document on `kill_peer/1`: this holds **because `peer_start_options/2` sets
  no `:shutdown` option**; adding a graceful one later would break the
  stale-lease premise (proof A's assertion would catch it loudly).
- **`ExUnit.CaseTemplate` threading**: `using opts do` receives use-site opts,
  and the proxy forwards only `ExUnit.Case.__keys__(opts)`
  (`[:async, :group, :parameterize, :register]`) to ExUnit.Case
  (case_template.ex:88-94) — a custom `peer_overrides:` opt triggers no
  unknown-option warning.
- **Elixir 1.20 warns per `{name, arity}` on unused `only:` imports**
  (verified empirically) — new helpers must be imported locally by the modules
  that use them, never added to the shared `using` quote (fence_race would
  warn; the Phase 1 Deviations entry documents this exact trap class).
- `ctx` crosses `:erpc` losslessly: `TenantCase.seed_tenant/1` returns a
  **string** tenant id and `actor_for/1` a plain map — no structs involved.
- `BlockingTestReactor`'s `BlockStep` sends `{:blocking_step_started, self(),
  run_id}` to `context[:test_pid]` **after** `ReactorMiddleware` has
  synchronously appended `step_started` — so once observed, the mid-execution
  state is already durable in `workflow_events`.
- **Gate park leaves the lease columns untouched** (no `suspend_claim` callers
  on the halt path; `finalize({:halted, _})` → `handle_gate_pause` only writes
  the checkpoint) and `:awaiting_approval` is **not claimable**
  (`workflow_run.ex:262`). After the park the sidecar is gone (executor ended)
  so the lease stops renewing and expires ~`lease_seconds` later.
- `Cases.decide(case_id, :approve, %{}, resume: false, tenant:, actor:)` is
  the production seam that is **commit-only for reactor resume** — it skips
  `GateResume`, though the gate hook + broadcast still dispatch post-commit
  (`human_gates_test.exs:191-212`, `cases.ex:431`):
  `approval_resolved` appended, status → `:running`, checkpoint retained — the
  exact input to reclaim's decision-recorded branch
  (`workflow_recovery.ex:275-283, 741-750` → `GateResume.resume(recovered: true)`).
  During B's resume the re-armed middleware stamps a fresh token and starts a
  sidecar renewing every `renew_seconds` — the resume is not racing its own
  5s lease.
- `RunExecution.lookup/1` → `{:ok, pid, tenant_id}` | `:error`
  (`run_execution.ex:141-146`) — the executor-gone probe.
- **Nothing clears the claim columns on terminal** (fence B only *reads*
  `claim_token`) — post-terminal `claimed_by == to_string(reclaimer_node)`
  assertions are stable.
- `reclaim_once`-driven expiry **defers to the DB clock**: the `:claimable`
  read filters `fragment("? < now()", claim_expires_at)` — the await loop
  re-asks the DB each iteration; no app-vs-DB clock skew, no sleeps.

## Design decisions (deltas from the WS6 doc's sketch, all to record in its Deviations log)

1. *(forced: one sensible path)* **No new flag-row `BlockingStep` reactor.**
   The doc sketches "a BlockingStep fixture that waits on a flag row"; the
   existing `BlockingTestReactor` (sleep-infinity) + polling the **durable
   `step_started` event** already gives the deterministic no-sleep
   mid-execution window, and **no Phase 2 proof ever releases the step** (all
   end via node death, fence-kill, or a gate park). Build the releasable
   flag-row fixture when a proof actually needs graceful release (Phase 3
   composer choreography, likely).
2. *(operator-decided)* Proof A asserts the fail-with-audit disposition (see
   Context).
3. *(operator-decided)* Proof C (gated resume) added beyond the doc's two
   proofs.
4. *(forced)* Proof B's "force-reclaim" is staged as `rotate_token!` (the
   documented reclaimer-steal seed) + a follow-up real `reclaim_once` on the
   other peer — racing a genuine claim against a healthy 1s renew cadence is
   inherently flaky; the production sequence (rotate → fence → reclaim
   disposition) is preserved end-to-end.
5. `kill_peer/1` rides `:peer.stop/1` (proven abrupt, supported API, already
   blocks for nodedown) rather than an erpc `:erlang.halt`.

**Shared timing config** for all three proof modules — renew cadence
comfortably inside the lease window; real expiry lands well inside a 30s
await; at any kill instant the lease has ≥4s left, so the stale-lease read is
robust under CI load:

```elixir
peer_overrides: [
  workflow_lease: [lease_seconds: 5, renew_seconds: 1, pending_grace_seconds: 60]
]
```

(`pending_grace_seconds` is not load-bearing — every proof reclaims a
*claimed* run via the expired-lease clause — but whole-key replace forces
setting it; 60 keeps fresh `:pending` rows unclaimable by accident.
Fence-latency note: `fence_decision`'s `@retry_ms 2000` back-off applies only
to `{:error, _}` renews; a rotation is a clean `{:ok, 0}` → immediate kill,
so proof B's fence lands within ~1 renew tick.)

## Implementation (in order)

### 1. `test/support/jido_claw/cluster/peer_harness.ex` — add `kill_peer/1`

```elixir
@doc """
Abrupt kill of one peer — closes the `:peer` stdio control channel, which
makes the peer self-halt via `erlang:halt/0` (no `Application.stop`, so a held
lease is left STALE for reclaim; abrupt BECAUSE `peer_start_options/2` sets no
graceful `:shutdown` option). Blocks until nodedown. Idempotent with
`stop_peers/1`.
"""
@spec kill_peer(peer()) :: :ok
def kill_peer(%{server: server, node: node}) do
  try do
    :peer.stop(server)
  catch
    _kind, _reason -> :ok
  end

  case await(fn -> node not in Node.list() end, 10_000) do
    :ok -> :ok
    {:error, :timeout} -> raise "peer #{node} still connected after kill"
  end
end
```

Two-arg `catch` mirrors `stop_peers/1` (no bare `rescue` — reach gate).

### 2. `test/support/jido_claw/cluster_case.ex` — thread `peer_overrides`

Move the peer boot from the template body into the `using` quote so use-site
opts reach it; **shared imports stay exactly as today** (per-arity
unused-import trap):

```elixir
using opts do
  overrides = Keyword.get(opts, :peer_overrides, [])

  quote do
    # imports / aliases / @moduletags exactly as today — no additions

    setup_all do
      JidoClaw.ClusterCase.boot_peers!(unquote(Macro.escape(overrides)))
    end
  end
end

@spec boot_peers!(keyword()) :: map()
def boot_peers!(overrides) do
  ensure_cluster_env!()
  PeerHarness.ensure_distribution!()
  peers = PeerHarness.start_peers(2, overrides: overrides)
  on_exit(fn -> PeerHarness.stop_peers(peers) end)
  [node_a, node_b] = nodes = Enum.map(peers, & &1.node)
  %{peers: peers, nodes: nodes, node_a: node_a, node_b: node_b}
end
```

Delete the template-body `setup_all` (the proxy-injected empty chain is a
harmless passthrough); keep the per-test `setup` (truncate + tenant) in the
template body; `ensure_cluster_env!` stays private (called from `boot_peers!`).
Behavior-preserving for `fence_race_test` (no opts ⇒ `[]` ⇒
`start_peers(2, overrides: [])`, a no-op merge). `on_exit` from a helper
invoked inside `setup_all` is the `LeaseHelpers.launch_blocking/1` precedent.
Verify `fence_race_test` still passes after this edit.

### 3. `test/support/jido_claw/cluster/run_fixtures.ex` — `JidoClaw.Cluster.RunFixtures` (new)

Peer-side launchers invoked via `call/5` as **named MFAs** (never ship funs
across nodes). On the peer code path automatically (`elixirc_paths(:test)`
includes `test/support`; peers get origin code paths).

```elixir
@spec launch_blocking(%{tenant: String.t(), actor: map()}) ::
        {:ok, String.t()} | {:error, :timeout}
def launch_blocking(%{tenant: tenant, actor: actor}) do
  parent = self()

  spawn(fn ->
    ReactorRunner.run(BlockingTestReactor, %{},
      tenant: tenant, actor: actor, context: %{test_pid: parent})
  end)

  receive do
    {:blocking_step_started, _executor, run_id} -> {:ok, run_id}
  after
    30_000 -> {:error, :timeout}
  end
end

@spec launch_gated(%{tenant: String.t(), actor: map()}) ::
        {:ok,
         %{run_id: String.t(), case_id: String.t(), workspace_name: String.t(),
           workspace_path: String.t()}}
        | {:error, term()}
def launch_gated(%{tenant: tenant, actor: actor}) do
  name = "gated-#{System.unique_integer([:positive])}"
  path = Path.join(System.tmp_dir!(), name)

  case ReactorRunner.run(GatedTestReactor, %{workspace_name: name, workspace_path: path},
         tenant: tenant, actor: actor) do
    {:ok, {:paused, case_id}, run} ->
      {:ok, %{run_id: run.id, case_id: case_id, workspace_name: name, workspace_path: path}}

    other ->
      {:error, other}
  end
end
```

Key points: `spawn/1` **unlinked** so the launcher survives the erpc process
exiting; plain `receive`, **not** `assert_receive` (no ExUnit on peers);
`launch_gated` is synchronous (the park returns promptly) and returns a
**map** — Proof C needs `workspace_path` later, and a map avoids tuple drift.
`@spec` + `alias` everything (credo strict).

### 4. `test/support/jido_claw/cluster/poll_helpers.ex` — `JidoClaw.Cluster.PollHelpers` (new)

Test-node DB-poll composables on `PeerHarness.await/2`; flunk on timeout
**including the last-seen state** for diagnosable failures. **Not** imported
by the `using` block — proof modules import locally.

```elixir
@spec await_run!(String.t(), (WorkflowRun.t() -> boolean()), timeout()) :: :ok
def await_run!(run_id, pred, timeout \\ 20_000)
# polls pred.(LeaseHelpers.reload_global(run_id)); flunks with the final row

@spec await_kind!(String.t(), atom(), map(), timeout()) :: :ok
def await_kind!(run_id, kind, ctx, timeout \\ 20_000)
# polls kind in LeaseHelpers.kinds(run_id, ctx); flunks with the kinds seen

@spec await_executor_gone!(node(), String.t(), timeout()) :: :ok
def await_executor_gone!(node, run_id, timeout \\ 15_000)
# polls PeerHarness.call(node, RunExecution, :lookup, [run_id]) == :error

@spec await_reclaim!(node(), String.t(), timeout()) :: :ok
def await_reclaim!(node, run_id, timeout \\ 30_000)
# polls PeerHarness.call(node, ReclaimPooler, :reclaim_once, []) until it
# returns EXACTLY 1 (0 before real lease expiry). A count > 1 flunks
# immediately — a stray claimable row contaminated the test (>= would hide
# it). On timeout, flunks with the run's last reloaded row so a non-expired
# lease is diagnosable from the failure message.
```

### 5. `test/jido_claw/cluster/stale_fence_halt_test.exs` — Proof B (build first: cross-node lift of the proven `reclaim_pooler_test.exs:156-174`)

`use JidoClaw.ClusterCase, async: false, peer_overrides: <shared config>`;
local imports: `PollHelpers`, `RunFixtures`, and
`import JidoClaw.Orchestration.LeaseHelpers, only: [rotate_token!: 2, expire_claim!: 1]`.

1. `{:ok, run_id} = call(node_b, RunFixtures, :launch_blocking, [ctx.ctx], 30_000)`.
2. `await_run!(run_id, &(&1.claimed_by == to_string(node_b) and &1.status == :running))`.
3. `stolen = Ecto.UUID.generate(); rotate_token!(run_id, stolen)` — the
   deterministic reclaimer-steal (design decision 4).
4. `await_executor_gone!(node_b, run_id)` — B's next **real** renew (≤1s)
   returns `{:ok, 0}` → sidecar kills the executor.
5. Assert **no terminal from B** (fence A): status still `:running`; kinds
   contain neither `:run_failed` nor `:run_completed`.
6. `expire_claim!(run_id)` (keeps `claimed_by` = B and the stolen token), then
   `assert 1 == call(node_a, ReclaimPooler, :reclaim_once, [], 30_000)`.
7. Assert exactly one terminal total: status `:failed`;
   `kinds(run_id, ctx.ctx) == [:run_started, :step_started, :run_recovered, :run_failed]`;
   `claimed_by == to_string(node_a)`. (The reclaim's kill-cast to live,
   connected B routes `{:remote, node_b}` — delivered but unobservable here
   since B's executor is already dead; asserting a cross-node kill of a
   *live* executor is Phase 3's cancel proof. Don't over-scope.)
8. `on_exit` hardening: best-effort `call(node_x, RunExecution, :kill_local, [run_id, tenant])`
   on surviving nodes — neutralizes a leaked blocking executor if a
   fence/kill ever fails to fire (truncation clears rows, not processes).

### 6. `test/jido_claw/cluster/reclaim_across_nodes_test.exs` — Proof A (**exactly one test** — it kills peer A, and peers are per-module)

Same `use` + local imports (adds `import ...PeerHarness, only: [kill_peer: 1]`).

1. `{:ok, run_id} = call(node_a, RunFixtures, :launch_blocking, [ctx.ctx], 30_000)`.
2. `await_run!(run_id, &(&1.claimed_by == to_string(node_a) and &1.status == :running))`;
   `stamped = reload_global(run_id)` (capture A's token).
3. `kill_peer(peer_a)` (from `ctx.peers`).
4. **Stale lease survived the death** (the WS6 doc's explicit requirement):
   reload — `status == :running` (no terminal was written — the real proof of
   abruptness), `claimed_by == to_string(node_a)`, `claim_token` unchanged;
   soft secondary: `claim_expires_at` still in the future.
5. Real expiry + reclaim on B: `await_reclaim!(node_b, run_id)` — exactly-one
   count, flunks with the last row state on timeout.
6. Assert the WS3 disposition: status `:failed`;
   `kinds == [:run_started, :step_started, :run_recovered, :run_failed]`
   (exactly one terminal, exactly one `:step_started` — nothing re-executed);
   `claimed_by == to_string(node_b)`. Kill-cast to the dead prior owner
   resolves `:unroutable` (no-op; expect a peer-side warning log at most).
7. Same `on_exit` kill_local hardening (surviving node only).

### 7. `test/jido_claw/cluster/gated_resume_across_nodes_test.exs` — Proof C (one test; kills peer A)

Same `use` + local imports (`kill_peer`, `PollHelpers`, `RunFixtures`; alias
`JidoClaw.Orchestration.Cases`, `JidoClaw.Workspaces.Workspace`).

1. `{:ok, %{run_id: run_id, case_id: case_id, workspace_path: ws_path}} = call(node_a, RunFixtures, :launch_gated, [ctx.ctx], 30_000)`.
   Assert the durable park: `status == :awaiting_approval`,
   `encrypted_resume_checkpoint` is a binary, `:approval_requested` in kinds.
2. `kill_peer(peer_a)` — the checkpoint's author BEAM is dead before any
   decision lands (mechanically inert — A holds no executor post-park — but it
   makes the headline exact: *B resumes a checkpoint whose author no longer
   exists*, and the run's `:awaiting_approval` status is untouchable by
   reclaim in the meantime).
3. Record the decision from the **test node** (operators decide from any
   node), **commit-only for reactor resume** — `resume: false` skips
   `GateResume`, but the gate's `after_approved` hook + broadcast still
   dispatch post-commit on the deciding node (`cases.ex:431`); harmless here,
   just not side-effect-free:
   `assert {:ok, _} = Cases.decide(case_id, :approve, %{}, resume: false, tenant: ctx.tenant, actor: ctx.actor)`
   → `approval_resolved` appended, status `:running`, checkpoint retained.
4. B reclaims after real expiry (A's last stamp is already ≤5s from death):
   `await_reclaim!(node_b, run_id)` — exactly-one count with last-row-state
   diagnostics, so a non-expired parked lease or a stray claimable row
   surfaces instead of hiding behind `>=`. Inside that call B's recovery
   classifies decision-recorded and runs `GateResume.resume(recovered: true)`:
   decrypts the checkpoint (identical Vault cipher via the env snapshot —
   verified: `config :jido_claw, JidoClaw.Security.Vault` rides
   `push_config/0`), re-arms the lease middleware, re-runs the downstream Ash
   create **on B**.
5. Assert the cross-BEAM resume: `await_run!(run_id, &(&1.status == :completed))`;
   checkpoint cleared (nil); kinds contain `:run_resumed` and exactly one
   terminal `:run_completed`, no `:run_failed`; `claimed_by == to_string(node_b)`;
   and the irreversible downstream write **landed**, asserted by the
   resource's real identity (tenant/path, `workspace.ex:245`):
   `assert {:ok, %Workspace{}} = Workspace.by_path(nil, ws_path, tenant: ctx.tenant, actor: ctx.actor)`
   from the test node on the shared DB. (The tenant/path DB identity enforces
   at-most-one row; the *no-rerun* proof proper is the event-count assertions
   above — one `:run_resumed`, one terminal.)
6. Update the stale IOU comment at `human_gates_test.exs:353-355` to point at
   this test.

### 8. Docs — `docs/plans/clustering/WS6-testing-and-ops.md`

Add a `### Phase 2` block under `## Deviations` as entries land; the five
pre-known entries are the Design decisions above (each marked
operator-decided vs forced).

## Precommit trap checklist (all new/edited files)

- `@moduledoc` everywhere; `@spec` on every public `test/support` function
  (house style; credo strict `Readability.Specs`).
- Zero warnings (`compile_check` allowlist empty; it compiles `lib` +
  `test/support` under the test run): no unused aliases/imports/vars; `only:`
  imports are tracked **per name/arity** — import locally per proof module.
- reach smells: no bare `rescue` (two-arg `catch` precedent); no interpolated
  `Repo.query` (none needed now that the flag-row reactor is dropped).
- ExSlop EXS3004: no comment line may start with the word "step" — watch
  wrapped comments near the reactor fixtures.
- `mise exec -- mix format` before finishing.

## Verification

1. **Cluster suite** — each new module in isolation while iterating, then the
   full suite:
   `JIDOCLAW_CLUSTER_TEST=1 mise exec -- mix test --only cluster test/jido_claw/cluster/<file>`
   and `mise exec -- scripts/test-cluster.sh`. Re-run the full suite **3×**
   for flake confidence (timing-sensitive `async: false` suite —
   `[[project_suite_flaky_tests]]`: verify in isolation).
2. **`mise exec -- mix precommit`** — must pass (the completion gate; cluster
   suite is tag-excluded from it, so it proves format/credo/dialyzer/
   compile_check/doc gates + the untouched single-BEAM suite).
3. Nothing committed; finish with the file list to stage + a suggested commit
   message (git policy: the operator stages and commits).

## Out of scope

- Phase 3 subsystem proofs (cross-node cancel, leader election, cron
  failover, composer reclaim) — Phase 2's kill/expiry/polling machinery is
  their scaffolding; the releasable flag-row blocking fixture is deliberately
  deferred until a Phase 3 proof needs staged release.
- Phase 4 observability + ops docs; lease telemetry (proofs poll the DB —
  telemetry is node-local).
