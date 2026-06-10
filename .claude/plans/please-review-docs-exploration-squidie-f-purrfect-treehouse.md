# Live-Run Workflow Cancellation (+ minimal dashboard asset pipeline)

## Context

The Squidie-borrow / Reactor-adoption effort (docs/exploration/squidie/) is complete through Phase 5 — all inventory items are shipped, skipped-by-design, or explicitly deferred. The docs' own "Next-phase scope (NOT started)" list (REACTOR-ADOPTION.md ~line 140) names three items: the §4.11 lease implementation (**gated on clustering — stays deferred**), the async step-timeline Writer (**deliberately deferred — sync appends are safer at current scale**), and **live-run cancellation — the one unblocked item, chosen by the user as the next increment**.

The gap: a `:running` workflow (LLM loop, stuck tool) cannot be stopped today short of killing the BEAM. Parked runs (`:awaiting_approval`) have `Cases.abandon/3`, but `Reactor.run` executes synchronously in the calling process with no run→pid registry, and Reactor 1.0.2 has no external cancel API (only step-returned halts). For an autonomous agent tool this is the missing operator kill switch.

Planning also surfaced that **the dashboard has no working browser JS**: `root.html.heex` loads `/assets/app.js`, but `priv/static/` doesn't exist and nothing builds `assets/js/app.js` (bare ESM imports need a bundler). Without LiveSocket, every `phx-click` (existing replay/reveal/toggle buttons included) is dead in a real browser — and `data-confirm` needs `phoenix_html.js` besides.

**User decisions:** build live-run cancellation; surface is **dashboard-only** (no CLI, no MCP — matches the replay-overrides-are-dashboard-only precedent); **fold a minimal esbuild asset pipeline into this plan** so the Cancel button (and all existing dashboard controls) actually work in a browser. Greenfield: no compat concerns. Done means `mix precommit` passes.

### Verified mechanics the design relies on

- `run_cancelled` is already a legal transition from `:pending`/`:running`/`:awaiting_approval` (`workflow_event/projection.ex` `next_status/2`) and clears the checkpoint. No projection changes needed.
- **Late-append behavior differs by middleware callback** (`reactor_middleware.ex`): `error/2` logs a failed `run_failed` append and returns `:ok`; but `init/1`'s start path and `complete/2` **propagate** a failed `run_started`/`run_completed` append, making `Reactor.run` itself return `{:error, %Ash.Error.Invalid{}}`. Nothing raises — but a cancelled run can surface as `{:reactor, {:error, …}}`, not only `{:exit, …}` (handled below).
- **Reactor's executor state is `struct!/2`-strict** (`deps/reactor/lib/reactor/executor/state.ex:56`) — unknown option keys raise. `run_id:` is a valid, already-used option; `tenant_id:` must NEVER reach `Reactor.run` (kept as RunExecution-local metadata).
- Reactor async steps are `Task.Supervisor.async_nolink`'d to a global PartitionSupervisor keyed on the executor pid (`deps/reactor/lib/reactor/executor/async.ex:25,66`) — killing the executor **orphans already-started step work, which may continue** (a spawned sub-agent, shell command, or external side effect runs to completion into the void; nothing *new* schedules). Accepted, documented limitation.
- `Task.Supervisor.async_nolink` propagates `$callers`, so Ecto SQL Sandbox shared-mode allowances keep working in tests.
- DBConnection reclaims a killed process's checked-out connection via its ownership monitor — no prod connection leak.
- `deps/phoenix_html/priv/static/phoenix_html.js` ships with the already-present hex package; esbuild with `NODE_PATH=deps` resolves `import "phoenix_html"` (the `data-confirm` interceptor).

## Architecture

**Killable execution**: wrap the `Reactor.run` call in a registered task; caller blocks on `Task.yield(task, :infinity)` so the public API stays synchronous and never-raises. **Durable-decision-first cancel**: append `run_cancelled` (one txn, cases cancelled too), *then* kill the pid — and never kill after a failed durable decision. The caller-side reload is the arbiter between "cancelled" and "crashed" (exit reasons can't distinguish them).

```
Cancellation.cancel(run_id, opts)          WorkflowsLive "cancel" event
  ├─ terminal            → {:error, :already_terminal}
  ├─ :awaiting_approval  → delegate to Cases.abandon/3 (parked; ends :abandoned)
  └─ :pending/:running   → WorkflowLog.terminate_cancelling_cases(run,
                             [{:run_cancelled, %{reason: …}}], reason, …)   # durable first
                             ├─ {:error, _} → reload: terminal? → {:error, :already_terminal}
                             │                (completion race; NO kill, no raw Ash error)
                             │                still non-terminal → {:error, reason}
                             └─ {:ok, _} → kill_if_live (tenant-checked) → broadcast → {:ok, reloaded}
```

## Implementation steps

### 1. Supervision — `lib/jido_claw/application.ex`

In `core_children/0`'s `infra_children`, **after `{Phoenix.PubSub, name: JidoClaw.PubSub}`** (~line 140) — *not* in the Registry cluster before `JidoClaw.Repo`:

```elixir
{Registry, keys: :unique, name: JidoClaw.Orchestration.RunRegistry},
{Task.Supervisor, name: JidoClaw.Orchestration.RunTaskSupervisor},
```

Rationale: supervisor shutdown is reverse start order, and workflow executor tasks are DB-heavy and broadcast via PubSub — starting them after Repo/Vault/PubSub means they are torn down **before** Repo/PubSub during application shutdown. `core_children` boots in every serve mode (MCP included), so the plumbing exists wherever runs can launch.

### 2. New: `lib/jido_claw/orchestration/run_execution.ex`

`RunExecution` — the single killable-execution seam used by **both** execution chokepoints:

- `run_killable(reactor, inputs, context, opts) :: {:reactor, reactor_result} | {:exit, reason} | {:duplicate, pid}` — **`Keyword.pop`s `:tenant_id` out of `opts` first** (RunExecution-local registry metadata; Reactor's executor state is `struct!`-strict and would raise on unknown keys — comment cites `executor/state.ex:56`); the remaining opts (`run_id:`, `async?:`, `timeout:`, `max_iterations:`) pass verbatim to `Reactor.run`. Spawns via `Task.Supervisor.async_nolink(RunTaskSupervisor, …)`. Inside the task, **handle `Registry.register/3` explicitly** (unique key = run-id string, value = tenant_id; Registry auto-cleans on task death):
  - `{:ok, _}` → proceed to `Reactor.run` (registration happens **before** `Reactor.run` so an immediate cancel finds the pid).
  - `{:error, {:already_registered, pid}}` → return the sentinel `{:__registration_conflict__, pid}` **without running the reactor** — never run a second, unkillable executor for a run that already has a live one.
  - `run_killable` maps the sentinel to `{:duplicate, pid}`; everything else from `Task.yield(task, :infinity)` maps to `{:reactor, result}` / `{:exit, reason}`.
- `lookup(run_id) :: {:ok, pid, tenant_id} | :error`.
- Moduledoc documents: the async-orphan limitation (already-started step work may continue); the cancel-before-register race; **the caller-death semantics** (below); and that fresh launches can't realistically collide (fresh run uuid per launch) — the duplicate guard exists for resume races on the *same* run id (operator approve vs boot recovery).

**Caller-death semantics (documented, deliberate):** with `async_nolink`, the executor task survives the death of the process blocked in `Task.yield` — a semantic change from today (where execution died with the caller). Durable terminals still land via the middleware regardless. What a dead caller skips is caller-side finalize bookkeeping: gate-checkpoint persistence (run parks `:awaiting_approval` with no checkpoint → recovery's **dangling-gate** branch reaps at next boot) and the pre-init `:pending` backstop (→ recovery's **stranded** branch). Those are the same recovery classes that covered caller death before this change — and in-flight work now *finishes durably* instead of dying with the caller (a feature for cron). No owner-monitor.

### 3. `lib/jido_claw/orchestration/reactor_runner.ex`

- Rewrite `execute/6`: build opts for `run_killable` (`run_id:`, `tenant_id:`, `async?:`, `timeout: :infinity`, `max_iterations: :infinity` — tenant_id popped inside RunExecution, never reaching Reactor), then `case RunExecution.run_killable(...)`:
  - `{:reactor, result}` → existing `finalize/3` (with the one change below);
  - `{:exit, reason}` → new `handle_exit/3`;
  - `{:duplicate, pid}` → `{:error, {:already_running, pid}, reload(run, opts)}` — **no `ensure_failed`**: the run has a live, healthy executor; terminal-izing it would wrongly fail a running workflow.
  - Keep the existing `try/rescue` around the whole body.
- New private `handle_exit(run, reason, opts)`: reload; if status `== :cancelled` → `{:error, :cancelled, reloaded}` (clean envelope); else crash path → `ensure_failed(reloaded, {:exit, Reason.format(reason)}, opts)` → `{:error, {:exit, …}, reload}`. (If the run reached some *other* terminal in the append/kill gap, `ensure_failed`'s non-terminal guard no-ops — durable status stays the truth.)
- **Cancelled-check in the shared error finalize** (covers the `{:reactor, {:error, …}}`-while-cancelled paths — a cancelled run's late `run_started`/`run_completed` append failure propagates out of `Reactor.run` as `{:error, %Ash.Error.Invalid{}}` via `init`/`complete`): change `finalize({:error, reason}, run, opts)` to reload **first**; if `:cancelled` → `{:error, :cancelled, reloaded}` (skip `ensure_failed`); else the existing `ensure_failed` path. Because `finalize/3` is the shared finalizer, GateResume inherits this for free.
- New public `@doc false finalize_exit/3` delegating to `handle_exit/3` (GateResume seam; the duplicate branch builds its envelope inline — the no-`ensure_failed` rule is the invariant).
- Moduledoc: add a "Killable execution" note (incl. caller-death semantics pointer); add `{:error, :cancelled, run}` and `{:error, {:already_running, pid}, run}` to the documented envelope values.

### 4. `lib/jido_claw/orchestration/gate_resume.ex`

Rewrite `run_reactor/7` identically: `RunExecution.run_killable(...)` → `{:reactor, result}` → `ReactorRunner.finalize/3`; `{:exit, reason}` → `ReactorRunner.finalize_exit/3`; `{:duplicate, pid}` → already-running envelope without `ensure_failed` (this is the realistic duplicate case: operator approve racing boot recovery on the same run id — the loser must leave the winner's `:running` run untouched). Resumed runs become killable for free; `Replay` (→ `ReactorRunner.run`) and `WorkflowRecovery` (→ `GateResume.resume`) inherit the wrapper through these two chokepoints — no changes there. Moduledoc note.

### 5. New: `lib/jido_claw/orchestration/cancellation.ex`

`Cancellation.cancel(run_or_id, opts)` (mirrors the `Replay.replay/2` module-function precedent; opts `:tenant`/`:actor` required → `:missing_required_opt`, optional `:reason`, default `"cancelled by operator"`):

- Load + route on reloaded status: terminal → `{:error, :already_terminal}`; `:awaiting_approval` → look up pending case (`AgentCase.pending_for_run/2`) and delegate to `Cases.abandon(case_id, %{cancellation_reason: reason, …}, …)` — **the parked run ends `:abandoned`, not `:cancelled`** (per `cases.ex` + the projection rule); parked-with-no-case (recovery-class orphan) falls through to the live path; `:pending`/`:running` → `cancel_live/…`.
- `cancel_live`, durable-first with race handling:
  1. `WorkflowLog.terminate_cancelling_cases(run, [{:run_cancelled, %{reason: reason}}], reason, tenant:, actor:)` — the one-transaction terminal + pending-case net (no-op case leg when caseless; covers multi-gate/resumed runs holding a pending case while `:running`).
  2. **On `{:error, _}` from the append: reload; if now terminal → `{:error, :already_terminal}`** (the run completed/failed/was cancelled between the entry load and the append — a clean race result, never the raw `%Ash.Error.Invalid{}`); if still non-terminal → `{:error, reason}` (genuine failure). **Never kill after a failed durable decision.**
  3. On `{:ok, _}`: `kill_if_live(run)` — `RunExecution.lookup(run.id)`; **verify the registry tenant value matches `run.tenant_id`** before `Process.exit(pid, :kill)` (defensive cross-tenant guard; mismatch → log warning, no kill); `:error` → no-op (a stranded `:running` run still cancels durably).
  4. Reload, `RunPubSub.broadcast(run.id, {:run_cancelled, run.id, %{tenant_id:, name:, workflow_type:, status: :cancelled, completed_at:}})` (mirrors the runner's backstop-broadcast shape), return `{:ok, reloaded}`.

### 6. Minimal asset pipeline (makes the dashboard's JS real)

Standard Phoenix esbuild setup, smallest viable slice:

- **`mix.exs`**: add `{:esbuild, "~> 0.10", runtime: Mix.env() == :dev}`; aliases `"assets.build": ["esbuild jido_claw"]` and append `assets.build` to the `setup` alias (the gateway dashboard needs `priv/static/assets/app.js` to exist; no prod deploy target, so no digest/minify alias needed — tailnet tool). No separate `assets.setup` alias: `mix esbuild PROFILE` auto-downloads the binary if missing, and `Esbuild.install_and_run/2` (the watcher) likewise installs on demand.
- **`config/config.exs`**:
  ```elixir
  config :esbuild,
    version: "0.25.0",
    jido_claw: [
      args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets),
      cd: Path.expand("../assets", __DIR__),
      env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
    ]
  ```
- **`config/dev.exs`**: add the endpoint watcher `esbuild: {Esbuild, :install_and_run, [:jido_claw, ~w(--sourcemap=inline --watch)]}` (confirm the dev endpoint config block exists; add `watchers` to it).
- **`assets/js/app.js`**: add `import "phoenix_html";` as the **first** import — ordering matters: both phoenix_html and LiveView install window click listeners, and registering phoenix_html's first lets a cancelled confirm stop LiveView's later `phx-click` handler.
- **`.gitignore`**: add `/priv/static/assets/` (build output; `priv/static/` currently doesn't exist at all). **Release caveat (document in the doc note)**: because the bundle is gitignored and there's no deploy/digest alias, any clean checkout / release build must run `mix assets.build` explicitly (it's in `mix setup`) before the dashboard has JS — acceptable for the tailnet/no-deploy scope.
- Sanity note for implementation: `phoenix` and `phoenix_live_view` JS also resolve via `NODE_PATH=deps` (both hex packages ship their JS), so the existing imports start working too — this is what brings LiveSocket (and every existing `phx-click`) to life in a real browser.

### 7. Dashboard — `lib/jido_claw/web/live/workflows_live.ex`

Mirror the replay handler (line ~108) and `replayable?/1` (~364):

- `handle_event("cancel", %{"id" => run_id}, socket)` → `Cancellation.cancel(run_id, cancel_opts(socket))`; on `{:ok, run}` re-`list_runs` + flash **using the run's actual resulting status** (a parked run reports `:abandoned`, a live one `:cancelled` — e.g. "#{run.name} is now #{run.status}"); on error flash (`:already_terminal` gets a friendly message). `cancel_opts/1` mirrors `replay_opts` (actor/tenant from `current_actor`, `[]` fallback → `:missing_required_opt`).
- Cancel button in the actions cell for `cancellable?(run.status)` (`status in [:pending, :running, :awaiting_approval]` — the inverse of `replayable?`), `id={"cancel-#{run.id}"}`, with `data-confirm="Cancel this run? Already-started step work may not stop immediately."` (functional once step 6 lands phoenix_html).
- **No PubSub subscription in this slice** — WorkflowsLive refreshes synchronously today (replay does the same); the broadcast exists for a future live-update follow-up.

### 8. Comment/doc touch-ups in code

- `cases.ex:47-49`: replace "Widening to in-flight runs is future work gated on lease/cancellation" with a pointer to `Cancellation` (which delegates parked runs to abandon).

## Caller-side result handling (the table)

| `run_killable` result | Reloaded status | Action | Envelope |
|---|---|---|---|
| `{:reactor, {:ok, …}}` / `{:ok, …, _}` | — | existing `finalize` | `{:ok, value, run}` |
| `{:reactor, {:error, r}}` | `:cancelled` | **reload-first in `finalize({:error,…})`** — skip `ensure_failed` | **`{:error, :cancelled, run}`** |
| `{:reactor, {:error, r}}` | other | existing `finalize` → `ensure_failed` | `{:error, r, run}` |
| `{:reactor, {:halted, reactor}}` | — | existing gate-pause finalize | `{:ok, {:paused, id}, run}` |
| `{:exit, _}` | `:cancelled` | `handle_exit` clean return | **`{:error, :cancelled, run}`** |
| `{:exit, r}` | non-terminal | crash → `ensure_failed` | `{:error, {:exit, …}, run}` |
| `{:exit, r}` | other terminal (race) | `ensure_failed` no-ops | `{:error, {:exit, …}, run}` |
| `{:duplicate, pid}` | (any) | **no `ensure_failed`** — live executor exists | `{:error, {:already_running, pid}, run}` |

Downstream consumers verified — no changes needed: `RunSkill` maps to `{:error, :cancelled}`; cron `WorkflowRunner` likewise; `Replay.launch` already treats `{:error, _, %WorkflowRun{}}` as `{:ok, run}`; `Cases.decide` approve returns `{:error, :cancelled}` if its resume is cancelled.

## Edge cases (documented in moduledocs)

- **Append-then-kill window**: a run completing in the gap stays `:cancelled` (first terminal wins under the per-run `FOR UPDATE` lock); the late `run_completed` append propagates `{:error, …}` out of `Reactor.run` via `complete/2` — mapped to the clean `{:error, :cancelled, run}` by the reload-first error finalize.
- **Cancel-vs-completion race in `cancel_live`**: the durable append fails as an illegal transition → reload → `{:error, :already_terminal}`; no kill, no raw Ash error.
- **Cancel-before-register race**: durable `run_cancelled` lands first → the late task's `init/1` `run_started` append is illegal → `Reactor.run` returns `{:error, …}` before any step runs → reload-first finalize maps it to `{:error, :cancelled, run}`. The decision wins against registration timing.
- **Duplicate executor (resume race)**: registration conflict returns `{:duplicate, pid}`; the loser reports `{:already_running, pid}` and must not touch the run's status.
- **Caller death**: executor outlives a dead caller (async_nolink); durable terminals land via middleware; skipped caller-side bookkeeping (gate checkpoint, pre-init backstop) is reaped by recovery's dangling-gate/stranded branches at next boot — the same classes that covered caller death before this change.
- **Orphaned async step work**: already-started `async_nolink` step tasks may continue to completion (spawned sub-agents, shell commands, external side effects included) — bounded to in-flight work; nothing new schedules. Killing the executor is a kill switch for the *workflow*, not a guaranteed interrupt of every side effect.
- **Recovery**: cancel reaches a terminal; `WorkflowRecovery` only scans non-terminal runs — no fight.

## Tests

Fixture: `test/support/jido_claw/reactors/blocking_test_reactor.ex` (next to `gated_test_reactor.ex`) — named `BlockStep` module sends `{:blocking_step_started, self(), context.workflow_run.id}` to `context[:test_pid]` (seeded via the runner's `:context` opt; base-wins merge preserves it), then `Process.sleep(:infinity)` — a **pure sleep, no DB query in flight**, so the kill never poisons the sandbox owner connection. Runs `async?: false` so the step executes in the killable task process itself.

New `test/jido_claw/orchestration/cancellation_test.exs` (**`async: false`** — singleton Registry/TaskSupervisor + shared sandbox; per the suite's flaky-test conventions). **Cleanup is narrow-first**: a launch helper tracks the launcher `Task` and (after `assert_receive`) the executor pid via `RunExecution.lookup(run_id)`; `on_exit` does `Task.shutdown(launcher, :brutal_kill)` and `Process.exit(executor, :kill)` for exactly the tracked pids. A file-level `on_exit` sweep of `Task.Supervisor.children(JidoClaw.Orchestration.RunTaskSupervisor)` remains only as the last-resort backstop for assertion-failed-before-tracking cases, with a comment calling out that this file is `async: false` singleton-isolated (the sweep would be unsafe otherwise).

1. **Cancel a running run**: launch via `Task.async(fn -> ReactorRunner.run(BlockingTestReactor, …) end)`, `assert_receive {:blocking_step_started, _, run_id}` (deterministic — no timer sleeps), cancel → `{:ok, %{status: :cancelled}}`; `run_cancelled` in event kinds; launcher task returns `{:error, :cancelled, run}`; `RunExecution.lookup(run_id) == :error` after death.
2. **Parked run delegates to abandon**: reach `:awaiting_approval` via the `gate_lifecycle_test.exs` helper pattern; cancel → **run `:abandoned`** (not `:cancelled`), case `:abandoned`, downstream step never ran.
3. **Terminal run refused**: `{:error, :already_terminal}`, no new event. Include the double-cancel variant (cancel an already-cancelled run).
4. **Stranded `:running`, no live pid**: force status via the `set_status`/`authorize?: false` test helper; cancel still lands durably; `kill_if_live` no-ops.
5. **Late append after cancel**: direct `WorkflowLog.append(run, :run_completed, …)` on a cancelled run → `{:error, %Ash.Error.Invalid{}}`, status stays `:cancelled`, nothing raises.
6. **Registration conflict**: register the would-be run id key in `RunRegistry` from the test process, call `RunExecution.run_killable/4` directly → `{:duplicate, pid}` and the reactor never ran; caller-level assertion that the run's status is untouched (no `run_failed` appended).
7. **Recovery interplay** (in `workflow_recovery_test.exs`): cancelled run untouched by `reconcile_all`.

New `test/jido_claw/web/live/workflows_live_test.exs` (none exists; follow `approvals_live_test.exs`'s direct-socket convention): `handle_event("cancel", …)` on a forced-`:running` run cancels + flashes the resulting status; render shows the Cancel button (with the `data-confirm` attribute) for non-terminal rows and not for terminal ones.

## Doc updates

- **`docs/exploration/squidie/REACTOR-ADOPTION.md`**: remove live-run cancellation from the "Next-phase scope (NOT started)" list (~line 141); split it out of the §4.11 deferral note (~line 23 — kill-based single-node cancellation shipped; multi-node lease/reclaim still deferred); add a shipped note to the status-reconciliation banner (RunRegistry/RunTaskSupervisor wrapper, `Cancellation.cancel/2` routing incl. abandon delegation + race handling, durable-first ordering, the already-started-work-may-continue orphan limitation, caller-death semantics, dashboard-only surface).
- **`docs/exploration/squidie/FEATURES-WORTH-BORROWING.md`**: annotate the T2-4 row's cancellation mention the same way (grep `cancel` for the exact lines).

## Verification

1. `mix test test/jido_claw/orchestration/cancellation_test.exs test/jido_claw/web/live/workflows_live_test.exs test/jido_claw/orchestration/workflow_recovery_test.exs test/jido_claw/orchestration/reactor_runner_test.exs test/jido_claw/orchestration/gate_lifecycle_test.exs` — new + adjacent suites (via `mise exec -- mix …`).
2. **Asset pipeline**: `mix assets.build` produces `priv/static/assets/app.js` containing the bundled phoenix_html confirm interceptor (grep for `data-confirm` in the bundle); boot the gateway and confirm in a browser (or via claude-in-chrome) that LiveSocket connects and the Cancel button shows the confirm dialog + cancels a run.
3. Manual smoke via Tidewave `project_eval` if useful: launch a `BlockingTestReactor`-style run, `Cancellation.cancel/2`, inspect `WorkflowEvent` rows.
4. **`mix precommit` must pass** (the completion gate): format, `jidoclaw.compile_check`, credo --strict, reach smells, ExSlop, dialyzer, full suite. Run it **bare in background and read the output tail — never piped** (pipe masks the exit code). Watch: no new `rescue` in the new modules (use `Task.yield` + explicit register handling, not rescue — no `bare_rescue` pragmas needed); don't start comment lines with the word "step" (ExSlop EXS3004); flaky async:false singletons (MCPServer/Prompt/PipelineStore/MultiSandbox) — verify in isolation before blaming the change.

## Explicitly out of scope (deferred by design — do not build)

§4.11 lease/Pooler implementation (gated on clustering), async step-timeline Writer, `tool_call`/`plan` gate producers + retraction trigger, WorkflowsLive PubSub live-updates (broadcast already fires; clean follow-up), CLI/MCP cancel surfaces (user chose dashboard-only), prod asset digesting/minification (no deploy target — tailnet tool).
