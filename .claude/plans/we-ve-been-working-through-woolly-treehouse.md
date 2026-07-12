# Plan: resolve the 8 session-resume code-review findings

> Rev 4. Round-3 corrections: the persisted `repark_reason` is now AUTHORITATIVE across
> repeated recoveries (a consumed-graft copy carrying a reason re-parks again instead of
> recovering `:ready`; the field threads both guidance codecs + `merge_guidance/3`; a
> repark → crash → recover-again e2e pins it), and the `Forge.run_loop` edit is corrected
> to match the real code (`continuation_opts/1` deletes — never forwards — the prompt;
> it now also deletes `:guidance`, plus a pin test).
>
> Rev 3. Two structural corrections from plan review round 2:
> **F2** — detection-then-repair was still post-hoc (a task-free fresh turn could publish,
> terminalize, or stage mutations before any repair ran — the continuation nudge literally
> instructs "call commit_proposals"). Replaced with pre-dispatch prevention: continuation
> guidance now rides a semantically-tagged `:guidance` opt that fresh-armed turns
> structurally ignore in favor of `state.prompt`. The whole repair-turn machinery
> (budget.full_prompt, act_on_directive/7, full_prompt_resend_needed?) is gone; detection
> survives only as a loud log. **F6** — the re-park prompt was broadcast-only; it now
> persists as a fenced `repark_reason` on the guidance marker (riding the already-planned
> initial checkpoint, zero new writers) and projects through `ForgeView` so an operator
> arriving after the broadcast sees actionable instructions.
> (Rev 2 corrections retained: owner-sweep bounds + tracked late kills + covering call
> timeout; harness registration reads `iteration_opts`; mint-time corrupt-guidance graft.)

## Context

The pre-argus Wave A build (`.claude/plans/please-review-docs-plans-pre-argus-do-no-rosy-hellman.md` — native CLI session resume, items #2+#3, all 13 slices shipped, uncommitted) got a code review that surfaced 8 findings (4×P1, 4×P2). **All 8 validated as real** against the working tree — several worse than reported:

- **F1** consolidator omits `resume: :armed` in both vendor configs (the docs page even claims it arms — `docs/system/forge-session-resume.md:259-260`); with `:off`, every turn ≥ 2 is a fresh conversation whose entire prompt is the task-free `Prompt.continuation/1` nudge.
- **F2** crash replay preserves the iteration number → guidance-only prompt; claude recovery ALWAYS lands fresh-armed (new HostShell temp dir trips the cwd gate), so the fresh conversation's whole prompt is "Continue the consolidation pass…" — which instructs a commit. Nothing prevents or detects the task-free turn. (Codex-docker self-heals via the `resume_rejected` → `:retry_fresh` lane; claude is silent on every recovery path.)
- **F3** `ChildTracker.spawn_kill/2` is liveness-only; the closing-registration refusal (`child_tracker.ex:150` — whose comment *claims* "identity-verified") and the TTL reap (`:465`) can kill a reused OS pid. `verified_kill/2` (`:355-364`) already encodes the correct predicate and both sites have the birth identity in scope.
- **F4** registration is single-phase (`register_spawn` needs an OS pid, which exists only after the CLI spawns — pre-spawn work includes a DB write); `graceful_teardown_session` replies immediately when no keys are registered, then RunServer deletes `run_forge_home` under the still-running task. **Worse**: the session tombstone is reaped at the first 5s tick when it has zero owners (`:469-471`), so even the late-kill protection lapses.
- **F5** both vendors build continuation prompts from `opts[:prompt] || "Continue."` — `rs.pending_guidance.text` is never read by anyone (the vendor `apply_input` impls write a `response.json` nothing reads); the harness then consumes the never-delivered answer.
- **F6** equal `guidance_rev` tie (the NORMAL checked-save state — one struct encodes both copies) resolves to the text-less metadata copy via first-maximal `Enum.max_by` (`resume_state.ex:493-505`). **Worse**: `ResumePolicy.restore_state/2` restores only `["resume"]["state"]` so recovered live state has NO guidance regardless, `transplant_snapshot` re-encoding a text-nil state drops the ciphertext permanently, and the promised re-park (pending-without-text, corrupt, inflight) is implemented nowhere.
- **F7** `kickoff_deferred/1` (`harness.ex:500-505`) broadcasts `:ready` with neither the checked initial checkpoint nor the degraded fallback that all three sibling ready-paths have (fresh eager `:989-1005`, recovery `:620-623`, lazy provision `:1707-1711`); the mint just cleared the pointer, so a crash leaves a claimed row that silently refuses recovery. (No production caller sets `deferred_provision` today — tests only — so this is an invariant/honesty fix.)
- **F8** codex's exit-0-no-terminal fallthrough produces `Runner.done` (`codex.ex:528-533`, deliberate + pinned) but `maybe_trust(rs, %{status: :done})` can't distinguish it from a real `turn.completed` → a truncated stream promotes a provisional anchor, violating CH2-6. The parser's `terminal` accumulator (`:489-510`) is the signal, currently discarded.

**Done-bar (user-set): `mise exec -- mix precommit` succeeds.** Note the full gate has NEVER run end-to-end on this working tree (per the Wave A handoff) — unrelated fallout is in scope to fix.

---

## Fixes

### F1 — arm the consolidator (`lib/jido_claw/memory/consolidator/run_server.ex`)

Add `resume: :armed` to both vendor maps in `base_runner_config/2` (`:771-790`). The `:fake` lane stays unarmed. Verified: nothing else needed — `materialize_config/1` persists the key (claude_code.ex:179, codex.ex:163), `RecoveredSpec` whitelists+decodes it (recovered_spec.ex:123, :138, :238), token-less runs skip fenced writes cleanly. Accepted side effects: armed claude adds one `pwd` exec at init; armed codex drops `--ephemeral` so session files persist under `CODEX_HOME` (= `run_forge_home`, cleaned at final teardown — anticipated by the comment at run_server.ex:517-519).

### F2 — semantically-tagged guidance: prevention before dispatch (`resume_policy.ex`, `run_server.ex`, `forge.ex`, `resume_state.ex`)

**Root design change (review round 2)**: the driver stops sending continuation guidance under `:prompt` — which fresh-armed turns treat as the ENTIRE prompt — and sends it under a new **`:guidance`** opt that only armed **continuation** turns read. The runner's resolved mode then structurally picks the safe source: `:continuation` → guidance text; `:fresh_armed` → `state.prompt` (the persisted full task, since `:guidance` is never consulted there and `:prompt` is absent). A task-free turn can no longer exist, so there is nothing to repair post-hoc — no bad publish, no bad terminal, no stale mutations.

New opts contract (documented in the docs page's runner-opts section):
- `:guidance` — continuation guidance; read ONLY by armed continuation turns (`take_continuation_guidance`, F5). Ignored everywhere else.
- `:prompt` — unchanged semantics where it already had them: default-off per-turn override (`Keyword.get(opts, :prompt, state.prompt)`) and fresh-armed override-else-`state.prompt`. Armed continuations now ignore `:prompt` entirely — a strengthening of CM2-3 (even a confused caller passing `prompt: task` to an anchored session cannot put the task on a continuation argv).

Edits:
- `ResumePolicy.take_continuation_guidance/2` (F5's shared helper) reads `ResumeState.inflight_text(rs) || Keyword.get(opts, :guidance) || @continuation_nudge` — never `opts[:prompt]`.
- `run_server.ex` `turn_prompt_opts/1` (`:712-713`) stays arity-1, emits the new key: `(1) → []`, `(n) → [guidance: Prompt.continuation(n)]`. Replay turns (`:await_recovery` at `:701`, `:retry_fresh` at `:680`) need NO special-casing — a live-anchor replay continues with meaningful guidance; a dropped-anchor replay resolves fresh and gets `state.prompt`. `source: :replay` stays for EM3-3 event marking only. Update the `:708-711` comment.
- `Forge.run_loop` — **no key swap** (review correction: `continuation_opts/1` at forge.ex:199 never forwarded a prompt; it DELETES the caller's `:prompt`, which is already mode-safe — armed continuation → nudge, fresh restart → `state.prompt`). The one real edit: `continuation_opts/1` deletes **both** `:prompt` and `:guidance`, so a caller-supplied `guidance:` on the initial call can never ride every continuation indefinitely (run_loop invents no guidance of its own — its `:guidance` lifecycle is "never forwarded across iterations"). Extend the `:195-198` comment.
- **Observability (detection survives as a log only)**: new `ResumeState.fresh_start?/1` (`session_start_source :resume` → false, else true). In `harness_loop` after `run_one_attempt`, when the result's `metadata.state.resume` reports a fresh start on an iteration > 1 turn, `Logger.warning` that mid-run context was lost and the turn redid the task fresh (safe now — that turn received the full prompt). No directive change, no extra turn. Falls through silently when `metadata.state` is absent (resume `:off`, fake/scripted runners).

### F3 — identity-verified late/TTL kills (`lib/jido_claw/forge/child_tracker.ex`)

Replace `spawn_kill/2` (`:366-373`) with an async wrapper over the existing predicate:
```elixir
defp spawn_kill(entry, grace) do
  Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> verified_kill(entry, grace) end)
end
```
Call sites: `:150` → `spawn_kill(%{os_pid: os_pid, birth_id: birth}, 0)` (`birth` is in scope from the register message); `:465` → `spawn_kill(entry, 0)`. Nil/mismatched birth → refuse (unverifiable). No other callers exist. (F4 additionally makes refusal kills *tracked* when a sweep/barrier is in flight — see below.)

### F4 — two-phase registration, bounded owner sweep, durable tombstones (`child_tracker.ex`, `lib/jido_claw/forge/harness.ex`)

The biggest edit. Verified enabler: `OsCmd.run`'s `:on_os_pid` runs synchronously **in the calling process** (os_cmd.ex:84-88, :124) — the iteration task itself — so attach is owner-keyed trivially.

In `child_tracker.ex`:
- **`register_owner/2`** (new public, `@spec`): `{:ok, ref} | {:error, :closing} | nil`; nil key → nil; `catch :exit → nil` (tracker unavailable never blocks work). Server side: closing → `{:error, :closing}` (no kill — nothing exists); else create an **owner-only entry** (`os_pid: nil, birth_id: nil`) joining `by_key` + owner monitor (extract shared entry-creation into a helper).
- **Attach in `handle_call({:register, ...})`** (`:146-175`): three-way — closing → refusal + F3's verified kill (**tracked** when a sweep for the key or a session wait is in flight, below); an owner-only entry under `key` with `owner == caller` → attach (set `os_pid`/`birth_id`, refresh `ttl`, reply the SAME ref so HostShell's later `unregister(ref)` drops the whole entry); else create standalone as today. During a sweep the key is tombstoned, so an attach can never land on a sweeping entry — it is refused (owner-only entries stay owner-only for the sweep's whole life).
- **Sweeps await owners, bounded**: sweep record becomes `%{task_pid, froms, kills_done :: boolean, pending_owners :: MapSet.t(ref), pending_kills :: MapSet.t(monitor_ref)}`. `start_sweep` partitions by `os_pid` nil-ness — spawned entries go to the kill task as today (none → `task_pid: nil, kills_done: true`); owner-only refs become `pending_owners`, and each schedules a **bounded owner-stop**: `Process.send_after(self(), {:owner_stop, key, ref}, grace)` — on firing, if the entry still exists and is still owner-only, `Process.exit(entry.owner, :kill)` (its DOWN clears the pending ref). New `maybe_complete_sweep/2` completes (existing reply/drop/settle body) only when `kills_done and pending_owners == ∅ and pending_kills == ∅`. Clearing events, all routed through one `clear_pending_owner/2`: owner DOWN, TTL reap, unregister.
- **Tracked late kills**: a refusal kill for a key with an in-flight sweep is monitored and its monitor ref joins that sweep's `pending_kills` (cleared by kill-task DOWN — fires on crash too); a refusal kill for a session with an in-flight `session_wait` but no sweeping key joins a session-scoped `late_kills :: %{monitor_ref => session_id}`, and session-wait settlement requires the session's late-kill set empty. This closes both review holes: the sweep can no longer complete while a just-refused CLI's terminate_tree is still running, and an owner exiting early no longer lets the barrier pass a live descendant sweep.
- **Covering call timeout**: both client calls (`:93-98`, `:107-112`) change to `2 * grace + @call_slack_ms` (kill phase ≤ grace + owner-stop ≤ grace + slack dominates the ps/exec overhead). Keep `catch :exit → :ok` as the last-resort never-block degradation, now with a `Logger.warning` so a truncated barrier is at least loud.
- **Owner DOWN** (`:243-249`): owner-only entry → drop it (no future attach possible — attach comes from the owner itself); then `clear_pending_owner`. Spawned entries keep today's semantics (CLI outlives task). Delete `release_owner/2` (tombstone `owners` goes away, below).
- **Tombstones TTL-only** (`:291-326`, `:469-471`): drop the `owners` field; reap predicate becomes TTL-only; fallback TTL changes from `2 × grace` to `@default_timeout_ms` (300s). Safe: `graceful_teardown_session`'s only production caller is RunServer FINAL cleanup, session ids are per-run UUIDs, recovered incarnations mint new epochs.
- Reap: owner-only expired entries drop with no kill (+ `clear_pending_owner`); dead sweep-task DOWN (`:251-255`) sets `kills_done` + `maybe_complete_sweep`. VM-shutdown sweep needs no change (`verified_kill` refuses nil birth). Update moduledoc laws.

In `harness.ex` — `start_iteration_task/4`: the task body registers before dispatch **using the enriched opts** (`iteration_opts = enrich_iteration_opts(opts, new_state)` at `:1026` is what carries `:incarnation_key` — the raw `opts` would make registration a permanent no-op):
```elixir
# inside the Task.Supervisor.start_child fn, replacing the direct run_iteration call
result = run_tracked_iteration(runner, client, runner_state, iteration_opts)

defp run_tracked_iteration(runner, client, runner_state, iteration_opts) do
  case ChildTracker.register_owner(Keyword.get(iteration_opts, :incarnation_key),
         timeout_ms: Keyword.get(iteration_opts, :timeout, 300_000)) do
    {:error, :closing} -> {:error, :session_closing}
    _registered_or_unavailable -> runner.run_iteration(client, runner_state, iteration_opts)
  end
end
```
`{:error, :session_closing}` flows through the existing `{:iteration_complete, _, {:error, reason}, ...}` arm — no new result shape. No explicit owner unregister (owner DOWN covers task exit). Harness `terminate/2`'s detached `graceful_teardown(incarnation_key)` composes for free (same sweep machinery).

### F5 — deliver parked guidance, vendor-owned disposition (`resume_state.ex`, `resume_policy.ex`, `claude_code.ex`, `codex.ex`)

**Design correction (round 1)**: gating the harness's `consume_inflight_guidance` on "runner returned metadata.state" would break the pinned test at `harness_resume_test.exs:552-572` (its fake runner DOES attach state carrying inflight). Corrected: **harness fallback stays byte-identical** (already a no-op when merged state has no `:inflight`); the **vendors own their guidance disposition explicitly**.

- `ResumeState.inflight_text/1` (new accessor): text only for `%{status: :inflight, text: binary}`.
- `ResumeState.guidance_undelivered/1` (new total transition): inflight → pending, keeps text, bumps `guidance_rev`; no-op otherwise. Constraint comment: only a runner that provably never placed the text on an argv may revert.
- `ResumePolicy.take_continuation_guidance/2` (shared — single owner of the `"Continue."` nudge, preempts ExDNA twins; reads `:guidance` per F2):
```elixir
@spec take_continuation_guidance(ResumeState.t(), keyword()) :: {String.t(), ResumeState.t()}
def take_continuation_guidance(rs, opts) do
  case ResumeState.inflight_text(rs) do
    nil -> {Keyword.get(opts, :guidance) || @continuation_nudge, rs}
    text -> {text, ResumeState.guidance_consumed(rs)}
  end
end
```
Consume-at-take: the text rides exactly one argv, never resent — even if the turn then errors/times out (`stalled_wall_clock` is NOT resume-unsafe, the anchor survives; consuming prevents a double-send).
- Both vendors' `run_continuation` (claude_code.ex:284-286, codex.ex:268-270): one-line swap to the shared helper; delete each module's `@continuation_nudge`. Both vendors' `run_fresh_armed` (claude `:240`, codex `:243`): first line `rs = ResumeState.guidance_undelivered(rs)` — an inflight answer survives an undelivering fresh-armed turn as `:pending` (redelivered next continuation; the pending status also makes the harness fallback a no-op).
- Harness: `consume_inflight_guidance` code unchanged; refresh its comment (+ the stale `:1124-1130` lifecycle comment) — consumption is vendor-owned on delivery; harness is the fallback for runners making no disposition.

Documented residual: a continuation that never spawned (exit 127) consumes an undelivered answer — accepted (a missing CLI kills the whole run; the alternative reintroduces double-send on timed-out delivered turns).

### F6 — tie-break, corrupt-evidence preservation, durable re-park (`resume_state.ex`, `harness.ex`, `resume_signal.ex`, `forge_view.ex`)

- **(i) Tie-break**: in `merge_guidance` (`resume_state.ex:493-496`) reorder candidates to `[{:checkpoint, cp_guidance}, {:metadata, md_guidance}]` — first-maximal `Enum.max_by` then gives the text-carrying checkpoint copy equal-rev wins; a strictly-newer metadata marker (e.g. best-effort consumed) still wins. Update the `select/4` docstring.
- **(ii) Transplant integrity + corrupt-evidence graft**: with (i), the merged rs carries text and `encode_guidance` already emits the ciphertext envelope for ANY text-carrying status (`:375-385`); `transplant_snapshot` re-encodes it. **The corrupt lane was unreachable**: `decode_guidance_copy` (`harness.ex:379-393`) collapses `{:error, :corrupt_guidance}` to nil BEFORE `select/4`, so when the metadata marker is also malformed/absent the evidence is erased entirely. Fix in `transplant_selector` (`:354-370`): track whether either guidance copy decoded corrupt; when corruption was seen AND the merged selection carries no live guidance, graft a conservative re-parkable marker via new `ResumeState.mark_guidance_lost/1` (sets `pending_guidance: %{status: :pending, text: nil}`, bumps `guidance_rev`) before stashing/returning. Downstream is then deterministic: transplant encodes marker-only pending → recovery disposition re-parks as `:guidance_text_missing`. Graft only when the selection is an rs; a nil selection (no armed state copies at all) has nothing to park on — log loud, documented residual.
- **(iii) Recovery disposition + durable re-park**: new `ResumeState.adopt_recovered_guidance/2` returning `{:none | :restored | :kept | {:repark, reason}, t()}` — dispositions, in order: **a copy carrying `repark_reason` (any status — practically the consumed-graft) → `{:repark, reason}` with the copy restored verbatim (no re-bump)** — the persisted reason is AUTHORITATIVE until an answer clears it, so a repark session that crashes again re-parks again instead of recovering `:ready` and silently dropping the operator request; then `pending`+text → graft (restore status/text/**rev** — a rev-less graft would let the transplant's marker out-rev a future re-park's fresh answer at a second recovery); `pending` no-text → graft marker then `guidance_consumed` (rev+1) + set `repark_reason` + `{:repark, :guidance_text_missing}`; `inflight` → same consume-graft + reason + `{:repark, :inflight_delivery_ambiguous}` (never resend); `consumed` (no reason) → keep marker; `{:error, :corrupt_guidance}` → no graft + `{:repark, :corrupt_guidance}` (kept as defense-in-depth: decryption can still fail AT RECOVERY TIME — vault key unavailable — even though the mint-time collapse now grafts).
  **Durable marker (review round 2 — the broadcast alone left a late-arriving operator with a blocked session and no instructions)**: ResumeState gains field **`repark_reason :: atom() | nil`** (default nil) + a static `@repark_prompt "Your previous answer could not be delivered safely; please enter it again."` with public `repark_prompt/0`. **`repark_reason` threads the FULL codec path so it survives arbitrarily many recoveries**: the `guidance_copy()` type gains the field; `encode_guidance_marker/1` AND the checkpoint `encode_guidance/1` envelope include `"repark_reason"` when set; both decode sides whitelist the three known reason strings (never `String.to_atom`); `merge_guidance/3` carries the winner copy's reason; `mark_guidance_lost/1` and `transplant_snapshot` re-encoding preserve it. `put_guidance/2` (a new operator answer) is the ONLY clearer, so the post-answer checked save self-clears the marker. Because the disposition runs BEFORE `ensure_initial_checkpoint`, the marker persists **fenced** into `metadata["resume"]["guidance"]` via the initial checkpoint's existing marker mirror — zero new writers or transactions.
  In `handle_info({:recover, checkpoint_id}, state)` (harness.ex:608-624), after `stamp_runner_resume` and **before** `ensure_initial_checkpoint`: decode `get_in(checkpoint.runner_state_snapshot, ["resume", "guidance"])` via `ResumeState.decode_guidance`, dispatch the transition, `put_runner_resume`. Then `finish_recovery(state, repark_reason)`: nil → today's ready tail; reason → `log_event("guidance.reparked")` + new `ResumeSignal.emit_guidance_reparked/1` (mirror `emit_recovery_degraded/1`; signal `jido_claw.forge.resume.guidance_reparked`, PubSub `{:resume_guidance_reparked, payload}`) + `update_phase(:needs_input)` + `PubSub.broadcast(sid, {:needs_input, %{prompt: ResumeState.repark_prompt(), reason: reason}})` + `%{state | state: :needs_input, input_sandbox: nil}`. Verified safe: `:needs_input` is in Manager's recoverable phase set (manager.ex:271) and in ForgeView's `@active_phases` (forge_view.ex:20); `apply_input` tolerates nil `input_sandbox`.
  **ForgeView projection (`lib/jido_claw/forge_view.ex`)**: `session_to_map/2` (`:119-133`) gains `needs_input:` — nil unless `session.phase == :needs_input`; when set, read `session.metadata["resume"]["guidance"]["repark_reason"]` (whitelist-decoded) → `%{reason: reason_or_nil, prompt: ResumeState.repark_prompt()}` (a runner-question `:needs_input` with no repark marker projects `nil` — its question travels via the executor AgentCase path, out of scope). Flows to the MCP `forge_status` tool, `runtime_overview`, and `forge_live` for free via `ForgeView.list/1`/`to_mcp_map/1`.

### F7 — deferred kickoff checkpoints before `:ready` (`harness.ex`)

`kickoff_deferred/1` (`:500-505`): insert `ensure_initial_checkpoint(state)` before `update_phase(:ready)`/broadcast (token-less sessions already no-op via the `:1243` clause). In `build_resume_snapshot/1` (`:1270-1271`), coalesce: `serialize_runner_state(...) || %{}` (deferred sessions have `runner: nil` → serialize returns nil; `Checkpoint.runner_state_snapshot` is `allow_nil?` but an explicit `%{}` keeps `resume_epochs_match?` semantics clean and restore tolerates it — `restore_state` falls back field-by-field on missing keys).

### F8 — codex promotes only on a real terminal (`codex.ex`)

`do_parse_output/1` (`:486-537`) returns `{result, thread_id, terminal}` (accumulator already in scope; the `nil ->` fallthrough KEEPS producing `Runner.done` — result posture is deliberate and pinned). Update destructuring at `parse_output/1` (`:476-479`, ignore terminal), `run_fresh_armed` (`:247-250` → pass `terminal` to `capture_anchor`), `run_continuation` (`:273-276`, ignore terminal — `verify_continuation_thread` performs no promotion). `capture_anchor/4` stays /4 — its `result` param (consumed only by `maybe_trust`) becomes `terminal`, in both the poisoned-rearm branch (`:294-299`) and plain capture (`:301-308`). `maybe_trust/2`:
```elixir
defp maybe_trust(rs, {:done, _usage}), do: ResumeState.trust(rs)
defp maybe_trust(rs, _no_clean_terminal), do: rs
```

---

## Tests

- **`test/jido_claw/forge/resume_state_test.exs`** (async: true): equal-rev tie → checkpoint text wins; metadata-strictly-newer consumed still wins; `inflight_text/1`, `guidance_undelivered/1`, `fresh_start?/1`, `mark_guidance_lost/1` rows; `adopt_recovered_guidance/2` seven-row disposition table (rev grafting; rev bump + `repark_reason` set on re-park lanes; **a copy already carrying `repark_reason` re-parks with the same reason, restored verbatim — the second-recovery authority row**); `repark_reason` round-trips through BOTH codecs (marker + checkpoint envelope; whitelist decode, unknown string → nil) and survives `merge_guidance` winner selection; `put_guidance/2` clears `repark_reason`.
- **`test/jido_claw/forge/runners/claude_code_test.exs` + `codex_test.exs`** — the F2/F5 mode-resolution pins (the structural prevention lives HERE, not in scripted-driver tests):
  - continuation uses `opts[:guidance]` (existing `:prompt`-based pins at claude `:528`/codex `:662`,`:706` update to the new key);
  - **continuation given BOTH `prompt:` and `guidance:` uses the guidance and the task never rides the argv** (CM2-3 strengthening);
  - **fresh-armed given `guidance:` ignores it and sends `state.prompt`** — THE prevention pin, both vendors;
  - continuation delivers parked inflight text (claude argv `["-p", "the parked answer"]`; codex tail `["resume", tid, "--", "the parked answer"]`) beating `guidance:`, returned state consumed; fresh-armed reverts inflight → pending and sends the full task;
  - codex F8: armed + `thread.started` + exit-0 + **no terminal** → anchor stays `:provisional` + next turn fresh-armed (uses the currently-dead `:none` branch of `thread_started_jsonl/2` at `:571-578`); existing `:616`/`:629`/`:652` stay green.
- **`test/jido_claw/forge/child_tracker_test.exs`** (async: false): barrier blocks on a pre-spawn owner, completes on owner DOWN (owner must be a separate process, not the barrier caller); **owner-stop bound: a wedged pre-spawn owner is force-stopped ~grace and the barrier still completes**; `register_owner` against a tombstoned session → `{:error, :closing}`; **zero-owner session tombstone survives a reap tick and still refuses `register_spawn`** (THE F4(iv) regression pin — send `:reap` + `:sys.get_state` to synchronize; assert refusal + verified kill of the live straggler); **a refusal kill during an in-flight barrier extends it** (barrier returns only after the kill task completes — observe via a slow-dying `spawn_tree` process); attach flow (register_owner → register_spawn same key/owner → same ref, one entry, swept verified); TTL reap kills a live leaked spawned entry (`timeout_ms: 1`) and refuses/no-crashes the dead-birth twin (F3 reap-path exercise). Existing `:125`/`:134`/`:175`/`:186`/`:204` verified green against the rework.
- **`test/jido_claw/forge/harness_resume_test.exs`** (async: false, TenantCase): F6 e2e — park answer → crash-simulate (the `:373-378` seam) → recover → fake runner sees `%{status: :inflight, text: …}` at spawn AND the transplant checkpoint retains decodable ciphertext; F6 re-park e2e — durable inflight (an `:error` turn attaching state) → recover → `assert_receive {:needs_input, %{prompt: prompt, reason: :inflight_delivery_ambiguous}}` with the static prompt, phase `:needs_input`, **durable marker: `metadata["resume"]["guidance"]["repark_reason"] == "inflight_delivery_ambiguous"`**, **a FRESH `ForgeView.list(scope)` (post-broadcast) returns the session with `needs_input: %{reason: :inflight_delivery_ambiguous, prompt: <static>}`** — proving a late-arriving operator sees actionable instructions — then `apply_input(sid, "again") == :ok` re-parks pending at a higher rev AND clears the marker (next ForgeView projects no repark); **F6 second-recovery authority e2e** — after the re-park lands (session `:needs_input`, marker carrying `repark_reason`), crash-simulate AGAIN and recover: the session lands back in `:needs_input` with the same durable reason and ForgeView projection (never `:ready` — the operator request survives repeated crashes until answered); **F6 tampered-checkpoint e2e** — park answer, crash-simulate, corrupt the pointed checkpoint's guidance envelope AND blank the metadata marker via direct row updates, recover → re-park fires as `:guidance_text_missing` (pins the mint-time graft; evidence never silently erased); F7 — deferred+claimed → pointer set + `runner_state_snapshot == %{}` before `{:ready}`, plus the degraded twin via the existing fail-first-save stub (mirror `:246`); F4 — tombstoned session → `Forge.run_iteration` returns `{:error, :session_closing}` and the injected iteration fun never ran. Pinned `:552-572` stays untouched-green (harness fallback consumes for the substrate runner).
- **`Forge.run_loop` pin** (new test beside the existing Forge facade tests in `test/jido_claw/forge/`, fake-runner opts capture): a loop entered with BOTH `prompt:` and `guidance:` set — iteration ≥ 2 opts contain NEITHER key (the caller's task is never resent, caller guidance never rides indefinitely; armed continuation falls to the nudge, a fresh restart to `state.prompt`).
- **`test/jido_claw/memory/consolidator/run_server_test.exs`** (async: false): F1 — extend `test/support/jido_claw/prompt_capture.ex` with `last_config/0` (keep `last_prompt/0` delegating); assert `resume == :armed` + prompt non-empty for both `harness: :claude_code` and `:codex`; F2 — `turn_prompt_opts/1` unit rows (`(1) == []`, `(3) == [guidance: …"turn 3"…]`); **driver-side prevention pin**: the scripted-journal multi-turn test (the `:678-745` pattern) asserts every turn ≥ 2 passes `opts[:guidance]` and `opts[:prompt] == nil` — including a journal where turn 2 reports a fresh `:startup` state, then commits and returns `:done` on a later turn → the run still publishes exactly once (the reviewer's terminal/commit regression case: with prevention, a fresh turn received the full task, so its commit is legitimate); the fresh-start `Logger.warning` fires (capture_log). (A real Manager-recovery `:await_recovery` e2e stays a deliberate cut — replay turns now share the exact same opts-building path as live turns.)

## Docs + reconciliation (same change — `system_docs.check` enforces)

- **`docs/system/forge-session-resume.md`**: the runner-opts contract (`:guidance` read only by armed continuations; `:prompt` retains default-off/fresh-armed override semantics; continuation ignores `:prompt` — CM2-3 strengthened; mode resolution is the structural guard that a fresh turn always carries the task); codex promotion = "a real `turn.completed` terminal in the same attempt — a terminal-less exit-0 stream stays provisional"; guidance delivery vendor-owned (`take_continuation_guidance`, fresh-armed revert, harness fallback scope) + the 127-consumption residual; checkpoint-wins-equal-rev tie-break + the mint-time corrupt-graft + the recovery disposition table + the durable `repark_reason` marker (+ self-clearing rule) + the `guidance_reparked` signal + the ForgeView `needs_input` projection; two-phase registration / barrier-awaits-pre-spawn-owners (bounded owner-stop at grace; tracked late kills; covering call timeout `2×grace + slack`) / TTL-retained tombstones; the fresh-start loud log; deferred kickoff now checkpoints (the "before every `:ready`" enumeration gains it); `verified:` bump to 2026-07-11. The `:259-260` consolidator-arms claim becomes TRUE rather than edited.
- **AGENTS.md**: verified — the forge-session-resume bullet stays accurate ("continuations send … a GUIDANCE-ONLY prompt (never the task twice)" remains true and becomes structural; promotion rule stricter; teardown claims strengthened). No edit expected; adjust minimally if any sentence reads false after the fixes.
- **`docs/plans/pre-argus-wave-a/README.md`** `## Deviations`: one dated entry (2026-07-11) summarizing the 8 post-review fixes; mark F5's harness-gate → vendor-owned-disposition, F4's TTL-only-reap, F2's `:prompt` → `:guidance` semantic split, and F6's mint-time graft + durable repark marker as corrections forced by the code/plan reviews.

## Implementation order (compiles at every step)

1. `resume_state.ex` (F6-i tie-break; `inflight_text/1`, `fresh_start?/1`, `guidance_undelivered/1`, `mark_guidance_lost/1`, `adopt_recovered_guidance/2`; `repark_reason` field + marker codec + `put_guidance` clearing + `repark_prompt/0`) → `resume_state_test.exs`.
2. `resume_policy.ex` (`take_continuation_guidance/2` reading `:guidance`).
3. `claude_code.ex` + `codex.ex` (F5 wiring; F2 mode pins; F8 3-tuple + terminal-gated trust — update ALL `do_parse_output` call sites in the same edit or the tree breaks) → vendor tests.
4. `resume_signal.ex` (`emit_guidance_reparked/1`).
5. `harness.ex` F6+F7 (selector corrupt-graft; recovery disposition + `finish_recovery`; deferred checkpoint; snapshot coalesce; comment refreshes) + `forge_view.ex` `needs_input` projection + `forge.ex` `continuation_opts/1` also deleting `:guidance` (+ its pin test).
6. `child_tracker.ex` F3+F4 (verified `spawn_kill`; two-phase + attach; bounded pending-owner sweeps via `maybe_complete_sweep`/`clear_pending_owner`/`{:owner_stop, …}`; tracked late kills; TTL-only tombstones; covering call timeouts) → then `harness.ex` `run_tracked_iteration` (reads `iteration_opts`, depends on the new API).
7. `child_tracker_test.exs` + `harness_resume_test.exs` additions.
8. `run_server.ex` F1+F2 (`resume: :armed`; `turn_prompt_opts/1` → `:guidance` key; fresh-start warning) → `prompt_capture.ex` + `run_server_test.exs`.
9. Docs + Deviations entry.
10. Final gate.

## Verification

- Per step: `mise exec -- mix compile --warnings-as-errors` + the step's test files + per-file credo. Targeted sweeps: `mise exec -- mix test test/jido_claw/forge/` and `test/jido_claw/memory/consolidator/`.
- Final: `mise exec -- mix precommit` **bare, in background** (never piped — tail masks the exit code), read the output tail, iterate to green. Known traps: dialyzer union totality (the new tagged-tuple returns), ExSlop (no comment line starting with "step"), credo strict Specs on new publics, reach fixed-shape, `jido_md`/`system_prompt`/`system_docs` checks, and the flaky async:false singletons (MCPServer/Prompt/PipelineStore/MultiSandbox) — verify any failure in ISOLATION before attributing it. The gate has never run on this tree: unrelated fallout is in scope; fix it, logging anything surprising in the Deviations entry.
- Finish with files-to-stage + suggested commit message(s) (operator commits; no git mutations).

## Accepted residuals (documented in the docs page)

- Exit-127 continuation consumes an undelivered answer (missing CLI kills the run anyway; the alternative double-sends on timed-out delivered turns).
- A brutal owner-stop landing in the microsecond window between `Port.open` and the attach call can orphan a CLI (same class as the existing fork-after-snapshot residual; bounded by the identity-verified refusal + VM-shutdown sweep).
- Corrupt guidance with NO armed state copies at all (nil selection) has nothing to park on — loud log, evidence lost (armed sessions always carry state copies in practice).
- PID-reuse refusal kill not e2e-testable (needs OS pid reuse); dead-birth refusal is the proxy pin.
- Tombstones now retained ~300s (per-run-unique session ids; recovered incarnations mint new epochs — cannot block legitimate work).
- A mid-run fresh restart redoes the task from scratch in a new conversation (prior in-conversation context is unrecoverable by definition) — now guaranteed to carry the full task and logged loudly; runner-question `:needs_input` sessions (non-repark) still project no question text through ForgeView (their question travels via the executor AgentCase path).
