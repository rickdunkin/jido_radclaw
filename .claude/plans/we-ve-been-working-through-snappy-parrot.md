# Composer Phase 1 — code-review fixes (fold `available/1`, `run_sync` leak, failed-wave history)

## Context

AR-2 Composer Phase 1 (the single-run in-memory loop) just landed and was code-reviewed.
The review surfaced three findings — two `P2`, one `P3`. I validated all three against the
code, tests, and the documented contracts; **all three are real**. This plan resolves them.
"Done" = `mix precommit` green.

Validation evidence (all confirmed):

1. **`Fold.available/1` ignores its own ">=1 producer" contract.** `fold.ex:41` is
   `MapSet.new(Map.keys(store))`, so a store key with an **empty** producer map (e.g. a seeded
   `%{"request" => %{}}`) is still reported available, and the router schedules a stage whose
   required artifact `ArtifactContext` then renders as *no value*. The module's own `@doc`
   (`fold.ex:36-39`) and moduledoc (`fold.ex:18-20`) both promise "a name with at least one
   producer entry" — the code under-delivers. Only caller is the tick (`route_composer.ex:155`),
   so the fix is local. The Phase-1 fixture seeds a **non-empty** producer map
   (`fixtures.ex:238`), so this fix does not perturb the passing integration tests.

2. **`run_sync/1` leaks a linked composer on timeout.** `route_composer.ex:114` is
   `{:ok, _pid} = start_link(...)` (linked) and the timeout branch (`:119`) returns
   `{:error, :timeout}` without unlinking or stopping the pid. The composer keeps turning the
   crank (running waves, writing child runs), and — still linked — a later hard crash propagates
   into a caller that already moved on. No cleanup code exists in the module today.

3. **A failed wave is dropped from history and its child run discarded.** `run_wave/3`'s `else`
   (`route_composer.ex:184-187`) maps both error envelopes to `finish({:failed, reason}, state)`,
   discarding the `_run` (which carries `child_run_id`) and recording no history entry. The
   `:failed` summary then can't say *which* stages failed or point at the child `WorkflowRun`,
   making the failure far less actionable than a successful wave.

## Fixes

### 1 — `Fold.available/1` excludes empty producer maps (`lib/jido_claw/route_composer/fold.ex`)

Filter to names with at least one producer (aligns the code with the existing doc — no doc
change needed):

```elixir
@spec available(store()) :: MapSet.t(String.t())
def available(store) do
  for {name, producers} <- store, map_size(producers) > 0, into: MapSet.new(), do: name
end
```

### 2 — `run_sync/1` cleans up the composer on timeout (`lib/jido_claw/route_composer/route_composer.ex`)

Keep the link (the documented "hard crash propagates" contract stays intact); only the timeout
branch changes — capture the pid, then unlink + kill so a timed-out run leaves no orphan:

```elixir
{:ok, pid} = start_link(start_opts)

receive do
  {:route_composer, ^ref, {:done, summary}} -> {:ok, summary}
after
  timeout ->
    Process.unlink(pid)
    Process.exit(pid, :kill)
    {:error, :timeout}
end
```

Add one sentence to the `run_sync/1` `@doc` (around `:99-103`): on timeout the composer is
unlinked and killed, so **no further waves run** and no leaked process keeps turning the crank.
(Monitor-style ownership was the reviewer's alternative; link + cleanup is the minimal change that
preserves the existing crash-propagation contract for a Phase-1 spike.)

**Scope — what this does and does not stop.** Killing the composer ends the leak (the orphaned
crank-turning GenServer + linked-crash propagation) and prevents any *further* wave (a dead
composer ticks no more). It does **not** cancel the wave already in flight: per
`JidoClaw.Orchestration.RunExecution` (`run_execution.ex:41-60`), the wave's executor task and
Reactor's async steps run under `Task.Supervisor.async_nolink`, so they survive the composer's
death and the current wave **finishes durably "into the void"** — its child `WorkflowRun` terminal
still lands via `ReactorMiddleware`. True mid-wave cancellation (killing the executor via
`Cancellation` / `RunExecution.lookup`) is a larger design and out of scope here; the plan's claim
is precisely "stops the leak and stops further waves," not "interrupts the in-flight wave." State
this explicitly in the `@doc` and the commit message so the boundary isn't overstated.

### 3 — Record failed waves in history, surfacing `child_run_id` (`lib/jido_claw/route_composer/route_composer.ex`)

Bind the run in the 3-tuple `else` clause, route every failure through a `finish_failed/5` that
appends a history entry, and unify the entry builder so successful and failed waves share one
shape distinguished by a `failed:` flag.

- Add `failed: boolean()` to `@type history_entry` (`:58-65`).
- Restructure `run_wave/3` so the decode result (which has the live `run` in scope) routes failures
  with their `run`, and the `else` binds `run` instead of `_run`:

```elixir
defp run_wave(dispatch, display, state) do
  stages = Enum.map(dispatch, &Map.fetch!(state.catalog, &1))

  with {:ok, reactor} <- WaveBuilder.build_wave(stages, wave_index: state.wave_index),
       extra_context = ArtifactContext.build(stages, state.artifacts),
       {:ok, value, run} <- run_reactor(reactor, extra_context, state) do
    handle_wave_value(decode_emissions(value), run, dispatch, display, state)
  else
    {:error, reason} -> finish_failed(reason, nil, dispatch, display, state)
    {:error, reason, run} -> finish_failed(reason, run, dispatch, display, state)
  end
end

defp handle_wave_value({:ok, emissions}, run, dispatch, display, state) do
  next = state |> Fold.fold(emissions) |> record_wave(dispatch, display, run, emissions)
  {:noreply, next, {:continue, :tick}}
end

defp handle_wave_value({:error, reason}, run, dispatch, display, state),
  do: finish_failed(reason, run, dispatch, display, state)

defp finish_failed(reason, run, dispatch, display, state) do
  next = record_wave(state, dispatch, display, run, [], true)
  finish({:failed, reason}, next)
end
```

- Unify `record_wave` (replaces the current `/5`) with a `failed?` default and a nil-tolerant
  `child_run_id` (build-wave failures have no run; decode/run failures do):

```elixir
defp record_wave(state, dispatch, display, run, emissions, failed? \\ false) do
  entry = %{
    index: state.wave_index,
    stages: dispatch,
    child_run_id: run && run.id,
    route: display.route,
    held_before: display.held,
    emissions: Enum.map(emissions, &emission_entry/1),
    failed: failed?
  }

  %{
    state
    | wave_index: state.wave_index + 1,
      prev_route: display.route,
      history: [entry | state.history]
  }
end
```

This keeps the `wave_index == length(history)` invariant for failed runs too (the failed wave
*was* attempted), and `final_route`/`held_before` now reflect the attempted wave. Update the
`record_wave` doc comment (`:212-215`) to note it records both successful and failed waves
(empty emissions + `failed: true` for failures).

## Tests

### Finding 1 — `test/jido_claw/route_composer/fold_test.exs` (add one case)

Pure, alongside the existing `available/1` test:

```elixir
test "available/1 excludes names whose producer map is empty" do
  store = %{"plan" => %{"planner" => "P"}, "request" => %{}}
  assert Fold.available(store) == MapSet.new(["plan"])
end
```

### Finding 3 — `test/jido_claw/route_composer/composer_loop_test.exs` (add one case)

Deterministic wave failure via an undeclared signal (`"bogus-signal"` ∉ `planner.publishes`),
which fails `DefaultMapper.map` → `WaveCollect` → `ReactorRunner` returns `{:error, reason, run}`:

```elixir
test "a wave failure records a failed history entry surfacing child_run_id", ctx do
  bad = put_in(TestFixtures.phase1_stub_outputs(), ["researcher", "signals"], ["bogus-signal"])
  Application.put_env(:jido_claw, :route_composer_stub_outputs, bad)

  assert {:ok, summary} = run(ctx)
  assert summary.terminal == :failed
  assert [entry] = summary.history
  assert entry.failed
  assert entry.stages == ["planner"]
  assert entry.child_run_id        # the wave's reactor ran; its child run id is surfaced
end
```

(No fixture change — `put_in/3` rewrites the researcher's signals on the existing
`phase1_stub_outputs/0` map.)

### Finding 2 — `test/jido_claw/route_composer/composer_loop_test.exs` (add one case) + `composer_stubs.ex` (add a blocking server)

Determinism comes from the block *out-lasting* the timeout, not from a long sleep: the wave is
hard-blocked for `block_ms`, and `run_sync(timeout: t)` with `t < block_ms` means no `:done` can
arrive before `t`, so the timeout fires every time. We prove the composer was *killed*, then —
because the wave executor is `async_nolink` and survives the kill (amendment above) — **drain the
orphaned executor** so its durable write lands inside the test's sandbox rather than after teardown.
Keep `block_ms` modest (test wall-clock ≈ `block_ms`). Add to
`test/support/jido_claw/route_composer/composer_stubs.ex`:

```elixir
defmodule JidoClaw.RouteComposer.TestSupport.BlockingAgentServer do
  @moduledoc """
  A `:step_agent_server` stub whose `await_completion/2` blocks for a bounded
  `block_ms` (app env, default 600) — long enough to outlast a short
  `RouteComposer.run_sync/1` timeout (so the timeout always fires), short enough
  that the orphaned (`async_nolink`) wave executor drains quickly within the
  test's sandbox once released by the sleep.
  """
  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, _opts) do
    Process.sleep(Application.get_env(:jido_claw, :route_composer_block_ms, 600))
    {:ok, %{status: :failed, result: :blocked}}
  end
end
```

Test:

```elixir
test "run_sync unlinks and kills the composer on timeout, then drains the in-flight wave", ctx do
  Application.put_env(:jido_claw, :route_composer_stub_outputs, TestFixtures.phase1_stub_outputs())
  Application.put_env(:jido_claw, :step_agent_server, BlockingAgentServer)

  parent = self()
  task = Task.async(fn -> send(parent, {:run_sync, run(ctx, timeout: 400)}) end)

  composer = await_linked_composer(task.pid)   # capture before the 400ms kill
  cref = Process.monitor(composer)

  # Core: timeout fires (wave blocked 600ms > 400ms) and the composer is *killed*,
  # not left turning the crank. Fails on the unfixed code (composer stays alive →
  # no :killed DOWN → assert_receive times out).
  assert_receive {:run_sync, {:error, :timeout}}, 3_000
  assert_receive {:DOWN, ^cref, :process, ^composer, :killed}, 3_000
  Task.await(task)

  # Hygiene: the in-flight wave runs under async_nolink and outlives the composer;
  # wait for it to finish its durable write so nothing writes under a torn-down
  # sandbox after the test returns.
  drain_run_registry(2_000)
end
```

Two small inline test helpers:

- `await_linked_composer(task_pid)` — bounded poll of `Process.info(task_pid, :links)` returning the
  linked pid whose `Process.info(pid, :dictionary)[:"$initial_call"]` is `{JidoClaw.RouteComposer,
  :init, 1}`. The composer is `start_link`ed at the top of `run_sync/1` (t≈0) and stays alive until
  the 400 ms kill, so the capture window is wide and deterministic.
- `drain_run_registry(timeout)` — **best-effort** bounded poll until
  `Registry.count(JidoClaw.Orchestration.RunRegistry) == 0` (the orphaned wave executor deregisters
  when its task finishes; the composer's wave is the only live run in this `async: false` test, so
  count→0 ⟺ the durable write is done). Best-effort: it returns after the bound without asserting, so
  the hygiene drain can never itself flake the test. (If stricter isolation is wanted, capture the
  executor pid via `Registry.select/2` before the sleep elapses and `assert_receive {:DOWN, …}` on
  it instead.)

Also extend the existing `run/2` helper to thread the timeout, e.g.
`timeout: Keyword.get(opts, :timeout, 30_000)` into `run_sync/1` (it currently hard-codes
`timeout: 30_000`).

## Precommit considerations

`mix precommit` runs (in order): `jidoclaw.compile_check` (clean recompile, **empty allowlist** —
zero non-allowlisted warnings), `system_prompt.check`, `deps.unlock --unused`, `format`,
`reach.check --arch --smells --strict`, `credo --strict`, `dialyzer`, `test`. For this change:

- **Warnings**: all new code is private fns + an updated `@type`; every var is used (the `else`
  `{:error, reason, run}` now consumes `run`), so no unused-var/clause warnings.
- **Dialyzer**: `@type history_entry` gains `failed: boolean()` and **both** record paths set it,
  so the type stays consistent with `@type summary`'s `history: [history_entry()]`. `child_run_id:
  run && run.id` is `term() | nil` — within the declared `term()`.
- **reach `--smells`**: no new **lib** module — only edits to two existing modules; the test-support
  `BlockingAgentServer` mirrors the existing `StubAgentServer` shape, so the smell surface is
  unchanged. No `.reach.exs` edit expected.
- **credo strict**: `run_wave/3` stays a flat `with` + two `else` clauses (helpers keep nesting ≤ 3,
  complexity well under 11); any added comments are rationale-only (no narrator/`# step` traps).
- **No Ash resource** touched → the AshCredo/`belongs_to` gauntlet doesn't apply.

## Verification

Run via `mise exec -- mix` (toolchain is mise-latest). Run gate commands **bare in the background**
and read the output tail — never pipe (a `| tail` masks the exit code).

1. `mise exec -- mix format` (changed files).
2. Targeted: `mise exec -- mix test test/jido_claw/route_composer/fold_test.exs test/jido_claw/route_composer/composer_loop_test.exs` — the new finding-1/2/3 cases plus the existing 4 loop cases pass.
3. The composer suite is `async: false` `TenantCase`; per the suite-flaky note, also run the loop
   file **in isolation** (not just `--seed 0`) to confirm the two new integration cases are stable:
   `mise exec -- mix test test/jido_claw/route_composer/composer_loop_test.exs`. For the timeout
   case specifically, confirm the run is clean of trailing `DBConnection.OwnershipError` /
   "owner exited" warnings — their absence is the signal that the drain landed the orphaned wave's
   durable write before sandbox teardown (the amendment's whole point).
4. Full gate (the done-criterion): `mise exec -- mix precommit` — must be green.
5. Optional Tidewave re-check of finding 1: in `project_eval`, confirm
   `JidoClaw.RouteComposer.Fold.available(%{"request" => %{}})` is now `MapSet.new([])`.

## Files

**Modified (lib)**: `lib/jido_claw/route_composer/fold.ex` (finding 1);
`lib/jido_claw/route_composer/route_composer.ex` (findings 2 + 3 — `run_sync/1`, `run_wave/3`,
`handle_wave_value/5`, `finish_failed/5`, unified `record_wave/6`, `@type history_entry`).

**Modified (test)**: `test/jido_claw/route_composer/fold_test.exs` (+1 case);
`test/jido_claw/route_composer/composer_loop_test.exs` (+2 cases, extend `run/2` to thread
`timeout`); `test/support/jido_claw/route_composer/composer_stubs.ex` (+`BlockingAgentServer`).

**Commit plan** (slicing guidance only — do **not** commit; leave everything unstaged). One commit
once precommit is green: `fix: composer Phase 1 review fixes — available/1 empty-producer filter,
run_sync timeout cleanup, failed-wave history`. (Split into a `fold.ex` commit and a
`route_composer.ex` commit if the user prefers finer granularity.)
