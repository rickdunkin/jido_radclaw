# Fix review follow-ups on M17/L15: already-running re-engagement & agent_id_taken leak

## Context

The M17+L15 implementation (previous plan, all unstaged) got a follow-up code review that found two P2 issues. **Both verified valid against the current code:**

- **P2-1 (valid):** `send_to_agent`'s `start_child` failure branch (`lib/jido_claw/tools/send_to_agent.ex:115-125`) unconditionally forces the entry `:error`. But `AgentTracker.mark_running/2` returns the same `:ok` for *re-activating a terminal entry* and for a *no-op on an already-`:running`* entry (`lib/jido_claw/agent_tracker.ex:362-374`). When the entry was already running (a follow-up sent to a busy agent — nothing guards against it), the forced `:error` terminalizes a live in-flight orchestration: the spawn cap frees while work is still running, and the original task's eventual `mark_complete` is discarded by the from-`:running`-only guard, so its real result status is lost. Relatedly, `reactivate_entry`'s `:running` clause (`agent_tracker.ex:494-496`) demonitors the **live** orchestrator at `mark_running` time — before the replacement task is known to have started — so on start failure (or tool death right after the gate) the in-flight task is left unmonitored and an uncatchable kill would strand the entry `:running` forever (the exact M17 failure mode this was all built to prevent).
- **P2-2 (valid):** `spawn_agent`'s `register` branch (`lib/jido_claw/tools/spawn_agent.ex:116-117`) returns `agent_id_taken_error/1` without stopping `subagent_pid`, which `start_subagent/2` already started. The agent is alive, untracked (register failed), and `restart: :temporary` — the TTL sweep only stops *tracked* agents, so it leaks until app shutdown. Narrow (UUID tags don't collide; explicit tags are pre-checked) but reachable via the pre-check→register TOCTOU and alternate tracker seams. The sibling `start_child`-failure branch (line 178-182) already reclaims correctly — close the asymmetry.

Fix direction (per reviewer, confirmed sound): keep the live orchestrator's monitor for already-running entries until the replacement attaches (`attach_orchestrator` already does demonitor+flush swap), and only force terminal on start failure when the call actually re-activated a terminal entry. For P2-2, reclaim the sub-agent before returning the taken error.

**Completion gate: `mix precommit` must pass.** No commits — leave everything unstaged, like the rest of the M17/L15 work. Greenfield: change `mark_running`'s return shape outright, no compat shim.

## Implementation steps

### 1. AgentTracker: distinguish reactivation, keep live orchestrator ref

**File:** `lib/jido_claw/agent_tracker.ex`

- **`mark_running/2`** (line 150-153): new return shape `{:ok, :reactivated | :already_running} | {:error, :not_found}`. Update `@spec` and `@doc` (lines 137-153): `:reactivated` = flipped a terminal entry back to `:running` (caller owns forcing it back terminal if its dispatch never starts); `:already_running` = no-op, an in-flight orchestration still owns the entry and its monitor stays armed.
- **Handler** (lines 362-374): derive the activation atom from the entry status before mutating:
  ```elixir
  %AgentEntry{pid: ^expected_pid, status: status} = entry ->
    if Process.alive?(expected_pid) do
      activation = if status == :running, do: :already_running, else: :reactivated
      {:reply, {:ok, activation}, reactivate_entry(state, id, entry)}
    else
      {:reply, {:error, :not_found}, state}
    end
  ```
- **`reactivate_entry/3`** (lines 488-503): the `:running` clause **stops demonitoring** — it becomes only `%{state | stopping: Map.delete(state.stopping, id)}`. The terminal clause is unchanged (still demonitors the stale ref + flips status). Rewrite the comment above it: only a *terminal* reactivation drops the (stale) previous ref; an already-running entry keeps its **live** orchestrator monitored until the replacement task attaches (`attach_orchestrator` does the demonitor+flush swap).
- **Moduledoc** invariant 3 (lines 36-51): update the last parenthetical — the stale-`:DOWN` close applies to "re-attach and terminal-entry reactivation"; an already-running entry keeps its current orchestrator armed until the replacement attaches. Add to the accepted residuals, stated honestly (not as "benign"): in the already-running swap window (between `mark_running` and the new task's attach), the old orchestrator dying forces the entry `:error` while the new dispatch proceeds — the new dispatch's later `mark_complete` is then discarded by the from-`:running`-only guard, so its terminal status (and the tracker-visible result status) can be lost. Rare, and accepted because it still beats leaving the live task unmonitored (a strand); a full fix needs per-run generation/tokens on terminal writes, or a policy decision to reject `send_to_agent` while a run is in flight — both deliberately out of scope here.

### 2. SendToAgent: only force terminal when this call reactivated

**File:** `lib/jido_claw/tools/send_to_agent.ex` (`dispatch/5`, lines 59-131)

- Match `{:ok, activation}` at line 67-68 (the `{:error, :not_found}` clause is unchanged).
- In the `start_result` `{:error, reason}` branch (lines 115-125): replace the unconditional `mark_complete` with a pattern-matched helper, keeping the same error return:
  ```elixir
  defp release_failed_engagement(:reactivated, agent_id),
    do: agent_tracker().mark_complete(agent_id, :error)

  defp release_failed_engagement(:already_running, _agent_id), do: :ok
  ```
  Rewrite the branch comment: a `:reactivated` entry has nothing left to complete it — force it terminal (agent pre-existed, stays alive/re-engageable); an `:already_running` entry still belongs to the in-flight orchestration, whose monitor stayed armed — leave it untouched.
- Update the `mark_running` gate comment (lines 62-66) to mention the two activation outcomes.

### 3. SpawnAgent: reclaim the sub-agent on `agent_id_taken`

**File:** `lib/jido_claw/tools/spawn_agent.ex` (lines 116-117)

```elixir
{:error, :agent_id_taken} ->
  # The sub-agent started but the tracker never adopted it — reclaim it,
  # mirroring the start_orchestration failure branch: an untracked agent
  # is invisible to the TTL sweep and would leak alive forever.
  _ = jido_runtime().stop_agent(subagent_pid)
  {:error, agent_id_taken_error(tag)}
```

### 4. Task-supervisor seam (makes both failure branches testable)

Both tools hardcode `Task.Supervisor.start_child(JidoClaw.TaskSupervisor, ...)`; the supervisor has no `max_children`, so the failure branches are unreachable in tests today. Add the same env seam idiom these modules already use for `:jido_runtime`/`:agent_tracker`/`:agent_templates`:

```elixir
defp task_supervisor do
  Application.get_env(:jido_claw, :task_supervisor, JidoClaw.TaskSupervisor)
end
```

in **both** `send_to_agent.ex` and `spawn_agent.ex`, used at their `start_child` call sites. (The tracker's own sweep stop-task keeps the hardcoded name — out of scope.) Tests inject failure with a real cramped supervisor: `start_supervised!({Task.Supervisor, name: __MODULE__.CrampedTaskSup, max_children: 0})` → `start_child` deterministically returns `{:error, :max_children}`.

### 5. Tests

**`test/jido_claw/agent_tracker_test.exs`** — return-shape updates + the keep-ref pin:
- Update assertions: line 130 → `{:ok, :reactivated}`; line 142 → `{:ok, :already_running}` (retitle the test accordingly); lines 184, 287, 427 → `{:ok, :reactivated}`.
- New test in the `attach_orchestrator/2` describe (red today): **"mark_running on an already-running entry keeps the current orchestrator armed"** — register agent, `attach_orchestrator(id, orch1)`, `mark_running(id, agent)` → `{:ok, :already_running}`, `kill_and_wait(orch1)` → entry `:error` with `"orchestrator died"`, cap 0. (Today the mark_running demonitors orch1, so the entry strands `:running`.)
- Existing "mark_running reactivation drops the stale orchestrator ref" (line 276) stays — it pins the terminal clause still demonitoring.

**`test/jido_claw/tools/send_to_agent_test.exs`:**
- Fakes: `FakeTracker.mark_running` (line 36-37) and `CapturingTracker.mark_running` (line 71-72) → return `{:ok, :reactivated}`, update their `@spec`s.
- Setup (lines 146-171): save/restore `:task_supervisor` env alongside the others.
- Two new tests in the "re-engagement of a finished agent (real tracker)" describe block (reuse `BlockingTemplates`, `wait_until`, the `register(self())`/FakeJido pid-identity pattern):
  1. **"a start failure on a busy agent leaves the in-flight run intact (P2-1 regression)"** — first send succeeds (`{:ask_sync_started, task1, _}`), entry `:running`; swap `:task_supervisor` to the cramped sup; second send returns `{:error, %{details: %{phase: :dispatch}}}`; assert entry still `:running` and `child_count == 1` (red today: forced `:error`); then `Process.exit(task1, :kill)` → `wait_until` entry `:error` with `"orchestrator died"` (red today: monitor was dropped at the gate → strand).
  2. **"a start failure on a re-engaged terminal entry forces it back terminal"** — register, `mark_complete(:done)`, cramped sup from the start; send returns the dispatch error; entry `:error`, `child_count == 0`, agent (test process) alive. Pins the `:reactivated` arm, previously untestable.

**`test/jido_claw/tools/spawn_agent_test.exs`:**
- `FakeRuntime.stop_agent/1` (lines 19-20): record — `send(Application.fetch_env!(:jido_claw, :spawn_agent_test_pid), {:stop_agent, target})` then `:ok`.
- New minimal fake for the taken path: `TakenTracker` with `child_count(_opts), do: 0` and `register(_, _, _, _, _), do: {:error, :agent_id_taken}` (`SwarmScope.tracker_scope` is pure, and the generated-id path skips `ensure_agent_id_available`, so nothing else is called).
- Setup (lines 89-108): save/restore `:agent_tracker` and `:task_supervisor` env.
- Two new tests:
  1. **"reclaims the started sub-agent when registration is taken (P2-2 regression)"** — `configure_fake_spawn()` + `put_env(:agent_tracker, TakenTracker)`; run **without** a tag; assert `{:error, %{code: :validation_error, details: %{reason: :agent_id_taken}}}`, `assert_receive {:start_agent, _opts, started_pid}`, `assert_receive {:stop_agent, ^started_pid}` (red today), and `refute_receive {:ask_sync, ...}`.
  2. **"a start_child failure forces the entry terminal and reclaims the sub-agent"** — real tracker + `configure_fake_spawn()` + cramped sup; run → `{:error, %{details: %{phase: :spawn}}}`; `assert_receive {:start_agent, _, started_pid}`, `assert_receive {:stop_agent, ^started_pid}`, entry `:error`, `child_count == 0`. Pins the existing (correct) branch the reviewer used as the model, previously untestable.
- **Pid hygiene:** `FakeRuntime.stop_agent` stays record-only (same deliberate design as `AgentTrackerTest.FakeRuntime` — tests control pid lifetime), so the fake's sleep-infinity agents are NOT killed by the reclaim call. Both new tests must end with `Process.exit(started_pid, :kill)`, matching the file's existing cleanup convention.

### 6. Review-doc annotation refresh

**File:** `docs/reports/code-review-2026-06-10.md`

- M17 bullet (line 243): correct the now-stale sentence "Re-attach, `mark_running` reactivation, and eviction all demonitor the previous orchestrator ref…" → re-attach, **terminal-entry** reactivation, and eviction; then append a short **review follow-up** note: a second-pass review found the no-op `mark_running` ambiguity (start-failure could terminalize a live in-flight run and drop its monitor) — fixed by `{:ok, :reactivated | :already_running}` + keep-live-ref-until-attach + conditional release in `send_to_agent`, and the `agent_id_taken` branch in `spawn_agent` now reclaims the started sub-agent like the start-failure branch; both with red-first regression tests and a `:task_supervisor` seam making the start-failure branches testable.
- Use the actual landing date for the follow-up note, and align the three existing "2026-06-12" M17/L15 annotation dates (lines 243, 264, 298) to it if landing on a different day — it's all one unstaged batch.

## Verification

1. `mix format`, `mix compile --warnings-as-errors`.
2. Targeted (same list the reviewer ran; all touched tests are in it): `mix test test/jido_claw/jido_test.exs test/jido_claw/agent_tracker_test.exs test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/skills/steps/agent_runner_test.exs test/jido_claw/agent/handoff/router_test.exs test/jido_claw/reasoning/compactor/coherence_test.exs`.
3. Red-first proof for the three regression pins: before applying the lib changes (or by temporarily reverting them), the new tests in step 5 marked "red today" must fail; after, pass.
4. **`mix precommit`** — the completion gate (compile_check, system_prompt.check, deps.unlock --unused, format check, reach.check --arch --smells --strict, credo --strict, dialyzer, full test).
5. Leave all changes unstaged; no commits.
