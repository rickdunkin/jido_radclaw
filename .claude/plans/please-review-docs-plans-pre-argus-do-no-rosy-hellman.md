# Plan: pre-argus Wave A — execution substrate (items #1–#4)

## HANDOFF — 2026-07-11 (third pause), #2+#3 slices 1–7 of 13 complete

Third operator hold, mid item #2+#3. Items #1 + #4 + the PORT gate were done
at the first pause; slices 1–3 (env denylist, ResumeState, forge_recovery
fence) at the second. THIS session shipped **slices 4–7 — config codec +
pointer loader, claude armed modes, codex armed modes, ResumeSignal/poison/
fallback tagging — all verified green per slice** (392 forge-dir tests, credo
clean, `--warnings-as-errors` clean), and had JUST marked slice 8 (harness)
in progress when paused: **zero slice-8 code written**. Everything below this
section is the original approved plan, annotated with DONE markers — **the
detailed Items #2+#3 spec further down is the authoritative build spec and
must be preserved** (the repo plan home doc
`docs/plans/pre-argus-wave-a/README.md` deliberately compresses that section
to a summary; this file is where the full fencing/ledger/argv/test detail
lives). Read "Fence semantics as BUILT", "Runner armed-mode API as BUILT",
and "Ash traps discovered" below before writing any slice-8+ code — the
harness/RunServer consumers must call these APIs exactly as shipped.

### Status at a glance

| Step | State |
| --- | --- |
| 0 — plan home doc | ✅ DONE — `docs/plans/pre-argus-wave-a/README.md`; `## Deviations` live (8 entries: 3 from #1/#4 + 5 new from #2 slices 1–3) |
| #1 — RunFailure taxonomy | ✅ DONE, verified (module + 43 tests + 3 consumers + docs + 6 reconciliation Status lines) |
| GATE — PORT-MC1-1 sign-off | ✅ DONE — map written, **explicitly signed off 2026-07-11** (all 4 recommended options confirmed via AskUserQuestion; recorded in the map). |
| #4 — exit-code tiers 4/5/6 | ✅ DONE, verified (run_command + AshErrors.not_found?/1 + moduledocs + tests + reconciliation) |
| #2+#3 slice 1 — env denylist | ✅ DONE, verified (env.ex + docker inject_env filter + 72 tests across both files + credo) |
| #2+#3 slice 2 — ResumeState | ✅ DONE, verified (`forge/resume_state.ex` + 36 tests + credo; full transitions/guidance/codecs/select) |
| #2+#3 slice 3 — forge_recovery fence | ✅ DONE, verified (Session fenced actions + Checkpoint `create_recovery` + `AshErrors.stale_write?/1` + Persistence mint/anchor/checked-save/degraded + 21 fence tests + credo; neighboring persistence tests green) |
| #2+#3 slice 4 — config codec + pointer loader | ✅ DONE, verified (`materialize_config/1` callback + impls on both runners w/ shared `@default_*` attrs; `RecoveredSpec.codec_stamp/1` + `runner_config/1` v1 whitelist codec wired into `normalize/1`; `Persistence.current_checkpoint/1` pointer loader on all THREE read paths — `Manager.recoverable?/1` matrix (@doc false public) + `Forge.wake/2` + `context_for_resume/1`; 18 new codec rows incl. the consolidator `:full` regression + double-round-trip + attempt-scoped-drop; +6 fence-file pointer rows; NEW `manager_recovery_test.exs` 8 matrix rows + `wake_test.exs` 2 negatives; `context_builder_test.exs` moved to checked saves) |
| #2+#3 slice 5 — claude armed modes | ✅ DONE, verified (31 tests: `resume: :armed` knob; pwd capture armed-only; head-dispatch armed/default; fresh-armed `--session-id` client mint + PRE-SPAWN persist via `:forge_resume_writer` seam; continuation `--resume` + guidance-only prompt + `"Continue."` floor; id-verify vs `"system"` echo; CM2-3 contract rows; serialize/restore + cwd-gate; StubSandbox gained `program_run_sequence/2` + `run_args_history/1`) |
| #2+#3 slice 6 — codex armed modes | ✅ DONE, verified (30 tests: workdir = config `-C cwd`, no pwd exec; fresh-armed drops `--ephemeral` ONLY; `thread.started` `thread_id` captured (fixture :313 updated); provisional-until-clean-`:done` promotes (CH2-6); continuation `… -C cwd resume <id> -- <guidance>` — exec opts BEFORE subcommand + `--` separator, both VERIFIED LIVE on 0.144.1; poisoned-id-reuse refusal; echo-verify) |
| #2+#3 slice 7 — ResumeSignal + poison + fallback | ✅ DONE, verified (118 tests across run_failure/resume_signal/runners: NEW `forge/resume_signal.ex` `emit_failed/2` — SignalBus `jido_claw.forge.resume.failed` + Forge.PubSub `{:resume_failed, payload}` + log, whitelist payload, bounded+redacted reason; NEW `runners/resume_policy.ex` shared vendor policy (ExDNA-forced extraction) — classify-once `{:known,label}`/`{:classify,label}`, poison on `resume_unsafe?`+anchored, `resume_rejected: true` on session_poisoned+continuation, `error_details` in metadata, serialize/restore codec; 2 verified-live rejection rules + `fallback_marker?/1` + `safe_message/1` hardening in RunFailure) |
| #2+#3 slices 8–13 | ⬜ NOT STARTED — slice 8 (harness) task marked in_progress, **zero code written**; harness regions read this session are listed under "Exact stop point" |
| off-plan — reach gate red at HEAD | ✅ FIXED — `mcp/consumer.ex:592` Map.keys→pairs smell (reach ~>2.2 post-deps-bump flags a committed file); consumer tests 46/46; logged in Deviations |
| Final — `mix precommit` green | ⬜ NOT RUN (per-slice verification green; the full gate — partitioned tests, dialyzer, reach project-wide, ExSlop, format, jido_md/system_prompt/system_docs checks — not yet run end-to-end) |

### What was verified (per-slice, all green)

From earlier sessions (#1/#4, slices 1–3):
- `run_failure_test.exs` 43/43 · `run_command_test.exs` + `ash_errors_test.exs` 48/48 · env/docker 72 · `resume_state_test.exs` 36 · fence 21 · `mix jidoclaw.system_docs.check` green · reach green project-wide.

THIS session (slices 4–7), each verified with `mise exec -- mix compile
--warnings-as-errors` + targeted tests + per-file credo:
- Slice 4: `recovered_spec_test.exs` 29 (11 old + 18 codec) · `persistence_resume_fence_test.exs` 27 (21 + 6 pointer/context rows) · NEW `manager_recovery_test.exs` 8 · NEW `wake_test.exs` 2 · `context_builder_test.exs` green post-rewire · runners+multi_sandbox 62.
- Slice 5: `claude_code_test.exs` 31 (13 armed rows + PR-3 pin extended with `--session-id`/pwd refutes).
- Slice 6: `codex_test.exs` 30 (10 armed rows + fixture update).
- Slice 7: run_failure 47ish + NEW `resume_signal_test.exs` 4 + runner failure-classification rows — 118 across the three; **full forge dir sweep: 392 passed, 17 excluded (docker tags)**.
- Live probes recorded in comments/tests: codex 0.144.1 rejects `-C` after `resume`; dash-leading guidance needs the `--` separator (parses clean); `thread.started` key is `thread_id` and fires before any turn (even failed ones); codex rejection `"Error: thread/resume: … no rollout found for thread id <uuid> (code -32600)"` exit 1; claude rejection `"No conversation found with session ID: <id>"` exit 1 with the JSON result line AFTER the bare text line.
- NOT yet exercised: full-suite partitioned run, dialyzer over the new modules, ExSlop project-wide. Expect the usual traps (memory notes): dialyzer union totality, ExSlop comment-starts-with-"step", flaky async:false singletons verified in ISOLATION before blaming this work.

### Exact stop point

Slice 8 (session task tracker #5, in_progress) was marked started and NOTHING
more: **zero slice-8 code written, no slice-8-specific files opened after the
marker**. Harness knowledge already loaded this session (current line
numbers, harness UNTOUCHED since slice 1's classify-once consumer):
`claim_and_start`/`start_claimed_session`/`kickoff_session` :181–263,
`:provision`/`:bootstrap` handlers :265–330, `{:recover, checkpoint_id}`
:389–422 (calls `load_checkpoint/1` :898 → `Checkpoint.get_by_id` — already
id-keyed, so wake's pointed id flows through), `run_iteration` call + task
spawn :456–485, `apply_input` :546–563, `iteration_complete` :655–762
(state-merge via `result.metadata %{state: …}` :707–714; `:error` arm
classifies `result.error` :667–668), `serialize_runner_state` :1276 (uses
`serialize_state/1` when exported — now exported by both vendors via
ResumePolicy), `save_topology_checkpoint` :1306 (best-effort
`save_checkpoint/4`), `persist/1` swallow-wrapper :1333,
`maybe_claim_session` :1536 (`claim: false` bypass). Also known:
`Manager.start_session` 30s call timeout; `terminate/2` detached destroys
~:790–810.

### What's next (resume here — slice 8 of 13)

Slices 1–7 ✅ done. Remaining, in order (full spec in "Items #2+#3" below):

8. **← RESUME HERE — Harness changes.** The spec is the "Harness changes"
   subsection below; these INTEGRATION DECISIONS are already established by
   slices 4–7 and must be honored:
   - **Claim-time mint** immediately after `maybe_claim_session` succeeds,
     before `:provisioning`/`:resuming`: fresh + terminal-reuse →
     `Persistence.mint_resume_epoch(sid, Persistence.stored_recovery_pair(sid), nil)`
     (blank); recovery (`resume_checkpoint_id` present) → mint with the
     SELECTOR-FUN transplant doing select-under-lock: decode
     `metadata["resume"]["state"|"guidance"]` + the POINTED checkpoint's
     `runner_state_snapshot["resume"]["state"|"guidance"]` via
     `ResumeState.decode_state/1`+`decode_guidance/1`, merge via
     `ResumeState.select/4`. Then IMMEDIATELY checked-save the transplant
     checkpoint under the new token. Hold `{epoch, token}` in harness state.
     `claim: false` / persistence-disabled → local in-process posture (no
     mint; epoch 0; no durable recovery).
   - **run_iteration opts**: thread `forge_session_id: state.session_id`,
     `incarnation_token`, AND `incarnation_epoch` (the runners already read
     all three — epoch joined the opts as a logged deviation; stamps a fresh
     runner's pre-spawn anchor copy with the true epoch).
   - **iteration_complete**: after the existing state-merge, best-effort
     FENCED mirror — when the merged runner state carries
     `%ResumeState{} = rs` and the harness holds a token:
     `Persistence.anchor_session(sid, ResumeState.stamp(rs, epoch, rs.revision + 1), token)`
     (stale ⇒ log + drop). ALSO: prefer
     `result.metadata.error_details.failure_kind` over re-classifying
     `result.error` in the `:error` arm (the runner classified closest to
     the evidence; label-only errors would downgrade to `agent_unknown`
     otherwise) — pending decision made, LOG AS DEVIATION when implemented.
   - **Checked initial checkpoint before `:ready`** (both fresh-provision
     and recovery completion): snapshot = `serialize_runner_state(...)`
     (both vendors now emit the canonical `{"iteration", "resume" =>
     %{"state" => …}}` via ResumePolicy). Failure ⇒
     `Persistence.mark_recovery_degraded(sid, token)` + Trace/log +
     `jido_claw.forge.recovery.degraded` signal; session still runs;
     self-heal is structural (any later checked save clears it).
   - **cwd-gate at recover_runner is now STRUCTURAL**: restore_state keeps
     the anchor's OLD workdir while the fresh init captures the NEW
     cwd/`resume_cwd`, and the runners' per-turn `resolve_mode` fails the
     mismatch toward fresh-armed. Verify nothing more is needed beyond the
     transplanted metadata state reaching the runner (the harness recovery
     path hands the POINTED snapshot to `restore_state/2`; the mint
     transplant already installed the merged copy in metadata).
   - **apply_input guidance lifecycle** per spec (checked `pending` save via
     `save_recovery_checkpoint` with the guidance marker + encrypted text in
     the snapshot's `["resume"]["guidance"]`; checked `inflight` BEFORE
     spawn, failure ⇒ no spawn; `consumed` best-effort) — infrastructure-only
     for vendor runners (neither produces `needs_input` today).
   - **Teardown ordering choice (open, decide at build)**: the "single
     sequenced teardown task" needs ChildTracker (slice 10). RECOMMENDED:
     build slice 8 WITHOUT the teardown resequencing; slice 10 adds
     ChildTracker + the harness teardown hook together (avoids a dangling
     reference or a stub).
   - **Session-start materialize-then-persist**: before
     `Persistence.claim_session`, when the resolved runner module exports
     `materialize_config/1`, replace `spec.runner_config` with the
     materialized map (stamped). Enforced for the vendor runners; others
     pass through. The recovery path then decodes via `RecoveredSpec` inside
     `wake/2` (already wired — slice 4).
9. RunServer (attempt-token endpoint + plug context + centralized helpers enforcement, serialized reserve-then-execute ledger, close-then-evaluate, crash-replay table, publish certificate — `record_run` `:run_id` argument mirrors the shipped `Checkpoint.create_recovery` named-pk pattern — + three-outcome reconciliation, watchdog + monitored blocking phases, recovery-await, multi-iteration loop with driver-side ledger-gated retry per Q3 reading the runners' `metadata.error_details` (`resume_rejected` + `retry`), per-attempt 0600 config files + cleanup, final-teardown `graceful_teardown_session` handshake, facade await derivation).
10. ChildTracker + `OsCmd.terminate_tree/2` (tagged incarnation keys; birth-identity PID-reuse guard; session tombstone; supervised at the front of core children) + the harness sequenced-teardown hook deferred from slice 8.
11. Transcript markers (EM3-3 — `iteration.completed` `source: :live | :replay`; `SubagentTranscript.do_append/6` whitelist stamp).
12. Docs page `docs/system/forge-session-resume.md` + index + AGENTS.md bullet (atomic — system_docs.check) + `executor-seam.md:258-260` edit + verified bump. Also fold in: run-failure.md producer-status updates (fallback-marker + session-poison producers now LIVE; the two new string rules; `fallback_marker?/1`; `safe_message` hardening) — run-failure.md is slice-1 content whose claims moved.
13. Reconciliation (rows listed in the spec below) + keep the plan-home Deviations current.
Then: `mise exec -- mix precommit` bare in background, read the tail, iterate to green; finish with files-to-stage + commit messages (operator commits).

### Working tree (all uncommitted; operator commits — nothing staged)

Maps to the suggested commit slices:
- **Slice 1 `feat: run-failure taxonomy (MC1-4 + OR3-2/BO2-3 riders)`** — NEW `lib/jido_claw/orchestration/run_failure.ex`, `test/jido_claw/orchestration/run_failure_test.exs`, `docs/system/run-failure.md`; MODIFIED `lib/jido_claw/core/telemetry.ex` (counter + `emit_run_failure/2`), `lib/jido_claw/forge/harness.ex` (classify-once consumer + `iteration_completed_data/4` + aliases), `lib/jido_claw/route_composer/route_composer.ex` (`emit_infra_observability/4` + Lane-B threading + alias), `docs/system/README.md`, `AGENTS.md` (new Key Patterns bullet), `docs/TRUST-BOUNDARIES.md` ("Retry ≠ resume" section), `docs/system/verdict-normalizer.md` (cross-link + verified bump), reconciliation in `docs/exploration/pms/multica/{MC-FIRST-WAVE,FEATURES-WORTH-BORROWING}.md` (item 1 / MC1-4), `docs/exploration/pms/orca/{FEATURES-WORTH-BORROWING,OR-FIRST-WAVE}.md` (OR3-2), `docs/exploration/pms/bosun/FEATURES-WORTH-BORROWING.md` (BO2-3 taxonomy half), `docs/plans/pre-argus-do-now/README.md` §1.
- **Slice 2 `docs: PORT-MC1-1 semantics map`** — NEW `docs/exploration/pms/multica/PORT-MC1-1.md` (signed off; sign-off recorded inside).
- **Slice 4 `feat: exit-code tiers 4-6 for mix jidoclaw run (MC3-4)`** — MODIFIED `lib/jido_claw/cli/run_command.ex`, `lib/jido_claw/core/ash_errors.ex` (`not_found?/1`), `lib/mix/tasks/jidoclaw.ex` + `lib/jido_claw/cli/main.ex` (moduledoc exit tables), `test/jido_claw/cli/run_command_test.exs`, `test/jido_claw/core/ash_errors_test.exs`, `docs/system/ambiguity-clarify.md` (verified bump), MC-FIRST-WAVE item 3 (+ restored `## 3.` header) / FWB MC3-4 / pre-argus README §4 / `docs/plans/unadopted-next-ten/README.md` (OQ-4 note).
- **Slice 3 `feat: native CLI session resume for Forge runners (MC1-1 + riders, EM3-3)`** — IN PROGRESS (build steps 1–7 of 13 done). NEW: `lib/jido_claw/forge/resume_state.ex`, `lib/jido_claw/forge/resume_signal.ex`, `lib/jido_claw/forge/runners/resume_policy.ex`, `test/jido_claw/forge/resume_state_test.exs`, `test/jido_claw/forge/persistence_resume_fence_test.exs`, `test/jido_claw/forge/manager_recovery_test.exs`, `test/jido_claw/forge/wake_test.exs`, `test/jido_claw/forge/resume_signal_test.exs`. MODIFIED: `lib/jido_claw/security/redaction/env.ex` (hard denylist), `lib/jido_claw/forge/sandbox/docker.ex` (`inject_env` denylist filter), `lib/jido_claw/forge/resources/session.ex` (4 fenced actions + inline changes), `lib/jido_claw/forge/resources/checkpoint.ex` (`create_recovery`), `lib/jido_claw/core/ash_errors.ex` (`stale_write?/1` — ALSO in slice 4's commit for `not_found?/1`; fold into whichever lands first), `lib/jido_claw/forge/persistence.ex` (fence block + `current_checkpoint/1` pointer loader + `context_for_resume/1` re-pointed + `latest_checkpoint/1` demoted-to-helper comment), `lib/jido_claw/forge/runner.ex` (`materialize_config/1` optional callback), `lib/jido_claw/forge/recovered_spec.ex` (`codec_stamp/1` + `runner_config/1` v1 codec wired into `normalize/1`), `lib/jido_claw/forge/runners/claude_code.ex` (armed modes + materialize + shared `@default_*`), `lib/jido_claw/forge/runners/codex.ex` (same + `do_parse_output` thread capture), `lib/jido_claw/forge/manager.ex` (`recoverable?/1` matrix, @doc false public), `lib/jido_claw/forge.ex` (`wake/2` via pointer), `lib/jido_claw/orchestration/run_failure.ex` (2 verified rejection rules + `fallback_marker?/1` + `safe_message/1` hardening — NOTE: this file belongs to commit-slice 1; the operator may fold these #2-driven additions there or keep them with slice 3), `test/support/stub_sandbox.ex` (`program_run_sequence/2` + `run_args_history/1` + run_queue), tests: `env_test`, `docker_test`, `recovered_spec_test`, `context_builder_test` (checked saves), `claude_code_test`, `codex_test`, `run_failure_test` (rules + marker + at-line-401 note), `docs/plans/pre-argus-wave-a/README.md` (13 Deviations entries total).
- **Off-plan (gate keep-green)** — MODIFIED `lib/jido_claw/mcp/consumer.ex` (reach smell fix at :592; could ride any slice or go standalone as `fix: reach smell in MCP consumer policy transition`).
- **Plan home** — NEW `docs/plans/pre-argus-wave-a/README.md` (commit with slice 1 or standalone).
- Slices 1+2+4 are commit-ready NOW (subject to the operator's own precommit run); slice 3 is NOT commit-ready (10 of its 13 build steps remain — committing now would ship fence plumbing with no consumers, which is harmless but pointless).
- Untracked noise predating this session: `.claude/plans/…` (this file), `.claude/skills/plan-prompt/`.

### Fence semantics as BUILT (slice 8+ consumers call these EXACT shapes)

All in `JidoClaw.Forge.Persistence`; every fenced write takes the incarnation
token; the token authorizes WRITES only (reads compare epoch stamps).

- `metadata["forge_recovery"]` = `{"epoch", "token", "current_checkpoint_id",
  "recovery_degraded"}`. Pair reader: `stored_recovery_pair(session_id)` →
  `%{epoch: pos_int, token: binary} | nil` (requires epoch > 0 — a virgin/
  malformed object reads nil, and nil is the ONLY state where the mint
  accepts `expected: nil`).
- `mint_resume_epoch(session_id, expected_pair_or_nil, transplant)` →
  `{:ok, %{epoch:, token:}}` | `{:error, :stale_mint | :no_session |
  :mint_failed | :persistence_disabled}`. `transplant :: %ResumeState{} | nil
  | (locked Session.t -> ResumeState.t | nil)` — the FUN form runs inside the
  FOR-UPDATE critical section (recovery's select-under-lock; fresh/terminal
  reuse pass nil = blank). Installs `metadata["resume"]` wholesale (`%{}` or
  `%{"state" => encoded, "guidance" => marker}`) stamped `{new_epoch, 0}`
  (marker epoch re-stamped too), clears the pointer, resets degraded.
- `anchor_session(session_id, %ResumeState{}, token)` → `:ok` |
  `{:error, :stale_resume_write}` (fence miss — caller logs + DROPS) | `nil`
  (infra, best-effort). Fence: token match AND encoded `revision` STRICTLY
  newer than stored (absent state ⇒ `-1`, so revision 0 post-mint means the
  first mirror writes revision 1). **The harness owns revision bumping** —
  ResumeState.stamp before each mirror.
- `save_recovery_checkpoint(session_id, sequence, snapshot_map, metadata_map,
  guidance_marker_or_nil, token)` → `{:ok, %Checkpoint{}}` | `{:error,
  :stale_resume_write | :no_session | :not_persisted |
  :persistence_disabled}`. CHECKED (never best-effort): pointer-FIRST under a
  pre-minted row UUID, one transaction; sets pointer + clears degraded +
  mirrors the marker; a stale refusal writes NOTHING. `marker nil` ⇒ guidance
  path untouched. DECIDED (slice 4): the epoch authority is the snapshot's
  encoded resume state (`runner_state_snapshot["resume"]["state"]["epoch"]`);
  checkpoint `metadata` stays free-form.
- `mark_recovery_degraded(session_id, token)` → `:ok | {:error,
  :stale_resume_write} | nil`. Cleared by the next successful checked save.
- `ResumeState` codecs: `encode_state/1` (both stores), `encode_guidance_marker/1`
  (metadata), `encode_guidance/1` (checkpoint, `{:ok, map|nil} | {:error,
  {:guidance_encrypt_failed, _}}` — STRICT, for checked saves),
  `decode_state/1` (`{:ok, rs} | :error`), `decode_guidance/1` (`{:ok,
  copy|nil} | {:error, :corrupt_guidance}`), `select/4` (md_state,
  md_guidance, cp_state, cp_guidance → merged rs | nil; text only from a
  checkpoint WINNER; consumed keeps its marker so answers never resend).

### Runner armed-mode API as BUILT (slices 8–9 consume these EXACT shapes)

- **Arming**: `runner_config[:resume] :: :off (default) | :armed`, read at
  `init/2`. Off is byte-identical to HEAD (PR-3 pins hold, extended with
  `--session-id`/pwd refutes). Armed claude captures `pwd` once at init
  (state keys `resume: %ResumeState{}` + `resume_cwd`); armed codex uses the
  config-declared `-C cwd` as the anchor workdir (NO pwd exec, no extra
  state key — `state.cwd` is the gate input).
- **run_iteration opts read by the runners** (all optional; each skips
  cleanly when absent): `:prompt` (continuation turns use it EXCLUSIVELY —
  absent falls to the `"Continue."` nudge, NEVER `state.prompt`),
  `:forge_session_id`, `:incarnation_token`, `:incarnation_epoch` (claude
  pre-spawn persist stamps `{epoch, rs.revision + 1}`), `:timeout`.
- **Pre-spawn persist seam** (claude fresh-armed only):
  `Application.get_env(:jido_claw, :forge_resume_writer)` — a 3-arity fun
  `(forge_session_id, %ResumeState{}, token) -> :ok | {:error, :stale_resume_write} | nil`;
  default `&Persistence.anchor_session/3`. Anything but a 3-arity fun falls
  back to the default. Tests observe pre-spawn ordering by snapshotting
  `StubSandbox.run_args_history/1` inside the injected writer (empty ⇒
  pre-spawn).
- **metadata.state contract**: EVERY armed path — success, error, timeout —
  returns the FULL updated runner-state map at `result.metadata.state`
  (resume replaced, `:iteration` bumped). The harness merges it wholesale at
  iteration_complete :707–714. Default-off returns NO metadata.state.
- **metadata.error_details contract** (armed terminal failures):
  `RunFailure.error_details(kind, extra)` ⇒ `%{failure_kind: kind, retry:
  boolean}` (+ `resume_rejected: true` ONLY on session_poisoned +
  continuation). `result.error` is one of: the known label
  (`"harness_timeout"`, `"runner_unavailable"`, `"<vendor> cli failed"`), a
  bounded first-non-JSON-line of the output (recognized string classes), or
  `{:fallback_marker, trimmed_output}`. Slice 8's harness `:error` arm
  should PREFER `metadata.error_details.failure_kind` over re-classifying
  `result.error` (decision made; log as deviation when implemented).
- **Anchor lifecycle in-runner** (never auto-retried): claude fresh-armed
  mints client-side (`anchor_fresh/3`: poisoned → `rearm_new_anchor`
  :client; unanchored → `mint_client`; anchored-but-gated → `clear(:new)`
  then mint) and id-verifies against the `"system"` event echo (mismatch ⇒
  `clear(:new)` + ResumeSignal, kind `:agent_unknown`). Codex captures
  `thread.started` post-run (`capture_anchor/4`), promotes provisional →
  anchored ONLY on a clean `:done` (`maybe_trust/2`), refuses poisoned-id
  reuse, echo-verifies continuations. Poisoning happens in
  `ResumePolicy.apply_resume_policy/3` on `resume_unsafe?(kind)` AND an
  anchor id present.
- **`ResumeSignal.emit_failed(kind, details)`**: SignalBus
  `"jido_claw.forge.resume.failed"` + Forge.PubSub `{:resume_failed,
  payload}` (only when `details.session_id` is a binary) + Logger.warning.
  Payload = whitelist `[:session_id, :anchor_id, :mode, :runner,
  :resume_rejected]` + `:kind` + `:reason` (format_reason-bounded +
  Patterns-redacted). Total (rescue → :ok). Emitted BEFORE the attempt
  returns — driver retry decisions happen after.
- **`ResumePolicy`** (`forge/runners/resume_policy.ex`) owns the shared
  vendor policy: `armed_failure/7`, `attach_runner_state/3`,
  `serialize_state/1` (canonical `{"iteration", "resume" => %{"state" =>
  encode_state(rs)}}` — resume key ABSENT for off sessions),
  `restore_state/2` (config-owned arming: never re-arms an off session;
  garbled copy ⇒ fresh armed state kept; iteration restored). Both runners
  delegate their `@impl` serialize/restore here.
- **`RunFailure` additions**: string rules `"no rollout found"` +
  `"no conversation found"` (verified live); `fallback_marker?/1` (≤320
  bytes, single-line, non-empty, not `{`-leading); `safe_message/1` now
  calls the exception's OWN `message/1` under rescue (never
  `Exception.message/1`'s shield text — its embedded line numbers
  false-positive the `\b401\b`-class rules).
- **`RecoveredSpec` codec**: `codec_stamp(:claude_code | :codex)` ⇒
  `%{runner: "…", v: 1}`; `runner_config/1` — unstamped ⇒ `{:ok, unchanged}`
  (legacy/non-vendor lane), stamped ⇒ typed decode keeping the stamp
  (N-recovery re-persist safety), refuse-on-missing/invalid for claude
  {access, config_sync, strict_mcp, allowed_mcp_tools} / codex {access,
  config_sync}; wired inside `normalize/1` (an undecodable stamped config
  refuses the whole spec → wake `{:error, {:unrecoverable_spec, …}}`).
  Attempt-scoped values (mcp_config_path/json, mcp_server_url) are
  whitelist-dropped.
- **`Persistence.current_checkpoint/1`**: the ONLY recovery selection
  authority (pointer + ownership check; warns on foreign/dangling);
  `context_for_resume/1` keys off it; `Manager.recoverable?/1` (@doc false
  public) adds the phase list + `resume_epochs_match?/2` (every PRESENT
  copy's epoch == fence epoch).

### Ash traps discovered this session (probe-verified; do NOT rediscover)

- **`Ash.Changeset.filter/2` from a change's `atomic/3` is SILENTLY DROPPED**
  (ash 3.29.3): `record_added_filter` only records in the `:pending` phase,
  and the atomic-upgrade path (`Ash.Actions.Update` ~line 155) overwrites the
  rebuilt changeset's `filter` with the original's never-recorded
  `added_filter` — the UPDATE lands with pk+tenant WHERE only. Fences must
  ride INSIDE the atomic expression: `expr(if fragment(<fence>) do <jsonb>
  else error(Ash.Error.Changes.StaleRecord, %{...}) end)` — the
  `OptimisticLock` idiom. Shipped this way in all three fenced Session
  changes.
- **ash_postgres savepoint-contains in-expression errors**: `with_savepoint/3`
  (data_layer.ex:2663) wraps error-capable atomic updates when inside a
  transaction and ROLLS BACK TO the savepoint on an `ash_error:` raise — the
  enclosing transaction STAYS USABLE. This is what lets the checked save
  treat a fence miss as a tagged `{:refused, :stale_resume_write}` success
  value instead of a rollback.
- **In-txn refusals are tagged SUCCESS values** (`{:refused, reason}` /
  `{:minted, pair}` / `{:saved, cp}`), never in-txn `{:error, _}` returns —
  `Ash.transaction` wraps rollback/error values opaque via `to_ash_error`
  (the GateDisposition-documented behavior). Genuine write failures use
  `Ash.DataLayer.rollback`.
- **`prepare(build(lock: "FOR UPDATE"))` in a read action returns ZERO ROWS**
  (no SQL even emitted). Compose locks manually on the generated query
  builder: `Session.query_to_by_name_global(sid) |> Ash.Query.lock("FOR
  UPDATE") |> Ash.read_one()` — also satisfies AshCredo's
  prefer-code-interface check.
- Probe method when Ash behaves oddly: throwaway test file + telemetry on
  `[:jido_claw, :repo, :query]` printing `meta.query`/`meta.params`; delete
  the probe after.

### Pick-up notes (read before resuming)

- **Decisions already made — do not re-litigate**: the three interview decisions (fullest resume cut incl. converting the single-shot consolidator to a true multi-iteration driver; exit table 4=not-found/5=unreachable/6=auth; kill_tree + graceful window + ChildTracker, never setsid) and the four PORT sign-offs (claude client-minted pre-spawn anchor; codex provisional-until-clean-exit; driver-side ledger-gated retry; `:local`-only crash-native-resume).
- **Deviations logged so far** (13 entries in the plan home doc `docs/plans/pre-argus-wave-a/README.md`, continue there): 3 from #1/#4; 5 from slices 1–3 (fence-in-expression, pointer-first checked save, manual FOR-UPDATE, env/docker details, reach fix); 5 NEW from slices 4–7 — codec engages on the STAMP not the runner type (decoded output keeps the stamp for N-recovery re-persist); armed-row epoch rule reads PRESENT copies + `recoverable?/1` @doc false public; `incarnation_epoch` joined `incarnation_token` as a run_iteration opt (a 0-stamped pre-spawn copy would brick the epoch match); two producer-exact rejection rules + the `safe_message` shield hardening (found via the totality test landing at literal line 401 → `\b401\b` false-positive); shared vendor policy extracted to `Runners.ResumePolicy` under ExDNA (scoped `ex_dna:disable-for-lines` on the twin dispatchers, safety_gate.ex precedent).
- **ResumeState design decisions already settled** (tested; don't re-open): sticky poison + `rearm_new_anchor/4`-only exit; guidance `consumed` keeps a rev-bumped marker; `select/4` guidance text only from a checkpoint status-winner.
- **ElixirLS noise**: after every runner edit it re-reports "materialize_config not a callback" — STALE (runner.ex not re-elaborated); `mix compile --warnings-as-errors` is the authority and is green. Plus the known pre-existing dialyzer noise in `type_module.ex`/`git.ex`/`session_manager.ex`/`endpoint.ex`.
- **StubSandbox gotcha**: `exec_response` is GLOBAL per client — the armed-claude pwd probe shares it with mkdir/FileSync execs; programming `{"/sandbox/work\n", 0}` works because mkdir ignores output and checked writes see exit 0. `program_run_sequence/2` queues per-call responses (falls back to `program_run/2` when drained); `run_args_history/1` returns all argvs chronologically.
- **Error-shape conventions preserved**: claude timeout passes the partial `output` into `Runner.error`; codex timeout passes `""` (both pre-existing). `{:known, label}` arms never classify output (partial output must not sway a timeout's class).
- Toolchain/process: `mise exec -- mix …`; gates bare, never piped; a PostToolUse formatter hook rewrites files after Write/Edit (re-read a region before editing it again if it may have been reformatted).
- Async postures: `resume_state_test`/`recovered_spec_test` async: true (pure); `persistence_resume_fence_test`/`manager_recovery_test`/`wake_test`/`context_builder_test` TenantCase async: true (sandboxed DB only); `claude_code_test`/`codex_test`/`resume_signal_test` async: false (app-env seams + global PubSub); consolidator/harness suites stay async: false when slices 8–9 touch them.
- **Codex/claude live probes are DONE** — the facts are recorded in code comments and test fixtures; do not re-run CLIs next session unless a new question arises (the one unprobed cost: a real `codex exec --json` model turn was attempted and conveniently failed pre-model with a 400, still emitting `thread.started` first — which is itself the recorded fact that thread ids arrive before any turn outcome).
- Session task-tracker state at pause (session-scoped; this doc supersedes it): tasks #1–#4 completed (slices 4–7), #5 in_progress ZERO code (slice 8 harness), #6–#10 pending (slices 9–13), #11 pending (precommit + files-to-stage).

---

*(Original approved plan follows, annotated. The Items #2+#3 section is the
authoritative remaining spec.)*

## Context

`docs/plans/pre-argus-do-now/README.md` Wave A: **#1 run-failure taxonomy → #2 native CLI session resume (+#3 transcript honesty riding it) → #4 exit-code tiering**. All four items land commit-ready but uncommitted; `mix precommit` green is the completion bar; greenfield — no compat shims, no DB migration anywhere. Run mix via `mise exec -- mix …`; gates bare, never piped.

**Operator decisions (interviews):**
1. Resume scope is the fullest cut: runner machinery + crash-recovery + `apply_input` continuation + the memory consolidator converted to a true multi-iteration driver (it is single-shot at HEAD — `run_server.ex:465`; reconciliation records the falsified source claim).
2. Exit codes: 2 keeps usage+validation+config; **4 = not-found, 5 = provider-unreachable, 6 = provider-auth**.
3. Group-kill: `kill_tree/1` stays the house mechanism; add a graceful window for host-tier runner teardown and a VM-shutdown ChildTracker.

**Hard gates during implementation:**
- **PORT-map sign-off**: `docs/exploration/pms/multica/PORT-MC1-1.md` written and explicitly signed off (AskUserQuestion) **before any #2 code** (docs/exploration/README.md:111-135). #1/#3/#4 are rubric lifts / deliberate divergence — no map.
- **Plan home**: step 0 creates `docs/plans/pre-argus-wave-a/README.md` (adapted from this plan) with a `## Deviations` section maintained as work proceeds.

---

## Item #1 — `JidoClaw.Orchestration.RunFailure` (MC1-4 + OR3-2 + BO2-3 riders) — ✅ DONE 2026-07-11

*(Shipped as specified, plus two logged deviations — timeout-phase-before-dig
and the reshaped hostile-Inspect row; see the plan home doc's Deviations.)*

### Module `lib/jido_claw/orchestration/run_failure.ex`

Mirrors `orchestration/verdict.ex` conventions: provenance header comment (multica MIT, failure.go/classify.go + riders), bounded rendering (`@inspect_opts [limit: 5, printable_limit: 120]`, `@max_reason_graphemes 240`), whitelist decode, never `String.to_atom`. Sits ABOVE `Forge.Error.classify/1` (its `{kind, recovery}` contract is pinned — compose, never break).

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
                                  # :failure_kind/"failure_kind", :reason/"reason") —
                                  # callers can never override policy bits or
                                  # reintroduce :reason (retry-hint diggers read it;
                                  # LoopGuard's :trigger precedent).
```

**Totality contract**: the entire public bodies of `classify/1` and `format_reason/2` are wrapped in a final `rescue`/`catch` (exceptions, **throws, and exits**) falling back to `:agent_unknown` / a bounded fallback string — totality is unconditional, not dependent on every internal branch being safe. Inner extraction (`Exception.message/1` on hostile exceptions, `String.downcase/1` on invalid UTF-8 via a `String.valid?/1`-guarded `safe_downcase/1`) is additionally guarded so the fallback is the backstop, not the mechanism.

### The 22-kind enum

Adapted from multica's 21: DROP `queued_expired`/`runtime_offline`/`runtime_recovery` (daemon members) and `agent_blocked` (their producer-less wart); RENAME `timeout` → `stalled_wall_clock`; ADD `stalled_no_output`, `user_cancelled`, `agent_fallback_message`, `agent_semantic_inactivity`, `agent_session_poisoned`.

**Platform (unprefixed)**
- `iteration_limit` — ¬retry, resume-unsafe. Producer = the iteration BOUND only: `Forge.run_loop`'s `:max_iterations_reached` (forge.ex:159) reworked to carry it + the consolidator loop's bound arm. Deadline exhaustion is `stalled_wall_clock`, never this.
- `api_invalid_request` — ¬retry, resume-unsafe (400 baked into history).
- `stalled_wall_clock` — retry. Producers: `"harness_timeout"` (claude_code.ex:145, codex.ex:165), sandbox `{_, :timeout}`, exit 124, run-deadline exhaustion.
- `stalled_no_output` — retry. **Producer-pending** (no silence watchdog exists; Wave B #8 registers the composer-level stall) — documented per-kind, never a silent wart.

**Non-failure**: `user_cancelled` (`failure?` false; producers exist: `cancellation.ex` `run_cancelled`, Forge `:cancelled` phases).

**Agent (`agent_` prefix)**: `agent_provider_auth_or_access` (→ exit 6) · `agent_provider_quota_limit` · `agent_provider_capacity_or_rate_limit` · `agent_provider_server_error` · `agent_provider_network` (→ exit 5) · `agent_timeout` · `agent_process_failure` · `agent_empty_or_unparseable_output` · `agent_context_overflow` · `agent_missing_config` · `agent_model_not_found_or_unavailable` · `agent_runtime_version_unsupported` (producer-pending) · `agent_runtime_missing_executable` (exit 127, `"runner_unavailable"`) · `agent_fallback_message` (¬retry, resume-unsafe; producer = #2's ≤320-char fallback-marker detection) · `agent_semantic_inactivity` (retry ∧ resume-unsafe) · `agent_session_poisoned` (retry ∧ resume-unsafe; bosun's codex family — `invalid_encrypted_content`, missing-rollout-path, `tool_call_id`/400 — plus the recognized invalid-anchor rejection class: session/thread not found/expired/corrupt) · `agent_unknown` (total fallback).

Derived sets: retryable = {stalled_wall_clock, stalled_no_output, agent_semantic_inactivity, agent_session_poisoned}; resume_unsafe = {iteration_limit, agent_fallback_message, api_invalid_request, agent_semantic_inactivity, agent_session_poisoned}. The overlap (semantic-inactivity, session-poisoned) is the point of two independent predicates. Docs state the narrow retryable set as a conservative multica-faithful default and a consumer policy seam — NOT justified by "HTTP retries already happened" (false for Anthropic 5xx in the current stack, osa FWB:176).

### classify/1 — rule order

1. Unwrap `{:error, r}` → recurse.
2. Cancels (`:cancelled`, `:run_cancelled`, `{:cancelled, _}`, `%{status: :cancelled}`) → `user_cancelled`.
3. **Nested-cause unwrapping before generic wrappers, depth-bounded (3)**: `JidoClaw.Error.ExecutionError` (and peer wrappers) first digs known nested causes — `details.cause` / `details["cause"]` (the Normalize layer wraps Jido.AI failures there, normalize.ex:389) — and classifies the nested leaf when specific. **Splode class containers** (a class struct wrapping an `errors` list): classify every leaf, then pick by an **explicit precedence rank over kinds** (order-invariant — permuting leaves cannot change the answer; `[agent_unknown, agent_process_failure]` → `agent_process_failure`): auth > quota > rate > api_invalid_request > model > server > network > session_poisoned > context_overflow > timeout-kinds > missing_config/missing_executable > empty_output > process_failure > unknown. Permutation tests pin it.
4. Struct clauses (aliased; shapes confirmed against deps source at build time): `Jido.AI.Error.API.{Auth, RateLimit}`; `Jido.AI.Error.API.Request` dispatching on its `kind` field (:timeout / :network / :provider+status); `%ReqLLM.Error.API.Request{}` by status (401/403→auth, 429→rate, 400→api_invalid_request, 404→model, 5xx→server), **nil status → `cause`-dispatch** (timeout-shaped → agent_timeout, transport → agent_provider_network); `%ReqLLM.Error.API.Response{}` (parse/unexpected-output class, deps/req_llm/lib/req_llm/error.ex:73) by status, **nil → agent_empty_or_unparseable_output**; `Jido.Error.TimeoutError` AND `Jido.Action.Error.TimeoutError`; first-party leaves (`ConfigError` → agent_missing_config; `ExecutionError` by phase after the cause-dig; `ValidationError` → agent_unknown — a boundary error, documented); Forge Splode structs → compose via `Forge.Error.classify/1`; any other exception → string arm via guarded message extraction.
5. Tuples/atoms: `{_, :timeout}` → stalled_wall_clock; `{_, :output_limit}` → agent_process_failure; `{_, 124}` → stalled_wall_clock; `{_, 127}` → agent_runtime_missing_executable; `{_, int}` → agent_process_failure; `{:fallback_marker, _}` → agent_fallback_message; `{:iteration_limit, _}` / `:max_iterations_reached` → iteration_limit; `:unauthorized` → auth; `:unreachable` → network.
6. String arm: `safe_downcase/1`, ordered `@string_rules` via `Enum.find_value/3`; numeric codes only boundary-safe (`~r/\b401\b/`-class) with negative tests ("40123", "error 4010").
7. `_ → :agent_unknown`.

### Consumers (control flow UNCHANGED — enrich, never redecide)

- **Forge harness `:error` arm** (harness.ex:684-686): classify once; broadcast becomes `{:error, %{reason: result.error, kind: kind}}` (subset-match consumers verified); `Telemetry.emit_run_failure(kind, provenance)`; `failure_kind` added to the existing `log_event("iteration.completed", …)` metadata (:703-708). No session-state change.
- **Composer Lane-B** (route_composer.ex:2269): kind computed beside `Verdict.format_reason({:wave_execution_failed, reason})`, threaded into the **non-durable Trace only** via an optional 4th arg to `emit_infra_observability/3` — durable `stage_infra` markers/event shapes untouched (welded wave commits are law).
- **Telemetry** (core/telemetry.ex): `counter("jido_claw.run_failure.total", tags: [:kind, :provenance])` + `emit_run_failure/2` beside `emit_composer_infra/2` (:298-305). `all_kinds/0` is the pre-warm export (no reporter harness exists — residual, documented).
- **Envelope helper**: `error_details/2` ships here and is consumed by #2's runner terminal errors.

### Tests `test/jido_claw/orchestration/run_failure_test.exs` (async: true, verdict_test.exs table shape)

Classify rule table over every producer input (runner strings, sandbox tuples, exit codes, workflow shapes, `Jido.AI` kind-dispatch rows, ReqLLM status + nil-status-by-module + `cause` rows, Splode container permutation rows, both TimeoutError leaves, first-party leaves, `{:fallback_marker,_}`, `:max_iterations_reached`, `:unauthorized`/`:unreachable`); **integration rows: build auth and network errors, pass through `Error.Normalize.reasoning_error/2` FIRST, then classify — must still yield auth/network** (the unwrap path exits 5/6 depend on); totality over garbage, invalid UTF-8, a hostile exception whose `message/1` raises, a thrower, and an exiter; boundary-safety negatives; exact derived-set membership + the retry∧resume-unsafe overlap; `failure?` false only for user_cancelled; decode round-trip + `"bogus"` → :error; provenance; bounded format_reason; `error_details/2` reserved-key stripping (atom AND string forms).

### Docs + reconciliation

New page `docs/system/run-failure.md` (type: subsystem; the 22-kind table WITH producer-status column; residuals: producer-pending kinds, the retryable-policy seam, pre-warm) + index row + AGENTS.md Key Patterns bullet — atomic (system_docs.check bidirectional pointer). `docs/TRUST-BOUNDARIES.md` gains a "Retry ≠ resume" section (engine-classified failure shape; two independent policies; `:failure_kind` never `:reason`; LoopGuard classifies repetition signatures, not failure class). `verdict-normalizer.md` cross-link sentence + `verified:` bump. Reconciliation (dated Status lines): MC-FIRST-WAVE item 1; multica FWB MC1-4 (note `agent_blocked` dropped for its own wart); OR-FIRST-WAVE item 3 back-ref + orca FWB OR3-2; bosun FWB BO2-3 (taxonomy half; the poisoned-list half reconciles with #2); pre-argus README row #1/§1.

---

## GATE: PORT-MC1-1.md + sign-off (before any #2 code) — ✅ CLEARED 2026-07-11

*(Map written and explicitly signed off — all four open divergences confirmed
as mapped; recorded inside the map's Sign-off gate section.)*

Per docs/exploration/README.md:122-135: header (entry link, multica `129efb768` + jido_radclaw HEAD, date); source mechanism summary (daemon eager-pin, resolveSessionID clear, gateResumeToReusedWorkdir, poisoned.go, env scrub, deadlock goroutines); side-by-side shapes; behaviors table **preserved / deliberately changed / dropped** — the load-bearing changed/dropped rows: claude anchor client-minted via `--session-id` pre-spawn (more eager than their first-event capture; enabled by batch parsing); codex anchor only-after-clean-exit (CH2-6); **retry authorization driver-side against a server-authoritative effect ledger** (their daemon-side "failed resume with no established session → retry once fresh" maps to our ledger-gated driver retry); epoch/token fencing (no multica equivalent — forced by our global-Task/recovery races); recovery owner = RunServer for consolidations; crash-native-resume scoped to `:local` sandboxes; kill_tree + preserved-set graceful phase, not setsid (os_cmd.ex:14-17 deliberate); stderr merged not tailed; runtime-pinning dropped. Edge cases vs their test names. Sign-off via AskUserQuestion; #4 may proceed during any wait.

---

## Items #2+#3 — Forge native CLI session resume + transcript honesty — 🔶 IN PROGRESS: build steps 1–7 ✅ DONE as specced + logged deviations (env denylist, ResumeState, fence, config codec + pointer loader, claude armed, codex armed, ResumeSignal/poison/fallback); steps 8–13 remain (this section is the authoritative spec; "Fence semantics as BUILT" + "Runner armed-mode API as BUILT" above record the shipped API shapes)

### `JidoClaw.Forge.ResumeState` — opaque struct with transition constructors

Fields: `arming (:off | :armed)`, `ownership (:client | :backend)`, `status (:unanchored | :provisional | :anchored | :poisoned)`, `session_id` (String, validated ≤512 chars / no control chars — argv data, never shell text), `workdir`, `session_start_source (:startup | :resume | :clear | :new | :fork | :compact` — HD2-2; we produce startup/resume/clear/new; fork/compact documented-unused)`, `retry_used`, `pending_guidance` (see guidance lifecycle), `anchored_at`, `epoch` (integer stamp of the incarnation the copy was written under), `revision` (per-incarnation monotonic int), `guidance_rev` (independent counter — see recovery codecs). **No token field** — the token is a write capability living in `metadata["forge_recovery"]`, passed to writers for fencing, never stored in a state copy. **Opaque**: constructors/transitions enforce cross-field invariants (`mint_client`, `capture_backend`, `trust`, `clear`, `poison`, `rearm_new_anchor` — poisoned ∧ anchored impossible; `retry_used` resets when a new anchor is established; a poisoned anchor id is never reused; a later clean fresh run MAY establish a new anchor).

### Fencing — epoch + token (ordering by integer, writes by CAS) + the current-checkpoint pointer

- **The incarnation fence is HARNESS-level, not vendor-level, and lives in `metadata["forge_recovery"]` for EVERY claimed session** — resume-off runners have no ResumeState, yet checked saves and ChildTracker still need `{epoch, token}`. `metadata["resume"]["state"]` stays specific to vendor continuation. ResumeState itself carries no token (the token is a write capability, never part of a stored copy); stored copies are stamped `{epoch, revision}` for selection.
- **Token threading is explicit end-to-end**: the harness passes the incarnation token to each attempt as an ephemeral **`incarnation_token` `run_iteration` option** (beside `forge_session_id`; never persisted), and every fenced write takes it as an Ash action argument marked **`sensitive?: true`** — `define(:anchor_resume, args: [:resume, :incarnation_token])`. **A stale runner uses the token captured when its iteration began — it never re-reads the current token**; a rotated incarnation therefore invalidates its writes automatically (`:stale_resume_write`).
- **Mint exactly once per Harness incarnation, IMMEDIATELY after claiming — before entering `:provisioning`/`:resuming`** (recover_runner/2 is too late under the provision → bootstrap → runner-recovery order, harness.ex:388 — terminal reuse would expose the old pointer during a recoverable phase): `Persistence.mint_resume_epoch(session_id, expected, transplant)` where `expected` is the **prior `{epoch, token}` (CAS) — `nil` only when no stored pair exists** — and `transplant` is the **complete sanitized vendor state selected for carry-over** (metadata-codec shape; blank for fresh starts, terminal reuse, and resume-off sessions). The filter-guarded atomic update, ONLY when the stored pair matches `expected`: increments the epoch, stores a fresh token, **installs the transplanted vendor state at `{new epoch, revision: 0}`** (post-mint metadata is never stale relative to the selected checkpoint and never ties it), and **clears `metadata["forge_recovery"]["current_checkpoint_id"]`**. Mismatch ⇒ `{:error, :stale_mint}`. A stale Harness holds a stale pair and **cannot** mint, replace the token, or fence out the legitimate incarnation. **Snapshot selection and mint run in ONE locked `Ash.transact` critical section** (Session row locked across read-select-mint — the existing FOR-UPDATE pattern): an outliving old task cannot bump a state revision or move the pointer between selection and mint, so the mint can never install a stale transplant (a deliberately-paused old-writer race test pins this). Recovery sequencing: recovery claim → locked {select snapshot per the recovery codecs + CAS-mint with it as `transplant`} → **immediately write the transplanted checkpoint under the new token** (checked, below).
- **Control data and state live at SEPARATE JSON paths** — the ordinary anchor mirror can never erase the pointer it must outlive:
  - `metadata["forge_recovery"]` → `{epoch, token, current_checkpoint_id, recovery_degraded}` (harness-level control data);
  - `metadata["resume"]["state"]` → the sanitized vendor ResumeState;
  - `metadata["resume"]["guidance"]` → the `{status, guidance_rev}` marker.
  `anchor_resume` updates ONLY the state path (fenced against `forge_recovery`'s pair); the checked checkpoint transaction updates ONLY the recovery pointer + guidance marker; mint updates the fence + state + pointer in its one atomic update. **Nested JSONB writes follow the existing `SetCompactionSnapshot` parent-object merge pattern** — an absent intermediate object must not turn `jsonb_set` into a no-op. **A stale incarnation's failed checkpoint write is token-fenced too** — it surfaces `:stale_resume_write` and can never mark a newer incarnation degraded. Concurrency tests: checkpoint-then-anchor, anchor-then-checkpoint, simultaneous sibling-path updates — the pointer survives all three.
- **The `current_checkpoint_id` pointer is the checkpoint-selection authority — through ONE loader on EVERY path**: the CHECKED checkpoint save creates the Checkpoint row AND sets the pointer (and clears `recovery_degraded`) **in one transaction** (token-fenced). A single **`Persistence.current_checkpoint/1`** (reads the pointer, loads the row, requires `checkpoint.session_id == session.id`) is used by `Manager.recoverable?/1`, **`Forge.wake/2`** (which today independently calls `latest_checkpoint/1`, forge.ex:49, and could otherwise restore checkpoint B after Manager validated checkpoint A), AND **`Persistence.context_for_resume/1`** (persistence.ex:463 — same independent `latest_checkpoint` today). Wall-clock `latest_for_session` sorting (checkpoint.ex:42) is no longer a selection authority anywhere. Test: direct wake AND Manager-driven wake with a newer UNPOINTED checkpoint present — both restore the pointed one.
- **Recovery lifecycle matrix** (`Manager.recoverable?/1`, manager.ex:247, changes to exactly this — NOT a blanket epoch rule, which would regress resume-off runners that have no ResumeState):

  | Session class | Recovery rule |
  |---|---|
  | Claimed + armed | pointed checkpoint (ownership-checked) **+ epoch match**: state/checkpoint copies' epoch stamps compared against `forge_recovery.epoch` — **the token never participates in reads; it only authorizes writes** |
  | Claimed + resume off (shell/workflow/custom) | pointed checkpoint + session ownership check only — **no ResumeState required** (generic Forge recovery keeps working) |
  | `claim: false` OR persistence disabled (`claim_session` succeeds without a row) | local in-process incarnation token; **no durable recovery** |
  | Terminal row reuse (fresh `:start` of a completed/cancelled/failed session — `Session.start` omits metadata from upsert fields, session.ex:58, so old metadata SURVIVES) | init-time mint **CAS's from the STORED pair** (expected ≠ nil) into a **blank fresh transplant**, clears the old pointer — the previous native anchor is never carried |

  `expected == nil` is therefore refined: nil only when no stored pair exists at all. Recovery tests: resume-off shell runner recovers via pointer+ownership; persistence-disabled Harness gets local-token posture; armed completed/cancelled/failed Session reuse starts blank.
- **Ordering authority is the epoch integer** (DB-incremented), never UUID comparison; `revision` orders within an incarnation.
- **Every resume-state write requires the CURRENT token**: `anchor_resume` is filter-guarded on `stored.token == caller.token AND caller.revision > stored.revision`. **Stale = a real ERROR** — the zero-rows-matched update surfaces as `{:error, :stale_resume_write}` (mapped from Ash's stale/notfound shape), logged and dropped by callers; never a silent success that preserved old state. Tests: sibling-key concurrency (both land), same-key stale token rejected WITH the error, stale-cannot-mint (CAS mismatch).
- **No-DB path** (`claim: false` sessions have no Session row — harness.ex:1504): a local incarnation is minted in-process — ResumeState may keep epoch `0`, but the **ChildTracker `incarnation_key` is the tagged `{session_id, {:local, uuid}}`** so reused session ids never collide; no CAS (nothing shared), no crash recovery (scoped below).
- ChildTracker keys are tagged `incarnation_key`s — `{session_id, {:durable, epoch}} | {session_id, {:local, uuid}}`; recovery selects among stored copies by the rules in "Recovery codecs" below.

### Recovery owner — RunServer owns consolidation recovery end-to-end

1. **Materialize-then-persist runner config, versioned per-runner codec, refuse-on-missing.** Concrete hazard this prevents: consolidator configs omit `access` (run_server.ex:531) so fresh claude runs `:full`; a defaulting codec would flip recovered sessions to read-only + empty `allowed_mcp_tools`, blocking the consolidator's own MCP tools. Each armed/recoverable runner exposes **`materialize_config/1` as a new OPTIONAL `Runner` callback** (required — enforced at session start — for armed/recoverable runners; pass-through for shell/workflow/custom/fakes with resume off) applying ALL its defaults (access, allowed tools, strict_mcp, config_sync, paths, timeouts, model, max_turns, effort, cwd). The session-start path persists ONLY materialized **static** config stamped `{"config_codec": {"runner": "claude_code", "v": 1}}`. `RecoveredSpec.runner_config/1` decodes via the versioned per-runner whitelist codec (string-keyed in, typed out; never `String.to_atom`); **missing/invalid security-critical fields (access, allowed tools, sandbox class, config_sync) ⇒ REFUSE recovery loudly** — never silently change behavior in either direction. The pinned string-keys test (recovered_spec_test.exs:149) updates to pin the codec. **Attempt-scoped values (tokenized MCP URL, per-attempt config paths) are NEVER part of persisted config** — they ride `run_iteration` opts only (see effect ledger).
2. **Initial checkpoint via the CHECKED save, completed BEFORE broadcasting `:ready`.** Failure does not brick the session: it sets an explicit **`recovery_degraded: true`** marker (Session metadata + Trace + `jido_claw.forge.recovery.degraded` signal); the session runs; recovery honestly refuses while degraded — enforced structurally, because the checked save is what sets `current_checkpoint_id` (a token-AUTHORIZED write), and recovery reads per the lifecycle matrix: the pointed checkpoint's **epoch stamp** must match `forge_recovery.epoch` (a stale pre-degradation checkpoint can never be selected; the token never participates in reads). **Self-healing: the first later successful checked checkpoint sets the pointer and clears the marker in its transaction** (transient-failure test pins this).
3. **RunServer retains lock, MCP endpoint, and `run_forge_home` across a harness crash**: on an abnormal harness exit (distinguished from an iteration error result), within the run deadline, it **closes the active attempt token FIRST, evaluates that attempt's ledger** (see crash-replay policy), then awaits Manager's recovered session and continues the loop. Resource teardown (`run_forge_home` delete at run_server.ex:488, endpoint close, lock release) moves to FINAL teardown only (clean terminal, watchdog, or recovery-wait exhaustion). Codex session files under `CODEX_HOME=run_forge_home` therefore survive recovery. **Cross-owner teardown handshake — session-wide, every epoch**: the Harness's own teardown runs detached from `terminate/2` (harness.ex:778), and a recovered run can have an OLD epoch's detached teardown still running while a newer epoch finishes — so RunServer's final-teardown task **synchronously calls `ChildTracker.graceful_teardown_session(session_id)`**: a session-wide barrier that marks the SESSION closing (a session-closing tombstone — any late registration for ANY epoch of the session is killed), sweeps every live epoch, joins in-flight epoch teardowns (idempotent), and returns only when all are complete — **before deleting `run_forge_home`**. The home directory is the LAST filesystem resource removed, never deleted under a CLI still inside any epoch's graceful window. `run_forge_home` is created **mode 0700 explicitly** (it now retains credentials + session data for the run's whole life). Cross-owner ordering test: a delayed CLI that keeps writing during the grace window — its home must survive until the sweep completes.
4. **Crash-native-resume is scoped to `:local` (HostShell) sandboxes.** Docker recovery creates a new microVM/workspace (docker.ex:91), destroy removes guest+workspace (:340), `run_forge_home` is not among the automatic mounts (:365), and the new workspace trips the cwd-gate. Docker-armed sessions get **in-run resume only** (continuations within one live sandbox); after a crash they go fresh via the cwd-gate, Trace'd honestly. The stable 0700 host-mounted session-dir design is recorded in the docs page as the named trigger if docker crash-resume becomes wanted.

### Harness-crash replay policy (explicit table)

After close-then-evaluate on the interrupted attempt:

| Interrupted attempt's ledger | Policy |
|---|---|
| Any mutation OR commit marker | **Terminal failure** — discard staging, publish nothing, no resend. |
| Zero effects | **One recovery replay**, gated by its own `crash_replay_used` latch (separate from the resume-clear latch) and the remaining deadline; the recovered driver re-issues the interrupted logical turn. Latch already used ⇒ terminal failure. |
| — | **Manager recovery by itself NEVER replays** — it restores process + state only; re-issue is exclusively the driver's decision. "Await recovery and continue" means the interrupted logical turn is re-evaluated (replayed once if effect-free, terminalized otherwise), never silently skipped. |

Tests: zero-effect crash → exactly one replay then continue; effectful crash → terminal, no replay, nothing published.

### Effect ledger — attempt-bound endpoint capabilities, close-then-evaluate

MCP calls and the task result arrive from different processes with **no ordering guarantee**; attribution must be capability-based, not time-based.
- **Each CLI invocation gets an attempt-bound MCP endpoint**: the loopback URL carries an opaque attempt token as a path segment. The consolidator Plug stamps **both `run_id` AND `attempt_token`** into the MCP context (plug.ex:20 currently extracts run_id only), and **token enforcement is centralized in the shared tool dispatcher** (tools/helpers.ex:20): every MCP call — readers included — validates against closed tokens centrally (a stale CLI cannot even read retry state, and a future mutating tool can't be forgotten); the ledger records mutators only. **Raw capability tokens are never logged** — a bounded digest only, where correlation is needed. **Tested through the real loopback HTTP route**, not only direct handler calls.
- **Claude**: a per-attempt **immutable mode-0600 config file with a unique per-attempt name** (never rewriting a shared file — an old process must not be able to reload a new attempt's capability). Note: the current MCP config is written to the host temp dir (scoped_endpoint.ex:84), not `forge_home`. **Codex**: per-invocation `-c` overrides. The tokenized URL + config path ride `run_iteration` opts only — never spec/checkpoint. **Config-file cleanup**: RunServer tracks ALL attempt config paths (today it tracks a single `temp_file_path`); each file is deleted only after its attempt's CLI/epoch teardown completes, with final teardown as the backstop deleting any survivors. No-temp-leak test across multiple continuation attempts.
- **Reserve-then-execute, serialized**: token validation and mutator-ledger reservation are ONE serialized RunServer operation — the effect is RECORDED before the mutation executes (the existing GenServer dispatch seam makes this idiomatic). "Accepted but still in flight" therefore cannot race close-then-evaluate: a close observes every reservation.
- **Close-then-evaluate**: on the attempt's terminal result OR harness DOWN, RunServer **closes the attempt token first** (later calls bearing it are rejected with a typed error the CLI sees), THEN reads the ledger. The crash path runs the same policy before any resend decision.
- **Retry authorization (driver-only)**: ONE fresh attempt iff `resume_rejected` (the recognized invalid-anchor class → `agent_session_poisoned`) AND `retryable?(kind)` AND the closed attempt's ledger shows zero mutations + no commit AND remaining deadline ≥ floor AND the per-anchor latch unset. `api_invalid_request` / `agent_fallback_message` (¬retryable): poison the anchor, NO auto-retry, honest error. Runners never auto-retry; ledger-less drivers (run_loop, plain harness callers) never auto-retry.
- Tests: a late mutation queued behind the terminal result → rejected + not attributed to the retry; crash after a mutation but before the result → ledger shows it → no retry.

### Publish gate — durable commit certificate, three-outcome reconciliation

`commit_proposals` today queues `:publish` immediately and can transact mid-attempt (run_server.ex:188, :248) — replaced: the MCP tool sets `commit_requested?` + **closes staging to further writes**; it never publishes. **Only the driver publishes.**
- **Publication authority (single rule)**: the explicit commit marker **plus a clean process exit (exit 0) of the committing attempt** — `:done` and `:continue` (claude's `:continue` specifically means `error_max_turns`, claude_code.ex:238) both qualify when the exit was clean and the attempt token matches the commit marker's. The commit marker is the model's terminal intent; the loop never continues past a commit (staging is closed — a later attempt could never match). A commit whose attempt ends in a genuine `:error`/timeout does NOT publish (terminal failure).
- **The publish transaction carries a durable identity**: `record_run` on `Memory.Resources.ConsolidationRun` gains a named **`:run_id` argument that sets the primary key inside the action** (idiomatic — never a broad `accept :id`; no migration), and `state.run_id` is passed so the run row written **in the same transaction** as the publish (run_server.ex:712) is the **commit certificate**. **All terminal audit rows (failed/incomplete runs) use the same deterministic id**, so reconciliation requires **`status == :succeeded`**, never mere row presence.
- **Three-outcome reconciliation** (on deadline the watchdog cancels and **awaits** the publish task, then reconciles): (a) row with the expected id AND `status == :succeeded` ⇒ commit won; (b) genuine NotFound — or a present row with a **non-success status** (`:failed`/`:skipped`-class terminal audit rows share the deterministic id and belong to this outcome) — after the publish task is definitely down ⇒ the transaction did not commit — nothing published; (c) **database/framework error reading the certificate ⇒ `publish_outcome_unknown`** — never republish, never claim nothing-published; retry the certificate read within the bounded reconciliation allowance, then surface the honest uncertain terminal (`stalled_wall_clock` with `%{publish_outcome: :unknown}` details).
- **Post-commit backfill hints**: the existing periodic BackfillWorker scan is the chosen authority — interrupted best-effort hints are re-derived by it; no new replay machinery.
- Tests: model commits then hangs → deadline publishes nothing (no `:succeeded` certificate); commit + clean exit (both `:done` and `:continue` shapes) → publishes exactly once; commit + `:error` exit → no publish; cancel immediately before commit / after commit but before the result message / during post-commit work → reconciliation resolves each; certificate read failing with a DB error → `publish_outcome_unknown`, no republish.

### Deadline budgets

- **Whole-run budget `max_run_ms` default 660_000** — matches today's facade default (600s runner + up to 60s bootstrap, consolidator.ex:131); not a reduction. Deadline minted at `await_and_start` from **monotonic time**, stored on RunServer.
- **Caller-visible cleanup cushion**: watchdog work (certificate reconciliation retries, graceful teardown) BEGINS at the deadline, so the facade and stream awaits are derived as `await_timeout = max_run_ms + reconciliation_allowance + teardown_reply_cushion` (`:consolidator_reconciliation_allowance_ms` default 10_000; cushion 5_000) — the default caller can no longer time out before RunServer replies. An exhausted-allowance `publish_outcome_unknown` maps to the EXISTING kind `stalled_wall_clock` with explicit details (`%{publish_outcome: :unknown}`) — the 22-kind enum does not grow silently.
- **Blocking phases (gate/load/publish) run in monitored tasks** so RunServer stays responsive and the watchdog can act during them. Watchdog at deadline: close the active attempt, stop the harness session, reconcile the publish certificate, release lock/endpoint/home. **A custom `await_ms` is a caller WAIT timeout only — never cancellation**; cancellation authority is the deadline watchdog alone (documented at the facade).
- Per-turn timeout = `min(per_turn_default, remaining)`; the loop stops when remaining < floor. Runner-level: `run_iteration` computes its own attempt deadline from `timeout_ms`; the runner never retries, so the harness single-inner-timeout + 5s cushion (harness.ex:55) holds.
- Deadline exhaustion classifies `stalled_wall_clock`; iteration-bound exhaustion classifies `iteration_limit`.

### Recovery codecs — two authorities, no cross-shape newest-wins

Metadata and checkpoint carry **differently scoped copies**; one global revision across shapes is unsafe (a newer partial marker must not replace full state):
- **Metadata codec** (`metadata["resume"]["state"]` + `metadata["resume"]["guidance"]`): the complete **sanitized anchor state** (all ResumeState fields EXCEPT guidance text) + **guidance STATUS only** (`{status, guidance_rev}`).
- **Checkpoint codec** (`runner_state_snapshot`): complete state + **encrypted guidance** (envelope below).
- **Selection**: anchor state = newest `{epoch, revision}` among the complete anchor copies (both stores qualify — both carry full anchor state); guidance TEXT only ever from the checkpoint; guidance STATUS = highest `guidance_rev` **within the selected epoch**, merged onto the full state. Tests: metadata newer than checkpoint for `pending`, `inflight`, and `consumed` — each resolves without fabricating or losing state.

### apply_input — checked guidance lifecycle (infrastructure-only for vendor runners)

Guidance is a sum `pending | inflight | consumed`, size-bounded (16KB, reject-over), **encrypted at rest**: a versioned Base64 wire envelope (`{"v": 1, "alg": "vault", "data": "<b64>"}`) inside the JSON-backed checkpoint `:map` (Cloak/Vault emits raw binary — hence the envelope; exact Vault API verified at build time). **Corrupt ciphertext / decryption failure ⇒ loud re-park (needs_input again + signal), never resend, never silent loss.** Metadata carries only `{status, guidance_rev}` — never text.
- `apply_input` (armed): CHECKED canonical checkpoint write of `pending` (a checked save variant beside best-effort `save_checkpoint/4`; `Harness.persist/1`-swallowing is not used here); ack `:ok` only on write success, else `{:error, :not_persisted}`.
- **`pending → inflight` is a CHECKED canonical transition that must succeed BEFORE the CLI spawns; failure ⇒ no spawn** (a best-effort inflight would let a crash resend the same answer). `consumed` stays conservative/best-effort — accepted tradeoff, documented: a crash after completion but before the consumed mark re-parks an already-answered question (an unnecessary re-prompt, never a double-send).
- Recovery from `inflight` is ambiguous ⇒ **never auto-resend**: discard, loud event, re-park `needs_input`.
- **Scope honesty**: neither vendor parser produces `Runner.needs_input/2` today (claude_code.ex:211, codex.ex:237) — for vendor runners this lifecycle is **infrastructure-only** in this build (live producers: workflow/static_fake runners; operator surfaces arrive with Wave C #9 / PR-4). Stated in docs + reconciliation.

### Arming, argv, and runner changes

**Arming**: `runner_config[:resume] :: :off | :armed`, read at `init/2`, default `:off`. Consolidator arms (`base_runner_config/2`); run_loop/recovery/apply_input inherit the session's config; **executor never arms** (fresh session_id + forge_home per step — PR-3 pin structural; dispatch untouched). Mode per turn: no anchor / `:provisional` / `:poisoned` / cwd-gate fail → `:fresh_armed`; `:anchored` + cwd match → `:continuation`. **`pwd` workdir capture happens ONLY when armed** (default-off init stays byte-identical; one programmable `Sandbox.exec(client, "pwd", [])`).

| mode | claude argv (build sites claude_code.ex:121-133) |
|---|---|
| default-off | today's argv exactly — no session flags (PR-3 pin) |
| fresh-armed | + `--session-id <minted-uuid>` (`Ecto.UUID.generate/0`); FULL prompt; anchor persisted pre-spawn on claimed sessions |
| continuation | + `--resume <anchor-id>`; GUIDANCE-ONLY prompt; no `--session-id`; **never `--continue`** |

| mode | codex argv (build sites codex.ex:131-153) — **exec-level opts BEFORE the `resume` subcommand** (verified: codex 0.144.1 rejects `-C`/`-s` after `resume`) |
|---|---|
| default-off | `codex exec <mcp_override> -m M <access> --json --ephemeral --skip-git-repo-check --ignore-rules -C cwd <FULL>` |
| fresh-armed | same minus `--ephemeral` (session must persist); capture `thread.started` (currently dropped, codex.ex:279-280); anchor `:provisional` until a clean `:done` exit promotes it (CH2-6 backend-trust rule) |
| continuation | `codex exec <mcp_override> -m M <access> --json --skip-git-repo-check --ignore-rules -C cwd resume <anchor-id> <GUIDANCE>` — never `--ephemeral`/`--last`; verify-live how a `-`-leading guidance positional parses post-`resume` (`--` or a non-dash prefix fallback) |

Runner flow both vendors: `resolve_mode` → eager anchor persist (claude fresh-armed, via the injected writer seam `Application.get_env(:jido_claw, :forge_resume_writer, …)`; skip cleanly when `forge_session_id` absent) → `build_args` → dispatch → parse/verify (claude extracts `session_id` from the `"system"` init event, claude_code.ex:221-223, verifying minted/requested id; codex captures `thread.started`) → classify failures (`RunFailure`), poison on `resume_unsafe?`, tag `{:fallback_marker, output}` for ≤320-char marker shapes, set `resume_rejected: true` for the invalid-anchor class, emit the loud signal — **runners never auto-retry**. Terminal errors carry `RunFailure.error_details(kind, …)` in result metadata. **Every state-changing path returns `metadata.state`** — including error/timeout terminals (a pre-spawn claude mint must reach harness state; harness merges only via metadata, harness.ex:692-700). CM2-3 sanitizer invariants pinned as contract tests: continuation argv never contains the original task; permission/trust flags derive ONLY from `state.access`, never anchor state; `--continue`/`--last` never appear; `--session-id` only fresh-armed claude; resume selectors only continuations, never combined; model/mcp/effort rebuilt fresh each turn. `serialize_state/1` = `%{iteration, resume: ResumeState.encode(rs)}`; `restore_state/2` overlays onto fresh init.

### Harness changes

1. `run_iteration` opts gain `forge_session_id`, the ephemeral `incarnation_token`, and the attempt-scoped execution config (tokenized MCP URL / per-attempt config path) — none of it persisted.
2. `iteration_complete`: state-merge (:692-700), then best-effort **fenced** mirror `Persistence.anchor_session/…` (stale ⇒ logged error, dropped).
3. Recovery: the CAS mint happens at RECOVERY-CLAIM time — restore/select the old snapshot, mint with its pair as `expected`, checkpoint the transplant — all BEFORE the `:resuming` phase begins its provision → bootstrap → runner-recovery sequence (harness.ex:388); `recover_runner/2` then runs under the already-minted incarnation: versioned config codec (refuse-on-missing) → decode state per the recovery codecs → cwd-gate (recovered sandbox = new workdir ⇒ drop anchor, source `:new`; poisoned never re-arms). Fresh starts (including terminal-row reuse) mint the same way right after `claim_session`, before `:provisioning`.
4. Initial CHECKED checkpoint before `:ready` broadcast (or `recovery_degraded`, self-healing on the next successful checkpoint).
5. apply_input per the guidance lifecycle.
6. Host-tier terminate: ONE detached sequenced task — `ChildTracker.graceful_teardown(incarnation_key)` (the tagged key) THEN `Sandbox.destroy` (two independent tasks could delete the workdir under a live CLI).

### Session actions + writers

- `update :anchor_resume` — named **`atomic/3` change** (mirror `SetMetadataKey`, conversations/resources/session.ex:393): jsonb_set of **`metadata["resume"]["state"]` only** (never the recovery-pointer or guidance paths), filter-guarded by the token/revision fence; sibling keys and sibling paths preserved by construction; **`define(:anchor_resume, args: [:resume, :incarnation_token])`** (token argument `sensitive?: true`) and call the generated interface directly.
- `Persistence.mint_resume_epoch/3` (locked select+mint: CAS + transplant install + pointer clear, as specified), **`Persistence.anchor_session/3`** (`session_id, resume, incarnation_token` — validate id; best-effort log+nil; fenced), the CHECKED checkpoint-save (creates the row + sets `current_checkpoint_id` + clears `recovery_degraded` in one transaction, token-authorized).

### ChildTracker + graceful teardown

`JidoClaw.Forge.ChildTracker` (GenServer + ETS): keys are **tagged incarnations** — `{session_id, {:durable, epoch}} | {session_id, {:local, uuid}}` — so no-DB incarnations never collide on a shared epoch 0 (a reused persistence-disabled session id with a surviving old task cannot have the old teardown kill the new process); `register` (immediate kill if the incarnation — or the whole session — is closing/closed; iteration Tasks run under the GLOBAL Task.Supervisor, harness.ex:474, and can outlive their Harness), `unregister`, `graceful_teardown/1` (one incarnation: mark closing → preserved-set kill; idempotent, synchronous — callers get sweep-complete as the return), **`graceful_teardown_session/1`** (the session-wide barrier: session-closing tombstone + **sweep every incarnation CONCURRENTLY** — wall time bounded by the max grace window, not the sum, so N epochs can't outgrow the reply cushion — and join in-flight sweeps, returning when all complete; the session tombstone remains until all registered owner tasks are down, with the derived-TTL bounded fallback), `terminate/2` VM-shutdown sweep; supervised at the front of core children (terminates last). **Tombstone lifecycle**: a closed epoch's tombstone is retained **until its owning iteration task is DOWN** (the tracker monitors the task pid supplied at registration — the true bound, since `timeout_ms` is configurable and a fixed TTL cannot dominate it), with a **derived TTL as the final leak backstop** (`2 × (attempt timeout_ms + grace_ms)` computed at registration). **PID-reuse guard**: birth identities (`ps -o lstart= -p PID`) are captured for **every discovered descendant at snapshot time**, not only the registered root; kills require a matching identity. `lstart`'s one-second resolution and any unavailable-field case are documented accepted residuals (low-probability reuse inside one grace window). `OsCmd.terminate_tree(os_pid, grace_ms)`: capture the full descendant set pre-TERM (fixpoint walk) → SIGTERM all → bounded window with continued re-discovery unioning new descendants of still-alive members → final SIGSTOP-fixpoint + SIGKILL over every captured survivor. **Documented residual**: a child forked after a snapshot and orphaned before the next rediscovery pass can still escape a PID-tree walk — accepted (process-group/cgroup boundary rejected at os_cmd.ex:14-17 for macOS portability); the VM-shutdown sweep and boot reaper bound the damage. Knob `:forge_runner_teardown_grace_ms` default 2_000. CLI-runner path passes `teardown: :graceful`; generic exec stays hard; docker tiers keep teardown-by-destruction.

### Env denylist + deadlock posture

`security/redaction/env.ex`: `@scrub_denylist_exact ~w(CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SSE_PORT)` + `CLAUDECODE_` prefix; public `denylisted?/1`; FIRST clause in `inheritable?/4` (operator `extra_allowed_env_vars`/`_prefixes` can never re-open) + reject from override_map in `scrubbed_cmd_env/1` (overrides bypass the allowlist, env.ex:172-175 — the load-bearing case); `scrubbed_port_env/1` + MCP stdio patch inherit automatically; docker `inject_env/2` rejects denylisted keys before `.forge_env` render. Deliberately NOT the whole `CLAUDE_CODE_*` namespace. **Deadlock discipline**: satisfied by construction (prompt rides argv; stdin `</dev/null` at host_shell.ex:212 + docker :506; stderr merged via `:stderr_to_stdout`, os_cmd.ex:103, so error output already carries the tail) — documented; the redirect gets a pin test; no code.

### Loud resume-failure + transcript markers

`JidoClaw.Forge.ResumeSignal.emit_failed/2`: **`JidoClaw.SignalBus.emit/2`** signal `jido_claw.forge.resume.failed` + Phoenix PubSub `{:resume_failed, details}` + `Logger.warning`; reason **bounded (`RunFailure.format_reason`) and redaction-passed** before either bus; emitted BEFORE any driver retry decision executes — never a silent fallback.

Markers: the **Forge event log is the live surface** — `iteration.completed` event data gains `source: :live | :replay` (`:replay` = a driver-authorized fresh re-send: the effect-free retry or the crash replay). `SubagentTranscript.do_append/6` (subagent_transcript.ex:119-152) additionally stamps turn metadata `source:`, **whitelist-decoded to `:live | :replay` only** (arbitrary `tool_context[:source]` values coerce to `:live`), default `:live` — the field EM3-3's gap statement names, with its `:replay` producer honestly documented as pending an agent-layer replay path. Interpretation recorded in the EM3-3 reconciliation.

### Consolidator loop (assembling the pieces)

`drive_harness/4`: turn 1 full prompt → loop on `:continue` within `max_iterations` (default 8) + the run deadline; continuation turns send `Prompt.continuation/1` guidance only (SY3-3 — never restate the task). Per attempt: mint attempt token + materialize the per-attempt endpoint capability (immutable claude config file / codex `-c`) → run → **close token → evaluate ledger** → at most one authorized fresh retry per the effect-ledger rules. Harness crash → the crash-replay policy table. Terminal: publish per the certificate gate; bound → `iteration_limit`, deadline → `stalled_wall_clock`, both publish nothing. Final result aggregates turns/usage; the reply handler stays byte-compatible for the existing single-`:done` fake. `run_loop` (forge.ex:153-172): continuation swaps in a guidance prompt; `:max_iterations_reached` carries `iteration_limit`; no auto-retry (no ledger); still caller-less (Wave F substrate).

### PR-3 pins + test plan

Pin tests (claude_code_test.exs:139-152, codex_test.exs:255-267) become the **default-off** case verbatim; armed cases added. StubSandbox gains `program_run_sequence/2` (response queue) + `run_args_history/1` (all argvs); the Fake runner gains `fake_iteration_statuses` threading `metadata.state`.

Coverage (beyond #1's): runner fresh-armed/continuation/cwd-gate argv tables; codex exec-opts-before-`resume` ordering; sanitizer invariants; claude id-verify mismatch → anchor cleared + loud signal (SignalBus + PubSub + telemetry asserted) with **no runner retry**; poison lifecycle (poisoned id never reused; later clean anchor allowed); codex clean-vs-dirty-exit trust; materialized-config round-trip per runner (**consolidator claude keeps `:full` + its MCP tools after recovery** — the regression case); refuse-recovery on missing `access`; checked initial checkpoint before `:ready` + `recovery_degraded` set/self-heal (transient failure); CAS mint (stale-cannot-mint; recovery transplant sequence; **metadata-older-than-checkpoint then crash immediately after mint — post-mint metadata carries the transplanted state**); **recovery-checkpoint failure with an old checkpoint present — the old epoch is never recovered (pointer rule)**; **multiple checked guidance checkpoints within one iteration — pointer selection stays correct**; fence errors (`:stale_resume_write` surfaced; sibling keys concurrent-safe); **metadata-path isolation** (checkpoint-then-anchor, anchor-then-checkpoint, simultaneous sibling-path updates — the pointer survives all three; a stale incarnation's failed checkpoint cannot mark the newer one degraded); **lifecycle matrix** (resume-off shell runner recovers via pointer+ownership; persistence-disabled Harness gets the local-token posture; armed terminal-session reuse CAS's to a blank transplant — the old anchor never carried; pointed checkpoint rejected when `checkpoint.session_id ≠ session.id`); attempt-token races through the **real loopback HTTP route** (late mutation after close rejected; a closed-token READ rejected centrally; crash-after-mutation → no retry; zero-effect crash → exactly one latched replay); publish certificate (commit-then-hang → nothing published; commit + clean exit — `:done` AND `:continue` shapes — publishes exactly once; commit + `:error` exit → no publish; cancel before commit / after commit before result / during post-commit — reconciliation resolves each; **certificate read DB-error → `publish_outcome_unknown`, never republished**); watchdog fires during a blocked publish phase (monitored-task split); custom `await_ms` waits without cancelling; guidance lifecycle (checked pending; checked inflight-before-spawn — write failure ⇒ no spawn; inflight-crash → no resend + re-park + loud event; consumed-conservative re-prompt; 16KB bound; corrupt-ciphertext re-park; raw text absent from metadata and plaintext snapshot); recovery-codec selection (metadata newer than checkpoint for pending/inflight/consumed); docker-armed: in-run continuation works, post-crash fresh via cwd-gate with Trace; env denylist truth table + override-drop + operator-reopen-blocked + `.forge_env` filter; `terminate_tree` preserved-set (root exits during window — reparented child still killed); ChildTracker (late register against closing epoch killed; stale teardown inert on the new epoch; tombstone TTL sweep; birth-identity mismatch not killed; VM-shutdown sweep; per-test DynamicSupervisor children under `Sandbox.allow`); harness single-sequenced-teardown; **cross-owner ordering: a delayed CLI writing through its grace window — `run_forge_home` survives until the sweep completes**; **multi-epoch barrier: epoch 1 crashes with a delayed CLI, epoch 2 completes — final teardown waits for BOTH before deleting the home**; **pointed-checkpoint authority on both wake paths: direct wake AND Manager-driven wake with a newer unpointed checkpoint restore the pointed one**; **`context_for_resume/1` selects the pointed checkpoint — and the events since it — when a newer unpointed row exists**; **token rotation: an iteration captures T1, recovery rotates to T2, the delayed T1 runner write is rejected (`:stale_resume_write`)**; **local-incarnation isolation: a persistence-disabled session id is reused while its old task survives — the new local incarnation is NOT killed**; **serialized reserve-then-execute: a mutation accepted-but-in-flight at close time is still counted**; **no-temp-leak across multiple continuation attempts** (every per-attempt config file cleaned by its epoch teardown or the final backstop); SubagentTranscript whitelist stamp. **Verify-live at build time**: claude system-event id key; codex `thread.started` id key (update the codex_test.exs:313 fixture to carry an id); codex post-`resume` positional parsing; Vault encrypt API + envelope. Async postures of touched files preserved (runner/consolidator/harness suites stay `async: false`).

### Docs + reconciliation

New page `docs/system/forge-session-resume.md` (spine: fencing epoch/token CAS; recovery owner + crash-replay table; effect ledger + attempt capabilities; publish certificate; recovery codecs; guidance lifecycle incl. consumed-conservative tradeoff + envelope; deadline budgets + watchdog semantics; `:local`-only crash-resume scope with the docker mount design as named trigger; arming/argv tables; poison lifecycle; env denylist; ChildTracker/teardown + preserved-set residual; markers; infrastructure-only apply_input note; verify-live residuals) + index row + AGENTS.md Key Patterns bullet — atomic. `executor-seam.md:258-260` surgical edit (resume machinery exists, `:off` by default, executor never arms — fresh-per-review-round holds structurally) + `verified:` bump. Reconciliation (dated Status lines): pre-argus README rows #2/#3; MC-FIRST-WAVE item 2 (correct the falsified consolidator-multi-iteration premise; record the driver-side-retry and `:local`-scope divergences); multica FWB MC1-1; chorus CH-FIRST-WAVE item 3 + FWB CH2-6/CH3-2; symphony FWB SY3-3; bosun FWB BO2-3 (poisoned-list half); herdr FWB HD2-2 (vocab; fork/compact documented-unused); cmux FWB CM2-3 (invariants as contract tests); myrlin FWB (`--continue` rejected; probe-from-disk rejected — Session row); emdash FWB EM3-3 (marker + loud event; interpretation note).

---

## Item #4 — exit-code tiering for `mix jidoclaw run` (MC3-4, adapted) — ✅ DONE 2026-07-11

*(Shipped as specified, plus one logged deviation — the injected-DB-failure
rows pinned at the `AshErrors.not_found?/1` seam instead of CLI-level; see
the plan home doc's Deviations.)*

Table: 0 success (`done_with_findings` stays 0, marked) · 1 generic error/failed/timeout · 2 usage+validation+config (unchanged — **foreign-workspace stays here**: found-but-invalid-for-the-requested-dir) · 3 human-input (gate|clarify, unchanged) · **4 not-found** · **5 provider-unreachable** · **6 provider-auth**.

`cli/run_command.ex`: widen both `@type`s (:68, :104); moduledoc table (:6-20). **Exit 4 discriminates Ash leaves on BOTH resolver branches**: in `resolve_session`, validate UUID syntax FIRST (malformed → `{:usage,…}` → 2); on `Session.by_id` error inspect the leaf — `Ash.Error.Query.NotFound`-class → `{:not_found, msg}` → 4, DB/framework shapes → `{:error, reason}` → 1; **the `--continue` branch (`most_recent_for_workspace`, :298-306) gets the same split** — nil/NotFound → 4, infrastructure failure → 1. New `dispatch/1` clause → `not_found_result/1` (exit 4, outcome `:not_found`). Provider tiers at the generic `{:error, reason}` arm only (:424-426) via `RunFailure.classify/1` (auth → 6 `:provider_auth`, network → 5 `:provider_unreachable`, else 1); `await_outcome` `{:done, :failed, run}` stays 1 (deliberate non-goal — launched-run provenance lives in run telemetry). JSON envelope is generic (`"ok" => exit_code == 0` holds); verify `run_line/1` fallthrough. No `--help` flag exists — the moduledocs ARE the help: update `lib/mix/tasks/jidoclaw.ex:13-16`, `cli/main.ex:14-17`, and the test moduledoc.

Tests (run_command_test.exs pattern: `RunCommand.main(argv, boot: fn -> :ok end)` + `Application.put_env` seam stubs, TenantCase async: false): unknown-valid-uuid → 4 (flips :142-146); no-continue → 4 (flips :148-151); **malformed uuid → 2**; **injected read failure (by_id) → 1**; **injected read failure (`--continue`) → 1**; foreign-workspace stays 2 (:161-178 unchanged); tier 5/6 via provider-shaped `dispatch_capture_response` errors (auth struct → 6, network → 5, `{:error, :boom}` → 1); config-boot stays 2; JSON envelope rows for 4/5/6. The #1 integration rows (Normalize-then-classify) guard the 5/6 path end-to-end.

Docs: ambiguity-clarify.md claims stay true → `verified:` bump only. Reconciliation: MC-FIRST-WAVE item 3 (Status + correct the stale "exits 0/1 only" claim + restore the missing `## 3.` header); multica FWB MC3-4 (Status + strike the stale claim); pre-argus README row #4/§4 (correct its "e.g. 4 not-found / 5 validation" sketch to the decided table; the #16 registry cross-ref stays pending — this build consumed RunFailure instead); unadopted-next-ten README:106 gets an "extended 0–6 by Wave A" note.

---

## Implementation order

0. ✅ Plan home doc (`docs/plans/pre-argus-wave-a/README.md` + Deviations).
1. ✅ **#1**: run_failure.ex (incl. unwrapping + precedence rank + total wrapper) → tests (incl. integration rows) → telemetry → harness consumer → composer consumer → docs (page + index + AGENTS.md + TRUST-BOUNDARIES + verdict cross-link) → reconciliation. Verify: `mise exec -- mix compile --warnings-as-errors`, targeted tests, `mix jidoclaw.system_docs.check`, targeted credo/dialyzer.
2. ✅ **PORT-MC1-1.md → sign-off** (#4 ran while waiting).
3. 🔶 **#2+#3** — steps 1–7 done (env denylist → ResumeState → fence → config codec + pointer loader → claude armed → codex armed → ResumeSignal/poison/fallback); **← RESUME at the harness step** (opts incl. `incarnation_token`+`incarnation_epoch` / fenced mirror / claim-time mint / guidance lifecycle; teardown resequencing recommended to ride slice 10 with ChildTracker) → RunServer (attempt-token endpoint + Plug context + serialized ledger + close-then-evaluate + crash-replay policy + publish certificate + watchdog with monitored tasks + recovery-await + loop) → ChildTracker + terminate_tree → markers → docs → reconciliation. Targeted tests per slice.
4. ✅ **#4**: run_command changes → tests → moduledocs → reconciliation.
5. ⬜ **Final**: `mise exec -- mix precommit` bare in background, read the output tail; suspected flakes verified in ISOLATION before blaming changes; iterate to green.

## Risks

Verify-live set: claude system-event id key; codex `thread.started` key + post-`resume` positionals; in-VM CLI versions for docker plans; Vault encrypt API + envelope; ReqLLM/Jido.AI struct fields. Deepest new mechanics — attempt-token endpoint plumbing and RunServer recovery-await — build test-first against the :fake harness. Precommit traps: credo Specs/AliasUsage/ImplTrue; ExSlop (never start a comment line with the word "step"); reach fixed_shape_map (pragma precedent exists); dialyzer union totality; system_docs atomicity (page + index + AGENTS.md same change); broadcast subset-match (forge_live). The partitioned suite is the long pole — targeted runs during development.

## Files touched

New: `lib/jido_claw/orchestration/run_failure.ex`, `lib/jido_claw/forge/resume_state.ex`, `lib/jido_claw/forge/resume_signal.ex`, `lib/jido_claw/forge/child_tracker.ex`, `docs/system/run-failure.md`, `docs/system/forge-session-resume.md`, `docs/exploration/pms/multica/PORT-MC1-1.md`, `docs/plans/pre-argus-wave-a/README.md`, tests (run_failure, resume_state, child_tracker).
Modified: forge/runners/{claude_code,codex}.ex (+ `materialize_config/1` on both; optional callback added to forge/runner.ex), forge/harness.ex, forge/persistence.ex (locked select+mint, checked checkpoint-save setting the pointer, `current_checkpoint/1`, `context_for_resume/1` re-pointed, anchor writer), forge/resources/session.ex (`:anchor_resume` + mint actions, `sensitive?: true` token args), forge/resources/checkpoint.ex (pointer-selection read), forge/manager.ex (`recoverable?/1` lifecycle matrix), forge/recovered_spec.ex (+ pinned-test update), lib/jido_claw/forge.ex (`wake/2` via `current_checkpoint/1`; run_loop), lib/jido_claw/application.ex (ChildTracker supervision), memory/resources/consolidation_run.ex (`record_run` gains the `:run_id` argument setting the pk), memory/consolidator/{run_server.ex (attempt tokens, ledger, publish certificate + three-outcome reconciliation, watchdog, recovery-await, loop, final-teardown handshake), plug.ex (attempt_token context), tools/helpers.ex (centralized token enforcement), consolidator.ex (derived facade await), prompt module}, mcp/scoped_endpoint.ex (per-attempt immutable 0600 config files; 0700 home), core/os_cmd.ex (terminate_tree), core/telemetry.ex, security/redaction/env.ex, forge/sandbox/docker.ex (.forge_env filter), route_composer/route_composer.ex, cli/run_command.ex, lib/mix/tasks/jidoclaw.ex + cli/main.ex (moduledocs), conversations/subagent_transcript.ex, test/support/{stub_sandbox.ex, fake runner}, ~15 test files, AGENTS.md, docs/system/{README, verdict-normalizer, executor-seam, ambiguity-clarify}.md, docs/TRUST-BOUNDARIES.md, 10 exploration/plan docs (reconciliation).

## Suggested commit slicing (user commits; nothing staged by me)

1. `feat: run-failure taxonomy (MC1-4 + OR3-2/BO2-3 riders)` — #1.
2. `docs: PORT-MC1-1 semantics map` (signed off).
3. `feat: native CLI session resume for Forge runners (MC1-1 + riders, EM3-3)` — #2+#3.
4. `feat: exit-code tiers 4-6 for mix jidoclaw run (MC3-4)` — #4.
