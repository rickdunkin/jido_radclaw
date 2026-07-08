# WS6 Phase 4 — observability + ops (implementation plan)

## Context

WS6 (`docs/plans/clustering/WS6-testing-and-ops.md`) is the last clustering
workstream; Phases 1–3 are done (1–2 committed, 3 pending commit in the working
tree). Phase 4 closes WS6 — and with it the clustering program: lease telemetry,
dashboard ownership columns, deploy docs + the `cluster_enabled` flip checklist,
and the embedding-counter decision record. No cluster-suite work — Phase 4 is
entirely single-BEAM (telemetry is node-local; that's exactly why the Phase 2/3
proofs poll the DB instead).

**Operator decisions at plan review** (log these in the WS6 doc's Deviations
`### Phase 4` when implementation starts):

1. **Docs home = a new governed `docs/system/clustering.md`** — the full triad
   (page + index row + AGENTS.md Key Patterns bullet), not ungoverned README
   prose. Makes the same-PR rule enforceable for future clustering changes.
2. **Ownership fields ride BOTH the dashboard and the observe surface** —
   `claimed_by`/`claim_expires_at` join `Visibility.run_view/3`'s base map (the
   single funnel: dashboard, `workflow_status`, `jido.runs`, `jido://bootstrap`,
   CLI) plus the two allowlisted consumers that don't inherit automatically
   (`inspect_workflow`'s projection, the `jido.runs` Lua binding's `returns:`
   doc), with the house-convention MINOR `SurfaceVersion` bump 1.1 → 1.2.
3. **Embedding counter recorded doc-side** — code stays unconditional (correct +
   simpler); the decision is recorded, not silently re-discoverable.

**Discovered delta** (forced; log as a fourth Deviations entry): the WS6 doc
lists four events to add, but `[:jido_claw, :orchestration, :reclaimed]`
**already ships** (WS3 — `ReclaimPooler.emit_reclaimed/1`,
`reclaim_pooler.ex:124-135`). Phase 4 adds only **claimed / renewed /
fenced_out**; all five (incl. `:recovered`) get `metrics/0` + docs coverage.

## Constraints (operator-set)

- Complete only when `mise exec -- mix precommit` passes (run bare, in
  background, read the tail — never pipe the gate).
- Greenfield; no compat concerns. No commits — everything stays unstaged; finish
  commit-ready (files-to-stage + suggested message).
- No deferrals. Deviations logged in `WS6-testing-and-ops.md` → new
  `### Phase 4` heading, as they happen.

---

## Item 1 — lease telemetry (3 new events + metrics + tests)

House shape (match exactly): inline `:telemetry.execute`, event
`[:jido_claw, :orchestration, <past-tense-verb>]`, measurements `%{count: 1}`,
metadata `%{run_id, tenant_id, ...}`. **No lease token in any metadata** (fence
credentials stay out of telemetry).

### 1a. `lib/jido_claw/orchestration/workflow_lease.ex` — pure `fenced_reason/1`

Public (with `@spec` + `@doc`, credo Specs gate), right after `fence_decision/3`
(~`:400`):

```elixir
@spec fenced_reason({:ok, 0} | {:error, term()}) :: :stolen | :lapsed
def fenced_reason({:ok, 0}), do: :stolen
def fenced_reason({:error, _}), do: :lapsed
```

`:stolen` = token rotated away (`{:ok, 0}`); `:lapsed` = renew error past the
lease window. In the sidecar's `:kill` branch the raw result is only ever
`{:ok, 0}` or `{:error, _}` (`{:ok, n>=1}` → `:renewed`) — the clauses match
exactly that precondition, **no catch-all**: an impossible input
(`{:ok, n>=1}`) fails loud rather than being silently classified. Kept separate
from `fence_decision/3` — its API and every consumer stay untouched. **Why public +
pure**: the `:lapsed` emit path is unreachable in the shared sandbox (forcing an
un-raised renew `{:error, _}` needs Mox, which the project lacks —
`middleware.ex:150-153` documents the same constraint for `stamp/4`), so the
pure function IS `:lapsed`'s test coverage.

### 1b. `lib/jido_claw/orchestration/workflow_lease/sidecar.ex` — renewed + fenced_out

In `act/2` (`:141-157`; raw `result` is in scope, `WorkflowLease` already
aliased):

```elixir
:renewed ->
  emit_renewed(state)
  loop(%{state | last_ok: monotonic_now()}, renew_interval())

:kill ->
  emit_fenced_out(state, WorkflowLease.fenced_reason(result))
  Process.exit(state.executor, :kill)
  :ok
```

Two **private** helpers (private → no Specs requirement, matches
`emit_reclaimed`): metadata `%{run_id, tenant_id, node:
WorkflowLease.node_identity()}`, fenced_out adds `reason:`. The `{:retry, ms}`
branch emits nothing (transient DB error inside the window — not a fence).
`renewed` fires every ~15s per live run — accepted volume. One moduledoc line in
"The loop" section naming the two events.

### 1c. `lib/jido_claw/orchestration/workflow_lease/middleware.ex` — claimed + fenced_out(:claim_lost)

```elixir
{:ok, :claimed} ->
  emit_claimed(id, tid, run.workflow_type)   # before start_sidecar: claimed = the CAS stamp won
  case WorkflowLease.start_sidecar(self(), id, tid, token) do ...

{:ok, :lost} ->
  emit_fenced_out(id, tid, :claim_lost)
  {:error, {:lease_lost, id}}
```

`claimed` metadata: `%{run_id, tenant_id, workflow_type, node}`. The two
per-module private `emit_fenced_out` helpers (different arity/metadata) are
intentional — don't share. One moduledoc line naming both events.

**`:claim_lost` means "claim refused", not "another node fenced us"**:
`stamp/4` returns `{:ok, :lost}` both for a lost cross-node CAS *and* for a
terminal/parked row's status-guard miss (the `middleware.ex:76-79` comment says
exactly this). Document that meaning verbatim wherever the reason appears — the
middleware moduledoc, the ARCHITECTURE.md row, and clustering.md's telemetry
section — so the metric is never read as a pure cross-node fence count.

### 1d. `lib/jido_claw/core/telemetry.ex` — `metrics/0` (all FIVE)

`counter("jido_claw.a.b.total")` maps to event `[:jido_claw, :a, :b]` but
**infers measurement `:total`** from the name's last segment — while all five
events emit `%{count: 1}`. Pass `measurement: :count` explicitly on every one
(the minimal fix; changing the emits to `%{total: 1}` would touch the shipped
`reclaimed`/`recovered` emitters). Add after the cron block (~`:116`):

```elixir
counter("jido_claw.orchestration.claimed.total", measurement: :count),
counter("jido_claw.orchestration.renewed.total", measurement: :count),
counter("jido_claw.orchestration.reclaimed.total", measurement: :count),
counter("jido_claw.orchestration.fenced_out.total", measurement: :count, tags: [:reason]),
counter("jido_claw.orchestration.recovered.total", measurement: :count, tags: [:branch]),
```

(`:reclaimed`/`:recovered` already emit but were never registered.) The existing
core telemetry test looks up metrics by name only — nothing breaks; add
assertions for the new counters that check **`metric.measurement` (`:count`)
and tags**, not mere presence. (Note, out of scope: several pre-existing
counters in `metrics/0` whose emitters send `%{count: 1}` share the same
inference mismatch — flag for a follow-up sweep, don't fix here.)

### 1e. Docs touches

- `docs/ARCHITECTURE.md` "Telemetry Metrics" table (~`:624-642`, currently
  missing the whole `:orchestration` domain): add the five rows.
- `reclaim_pooler.ex` `## Telemetry` moduledoc section: one line pointing at the
  full five-event family / the new clustering page.

### 1f. NEW `test/jido_claw/orchestration/lease_telemetry_test.exs`

`use JidoClaw.TenantCase, async: false`; **replicate `workflow_lease_test.exs`'s
setup** (`:49-66` — the leaked `RunTaskSupervisor`/`LeaseTaskSupervisor`
`on_exit` kill is required by `launch_blocking/1`); local `OkStep`/`OkReactor`
fixtures (the `workflow_lease_test.exs:1-15` shape); attach helper in the
cron-telemetry style (`test/jido_claw/cron/telemetry_test.exs:39-53`): unique
handler id via `System.unique_integer([:positive])`, send-to-test-pid tagged
tuple, detach in `on_exit` (no `try`/`after` — credo). Import
`JidoClaw.Orchestration.LeaseHelpers` (`seed_run/2`, `launch_blocking/1`,
`rotate_token!/2`).

| Test | Driver |
| --- | --- |
| `claimed` | `ReactorRunner.run(OkReactor, ...)` — the real self-claim path (`workflow_lease_test.exs:279-291` shape); assert `run_id`/`tenant_id`/`workflow_type`/`node == WorkflowLease.node_identity()` (the project seam — never `to_string(Node.self())`) |
| `renewed` | `launch_blocking(ctx)` → `Registry.lookup(LeaseRegistry, run_id)` → `send(sidecar, {:lease_tick, self()})` → `assert_receive {:lease_ticked, {:ok, 1}}` + the event |
| `fenced_out :stolen` | `launch_blocking` → `rotate_token!` → tick → `{:ok, 0}` (existing stale-fence scenario, `workflow_lease_test.exs:209-232`) + event with `reason: :stolen` |
| `fenced_out :claim_lost` | drive `Middleware.init/1` directly: `seed_run(ctx)` (nil DB token) → `rotate_token!(run.id, Ash.UUID.generate())` → `Middleware.init(%{claim_token: Ash.UUID.generate(), workflow_run: run})` → `{:error, {:lease_lost, _}}` + event (no sidecar started) |
| `fenced_reason/1` | pure: `{:ok, 0} → :stolen`, `{:error, :db_down} → :lapsed`; comment states the `:lapsed` emit path isn't sandbox-reachable, this is its coverage |

---

## Item 2 — ownership columns: dashboard + observe surface

### 2a. `lib/jido_claw/web/live/workflows_live.ex`

- Two `<th>` between Deadline (`:208`) and Actions (`:209`): `Owner`,
  `Lease expires`.
- Two `<.toggle_cell run_id={run.id}>` data cells after the Deadline cell
  (`:237`), muted styling like the Started cell: `{run.claimed_by || "—"}` and
  `{format_time(lease_expiry(run))}` (`format_time/1` `:474-475` already
  nil-safes to `"—"`). **Blank the expiry on terminal rows**: terminal runs
  deliberately keep their claim columns frozen (lease frozen at terminal), so
  rendering `claim_expires_at` unconditionally implies a live lease on
  completed/failed/cancelled runs. Small private helper reusing the existing
  seam (`replayable?/1` at `:477` already uses it):

  ```elixir
  defp lease_expiry(run) do
    if Projection.terminal_status?(run.status), do: nil, else: run.claim_expires_at
  end
  ```

  `claimed_by` stays unconditional — "which node ran it" is meaningful on
  terminal rows too. Fields are always on the struct (`public?(false)` hides
  from the Ash API, not struct reads; `list_runs/1` does no select narrowing) —
  **no query change, no new socket assign**, so the render-assigns triad and
  both `build_socket/1` helpers stay untouched.
- **CRITICAL: all four hardcoded `colspan="6"` → `colspan="8"`** — `:301`
  (expanded steps), `:382` (replay diagnostics), `:388` (runs_error), `:393`
  (empty state). Miss one and the full-width rows misalign.
- Stale prose: `:404` comment "all five data cells" → seven.

### 2b. `test/jido_claw/web/live/workflows_live_test.exs`

- `:72` — `count_substring(..., toggle_steps...) == 5` → `== 7`; update the
  `:69-71` comment and the moduledoc (`:7-8`, "exactly 5 toggle bindings").
- New assertions (no DB write needed — `render_runs/2` takes structs): struct-
  update a seeded run (`%{run | claimed_by: "peer@host", claim_expires_at:
  ~U[...]}`), render, assert both headers and both values appear; a nil-claim
  run renders `—`; and a **terminal** run with frozen claim columns renders its
  owner but `—` for lease expiry (the blanking rule above).

### 2c. `lib/jido_claw/orchestration/visibility.ex` — the funnel

Add to `run_view/3`'s `base` map (`:56-76`):

```elixir
claimed_by: run.claimed_by,
claim_expires_at: run.claim_expires_at,
```

Scopes verified: `:operator -> base`, `:auditor -> base + result` — no scope
redacts base fields, so all consumers gain them (`workflow_view.ex:249` →
`workflow_status` + `jido.runs`; `bootstrap.ex:20`; `workflows_live.ex:218`;
`run_command.ex:429,442`). `JsonSafe` handles DateTime → ISO-8601 and key
stringification — the fields land *inside* the `{:list, :map}` run maps, so no
`workflow_status` output_schema change and no atom-key trap. Update the `@doc`
("additively extended with `deadline`" → also the WS6 ownership fields).

**Semantics caveat (document, don't transform)**: unlike the dashboard (which
blanks expiry on terminal rows), the observe surfaces expose the **raw/frozen**
claim columns — a terminal run's `claim_expires_at` is the frozen last-claim
value, never live lease state. State that in one sentence in the `run_view`
`@doc`, clustering.md's telemetry/columns section, and the v1.2 changelog
entry, so agent consumers pair the field with `status` instead of reading it
as liveness.

Two consumers do NOT inherit automatically and are in scope (both part of the
"observe surface" decision):

- **`inspect_workflow`** (`lib/jido_claw/tools/inspect_workflow.ex:94-108`):
  `project/1` re-projects `WorkflowView.snapshot/2` through an explicit
  `put_present` allowlist — the new fields would be silently dropped. Add
  `|> put_present(:claimed_by, s.claimed_by)` and
  `|> put_present(:claim_expires_at, JsonSafe.encode(s.claim_expires_at))`
  (nil → key absent, per the tool's shape rules), and **declare the two new
  type-stable top-level fields** in its `output_schema` (optional `:string`s,
  atom keys per the documented contract at `:83-93`). Note this is a deliberate
  declaration, not precedent-following: `started_at`/`completed_at` are today
  *undeclared* pass-through extras (unknown keys pass validation preserved).
  Extend `test/jido_claw/tools/inspect_workflow_test.exs`.
- **`jido.runs` Lua binding docs**
  (`lib/jido_claw/tools/lua/bindings.ex:182-185`): the data path inherits via
  `run_view` (verify `runs_read/2` at implementation), but the entry's
  `returns:` string enumerates the run-map fields explicitly — append
  `claimed_by` + `claim_expires_at` so `lua_docs` doesn't go stale (`jido.run`'s
  entry describes itself as "the jido.runs projection", no list — untouched).
  Check `test/jido_claw/tools/lua_docs_test.exs` for rendered-docs assertions
  and extend as needed.

### 2d. Tests touched by 2c

- `test/jido_claw/orchestration/visibility_test.exs:96-110` — the **exact
  sorted key-set** assertion: add `:claimed_by` + `:claim_expires_at`. Add a
  positive pass-through assertion via `run_fixture(claimed_by: ...,
  claim_expires_at: ...)`.
- `workflow_view_test.exs` / `bootstrap_test.exs` assert field-wise (never exact
  key-sets) — safe; optionally assert the new fields ride `workflow_status`'s
  string-keyed run maps in `workflow_view_test.exs`.

### 2e. `lib/jido_claw/core/mcp_server/surface_version.ex` — MINOR bump

`@current "1.1"` → `"1.2"`. The moduledoc's own contract covers "output fields",
so this is squarely a MINOR per the stated bump rules. Add a changelog entry
modeled on v1.1 (stamp the actual implementation date):

```
* v1.2 (<impl date>) — MINOR: run views served by `workflow_status`,
  `jido.runs`, `jido://bootstrap`, and `inspect_workflow` gain the additive
  `claimed_by` + `claim_expires_at` ownership fields (WS6 lease observability,
  via `Visibility.run_view/3`). Tools, URIs, and templates unchanged.
```

### 2f. `test/fixtures/mcp_surface/served_surface.json`

Single-line edit: `"surface_version": "1.1"` → `"1.2"` (the golden test
set-compares tool names / URIs / templates / version only — no tools change; on
mismatch the test prints the regen JSON).

### 2g. `docs/system/mcp-server-surface.md`

Same-PR rule (SurfaceVersion is this page's subsystem): add a v1.2 note parallel
to the existing v1.1 mention, and bump `verified:` to the implementation date.

### 2h. Explicitly NOT touched (verified)

`.jido/JIDO.md` / `mix jidoclaw.jido_md.check` (derives app tool/template/skill
names + version — does not embed SurfaceVersion) and
`mix jidoclaw.system_prompt.check`. Do not run the generators.

---

## Item 3 — `docs/system/clustering.md` (new governed page + triad)

Machine-enforced (all in one change, or `system_docs.check` fails both
directions): **(1)** the page — frontmatter with `type: subsystem`, one-line
`description`, non-empty `sources:` of existing repo-relative paths,
`verified:` stamped with the implementation date (omit `verified_sha`), plus a
`## Source map` section
with ≥1 backticked `path[:line]` ref; **(2)** an index row in
`docs/system/README.md` (`- [Clustering](clustering.md) — <hook>`, em-dash
required); **(3)** an AGENTS.md bullet containing a
`docs/system/clustering.md` link in the hand-written region. The full body
skeleton (`## What & why` → `## Invariants & contracts` → `## Mechanics` →
`## Config & telemetry` → `## Residuals & accepted risks` → `## Source map`) is
convention, not gated — include it anyway.

**Frontmatter `sources:`** — `lib/jido_claw/core/cluster.ex`,
`lib/jido_claw/application.ex`, `lib/jido_claw/orchestration/workflow_lease.ex`,
`lib/jido_claw/orchestration/reclaim_pooler.ex`,
`lib/jido_claw/orchestration/workflow_recovery.ex`,
`lib/jido_claw/orchestration/workflow_lease/middleware.ex`,
`lib/jido_claw/orchestration/workflow_lease/sidecar.ex`, `config/config.exs`.

**Content outline** (use CURRENT line cites — the WS6 doc's are ~45 lines
stale):

- **What & why** — multi-node execution off by default; libcluster + `:pg`
  baseline ships; this page = how to run clustered safely + the run-ownership
  model. Design history stays in `docs/plans/clustering/README.md` (link it).
- **Invariants & contracts** — `cluster_enabled: false` default
  (`config.exs:186`); libcluster starts only when enabled AND distribution is up
  (`application.ex:483-491`); `:gossip` **raises without a shared secret**
  (`gossip_secret!/0`, `cluster.ex:210-237`); the layered trust model (secret
  *encrypts* heartbeats — AES-CBC, no MAC, not auth; the distribution cookie
  gates membership; Ed25519 peer sigs authenticate messages — align with
  `README.md:865-891`); the lease discipline (CAS stamp claims, token-fenced
  renew, rotated token fences the zombie kill-before-terminal, always-on
  claim-gated `ReclaimPooler`); **the load-bearing gotcha** — boot recovery
  turns itself off under clustering (`owns_recovery?`,
  `workflow_recovery.ex:780-784`), lease-expiry reclaim replaces it.
  - **The `cluster_enabled` flip checklist** (from `WS6:202-211`, fixing its
    "(README §gotcha)" pointer to cite `docs/plans/clustering/README.md`'s "The
    load-bearing gotcha"): 1. WS1+WS3 landed (hard gate — both shipped; the row
    records *why*). 2. WS4 leader election present (or cron audited idempotent).
    3. Shared, reachable Postgres (not per-node). 4. Cluster secret + topology
    on every node; non-default distribution cookie. 5. **MCP-mode nodes are
    execution nodes too** — `serve_mode: :mcp` skips Gateway/Discord and *boot
    recovery* (`owns_recovery?`), NOT run execution: `run_skill` launches
    workflows (`ReactorRunner.run`) and the always-on claim-gated
    `ReclaimPooler` covers every serve mode (`reclaim_pooler.ex:23`) — so a
    clustered MCP node needs the same shared Postgres, secret/topology, and
    lease/reclaim coverage as any node. (This **corrects the WS6 sketch's
    item 5**, which claimed MCP mode "skips run execution" — log the
    correction as a Deviations entry.)
- **Mechanics** — `topology/0` (`cluster.ex:141-181`) dispatch on
  `:cluster_strategy`: gossip (`:190-204`; multicast + secret), kubernetes
  (DNS), epmd (static `cluster_nodes`), `:none`; the env-var-at-call-time
  design note (`cluster.ex:206-209` — `.env` loads before `cluster_children/0`,
  runtime.exs is too early); `application.ex:483-518` wiring
  (`LeadershipSupervisor`, `:nonode@nohost` warning); lease model summary
  (stamp/renew/claim_next, Pooler drain, Recovery disposition,
  `WorkflowLease.node_identity/0` — delegates through `Cluster.local_node/0`,
  `workflow_lease.ex:107-109`).
- **Config & telemetry** — config keys (`cluster_enabled`/`cluster_strategy`
  defaults `config.exs:186-187`; `cluster_secret`/`JIDOCLAW_CLUSTER_SECRET`,
  `cluster_nodes`, `k8s_*`, `gossip_port`; `workflow_lease` 60/15 +
  `pending_grace_seconds`; `reclaim_pooler` knobs); the **five node-local
  events** (claimed/renewed/reclaimed/fenced_out/recovered) with metadata
  shapes + the node-locality note (why cluster proofs poll the DB); the
  dashboard ownership columns + observe-surface fields (v1.2).
- **Residuals & accepted risks** — the two consciously-deferred watchdogs
  (composer hung-wave C-M3; cron-worker stuck-detection — `WS6:225-234`); the
  sidecar untrappable-kill residual (`sidecar.ex:26-32`).
- **Source map** — backticked refs: `lib/jido_claw/core/cluster.ex:141`,
  `lib/jido_claw/core/cluster.ex:210`, `lib/jido_claw/application.ex:483`,
  `lib/jido_claw/orchestration/workflow_lease.ex`,
  `lib/jido_claw/orchestration/reclaim_pooler.ex`,
  `lib/jido_claw/orchestration/workflow_recovery.ex:780`,
  `config/config.exs:186`.

**AGENTS.md bullet** (after the Executor Seam bullet, `:95`; dense house style —
draft, refine in place):

> - **Clustering & Lease Ownership**: multi-node execution is **off by default**
>   (`cluster_enabled: false`); libcluster starts only when enabled AND
>   distribution is up, across four topologies — `:gossip` (default; **raises
>   without `JIDOCLAW_CLUSTER_SECRET`**), `:kubernetes`, `:epmd`, `:none` — with
>   a layered trust model (gossip secret *encrypts* discovery only; the
>   **distribution cookie gates membership**; Ed25519 peer sigs authenticate
>   messages). Run ownership is a durable DB lease on `WorkflowRun`: a CAS stamp
>   claims, a token-fenced renew heartbeats, a rotated token fences the zombie
>   (kill-before-terminal), and the always-on claim-gated `ReclaimPooler`
>   reclaims expired leases — which is why boot recovery **turns itself off under
>   clustering** (never flip `cluster_enabled` outside the documented checklist).
>   Five node-local lease telemetry events + dashboard/observe ownership fields.
>   Topologies, the flip checklist, invariants, residuals →
>   [docs/system/clustering.md](docs/system/clustering.md)

**Index row** (`docs/system/README.md`): `- [Clustering](clustering.md) —
multi-node topologies, the DB-lease ownership model, and the cluster_enabled
flip checklist`.

**Root `README.md`** (ungoverned): one pointer line after the trust-model
paragraph (~`:891`): "For the run-ownership model, deploy topologies, and the
`cluster_enabled` flip checklist, see
[docs/system/clustering.md](docs/system/clustering.md)."

---

## Item 4 — embedding-counter record + WS6-close bookkeeping

- **`docs/_archive/PLAN-v0.6-memory.md`** — one line in the top Status banner
  (`:3-11`; it already amends shipped-vs-designed deltas — do NOT edit the
  interior prose at `:1740-1743`/`:1825-1827`, per its "kept as the original
  record" policy): the cross-node embedding dispatch counter shipped
  **unconditional**, not `:cluster_enabled`-gated — deliberately kept (correct +
  simpler single-node; a harmless one-row UPSERT per dispatch); decision
  recorded WS6 Phase 4.
- **`docs/plans/clustering/README.md`** coverage matrix: row `:172` (embedding
  counter) → `✅ **WS6** — decision recorded (unconditional kept; see the
  `PLAN-v0.6-memory.md` banner)`; row `:173` (multi-node test harness) →
  `✅ **WS6 shipped** (Phases 1–3)`. Rows `:174-175` (the two watchdogs) stay
  deferred — now also recorded as clustering.md residuals. No other table
  changes (the workstream summary table has no status column; baseline row
  `:72` is already accurate).
- **`docs/plans/clustering/WS6-testing-and-ops.md`** — new `### Phase 4` under
  `## Deviations`, modeled on the Phase 2/3 entries: the three operator-decided
  entries (docs home; both surfaces + SurfaceVersion 1.2; embed counter
  doc-side) + two corrections surfaced at plan review: (a) `reclaimed` already
  shipped — three events to add, not four *(forced by discovery)*; (b) the
  flip-checklist item 5 premise was wrong — MCP mode skips Gateway/Discord and
  boot recovery, not run execution; clustering.md carries the corrected item
  *(operator-surfaced at plan review)*. Log further deviations as they happen.

---

## Cross-cutting implementation notes

- Precommit gotchas (`[[project_precommit_newcode_gotchas]]`): emit helpers stay
  **private** (credo Specs applies to public fns — `fenced_reason/1` is the one
  new public fn and carries `@spec` + `@doc`); no new aliases needed
  (AliasUsage); no comment line beginning with the word "step" (ExSlop wrap
  trap); no bare `rescue`/explicit `try` (attach/detach via `on_exit`);
  `mise exec -- mix format` before the gate.
- **At minimum** two existing tests break silently-until-full-precommit:
  `workflows_live_test.exs:72` (toggle count 5→7) and
  `visibility_test.exs:96-110` (exact key-set) — fix in the same change as the
  source edits. The other touched test files (inspect_workflow, lua_docs,
  telemetry, bootstrap) are deliberate extensions, but check each for
  assertions the new fields disturb.
- **Dates**: stamp every new `verified:` and changelog entry with the actual
  implementation date (the session crossed 2026-07-07 → 2026-07-08 during plan
  review) — never copy a date from this plan.
- The cluster suite (`@moduletag :cluster`) is untouched and stays excluded from
  precommit; its `claimed_by` assertions are DB reads, unaffected.
- After implementation: update memory `[[project_clustering_state]]` (WS6
  complete — the clustering program is closed).

## Verification

1. Targeted first: `mise exec -- mix test
   test/jido_claw/orchestration/lease_telemetry_test.exs
   test/jido_claw/orchestration/visibility_test.exs
   test/jido_claw/web/live/workflows_live_test.exs
   test/jido_claw/orchestration/workflow_view_test.exs
   test/jido_claw/tools/inspect_workflow_test.exs
   test/jido_claw/tools/lua_docs_test.exs
   test/jido_claw/core/mcp_server/served_surface_golden_test.exs
   test/jido_claw/core/mcp_server/resources/bootstrap_test.exs
   test/jido_claw/core/telemetry_test.exs` — bootstrap_test is non-optional
   (the v1.2 changelog names `jido://bootstrap`; pin the surface claim with one
   ownership-field assertion there).
2. Doc gates alone: `mise exec -- mix jidoclaw.system_docs.check` (the new-page
   triad), then `jido_md.check` + `system_prompt.check` (expected: pass,
   untouched).
3. Full gate, bare, in background, read the tail
   (`[[feedback_no_pipe_on_gate_commands]]`): `mise exec -- mix precommit`.
4. Optional eyeball: boot the gateway and view `/workflows` ownership columns
   (render tests are the primary proof; a live run shows `claimed_by`
   populated).

## Files

New:
- `docs/system/clustering.md`
- `test/jido_claw/orchestration/lease_telemetry_test.exs`

Modified (lib):
- `lib/jido_claw/orchestration/workflow_lease.ex` — `fenced_reason/1`
- `lib/jido_claw/orchestration/workflow_lease/sidecar.ex` — renewed/fenced_out
  emits + moduledoc line
- `lib/jido_claw/orchestration/workflow_lease/middleware.ex` —
  claimed/fenced_out(:claim_lost) emits + moduledoc line
- `lib/jido_claw/orchestration/reclaim_pooler.ex` — moduledoc Telemetry pointer
- `lib/jido_claw/orchestration/visibility.ex` — base-map fields + @doc
- `lib/jido_claw/core/telemetry.ex` — five orchestration counters
- `lib/jido_claw/core/mcp_server/surface_version.ex` — 1.2 + changelog
- `lib/jido_claw/web/live/workflows_live.ex` — columns + terminal-blanked
  expiry + colspans + comment
- `lib/jido_claw/tools/inspect_workflow.ex` — allowlist + output_schema fields
- `lib/jido_claw/tools/lua/bindings.ex` — `jido.runs` `returns:` doc

Modified (test):
- `test/jido_claw/orchestration/visibility_test.exs` — key-set + pass-through
- `test/jido_claw/web/live/workflows_live_test.exs` — count 7 + column asserts
- `test/jido_claw/tools/inspect_workflow_test.exs` — ownership fields
- `test/jido_claw/tools/lua_docs_test.exs` — `jido.runs` returns doc (if it
  asserts rendered field lists)
- `test/jido_claw/core/mcp_server/resources/bootstrap_test.exs` — one
  ownership-field assertion (pins the v1.2 `jido://bootstrap` claim)
- `test/jido_claw/core/telemetry_test.exs` — counter measurement + tags
- `test/fixtures/mcp_surface/served_surface.json` — version line

Modified (docs):
- `AGENTS.md` — the Clustering Key Patterns bullet
- `docs/system/README.md` — index row
- `docs/system/mcp-server-surface.md` — v1.2 note
- `docs/ARCHITECTURE.md` — five telemetry table rows
- `README.md` — pointer line in the Clustering section
- `docs/plans/clustering/README.md` — two coverage-matrix rows
- `docs/plans/clustering/WS6-testing-and-ops.md` — Deviations `### Phase 4`
- `docs/_archive/PLAN-v0.6-memory.md` — status-banner line

Suggested commit message (for the operator):
`WS6 Phase 4 — lease observability + ops docs; closes the clustering program`
