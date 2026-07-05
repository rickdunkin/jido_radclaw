# OpenHelm first wave — adoptable now + recorded riders

Companion to [FEATURES-WORTH-BORROWING.md](FEATURES-WORTH-BORROWING.md) (2026-07-04).
Same convention as the orca/pad first-wave docs: only items adoptable **without any
argus slice**, plus riders on already-queued work recorded so they don't slip. Everything
else in the inventory waits for its named slice/trigger.

## 1. Cron failure provenance + circuit breaker (OH1-1) — adoptable now

**Why now**: the gap is live and operator-facing today — a cron job that fails 3 ticks
auto-disables via an in-memory counter (reset by any Owner reconcile/restart), the
disabled row disappears from `:for_tenant` listings, telemetry cannot distinguish a
failed tick from a successful one, and cron emits zero Trace events. No argus dependency;
touches only the cron subsystem.

**Shape** (one PR, or two commits: provenance / breaker):

1. **Provenance**: `Cron.Job` gains `consecutive_failures`, `last_error_class`,
   `last_failure_at`, `paused_until` (distinct from `disabled_at`). Worker classifies
   dispatch results before counting — retryable / rate-limited / infra / terminal (the
   MC1-4 taxonomy split; rate-limited and infra do **not** increment, per OpenHelm's
   `cli-error-monitor.ts` classification rule). Persist on every failure; reset on
   success.
2. **Telemetry honesty**: `status` tag on `cron.job.stop`; emit the exception-equivalent
   for returned `{:error, _}` (today only raises count — `worker.ex:216-235`).
3. **Trace**: first producer for the dormant `:schedule` channel
   (`trace/collector.ex:109`) — tick failures, trips, pauses, auto-resumes.
4. **Breaker**: threshold trip ⇒ set `paused_until` (not `disabled_at`), emit Trace +
   PubSub, and surface an attention row (pending-inbox adjacent). Owner reconcile
   re-arms expired pauses (OpenHelm's auto-recovery lesson: an un-recovered pause once
   cost them a 9-hour fleet outage; bounded re-trip churn is the accepted cost).
5. **Visibility**: disabled/tripped jobs stay listable (`include_disabled?` read arg or
   a `:for_tenant_all`); `/gates`-style REPL + dashboard read.

**Open decision at pickup**: OQ-3 — columns on `Cron.Job` vs a separate per-job health
resource.

## 2. Riders on already-queued work (record-only, land inside their items)

- **next-ten #5 (deterministic verify authority)** ← OH1-3: give the judge **read-only
  deterministic tools** rather than transcript-only input (our `lua_query` is the
  natural vehicle — sandboxed, lexical-only, tenant-scoped); cap the judge and force a
  committed verdict at the cap (OpenHelm `run-verifier.ts:42-64` — never a silent
  failure).
- **next-ten #6 (honest terminal statuses)** ← OH1-3: the `partially_succeeded` /
  `permanent_failure` split with an enforced transition table
  (`db/queries/runs.ts:48-57`) is the field shape; `succeeded` accepts no further
  transitions.
- **next-ten #9 (structured premises / acceptance criteria)** ← OH1-3: reserve
  `outcome_spec`-shaped fields (`endState` / `check` / `stopBound`) for cron/automation
  producers — OpenHelm makes the contract **required at creation** for agent-created
  jobs; that's the enforcement point, not review time.
- **next-ten #10 (evidence floor)** ← OH1-3: claimed-vs-observed (`verifiedDelta`
  in `planner/schemas.ts:142-185`) as the sharpest single check; count fabrication
  breaches, don't just demote the run. Compaction guard: suppress log-count-based
  demotion on compacted transcripts.
- **Slice-6 CLI adapter reading list** ← OH2-3 + OH2-5: the `--disallowed-tools`
  platform-competing deny-list (scheduling/skills/slash-commands); MCP preflight with
  min-tool-count gates; `ENABLE_TOOL_SEARCH=false` when injecting `--mcp-config`
  (tool-search deferral broke every MCP job — their 2026-06-04 root cause);
  `--strict-mcp-config`; prompt via stdin; process-group SIGTERM→SIGKILL with 5s grace
  (`runner.ts:782-811` — the CH-FIRST-WAVE process-killer datapoint, now at file:line).
- **WS3 reclaim test case** ← OH3-2: rolling-deploy overlap — a rejoining node must not
  reclaim runs whose lease is healthy merely because the node just booted.
