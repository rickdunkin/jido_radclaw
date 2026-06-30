# WS6 — Testing & ops

*Builds: a real multi-node test harness, deployment config, and the small gate
fixes. Depends on: all (validates them). Cross-cutting — woven throughout, finalized
last.*

> **What this owns.** Lease/fence/reclaim correctness is the kind of thing that
> only shows up across real BEAM nodes, and no multi-node test harness exists yet.
> WS6 stands one up, documents the deploy config to actually run clustered, and
> sweeps the small doc-vs-code gaps.

## Component 1 — Multi-node test harness

Today there is **no real multi-node testing**. The one clustering test simulates
the cross-node path single-node via a `MockHarness` GenServer that isn't in the
local registry, forcing the `:pg` fallback
(`test/jido_claw/forge/clustering_test.exs`). That's fine for exercising fallback
*logic*, but it cannot test lease reclaim, fence races, or "kill a node, watch a
peer take over" — the WS1/WS3 correctness claims.

Options:

- **`:peer` (recommended).** OTP-native multi-node test nodes (`:peer.start_link/1`),
  no dependency. The toolchain is OTP 29 (`[[project_toolchain_mise_latest]]`), so
  `:peer` is available and is the modern replacement for `:slave`. Start 2–3 peer
  nodes, connect them, point them at the same test Postgres, and assert reclaim.
- **`LocalCluster` dep.** Friendlier API, but adds a test dep for what `:peer`
  does natively.
- **Extend the mock.** Cheapest, but can't validate real fencing — keep it for
  fast unit coverage, not the integration proof.

**The Ecto sandbox is the hard part.** The `Ecto.Adapters.SQL.Sandbox` pattern
(`async: false` clustering test, `clustering_test.exs`) does not span nodes — peer
nodes need a *shared, non-sandboxed* test database (or `Sandbox.mode(:shared)`
with explicit allowances) so a run claimed by peer A is visible to peer B. Design
the harness around a shared DB checkout, not per-test sandbox isolation.

**Flakiness watch.** Multi-node lease tests are `async: false` and timing-sensitive
(lease expiry, renew cadence). Per `[[project_suite_flaky_tests]]`, async:false
singleton/resource tests already move run-to-run under load — verify these in
isolation, use generous lease windows in tests, and avoid wall-clock sleeps in
favor of polling for the claimed/reclaimed state.

## Component 2 — Deployment config & the `cluster_enabled` flip checklist

The topologies exist (`core/cluster.ex:97-160`) but running clustered needs:

- **Gossip secret.** The default `:gossip` strategy **raises without a shared
  secret** (`core/cluster.ex:166-193`, `gossip_secret!/0`) — `JIDOCLAW_CLUSTER_SECRET`
  / `:cluster_secret` must be set on every node, or pick `:kubernetes` / `:epmd`.
- **Topology choice.** `:cluster_strategy` (default `:gossip`, `config.exs:187`).
  Document gossip (multicast, dev/LAN) vs kubernetes (DNS) vs epmd (static hosts).
- **The flip checklist** — a documented precondition list for setting
  `cluster_enabled: true`:
  1. WS1 (lease) **and** WS3 (reclaim) have landed — otherwise recovery is silently
     off (README §gotcha). **Hard gate.**
  2. WS4 leader election present (or cron audited idempotent).
  3. A shared, reachable Postgres (already required; confirm not per-node).
  4. Cluster secret / topology configured on every node.
  5. `serve_mode` is not `:mcp` on the execution nodes (MCP mode skips Gateway +
     run execution, `application.ex`).

## Component 3 — Small gate fixes (the WS0 leftovers)

- **Embedding counter `:cluster_enabled` gap.** The cross-node embedding budget
  counter runs **unconditionally** (`embeddings/rate_pacer.ex`, called at
  `backfill_worker.ex:314-315`), but `PLAN-v0.6-memory.md:1731-1734` designed it to
  engage only "when clustering is enabled." The code is **harmless and correct
  single-node** (a one-row UPSERT per dispatch, as the doc itself notes at
  `:1816-1818`). **Recommendation: update the doc to match the code** (unconditional
  is fine and simpler) rather than add a gate — but record the decision explicitly
  so the discrepancy isn't re-discovered as a bug. Trivial either way.

## Component 4 — Observability

Lease behavior must be visible in the dashboard and telemetry:

- Add lease telemetry events (claimed / renewed / reclaimed / fenced-out) beside
  the existing `[:jido_claw, :orchestration, :recovered]` (`workflow_recovery.ex:460-466`).
- Surface `claimed_by` / `claim_expires_at` in the workflow dashboard so an
  operator can see *which node owns a run* — gust's stated payoff of a DB-backed
  lease ("the dashboard can show who owns a run", `gust/…:127-128`). This pairs
  with the AR-2 §10.2 observe surface (`workflow_status` / `WorkflowView`).

## Test plan (the integration proofs WS6 must produce)

- **Reclaim across real nodes** — peer A claims and starts a run; kill A; peer B
  reclaims after lease expiry and resumes/re-runs it correctly (WS1 + WS3).
- **Fence race** — two peers race to claim one run; exactly one wins; the loser
  never executes (WS1 `SKIP LOCKED`).
- **Stale-fence halt across nodes** — force-reclaim a run B is executing; B's
  `Lease` middleware halts it without a double terminal (WS1).
- **Composer reclaim across nodes** — kill a node mid-composer-route; a peer
  rebuilds state from the parent log and resumes mid-route (WS2 + WS3).
- **Cross-node cancel** — cancel on A a run owned by B; B's executor is killed
  promptly via the terminator route, `run_cancelled` already durable (WS5).
- **Leader election** — exactly one leader across peers; re-elects on leader death
  (WS4).
- **User-cron exactly-once failover** — two `:peer` nodes; exactly one runs a
  given user job (the leader's `Cron.Owner`); kill the leader, assert the
  survivor's Owner reloads within the election + reconcile window and continues
  firing, with no double-fire (WS4a). The only WS4a behavior not provable
  single-BEAM; rides this harness exactly as the WS1/WS3/WS4 cross-BEAM proofs
  do.

## Cross-references

- Current mock harness — `test/jido_claw/forge/clustering_test.exs`.
- Topology + secret — `core/cluster.ex:97-193`; config `config.exs:186-187`.
- Embedding counter — `embeddings/rate_pacer.ex`; design `PLAN-v0.6-memory.md:1731-1834`.
- Observe surface — AR-2 §10.2 (`AR-2-COMPOSER-PLAN.md:906-926`); gust DB-backed
  payoff `gust/FEATURES-WORTH-BORROWING.md:127-128`.
- Validates: WS1–WS5, WS4a.
