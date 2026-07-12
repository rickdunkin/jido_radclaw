---
type: subsystem
description: Native CLI session resume for Forge vendor runners — epoch/token fencing, pointer-selected recovery, attempt-bound capabilities, the publish certificate, graceful tree teardown.
sources:
  - lib/jido_claw/forge/resume_state.ex
  - lib/jido_claw/forge/resume_signal.ex
  - lib/jido_claw/forge/runners/resume_policy.ex
  - lib/jido_claw/forge/runners/claude_code.ex
  - lib/jido_claw/forge/runners/codex.ex
  - lib/jido_claw/forge/persistence.ex
  - lib/jido_claw/forge/harness.ex
  - lib/jido_claw/forge/manager.ex
  - lib/jido_claw/forge/recovered_spec.ex
  - lib/jido_claw/forge/child_tracker.ex
  - lib/jido_claw/forge_view.ex
  - lib/jido_claw/core/os_cmd.ex
  - lib/jido_claw/memory/consolidator/attempt_ledger.ex
  - lib/jido_claw/memory/consolidator/run_server.ex
  - lib/jido_claw/security/redaction/env.ex
verified: 2026-07-11
verified_sha: "6e252a40"
---

# Forge Session Resume (native CLI resume, fenced recovery, attempt capabilities)

## What & why

Vendor Forge runners (claude_code, codex) can now continue a CLI's own
conversation across iterations and crashes instead of resending the whole task
every turn — multica MC1-1 (semantics map
`docs/exploration/pms/multica/PORT-MC1-1.md`, signed off 2026-07-11) plus the
CH2-6/SY3-3/BO2-3/HD2-2/CM2-3/EM3-3 riders. Everything is opt-in
(`runner_config[:resume] :: :off | :armed`, default `:off` — byte-identical
argv, PR-3 pins hold; the executor never arms), and every durable write is
fenced so a crashed incarnation's stragglers can never corrupt its successor.

## Invariants & contracts

- **The incarnation fence is HARNESS-level, for EVERY claimed session** —
  `metadata["forge_recovery"] = {epoch, token, current_checkpoint_id,
  recovery_degraded}`. Minted exactly once per Harness incarnation,
  IMMEDIATELY after the claim (terminal reuse must never expose the prior
  pointer during a recoverable phase): CAS from the stored pair (nil only
  when none exists), epoch incremented, token rotated, transplant installed
  at `{new epoch, revision 0}`, pointer cleared — one FOR-UPDATE critical
  section. The token authorizes WRITES only; reads compare epoch stamps. A
  failed/stale mint is a loud session stop, never an un-fenced run.
- **Control data and state live at separate JSON paths**: the fenced anchor
  mirror (`anchor_session/3`, token + strictly-newer revision) touches only
  `metadata["resume"]["state"]`; the CHECKED checkpoint save
  (`save_recovery_checkpoint/6`, pointer-first, one transaction) touches the
  pointer + guidance marker; a stale writer surfaces
  `{:error, :stale_resume_write}` and writes NOTHING.
- **The `current_checkpoint_id` pointer is the only recovery-selection
  authority** — `Persistence.current_checkpoint/1` (ownership-checked) feeds
  `Manager.recoverable?/1`, `Forge.wake/2`, and `context_for_resume/1`;
  wall-clock `latest_checkpoint/1` is an inspection helper, never selection.
  Armed sessions additionally require every PRESENT copy's epoch stamp to
  match the fence epoch.
- **Anchors are never trusted blindly**: claude mints its anchor CLIENT-side
  (`--session-id`, persisted pre-spawn through the fenced writer seam) and
  id-verifies the CLI's `"system"` echo; codex captures `thread.started`
  as `:provisional` and promotes only on a real `turn.completed` terminal in
  the same attempt — a terminal-less exit-0 stream stays provisional (CH2-6;
  the parser's `terminal` accumulator carries the signal, since the
  nil-fallthrough result posture is deliberately `Runner.done`).
  Continuations send `--resume <id>` / `resume <id>` with a GUIDANCE-ONLY
  prompt — the task never rides the argv twice (CM2-3/SY3-3); never
  `--continue`, never `--last`. A resume-unsafe failure POISONS the anchor
  (sticky; the poisoned id is never reused), and runners NEVER auto-retry.
- **The `:prompt`/`:guidance` opts split is the structural guard that a
  fresh conversation always carries the full task**: `:guidance`
  (continuation guidance) is read ONLY by armed continuation turns;
  `:prompt` keeps its default-off per-turn-override and
  fresh-armed-override-else-`state.prompt` semantics, and armed
  continuations ignore it entirely — a CM2-3 strengthening (even a confused
  caller passing `prompt: task` to an anchored session cannot put the task
  on a continuation argv), and the reason a task-free turn cannot exist: a
  fresh-armed turn structurally falls to `state.prompt`, the persisted full
  task.
- **Only the driver publishes / retries**: `commit_proposals` is a marker
  that closes staging; publication = marker + clean exit (`:done` or
  `:continue`) of the SAME attempt, written as the `:run_id`-pinned
  certificate row in the publish transaction; the one fresh retry and the
  one crash replay are ledger-gated (zero effects, latched, deadline-floored).
- **Teardown is sequenced and identity-verified**: the harness sweeps its
  incarnation's CLIs through `ChildTracker.graceful_teardown/2` BEFORE
  destroying sandboxes; the consolidator's final teardown runs the
  session-wide barrier before `run_forge_home` — the LAST filesystem
  resource — is removed; every kill verifies the birth identity so a reused
  OS pid is never killed.

## Mechanics

### ResumeState (`forge/resume_state.ex`)

Opaque struct; transitions enforce the lifecycle (`mint_client`,
`capture_backend`, `trust`, `clear`, `poison`, `rearm_new_anchor` — poisoned ∧
anchored unrepresentable; `retry_used` resets on a new anchor; `clear/2` on
poisoned is a no-op). `session_start_source` carries the HD2-2 vocabulary
(startup/resume/clear/new produced; fork/compact accepted, never produced);
`fresh_start?/1` reads it for the driver's mid-run fresh-restart warning.
Copies are stamped `{epoch, revision}`; `select/4` merges the metadata and
checkpoint copies — anchor state by newest `{epoch, revision}`, guidance
status by highest `guidance_rev` within the selected epoch with the
CHECKPOINT copy winning an equal-rev tie (the normal checked-save state: one
struct encodes both copies, and the text-less metadata marker winning the
tie would strip the operator's answer — a strictly newer metadata marker
still wins), guidance TEXT only from a checkpoint copy that is the status
winner. Whitelist codecs (`encode_state/1`, `encode_guidance_marker/1`,
`encode_guidance/1` strict with the Vault envelope `{"v",​"alg",​"data"}`,
`decode_state/1`, `decode_guidance/1`); a garbled copy decodes as absent,
never a guess — except guidance corruption, which is a DISTINCT loud result
the transplant selector preserves (below). The durable `repark_reason`
marker rides BOTH guidance codecs (whitelist-decoded, three known reasons,
unknown strings drop to nil) so it survives arbitrarily many recoveries;
`put_guidance/2` — a fresh operator answer — is its ONLY clearer.

### Per-turn mode + argv

`resolve_mode(rs, cwd)`: `:continuation` only for a trusted anchor in the
same workdir (claude captures `pwd` once at armed init; codex's anchor
workdir is the config-declared `-C cwd`); everything else is
`{:fresh_armed, reason}`. Claude fresh-armed: `--session-id <minted-uuid>` +
the full task (`opts[:prompt]`-else-`state.prompt`; `:guidance` structurally
ignored); continuation: `--resume <anchor>` + guidance only. Codex
fresh-armed drops `--ephemeral` only; continuation: exec opts BEFORE the
`resume` subcommand + a `--` separator for dash-leading guidance (both
live-verified on codex 0.144.1). Session flags derive only from mode +
anchor id; permission/trust flags only from `state.access` — the two never
mix.

Continuation guidance is VENDOR-OWNED through the shared
`ResumePolicy.take_continuation_guidance/2` — the single owner of the
`"Continue."` nudge: parked inflight text first (CONSUMED AT TAKE — the
answer rides exactly one argv and is never resent, even when the turn then
errors or times out; a `stalled_wall_clock` keeps the anchor, and consuming
prevents the double-send), then `opts[:guidance]`, then the nudge. Both
vendors' fresh-armed turns first revert inflight guidance to `:pending`
(`guidance_undelivered/1` — legal exactly because a fresh-armed turn
provably never places the answer on an argv; it redelivers on the next
continuation). The harness's post-iteration consume survives only as the
FALLBACK for runners that made no disposition (attached no armed state —
the fake/scripted substrate).

### Failure policy (`runners/resume_policy.ex`)

One shared module so the vendors cannot drift: classify ONCE
(`{:known, label}` arms — timeout, missing executable — never classify
output; `{:classify, label}` arms try the output first, then the
fallback-marker heuristic, then the label), poison on
`RunFailure.resume_unsafe?/1` + an anchored id, tag `resume_rejected: true`
only on session-poisoned continuations, thread
`RunFailure.error_details(kind, extra)` through `metadata.error_details`,
attach the FULL updated runner state at `metadata.state` on EVERY armed
terminal (success, error, timeout — the harness merges only via metadata),
and emit `ResumeSignal.emit_failed/2` (SignalBus
`jido_claw.forge.resume.failed` + session PubSub `{:resume_failed, payload}`
+ log; whitelist payload, bounded + redacted reason) BEFORE the attempt
returns. `serialize_state/1` emits the canonical
`{"iteration", "resume" => {"state"}}` checkpoint shape; `restore_state/2`
is config-owned (a snapshot never re-arms an off session).

### Harness integration (`forge/harness.ex`)

Claim-time mint (fresh/terminal-reuse → blank; recovery → the transplant
selector runs INSIDE the mint's lock, re-reads the pointer from the locked
row, merges via `select/4`, and the checked TRANSPLANT checkpoint is written
immediately under the new token — recovery then restores from the transplant
id, so the runner never sees a pre-select stale copy). The selector TRACKS
guidance corruption instead of collapsing it: when either copy decoded
corrupt and the merged selection carries no live guidance, it grafts a
conservative re-parkable marker (`mark_guidance_lost/1` — pending, no text,
rev bumped) so the transplant encodes marker-only pending and recovery
deterministically re-parks instead of silently erasing the operator's
answer (a nil selection — no armed state copies at all — has nothing to
park on: loud log, documented residual). The checked INITIAL checkpoint
lands before every `:ready` (fresh provision, lazy provision, DEFERRED
kickoff — with an honest runner-less `%{}` snapshot — and recovery
completion); its failure marks `recovery_degraded` (token-fenced) + emits
`jido_claw.forge.recovery.degraded`, and the session still runs — the next
successful checked save self-heals in its own transaction. The
per-iteration topology save IS the checked save for token holders (recovery
restores the last durably pointed state); token-less sessions keep the legacy
unpointed row. `run_iteration` opts thread `forge_session_id`,
`incarnation_token`, `incarnation_epoch`, `incarnation_key`; the iteration
task pre-registers as the incarnation's ChildTracker OWNER before dispatch
(a closing session refuses with `{:error, :session_closing}`); after each
iteration the harness mirrors the anchor fenced (`stamp(rs, epoch,
revision + 1)` — the harness owns revision bumping; stale ⇒ log + drop).
`apply_input` parks operator guidance `:pending` via the checked save
(encrypted text in the checkpoint, marker in metadata; ack `:ok` only on a
landed write — and a fresh answer self-clears the durable `repark_reason`),
the next iteration flips it `:inflight` CHECKED before the spawn (failure ⇒
no spawn), and delivery consumption is vendor-owned at take (the harness
post-iteration consume is the no-disposition fallback) — a crash re-parks
an answered question, never double-sends.

**Recovery guidance disposition** (`ResumeState.adopt_recovered_guidance/2`
— runs after `stamp_runner_resume`, BEFORE the initial checkpoint, so a
re-park's durable marker persists fenced through the checkpoint's existing
marker mirror with zero new writers). The runner's `restore_state` restores
only `["resume"]["state"]`; the harness adopts the transplant's guidance
copy explicitly, in order:

| copy | disposition |
| --- | --- |
| carries `repark_reason` (any status) | `{:repark, reason}` restored VERBATIM — the persisted reason is AUTHORITATIVE until an answer clears it, so a re-parked session that crashes again re-parks again, never recovers `:ready` |
| `:pending` + text | `:restored` (status/text/REV — a rev-less graft would let the marker out-rev a later answer) |
| `:pending`, no text | consume-graft (marker at the copy's rev, then rev+1) + `{:repark, :guidance_text_missing}` |
| `:inflight` | same consume-graft + `{:repark, :inflight_delivery_ambiguous}` — never resent |
| `:consumed`, no reason | `:kept` |
| corrupt at recovery time | consume-graft of a SYNTHETIC copy at the state's own rev + `{:repark, :corrupt_guidance}` — the durable consumed marker + reason land like every other repark lane (ForgeView-visible, authoritative at the next recovery); defense-in-depth — vault key unavailable at recovery; the mint-time collapse normally grafts first |

A re-park lands the session `:needs_input` (a recoverable, ForgeView-active
phase) with the static `ResumeState.repark_prompt/0`, emits
`jido_claw.forge.resume.guidance_reparked` + session PubSub
`{:needs_input, %{prompt, reason}}` / `{:resume_guidance_reparked, _}`, and
logs the `guidance.reparked` event. `ForgeView` projects `needs_input:
%{reason, prompt}` from the durable metadata marker for `:needs_input`
sessions (nil for runner-question parks with no repark marker — their
question travels the executor AgentCase path), so an operator arriving
after the broadcast still sees actionable instructions via `forge_status` /
`runtime_overview` / `forge_live`.

### Materialize-then-persist + recovery codec

`Runner.materialize_config/1` (optional callback; both vendors implement)
writes every init default explicitly, stamped
`RecoveredSpec.codec_stamp/1`; `Harness.persistable_spec/1` materializes the
PERSISTED claim copy (column + nested spec) while the runtime spec keeps the
caller's config (attempt-scoped `mcp_config_path`/`mcp_config_json` still
ride init until drivers move fully to opts). `RecoveredSpec.runner_config/1`
dispatches on the stamp: stamped ⇒ strict typed decode (missing/invalid
security-critical fields — access, config_sync, strict_mcp/allowed tools —
REFUSE recovery loudly; the decoded output keeps the stamp for N-recovery
re-persist), unstamped ⇒ byte-exact passthrough (the shell/workflow/custom/
fake lane — which recovers string-keyed, so only stamped vendor runners can
recover ARMED; config-owned arming makes that structural).

### Attempt-bound capabilities + effect ledger (consolidator)

Each CLI invocation gets a tokenized endpoint URL
(`/run/<run_id>/a/<attempt_token>`, stamped as a second assign by
`Consolidator.Plug`) and a UNIQUE immutable 0600 config file — both ride
`run_iteration` opts only (the runners merge them into the turn's state copy;
the checkpoint codec never serializes them). `Tools.Helpers` wraps every
envelope `{:mcp_tool, token, msg}` and the RunServer validates centrally —
readers included; a closed/absent token gets a typed `"attempt_closed"`
error the CLI sees (tokenless legacy routes stay routable but fail closed).
Mutators reserve on `AttemptLedger` BEFORE executing (one GenServer message
= serialized; a close observes every reservation; a soft-rejected block
proposal still counts — the conservative direction). `commit_proposals` sets
the marker + closes staging; it never publishes.

### Close-then-evaluate, retry, crash replay (`AttemptLedger`)

On the attempt's result or a harness crash the RunServer closes the token
FIRST, then evaluates: commit + clean exit ⇒ `:publish`; commit + unclean ⇒
halt (`commit_without_clean_exit`); `:done` without commit ⇒ halt
(`completed_without_commit` — the old mid-attempt publish is gone); clean
`:continue` ⇒ next turn (turn ≥ 2 sends `guidance:` — never `:prompt` —
so an anchored continuation rides `--resume` with it while a fresh-armed
turn structurally falls to the full task; bound by `max_iterations`,
default 8). Replay turns share the exact same opts-building path — a
live-anchor replay continues with meaningful guidance, a dropped-anchor
replay resolves fresh and gets the task; `source: :replay` marks events
only. When a turn ≥ 2 comes back reporting a FRESH conversation
(`ResumeState.fresh_start?/1` on the attached armed state) the driver logs
a loud warning — mid-run context was lost and the turn redid the task from
scratch (safely: it carried the full prompt) — with no directive change and
no extra turn. The ONE fresh retry needs `resume_rejected` + retryable kind
+ zero effects + deadline ≥ floor + an unset per-run latch (strictly more
conservative than the per-anchor latch the plan sketched — the driver
cannot reach the harness-held ResumeState). A crash with ANY effect
(mutation or marker) is terminal; effect-free + recoverable + unlatched ⇒
await Manager recovery on the run-long PubSub subscription (capped) and
replay the interrupted logical turn once, marked `source: :replay`.

### Publish certificate + watchdog

`do_publish` passes `run_id:` so `ConsolidationRun.record_run`'s named pk
argument (`Changes.PinRunId`, the `Checkpoint.create_recovery` pattern) makes
the succeeded row the commit certificate; ALL terminal audit rows share the
deterministic id, so reconciliation requires `status == :succeeded`. The
publish runs in a monitored task; the whole-run watchdog
(`harness_options[:max_run_ms]`, default 660_000, monotonic) closes the open
attempt, stops the session, cancels + awaits the publish task, then
reconciles three ways: succeeded row ⇒ the commit won; not-found/non-success
⇒ nothing published; a DB error after bounded retries
(`:consolidator_reconciliation_allowance_ms`, default 10_000) ⇒
`publish_outcome_unknown` — never republish, never claim nothing-published.
The facade await derives as `max_run_ms + allowance + 5s cushion`; a custom
`await_ms` is a WAIT timeout only — cancellation authority is the watchdog
alone. Final teardown (lock, endpoint, attempt config files, forge home) runs
only at terminal — the lock/endpoint/home survive a harness crash so
recovery finds them (codex session files under `CODEX_HOME=run_forge_home`
survive; the dir is created mode 0700).

### Graceful tree teardown (`ChildTracker` + `OsCmd.terminate_tree/2`)

`terminate_tree(os_pid, grace_ms)`: capture the descendant set (fixpoint
walk, birth identities per pid) → SIGTERM all → a polled grace window with
continued re-discovery (newcomers unioned + TERMed) → a STOP-fixpoint +
SIGKILL over identity-verified survivors. The tracker keys entries by tagged
incarnation (`{sid, {:durable, epoch}}` / `{sid, {:local, uuid}}`).
Registration is TWO-PHASE: the harness iteration task pre-registers as the
OWNER (`register_owner/2`) before dispatch — covering pre-spawn work like
the fenced anchor write — and the CLI spawn attaches to that entry in
`HostShell.run/4` via `OsCmd`'s `:on_os_pid` seam (same process ⇒ same ref,
so the command-return unregister drops the whole entry) when the vendor
runners thread `teardown: :graceful` + the harness's `incarnation_key`
(generic exec stays hard; docker keeps teardown-by-destruction). Late
registrations against a closing incarnation OR session are refused and
killed IDENTITY-VERIFIED — and the kill is TRACKED by any in-flight
sweep/barrier (the sweeping key's `pending_kills`, else the session wait's
late-kill set), so a barrier can never complete under a still-running
refusal kill. Sweeps run in tracker-owned tasks and complete only when the
kill phase is done AND every pre-spawn owner resolved (owner DOWN — the
TTL reap and the BOUNDED owner-stop at the grace window both force-stop a
wedged owner so its own DOWN resolves it) AND every tracked late kill AND
every adopted reap-kill finished; callers — initiator and joiners — block
until then (covering call timeout `2 × grace + slack`, with a loud log on
the never-block degradation). `graceful_teardown_session/2` is the barrier
the consolidator's final teardown calls before deleting the home.
Tombstones are retained on a pure TTL — at least a fresh 300s window at
tombstone time, lifted to the max registered entry TTL when higher, and
re-tombstoning only ever extends, never inheriting an already-expired
entry TTL (per-run-unique session ids and epoch-minting recovery make long
retention safe; the old owner-emptiness reap lapsed the late-kill
protection). The TTL reap never drops live bookkeeping: an expired
pre-spawn owner is force-stopped and RETAINED, an expired spawned entry
gets a monitored identity-verified kill and is RETAINED, and a reaping
entry is removed only by its DOWN — `unregister` defers to it, an attach
to a reaping owner refuses `closing` with the identity adopted for the
verified kill (never a revival), sweeps adopt pending reap-kills into
`pending_kills` in both orderings, and an abnormal kill-task exit restarts
the kill (replacement started before the dead monitor clears). Task-
supervisor unavailability (VM shutdown — it terminates before the tracker)
degrades every kill lane from asynchronous to SYNCHRONOUS in-server
verified kills — sweep kill tasks, refusal kills, and the reap replacement
all fall back rather than pretending completion, so a barrier never
returns over a kill that silently did not run. The tracker sits first in
the core children so its `terminate/2` VM-shutdown sweep runs last. Grace
knob: `:forge_runner_teardown_grace_ms` (default 2_000).

### Env denylist + deadlock posture

`Env.@scrub_denylist_exact` (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`,
`CLAUDE_CODE_EXECPATH`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_SSE_PORT`) +
the `CLAUDECODE_` prefix are denied FIRST — operator allowlists and
`scrubbed_cmd_env/1` overrides can never re-open them; docker `inject_env`
filters them before the `.forge_env` render. Deliberately NOT the whole
`CLAUDE_CODE_*` namespace. Deadlock discipline is satisfied by construction:
prompts ride argv, stdin is `</dev/null`, stderr merges via
`:stderr_to_stdout`.

### Transcript markers (EM3-3)

`iteration.completed` event data carries `source: :live | :replay`
(whitelist-decoded from the driver's `source:` opt; the consolidator marks
its retry/replay turns). `SubagentTranscript.do_append/6` stamps every turn's
metadata with the same whitelist-decoded field (default `:live`; arbitrary
`tool_context[:source]` values coerce) — its `:replay` producer honestly
awaits an agent-layer replay path.

## Config & telemetry

- `runner_config[:resume]` — `:off` (default) | `:armed`; the consolidator
  arms via `base_runner_config/2`. Config knobs:
  `:forge_runner_teardown_grace_ms` (2_000),
  `harness_options[:max_run_ms]` (660_000),
  `harness_options[:max_iterations]` (8),
  `:consolidator_reconciliation_allowance_ms` (10_000).
- Signals: `jido_claw.forge.resume.failed`,
  `jido_claw.forge.recovery.degraded`,
  `jido_claw.forge.resume.guidance_reparked` (+ session PubSub
  `{:resume_failed, _}` / `{:recovery_degraded, _}` /
  `{:resume_guidance_reparked, _}` and the re-park's
  `{:needs_input, %{prompt, reason}}`); Forge event rows
  `recovery.degraded`, `incarnation.mint_failed`, `guidance.reparked`, and
  the `source:` field on `iteration.completed`.
- Test seams: `:forge_resume_writer` (claude pre-spawn persist),
  `:forge_persistence` (harness fence-write stubs),
  `:harness_resume_iteration` / `:consolidator_scripted_turn` (test runners).

## Residuals & accepted risks

- **Crash-native resume is `:local`-only**: docker recovery creates a new
  microVM/workspace (the cwd-gate then forces fresh-armed), and
  `run_forge_home` is not among the automatic mounts. Docker-armed sessions
  get in-run continuations only; the named trigger for docker crash-resume
  is a stable 0700 host-mounted session dir design.
- **`consumed` is best-effort**: a crash after completion but before the
  consumed mark re-parks an already-answered question — an unnecessary
  re-prompt, never a double-send. Recovery from `inflight` never auto-resends.
- **An exit-127 continuation consumes an undelivered answer**: consume-at-take
  fires before the spawn, so a missing CLI (which kills the whole run anyway)
  eats the parked text — accepted; the alternative reintroduces the
  double-send on timed-out DELIVERED turns.
- **Corrupt guidance with NO armed state copies at all** (a nil transplant
  selection) has nothing to park the loss on — loud log, evidence lost.
  Armed sessions always carry state copies in practice.
- **A mid-run fresh restart redoes the task from scratch** in a new
  conversation — prior in-conversation context is unrecoverable by
  definition. It is now guaranteed to carry the full task (the
  `:prompt`/`:guidance` split) and logged loudly by the driver.
- **Runner-question `:needs_input` sessions (non-repark) project no question
  text through ForgeView** — their question travels the executor AgentCase
  path (PR-4); only the re-park's static prompt projects.
- **`lstart` identity has one-second resolution** and a child forked after a
  snapshot and orphaned before the next rediscovery pass can escape a
  PID-tree walk — accepted (process groups rejected for macOS portability);
  the VM-shutdown sweep and boot reaper bound the damage. A nil identity is
  unverifiable and never blind-killed. PID-reuse refusal kills are not
  e2e-testable (they need OS pid reuse); the dead-birth refusal is the proxy
  pin.
- **A brutal owner-stop landing in the microsecond window between
  `Port.open` and the attach call can orphan a CLI** — same class as the
  fork-after-snapshot residual; bounded by the identity-verified refusal +
  the VM-shutdown sweep.
- **Tombstones are now retained ~300s** (TTL-only) — per-run-unique session
  ids and epoch-minting recovery mean retention cannot block legitimate
  work.
- **Unstamped (non-vendor) runner configs recover string-keyed** through the
  RecoveredSpec passthrough lane, so only stamped vendor runners recover
  armed — config-owned arming makes this structural, not a gap.
- **The per-run retry latch under-retries one case** (a consolidator run
  that re-anchors mid-run) relative to the per-anchor latch — deliberately
  conservative.
- **Gate/load/cluster phases remain synchronous** in the RunServer; only
  publish runs in a monitored task (the watchdog contract the plan tests).
- **The consolidator crash-replay path is pinned at the ledger table**, not
  e2e — the consolidator suite runs Forge-persistence-disabled where
  recovery is honestly impossible; harness-side recovery has its own
  integration coverage.

## Source map

- `lib/jido_claw/forge/resume_state.ex` — lifecycle, codecs, select
- `lib/jido_claw/forge/resume_signal.ex` — loud failure/degraded channels
- `lib/jido_claw/forge/runners/resume_policy.ex` — shared vendor policy
- `lib/jido_claw/forge/runners/claude_code.ex:189` — armed dispatch, argv
- `lib/jido_claw/forge/runners/codex.ex:192` — armed dispatch, thread capture
- `lib/jido_claw/forge/persistence.ex:389` — fence block (mint/anchor/checked save/pointer)
- `lib/jido_claw/forge/resources/session.ex` — fenced atomic actions
- `lib/jido_claw/forge/resources/checkpoint.ex:43` — `create_recovery` named pk
- `lib/jido_claw/forge/harness.ex` — claim-time mint, transplant, initial checkpoint, guidance lifecycle + recovery disposition
- `lib/jido_claw/forge_view.ex` — the `needs_input` re-park projection
- `lib/jido_claw/forge/manager.ex:264` — `recoverable?/1` lifecycle matrix
- `lib/jido_claw/forge/recovered_spec.ex:105` — versioned runner-config codec
- `lib/jido_claw/forge/child_tracker.ex` — tagged incarnations, sweeps, barrier
- `lib/jido_claw/core/os_cmd.ex` — `terminate_tree/2`, `process_identity/1`, `:on_os_pid`
- `lib/jido_claw/forge/runner/host_shell.ex` — registration seam
- `lib/jido_claw/memory/consolidator/attempt_ledger.ex` — the directive table
- `lib/jido_claw/memory/consolidator/run_server.ex` — driver loop, watchdog, certificate
- `lib/jido_claw/memory/resources/consolidation_run.ex` — `record_run` `:run_id`
- `lib/jido_claw/conversations/subagent_transcript.ex` — turn source stamp
- `test/jido_claw/forge/harness_resume_test.exs` — harness integration
- `test/jido_claw/forge/child_tracker_test.exs` — real-process teardown
- `test/jido_claw/memory/consolidator/attempt_ledger_test.exs` — policy table
- `test/jido_claw/forge/persistence_resume_fence_test.exs` — fence laws
