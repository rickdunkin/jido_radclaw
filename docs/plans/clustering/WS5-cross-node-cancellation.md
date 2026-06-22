# WS5 — Cross-node cancellation

*Builds: routing a cancel kill to the node that owns the run. Depends on: WS1
(populates `claimed_by`). Closes T2-4's "cluster-correct cancellation" deferral.*

> **What this owns.** The shipped live-run cancellation is a **single-node** kill
> switch; the run registry it kills through is node-local. Under clustering, a
> cancel issued on node A cannot kill a run executing on node B. WS5 routes the
> kill to the owning node (gust's terminator pattern).

## Current state — what's already correct, and what isn't

The shipped cancellation (2026-06-10, `squidie/FEATURES-WORTH-BORROWING.md:294`)
is **durable-decision-first** and that half is already cluster-correct:

- `Cancellation.cancel/2` (`cancellation.ex:90`) appends the durable
  `run_cancelled` event (one transaction with pending-case cancellation) **before**
  any kill. This is a DB write — it works regardless of which node issued it.
- *Then* it does the kill: `RunExecution.lookup/1` → `Process.exit(pid, :kill)`
  (`run_execution.ex:138-144`).

The kill is the node-local part. `RunExecution` registers executors in
`JidoClaw.Orchestration.RunRegistry` — a **node-local `Registry`**
(`run_execution.ex:108`, `application.ex:153`). So `lookup/1` on node A finds only
node A's executors. A cancel for a run executing on node B:

- ✅ **appends `run_cancelled`** (terminal status lands durably), and
- ⚠️ **misses the kill** on node A (`lookup/1` returns `:error`), so node B's
  executor keeps burning until it next tries a status write — at which point the
  cancel-before-register / terminal-reload guard stops it
  (`run_execution.ex:33-42`) or, once WS1 lands, its `Lease` renew notices the
  fence. Either way it eventually stops, but it can waste an LLM/tool call's worth
  of work in the gap.

So WS5 is a **latency/waste fix, not a correctness fix** — the durable decision
already wins. But "kept burning an expensive model call after I cancelled it" is
worth closing.

## Design — route the kill to the owner

Port gust's cross-node cancel (`gust/FEATURES-WORTH-BORROWING.md:119-122`,
`terminator/worker.ex`):

1. `Cancellation.cancel/2` appends `run_cancelled` as today.
2. Read `run.claimed_by` (the owning node name — populated by WS1).
3. If `claimed_by == Node.self()` or nil → local kill, as today.
4. If `claimed_by` is a *remote* node → route the kill there: `send`/`GenServer.cast`
   to a per-node **terminator** process (a tiny named GenServer on each node) that
   runs the local `RunExecution.lookup/1` + `Process.exit(pid, :kill)` and the
   tenant check. Uses the existing libcluster connection — no new transport.

The tenant verification that `Cancellation` does before killing
(`run_execution.ex:134-143`, the registry value is the tenant id) moves to the
terminator on the owning node, so the kill stays tenant-scoped wherever it runs.

## Reuse / current state

- `Cancellation.cancel/2` — `cancellation.ex:90` (durable-decision-first ordering
  is reused verbatim; WS5 only adds kill routing).
- `RunExecution.lookup/1` + `run_killable/4` — `run_execution.ex:138-144,96`
  (the local kill seam each node already has).
- `claimed_by` — `workflow_run.ex:333` (populated by WS1; nil/`Node.self()` →
  local path keeps single-node behavior byte-identical).
- libcluster + `:pg` connectivity — `core/cluster.ex`, `application.ex:411-431`.

## Decisions

- **D1 — terminator addressing.** A per-node named GenServer reached by
  `{name, node}` (gust's approach) vs a `:pg` group of terminators. Recommend the
  named-`{name, node}` form — `claimed_by` already names the exact node, so no
  group lookup is needed.
- **D2 — what if the owner died between append and routing?** The cancel already
  landed durably; the now-dead owner's run is reclaimed by WS3 and will observe
  the terminal status on its reconciliation branch. No special-casing — the
  durable decision plus WS3 reclaim covers it.

## Test plan

- **Local path unchanged** — `claimed_by == Node.self()` (or nil) kills locally;
  single-node behavior identical to today.
- **Remote routing** — `claimed_by` = a remote node routes the kill to that node's
  terminator (mock the terminator single-node; real cross-node is WS6).
- **Durable-decision-first preserved** — `run_cancelled` is appended before any
  routing, even when the owner is unreachable.
- **Tenant scoping** — a cross-tenant cancel is refused at the owning node's
  terminator.

## Cross-references

- T2-4 deferral — `squidie/FEATURES-WORTH-BORROWING.md:294` ("the lease/fencing
  remains what would make cancellation cluster-correct").
- gust cross-node cancel — `gust/FEATURES-WORTH-BORROWING.md:119-122`.
- WS1 ([WS1-lease-core.md](WS1-lease-core.md)) — populates `claimed_by`. WS3
  ([WS3-reclaim-and-recovery.md](WS3-reclaim-and-recovery.md)) — covers the
  owner-died-mid-cancel case.
