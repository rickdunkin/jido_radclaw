# Executor Seam PR-1 — post-review remediation (3 findings)

## Context

PR-1 of the executor seam (plan `please-review-docs-plans-unadopted-next-temporal-wilkes.md`) shipped unstaged; a code review flagged three issues. All three were **verified against the source and are CONFIRMED** (P2 with a narrower mechanism than the review states). This plan fixes all three. Done = bare `mix precommit` green.

### Verification verdicts

**P1 CONFIRMED — `run_iteration` outer/inner timeout geometry (deterministic, not just a race).**
`ForgeExecutor.run_session` calls `Forge.run_iteration(sid, timeout: 180_000)` (`forge_executor.ex:184`) → `Harness.run_iteration/2` (`harness.ex:56-58`) uses `opts[:timeout]` as the **outer** `GenServer.call` deadline while the same opts ride to the runner task → `Runners.Shell` → `Sandbox.exec` → HostShell's **inner** OsCmd deadline (`host_shell.ex:75,94` — expiry manufactures `{"timeout after Nms", 124}`). The outer clock starts before the inner one, so on a genuinely slow command the outer **always** expires first → uncaught `:exit, {:timeout, {GenServer.call, …}}` (`call/3` catches only `:noproc`, `harness.ex:123-141`). Upstream: `run_session`'s `try/after` runs `stop_session` on the way out, but `AgentRunner.run_recorded` has `rescue` only — **exits are not caught** — so the exit escapes the documented `{:ok, StepResult} | {:error, binary}` step contract into the Reactor. Precedent fix confirmed: `Harness.exec/3` cushions via `exec_call_timeout/1` = inner + `Forge.exec_timeout_cushion_ms()` (5_000), unit-tested at `run_command_test.exs:772-776`.
Caller sweep (shared-helper ripple): `Harness.run_iteration` callers are the bridge (180_000), the consolidator (`run_server.ex:453`, integer `timeout_ms`, already wrapped in `rescue` + `catch :exit`, no exact-deadline watchdog on its task — the cushion is safe and mildly beneficial there), and one test (`timeout: 1_000`, instant CrashingRunner — unaffected). No caller passes `:infinity`/non-integer (whose semantics `exec_call_timeout/1` would change).

**P2 CONFIRMED (narrower than reviewed) — the terminal-publish sequence is not total.**
`agent_runner.ex:216-230` promises "best-effort — a bus miss must never fail the step", but nothing enforces it. The dep's `bus_call` (`deps/jido_signal/lib/jido_signal/bus.ex:521-530`) **does** absorb `:noproc`/`:timeout` exits → `{:error, _}`, so a cleanly-dead bus is safe. What still escapes: (a) the bus dying **mid-call** — exit reasons `:killed`/`{:shutdown, _}`/crash reasons don't match the dep's catch clauses; (b) the bus **registry** being gone (app teardown) — and this raises in **`Bus.whereis` itself**, not just publish: `Bus.whereis` delegates to `Jido.Signal.Util.whereis` (`deps/jido_signal/lib/jido_signal/util.ex:117-131`), which calls `Registry.lookup/2` — `ArgumentError` on an unknown registry. Case (b) raises → `run_recorded`'s rescue converts a **successful** forge step into `{:error, "Step … crashed"}` and the rescue-path `record_terminal` then waits out the Recorder flush-barrier timeout (the signal was never published); case (a) exits → escapes `run_recorded` entirely. House precedent: `AgentServerPlugin.Recorder` wraps its `Bus.publish` in `rescue` + `catch kind, payload` for exactly this (`agent_server_plugin/recorder.ex:62-74`).

**P3 CONFIRMED — whitespace-only shell command passes hydration.**
`templates.ex:536-537` guard `is_binary(command) and command != ""` passes `"   "` → `Runners.Shell` → `sh -c "   "` → exit 0, empty output → `{:ok, Runner.done("")}` — the exact silent green the "command-less shell template fails closed" contract (moduledoc + operator decision 2) forecloses. Guards can't call `String.trim/1`, so the fix restructures into the body.

---

## Fixes

### 1. P1 — cushion `Harness.run_iteration/2` (`lib/jido_claw/forge/harness.ex`)

- Change `run_iteration/2` (harness.ex:55-59) to size the outer call with the **existing** `exec_call_timeout/1`:
  ```elixir
  def run_iteration(session_id, opts \\ []) do
    call(session_id, {:run_iteration, opts}, exec_call_timeout(opts))
  end
  ```
  with a comment mirroring `exec/3`'s C3 note: outer = inner + cushion so a real command timeout surfaces as the runner's graceful reply (Shell maps HostShell's manufactured `{_, 124}`) instead of an uncaught caller `:exit` — the same geometry `exec/3` fixed.
- Update `exec_call_timeout/1`'s doc comment (harness.ex:73-77): it now sizes the outer deadline for **both** `exec/3` and `run_iteration/2`. Keep the name — `run_command_test.exs:772-776` references it and a rename buys nothing.
- **`lib/jido_claw/forge.ex`** doc-truth: the cushion comment (forge.ex:108-118) enumerates "Two independent consumers" — update to include `Harness.run_iteration/2` (three consumers; false-invariant sweep rule).
- Explicit non-change: runners that ignore `opts[:timeout]` (or the no-`:timeout` default, where HostShell's inner is `:infinity`) can still hang to the outer deadline and exit the caller — pre-existing for those callers, out of scope; the cushion neither helps nor hurts them.

### 2. P2 — make the whole terminal-publish sequence total (`lib/jido_claw/skills/steps/agent_runner.ex`)

- Make `publish_forge_terminal/2` itself total with **function-level** `rescue`/`catch` around the entire `whereis → Jido.Signal.new → Bus.publish` sequence (the `Recorder.Plugin` pattern, recorder.ex:62-74) — `Bus.whereis` reads the jido_signal Registry and raises `ArgumentError` when the registry is gone during teardown, so a wrapper scoped to publish alone would still leak that raise:
  ```elixir
  defp publish_forge_terminal(request_id, result) do
    type = ...

    with {:ok, _pid} <- Bus.whereis(JidoClaw.SignalBus),
         {:ok, signal} <-
           Jido.Signal.new(type, %{request_id: request_id}, source: "/forge_executor") do
      _ = Bus.publish(JidoClaw.SignalBus, [signal])
    end

    :ok
  rescue
    e ->
      Logger.warning("[AgentRunner] forge terminal publish raised: #{Exception.message(e)}")
      :ok
  catch
    kind, payload ->
      Logger.warning("[AgentRunner] forge terminal publish #{kind}: #{inspect(payload)}")
      :ok
  end
  ```
  An ordinary `{:error, :not_found}` whereis miss stays a **quiet skip** (the `with` falls through without logging — bus not running ⇒ no warning noise); only a genuine raise/exit/throw logs. Publish stays **inside** `run_fun` — ordering is load-bearing (signal before `record_step_terminal`'s flush barrier).
- Add `require Logger` to the module (currently absent). The module-level `# reach:disable-for-this-file bare_rescue` pragma (agent_runner.ex:25) already covers the new rescue. Update the function comment to state the exact windows this closes (whereis registry-gone raise; mid-call bus death; publish-side registry raise) — the dep's `bus_call` already absorbs clean `:noproc`/`:timeout`.
- Clone-check note: the wrapper's body differs from `Recorder.Plugin`'s (log prefixes, return, enclosed `with`); non-contiguous, different module — below ExSlop min_mass risk.

### 3. P3 — reject blank shell commands (`lib/jido_claw/agent/templates.ex`)

- Restructure `validate_executor!({:forge, :shell}, config, t)` (templates.ex:533-545) — `String.trim/1` is not guard-safe:
  ```elixir
  command = Map.get(config, :command)

  if is_binary(command) and String.trim(command) != "" do
    :ok
  else
    raise ArgumentError,
          "executor {:forge, :shell} for #{inspect(Map.get(t, :module))} requires " <>
            ":executor_config %{command: <non-blank binary>}, got command: #{inspect(command)}"
  end
  ```
  Message keeps matching the existing tests' `~r/requires :executor_config/` (templates_test.exs:529,539). Extend the clause comment: whitespace-only runs `sh -c "   "` → exit 0 — the same silent green.
- Hydration is the single gate (`forge_executor.ex:87` trusts `executor_config.command`), so no other site needs the check. AGENTS.md's "a command-less shell template raises" stays true — no doc change required.

---

## Tests

1. **P1 regression** — `test/jido_claw/forge/harness_iteration_monitor_test.exs` (already `async: false` + Forge persistence disabled): new test starting its own real HostShell session —
   `Forge.start_session(sid, %{runner: :shell, runner_config: %{command: "sleep 2"}, sandbox: :local})`, await `{:ready, ^sid}`, then
   `assert {:ok, %{status: :error, error: error}} = Forge.run_iteration(sid, timeout: 200)` with `error =~ "exit code 124"`; `on_exit` stops the session.
   **Red-first proof**: without the cushion the outer call exits at ~200ms (test fails with the exit); with it, HostShell's inner OsCmd kills the command at 200ms and the manufactured 124 reply arrives well inside the cushion (~0.3s runtime). Run it once against the unfixed harness to confirm red, then fix.
2. **P3 regression** — `test/jido_claw/templates_test.exs`: mirror the empty-string test at :535 with a whitespace-only command (`" \n\t "`) asserting `assert_raise ArgumentError, ~r/requires :executor_config/`. Confirm red before the fix.
3. **P2 — accepted untested residual (documented)**: the escape windows (registry gone at whereis/publish; bus dies mid-call) have no deterministic injection seam — `bus_call` absorbs clean `:noproc`, so killing the bus in a test only exercises the quiet `{:error, :not_found}` skip. Precedent parity: `Recorder.Plugin` ships the identical wrapping without fault-injection tests. The function is total by construction (function-level rescue/catch encloses the whole sequence); the existing forge-envelope tests in `agent_runner_test.exs` remain the guard for the happy publish path. No prod seam gets added just to make this injectable.
4. Existing suites stay green: templates / forge_executor / agent_runner / composer-forge eval files (the 135 the reviewer ran), `run_command_test.exs:772` (cushion unit test, unchanged), `harness_iteration_monitor_test.exs:47` (`timeout: 1_000` + instant crash — cushion-insensitive).

## Files touched

| File | Change |
|---|---|
| `lib/jido_claw/forge/harness.ex` | P1: cushion `run_iteration/2` via existing `exec_call_timeout/1`; comment updates |
| `lib/jido_claw/forge.ex` | P1: cushion-consumers comment now lists three |
| `lib/jido_claw/skills/steps/agent_runner.ex` | P2: `publish_forge_terminal/2` made total (function-level rescue+catch over whereis → new → publish); `require Logger`; comment |
| `lib/jido_claw/agent/templates.ex` | P3: blank-command raise (trim check in body) |
| `test/jido_claw/forge/harness_iteration_monitor_test.exs` | P1 red/green regression test |
| `test/jido_claw/templates_test.exs` | P3 red/green regression test |

## Verification

1. Red-first: run the two new tests against unfixed code; confirm both fail for the expected reason (P1: caller exit; P3: no raise).
2. Targeted: `mix test test/jido_claw/templates_test.exs test/jido_claw/forge/harness_iteration_monitor_test.exs test/jido_claw/skills/steps/forge_executor_test.exs test/jido_claw/skills/steps/agent_runner_test.exs test/jido_claw/eval/composer_forge_fake_case_test.exs test/jido_claw/tools/run_command_test.exs`.
3. Full gate: bare `mix precommit` (never piped) — report exit code + counts verbatim. Known: one unrelated rotating timing flake per full run (MemoryExport / collector / `:pg`) — re-run once, don't chase.
4. Nothing committed; changes stay unstaged with the rest of PR-1.

**Precommit risk register**: credo `--strict` (MaxLineLength 120 on new comment/raise lines); reach `--smells` (both touched lib files already carry file-level `bare_rescue` pragmas — the new function-level rescue in `publish_forge_terminal/2` and the moved logic add no new pragma needs); dialyzer (`exec_call_timeout/1` already returns `timeout()`; no new specs needed); compile_check (no new warnings — allowlist stays empty).
