# Plan: resolve the 2 post-implementation review findings (F9, F10)

## Context

The 8-finding session-resume fix plan (`.claude/plans/we-ve-been-working-through-woolly-treehouse.md`, F1–F8) is implemented on this working tree, uncommitted. A follow-up code review surfaced 2 new P2 findings in that new code. **Both validated as real:**

- **F9 (P2) — recovery-time corruption re-parks without a durable marker.** `adopt_recovered_guidance/2`'s corrupt lane (`lib/jido_claw/forge/resume_state.ex:430-432`) returns `{{:repark, :corrupt_guidance}, rs}` with `rs` untouched — the ONE disposition lane that installs no durable marker (the `:guidance_text_missing` / `:inflight_delivery_ambiguous` lanes both `consume_graft` a consumed marker + reason). The recovered `rs` carries no guidance at all (the runner's `restore_state` restores only `["resume"]["state"]`), so the initial checkpoint that follows (`harness.ex:660-664`: `readopt_guidance` → `ensure_initial_checkpoint` → `finish_recovery`) persists a nil guidance object and a nil marker mirror. Consequences, both confirmed: (a) `ForgeView.needs_input_projection/1` (`forge_view.ex:143-156`) returns nil without a metadata `repark_reason` — a late-arriving operator sees a `:needs_input` session with no prompt or reason; (b) a second crash recovers from the new (guidance-less) checkpoint → `decode_guidance(nil)` → `{:ok, nil}` → `:none` → `finish_recovery(state, nil)` → `:ready` — the operator request silently evaporates, violating the "persisted reason is AUTHORITATIVE across recoveries" design the other lanes uphold. The lane is defense-in-depth (Vault key unavailable at recovery / post-transplant row tampering — the mint-time transplant collapse normally grafts first), which is why P2 not P1.

- **F10 (P2) — the TTL reap lapses barrier accounting four ways.** The reviewer's core finding plus three adjacent holes confirmed in the same machinery (`lib/jido_claw/forge/child_tracker.ex`):
  1. **Live pre-spawn owner dropped** (`reap_entry/3` owner-only clause, `:712-718`): an expired owner-only registration is `drop_entry`'d without stopping its owner, and `reap/1` additionally `clear_pending_owner`s it. A wedged owner past its TTL (2 × (timeout + grace)) is silently removed; a subsequent `graceful_teardown_session` finds no refs (`start_sweep` → `{:empty, _}`) and returns immediately; RunServer removes `run_forge_home` while the still-live owner continues pre-spawn writes under the deleted home — the exact race the F4 two-phase barrier exists to prevent. A reap tick DURING an in-flight sweep likewise completes the barrier while the owner lives. The moduledoc even names "TTL reap" as a valid owner resolution (`:31-32`) — a design slip, not just an implementation slip.
  2. **Spawned reap kills untracked** (`reap_entry/3` spawned clause, `:720-727`): the reap starts a fire-and-forget `spawn_kill/2` and drops the entry immediately — a barrier processed next sees neither the entry nor a tracked kill and can return while `terminate_tree` is still running (the same class F4's `refuse_kill` → `track_late_kill` closed for refusals, left open on the reap path). The unregister path compounds it: a reaped root's death makes the command return, so HostShell `unregister/1`s (`host_shell.ex:205`) and the unconditional cast handler (`:286-288`) drops the entry while the kill task is still sweeping descendants.
  3. **Tombstones inherit expired TTLs** (`tombstone_key/2` `:411-414`, `tombstone_session/2` `:416-425`, `tombstone_ttl/2` `:427-432`): tombstone TTLs are `Enum.max` over entry TTLs — the fresh-window fallback only fires when NO entries exist, so an already-expired entry's TTL propagates into the tombstone, which the very next reap tick removes (even mid-sweep, before the owner's DOWN), letting a queued late registration through `closing?`. `Map.put_new/3` additionally never refreshes an existing near-expired tombstone.
  4. **Queued attach can revive a reaped owner**: a `register_spawn` call queued before the reap's `:kill` lands is processed after it (its DOWN always trails the already-queued call) — a plain attach would set `os_pid`, refresh the TTL, and `owner_down/2` then KEEPS the spawned entry: an orphaned live CLI, permanently reap-exempt once a `reaping` flag exists.

Both fixes are small and follow existing in-repo patterns (`consume_graft` symmetry; the tracked-late-kill / bounded-owner-stop posture). Greenfield: no wire/data compat concerns.

**Done-bar (user-set): `mise exec -- mix precommit` passes. No commits — finish with files-to-stage + suggested commit message.**

## Fixes

### F9 — corrupt lane grafts the durable consumed marker (`lib/jido_claw/forge/resume_state.ex`)

Replace the corrupt lane's body to reuse `consume_graft/3` with a synthetic copy at the state's own rev (no decodable copy exists — that's what corrupt means):

```elixir
def adopt_recovered_guidance(%__MODULE__{} = rs, {:error, :corrupt_guidance}) do
  {{:repark, :corrupt_guidance},
   consume_graft(rs, %{status: :consumed, guidance_rev: rs.guidance_rev}, :corrupt_guidance)}
end
```

Effect: `pending_guidance: %{status: :consumed, text: nil}`, `guidance_rev: rs.guidance_rev + 1` (rev 1 in practice — the restored rs carries rev 0; epoch isolation makes cross-epoch rev comparison moot), `repark_reason: :corrupt_guidance`. Update the `@doc` disposition list (the `{:error, :corrupt_guidance}` bullet: no longer "state untouched" — grafts the consumed marker so the re-park is durable and authoritative like every other lane).

**Zero downstream changes** — verified end-to-end: `encode_guidance/1` on a text-nil marker emits the marker object (with `repark_reason`) into the checkpoint's `["resume"]["guidance"]`; `encode_guidance_marker/1` mirrors it into metadata via `save_recovery_checkpoint/6`'s pointer write; ForgeView's projection and the next recovery's reason-carrying-copy disposition (`adopt_recovered_guidance` clause 2 → `{:repark, reason}` verbatim) already handle it; `put_guidance/2` remains the only clearer; `:corrupt_guidance` is already in the `@repark_reasons` decode whitelist and the `repark_reason()` type.

### F10 — the reap never drops live bookkeeping; tombstones never inherit expired TTLs (`lib/jido_claw/forge/child_tracker.ex`)

One uniform law replaces the reap's drop-eagerly behavior: **a reaping entry is removed only by its DOWN** — owner DOWN for owner-only entries, the monitored reap-kill task's DOWN for spawned ones; `unregister/1` and attach defer to it, and **sweeps ADOPT a pending reap-kill** (below) so `complete_sweep/3` can never drop a reaping entry either — by the time a sweep completes, the reap-kill DOWN has already resolved it. This holds even in the sweep-task crash lane (`sweep_task_down/2` `:611-622` marks the kill phase done best-effort when the task dies unreported — without adoption, a mid-reap barrier whose own kill task crashed would drop the entry and return while the original reap-kill is still terminating descendants). Any barrier arriving mid-reap therefore sees either the entry (and outwaits its kill) or nothing left alive.

Entry maps gain `reaping: false` and `reap_kill_mon: nil` (in `create_entry/6`); the expired filter becomes `entry.ttl < now and not entry.reaping`; `reap/1` stops wrapping `clear_pending_owner` around `reap_entry` — each clause owns its resolution.

**(i) Owner-only clause** — force-stop the owner, mark reaping, retain; the existing `owner_down/2` (owner-only → `drop_entry` + `clear_pending_owner`) is the single resolution point:

```elixir
defp reap_entry(state, ref, %{os_pid: nil} = entry) do
  Logger.warning(
    "[Forge.ChildTracker] force-stopping TTL-expired pre-spawn owner for #{inspect(entry.key)}"
  )

  Process.exit(entry.owner, :kill)
  mark_reaping(state, ref)
end
```

Why force-stop rather than retain-until-teardown (the reviewer offered both): retention would leave a wedged live process holding pre-spawn write capability for arbitrarily long; force-stop matches the sweep's existing 2s bounded owner-stop and the spawned clause's kill-at-TTL posture. An owner-only entry alive at TTL = 2 × (iteration timeout + grace) (~10min via `run_tracked_iteration`) has spent double its iteration budget without spawning a CLI — genuinely wedged. The harness's monitored iteration task dying `:killed` flows through the existing non-normal DOWN arm (iteration failed, phase `:ready`) — the honest outcome.

**(ii) Spawned clause** — monitored kill task, entry retained until the kill's DOWN; on task-start failure RETAIN un-marked (never drop-before-death — the next 5s tick retries and any intervening barrier still sees the entry):

```elixir
defp reap_entry(state, ref, entry) do
  Logger.warning(...)  # existing message
  start_reap_kill(state, ref, entry)
end

defp start_reap_kill(state, ref, entry) do
  case spawn_kill(entry, 0) do
    {:ok, task_pid} ->
      mon = Process.monitor(task_pid)
      entry = %{entry | reaping: true, reap_kill_mon: mon}

      %{
        state
        | monitors: Map.put(state.monitors, mon, {:reap_kill, ref}),
          entries: Map.put(state.entries, ref, entry)
      }

    _not_started ->
      state
  end
end
```

Entries gain a second bookkeeping field, `reap_kill_mon: nil`, so the kill is discoverable by sweeps, and `start_reap_kill/3` ends with `adopt_into_sweep(state, entry.key, mon)` — a no-op without an in-flight sweep, otherwise `MapSet.put` into that sweep's `pending_kills`.

**Sweep adoption covers BOTH orderings**: reap→sweep — `start_sweep/4` seeds the new sweep's `pending_kills` with the `reap_kill_mon` of every spawned entry that carries one (the entries still ALSO go to the sweep's own kill task — idempotent, identity-verified, and robust if the reap-kill task crashed without killing); sweep→reap — a `:reap` firing while a sweep is already in flight inserts its fresh monitor via `adopt_into_sweep`. A sweep therefore cannot complete — even when its own kill task dies unreported and `sweep_task_down/2` marks `kills_done` best-effort — until every adopted reap-kill has resolved, which is also what already dropped the reaping entry before `complete_sweep/3` runs.

**The `{:reap_kill, ref}` DOWN arm dispatches on the exit reason** — a dead kill task is only proof of a finished kill when it exited `:normal`:
- `:normal` → success: `drop_entry` + the defensive `clear_pending_owner` + a new `clear_pending_kill(state, mon)` (the `clear_pending_owner` mirror over every sweep's `pending_kills` + `maybe_complete_sweep`).
- any other reason → the kill did NOT complete (task crash, or the TaskSupervisor — which starts AFTER ChildTracker at `application.ex:219` vs `:206` and so terminates FIRST at shutdown — killing in-flight tasks). **Order matters: replace first, clear second.** `clear_pending_kill` runs `maybe_complete_sweep`, so removing the dead monitor while it is the sweep's LAST dependency would synchronously reply to the barrier and `complete_sweep`-drop the entry before any replacement exists. The handler therefore: logs a warning; resets the entry (`reaping: false, reap_kill_mon: nil`); re-runs `start_reap_kill/3` (replacement task + fresh monitor, `adopt_into_sweep`ed) — and only THEN `clear_pending_kill(old_mon)`, whose completion check now sees the replacement pending. All within one `handle_info` — no window. If the restart fails (`{:error, :unavailable}` — supervisor gone, i.e. VM shutdown): fall back to a SYNCHRONOUS in-server `verified_kill(entry, 0)` (bounded — grace 0, two ps execs; the pathological lane can afford it), then drop the entry and clear the old monitor — the sweep may then complete legitimately, everything verified dead. A raise inside that fallback is rescued: keep the entry, clear the old monitor, log loud — the truly-pathological residual (supervisor down AND the kill raising), same accepted class as the existing dead-sweep-task lane.

**`spawn_kill/2` becomes TOTAL** — today `Task.Supervisor.start_child/2` against a missing named supervisor EXITS `:noproc` (it never returns an error), so every "task didn't start" branch — including the shutdown fallback above and the pre-existing `refuse_kill` one at `:505-510` — is unreachable exactly when needed, crashing the tracker instead. Wrap the start in `catch :exit, _ -> {:error, :unavailable}`, and thread the supervisor from state (`state.task_supervisor`, new init opt below) rather than the hardcoded name. `start_kill_task/4` (sweep kills) gets the same exit-safety: a start refusal yields `{nil, state}` → `kills_done: true` immediately — the existing best-effort shutdown posture, unchanged in spirit but no longer a crash.

**(iii) `unregister/1` preserves reaping entries.** A reaped root's death makes the command return → HostShell unregisters while the reap-kill task is still sweeping descendants; the unconditional drop at `:286-288` would remove the entry from barrier accounting mid-kill. The cast handler gains a guard: `%{reaping: true}` → no-op (the reap-kill DOWN owns the drop); anything else → today's `clear_pending_owner(drop_entry(...))`.

**(iv) Attach to a reaping owner is CLOSING, never a revival.** In the register handler's attach branch, when `state.entries[ref].reaping` is true: adopt the identity only (set `os_pid`/`birth_id`; NO TTL refresh), run the same `start_reap_kill/3` (its DOWN drops the entry; on task-start failure clear `reaping` so the next tick retries via the spawned clause — the un-refreshed TTL is still expired), and reply `{:error, :closing}`. Without this, `owner_down/2` keeps the just-attached spawned entry and the `reaping` flag exempts it from every future reap — an orphaned live CLI leaks permanently. Normal attaches (`reaping: false`) are unchanged — `attach_spawn/5` needs no reaping logic at all.

**(v) Tombstone TTL clamp + refresh** — a tombstone always retains at least a fresh default window and re-tombstoning only extends:

```elixir
defp tombstone_key(state, key) do
  ttl = tombstone_ttl(state, key)
  %{state | tombstones: Map.update(state.tombstones, key, %{ttl: ttl}, &%{ttl: max(&1.ttl, ttl)})}
end
# tombstone_ttl/2 and tombstone_session/2: pipe the Enum.max through
# `max(_, System.monotonic_time(:millisecond) + @default_timeout_ms)` so an
# already-expired entry TTL can never produce a born-dead tombstone;
# tombstone_session/2 gets the same Map.update refresh.
```

Live long-TTL entries keep dominating (their max exceeds the floor); only expired/short ones get lifted.

**Three test-enabling affordances (same file, deliberately minimal):**
- `init/1` gains `task_supervisor:` (default `JidoClaw.TaskSupervisor`, stored on `State`; accepts a name or PID — `Task.Supervisor.start_child/2` takes either): production unchanged, and a test can hand a private supervisor it stops mid-choreography — the deterministic seam that makes `spawn_kill`'s `{:error, :unavailable}` lane and the synchronous fallback actually coverable.
- `start_link/1` gains an optional `:name` (default `__MODULE__`) and `schedule_reap: false` (default true — production unchanged), PERSISTED as an `auto_reap` field on `State`: `init/1` skips the initial timer when false and `handle_info(:reap, state)` reschedules only when `state.auto_reap` — so the option genuinely means tick-less, including after test-sent `:reap`s. The new concurrency tests drive PRIVATE, tick-less instances via direct `GenServer.call/cast` and send every `:reap` explicitly — no automatic tick can ever interleave mid-choreography (relying on "the test finishes inside 5s" would break under slow CI, and on the OLD code an early tick would drop the owner so the barrier mints a fresh fallback-floor tombstone, making the tombstone regressions false-pass), and the tests stop touching the global instance other suites depend on (the known flaky-singleton class).
- `spawn_kill/2`'s task body gains a kill gate: when app env `:forge_child_tracker_kill_gate` holds a pid, the task announces `{:kill_gate, ref, self()}` and blocks for `{:kill_gate_release, ref}` (bounded `after` fallback so a leaked gate can never wedge a real kill); unset — production — it is a zero-cost no-op. This is the fake↔live-style app-env arming seam (no test module named in lib) that lets tests hold a kill open and observe retention deterministically.

Update the moduledoc laws in the same edit: the sweep-completion law (kill phase done AND owners resolved AND tracked late kills AND adopted reap-kills finished); the reap law ("entries whose TTL passes are hard-reaped" → the reap force-stops and retains; a reaping entry is removed only by its DOWN — unregister defers, attach refuses as closing with identity adopted for the verified kill, sweeps adopt pending reap-kills in both orderings, and only a `:normal` kill-task exit resolves — an abnormal DOWN resets and retries so a crashed/shutdown-killed task never discards a live entry); the tombstone law (TTL at least a fresh default window at tombstone time, only ever extended); and the `clear_pending_owner/2` "owner DOWN, TTL reap, and unregister all route here" comment.

## Tests

- **`test/jido_claw/forge/resume_state_test.exs`** — re-pin the corrupt row (`:637` "corrupt guidance re-parks without touching the state" currently pins the bug): disposition `{:repark, :corrupt_guidance}`, `pending_guidance == %{status: :consumed, text: nil}`, `repark_reason == :corrupt_guidance`, `guidance_rev == rs.guidance_rev + 1`. Add the second-recovery authority round-trip: adopt-corrupt → `encode_guidance/1` → `decode_guidance/1` → adopt again on a fresh rs → `{:repark, :corrupt_guidance}` with the copy restored verbatim (proves the graft rides the codec and re-parks forever until answered). No harness e2e: the recovery-time corrupt lane has no deterministic seam (the transplant re-encrypts at claim, so pre-recover tampering is caught at mint — the existing tampered e2e — and post-transplant corruption needs interposing inside `Forge.start_session`); the durable-marker plumbing downstream of the disposition return is byte-shared with the `:inflight_delivery_ambiguous` lane, already e2e-pinned (durable marker, ForgeView projection, second-recovery authority, answer-clears at `harness_resume_test.exs:672-750`).
- **`test/jido_claw/forge/child_tracker_test.exs`** — nine new tests in a new describe. Shared setup helper: start a PRIVATE, TICK-LESS tracker (unnamed `start_link(schedule_reap: false, …)`, driven by direct `GenServer.call/cast` mirroring the thin client funs; every `:reap` is test-sent), `forge_runner_teardown_grace_ms: 10` env (on_exit restore), and `on_exit` cleanup that kills every spawned owner (`Process.exit(_, :kill)`), `OsCmd.terminate_tree/2`s every spawned OS tree, deletes the kill-gate env, and stops the private tracker. Determinism comes from three mechanisms, never sleeps-as-proof: tick-less private instances (no automatic `:reap` exists — every reap is explicit, so no tick can fire inside a test's window even on paused/slow CI), the kill gate (a held kill makes retention observable and DOWN timing test-controlled), and `Process.info(tracker, :messages)` mailbox inspection for queued-call handshakes.
  1. **Reap force-stops a live pre-spawn owner (the reviewer's repro):** sleeping owner registers `timeout_ms: 1`; monitor it; sleep past the TTL; send `:reap` → `assert_receive {:DOWN, _, _, owner, :killed}`; poll `by_key` empty (its DOWN, not the reap, dropped it); a session teardown then returns `:ok` with nothing live. Old code: the owner survives → the DOWN assert fails.
  2. **Key-only tombstone clamp (independent of session tombstones):** expired sleeping owner under `key`; `Task.async` a key-only `{:teardown, key, 2_000}` call (sweep pends on the owner); poll `:sys.get_state` until the sweep is registered; send `:reap`; then a same-key `{:register_owner, key, …}` must return `{:error, :closing}` — only `tombstones[key]` can refuse it (no session tombstone exists); `Task.await` → `:ok` and `refute Process.alive?(owner)`. Old code: the born-dead key tombstone is reaped in the same tick → the registration passes.
  3. **Session-barrier tombstone clamp + owner retention:** same shape via `{:teardown_session, sid, 2_000}`; post-`:reap`, a new-epoch `register_owner` AND a `register_spawn` straggler (fresh `spawn_tree("sleep 300")`) both `{:error, :closing}` + `assert_eventually_dead(straggler)` (session tombstone clamped; refusal kill tracked); `Task.await` → `:ok`, `refute Process.alive?(owner)`. Old code: the reap drops the owner + clears the pending ref → the barrier returns with the owner alive, and the reaped session tombstone admits the registrations.
  4. **Reap→sweep adoption (gated):** arm the kill gate; register a `spawn_tree("sleep 300")` entry `timeout_ms: 1`; expire; send `:reap` → `assert_receive {:kill_gate, gate_ref, _}` (the kill is held); `:sys.get_state` → the ref is STILL in `by_key`, `entries[ref].reaping == true` with `reap_kill_mon` set, a `{:reap_kill, _}` tag in `monitors` — retention asserted while the kill provably runs (old code: `by_key` already empty → fails here); `Task.async` a session teardown, then poll `:sys.get_state` until `sweeps[key].kills_done == true` (the sweep's OWN kill phase is explicitly finished — never inferred from elapsed time; on non-adopting code the sweep is GONE from `sweeps` at that point instead, having completed → fail) and assert `MapSet.member?(sweeps[key].pending_kills, entries[ref].reap_kill_mon)` + `Task.yield(barrier, 100) == nil` — with kills done and no owners, ONLY the adopted reap-kill is holding the barrier (also the structural cover for the sweep-task crash lane); release the gate → the reap task finishes, its `:normal` DOWN drops the entry + clears the adopted pending kill → `Task.await` → `:ok`, `refute alive?(os_pid)`, final `by_key` empty, no crash.
  5. **Sweep→reap adoption (gated):** register a TERM-trapping tree (`trap "" TERM; while true; do sleep 0.2; done`) `timeout_ms: 1`; expire; start the barrier FIRST with `grace_ms: 2_000` — the trap makes the sweep's own kill wait the FULL grace before its KILL, a deterministic LOWER bound keeping the sweep in flight while the test's next steps (ms-scale) run (slow CI only widens the window — the safe direction); poll `:sys.get_state` until the sweep is registered; arm the gate and send `:reap` → poll until `entries[ref].reap_kill_mon` is non-nil AND a member of `sweeps[key].pending_kills` — the direct adoption assert for the mid-sweep `start_reap_kill` (on adoption-at-start_sweep-only code membership never appears, and if the sweep instead completes and vanishes the poll helper fails loud on either shape); then poll `kills_done == true` and assert `Task.yield(barrier, 100) == nil` (the barrier waits on the ADOPTED kill alone); release the gate → `Task.await` → `:ok`, tree dead, `by_key` empty.
  6. **Abnormal reap-kill DOWN: replace-then-clear at the last-dependency boundary (gated):** setup as test 4 THROUGH the `kills_done == true` + membership poll — the held monitor is now provably the sweep's LAST dependency, so this exercises the exact completion race; `Process.exit(gated_task_pid, :kill)` (the pid rides the gate announce) → assert a SECOND `{:kill_gate, ref2, _}` arrives (the replacement task — the abnormal DOWN reset + re-ran `start_reap_kill` BEFORE clearing the dead monitor), the entry is still in `by_key`, the NEW `reap_kill_mon` is a member of `pending_kills`, and `Task.yield(barrier, 100) == nil` (the crashed kill resolved nothing); release `ref2` → barrier completes, tree dead, `by_key` empty. On drop-on-any-DOWN code the entry vanishes at the crash; on clear-before-replace code the sweep completes synchronously inside the DOWN and the barrier returns with the kill unfinished → both fail.
  7. **`unregister/1` defers to the reap-kill DOWN (gated):** same held-kill setup keeping the `register_spawn` ref; with the gate held, `GenServer.cast(tracker, {:unregister, ref})` then `:sys.get_state` (cast-then-call from one sender is FIFO) → the entry is STILL in `by_key` (old code: dropped → fails); release the gate → poll `by_key` empty via the DOWN.
  8. **Supervisor loss mid-kill takes the synchronous fallback (gated):** start a PRIVATE `Task.Supervisor` (unnamed, pid-addressed) and pass its pid as the tracker's `task_supervisor:`; run test 4's setup through the `kills_done == true` + sole-membership poll (gated kill A is the sweep's last dependency, tree = plain `spawn_tree("sleep 300")`); `Supervisor.stop(private_sup)` — ONE stroke deterministically delivers both halves: kill A dies abnormally (its DOWN enters the replace-then-clear path) AND the replacement start exits `:noproc` → `{:error, :unavailable}` → the synchronous in-server `verified_kill` fallback fires; `Task.await(barrier)` → `:ok` with `refute alive?(os_pid)` (the SYNC kill terminated the tree before the sweep was allowed to complete) and `by_key` empty. On the exit-crashing `spawn_kill` the tracker dies here; on a fallback-less implementation the tree is alive at barrier return → both fail.
  9. **Queued attach to a reaping owner refuses + kills, never revives:** owner registers `timeout_ms: 1` then blocks awaiting `:go`; sleep past the TTL; `:sys.suspend(tracker)`; send `:reap`; poll `Process.info(tracker, :messages)` until `:reap` is visible; send the owner `:go` (it fires a blocking direct `{:register, key, os_pid, birth, self(), …}` call for a fresh sleep tree); poll `:messages` until that `{:"$gen_call", _, {:register, …}}` is queued BEHIND `:reap`; `:sys.resume` — the reap kills the owner and marks reaping, THEN the queued register is processed against the reaping entry. Assert: `assert_eventually_dead(cli_os_pid)` (identity adopted, monitored reap kill fired), `by_key` ends empty, and no live entry remains. On plain-attach code: the entry is revived (fresh TTL, reap-exempt) and the tree stays alive → fails.
  Existing owner tests (`:204`, `:228`, `:236`, `:261`) use `timeout_ms: 5_000/30_000` against the shared singleton — untouched; verify green.

## Docs (same change — `system_docs.check` enforces)

- **`docs/system/forge-session-resume.md`**: disposition-table row (`:213`) — corrupt at recovery time now grafts the consumed marker + `repark_reason` (durable, authoritative, ForgeView-visible) instead of "state untouched"; the teardown-barrier owner-resolution sentence (`:319-320`); the reap/tombstone law lines (`:326-329`) — "(owner-only ones drop with no kill)" becomes the removal law (the reap force-stops + retains; a reaping entry is removed only by its DOWN; unregister defers; attach refuses as closing; sweeps adopt pending reap-kills into `pending_kills`), and the tombstone retention becomes "at least a fresh 300s window, only ever extended, never inherited from expired entries"; bump `verified:` to 2026-07-11.
- **`docs/plans/pre-argus-wave-a/README.md` `## Deviations`**: extend the existing 2026-07-11 entry with the second-review corrections — the corrupt lane's planned "no graft, state untouched" posture broke repark durability (now grafts like the other lanes), and the F4-rework reap machinery lapsed its own barrier four ways (owner drop, untracked spawned kill + unregister mid-kill, expired-TTL-inheriting tombstones, queued-attach revival) — now unified under reaping-drops-only-by-DOWN + clamped tombstones.
- **AGENTS.md**: no edit expected (the forge-session-resume bullet doesn't state either micro-behavior); adjust only if a sentence reads false after the fixes.

## Implementation order (compiles at every step)

1. `resume_state.ex` F9 (+ docstring) → `resume_state_test.exs` re-pin + round-trip row → run that file.
2. `child_tracker.ex` F10 (+ moduledoc laws, `:name` option, kill gate) → `child_tracker_test.exs` six new tests → run that file.
3. Docs page + Deviations entry.
4. Targeted sweep: `mise exec -- mix test test/jido_claw/forge/` (+ `mix format`, per-file credo).
5. Final gate: `mise exec -- mix precommit` **bare, in background** (never piped — tail masks the exit code), read the output tail, iterate to green. Traps: credo-strict on new publics (none added — both fixes touch existing functions; the `:name` option keeps `start_link/1`'s existing spec), ExSlop comment rules (no comment line starting with "step"), and the known flaky async:false singletons (MCPServer/Prompt/PipelineStore/MultiSandbox) — verify any failure in ISOLATION before attributing it.

## Verification

- The new child_tracker tests fail on the current code (they pin the exact review repros: owner survives the reap; born-dead key/session tombstones admit registrations mid-barrier; the spawned entry is dropped while its kill provably runs — via reap in both sweep orderings, via unregister, and via an abnormal kill-task DOWN; the tracker exit-crashes when the TaskSupervisor vanishes mid-kill instead of taking the sync fallback; a queued attach revives a reaped owner) and pass after; the re-pinned resume_state row likewise.
- Existing e2e suite (`harness_resume_test.exs`) stays green untouched — F9 changes no shared plumbing, F10 changes no sweep/attach path for non-reaping entries.
- Done when `mise exec -- mix precommit` exits 0. Finish with files-to-stage + suggested commit message (operator commits; no git mutations).
