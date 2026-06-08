# ReactorRunner — resolve the two P2 review findings (auto-wire middleware + fully protect the never-raises contract)

## Context

The Reactor Phase 1 slice (plan `please-review-docs-exploration-squidie-f-lexical-key.md`)
landed `ReactorMiddleware`, `ProjectRegistration`, and `ReactorRunner` as the invocation seam.
A code review raised two **P2** findings against `lib/jido_claw/orchestration/reactor_runner.ex`,
both about `run/3` as a **reusable public seam** (its moduledoc advertises it that way, and it is
the generic entry point for *all* future reactor workflows — today only `ProjectRegistration`
exists and the only caller is its test, so both findings are latent, not yet-firing, bugs).

**Both findings are validated (read directly):**

1. **No middleware → silent `:pending`-on-success strand.** `finalize/3`
   (`reactor_runner.ex:129-142`) has a backstop only on the *failure* path (`ensure_failed`);
   the success clause just reloads. A reactor run through the seam **without**
   `ReactorMiddleware` would return `{:ok, value, run}` with the run stuck at `:pending`,
   because no `run_started`/`run_completed` event is ever appended. `ProjectRegistration` does
   declare the middleware, so this is a latent footgun for the next reactor author.

2. **Pre-run path escapes the never-raises contract.** The sibling `WorkflowRunner.run/1`
   wraps its *entire* body in `try/rescue` (`workflow_runner.ex:77-78`) plus a defensive
   fallback clause (`:84`). `ReactorRunner.run/3` only rescues inside `execute/5` —
   `Keyword.get`/`Keyword.fetch`/`WorkflowRun.create` sit **outside** it (`reactor_runner.ex:72-93`),
   so a non-keyword `opts` or a data-layer exception during run creation raises to the caller,
   breaking the documented "never raises" contract.

**Chosen direction (user, 2026-06-08):** Finding 1 → **auto-wire (inject)**. The runner becomes
the envelope authority: it injects `ReactorMiddleware` if the reactor doesn't already declare it.
Finding 2 → wrap the pre-run path (mirror `WorkflowRunner`).

**Done means `mix precommit` passes** — `jidoclaw.compile_check`, `jidoclaw.system_prompt.check`,
`deps.unlock --unused`, `format`, `reach.check --arch --smells --strict`, `credo --strict`,
`dialyzer --format short`, `test` (`mix.exs:240-251`).

## Verified mechanics (read directly)

- `Reactor.run/4` has **no** `middleware` run-option (`@run_schema`, `deps/reactor/lib/reactor.ex`):
  `max_concurrency`, `timeout`, `max_iterations`, `async?`, `concurrency_key`, `run_id`,
  `fully_reversible?`. Auto-wiring therefore means **augmenting the reactor struct**, not passing
  an option.
- `Reactor.Builder.add_middleware/2` (`deps/reactor/lib/reactor/builder.ex:295-310`) returns
  `{:ok, reactor}` or `{:error, _}`; `assert_unique_middleware` (`:341-343`) would itself error
  on a duplicate. We **don't** rely on that error for dedup — instead the helper checks
  `ReactorMiddleware in base.middleware` first and only calls `add_middleware/2` when absent, so a
  reactor that already declares the middleware (`ProjectRegistration`) runs unchanged
  (**single emission, no double-wiring**) and any *unexpected* `add_middleware/2` failure is
  propagated, not swallowed.
- `Reactor.run(module, …)` already resolves a module via `Spark.Dsl.is?(module, Reactor)` then
  runs `module.reactor()` (`deps/reactor/lib/reactor.ex:212-216`). So `reactor_module.reactor()`
  returns a runnable `:pending` `%Reactor{}` struct, and `Reactor.run/4` accepts a struct
  identically to a module — injecting and running the augmented struct is exactly what the
  module path does internally, plus our middleware.
- The file already carries `# reach:disable-for-this-file bare_rescue` (`reactor_runner.ex:48`),
  so a second body-level rescue adds **no new smell**.

## Implementation

All substantive change is in **`lib/jido_claw/orchestration/reactor_runner.ex`**.

### 1. Auto-wire the middleware (Finding 1)

Add two aliases (`alias JidoClaw.Orchestration.ReactorMiddleware`, `alias Reactor.Builder`) and a
non-raising `build_runnable/1` helper that resolves the module to a struct and injects the
middleware dedup-safely:

```elixir
# Finding 1: the runner is the envelope authority — it guarantees
# ReactorMiddleware is wired, so a successful run can never strand the
# WorkflowRun in :pending. Dedup via an *explicit membership check* (not by
# swallowing an add_middleware/2 error): a reactor that already declares the
# middleware (e.g. ProjectRegistration) runs its original struct, while a
# genuine add_middleware/2 failure surfaces as a pre-run {:error, reason, nil}
# rather than silently running an un-augmented, strand-prone reactor.
defp build_runnable(reactor_module) do
  if Spark.Dsl.is?(reactor_module, Reactor) do
    base = reactor_module.reactor()

    if ReactorMiddleware in base.middleware do
      {:ok, base}
    else
      Builder.add_middleware(base, ReactorMiddleware)
    end
  else
    {:error, :not_a_reactor}
  end
end
```

`@spec build_runnable(module()) :: {:ok, Reactor.t()} | {:error, term()}`
(`:not_a_reactor` plus any `add_middleware/2` error). The `%Reactor{}` struct's `middleware`
field is a flat list of middleware modules (`deps/reactor/lib/reactor.ex:49,140`), so the `in`
membership test is exact. `ProjectRegistration` keeps its `middlewares do … end` block unchanged
(it documents intent locally and the membership check makes it a no-op; it costs nothing).

### 2. Fully protect the never-raises contract + thread the runnable (Finding 2)

Restructure `run/3` so the pre-run path is inside a body-level `try/rescue` (mirroring
`WorkflowRunner.run/1`) and so the resolved struct flows into `execute`:

```elixir
@spec run(module(), map(), keyword()) :: run_result()
def run(reactor_module, inputs, opts) do
  name = Keyword.get(opts, :name, inspect(reactor_module))

  with {:ok, runnable} <- build_runnable(reactor_module),
       {:ok, tenant} <- Keyword.fetch(opts, :tenant),
       {:ok, actor} <- Keyword.fetch(opts, :actor),
       {:ok, run} <-
         WorkflowRun.create(
           %{name: name, workflow_type: "reactor", config: %{reactor: inspect(reactor_module)}},
           tenant: tenant,
           actor: actor
         ) do
    execute(run, runnable, reactor_module, inputs, tenant, actor)
  else
    {:error, :not_a_reactor} -> {:error, {:not_a_reactor, reactor_module}, nil}
    :error -> {:error, :missing_required_opt, nil}
    {:error, reason} -> {:error, reason, nil}
  end
rescue
  # Finding 2: a raise in the pre-run path (non-keyword opts -> Keyword.get/
  # fetch raises; or a data-layer exception escaping WorkflowRun.create) is
  # normalized to the pre-run envelope — no usable run exists yet, so the run
  # slot is nil. Raises *inside* execute/6 are caught by its own rescue, which
  # carries the in-memory run.
  error -> {:error, {:exception, Exception.message(error)}, nil}
end
```

`execute/5` becomes `execute/6` — it takes the resolved `runnable` struct and pipes **that**
(not the module) into `Reactor.run/4`; everything else (context map, `finalize/3`,
`ensure_failed/3`, its inner `try/rescue`) is unchanged:

```elixir
defp execute(run, runnable, reactor_module, inputs, tenant, actor) do
  context = %{tenant: tenant, actor: actor, workflow_run: run, reactor: inspect(reactor_module)}
  finalize_opts = [tenant: tenant, actor: actor]

  try do
    runnable
    |> Reactor.run(inputs, context,
      run_id: run.id, async?: false, timeout: :infinity, max_iterations: :infinity)
    |> finalize(run, finalize_opts)
  rescue
    error ->
      reason = {:exception, Exception.message(error)}
      ensure_failed(run, reason, finalize_opts)
      {:error, reason, run}
  end
end
```

**No guard clause / fallback `def run(_, _, _)`** (unlike `WorkflowRunner`): with the precise
`@spec run(module(), map(), keyword())`, a guarded first clause would make the fallback
unreachable per the spec domain and trip a dialyzer "clause cannot match". The body-level rescue
gives the same never-raises guarantee for malformed opts without the dialyzer risk.

The existing `@type run_result :: {:ok, term(), WorkflowRun.t()} | {:error, term(), WorkflowRun.t() | nil}`
already covers the new `{:error, {:not_a_reactor, _}, nil}` and `{:error, {:exception, _}, nil}`
shapes — no type change.

### 3. Doc touch-ups

- `reactor_runner.ex` moduledoc: add a one-line "Middleware auto-wiring" note (the seam injects
  `ReactorMiddleware` dedup-safely, so a successful run can't strand `:pending`); extend the
  "Never raises" section to say the pre-run path is now rescued too, and that pre-run failures
  include `{:not_a_reactor, mod}` and malformed opts. Update the `execute/5` reference to `execute/6`.
- `lib/jido_claw/orchestration/reactor_middleware.ex` moduledoc (`:9-12`): soften "wires this
  middleware in via the reactor's `middlewares` block" → the runner **injects** it (dedup-safe),
  so a reactor *may* declare it but need not.

### Not changing

`ProjectRegistration` (keeps its declaration), `ReactorMiddleware` logic, `Reason`, and every
Phase 0 module. No new module → no reach `--arch` rule needed.

## Tests

### New: `test/jido_claw/orchestration/reactor_runner_test.exs` (`use JidoClaw.TenantCase`, `async: false`)

Define two test-support modules at the top of the file (mirroring `reactor_middleware_test.exs`'s
`OkStep`):

```elixir
defmodule JidoClaw.Orchestration.ReactorRunnerTest.OkStep do
  @moduledoc false
  use Reactor.Step
  @impl true
  def run(_args, _context, _opts), do: {:ok, :done}
end

defmodule JidoClaw.Orchestration.ReactorRunnerTest.NoMiddlewareReactor do
  @moduledoc false
  use Reactor
  step(:only, JidoClaw.Orchestration.ReactorRunnerTest.OkStep)
  return(:only)
end
```

Cases:

- **Auto-wire (Finding 1 keystone).** Run `NoMiddlewareReactor` (declares **no** middleware) via
  `ReactorRunner.run/3` with a seeded `tenant`/`actor`. Assert `{:ok, :done, run}`,
  `run.status == :completed`, and the `WorkflowEvent.for_run` kind sequence is
  `[:run_started, :step_started, :step_completed, :run_completed]` — proving the runner injected
  the middleware for a reactor that never declared it.
- **Per-run augmentation isolation.** Run `NoMiddlewareReactor` **twice** in two separate
  `ReactorRunner.run/3` calls (distinct runs). Assert each run's events contain exactly one
  `:run_started` and one `:run_completed`. Proves the struct augmentation is per-call and never
  mutates shared DSL state / accumulates middleware across runs (Elixir immutability guarantees
  it, since `reactor_module.reactor()` returns the original struct each call and
  `add_middleware/2` copies — this pins it empirically).
- **No double emission (dedup).** Run `ProjectRegistration` (already declares the middleware) via
  the runner; assert exactly one `:run_started` and one `:run_completed` event — proving the
  dedup branch (`{:error, _already_present} -> base`) prevents double-wiring. *(Equivalently, add
  `assert Enum.count(kinds, &(&1 == :run_started)) == 1` to the existing happy-path test in
  `project_registration_test.exs`; see below.)*
- **Not-a-reactor → pre-run envelope (Finding 2 + the `build_runnable` guard).** Call
  `ReactorRunner.run(Enum, %{}, tenant: t, actor: a)` (any non-reactor module). Assert
  `{:error, {:not_a_reactor, Enum}, nil}` — no run created, no raise.
- **Malformed opts → never raises (Finding 2).** Call
  `ReactorRunner.run(ProjectRegistration, valid_inputs, %{tenant: t, actor: a})` (a **map**, not a
  keyword list). Assert it returns `{:error, _reason, nil}` (the body-level rescue normalizes the
  `Keyword.get` raise) — the match itself proves no exception escaped.

*(The "WorkflowRun.create raises a data-layer exception" branch is covered structurally by the
body-level rescue but is intentionally not unit-tested — forcing a deterministic Postgrex/Ash
raise needs a mock; the rescue is the contract net and boot recovery does not apply since no run
is created. Noted as a decision, not an omission.)*

### Edit: `test/jido_claw/orchestration/reactors/project_registration_test.exs`

In the happy-path test, after computing `kinds`, add the dedup assertion (one line):
`assert Enum.count(kinds, &(&1 == :run_started)) == 1`. Everything else is unchanged; the
keystone failure / missing-input / missing-opt tests already pass and stay green.

## Verification (end-to-end)

Toolchain runs `mix` via `mise exec -- mix` (OTP 29 / Elixir 1.20).

1. `mise exec -- mix compile --warnings-as-errors` — clean (no new modules/resources).
2. `mise exec -- mix test test/jido_claw/orchestration/` — the new `reactor_runner_test.exs` plus
   the unchanged `project_registration_test.exs`, `reactor_middleware_test.exs`,
   `reactor_undo_authz_test.exs`, and the Phase 0 suite all pass.
3. **Tidewave** (`project_eval` + `execute_sql_query`): run the no-middleware reactor through the
   seam and confirm injection produced the timeline —
   `select seq, kind from workflow_events where workflow_run_id = '<id>' order by seq` shows
   `run_started → step_started → step_completed → run_completed` and the run's `status` is
   `completed`. Re-run `ProjectRegistration` and confirm exactly one `run_started` row (no
   double emission).
4. **`mise exec -- mix precommit` passes** — the bar for done. Watch especially
   `reach.check --smells --strict` (zero today; the new `case`/error tuples add no
   `fixed_shape_map` surface and the rescue is covered by the existing file pragma) and
   `dialyzer --format short` (the single-clause `run/3` + `Reactor.t()` spec on `build_runnable/1`
   avoid the fallback-clause warning discussed above).
