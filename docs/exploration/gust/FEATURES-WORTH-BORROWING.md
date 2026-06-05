# Features Worth Borrowing from Gust

Exploration notes — not a plan, not a commitment. Inventory **2026-06-04**.

Source: `~/workspace/claws/gust` — **Gust** (author: marciok), "a task orchestration
system designed to be efficient, fast and developer-friendly" — an explicit **Apache
Airflow replacement** for Elixir (the README motivation says so). An **umbrella**
project, ~7k LOC across three Hex packages:

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
one Tier-1 borrow here (distributed claiming) is folded into that doc's §4.11.

## Determination (TL;DR)

**Gust is an Airflow competitor / a full platform — not really a Reactor competitor.
Don't adopt it; take one genuinely valuable pattern and two cheap-later ones.**

| Part of gust | As a dependency | What to take |
| --- | --- | --- |
| Core executor (dag/stage/task workers) | ❌ No | Nothing — Reactor wins on every axis |
| **Distributed run-claiming** | ❌ No | **The lease + fence-token + `SKIP LOCKED` + advisory-lock-leader mechanism (G1-1 — the gem)** |
| `gust_web` (UI + MCP) | ❌ No | The MCP workflow-control-surface *shape* (G2-1) |
| `gust_py` (Python via uv) | ❌ No | The framed-port JSON-RPC *protocol* for Forge (G2-2) |

Gust's *executor* is a hand-rolled, weaker cousin of Reactor — no saga compensation/undo,
no typed step I/O (tasks pass data by re-querying the DB by string name —
`dsl.ex:46-51`), no halt/resume, **hardcoded 3 retries** at `5s·2ⁿ`
(`stage_coordinator/retrying_task.ex`, `task_delayer/calculator.ex`), only stages for
structure. It's raw Ecto. Since jido_radclaw is adopting Reactor + the durable envelope,
gust's engine is a regression and its platform pieces (cron, dashboard, vault, MCP)
overlap what jido_radclaw already has. But its **distributed run-claiming** is the best
distillation of lease + fence + `FOR UPDATE SKIP LOCKED` I've read in idiomatic Elixir,
and it's exactly the capability the Reactor doc marked "deferred" (T2-4).

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
  concurrent pollers across nodes race-free.
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
  run-identity (T2-3 / Reactor doc §4.10).

---

## Tier 2 — Medium Impact

### G2-1. MCP as a workflow-control surface

**Recommendation**: BORROW-PATTERN (the *shape*, not the code; cheap once Reactor lands).

**Where**: `apps/gust_web/lib/gust_web/mcp/tools/list.ex` (11 tools), `mcp/resources/list.ex`
(DAG files as resources), `mcp/server.ex` (hand-rolled JSON-RPC over HTTP).

**What**: Exposes workflow lifecycle as MCP **tools** (`trigger_dag_run`, `restart_run`,
`restart_task`, `cancel_task`, `query_dag_run`, `get_tasks_on_run`, `get_logs_on_task`,
`get_dag_def`, `toggle_enabled_dag`, `list_dags`, `list_secrets`) and workflow definitions
as MCP **resources** (each DAG file readable by URI). An LLM client gets a clean
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

---

## Tier 3 — Polish

- **G3-1. Cross-node command routing — BORROW-PATTERN.** `terminator/worker.ex`: look up
  the owning node from a resource field and `GenServer.cast({Name, node}, …)`. The pattern
  for cancelling a swarm sub-agent on a remote node. ~50 lines.
- **G3-2. Debounced file-watch — BORROW-PATTERN (dev only).** `file_monitor/worker.ex`'s
  debounced `file_system` subscription is a tidy template for reloading `.jido/skills/*.yaml`
  on change (the skill→Reactor compile loop). Phoenix's reloader covers `.ex`; this covers
  YAML.
- **G3-3. Disk-of-truth reconciliation — BORROW-PATTERN (small).** `flows.ex` +
  `dag/loader/worker.ex`: on boot, delete DB rows that no longer have a file on disk. Apply
  only where files are canonical (`.jido/{skills,strategies,pipelines}`).

---

## Skip / Already Covered

- **The hand-rolled executor** (dag/stage/task workers + supervisors, stage coordinator,
  retrying_task, task_delayer, terminator) → **SKIP**. Reactor + `Ash.Reactor` covers all
  of it with saga, halt/resume, typed I/O, and compositional steps.
- **`Gust.DSL` / the `task` macro** → **SKIP**. Reactor's DSL is stronger; skills compile
  to `Reactor.Builder`. Adopting it would create a fourth orchestration surface.
- **`Gust.Flows` Ecto data layer** → **SKIP** (shape borrowable for the run resource, but
  the raw-Ecto access surface doesn't translate to Ash).
- **`quantum` cron (leader-only)** → **SKIP**. jido_radclaw's `crontab` cron is
  tenant-scoped; only the "cron runs on the elected leader" shape is worth keeping (it
  comes free with G1-1's leader).
- **`gust_web` LiveView dashboard** → **SKIP**. jido_radclaw has its own.
- **Mermaid viz + per-run module recompilation + cloak vault + dns_cluster + the HTTP MCP
  implementation + `gust_py` as a whole** → **SKIP** (jido_radclaw has equivalents, or
  Reactor/`jido_mcp`/`libcluster` cover it).
- **Workflow-graph viz, generally** → note: Reactor's own docs include Mermaid
  visualization guidance (a `visualize_reactor` debug-helper pattern), which likely covers
  workflow viz with minimal code — **this also weakens the SquidSonar graph-layout borrow
  (squidie T3-1)**. Check Reactor's viz story before porting either.

---

## Comparison: gust vs Reactor + envelope

| Capability | gust | Reactor + envelope (the plan) | Winner |
| --- | --- | --- | --- |
| DAG execution | hand-rolled stage/task workers | Reactor (typed args, async, `map`/`switch`/`compose`) | Reactor |
| Saga / undo | none (`upstream_failed` only) | `compensate`/`undo`, durable Ash undo | Reactor |
| Retry | hardcoded 3× / `5s·2ⁿ` | per-step `max_retries` + backoff | Reactor |
| Pause/resume (human gates) | "delete & recreate run" | `{:halt}` → resume | Reactor |
| Persistence | raw Ecto, DB-as-databus | Ash event log + projection | Reactor/envelope |
| **Distributed claiming** | **lease + fence + `SKIP LOCKED` + leader** | deferred → now specified (§4.11) | **gust → borrowed** |
| Scheduling | `quantum`, leader-only | tenant-scoped `crontab` cron | jido_radclaw |
| Python tasks | `uv` framed-port runner | Forge (future) | gust pattern usable |
| MCP | HTTP, workflow-control tools | stdio (`jido_mcp`) | shape borrowable |
| Maturity | ~6 mo, 1 author, Ecto | Reactor 1.0.2 via Ash (in-tree) | Reactor |

## Bottom line

Gust is a real, working Airflow replacement — but for an audience (small teams wanting
Python-DAG ergonomics) that isn't jido_radclaw. Don't adopt it. Borrow **one thing that
matters** — the distributed claim/lease/fence mechanism (G1-1), now specified in the
Reactor doc §4.11 — plus two cheap-later patterns (MCP control surface G2-1, framed-port
RPC for Forge G2-2). Everything else is covered better by Reactor + the envelope or by what
jido_radclaw already has.
