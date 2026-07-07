# WS6 Phase 1 — the `:peer` multi-node harness, proven by the fence race

## Context

WS6 is the last clustering workstream (WS1–WS5 + WS4a shipped). Today there is
**no real multi-node testing**: the one clustering test simulates cross-node
paths single-BEAM via a MockHarness forced onto the `:pg` fallback
(`test/jido_claw/forge/clustering_test.exs` — stays, untouched). Nothing can
currently prove lease/fence/reclaim correctness across real BEAM nodes — the
WS1/WS3 claims left as cross-BEAM IOUs in four test moduledocs.

Phase 1 (of 4, per `docs/plans/clustering/WS6-testing-and-ops.md`) lands the
`:peer` harness with exactly one proof — the **fence race** (WS1): seed one
claimable run in a shared DB, two peers race the claim, exactly one wins, the
loser never executes. No kill, no expiry, no timing window — the DB decides
the race (`FOR UPDATE SKIP LOCKED` + token CAS), so it forces every harness
decision while staying immune to timing flakiness.

**Completion bar**: cluster suite green via its own invocation; `mix precommit`
green (cluster suite excluded from it by tag); nothing committed — finish
commit-ready, end with files-to-stage + suggested commit message. Greenfield:
no compat shims. Toolchain: run mix via `mise exec -- mix`.

## Settled decisions (WS6 doc + user-confirmed)

- **Entry point: `scripts/test-cluster.sh`** (user-confirmed). Mix evaluates
  `config/test.exs` at CLI startup, *before* alias steps run, so the env flag
  must be in the OS env before `mix` boots. Precedent:
  `scripts/test-partitioned.sh`.
- **Formation: `cluster_strategy: :none` + explicit `Node.connect` mesh**
  (user-confirmed). Peers boot `cluster_enabled: true` → `:pg` scope
  `:jido_claw` + `Cluster.Leader` start (`application.ex:483-518`); `:none`
  topology (`core/cluster.ex:174-175`) keeps libcluster idle — no gossip
  secret, no strategy polling. The harness meshes peers deterministically.
- **No doc updates this unit** (user-confirmed). No gate fires: system_docs /
  jido_md / system_prompt checks only react to lib-subsystem / tool /
  template changes; this change is test-support + config + script only.
- **Test node stays `cluster_enabled: false`** — pure coordinator. It seeds
  and asserts via the shared DB; it needs no `:pg`. All cross-node assertions
  poll the DB — telemetry and PubSub are node-local and never cross BEAMs.
- **The Ecto sandbox cannot span BEAMs** → under `JIDOCLAW_CLUSTER_TEST=1`
  the Repo runs a regular pool against `jido_claw_cluster_test`; the cluster
  suite is `@moduletag :cluster`, excluded by default; clean by truncation.
- **Peer-executed code lives in `test/support/`** (compiled via
  `elixirc_paths(:test)`, `mix.exs:52`) — never inline in `.exs`.
- Naming deviation from the doc's "sname" wording: use **longnames pinned to
  `@127.0.0.1`** (same per-run-uniqueness intent; dodges macOS/CI hostname
  resolution flakiness). Per-run suffix = OS pid + `System.unique_integer`.
- **Deviations log (AGENTS.md convention)**: WS6 is a `docs/plans/` plan, so
  every deviation from it gets recorded under a `## Deviations` heading in
  `docs/plans/clustering/WS6-testing-and-ops.md` **as it happens** — what
  the plan assumed, what the code revealed, what was chosen and why. The
  longnames-vs-sname call above is the first entry. (This is the mandated
  deviations mechanism, distinct from the status/ops doc updates the user
  declined for this unit.)

## Key machinery (verified file:line)

- `WorkflowLease.claim_next/1` (`lib/jido_claw/orchestration/workflow_lease.ex:271`)
  — pure claim: `:claimable` Ash read locked with literal
  `"FOR UPDATE SKIP LOCKED"` (`:326-335`), CAS token rotate via raw SQL.
  Returns `{:ok, run, prior_owner} | :none | {:error, term}`. Stamps
  `claimed_by = to_string(Node.self())`.
- Claimable (`workflow_run.ex:249-268`): expired lease OR aged genesis orphan
  (`:pending`, nil token, `inserted_at < now() - pending_grace_seconds`
  [60s]).
- `ReclaimPooler.reclaim_once/0` (`reclaim_pooler.ex:93-94`) — production
  caller; **returns count reclaimed** (winner 1, loser 0); pooler loop is
  `enabled?: false` in test env (peers inherit that — no auto-racing).
- Reclaimed plain `:pending` run ⇒ `fail_stranded`: appends exactly
  `:run_recovered` + `:run_failed` (`workflow_log.ex:94-95`), projects status
  `:failed`.
- Reused helpers: `TenantCase.seed_tenant/1` + `actor_for/1` (plain
  functions — no sandbox dependency); `LeaseHelpers.seed_run/2`,
  `backdate_inserted!/2`, `reload_global/1`, `kinds/2`
  (`test/support/jido_claw/orchestration/lease_helpers.ex`).
- Peers boot with **empty app env** (the built `.app` carries none; Mix
  config applies only to the test node) — the full-env push is mandatory.
  OS env + cwd inherit. Boot preamble (dotenv → RuntimeSecrets → VaultConfig
  → BootGuard) is satisfied by the pushed test config, incl. the literal
  Cloak cipher (`config/test.exs:138-143`) — same AES key on every node
  sharing the DB, which is required.
- `WorkflowRecovery.owns_recovery?` is auto-false under
  `cluster_enabled: true` (`workflow_recovery.ex:781-783`) — no boot
  fail-all sweep on peers.
- Excluded modules skip `setup_all` (in-repo precedent:
  `docker_integration_test.exs`, `@moduletag :docker_sandbox`) — precommit
  never boots peers.

## Implementation

### 1. NEW `test/support/jido_claw/cluster/peer_harness.ex` — `JidoClaw.Cluster.PeerHarness`

Pure infrastructure, zero ExUnit coupling (reusable by Phases 2–3). Public
API (every public def `@spec`'d; `@moduledoc` explaining the cross-BEAM
model):

- `ensure_distribution!/0 :: node()` — idempotent: ensure epmd
  (`System.cmd(System.find_executable("epmd"), ["-daemon"], env: [])` —
  abs path + `env: []` satisfies credo LeakyEnvironment), then unless
  `Node.alive?()`: `Node.start(:"jc_origin_<suffix>@127.0.0.1", :longnames)`.
- `start_peers(n, opts) :: [peer]` where `peer :: %{node: node(), server: pid()}`
  — snapshot pushed config ONCE, boot peers **sequentially** (shared-DB boot
  writers: SystemJobsInitializer / default tenant — idempotent but no need
  to race them), then `connect_mesh/1` + `await/2` until the mesh settles.
  `opts`: `:boot_timeout` (default ~60s). **The whole body (boot loop + mesh
  + awaits) is wrapped so ANY failure class triggers cleanup — `rescue`
  alone is not enough**: `:erpc.call`/`:peer.call` and peer boot failures
  can **exit** rather than raise, so use `try ... rescue ... catch kind,
  reason ...`, stop every already-started peer in both branches, and
  re-raise preserving class + stacktrace (`reraise`/`:erlang.raise/3`).
  Otherwise a peer booted before a later failure (peer 2's boot, the mesh
  await) leaks for the rest of the test BEAM, since `setup_all`'s `on_exit`
  is only registered after `start_peers` returns.
- Per peer (private `start_one/2`) — **bootstrap rides the `:peer` control
  channel (`:peer.call/5`), NOT `:erpc`**: `:erpc` needs working distribution
  (cookie/name/connect), so using it for bootstrap would turn any
  distribution misconfiguration into an opaque `:noconnection` before
  `boot/1` can return its staged error. Sequence:
  1. `:peer.start/1` — **UNLINKED**, with
     `%{name: :"jc_peer<i>_<suffix>", host: ~c"127.0.0.1", longnames: true,
     args: [~c"-setcookie", <origin cookie>], wait_boot: <boot_timeout>,
     connection: :standard_io}`. Synchronous `wait_boot` + explicit `name`
     ⇒ the return shape is `{:ok, pid, node}` (the dialyzer note below
     assumes exactly this form). Unlinked because `setup_all` runs in a
     transient process — OTP parent/link semantics would otherwise tear the
     peers down when it exits; lifecycle is owned explicitly by the
     partial-failure cleanup + `on_exit` instead. Stdio control channel ⇒
     peers self-halt if the origin BEAM dies; no orphans.
  2. `:peer.call(server, :code, :add_paths, [:code.get_path()], timeout)` —
     control channel; puts every `_build/test/lib/*/ebin` (incl.
     test/support modules) on the peer path.
  3. `:peer.call(server, PeerHarness, :boot, [%{config: pushed, overrides:
     overrides}], timeout)` — named MFA (never ship anonymous funs across
     nodes); staged errors surface even when distribution is broken.
  4. **Prove distribution**, then switch transports: `Node.connect(node)`
     from the origin, `await` until `node in Node.list()`, and a canary
     `:erpc.call(node, :erlang, :node, []) == node`. From here on, all
     test-time calls use `call/5` (`:erpc`).
- `boot/1` (**runs on the peer**; the single boot procedure — keeps ExDNA
  happy): start `:elixir` + `:logger` apps first; apply pushed config via
  `Application.put_env/3` loop; apply overrides LAST (so `cluster_enabled:
  true` wins); `Application.ensure_all_started(:jido_claw)`; poll
  `Repo.query("SELECT 1")` to a deadline. Returns `:ok | {:error, {stage,
  reason}}` with `stage ∈ [:ensure_all_started, :db_timeout]` for
  attributable setup failures.
- `push_config/0` (private) — `Application.get_all_env/1` for every loaded
  app EXCEPT `[:kernel, :stdlib]` (keep `:elixir` — it carries the
  tz-database config from `config.exs`). This carries the flag-switched Repo
  config (regular pool + cluster DB), Vault cipher, secrets, logger level,
  and the config-gated pollers (`reclaim_pooler`/`workflow_recovery`/
  `cron_owner`/Consolidator all off in test env) to peers for free.
  **Accepted residual — `Embeddings.BackfillWorker`**: it starts bare on
  every node — both peers AND the origin/test BEAM (`application.ex:241`,
  no opts/config seam) — and schedules a scan every 30s
  (`backfill_worker.ex:111`). The leader gate (`:123`) trims the peers to
  one scanner (the elected peer leader), but the origin runs
  `cluster_enabled: false`, where `Cluster.leader?/0` is `true`
  (single-node semantics) — so expect **two** periodic scanners, not one.
  Every claim is SKIP-LOCKED and the Phase 1 cluster DB has zero embedding
  rows, so both are cheap idle SELECTs; worst case one momentarily delays a
  `TRUNCATE` (ACCESS EXCLUSIVE). Accepted for Phase 1 and recorded below as
  a named Phase 2 prerequisite (a quieting seam) before longer-running
  scenarios.
- `peer_overrides/1` (private, built in ONE place — reach `fixed_shape_map`
  smell): `[cluster_enabled: true, cluster_strategy: :none, skip_discord:
  true, forge_home: <unique tmp dir per peer>]`. `mode: :cli` and
  `serve_mode: nil` arrive via the push (no Endpoint, no served stdio MCP —
  the two internal MCP server processes, `application.ex:271` and `:277`,
  still start on peers; they mint per-run endpoints rather than binding boot
  ports, so they're harness-inert).
- `connect_mesh([node]) :: :ok` — `:erpc` `Node.connect/1` across peer pairs
  (origin↔peer is implicit; peer↔peer is not).
- `stop_peers([peer]) :: :ok` — `:peer.stop/1` each.
- `call(node, m, f, a, timeout \\ 15_000) :: term()` — thin `:erpc.call/5`
  wrapper; the default argument yields both `call/4` and `call/5` (the test
  skeletons below use the 4-arity; anything wanting a tighter/looser bound
  passes the fifth argument explicitly).
- `await(fun, timeout) :: :ok | {:error, :timeout}` — the ONE bounded
  poll-until-true helper (never bare sleeps).

### 2. NEW `test/support/jido_claw/cluster_case.ex` — `JidoClaw.ClusterCase`

`ExUnit.CaseTemplate` (top-level beside `TenantCase`/`SolutionsCase`):

- `using` block: `@moduletag :cluster`; import `PeerHarness` (`call/4`,
  `call/5`, `await/2`), `TenantCase` (`seed_tenant/1`, `actor_for/1` — imported as
  plain functions, deliberately NOT `use TenantCase`: its setup calls
  `Sandbox.start_owner!`, which explodes on the regular pool), and
  `LeaseHelpers` seeders (`seed_run/2`, `reload_global/1`, `kinds/2`,
  `backdate_inserted!/2`, …); alias `WorkflowLease`/`WorkflowRun`/
  `ReclaimPooler`.
- `setup_all`: **raise with a clear message unless
  `JIDOCLAW_CLUSTER_TEST == "1"`** (fail-loud if someone runs
  `mix test --only cluster` without the script — otherwise peers would race
  a sandbox pool); `ensure_distribution!()`; `start_peers(2, ...)`;
  `on_exit` → `stop_peers`; context `%{peers:, nodes:, node_a:, node_b:}`.
- `setup` (per test): `truncate_all!()` **BEFORE** each test — enumerate
  `pg_tables` (`schemaname='public'`, exclude `schema_migrations`), one
  `TRUNCATE …, … RESTART IDENTITY CASCADE` on the test node's Repo (shared
  DB ⇒ clears for all nodes); then seed a fresh tenant + actor, return
  `%{tenant:, actor:, ctx: %{tenant:, actor:}}`.
  - Truncate-before rationale: clean slate even after crashes; boot-created
    system/default tenant rows die at the first truncation — inert for
    Phase 1 (the claim path is `multitenancy(:bypass)` DB work; each test
    seeds its own tenant). Peer in-memory tenant caches going stale is also
    inert here; noted as a Phase 2 concern (quiescence before TRUNCATE's
    ACCESS EXCLUSIVE lock).

### 3. NEW `test/jido_claw/cluster/fence_race_test.exs` — `JidoClaw.Cluster.FenceRaceTest`

`use JidoClaw.ClusterCase, async: false` (satisfies PassAsyncInTestCases).
Three tests:

**Test 1 — harness smoke** (separates harness failures from proof failures):
- `:jido_claw` started on both peers (`call(peer, Application,
  :ensure_all_started, [:jido_claw])` — idempotent);
- mesh: `node_b in call(node_a, Node, :list, [])` and vice versa;
- shared DB: `seed_run(ctx)` on the test node is visible from a peer via
  `call(node_a, WorkflowRun, :by_id_global, [run.id])`;
- `:pg` propagates peer-to-peer — asserted **black-box via the public API**
  (the Leader's `:pg` group name is a private module attribute,
  `leader.ex:72`; don't reach into it): `await` until
  `call(node_a, JidoClaw.Cluster, :leader, [])` and
  `call(node_b, JidoClaw.Cluster, :leader, [])` are non-nil and equal, then
  assert exactly ONE of the two peers answers
  `call(peer, JidoClaw.Cluster, :leader?, []) == true`. Leader agreement
  across peers is only possible if the `:pg` scope propagated over the mesh
  — same proof, public surface (`core/cluster.ex:110-123`).

**Test 2 — bare claim race (the WS1 primitive)**:
- `seed_run(ctx)` + `backdate_inserted!(run.id,
  WorkflowLease.pending_grace_seconds() + 60)` — aged genesis orphan;
- two `Task.async` → `call(peer, WorkflowLease, :claim_next, [[]])`,
  `Task.await_many`;
- assert exactly one `{:ok, run, nil}` and one `:none` (any interleaving:
  row-locked ⇒ SKIP LOCKED ⇒ `:none`; fresh lease ⇒ not claimable);
- `reload_global(run.id)`: `claimed_by == to_string(winner_node)`,
  `claim_token == won.claim_token` (single stamp), `status == :pending`
  (claim never touches status);
- `kinds(run.id, ctx) == []` — nothing executed.

**Test 3 — production-path race (claim → reclaim dispatch, exactly-once)**:
- fresh seeded + aged run; two `Task.async` → `call(peer, ReclaimPooler,
  :reclaim_once, [])`;
- `Enum.sort([count_a, count_b]) == [0, 1]` — decisive winner/loser from
  return values;
- `reload_global(run.id).status == :failed` (fail_stranded terminal);
- `kinds(run.id, ctx)` contains exactly ONE `:run_recovered` and ONE
  `:run_failed` — the loser appended nothing (no duplicate execution events
  in the parent log).

Tests 2 and 3 stay separate: 2 proves the claim primitive is exclusive,
3 proves the production disposition is exactly-once — if 2 is green and 3 is
red, the bug is in reclaim/recovery, not the claim.

### 4. NEW `scripts/test-cluster.sh` (mode 755)

```bash
#!/usr/bin/env bash
# WS6 cluster suite entry point. Runs the :peer multi-node tests
# (@moduletag :cluster) against the shared jido_claw_cluster_test DB.
#
# Invoke via a shell where `mix` resolves to the project toolchain:
#   mise exec -- scripts/test-cluster.sh      # explicit (canonical)
#   scripts/test-cluster.sh                   # fine in an activated shell
#
# JIDOCLAW_CLUSTER_TEST=1 and --only cluster MUST travel together:
# the flag swaps the Repo pool (sandbox -> regular), which breaks every
# non-cluster test; the tag keeps peer tests out of sandbox runs.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
export JIDOCLAW_CLUSTER_TEST=1
exec mix test --only cluster "$@"
```

Plain `mix` inside (precedent: `test-partitioned.sh` — the script is
toolchain-agnostic; the header names `mise exec -- scripts/test-cluster.sh`
as the canonical invocation). The `test` alias's `ash.setup --quiet` runs
with the flag exported → creates/migrates `jido_claw_cluster_test` on first
use (the partition-DB mechanism).

### 5. EDIT `config/test.exs` — gated Repo overlay (after line 157)

```elixir
# Cluster suite (JIDOCLAW_CLUSTER_TEST=1, via scripts/test-cluster.sh): swap
# the SQL sandbox for the regular pool + a dedicated DB so a real :peer
# cluster shares ONE Postgres across BEAMs — sandbox ownership cannot span
# nodes. Gated so normal `mix test`/precommit keep the sandbox. Merges onto
# the JidoClaw.Repo block above.
if System.get_env("JIDOCLAW_CLUSTER_TEST") == "1" do
  config :jido_claw, JidoClaw.Repo,
    database: "jido_claw_cluster_test",
    pool: DBConnection.ConnectionPool,
    pool_size: 10
end
```

`Config.config/2` merges by key — username/password/hostname carry over.
`pool:` must be set explicitly (merge can override, never remove). 3 nodes ×
10 = 30 connections ≪ Postgres' default 100. `forge_home` untouched
(per-peer uniqueness comes from the harness override).

### 6. EDIT `test/test_helper.exs`

```elixir
ExUnit.start(exclude: [:docker_sandbox, :slow, :cluster])
```

Keeps the suite out of `mix test`, `precommit`, and partitioned runs;
`--only cluster` re-includes it. Distribution bootstrap deliberately does
NOT live here — it stays in `ClusterCase.setup_all` via the idempotent
`ensure_distribution!/0`, preserving the one-line helper.

## Precommit compliance (gates run in MIX_ENV=test and see test/support)

- `@spec` on every public def + `@moduledoc` (credo Readability.Specs,
  strict); alias nested modules >2 deep (Design.AliasUsage); ≤120 cols;
  no comment line starting with "step" (ExSlop); no copy-paste boot logic
  (ExDNA) — `boot/1` and `await/2` are the single implementations.
- Dialyzer: `:peer.start/1` is called with synchronous `wait_boot` + an
  explicit `name`, so the expected return is `{:ok, pid, node}` (async
  wait modes return differently — we don't use them); verify against
  installed OTP 29 on the first `mix dialyzer` and add variants only if
  flagged. `call/5 :: term()` (honest — `:erpc.call` result); destructure
  `Application.loaded_applications/0` tuples.
- `System.cmd` for epmd: absolute path + `env: []`
  (Warning.LeakyEnvironment).
- No mix.exs/mix.lock change (`:peer`/`:erpc` are OTP; libcluster already a
  dep) → the `deps.unlock --unused` step (`mix.exs:269`) unaffected.
- system_prompt/jido_md/system_docs checks: not triggered (no tools,
  templates, skills, or lib/ subsystem docs touched).
- Full `mix test` behavior byte-identical: overlay gated off, no existing
  test tagged `:cluster`, excluded module never runs `setup_all`.

## Verification (in order)

1. `mise exec -- scripts/test-cluster.sh` — first run creates + migrates
   `jido_claw_cluster_test`, then runs the 3 cluster tests. Expect green.
2. Re-run twice (flake shake — per project flaky-test experience, verify in
   isolation; this suite runs alone by construction, and Phase 1 has no
   timing window: the only polls are bounded `await`s on boot/mesh/`:pg`).
3. `mise exec -- mix test` (normal suite, sandbox path) — confirm untouched.
4. `mise exec -- mix precommit` — run bare in background (never piped),
   read the output tail. Must be green end-to-end.
5. Finish: report files-to-stage + suggested commit message
   (`feat: WS6 Phase 1 — :peer cluster harness + fence-race proof` or
   similar). Nothing committed. Update the clustering-state memory note
   (WS6 Phase 1 shipped, Phases 2–4 remain).

**Debug hints for likely failures**: epmd down → `epmd -names`;
`boot/1` `{:error, {:ensure_all_started, _}}` → pushed-config gap (Vault/
secrets — check push ran before boot); `{:error, {:db_timeout, _}}` → DB
missing/creds; failure at the distribution-proof step (`Node.connect` /
canary `:erpc`) while `boot/1` already returned `:ok` over the control
channel → cookie or name-domain mismatch (that separation is exactly why
bootstrap rides `:peer.call`); "too many connections" → check
`pg_stat_activity`, lower pool_size; TenantCase tests exploding under the
flag → someone ran `JIDOCLAW_CLUSTER_TEST=1 mix test` without
`--only cluster` (the script always pairs them; ClusterCase's setup_all
raise covers the inverse mistake).

## Out of scope (later phases)

Phase 2: kill/lease-expiry machinery + reclaim/stale-fence proofs. Phase 3:
cancel/leader/cron/composer proofs. Phase 4: lease telemetry, dashboard
ownership columns, deploy docs, embedding-counter doc fix. The harness is
built so Phases 2–3 only add scenario choreography (short real lease
windows pushed per-peer via the same overrides seam; `reclaim_pooler
enabled?: true` per-peer when needed).

**Named Phase 2 prerequisite** (from the accepted Phase 1 residual): a
quieting seam for `Embeddings.BackfillWorker` — it starts with no
opts/config seam (`application.ex:241`), so its leader-gated 30s scan
cannot be silenced by env push today. Before Phase 2's longer-running
kill/expiry scenarios, feed its `init/1` opts from app config (a tiny lib
change, done in that unit with its docs obligations) so peers can park the
scan interval the way `renew_seconds: 86_400` parks the lease timer.
