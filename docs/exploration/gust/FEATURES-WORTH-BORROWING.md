# Features Worth Borrowing from Gust

Exploration notes — not a plan, not a commitment. Inventory **2026-06-04**; re-verified
**2026-06-11** against both repos (gust unchanged upstream — still 384 commits, latest
2026-05-29; the jido_radclaw side moved a lot — see the dated **Status** notes per entry).

Source: `~/workspace/claws/gust` — **Gust** (author: marciok), "a task orchestration
system designed to be efficient, fast and developer-friendly" — an **Apache Airflow
alternative** for Elixir (the README motivation: "kept what we liked about Airflow and
ditched what we didn't"). An **umbrella** project, ~7k LOC across three Hex packages:

- `apps/gust` — core: a compile-time `Gust.DSL` for DAGs/tasks, DAG parser/loader, a
  hand-rolled OTP execution engine (dag → stage → task workers + supervisors), a
  `quantum` cron scheduler, **distributed execution** (leader election, Postgres
  advisory locks, run claim/pooler, dns_cluster), a `Flows` Ecto context
  (`Dag`/`Run`/`Task`/`Log`/`Secret`), a `cloak_ecto` vault, and a `file_monitor` that
  hot-reloads DAG files.
- `apps/gust_web` — Phoenix LiveView dashboard + JSON API + an **HTTP MCP server**
  (workflow-control tools + DAG-file resources) + `mermaid` DAG diagrams.
- `apps/gust_py` — **Python task execution** via `uv` over a framed-port JSON protocol.

384 commits since 2025-11-27 (latest 2026-05-29); single primary author. Deps:
`ecto_sql`, `postgrex`, `quantum`, `cloak_ecto`, `file_system`, `phoenix_pubsub`,
`dns_cluster`, `req`, `swoosh`. **No Ash.**

Read alongside [`../squidie/REACTOR-ADOPTION.md`](../squidie/REACTOR-ADOPTION.md) — the
one Tier-1 borrow here (distributed claiming) is folded into that doc's §4.11, whose
**data model has since landed** on `WorkflowRun` (columns + global scan indexes); the
lease *behavior* stays deferred until clustering is real. Cross-linked 2026-06-11:
[`../alp-river/FEATURES-WORTH-BORROWING.md`](../alp-river/FEATURES-WORTH-BORROWING.md)'s
AR-2 (the composer) interacts with three borrows here — G1-1 (the lease's unit of claim),
G2-1's open tail (catalog as MCP resources), G3-2/G3-3 (catalog storage choice) — notes
inline per entry.

## Determination (TL;DR)

**Gust is an Airflow competitor / a full platform — not really a Reactor competitor.
Don't adopt it; take one genuinely valuable pattern and two cheap-later ones.**

| Part of gust | As a dependency | What to take |
| --- | --- | --- |
| Core executor (dag/stage/task workers) | ❌ No | Nothing — Reactor wins on every axis |
| **Distributed run-claiming** | ❌ No | **The lease + fence-token + `SKIP LOCKED` + advisory-lock-leader mechanism (G1-1 — the gem; columns since landed, behavior deferred)** |
| `gust_web` (UI + MCP) | ❌ No | The MCP workflow-control-surface *shape* (G2-1 — since largely shipped) |
| `gust_py` (Python via uv) | ❌ No | The framed-port JSON-RPC *protocol* for Forge (G2-2 — still open) |

Gust's *executor* is a hand-rolled, weaker cousin of Reactor — no saga compensation/undo,
no typed step I/O (tasks pass data by re-querying the DB by string name —
`dsl.ex:46-51`), no halt/resume, **hardcoded 3 retries** at `5s·2ⁿ`
(`stage_coordinator/retrying_task.ex`, `task_delayer/calculator.ex`), only stages for
structure. The two late additions (2026-05-28) don't change that calculus: `skip_if` (a
predicate that skips a task and cascade-skips its downstream) and a JSON `params` map on
Run (settable via API/CLI/MCP, read back by re-querying `run.params` — the same
DB-as-databus). It's raw Ecto. jido_radclaw has since **shipped** Reactor + the durable
envelope (squidie T1-1 complete 2026-06-09; Phase 5 read-models/viz 2026-06-10), so
gust's engine is a regression and its platform pieces (cron, dashboard, vault, MCP)
overlap what jido_radclaw already has. But its **distributed run-claiming** is the best
distillation of lease + fence + `FOR UPDATE SKIP LOCKED` I've read in idiomatic Elixir —
the capability the Reactor doc had marked "deferred" (T2-4), since specified as §4.11
with the data model landed.

## Why not adopt gust as a dependency

1. **Ash-vs-raw-Ecto.** `Flows.{Dag,Run,Task,Log,Secret}` are plain Ecto schemas; all
   access is `Repo.get!`/changesets. jido_radclaw is Ash-native.
2. **Executor regression.** Adopting gust's engine over Reactor trades a typed DAG with
   saga/undo/halt-resume for a stringly-typed stage walker with hardcoded retries and
   DB-as-databus. Strictly worse for "agent did things in the world" workflows.
3. **Platform overlap.** Its cron (`quantum`, leader-only), dashboard, cloak vault, and
   MCP server all duplicate things jido_radclaw already has (and jido_radclaw's cron is
   tenant-scoped; gust's is not).
4. **Umbrella shape.** Gust assumes you're standing up a new Phoenix app; it's a product,
   not an embeddable library.
5. **Maturity / deps.** ~6 months, one author; would add `quantum` + a second raw
   `ecto_sql` surface alongside Ash.

## How to read this document

Recommendation axis: **ADOPT-AS-DEP / BORROW-PATTERN / SKIP**. Tiers scoped to this
codebase. Per entry: **Recommendation**, **Where**, **What**, **Gap**, **Why**,
**Adoption sketch**. Cites are accurate to within a few lines; the G1-1 mechanism was
verified firsthand.

---

## Tier 1 — High Impact

### G1-1. Distributed run-claiming: lease + fence token + `SKIP LOCKED` + advisory-lock leader

**Recommendation**: BORROW-PATTERN (the single highest-value lift in the repo). Folded
into [`../squidie/REACTOR-ADOPTION.md`](../squidie/REACTOR-ADOPTION.md) §4.11.

**Where**: `apps/gust/lib/gust/run/claim/repo.ex` (claim + renew), `run/pooler.ex` (poll
loop), `dag/runner/dag_worker.ex` (lease renewal), `leader.ex` + `db_locker/postgres.ex`
(advisory-lock leader election), `dag/terminator/worker.ex` (cross-node cancel), migration
`priv/repo/migrations/20251230160539_add_claim_fields_to_runs.exs`.

**What** (verified firsthand):

- **Claim** (`claim/repo.ex:24-58`): inside a transaction, select one run with
  `lock: "FOR UPDATE SKIP LOCKED"` where `status == :enqueued OR (status == :running AND
  claim_expires_at < now)`, oldest first; stamp `status: :running`, `claimed_by: node`,
  `claim_expires_at: now + lease`, and a fresh `claim_token` (UUID). `SKIP LOCKED` makes
  concurrent pollers across nodes race-free. (Since fix #70, 2026-05-28, the claim query
  also joins the DAG and requires `enabled == true` — claim-time respect for a paused
  flag; keep that in the port.)
- **Fence + renew** (`claim/repo.ex:8-22`): `update_all` sets a new `claim_expires_at`
  **only where `id == ^id AND claim_token == ^token`**, returning the row; `{0, []}` →
  `nil`. The token match is the fence.
- **Lease renewal** (`dag_worker.ex`): the per-run worker renews every 5s; if `renew`
  returns `nil` (someone re-claimed and rotated the token), the worker `:stop`s itself.
  A zombie worker that wakes after its lease lapsed self-terminates without
  double-completing the run.
- **Leader election** (`leader.ex` + `db_locker/postgres.ex:12-20`): a held
  `pg_try_advisory_lock($key)` inside a `Repo.checkout(..., timeout: :infinity)` kept open
  by `Process.sleep(:infinity)`. On node death the connection closes → Postgres releases
  the lock → a follower acquires it (retry every 3s). The leader runs leader-only children
  (the cron scheduler + job loader).
- **Cross-node cancel** (`terminator/worker.ex`): read `run.claimed_by` (a node name) and
  `GenServer.cast({Terminator, run_node}, …)` to that node's locally-named worker.

**Gap in jido_radclaw**: The Reactor doc marked lease/fencing **deferred** (T2-4) — only
sketched as an in-memory idea. jido_radclaw has no durable, crash-surviving work-claiming;
the in-memory lease evaporates with the BEAM.

**Why it matters**: This is the concrete, proven implementation of exactly what the
clustered-tailnet future (argus) needs. Durable (DB is source of truth → the dashboard can
show who owns a run), crash-correct (bounded recovery window = lease length), and ~100
lines. Strictly better than the in-memory lease sketch.

**Adoption sketch**: Add `claimed_by` / `claim_expires_at` / `claim_token` to the durable
`WorkflowRun` resource. `:claim_next` = an Ash read action using
`Ash.Query.lock("FOR UPDATE SKIP LOCKED")` then an update; `:renew` = an update filtered by
`(id, claim_token)`. A `Pooler` GenServer (poll + PubSub-trigger) starts each claimed run's
Reactor under a `DynamicSupervisor`. A `Reactor.Middleware` renews on a timer and halts the
reactor on a stale token. Leader election: port the advisory-lock approach, **or** use the
already-conditional `libcluster` + `:global`/`:pg`. **Tune up gust's defaults**: gust uses
a 15s lease / 5s renew (`:claim_lease_seconds` default 15), which risks double-executing a
slow LLM step — use ~60s lease / 15s renew **plus step-level idempotency keys**, because
double-calling a model/tool is costly.

**Known weaknesses to fix in the port** (don't inherit them):
- Leader advisory lock is purely session-bound → a partition where the leader's TCP
  survives but it's unreachable stalls cron globally (add a heartbeat or use `:pg`).
- No work-stealing / graceful-drain between *actively running* nodes (only dead-node
  recovery). Add a drain-on-shutdown protocol if needed.
- Cron firing isn't idempotent against leader flapping → pair with the envelope's cron
  run-identity (T2-3 / Reactor doc §4.10 — since shipped as `WorkflowRun.idempotency_key`
  + the `cron:<job_id>:<window>` key).

**Status (2026-06-11)**: partially adopted — the **data model shipped**, the behavior is
deliberately deferred. `WorkflowRun` carries `claimed_by` / `claim_expires_at` /
`claim_token` plus the two global (`all_tenants?: true`) scan indexes
(`orchestration/workflow_run.ex:328-341`, `:65-72`) — the adoption sketch's first item,
landed greenfield so there's no later migration; all three stay nil until the lease
ships. The behavior half (`:claim_next`, renew, `Pooler`, lease middleware, leader
election) waits for real clustering (REACTOR-ADOPTION.md §4.11's status). Meanwhile
single-node crash-correctness shipped separately (2026-06-10): a boot reconciler for
stranded runs (`WorkflowRecovery`) plus kill-based live-run cancellation
(`RunExecution.run_killable/4` + `Cancellation`) — the lease is what would make those
cluster-correct.

**Cross-reference (alp-river AR-2, the composer —
[`../alp-river/FEATURES-WORTH-BORROWING.md`](../alp-river/FEATURES-WORTH-BORROWING.md))**:
the sketch above assumes *run = one `Reactor.run`* — the Pooler claims a run and starts
its reactor, the middleware renews, a stale fence halts that reactor. AR-2's composer
breaks the assumption: a composed run is a composer loop spanning N waves, each wave its
own Reactor, with composer state living *between* reactor executions. If AR-2 lands
before clustering, re-derive the lease around that unit — the Pooler starts *composers*;
the composer renews across waves and stops on a stale fence. The payoff is mutual: the
lease makes the composer cluster-correct, and because AR-2's `live`/`available`/`ran`
projects from the `WorkflowEvent` log, a reclaiming node can rebuild composer state and
**resume mid-route** — strictly better than gust's blind re-run. Two corollaries: wave
boundaries multiply reclaim surface, so the step-level idempotency keys above stop being
optional; and gust can't answer the gate question (it has no gates) — the port must
define lease behavior across the park/resume cycle (an `:awaiting_approval` run holds no
lease; `GateResume` re-claims on whichever node resumes). The future AR-2 exploration
doc should own this design point.

---

## Tier 2 — Medium Impact

### G2-1. MCP as a workflow-control surface

**Recommendation**: BORROW-PATTERN (the *shape*, not the code; cheap once Reactor lands).

**Where**: `apps/gust_web/lib/gust_web/mcp/tools/list.ex` (11 tools), `mcp/resources/list.ex`
(DAG files as resources), `mcp/server.ex` (hand-rolled JSON-RPC over HTTP).

**What**: Exposes workflow lifecycle as MCP **tools** (`trigger_dag_run`, `restart_run`,
`restart_task`, `cancel_task`, `query_dag_run`, `get_tasks_on_run`, `get_logs_on_task`,
`get_dag_def`, `toggle_enabled_dag`, `list_dags`, `list_secrets`) and workflow definitions
as MCP **resources** (each DAG file readable by URI). `trigger_dag_run` accepts an
optional `params` object since 2026-05-28. An LLM client gets a clean
discover → inspect → trigger → observe loop.

**Gap in jido_radclaw**: It has an MCP server (`jido_mcp` over stdio) with file/git/code
tools, but no first-class "drive and observe workflows over MCP" surface (no
trigger/restart/cancel/query for runs, no workflow-defs-as-resources).

**Why it matters**: Once Reactor + the envelope land, letting the agent (and external MCP
clients) trigger/inspect/cancel workflow runs over MCP is natural and high-leverage.

**Adoption sketch**: Add tools to `JidoClaw.MCPServer` — `TriggerWorkflow`,
`QueryWorkflowRuns`, `GetWorkflowRunStatus`, `RestartRun`, `CancelStep`, `GetWorkflowLogs`
— and expose Skill/Reactor definitions as MCP resources (`jido://workflows/<id>`). Use the
existing `jido_mcp` substrate; **don't** port gust's hand-rolled JSON-RPC/HTTP server.

**Status (2026-06-11)**: largely shipped with the envelope, with one deliberate
divergence. The MCP `publish` list (`core/mcp_server.ex`) now carries `run_skill`
(trigger: skill → Reactor → tracked `WorkflowRun`), `workflow_status` (tenant-scoped
active + recent runs), and `replay_workflow` (re-run a *terminal* run from its
durably-stored inputs as a **new** tracked run — not gust's reset-in-place restart;
definition-fingerprint + irreversible-steps gates, no overrides). The divergence: gust
hands cancel/restart to MCP clients; jido_radclaw deliberately keeps destructive
controls — live-run cancellation and the replay `force`/`allow_irreversible` overrides —
dashboard-only (`Cancellation`'s moduledoc states it). Still open from the sketch:
per-run logs over MCP, and workflow-defs-as-MCP-resources (`jido://workflows/<id>`) —
the `publish` block exposes tools only, no resources. Both open items converge with
alp-river AR-2 (the composer): its stage catalog (`subscribes`/`publishes`/`routes`) is
exactly what the resource URIs should expose, and `workflow_status` would need to learn
composer state (current wave, held, dropped, live signals) — ship this tail as one piece
when AR-2 lands.

### G2-2. Framed-port JSON-RPC for external runtimes

**Recommendation**: BORROW-PATTERN (the protocol shape; for a future Forge runner).

**Where**: `apps/gust_py/lib/gust_py/executor/uv.ex`, `task_messenger/json.ex`,
`task_worker/adapter.ex`.

**What**: Runs Python via `uv run …` over a `Port.open({:spawn_executable, …}, [{:packet, 4}])`
with a JSON line protocol — message types `log` / `call` / `start` (OS pid) / `result` /
`error`, with synchronous `reply` for lookups. The Elixir side dispatches via a behaviour;
the same `{:task_result, …}` shape is shared with the native Elixir adapter (a clean
per-language `Adapter` seam: `parser` / `runtime` / `task_worker`).

**Gap in jido_radclaw**: Forge sandboxes execution but has no established
"LLM-authored script talks to the host over a typed RPC" protocol (cf. hermes T1-1
programmatic tool calling).

**Why it matters**: A reusable, transport-agnostic primitive for a "RunPythonScript"
Forge runner — the protocol is the keeper.

**Adoption sketch**: Model a Forge runner on the `{:packet, 4}` + JSON-line protocol, but
(a) use a **warm process pool**, not gust's per-task fork-exec (too many cold starts for an
LLM loop), and (b) pass everything the script needs in its initial context — **drop the
synchronous `call`-back-to-host surface** (an LLM script that infinite-loops on a sync DB
call would stall the worker).

**Status (2026-06-11)**: still open. Forge remains CLI-hosted runners only
(`claude_code` / `codex` / `shell` / `custom` / `workflow` + the `sbx` docker sandbox);
no Python runner, no `{:packet, 4}` framed RPC, no warm pool. Hermes T1-1 (programmatic
tool calling — the same gap seen from the other side) is likewise NOT_ADOPTED.

---

## Tier 3 — Polish

- **G3-1. Cross-node command routing — BORROW-PATTERN.** `terminator/worker.ex`: look up
  the owning node from a resource field and `GenServer.cast({Name, node}, …)`. The pattern
  for cancelling a swarm sub-agent on a remote node. ~50 lines. *Still open (2026-06-11):
  cancellation shipped single-node only (`Cancellation.cancel/2` kills the registered run
  task via `RunRegistry`); this cast is the missing clustered half, routing on §4.11's
  `claimed_by`. With alp-river AR-2, "cancel" grows to stop-the-composer + kill the
  current wave's task — same cast, new target.*
- **G3-2. Debounced file-watch — BORROW-PATTERN (dev only).** `file_monitor/worker.ex`'s
  debounced `file_system` subscription is a tidy template for reloading `.jido/skills/*.yaml`
  on change (the skill→Reactor compile loop). Phoenix's reloader covers `.ex`; this covers
  YAML. *Still open (2026-06-11), and cheaper now: `JidoClaw.Skills` is a boot-time
  GenServer cache with a manual `reload/0` (replay already bypasses it via `load_skill/2`) —
  the watcher would just drive `reload/0`. AR-2's stage catalog, if it lands as
  YAML-on-disk, is a second watch target.*
- **G3-3. Disk-of-truth reconciliation — BORROW-PATTERN (small).** `flows.ex` +
  `dag/loader/worker.ex`: on boot, delete DB rows that no longer have a file on disk. Apply
  only where files are canonical (`.jido/{skills,strategies,pipelines}`). *Mostly mooted
  (2026-06-11): cron moved DB-native (the `cron_jobs` table — files aren't canonical there
  anymore), and the file-canonical stores (skills/strategies/pipelines) have no DB mirror
  to reconcile — boot re-parse is the reconciliation. Dormant unless a DB mirror of
  file-canonical defs appears — and alp-river AR-2's catalog is the live candidate: its
  sketch leaves storage open ("Ash data or compiled YAML"); the Ash-data branch would
  un-moot this.*

---

## Skip / Already Covered

- **The hand-rolled executor** (dag/stage/task workers + supervisors, stage coordinator,
  retrying_task, task_delayer, terminator) → **SKIP**. Reactor + `Ash.Reactor` covers all
  of it with saga, halt/resume, typed I/O, and compositional steps.
- **`Gust.DSL` / the `task` macro** → **SKIP**. Reactor's DSL is stronger; skills now
  compile to `Reactor.Builder` (shipped — `JidoClaw.Skills.Compiler`). Adopting it would
  create a fourth orchestration surface.
- **`Gust.Flows` Ecto data layer** → **SKIP** (shape borrowable for the run resource, but
  the raw-Ecto access surface doesn't translate to Ash).
- **`quantum` cron (leader-only)** → **SKIP**. jido_radclaw's `crontab` cron is
  tenant-scoped; only the "cron runs on the elected leader" shape is worth keeping (it
  comes free with G1-1's leader).
- **`gust_web` LiveView dashboard** → **SKIP**. jido_radclaw has its own.
- **Mermaid viz + per-run module recompilation + cloak vault + dns_cluster + the HTTP MCP
  implementation + `gust_py` as a whole** → **SKIP** (jido_radclaw has equivalents, or
  Reactor/`jido_mcp`/`libcluster` cover it).
- **Workflow-graph viz, generally** → resolved (2026-06-10): squidie T3-1 shipped as
  `JidoClaw.Web.Components.GraphLayout` (the SquidSonar port, Apache-2.0 attribution)
  behind a `StepGraph` adapter over the durable `WorkflowStep.depends_on` column — the
  dashboard went with the HTML/CSS layout, not Reactor's Mermaid debug-helper (which
  remains an option for dev-time reactor inspection).

---

## Comparison: gust vs Reactor + envelope

| Capability | gust | Reactor + envelope (shipped 2026-06-08..10) | Winner |
| --- | --- | --- | --- |
| DAG execution | hand-rolled stage/task workers | Reactor (typed args, async, `map`/`switch`/`compose`) | Reactor |
| Saga / undo | none (`upstream_failed` + `skip_if` cascade only) | `compensate`/`undo`, durable Ash undo | Reactor |
| Retry | hardcoded 3× / `5s·2ⁿ` | per-step `max_retries` + backoff | Reactor |
| Pause/resume (human gates) | none (`restart_run` = reset-in-place requeue) | `{:halt}` → resume (gate DSL + approvals) | Reactor |
| Persistence | raw Ecto, DB-as-databus | Ash event log + projection | Reactor/envelope |
| **Distributed claiming** | **lease + fence + `SKIP LOCKED` + leader** | §4.11: columns landed, lease behavior deferred | **gust → borrowed** |
| Scheduling | `quantum`, leader-only | tenant-scoped `crontab` cron + idempotent cron run-identity | jido_radclaw |
| Python tasks | `uv` framed-port runner | Forge (future) | gust pattern usable |
| MCP | HTTP, workflow-control tools | stdio (`jido_mcp`) + `run_skill`/`workflow_status`/`replay_workflow` | shape borrowed (G2-1) |
| Maturity | ~6 mo, 1 author, Ecto | Reactor 1.0.2 via Ash (in-tree) | Reactor |

## Bottom line

Gust is a real, working Airflow alternative — but for an audience (small teams wanting
Python-DAG ergonomics) that isn't jido_radclaw. Don't adopt it. Borrow **one thing that
matters** — the distributed claim/lease/fence mechanism (G1-1), specified in the Reactor
doc §4.11 and half-landed (columns shipped on `WorkflowRun`; lease behavior waits for
clustering) — plus two cheap-later patterns: the MCP control surface (G2-1 — since
largely shipped, with cancel deliberately kept dashboard-only) and the framed-port RPC
for Forge (G2-2 — still open). Everything else is covered better by Reactor + the
envelope (now shipped) or by what jido_radclaw already has.
