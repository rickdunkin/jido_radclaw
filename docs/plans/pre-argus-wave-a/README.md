# Plan: pre-argus Wave A — execution substrate (items #1–#4)

*Approved 2026-07-11. Executes the first wave of
[the pre-argus do-now queue](../pre-argus-do-now/README.md): **#1 run-failure
taxonomy → #2 native CLI session resume (+ #3 transcript honesty riding it) →
#4 exit-code tiering**. All four land commit-ready but uncommitted;
`mix precommit` green is the completion bar; greenfield — no compat shims, no
DB migration anywhere.*

**Status (2026-07-11): all four items BUILT** — #1, #4, and the PORT gate in
the first sessions; #2+#3's thirteen build slices completed across three
sessions (fence + codecs + armed runners, then harness integration, the
consolidator driver rebuild, ChildTracker/terminate_tree, EM3-3 markers, the
[forge-session-resume](../../system/forge-session-resume.md) page, and
reconciliation). Deviations below are the authoritative build-vs-plan record.

**Operator decisions (interviews, 2026-07-11):**

1. Resume scope is the fullest cut: runner machinery + crash-recovery +
   `apply_input` continuation + the memory consolidator converted to a true
   multi-iteration driver (it is single-shot at HEAD — `run_server.ex:465`;
   reconciliation records the falsified source claim).
2. Exit codes: 2 keeps usage+validation+config; **4 = not-found,
   5 = provider-unreachable, 6 = provider-auth**.
3. Group-kill: `kill_tree/1` stays the house mechanism; add a graceful window
   for host-tier runner teardown and a VM-shutdown ChildTracker.

**Hard gates:**

- **PORT-map sign-off**: `docs/exploration/pms/multica/PORT-MC1-1.md` written
  and explicitly signed off **before any #2 code**
  (docs/exploration/README.md anatomy). #1/#3/#4 are rubric lifts / deliberate
  divergence — no map.
- This doc's `## Deviations` section is maintained as work proceeds (what the
  plan assumed, what the code revealed, what was chosen and why, forced vs
  surfaced).

---

## Item #1 — `JidoClaw.Orchestration.RunFailure` (MC1-4 + OR3-2 + BO2-3 riders)

### Module `lib/jido_claw/orchestration/run_failure.ex`

Mirrors `orchestration/verdict.ex` conventions: provenance header comment
(multica MIT, failure.go/classify.go + riders), bounded rendering
(`@inspect_opts [limit: 5, printable_limit: 120]`, `@max_reason_graphemes 240`),
whitelist decode, never `String.to_atom`. Sits ABOVE `Forge.Error.classify/1`
(its `{kind, recovery}` contract is pinned — compose, never break).

```elixir
@type kind :: <22-atom union>
classify(term) :: kind            # TOTAL — see totality contract below
failure?(kind) :: boolean         # false ONLY for :user_cancelled
retryable?(kind) :: boolean       # retry-the-WORK — independent of…
resume_unsafe?(kind) :: boolean   # …reuse-the-CONVERSATION
provenance(kind) :: :platform | :agent
all_kinds() :: [kind]             # closed set; telemetry pre-warm + totality tests
decode(String.t) :: {:ok, kind} | :error
format_reason(kind, term) :: String.t
error_details(kind, extra) :: map # %{failure_kind: kind, retry: retryable?(kind)}
                                  # merged over extra AFTER stripping reserved keys in
                                  # BOTH atom and string forms (:retry/"retry",
                                  # :failure_kind/"failure_kind", :reason/"reason")
```

**Totality contract**: the entire public bodies of `classify/1` and
`format_reason/2` are wrapped in a final `rescue`/`catch` (exceptions,
**throws, and exits**) falling back to `:agent_unknown` / a bounded fallback
string. Inner extraction (`Exception.message/1` on hostile exceptions,
`String.downcase/1` on invalid UTF-8 via a `String.valid?/1`-guarded
`safe_downcase/1`) is additionally guarded so the fallback is the backstop,
not the mechanism.

### The 22-kind enum

Adapted from multica's 21: DROP `queued_expired`/`runtime_offline`/
`runtime_recovery` (daemon members) and `agent_blocked` (their producer-less
wart); RENAME `timeout` → `stalled_wall_clock`; ADD `stalled_no_output`,
`user_cancelled`, `agent_fallback_message`, `agent_semantic_inactivity`,
`agent_session_poisoned`.

**Platform (unprefixed)**

- `iteration_limit` — ¬retry, resume-unsafe. Producer = the iteration BOUND
  only: `Forge.run_loop`'s `:max_iterations_reached` reworked to carry it +
  the consolidator loop's bound arm. Deadline exhaustion is
  `stalled_wall_clock`, never this.
- `api_invalid_request` — ¬retry, resume-unsafe (400 baked into history).
- `stalled_wall_clock` — retry. Producers: `"harness_timeout"`
  (claude_code/codex), sandbox `{_, :timeout}`, exit 124, run-deadline
  exhaustion.
- `stalled_no_output` — retry. **Producer-pending** (no silence watchdog
  exists; Wave B #8 registers the composer-level stall).

**Non-failure**: `user_cancelled` (`failure?` false; producers:
`cancellation.ex` `run_cancelled`, Forge `:cancelled` phases).

**Agent (`agent_` prefix)**: `agent_provider_auth_or_access` (→ exit 6) ·
`agent_provider_quota_limit` · `agent_provider_capacity_or_rate_limit` ·
`agent_provider_server_error` · `agent_provider_network` (→ exit 5) ·
`agent_timeout` · `agent_process_failure` ·
`agent_empty_or_unparseable_output` · `agent_context_overflow` ·
`agent_missing_config` · `agent_model_not_found_or_unavailable` ·
`agent_runtime_version_unsupported` (producer-pending) ·
`agent_runtime_missing_executable` (exit 127, `"runner_unavailable"`) ·
`agent_fallback_message` (¬retry, resume-unsafe; producer = #2's ≤320-char
fallback-marker detection) · `agent_semantic_inactivity` (retry ∧
resume-unsafe) · `agent_session_poisoned` (retry ∧ resume-unsafe; bosun's
codex family + the recognized invalid-anchor rejection class) ·
`agent_unknown` (total fallback).

Derived sets: retryable = {stalled_wall_clock, stalled_no_output,
agent_semantic_inactivity, agent_session_poisoned}; resume_unsafe =
{iteration_limit, agent_fallback_message, api_invalid_request,
agent_semantic_inactivity, agent_session_poisoned}. The overlap is the point
of two independent predicates. The narrow retryable set is a conservative
multica-faithful default and a consumer policy seam — NOT justified by "HTTP
retries already happened" (false for Anthropic 5xx in the current stack).

### classify/1 — rule order

1. Unwrap `{:error, r}` → recurse.
2. Cancels (`:cancelled`, `:run_cancelled`, `{:cancelled, _}`,
   `%{status: :cancelled}`) → `user_cancelled`.
3. **Nested-cause unwrapping before generic wrappers, depth-bounded (3)**:
   `JidoClaw.Error.ExecutionError` (and peer wrappers) first digs known nested
   causes — `details.cause` / `details["cause"]` — and classifies the nested
   leaf when specific. **Splode class containers**: classify every leaf, then
   pick by an **explicit precedence rank over kinds** (order-invariant): auth >
   quota > rate > api_invalid_request > model > server > network >
   session_poisoned > context_overflow > timeout-kinds >
   missing_config/missing_executable > empty_output > process_failure >
   unknown. Permutation tests pin it.
4. Struct clauses: `Jido.AI.Error.API.{Auth, RateLimit}`;
   `Jido.AI.Error.API.Request` dispatching on its `kind` field;
   `%ReqLLM.Error.API.Request{}` by status (401/403→auth, 429→rate,
   400→api_invalid_request, 404→model, 5xx→server), nil status →
   `cause`-dispatch; `%ReqLLM.Error.API.Response{}` by status, nil →
   agent_empty_or_unparseable_output; `Jido.Error.TimeoutError` AND
   `Jido.Action.Error.TimeoutError`; first-party leaves; Forge Splode structs
   → compose via `Forge.Error.classify/1`; any other exception → string arm
   via guarded message extraction.
5. Tuples/atoms: `{_, :timeout}` → stalled_wall_clock; `{_, :output_limit}` →
   agent_process_failure; `{_, 124}` → stalled_wall_clock; `{_, 127}` →
   agent_runtime_missing_executable; `{_, int}` → agent_process_failure;
   `{:fallback_marker, _}` → agent_fallback_message; `{:iteration_limit, _}` /
   `:max_iterations_reached` → iteration_limit; `:unauthorized` → auth;
   `:unreachable` → network.
6. String arm: `safe_downcase/1`, ordered `@string_rules`; numeric codes only
   boundary-safe (`~r/\b401\b/`-class) with negative tests.
7. `_ → :agent_unknown`.

### Consumers (control flow UNCHANGED — enrich, never redecide)

- **Forge harness `:error` arm**: classify once; broadcast becomes
  `{:error, %{reason: result.error, kind: kind}}` (subset-match consumers
  verified); `Telemetry.emit_run_failure(kind, provenance)`; `failure_kind`
  added to the existing `log_event("iteration.completed", …)` metadata.
- **Composer Lane-B**: kind computed beside
  `Verdict.format_reason({:wave_execution_failed, reason})`, threaded into the
  **non-durable Trace only** via an optional 4th arg to
  `emit_infra_observability/3` — durable `stage_infra` markers/event shapes
  untouched.
- **Telemetry**: `counter("jido_claw.run_failure.total", tags: [:kind,
  :provenance])` + `emit_run_failure/2`. `all_kinds/0` is the pre-warm export
  (no reporter harness exists — residual, documented).
- **Envelope helper**: `error_details/2` ships here, consumed by #2's runner
  terminal errors.

### Docs + reconciliation

New page `docs/system/run-failure.md` + index row + AGENTS.md Key Patterns
bullet — atomic. `docs/TRUST-BOUNDARIES.md` gains a "Retry ≠ resume" section.
`verdict-normalizer.md` cross-link sentence + `verified:` bump. Reconciliation
(dated Status lines): MC-FIRST-WAVE item 1; multica FWB MC1-4; OR-FIRST-WAVE
item 3 back-ref + orca FWB OR3-2; bosun FWB BO2-3 (taxonomy half); pre-argus
README row #1/§1.

---

## GATE: PORT-MC1-1.md + sign-off (before any #2 code)

Header (entry link, multica `129efb768` + jido_radclaw HEAD, date); source
mechanism summary; side-by-side shapes; behaviors table
**preserved / deliberately changed / dropped** — the load-bearing
changed/dropped rows: claude anchor client-minted via `--session-id`
pre-spawn; codex anchor only-after-clean-exit (CH2-6); **retry authorization
driver-side against a server-authoritative effect ledger**; epoch/token
fencing (no multica equivalent); recovery owner = RunServer for
consolidations; crash-native-resume scoped to `:local` sandboxes; kill_tree +
preserved-set graceful phase, not setsid; stderr merged not tailed;
runtime-pinning dropped. Edge cases vs their test names. Sign-off via
AskUserQuestion; #4 may proceed during any wait.

---

## Items #2+#3 — Forge native CLI session resume + transcript honesty

See the approved plan body (this doc's source): ResumeState opaque struct;
epoch+token fencing with the locked select+mint CAS; `current_checkpoint_id`
pointer authority through one loader; recovery lifecycle matrix; RunServer as
consolidation recovery owner (materialize-then-persist config, checked initial
checkpoint, `recovery_degraded` self-healing, cross-owner teardown handshake,
`:local`-scoped crash-native-resume); harness-crash replay policy table;
attempt-bound effect ledger (reserve-then-execute, close-then-evaluate,
driver-only retry authorization); publish gate with durable commit certificate
+ three-outcome reconciliation; deadline budgets (`max_run_ms` 660_000,
derived facade await); two-authority recovery codecs; checked guidance
lifecycle (pending → inflight → consumed, encrypted at rest,
infrastructure-only for vendor runners this build); arming/argv tables for
claude + codex; harness changes; Session `anchor_resume` + mint actions;
ChildTracker + `terminate_tree` preserved-set graceful teardown; env denylist;
`ResumeSignal.emit_failed/2` loud failure; transcript `source: :live | :replay`
markers; consolidator multi-iteration loop.

Docs: new page `docs/system/forge-session-resume.md` + index + AGENTS.md
bullet — atomic; `executor-seam.md` surgical edit. Reconciliation: pre-argus
README rows #2/#3; MC-FIRST-WAVE item 2; multica FWB MC1-1; chorus
CH-FIRST-WAVE item 3 + FWB CH2-6/CH3-2; symphony FWB SY3-3; bosun FWB BO2-3
(poisoned-list half); herdr FWB HD2-2; cmux FWB CM2-3; myrlin FWB; emdash FWB
EM3-3.

---

## Item #4 — exit-code tiering for `mix jidoclaw run` (MC3-4, adapted)

Table: 0 success (`done_with_findings` stays 0, marked) · 1 generic
error/failed/timeout · 2 usage+validation+config (unchanged —
**foreign-workspace stays here**) · 3 human-input (gate|clarify, unchanged) ·
**4 not-found** · **5 provider-unreachable** · **6 provider-auth**.

`cli/run_command.ex`: widen both `@type`s; moduledoc table. **Exit 4
discriminates Ash leaves on BOTH resolver branches** (by_id and `--continue`):
malformed UUID → 2; NotFound-class → 4; DB/framework shapes → 1. Provider
tiers at the generic `{:error, reason}` arm only via `RunFailure.classify/1`
(auth → 6, network → 5, else 1); `await_outcome` `{:done, :failed, run}` stays
1 (deliberate non-goal). JSON envelope generic (`"ok" => exit_code == 0`
holds). No `--help` flag exists — the moduledocs ARE the help: update
`lib/mix/tasks/jidoclaw.ex`, `cli/main.ex`, and the test moduledoc.

Docs: ambiguity-clarify.md claims stay true → `verified:` bump only.
Reconciliation: MC-FIRST-WAVE item 3 (Status + correct the stale "exits 0/1
only" claim + restore the missing `## 3.` header); multica FWB MC3-4;
pre-argus README row #4/§4; unadopted-next-ten README "extended 0–6 by
Wave A" note.

---

## Implementation order

0. This doc.
1. **#1**: run_failure.ex → tests → telemetry → harness consumer → composer
   consumer → docs → reconciliation.
2. **PORT-MC1-1.md → sign-off** (#4 may run while waiting).
3. **#2+#3**: env denylist → ResumeState → fence/mint/actions →
   materialize_config + codecs + pointer loader → claude armed → codex armed →
   ResumeSignal/poison/fallback-marker → harness → RunServer → ChildTracker +
   terminate_tree → markers → docs → reconciliation.
4. **#4**: run_command → tests → moduledocs → reconciliation.
5. **Final**: `mise exec -- mix precommit` bare in background; flakes verified
   in ISOLATION before blaming changes; iterate to green.

## Suggested commit slicing (operator commits; nothing staged by the agent)

1. `feat: run-failure taxonomy (MC1-4 + OR3-2/BO2-3 riders)` — #1.
2. `docs: PORT-MC1-1 semantics map` (signed off).
3. `feat: native CLI session resume for Forge runners (MC1-1 + riders, EM3-3)` — #2+#3.
4. `feat: exit-code tiers 4-6 for mix jidoclaw run (MC3-4)` — #4.

## Deviations

*(Maintained as work proceeds — what the plan assumed, what the code revealed,
what was chosen and why; surfaced-decision vs forced-correction marked per
entry.)*

- **#1 — timeout-phase wrappers dispatch before the cause dig** (forced
  correction, 2026-07-11). The plan ordered "dig `details.cause`, then phase
  dispatch" for `ExecutionError`. The code revealed `Normalize.Common.
  timeout_error/3` stores the raw `{:timeout, ms}` tuple in `details.cause`,
  so a dig-first order would classify EVERY Normalize-built timeout wrapper
  `stalled_wall_clock` and dead-code the forge-vs-agent operation split. A
  `:timeout`-phase wrapper is timeout-specific by construction, so it now
  dispatches on `details.operation` BEFORE the generic dig; all other phases
  dig first as planned.
- **#1 — hostile-Inspect totality row reshaped** (forced correction,
  2026-07-11). The plan's format_reason test wanted a raising `Inspect` impl;
  the protocol is consolidated in test env (a test `defimpl` is inert) and
  `Kernel.inspect` defaults to safe rendering (`#Inspect.Error<…>` instead of
  raising), so the rescue backstop is unreachable via Inspect. The row now
  pins bounded output on a malformed `%{__struct__: Range}` shape; the
  rescue/catch wrapper stays as belt-and-suspenders.
- **#4 — injected-DB-read-failure rows moved to the discrimination seam**
  (forced correction, 2026-07-11). The plan wanted CLI-level "injected read
  failure → exit 1" rows for both resolver branches. No mocking library
  exists in the project and `TenantCase`'s shared sandbox owner cannot be
  killed mid-test without failing its own `on_exit` teardown — there is no
  clean DB-failure injection seam. The 4-vs-1 discrimination is instead
  pinned where the branch decision actually lives: `AshErrors.not_found?/1`
  unit rows with the real error shapes (a REAL `Session.by_id` miss ⇒ true;
  connection/ownership/mixed-container shapes ⇒ false), plus the CLI-level
  4-path rows against the real DB. The `{:error, non-miss}` → exit-1 mapping
  is structural (`error_result/1` default).
- **#2 — the anchor fence rides INSIDE the atomic expression, not a
  changeset filter** (forced correction, 2026-07-11). The plan specified
  "filter-guarded atomic update" via `Ash.Changeset.filter/2` in the change.
  Probe-verified on ash 3.29.3: a filter added from a change's `atomic/3` is
  SILENTLY DROPPED on the atomic-upgrade path — `record_added_filter` only
  records in the `:pending` phase (changes never run there), and
  `Ash.Actions.Update` overwrites the rebuilt changeset's `filter` with the
  original's never-recorded `added_filter`, so the emitted UPDATE's WHERE
  carried only pk+tenant and a bogus token landed. The fence semantics are
  unchanged but the mechanism is now the `OptimisticLock` idiom: the token
  (+ revision) check is a CASE inside the atomic jsonb expression whose else
  branch is `error(Ash.Error.Changes.StaleRecord, …)`. Bonus alignment:
  ash_postgres savepoint-wraps error-capable atomic updates
  (`with_savepoint/3` on `has_error?`), so a fence miss inside the checked
  checkpoint transaction rolls back to the savepoint and the transaction
  stays usable — which is what lets refusals stay tagged success values.
- **#2 — checked checkpoint save is pointer-FIRST under a pre-minted row id**
  (surfaced refinement, 2026-07-11). The plan said "creates the Checkpoint
  row AND sets the pointer in one transaction". Order within that
  transaction is now: mint the checkpoint UUID client-side → token-fenced
  pointer write (naming the not-yet-created id) → `create_recovery` row
  create under that exact id (the ConsolidationRun named-pk-argument
  pattern, no broad `accept :id`). A stale refusal therefore writes NOTHING
  (no row to roll back), which keeps the refusal a tagged success value
  instead of a rollback whose reason `Ash.transaction` wraps opaque (the
  GateDisposition-documented behavior).
- **#2 — FOR-UPDATE locked read composes manually, not via DSL prepare**
  (forced correction, 2026-07-11). A `read` action carrying
  `prepare(build(lock: "FOR UPDATE"))` returns ZERO rows for an existing
  row on this Ash version (probe: no SQL even emitted), while
  `Session.query_to_by_name_global/1 |> Ash.Query.lock("FOR UPDATE")`
  emits the expected locked SELECT. The mint's critical-section read uses
  the composed form (which also satisfies AshCredo's prefer-code-interface
  check via the generated query builder).
- **off-plan — reach gate was red at HEAD in `mcp/consumer.ex`** (forced
  correction, 2026-07-11). `mix reach.check --smells` (reach ~> 2.2, post
  deps-bump) flags `Map.keys/1 → Enum.filter` in
  `Consumer.publish_transition_policy/1` — a committed, unmodified file;
  Wave A's precommit bar cannot pass over it. Fixed in place (iterate the
  map as `{key, value}` pairs); `consumer_test.exs` 46/46 green.
- **#2 — the runner-config codec engages on the STAMP, not the runner type**
  (surfaced refinement, 2026-07-11). The plan named refuse-on-missing for
  vendor configs but left the unstamped case implicit.
  `RecoveredSpec.runner_config/1` dispatches purely on the `config_codec`
  stamp: stamped ⇒ strict typed decode (security-critical fields refuse on
  missing/invalid; unknown runner/version refuses), unstamped ⇒ byte-exact
  pass-through (the shell/workflow/custom/fake lane — the pinned :149 test
  keeps holding). Enforcement that vendor sessions are ALWAYS stamped lives
  at session start (slice 8's materialize-then-persist), not at decode. The
  decoded output deliberately KEEPS the stamp: the recovery claim re-persists
  the typed config through `session_attrs/2`, and the Nth recovery must
  decode it again — a stamp-stripping decode would silently downgrade the
  second recovery to the pass-through lane with string keys.
- **#2 — the armed-row epoch rule reads PRESENT copies; recoverable?/1 is
  @doc false public** (surfaced refinement, 2026-07-11). The lifecycle
  matrix's "claimed + armed" and "claimed + resume off" rows are one
  mechanism in `Manager.recoverable?/1`: every PRESENT resume-state copy
  (session metadata + pointed checkpoint snapshot) must carry the current
  `forge_recovery.epoch` stamp; a copy-less (resume-off) session degenerates
  to pointer + ownership alone — no explicit armed bit needed, and fenced
  writes make a mismatch corruption by construction. The handoff's open
  decision (epoch from snapshot vs checkpoint metadata) resolved to the
  snapshot's encoded resume state (`runner_state_snapshot["resume"]["state"]
  ["epoch"]`) — one authority, checkpoint `metadata` stays free-form.
  `recoverable?/1` went `@doc false` public so the matrix is pinned DB-only
  (`manager_recovery_test.exs`) without booting a Harness.
- **#2 — `incarnation_epoch` joins `incarnation_token` as a run_iteration
  opt** (surfaced refinement, 2026-07-11). The plan threaded only the token
  to attempts, but the claude pre-spawn anchor persist must STAMP its copy
  with the CURRENT incarnation epoch — a fresh runner's ResumeState carries
  epoch 0, and a 0-stamped copy would fail `recoverable?/1`'s epoch match,
  bricking recovery of the very anchor the eager persist exists to save.
  The runner stamps `{opts[:incarnation_epoch], revision + 1}` before the
  fenced write and returns the stamped copy in `metadata.state`; the
  harness's post-iteration mirror bumps onward from it (revision-bumping
  for the MIRROR write stays harness-owned as specced). Both opts skip
  cleanly when absent (claim: false runs, direct callers).
- **#2 — two producer-exact rejection rules + a `safe_message` hardening**
  (forced corrections, 2026-07-11). The LIVE vendor rejection messages —
  claude "No conversation found with session ID: …" (probed, exit 1) and
  codex 0.144.1 "… no rollout found for thread id … (code -32600)" (probed,
  exit 1) — do NOT substring-match the planned family rules ("conversation
  not found", "rollout path"); two verified rules were added to the
  session-poison family. Separately, `Exception.message/1` SHIELDS a
  hostile `message/1` and returns diagnostic text carrying call-site line
  numbers, which the boundary-safe `\b401\b`-class rules can false-positive
  on — discovered when the totality test happened to land at literal line
  401 of its own file. `safe_message/1` now invokes the exception's own
  `message/1` under the classifier's rescue, so a hostile extraction
  classifies `:agent_unknown` and the string arm never sees shield text.
- **#2 — the shared vendor failure policy lives in `Runners.ResumePolicy`**
  (forced by the ExDNA gate, 2026-07-11). The classify→poison→reject→emit
  policy, `metadata.state` attachment, and the checkpoint serialize/restore
  codec are IDENTICAL in both vendor runners by design; ExDNA rightly
  flagged the copies (mass 128–155), so they were extracted to one module
  the runners delegate to — the policies now cannot drift. The 2-clause
  armed-vs-off `run_iteration` dispatcher keeps a scoped
  `ex_dna:disable-for-lines` (behaviour-shaped sameness; the
  `safety_gate.ex` precedent).
- **#2 — materialization feeds the PERSISTED claim spec only; the runtime
  spec keeps the caller's config** (forced correction, 2026-07-11, slice 8).
  The handoff said "replace spec.runner_config with the materialized map"
  before claiming, but `materialize_config/1` deliberately DROPS
  attempt-scoped keys (`mcp_config_path`/`mcp_config_json`) — and today's
  consolidator still delivers its per-run MCP endpoint config through
  `runner_config` into `init/2`. Replacing the runtime copy would have
  broken every live consolidation until slice 9 moves that material to
  `run_iteration` opts. `Harness.persistable_spec/1` therefore materializes
  the copy handed to `claim_session` (both the `runner_config` column and
  the nested `spec.runner_config` jsonb the wake path decodes), while the
  in-memory spec — what `init/2` sees — stays byte-identical. Revisit at
  slice 9: once attempt-scoped material rides opts, the runtime copy could
  be materialized too (today it would change nothing — init applies the
  same defaults).
- **#2 — mint and transplant failures at claim time are LOUD STOPS**
  (surfaced decision, 2026-07-11, slice 8). The plan specified the CAS
  semantics but not the failure policy for the mint itself. A failed or
  stale mint stops the session (`{:stop, {:mint_failed | :recovery_failed,
  …}}`): running un-minted after terminal reuse would leave the OLD
  incarnation's pointer live during a recoverable phase — exactly the
  hazard claim-time minting exists to close — and a stale mint means
  another claimant owns the row. Likewise the recovery transplant
  checkpoint: the mint has already CLEARED the pointer, so proceeding past
  a failed transplant save would either strand the session unrecoverable
  mid-flight or restore a pre-select stale copy (resurrecting a poisoned
  anchor). The `recovery_degraded` continue-path is reserved for the
  initial checkpoint at READY time, where the session has real value
  running; Manager's recovery sweep retries stopped boots.
- **#2 — the per-iteration topology save IS the checked save for
  token-holding sessions** (surfaced refinement, 2026-07-11, slice 8). The
  plan listed the checked save's producers (initial, guidance, transplant)
  but kept "save_topology_checkpoint" best-effort; that would have parked
  the pointer at the initial checkpoint forever for ordinary sessions —
  regressing recovery topology (iteration count, extra sandboxes) relative
  to HEAD's wall-clock-latest restore, and leaving the documented
  "first later successful checked checkpoint self-heals degraded" with no
  producer on sessions that never park guidance. `save_topology_checkpoint/1`
  now routes through `save_recovery_checkpoint/6` when the harness holds a
  token (failure = log, pointer unchanged, session continues — degraded is
  NOT set by mid-session failures); token-less sessions keep the legacy
  unpointed `save_checkpoint/4`.
- **#2 — the harness `:error` arm prefers `metadata.error_details.failure_kind`**
  (pending decision made, 2026-07-11, slice 8, as flagged in the handoff).
  `failure_kind_of/1` reads the runner-classified kind (validated against
  `RunFailure.all_kinds/0`) before falling back to `classify(result.error)`
  — the armed runners classify closest to the evidence, and their
  label-only `result.error` terms would otherwise downgrade to
  `:agent_unknown` in the broadcast/telemetry/event row.
- **#2 — recovery restores from the TRANSPLANT checkpoint id, and the
  selector re-reads the pointer under the mint lock** (surfaced refinement,
  2026-07-11, slice 8). The wake-requested checkpoint id is a pre-lock
  read; the transplant selector re-reads `current_checkpoint_id` from the
  LOCKED row (a checked save between wake and claim could have moved it —
  logged when it differs), and the `{:recover, id}` message is swapped to
  the NEW transplant checkpoint so `restore_state/2` receives the
  post-select merged copy, never the pre-select snapshot. The selector
  stashes its under-lock selection via a unique-ref process-dictionary slot
  (the fun runs synchronously in the harness process; mint returns only
  `{epoch, token}`) — deleted immediately after the mint returns.
- **#2 — smaller slice-8 notes** (2026-07-11): the recovery-degraded loud
  channel is `ResumeSignal.emit_recovery_degraded/1` (SignalBus
  `jido_claw.forge.recovery.degraded` + session PubSub
  `{:recovery_degraded, payload}` + log + a `recovery.degraded` event row)
  — no Trace, which is run-scoped and the harness has no run context;
  deferred-provision sessions mint at claim but skip the initial checkpoint
  (no runner state yet — their pointer arrives with the first checked
  save); the `persistence()` app-env seam widened from complete-only to the
  fence writes so tests can force checked-save/mint failures
  (delegating-stub idiom, `harness_resume_test.exs`); unstamped (non-vendor)
  runner configs recover string-keyed through the RecoveredSpec passthrough
  lane, so only stamped vendor runners can recover ARMED — config-owned
  arming makes this structural, and the harness integration test drives
  recovery via an explicit spec rather than wake for exactly that reason.
- **#2 — slice 9 (RunServer) shape decisions** (2026-07-11). (a) The
  monitored-task split covers PUBLISH only: gate/load/cluster remain
  synchronous `handle_continue`s — they are bounded Ash reads with
  `@db_errors` rescues, and the watchdog semantics the plan tests
  ("watchdog fires during a blocked publish phase") only need the publish
  split; revisit if a load phase ever hangs in practice. (b) The
  driver-retry latch is PER-RUN (`AttemptLedger.resume_retry_used?`), not
  per-anchor: the driver cannot reach the harness-held `ResumeState` where
  the per-anchor `retry_used` field lives, and a run-scoped latch is
  strictly MORE conservative (never retries more than the plan allows; a
  consolidator run re-anchoring mid-run is the only case it under-retries).
  (c) The close-then-evaluate policy table lives in the pure
  `Consolidator.AttemptLedger` module so the crash-replay and retry rows
  are pinned exhaustively without a RunServer; the RunServer serializes
  every ledger mutation through its own GenServer dispatch (the
  reserve-then-execute law). (d) Crash-await/replay is exercised at the
  ledger table, not e2e — the consolidator suite runs Forge-persistence-
  disabled (shared-sandbox constraint), where `recovery_possible?/1` is
  honestly false; the harness-side recovery machinery has its own
  integration coverage in `harness_resume_test.exs`.
- **#2 — attempt-scoped endpoint config needed a runner seam the armed
  slices hadn't built** (forced correction, 2026-07-11). The plan routes
  the tokenized URL/config path through `run_iteration` opts, but the
  slice-5/6 runners read `mcp_config_path`/`mcp_server_url` from INIT
  config only. Added a per-turn `attempt_state/2` override in BOTH vendor
  runners (claude: `:mcp_config_path`; codex: `:mcp_server_url`) and the
  Fake runner (opts-first config path): opts land in the turn's state copy,
  are never serialized (the checkpoint codec whitelists exclude them), and
  absent opts leave the argv byte-identical (PR-3 pins hold, re-verified by
  the untouched runner suites).
- **#2 — publish-gate reason strings replace the old conflation**
  (2026-07-11): a clean exit WITHOUT a commit marker now fails
  `"completed_without_commit"` (the old `"max_turns_reached"` string
  documented the pre-rebuild behavior where staging-empty stood in for
  commit intent, and a staged-but-uncommitted run silently PUBLISHED — the
  exact mid-attempt transact the certificate gate removes). Deadline and
  bound terminals are `"run_deadline_exceeded"` / `"iteration_limit_reached"`.
  `Forge.run_loop/2` bound exhaustion reshaped to
  `{:error, {:iteration_limit, max}}` (caller-less Wave F substrate;
  classifies `:iteration_limit` by the existing tuple rule) and its
  continuation turns drop the caller's `:prompt` (SY3-3). The `:retry_fresh`
  turn resets to turn-1 prompt shape — a fresh conversation must receive
  the full task, never guidance-only.
- **#2 — the attempt token rides the URL path, stamped as a second assign**
  (2026-07-11): `/run/<run_id>/a/<attempt_token>` routes in
  `Consolidator.Plug` assign `:consolidator_attempt_token` before the
  ScopedForward delegation; the tokenless legacy routes stay routable but
  carry no token, so the RunServer's central validation refuses them —
  an old-shape client fails CLOSED, never open.
- **#2 — slice 10 (ChildTracker/terminate_tree) shape decisions**
  (2026-07-11). (a) Registration plumbing the plan implied but did not
  shape: `OsCmd.run/3` gained an `:on_os_pid` callback seam (synchronous,
  swallowed-raise — bookkeeping never kills a live command) and
  `HostShell.run/4` registers/unregisters around it via a pdict-scoped ref
  (the transplant-selector precedent); ONLY the CLI-runner `run` path opts
  in (`teardown: :graceful` + the harness-threaded `incarnation_key`),
  `exec` stays hard, docker keeps teardown-by-destruction. (b) Sweeps run
  in TRACKER-owned supervised tasks with every caller — initiator and
  joiners — as pure waiters; a crashed sweep task completes best-effort so
  joiners can never wedge. (c) The tracker sits at the FRONT of
  `infra_children` (one_for_one InfraSupervisor) rather than a literal new
  slot in `core_children` — same terminates-last property (reverse-order
  shutdown; the Forge tree stops before infra) without `rest_for_one`
  restart coupling. (d) Late-registration and VM-shutdown kills use
  `terminate_tree(pid, 0)` — hard but still identity-verified; a nil birth
  identity (pid dead at registration, ps unavailable) is UNVERIFIABLE and
  never blind-killed. (e) The harness single-sequenced-teardown hook
  (tracker sweep THEN sandbox destroys, one detached task) landed here as
  the handoff recommended, not in slice 8.
- **Gate-driven cleanups (2026-07-11, full-precommit pass)**. The project-wide
  gates caught what per-slice runs structurally cannot: (a) credo's CROSS-FILE
  duplicate check flagged `bounded_inspect/1` copied from `Verdict` into
  `RunFailure` (slice 1 followed the "mirror Verdict conventions" instruction
  literally) — extracted to `Verdict.bounded_inspect/1` in its existing
  "shared fail-closed primitives, used qualified" section, `RunFailure` calls
  it qualified; (b) reach's repeated-map-shape smell on the three anchor
  id-verify emissions — extracted `ResumePolicy.emit_anchor_mismatch/5` so
  the whitelist payload has ONE producer; (c) the two `attach_runner_state`
  trivial forwarders removed (runners call `ResumePolicy` directly); (d)
  `ResumeSignal`'s `reach:disable-next-line bare_rescue` comments were
  anchored on the Logger line, not the rescue clause — repositioned; (e)
  assorted `Map.keys/values`-chain smells in `ChildTracker`/`OsCmd` rewritten
  as pair iterations/comprehensions; (f) three test-file readability nits
  (nested-module aliasing in the vendor runner suites, a one-line pipe chain
  in `recovered_spec_test`).
- **Post-review fixes: all 8 code-review findings resolved (2026-07-11)**.
  The Wave A build's review surfaced 4×P1 + 4×P2, all validated real; four
  were resolved as review-forced CORRECTIONS to the build's original design,
  the rest as straight fixes. (F1) the consolidator now actually arms
  `resume: :armed` in both vendor lanes — the docs claimed it, the code
  omitted it, so every turn ≥ 2 was a fresh conversation whose whole prompt
  was the task-free nudge. (F2, correction) the planned post-hoc
  repair-turn machinery was replaced with PRE-DISPATCH prevention: the
  driver's continuation guidance moved from `:prompt` to a
  semantically-tagged `:guidance` opt that only armed CONTINUATION turns
  read — a fresh-armed turn structurally falls to `state.prompt`, so a
  task-free turn cannot exist; detection survives as the driver's loud
  fresh-start warning only, and `Forge.run_loop`'s `continuation_opts/1`
  drops `:guidance` alongside `:prompt`. (F3) the ChildTracker's
  late-registration and TTL-reap kills now go through the same
  identity-verified predicate as sweeps (a reused OS pid is never killed;
  nil birth refuses). (F4, correction) registration became TWO-PHASE
  (`register_owner/2` pre-dispatch + spawn attach) with sweeps awaiting
  pre-spawn owners under a bounded owner-stop, refusal kills TRACKED by
  in-flight barriers, covering call timeouts `2×grace + slack`, and
  tombstones retained on a pure TTL — the owner-emptiness reap the plan
  originally kept was the hole that lapsed late-kill protection at the
  first 5s tick. (F5, correction) parked-guidance delivery is VENDOR-OWNED
  (`ResumePolicy.take_continuation_guidance/2`, consume-at-take;
  fresh-armed reverts inflight → pending) instead of the planned
  harness-side gate, which would have broken the pinned substrate-runner
  fallback; the harness consume survives as the no-disposition fallback.
  (F6, correction) `select/4` ties now resolve to the text-carrying
  checkpoint copy; the transplant selector grafts a re-parkable marker when
  corrupt guidance would otherwise erase the evidence; recovery runs an
  explicit guidance disposition whose re-park lands `:needs_input` with a
  DURABLE whitelisted `repark_reason` marker (authoritative across repeated
  recoveries, self-cleared by the next answer) + the `guidance_reparked`
  signal + a ForgeView `needs_input` projection — the broadcast-only
  re-park the plan first sketched left late-arriving operators blind.
  (F7) deferred kickoff now lands the same checked initial checkpoint as
  every sibling ready-path (honest `%{}` snapshot). (F8) codex anchor
  promotion is gated on the parser's real `turn.completed` terminal — the
  deliberate exit-0-no-terminal `Runner.done` posture no longer promotes a
  provisional anchor (CH2-6).
- **Second-review fixes: F9 + F10 resolved (2026-07-11)**. A follow-up
  review of the 8-finding build surfaced 2 more P2s, both validated real.
  (F9, correction) the corrupt lane's planned "no graft, state untouched"
  posture broke repark durability: recovery-time corruption re-parked with
  NO durable marker — nil guidance object, nil metadata mirror — so the
  ForgeView projection showed a `:needs_input` session with no prompt or
  reason, and a second crash recovered `:ready`, silently evaporating the
  operator request. The lane now consume-grafts a synthetic copy at the
  state's own rev (`repark_reason: :corrupt_guidance`), durable and
  authoritative like the sibling repark lanes — zero downstream changes,
  the marker rides the existing codecs. (F10, correction) the F4-rework
  reap machinery lapsed its own barrier four ways: a TTL-expired pre-spawn
  owner was silently dropped (leaving a live owner writing under a deleted
  `run_forge_home`); a reaped spawned entry was dropped while its
  fire-and-forget kill still ran (and the unregister on command-return
  compounded it mid-kill); tombstones inherited already-expired entry TTLs
  (born-dead, reaped next tick, admitting late registrations mid-barrier);
  and a `register_spawn` queued behind the reap could revive a reaped
  owner as a permanently reap-exempt orphan. Unified under one law — a
  reaping entry is removed only by its DOWN: the reap force-stops owners
  and hands spawned entries monitored kills, sweeps adopt pending
  reap-kills in both orderings, an abnormal kill-task DOWN restarts the
  kill (replacement BEFORE the dead monitor clears — the completion-race
  order) with a synchronous in-server fallback when the task supervisor is
  gone (`spawn_kill` made total: `Task.Supervisor.start_child` EXITs
  `:noproc` against a missing supervisor, it never returns an error — the
  same totality applied to the sweeps' `start_kill_task`, where a
  born-complete refused sweep now returns the empty/best-effort path
  instead of installing a never-completing sweep), unregister defers,
  attach-to-reaping refuses `closing` with the identity adopted for the
  verified kill, and tombstone TTLs clamp to at least a fresh default
  window and only ever extend. Test affordances (deliberately minimal):
  `init` gained `task_supervisor:` + `schedule_reap:` (persisted, so a
  tick-less instance stays tick-less after test-sent `:reap`s),
  `start_link` a `:name`, plus the app-env kill-gate arming seam — nine
  new choreography tests drive private tick-less trackers, and the
  crucial lanes were mutation-verified (seed removal, clear-before-
  replace, unregister drop, clamp removal, plain attach each fail their
  pinning test). One existing test adjusted (forced by the new
  semantics): the TTL-reap row's final `by_key` assert became a poll —
  entries now drop via the kill task's DOWN, asynchronously, not
  synchronously inside the reap tick.
- **Third-review rider on F10: supervisor-loss lanes unified as
  async→sync, never pretend-done (2026-07-11)**. Review of the F10 build
  itself surfaced three more P2s, all validated. (a) The F10
  tombstone-clamp refactor seeded the empty-collection max with 0 — the
  BEAM monotonic clock is NEGATIVE, so `max(0, fresh_deadline)` returned
  0 and `ttl < now` never fired: every zero-entry key/session tombstone
  became immortal (an unbounded leak; the pre-F10 code's direct
  fresh-deadline fallback was correct). Both TTL folds now seed the
  reduce with the fresh deadline itself, pinned by before/after bounds
  that hold on either clock sign. (b) A refused sweep kill task still set
  `kills_done: true` — with a pending owner the sweep installed anyway
  and `complete_sweep` later dropped the never-killed spawned entries;
  `start_kill_task` now kills synchronously in-server on `:unavailable`
  (so a nil task pid truthfully means no async work left) and the
  born-complete branch drops its verifiably-dead refs instead of leaving
  them registered. (c) A refused refusal-kill start left the late CLI
  alive and untracked (HostShell ignores `:closing` and the command runs
  on); `refuse_kill` now falls back to the same synchronous verified kill
  before the `:closing` reply lands. `start_task` additionally normalizes
  every non-`{:ok, pid}` `start_child` result to `{:error, :unavailable}`
  so a future `:max_children` config takes the same safe path, and the
  shared rescued `sync_verified_kill/1` keeps a raising shutdown-time
  kill in the accepted best-effort residual class. Four new tests
  (tombstone TTL bounds; sweep fallback spawned-only and spawned+owner;
  refusal fallback), each mutation-verified to fail on the reverted code.
