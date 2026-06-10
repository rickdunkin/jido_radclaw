# Fix H10 (AgentTracker spawn-cap lockout) + H11 (compactor exception safety)

## Context

From `docs/reports/code-review-2026-06-10.md`, the two highest-value reliability fixes after H1/H2:

- **H10**: `AgentTracker.child_count` counts every non-`"main"` entry regardless of status, and nothing ever removes entries. After 8 cumulative spawns in a scope, every further `spawn_agent` fails with `:max_children` until restart, and the `agents` map grows unboundedly.
- **H11**: `Compactor.maybe_compact/3` has no `try/rescue`. `Storage.latest` (compactor.ex:242, 259) and `load_slice_count` (compactor.ex:275 → Ash `Message` reads) can raise (e.g. `DBConnection` pool errors) uncaught, and `Compactor.Telemetry.with_compaction` (compactor/telemetry.ex:60-75) **reraises rescued exceptions** expecting the caller to rescue — which it doesn't. A raise propagates through `Defaults.on_before_cmd/2` (defaults.ex:72-82) and crashes the live ReAct turn, violating the documented "never blocks forward progress" contract. (Precise telemetry semantics: raises are reraised; **exits are already converted to `{:error, reason}`** there; throws pass through uncaught.)

**User decisions/review feedback incorporated**:
- TTL sweep (terminal TTL **30 min**, sweep every 60s), not evict-on-`:DOWN` — immediate eviction breaks SwarmView counts, the Display "Swarm complete" summary, and swarm history.
- **Invariant 1: a live runtime agent always has a tracker entry.** Scoped tools (`send_to_agent`, `get_agent_result`, `kill_agent`) prove tenant ownership through the tracker entry before touching the runtime. Expiry is **stop-idle-child-then-evict**: the sweep only ever evicts dead pids.
- **Invariant 2: an entry can be `:running` only while its pid is alive and monitored** (else it would consume the spawn cap forever with nothing to transition it). `mark_running` validates liveness atomically in the tracker; all post-`mark_running` failure paths end in `mark_complete` or are covered by the armed monitor.
- `mark_complete` gets the same from-`:running`-only terminal guard as `:DOWN` (one shared helper; closes the clobber race in both directions).
- Stop requests are deduplicated across sweeps (`stopping` map with retry threshold) and stop failures are logged.
- The H11 containment rescue path itself must be non-throwing (`safe_emit_error`).
- Public-behavior tests around TTL expiry assert tracker state after not_found paths, not just return values.

Greenfield — no compat concerns. **Done = `mix precommit` passes** (compile_check, system_prompt.check, deps.unlock --unused, format, `reach.check --arch --smells --strict`, credo --strict, dialyzer, full test suite).

## H10 — `lib/jido_claw/agent_tracker.ex` (+ `tools/send_to_agent.ex`)

Verified: the only production caller of `child_count` is `enforce_spawn_limits/2` (spawn_agent.ex:154). `jido_runtime().stop_agent(id)` (from `use Jido`, deps/jido/lib/jido.ex:455-465) = `DynamicSupervisor.terminate_child` — removes the child, no `:permanent` restart; same API `kill_agent` uses. `JidoClaw.TaskSupervisor` starts before `AgentTracker` (application.ex:141 vs 268).

1. **`child_count` handler (lines 262-269)** — count only `id != "main" and entry.status == :running`. Update `@doc` (~131). **This alone fixes the spawn lockout.**

2. **Shared terminal-transition helper** — one private `complete_entry(state, id, status, error \\ nil)` that transitions **only from `:running`** (sets `status`/`finished_at`/`error`), `notify_display({:agent_completed, ...})` only on actual transition, and clears the id from the `stopping` map. Used by:
   - `mark_complete` cast handler (300-308) — a late `mark_complete(:done)` can no longer clobber a `:DOWN`-marked `:error`.
   - `:DOWN` handler (316-337) — no clobber of `:done` → `:error`, no duplicate display events. **`:DOWN` never evicts** (pre-TTL history preserved; dead-pid terminal entries are TTL-swept later).

3. **`mark_running/2` (new, synchronous call, liveness- and identity-validating)** — `mark_running(id, expected_pid)` flips an entry back to `:running` (`finished_at: nil, error: nil`, clear from `stopping`) **only if the entry exists, `entry.pid == expected_pid`, and `Process.alive?(entry.pid)`**; otherwise returns `{:error, :not_found}` with **no mutation** (a dead terminal entry stays terminal and sweepable — never resurrect what the monitor can't watch; the pid match closes the stale-registry/stale-tracker edge since the caller dispatches to the `whereis` pid; pid alive ⟹ its monitor ref is still in `monitors`, since refs are only removed by `:DOWN` (pid dead) or eviction (entry gone)). Already-`:running` entries with a matching live pid return `:ok` (no-op).

4. **`send_to_agent` re-engagement** (lib/jido_claw/tools/send_to_agent.ex:23-63 currently leaves the entry `:done` during follow-ups and discards the outcome at line 62 — so "terminal" doesn't mean "idle", and a TTL stop could kill in-flight work):
   - Order **everything fallible before** `mark_running`: keep the early `whereis` preflight (line 26), hoist `template_for_agent` + child-context build, **and `register_child_correlation/1`** (it touches Ash/Postgres via `RequestCorrelation.register/1`, jido_claw.ex:288/362, so it can raise — before the gate a raise propagates with no tracker mutation; an unused correlation row is benign since the entry's `request_id` is only updated after the gate). Then `mark_running(agent_id, pid)` is the **last gate** before dispatch (`{:error, :not_found}` → `Error.not_found(:agent, ...)`). After it succeeds, only `update_request_id` (tracker call, no-op-safe) and the spawn block remain; pid death before/during dispatch self-heals via the armed monitor → `:DOWN` → `:error`.
   - In the spawn block: keep `record_result`'s status and call `agent_tracker().mark_complete(agent_id, status)` (mirroring spawn_agent.ex:97-98), and wrap the block body in a minimal `try/rescue` → `mark_complete(agent_id, :error)` so a crash in `record_task`/`record_result` can't strand the entry `:running` (narrow guard for the state this change introduces; the full M17 supervised-task fix stays out of scope).
   - Side effects are correct: a re-engaged agent counts toward the spawn cap again and re-shows as running in the swarm UI.

5. **TTL sweep (stop-then-evict, deduplicated)** — state gains `stopping: %{id => requested_at_ms}`:
   - Arm first timer in existing `handle_continue(:setup, ...)` (152-172): `Process.send_after(self(), :sweep_terminal, sweep_interval_ms())`; re-arm in the handler.
   - New `handle_info(:sweep_terminal, state)`: for entries where `id != "main"`, `status in [:done, :error]`, `is_integer(finished_at)`, `now - finished_at >= terminal_ttl_ms()`:
     - **pid dead** → evict: `Map.drop` from `agents`, reject from `order`, `Process.demonitor(ref, [:flush])` + drop any `monitors` refs for evicted ids (`:flush` kills queued `:DOWN`s), delete from `stopping`. No `notify_display` on sweep.
     - **pid alive** → request stop **only if** id is absent from `stopping` or `now - requested_at >= stop_retry_ms()` (re-record `requested_at`, log re-requests): `Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> ... end)` where the task calls **`jido_runtime().stop_agent(entry.pid)`** — by pid, not id: `Jido.stop_agent/2` supports pids (deps/jido/lib/jido.ex:455-458, straight to `DynamicSupervisor.terminate_child`), and stopping the monitored pid avoids the stale/missing-registry case where an id lookup fails forever while the pid lives. The task logs non-`:ok` results (debug for `{:error, :not_found}` — already gone; warning otherwise) and catches exits → log (observable, never crashes noisily). **Keep the entry**; once the pid dies (`:DOWN` drops the ref + clears `stopping`), a later sweep evicts. An agent is never invisible while alive.
   - `:DOWN` and `reset` also clear `stopping` for their ids; `reset` returns the empty-state map including `stopping: %{}`.
   - Tracker gains the `jido_runtime()` accessor (`Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)` — same indirection as the tools, test-swappable).
   - Config readers (private, read per-call; code-defaults only, matching the `:spawn_agent_max_children` precedent): `:agent_tracker_sweep_interval_ms` default `60_000`, `:agent_tracker_terminal_ttl_ms` default `1_800_000`, `:agent_tracker_stop_retry_ms` default `300_000`.
   - Moduledoc: "lifecycle & retention" note — `child_count` counts `:running` only; terminal entries retained for observability; expiry = stop idle child, evict once dead; the two invariants above.

Accepted consequences (note, don't fix): after expiry, finished agents drop out of swarm_status/list_agents history and RuntimeOverview's scoped agent count (intended). Narrow benign race: a sweep-initiated stop already in flight when `mark_running` lands can kill the dispatch target; the armed monitor marks `:error` — recorded, not stranded.

## H11 — `lib/jido_claw/reasoning/compactor.ex` (+ doc touch in `agent/defaults.ex`)

`maybe_compact/3` clauses: `:off` (117-118, untouched), `:manual` (120-154), auto catch-all (156-207). Only the `cond`s' `true ->` I/O branches get wrapped — the `missing_context`/collision branches keep returning `{:ok, action}` / `{:error, :existing_request_transformer}` (tests assert the latter).

1. **Containment wrapper** (private, function-level rescue like trace.ex:271-279):
   ```elixir
   defp compact_or_forward(action, base_metadata, fun) do
     fun.()
   rescue
     # reach:disable-next-line bare_rescue
     e ->
       Logger.warning("[Compactor] compaction raised; forwarding original action: " <> Exception.message(e))
       safe_emit_error(:exception, e, base_metadata)
       {:ok, action}
   catch
     kind, reason ->
       Logger.warning("[Compactor] compaction #{kind}: #{inspect(reason)}; forwarding original action")
       safe_emit_error(:exception, reason, base_metadata)
       {:ok, action}
   end
   ```
   - What it actually catches: raises from outside `with_compaction` (`Storage.latest` 259/242, `load_slice_count` 275) and raises **reraised** by `with_compaction` (telemetry.ex:70); exits from outside `with_compaction` (inside ones already return `{:error, reason}` via its `:exit` catch — handled by the existing `handle_result` path); throws from anywhere (telemetry doesn't catch throws).
   - **`safe_emit_error/3`**: wraps `emit_error/3` (verified signature `(stage, reason, base_metadata)`, compactor.ex:692-708) in its own rescue/catch that only `Logger.debug`s — a `Trace.emit` fault must not crash the containment path. Each bare rescue gets the `# reach:disable-next-line bare_rescue` pragma (no `.reach.exs` allowlist exists; per-site pragma is the convention).
   - Leave `with_compaction`'s reraise as-is — its documented "caller rescues" contract finally becomes true.

2. **Auto `true ->` branch (180-205)**: `compact_or_forward(action, compactor_ctx.base_metadata, fn -> run(action, params, compactor_ctx) end)`.

3. **Manual `true ->` branch (143-152)**: `manual_install/3` builds its metadata internally, so build the emit map in the branch: `meta = %{tenant_id: tenant_id, session_uuid: session_uuid, agent_id: agent_id, request_id: request_id}` then `compact_or_forward(action, meta, fn -> manual_install(...) end)` (manual_install call unchanged).

4. **Testability seam** (no Mimic/Mox in repo; convention is Application-env module swapping, e.g. `:compaction_summarizer`, summarizer.ex:201-204): `defp storage, do: Application.get_env(:jido_claw, :compaction_storage, Storage)` with `@spec storage() :: module()`; route **all 5** `Storage.` call sites through it (242, 259, 373, 747, 829).

5. **Docs**: compactor.ex moduledoc "Always best-effort" (~28-34, ~110-113) — raises/exits/throws now contained (original action forwarded, `:exception`-stage error trace). defaults.ex moduledoc (~33-36) — best-effort covers raises, not just `{:error, _}`.

## Tests

**New `test/jido_claw/agent_tracker_test.exs`** (`async: false`; mirror spawn_agent_test/swarm_view_test idioms: `AgentTracker.reset()` setup + on_exit, live child pids via `spawn(fn -> Process.sleep(:infinity) end)`, cast-drain barrier via `get_state()`, `restore_env/2` for config keys and `:jido_runtime`; trigger sweeps deterministically with `send(AgentTracker, :sweep_terminal)` + barrier, TTL=0 — no timer sleeps; barrier between `mark_complete` cast and the `send`):
- child_count ignores terminal entries (which remain in `get_state`)
- `:DOWN` on running marks `:error` / preserves an earlier `:done`
- `mark_complete(:done)` after `:DOWN`-marked `:error` does not clobber (reverse race)
- `mark_running/2`: re-activates a live terminal entry with a matching pid (counts in child_count again); **returns `{:error, :not_found}` and mutates nothing for a dead-pid entry, a mismatched `expected_pid`, and a missing id**
- post-`mark_running` self-healing: mark_running ok → kill pid → `:DOWN` → entry ends `:error`, never stuck `:running`
- sweep + dead pid → evicted from `agents`/`order`, demonitored (later kill of an already-swept id is silent/no crash); running + `"main"` + fresh-terminal entries survive
- sweep + live pid → entry retained, `stop_agent(pid)` called on the fake runtime **with the entry's pid**; **a second sweep before the retry threshold does NOT fire a duplicate stop** (FakeRuntime records calls); once dead, next sweep evicts
- sweep does **not** stop an entry re-marked `:running` via `mark_running`

**`test/jido_claw/tools/spawn_agent_test.exs`** — H10 acceptance regression: `:spawn_agent_max_children` = 1, register + `mark_complete` one child, flush, then `SpawnAgent.run` **succeeds** (fails with `:max_children` before the fix).

**Public-behavior TTL tests** (tool test files or a describe in agent_tracker_test, existing FakeRuntime/put_env patterns):
- after stop-but-not-yet-evicted (entry present, `whereis` → nil): `send_to_agent`/`get_agent_result` → not_found via whereis guard; `kill_agent` → not_found from `stop_agent`. **Assert afterwards: the entry is still terminal (not `:running`) and `child_count` is unchanged (0)** — this is the assertion that catches the resurrection race.
- after full eviction: all three → not_found via `scoped_agent`
- `send_to_agent` happy path: marks running before dispatch, `mark_complete`s the follow-up outcome; failure path (e.g. template lookup fails): entry stays terminal, child_count 0 (extend send_to_agent_test)

**`test/jido_claw/reasoning/compactor/compactor_test.exs`** — new `describe "maybe_compact/3 — exception containment"` with its own telemetry-attach setup (copy the manual-mode describe's setup at 252-269 — capture is per-describe) and `:compaction_storage` put_env/restore. Stubs: `RaisingStorage` (raise in `latest`), `ExitingStorage` (`exit(:boom)` in `latest`), `ThrowingStorage` (`throw(:boom)` in `latest`), `PersistRaisingStorage` (delegates `latest` to real `Storage`, raises in `persist`):
- auto-mode `latest` raise → `{:ok, ^original_action}` (unchanged, no transformer) + `{:compaction_event, _, %{event: :error, stage: :exception}}`
- auto-mode `latest` exit → same; `latest` throw → same (exit/throw originate **outside** `with_compaction` — the paths the outer `catch kind, reason` exists for)
- manual-mode `latest` raise → same
- persist raise with a real seeded slice (`seed_full` + turns over threshold + existing `FixedSummaryBackend`) → `{:ok, ^action}` + `stage: :exception` — proves the wrapper catches `with_compaction`'s **reraise**
- re-run existing collision test (`{:error, :existing_request_transformer}`) and `:load_snapshot` error-tuple test (372-392) — no regression

## Report annotation

Following the H1/H2 convention in `docs/reports/code-review-2026-06-10.md`: append "— ✅ fixed 2026-06-10" to H10/H11 headings with a short **Fixed (2026-06-10):** paragraph each (H10: child_count counts `:running` only; retain-and-sweep with stop-idle-then-evict instead of evict-on-`:DOWN`; the two lifecycle invariants; both terminal writers guarded; send_to_agent re-engagement made status-coherent. H11: containment wrapper + non-throwing emit path + storage seam). Annotate priority item 2 (H12 remains open).

## Verification

1. Targeted: `mix test test/jido_claw/agent_tracker_test.exs test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/reasoning/compactor/compactor_test.exs test/jido_claw/agent/defaults_compaction_test.exs`
2. New regression/containment tests fail on HEAD, pass with the fix.
3. **`mix precommit`** — the completion gate. Watch: reach `bare_rescue` pragmas (two sites in compactor.ex), dialyzer on the `storage()` seam (precedented pattern; tighten with the `module()` spec if flagged — no ignore entry unless actually needed), `mix format`.

## Order of work

1. H10 child_count fix + spawn_agent regression test
2. H10 shared terminal guard (`mark_complete` + `:DOWN`) + liveness/pid-validating `mark_running/2` + send_to_agent reordering (correlation hoisted before the gate) + outcome recording
3. H10 sweep (stop-then-evict with `stopping` dedup + logging) + tracker test file + public-behavior TTL tests
4. H11 seam + wrapper + safe_emit_error + compactor tests
5. Doc touch-ups + report annotations
6. `mix precommit`
