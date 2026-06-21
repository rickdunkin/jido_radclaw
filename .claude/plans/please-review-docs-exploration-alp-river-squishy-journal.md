# AR-2 Composer — Phase 2: close the remaining test gaps + certify green

## Context

The user asked whether anything remains in **Phase 2** of the AR-2 Composer (the "Durable
Envelope"), as designed in `docs/exploration/alp-river/AR-2-PHASE-2-DURABLE-ENVELOPE.md`
and `docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md` (§6/§7/§14).

**Finding: the Phase 2 *implementation* is fully landed and faithful to the doc.** All four
sub-phases are committed (`92d63f2` 2a, `9495b19` 2b, `2184f65` 2c, `6bf8e66` 2d) and verified
against the spec:

- **2a/2c/2d (orchestration core):** parent-run lineage + cross-tenant guard; all 17 composer
  event kinds; the projection (incl. the load-bearing `route_rejected`/`route_abandoned`
  *own-clause* disposition lifting and `route_budget_exhausted → :failed` carrying the bound in
  `error`); the composer-state fold (additive + subtractive deltas in `seq` order); the dedicated
  one-transaction commit helper over `[WorkflowEvent, WorkflowRun, ComposerArtifact]`; the
  supervised lifecycle (`DynamicSupervisor` + unique `Registry` keyed by `parent_run_id`,
  `:transient`); and the **real 2d rebuild+resume recovery branch** with both re-launch rules,
  fold-replay, gate-terminal synthesis, and inert-orphaned-`:pending` handling.
- **2b (artifact store + P1 leak closure):** the `ComposerArtifact` encrypted ref-store, the
  versioned no-novel-atom envelope, the Fold/WaveCollect/StageEmission/ArtifactContext/DefaultMapper
  rewiring (in-memory store is `name → producer → ref`), the `replay_inputs`-key omission for
  composer waves, **all seven** leak-closure sinks, and the full `sanitize_sensitive_context`
  marker plumbing (canonical key, durable `RequestCorrelation` field + cache mirror, the widened
  `register_child_correlation/1` with marked-write-failure abort + caller cleanup, the durable
  `deadline_at` / per-wave `:execution_timeout` / `expires_at`-ceiling TTL contract).

The doc's "no deferrals within Phase 2" holds: event kinds whose *producers* live in later phases
(gates → Phase 4, reruns → AR-4) are correctly built and tested at the closed-set + projection +
recovery layer, which is exactly Phase 2's mandate.

**What remains** is small and does **not** need a new design doc:

1. `mix precommit` has not been certified green in this session (it is the user's explicit bar
   for "complete").
2. Two **doc-specified test-coverage gaps** in 2b's leak-closure acceptance criteria. The 2b row's
   "Done when" requires *"Test all three carriers ... cache-hit **and** cache-miss (evict +
   rehydrate) for Recorder and Audit"* and *"a marked composer subagent's tool arguments are
   redacted."* The **implementation is correct** (the marker is re-carried on durable rehydrate in
   all three carriers — `recorder.ex:832`, `signal_listener.ex:157`, `collector.ex:658`), but no
   test locks: (a) the **marker surviving a cache-miss durable rehydrate** for Recorder / Audit /
   Trace, and (b) Audit's **marked-arguments redaction** at all.
3. A **stale comment** at `workflow_recovery.ex:162-170` that calls the composer recovery branch a
   "no-op guard ... until 2d's real rebuild+resume branch" — but the real 2d branch is implemented
   in the same file (`reconcile_branch(:composer, run)` → `resume_composer/1`).

This plan closes (2) and (3), then certifies (1).

---

## Work items

### 1. Add the missing leak-closure tests (the "cache-hit **and** cache-miss" criterion)

The reusable seam for a **marked durable** correlation row in a test:

```elixir
# Writes BOTH the durable RequestCorrelation row (sanitize_sensitive_context: true)
# AND the ETS cache; deleting the cache then forces the durable-rehydrate path.
:ok = JidoClaw.register_correlation(request_id, session.id, tenant, nil, nil,
        sanitize_sensitive_context: true)
JidoClaw.Conversations.RequestCorrelation.Cache.delete(request_id)
```

This mirrors the *unmarked* pattern at `recorder_test.exs:363-373`. Redaction sentinels (from the
existing marked tests): content → `"[composer-sensitive:redacted]"`; map placeholder →
`%{"redacted" => true}` (string-keyed; survives the JSONB round-trip in the audit payload).

> **Test-infrastructure constraints (verified — these shape the seeding, not optional polish):**
> `RequestCorrelation.register/1` **validates `session_id`/`workspace_id` belong to `tenant_id`**
> (`request_correlation.ex:51-56,343-356` via `Session.by_id_global`). So a **cache-miss** test
> that calls `register_correlation` needs a **real persisted `Session`** — a generated UUID or
> bare tenant fails the cross-tenant FK check. (The existing Audit cache-*hit* test gets away with
> a generated `session_id` only because it writes the cache directly and never calls `register/1`.)

- **`test/jido_claw/conversations/recorder_test.exs`** (sink iv) — add **1 test** to the
  `describe "AR-2 Phase 2b — sensitive sanitization (sink iv)"` block: a **marked durable row +
  cache miss** rehydrates the marker so a tool_result is still redacted (`content ==
  "[composer-sensitive:redacted]"`, `metadata == %{"redacted" => true}`). Mirror the existing
  marked test at `:404` but seed via `register_correlation(..., sanitize_sensitive_context: true)`
  + `Cache.delete/1` instead of `Cache.put/2`. This file already seeds a **real** session via its
  own `seed_session/1` helper (`:442`) and already does DB writes, so **no new infra is needed**.

- **`test/jido_claw/audit/signal_listener_test.exs`** (sink v) — add **2 tests** (this file has
  **no** marked coverage today). The file is `use JidoClaw.TenantCase`, so `seed_full/1`
  (`tenant_case.ex:155`, returns tenant+workspace+**session**) is available. Both send a tool
  signal via `build_signal/3` carrying a **unique secret string in `arguments`**, then read the
  persisted `Audit.Event.payload` and assert **both**: (a) the arguments are the
  `SensitiveScrub.redacted_map()` placeholder, via the file's existing key-shape helper —
  `MapKeys.field(payload, :arguments) == %{"redacted" => true}` (or
  `MapKeys.coalesce_field(payload, "arguments")`, matching the `:89` idiom), **not**
  `payload["arguments"]` — and (b) `refute inspect(payload) =~ secret` (the leak assertion makes
  the test's intent hard to accidentally weaken):
  1. **cache-hit marked**: `Cache.put(req, %{..., sanitize_sensitive_context: true})` (cache-only,
     no real session required — may keep `seed_tenant/1`).
  2. **cache-miss marked rehydrate**: `seed_full/1` for a real session, then
     `register_correlation(req, session.id, tenant, workspace.id, nil,
     sanitize_sensitive_context: true)` + `Cache.delete(req)`.
  Reuse the existing `eventually/1` + `Event.read/1` assertion pattern from the cache-hit test at
  `:58`.

- **Trace (sink vi)** — add **1 test**: a **marked durable row + cache miss** digests the span.
  This is the highest-infra item. The marker tests in `collector_test.exs` (`use ExUnit.Case`,
  `persist?: false`, **no DB sandbox owner**) are cache-only (`mark/2` → `Cache.put`, synthetic
  `tenant_id: "trace-tenant"`/`session_id: nil`); the `:410` "unknown" test passes because the
  marker resolves to `:unknown` under the contract **"absent *or* faulting durable read ⇒
  unknown"** — in that no-sandbox file an absent row and a faulting lookup both land there. A real
  marked durable-row lookup needs a sandbox owner + a real persisted session, so:
  **Recommended — put this one test in `test/jido_claw/trace/trace_test.exs`**, which already owns
  the full pattern: `Sandbox.start_owner!(JidoClaw.Repo, shared: true)` (`:18`), the
  drain-before-stop `on_exit` (`H.drain_trace_processes()`, `:32-38` — the global Collector borrows
  the shared connection during ingest), and the `Tenant`/`Session`/`Workspace` aliases for inline
  seeding. There, seed a real session inline, `register_correlation(..., sanitize_sensitive_context:
  true)`, `Cache.delete/1`, fire `[:jido, :ai, :request, :start]` with that `request_id`,
  `H.sync_collector()`, and assert the span **is** digested — mirror the *marked* (cache-hit)
  assertions, the inverse of `collector_test.exs:400`'s unmarked control (`refute event.name ==
  secret`, hex span_id dropped, `event.metadata == %{"redacted" => true}`). *(Acceptable
  alternative: keep it in `collector_test.exs` beside the other marker tests via a `describe`-scoped
  `setup` that starts the owner and drains before stopping it — at the cost of introducing a DB
  sandbox into a previously DB-free file.)*

These four tests assert behavior the code already implements, so they should pass on the first run.
**If any fails, that is a real regression to fix, not an expected flake** — none of these touch the
known async singleton flaky set (per the suite-flaky-tests note).

### 2. Fix the stale recovery comment

**`lib/jido_claw/orchestration/workflow_recovery.ex:162-170`** — reword the comment above
`defp classify(%WorkflowRun{workflow_type: "composer", status: :running}), do: :composer`. It
currently reads as a pre-2d interim ("Until 2d's real rebuild+resume branch, this no-op guard ...
observes, like the `:parked` branch"), which is no longer true. Reword to state that the
`:running` composer head dispatches to the **real** rebuild+resume branch
(`reconcile_branch(:composer, run)` → `resume_composer/1`), keeping the two accurate points: it is
checked on `workflow_type` **first** (so a healthy composer parent is never mis-classified as a
stranded reactor run), and it is scoped to `:running` only (a `:pending` / `:awaiting_approval`
composer falls through to the status heads, so a never-started `:pending` composer is still
correctly failed). Comment-only change; no behavior change.

---

## Verification

Toolchain: run mix via `mise exec -- mix` (OTP 29 / Elixir 1.20 — do **not** pin OTP 28).

1. **Baseline (optional but recommended):** before any edits, confirm the committed tree is green
   so the new tests are added to a known-good base:
   `mise exec -- mix precommit` (run bare in the background; read the output tail — **do not pipe
   through `tail`**, which masks the exit code).
2. **Fast inner loop** on the three changed test files:
   ```
   mise exec -- mix test test/jido_claw/conversations/recorder_test.exs \
     test/jido_claw/audit/signal_listener_test.exs \
     test/jido_claw/trace/collector_test.exs
   ```
3. **Format** the new/edited code: `mise exec -- mix format`.
4. **Full gate (the bar):** `mise exec -- mix precommit` — must end green. The alias runs, in
   order: `jidoclaw.compile_check` (allowlist is empty → effectively `--warnings-as-errors`) →
   `jidoclaw.system_prompt.check` → `deps.unlock --unused` → `format --check-formatted` →
   `reach.check --arch --smells --strict` → `credo --strict` → `dialyzer` → `test`. Keep the new
   test code idiomatic to each file to avoid reach/credo smells (follow the existing helpers and
   `describe` structure already in those files).
5. If a test flake appears in the *full* suite, re-verify the suspect file **in isolation** (not
   at `--seed 0`) before attributing it to these changes — the known flaky set is async singleton
   tests (MCPServer, Prompt, PipelineStore, MultiSandbox), none of which this plan touches.

**Done when:** the four new tests pass and `mix precommit` is green.

---

## Out of scope (deferred by the parent plan's own phasing — *not* Phase 2 work)

These are intentionally not Phase 2 and require no action here: the triage seed (Phase 3), gates in
the composer + `Reactors.PlanGate`/`SafetyGate` + the producers for `wave_paused`/`route_rejected`
(Phase 4), the self-heal rerun producers for `stages_invalidated` (AR-4), MCP observe surface
(Phase 5), and the cluster lease / multi-node reclaim (Phase 6, §10.1). Phase 2 deliberately builds
and tests the *substrate* (event kinds, projection, recovery) for the first three even though their
producers ship later.

---

## Commit guidance (per project policy — do not commit; leave unstaged)

Suggested staging once verified green:
- `test/jido_claw/conversations/recorder_test.exs`
- `test/jido_claw/audit/signal_listener_test.exs`
- `test/jido_claw/trace/trace_test.exs` (or `test/jido_claw/trace/collector_test.exs` if the
  alternative placement is taken)
- `lib/jido_claw/orchestration/workflow_recovery.ex`

Suggested commit message:

```
test: close AR-2 Phase 2b leak-closure cache-miss + Audit marker gaps

Lock the doc-specified "cache-hit AND cache-miss (evict + rehydrate)"
acceptance criterion for the sanitize_sensitive_context marker across all
three lookup carriers, plus Audit's marked-arguments redaction:
- recorder (sink iv): marked durable row survives a cache miss -> redacted
- audit signal_listener (sink v): marked args redacted (cache-hit + miss)
- trace collector (sink vi): marked durable row survives a cache miss -> digested

Also reword the stale workflow_recovery.ex composer-branch comment, which
described a pre-2d "no-op guard" though the real rebuild+resume branch is
implemented in the same file.

No behavior change; the implementation already carried the marker on
durable rehydrate. Phase 2 (2a-2d) implementation was already complete.
```
