# Reactor Phase 1 — First Ash.Reactor workflow + event-producing middleware (core slice)

## Context

`docs/exploration/squidie/FEATURES-WORTH-BORROWING.md` and its two companions
(`T1-1-WORKFLOW-EVENT-LOG-PLAN.md`, `REACTOR-ADOPTION.md`) settle on a direction:
**Reactor is the workflow execution engine; the Squidie-borrowed event log is the durable
envelope around it.** They stack, they don't compete.

**Phase 0 is already done and committed** (`f825097`, "Workflow Event Log — Phase 0"):
the append-only `WorkflowEvent` resource, the `Projection` (status-authority + transition
guard), the `Allocate` change (sole `seq` allocator + redactor + in-transaction status
writer), the `WorkflowLog` append seam, the boot-time `WorkflowRecovery` reconciler, and the
redaction widening. `WorkflowRun.status` is now a pure projection of the event log, written
only by the append path. But **nothing runs through Reactor yet** — the only producer is the
cron-driven `WorkflowRunner`, which still dispatches to the bespoke skill-DAG drivers.

This plan implements **Reactor-doc Phase 1: "First Reactor workflow end-to-end"** — the
keystone that makes Reactor a real engine in this codebase and proves the
middleware-as-event-producer pattern that every later phase (human gates, skills→Reactor,
replay) builds on. The intended outcome: one developer-authored `Ash.Reactor` runs under a
new `Reactor.Middleware` that emits the full `run_started → step_* → terminal` timeline into
the existing event log, with **compensation/undo visible in the log** when a step fails.

**Scope was chosen with the user (2026-06-08):**
- **Core slice** — middleware (synchronous appends) + one Ash.Reactor + a `run/3` invocation
  seam + tests, run `async?: false`. The async step-`Writer` GenServer and the `WorkflowStep`
  projection are **deferred** as named follow-ups (see "Out of scope").
- **First workflow** — a **Project + Workspace registration saga**: register a `Project`,
  then a tenant-scoped `Workspace` linked to it, both steps declaring durable `undo`. A forced
  failure on the workspace step rolls the project row back via Reactor's saga undo.

**Greenfield**: no compat/migration concern. **Zero new dependencies** — `reactor 1.0.2` is
already a non-optional dep of `ash 3.27.7`; `Ash.Reactor` is its extension.

**Done means `mix precommit` passes** — `jidoclaw.compile_check`,
`jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format`,
`reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`, `test`
(`mix.exs:245-254`).

## Scope

**In:**
1. `JidoClaw.Orchestration.ReactorMiddleware` — a `Reactor.Middleware` that is the sole event
   producer for reactor-driven runs. `init/1`/`complete/2`/`error/2` append run-lifecycle
   events synchronously via `WorkflowLog.append`; `event/3` appends the per-step timeline
   (synchronously in this slice — see rationale).
2. `JidoClaw.Orchestration.Reactors.ProjectRegistration` — the first `Ash.Reactor`: create a
   `Project`, then register a `Workspace` FK-linked to it, both with declarable durable `undo`
   (via small additive `:reactor_undo` destroy actions on `Project`/`Workspace` — §4; the only
   edits outside the `Orchestration` subsystem).
3. `JidoClaw.Orchestration.ReactorRunner` — the `run/3` invocation seam: creates the
   `WorkflowRun` (genesis `:pending`), calls `Reactor.run/4` with `run_id = run.id` and a
   context map carrying `tenant`/`actor`/`workflow_run`/`reactor`, then a `finalize/3` that
   guarantees terminal durability. A never-raises seam returning a run-carrying envelope
   (`{:ok, value, run}` / `{:error, reason, run | nil}` — `nil` only for pre-run failures).
4. Tests proving (a) a successful run yields the full event timeline + `status: :completed`,
   and (b) a forced mid-run failure yields `step_failed` + `step_undone` + `run_failed`, with
   the project row actually rolled back.

**Out of scope (deferred, named so they read as decisions):**
- **Async step-timeline `Writer` GenServer** (per-run FIFO + the synchronous flush "barrier" +
  back-pressure). Only matters under high-concurrency *async* step writes; this slice runs
  `async?: false` (deterministic, test-friendly), where synchronous `event/3` appends are
  correct and the per-run `FOR UPDATE` lock in `Allocate` already serializes `seq`. Build the
  Writer when a concurrent producer exists (the skills→Reactor compiler, Phase 3), per
  REACTOR-ADOPTION §4.3.
- **`WorkflowStep` projection** (T1-1 Phase 2 — populate the dashboard's per-step view from
  `step_*` events) and the `WorkflowStep` tenant-scoping migration.
- **`halt/1` + human gates** (Reactor-doc Phase 2). This slice forbids halts (`max_iterations:
  :infinity`, `timeout: :infinity`, no `{:halt}` steps); `halt/1` / `run_halted` / `run_resumed`
  land with gates, where they're exercised and tested.
- Skills→Reactor compiler + retiring `WorkflowRunner`/skill drivers (Phase 3); replay +
  fingerprint (Phase 4); read-models — deadlines, actor-visibility, cron idempotency (Phase 5);
  multi-node lease/fencing (§4.11).

## Verified baseline (read directly)

- **Reactor 1.0.2 `Reactor.Middleware`** (`deps/reactor/lib/reactor/middleware.ex`): all
  callbacks optional. `init(context) :: {:ok, context} | {:error, any}`;
  `complete(result, context) :: {:ok, result} | {:error, any}`;
  `error(error_or_errors, context) :: :ok | {:error, any}`;
  `halt(context) :: {:ok, context} | ...`;
  `event(step_event, %Reactor.Step{}, context) :: :ok` — **and its docstring (`:113-118`)
  states it BLOCKS the reactor** (the sync/async split rationale). `step_event` vocabulary
  (`:26-48`) includes `{:run_start, args}`, `{:run_complete, result}`, `{:run_error, errors}`,
  `{:run_retry, _}`, `:compensate_complete`, `:undo_complete`.
- **`Reactor.run/4`** (`deps/reactor/lib/reactor.ex:210-235`): `(reactor, inputs, context,
  options)`. `options[:run_id]` is `type: :any` and is lifted into `context.run_id` by
  `Executor.Init` (`init.ex:37`, `Map.put_new`). Context is **deep-merged and NOT validated**
  (only declared *inputs* are validated/filtered, `init.ex:53`) — so `tenant`/`actor`/
  `workflow_run` ride safely in context.
- **`Ash.Reactor.CreateStep`** reads `context[:actor]` + `context[:tenant]` in both `run/3`
  (`deps/ash/lib/ash/reactor/steps/create_step.ex:20-21`) and `undo/4` (`:71-72`). One context
  map (`%{tenant: ..., actor: ..., workflow_run: ...}`) therefore serves both the Ash steps and
  our middleware.
- **`Project`** (`lib/jido_claw/projects/project.ex`): plain `use Ash.Resource`, `policy
  always()` (NOT tenant-scoped). `create` accepts `[:name, :github_full_name, :default_branch,
  :settings]` (`name`/`github_full_name` required, `github_full_name` min_length 3); `destroy`
  exists; identity `unique_github_full_name`; code interface `create`/`read`/`destroy`/
  `get_by_github_full_name`.
- **`Workspace`** (`lib/jido_claw/workspaces/resources/workspace.ex`): `use JidoClaw.Resource`
  (tenant-scoped). `register` (primary create) accepts `[:name, :path, :user_id, :project_id,
  ...]` (`name`/`path` required); `belongs_to :project`; `destroy` via `defaults([:read,
  :destroy])`.
- **`WorkflowRun.create`** (`workflow_run.ex:35-40`): accepts `[:name, :workflow_type, :config,
  :retry_of_id, :user_id, :project_id, :metadata]`, forces `status: :pending`.
- **`WorkflowLog.append/4`** (`workflow_log.ex:23-32`): `(run, kind, payload, opts)`,
  `opts` = `tenant:`/`actor:`/`metadata:`; defaults tenant→`run.tenant_id`,
  actor→`Actor.system(run.tenant_id)`. Payload/metadata are redacted inside `Allocate` via
  `Transcript.redact`.
- **`Actor.system/1`** (`authorization/actor.ex:32-35`): `%{kind: :system, user_id: nil,
  tenant_id: t}`.
- **`TenantCase`** (`test/support/jido_claw/tenant_case.ex`): `seed_tenant/1`,
  `actor_for/1` (`%{user_id: t, tenant_id: t}`), shared sandbox by default (so an
  `async?: false` reactor running in the test process sees seeded rows and its own writes).
- **reach** arch layers constrain only `web`/`data`; `Orchestration.*` is unconstrained, so
  module placement under `Orchestration` is free. The live gate is `smells --strict` at zero
  (`.reach.exs`). New modules live under `JidoClaw.Orchestration.*` for consistency with the
  Phase 0 modules and to stay inside the unconstrained namespace.

## Implementation

All new modules under `JidoClaw.Orchestration.*` (consistent with `WorkflowEvent`,
`WorkflowLog`, `WorkflowRecovery`).

### 1. `JidoClaw.Orchestration.ReactorMiddleware` — `lib/jido_claw/orchestration/reactor_middleware.ex` (new)

`use Reactor.Middleware`. The sole event producer. Reads identity from the run context the
seam sets: `%{tenant: tenant_id, actor: actor, workflow_run: %WorkflowRun{} = run}`.

Callbacks (all synchronous in this slice):

- **`init/1`** — append `:run_started` with a minimal JSON-safe payload (`%{reactor:
  context[:reactor]}`, set explicitly by the runner — see P3 below; full definition
  fingerprint is Phase 4). Return `{:ok, context}`. On a missing/garbled context shape, return
  `{:error, reason}` so a misconfigured caller fails loudly (no silent event drops). *(Phase 1
  is single-start only; the `:halted`/`run_resumed` branch — guarded on
  `context.__reactor__.initial_state` — lands with gates.)*
- **`complete/2`** — append `:run_completed` (payload `%{}` in this slice — see "Payloads must
  be JSON-safe" below), return `{:ok, result}`; on append error return `{:error, reason}`.
- **`error/2`** — append `:run_failed` with `%{error: format_reason(errors)}` (a string;
  `Projection.status_attrs(:run_failed, …)` writes it to the `WorkflowRun.error` string
  column). Best-effort: return `:ok` (lets other middleware see the same reason), logging on
  append failure. **`run_failed` is status-authority, so terminal durability cannot rest on
  this callback alone** — the runner's `finalize` backstop (§3 `ReactorRunner`) guarantees a
  terminal event for any non-terminal run after `Reactor.run` returns; boot recovery is the
  final net.
- **`event/3`** — map and append the per-step timeline, returning `:ok` always (best-effort;
  log on append error, never block the reactor):
  - `{:run_start, _}` → `:step_started` `%{step: inspect(step.name)}`
  - `{:run_complete, _}` → `:step_completed` `%{step: inspect(step.name)}`
  - `{:run_error, errs}` → `:step_failed` `%{step: inspect(step.name), error: format_reason(errs)}`
  - `{:run_retry, _}` / `:run_retry` → `:step_retried` `%{step: inspect(step.name)}`
  - `:compensate_complete` / `{:compensate_continue, _}` → `:step_compensated`
  - `:undo_complete` → `:step_undone` `%{step: inspect(step.name)}`
  - any other event → `:ok` (ignore; e.g. `{:run_halt, _}`, `:undo_start`, guard events)
- **No `halt/1`** in this slice (optional callback; deferred to the gate phase).

Helper: `append/4` thin wrapper → `WorkflowLog.append(run, kind, payload, tenant:
run.tenant_id, actor: context_actor || Actor.system(run.tenant_id))`. `format_reason/1`
mirrors `WorkflowRunner.format_reason/1` (normalizes exception/list/term → string).

**Payloads must be JSON-safe.** The `WorkflowEvent.payload` column is jsonb and the
status-authority projection copies `run_completed`'s `payload[:result]` into the
`WorkflowRun.result` map column. Ash record structs are not cleanly JSON-encodable, so this
slice stores only identifiers and formatted error strings — **not** raw step/run results.
Structured result capture (with a JSON-safe serializer + the existing redaction) is a
follow-up; it is not needed to prove the timeline or undo.

### 2. `JidoClaw.Orchestration.Reactors.ProjectRegistration` — `lib/jido_claw/orchestration/reactors/project_registration.ex` (new)

`use Ash.Reactor`. Wire the middleware in the `middlewares do middleware
JidoClaw.Orchestration.ReactorMiddleware end` block.

```
input :github_full_name
input :project_name
input :workspace_name
input :workspace_path

create :register_project, JidoClaw.Projects.Project, :create do
  inputs %{name: input(:project_name), github_full_name: input(:github_full_name)}
  undo_action :reactor_undo
  undo :always
end

create :register_workspace, JidoClaw.Workspaces.Workspace, :register do
  inputs %{
    name: input(:workspace_name),
    path: input(:workspace_path),
    project_id: result(:register_project, [:id])
  }
  undo_action :reactor_undo
  undo :always
end

return :register_workspace
```

`tenant`/`actor` are inherited from `Reactor.run/4`'s context (verified — `CreateStep`
reads `context[:actor]`/`context[:tenant]`), and the per-step **domain is inferred** from each
resource's declared `domain:` via `Ash.Resource.Info.domain/1` (confirmed), so cross-domain
create steps need no per-step plumbing.

**Undo actions (P1 blocker — verified against installed Ash 3.27.7).** `undo_action` for an
`Ash.Reactor` create step must be a destroy/update action that takes **exactly one argument
named `:changeset`** — the builder verifier rejects anything else
(`deps/ash/lib/ash/reactor/builders/create.ex:115-125`), and the undo path calls
`Changeset.for_destroy(undo_action, %{changeset: stored}, …)` (`.../steps/create_step.ex:90`).
The existing `Project.destroy` / `Workspace` default destroy do **not** take `:changeset`, so
`undo_action :destroy` would fail at compile with an empty-step reactor. Add a dedicated
Reactor-undo destroy to each resource:

```elixir
# in JidoClaw.Projects.Project and JidoClaw.Workspaces.Workspace
destroy :reactor_undo do
  description("Undo action for Ash.Reactor create-step rollback.")
  public?(false)
  argument(:changeset, :term)
end
```

`public?(false)` keeps this second destructive action off code-interface/AshAdmin-style
surfaces; it does **not** affect the Reactor undo path, which invokes the action internally via
`Changeset.for_destroy/3` (public exposure ≠ internal authorization). Authorization still runs:
`Project`'s `policy always()` authorizes its undo; `Workspace`'s tenant policy (`action_type
:destroy` → `ActorTenantMatches`) authorizes the undo under the run's tenant-matching actor.
These actions are additive (no migration, no columns, no `code_interface` entry). In this saga
only the **project** step's undo actually fires at runtime (the workspace step is terminal);
the workspace undo is declared for pattern completeness and forward Phase-4 undo, and a focused
test proves it stays authorized while private (see Testing).

### 3. `JidoClaw.Orchestration.ReactorRunner` — `lib/jido_claw/orchestration/reactor_runner.ex` (new)

The invocation seam (sibling to `WorkflowRunner`). `run(reactor_module, inputs, opts)`:

```
def run(reactor_module, inputs, opts) do
  name = Keyword.get(opts, :name, inspect(reactor_module))

  with {:ok, tenant} <- Keyword.fetch(opts, :tenant),   # fetch, not fetch! — never raises
       {:ok, actor}  <- Keyword.fetch(opts, :actor),
       {:ok, run} <-
         WorkflowRun.create(%{name: name, workflow_type: "reactor",
                              config: %{reactor: inspect(reactor_module)}},
                            tenant: tenant, actor: actor) do
    execute(run, reactor_module, inputs, tenant, actor)
  else
    :error           -> {:error, :missing_required_opt, nil}  # bad opts, no run yet
    {:error, reason} -> {:error, reason, nil}                 # create failed, no run yet
  end
end

# One try/rescue around BOTH Reactor.run AND finalize, so a raise can't skip finalization.
defp execute(run, reactor_module, inputs, tenant, actor) do
  context = %{tenant: tenant, actor: actor, workflow_run: run,
              reactor: inspect(reactor_module)}   # P3: explicit reactor identity
  try do
    reactor_module
    |> Reactor.run(inputs, context,
         run_id: run.id, async?: false, timeout: :infinity, max_iterations: :infinity)
    |> finalize(run, tenant: tenant, actor: actor)   # {:ok,v}->{:ok,v,run}; {:error,r}->ensure_failed+{:error,r,run}
  rescue
    e ->
      ensure_failed(run, {:exception, Exception.message(e)}, tenant: tenant, actor: actor)
      {:error, {:exception, Exception.message(e)}, run}   # in-memory run; no reload (avoid a 2nd raise)
  end
end
```

Creating the `WorkflowRun` *before* `Reactor.run` mirrors the existing `WorkflowRunner`
pattern: the row exists in `:pending`, then the middleware's `init/1` appends `run_started`
and `Allocate` flips it to `:running` in the same transaction. The reactor never creates the
run — the envelope does.

**`finalize/3` — the terminal-durability backstop (fixes P1 strand + P2 terminal-append
failure).** `Executor.Init.init/4` validates inputs **before** `Hooks.init` runs the
middleware (`deps/reactor/lib/reactor/executor/init.ex`, `executor.ex:69`), so a missing
required input / bad reactor / bad context returns `{:error, _}` from `Reactor.run`
**without** `init/1` (no `run_started`) or `error/2` (no `run_failed`) ever firing — which
would strand the freshly-created run in `:pending`. `finalize/2` closes this: after
`Reactor.run` returns, **reload the run; if its status is still non-terminal, append
`run_failed`** (`next_status(:pending|:running|:awaiting_approval, :run_failed)` is legal, so
this works whether or not `run_started` was recorded). This one mechanism also covers a failed
`error/2` append (run left `:running`). Then return an **envelope carrying the run** (P2):

- `{:ok, value}` → `{:ok, value, reloaded_run}`
- `{:error, reason}` → `ensure_failed(run, reason)` then `{:error, reason, reloaded_run}`

Reload via a tenant-scoped read (`WorkflowRun.by_id/…` with `tenant:`). `ensure_failed/3`
appends `run_failed` only when the reloaded status ∈ non-terminal (else no-op — the middleware
already recorded the terminal). **`ensure_failed/3` must be strictly non-raising** — it
rescues/logs its own internal errors (the reload and the append) and returns `:ok` regardless,
so when it's called from the rescue branch a fresh failure (e.g. DB still down) can't escape
the already-entered `try/rescue`.

**Never-raises contract (P2/P3).** `run/3` is a **never-raises seam**, like `WorkflowRunner`.
`@spec`/moduledoc state the full return shape: `{:ok, value, run} | {:error, reason, run |
nil}` — `run` is **`nil` for pre-run failures** (missing `:tenant`/`:actor` opts caught by
`Keyword.fetch/2`, or a `WorkflowRun.create` failure — there is no run yet), and non-nil once
the run exists. The `try/rescue` lives in `execute/5` and wraps **both** `Reactor.run/4` **and**
`finalize/3`, so a raise anywhere in run-or-finalize is caught (not skipped): the rescue calls
`ensure_failed` (best-effort) and returns `{:error, {:exception, msg}, run}` with the in-memory
run — it does **not** re-raise and does **not** reload (avoiding a second raise if the DB is
the cause). `ensure_failed`/`reload` use tuple-returning Ash calls. This needs the same
`# reach:disable-for-this-file bare_rescue` pragma `WorkflowRunner` carries. Boot recovery is
the final net if even the backstop append fails (e.g. DB down).

### 4. Undo actions on `Project` + `Workspace` (additive)

Add the `destroy :reactor_undo do public?(false); argument(:changeset, :term) end` action
(shown in full in §2 — note the `public?(false)`) to both
`lib/jido_claw/projects/project.ex` and `lib/jido_claw/workspaces/resources/workspace.ex`.
No migration, no `code_interface` entry. These are the only edits outside the `Orchestration`
subsystem.

### 5. No changes to other Phase 0 modules

`WorkflowEvent`, `Projection`, `Allocate`, `WorkflowLog`, `WorkflowRun`, `WorkflowRecovery`
are unchanged — this slice is a new *producer* on top of them. `Orchestration` domain,
`WorkflowStep`, `ApprovalGate`, `WorkflowRunner` are untouched.

## Testing

Under `test/jido_claw/orchestration/`, `use JidoClaw.TenantCase` (shared sandbox; `async:
false` so the in-process `async?: false` reactor and its nested Ash actions share the
connection). Read events with `WorkflowEvent.for_run(run_id, tenant:, actor:)`.

### `reactors/project_registration_test.exs`

- **Happy path.** `{:ok, %Workspace{project_id: pid}, run} = ReactorRunner.run(
  ProjectRegistration, %{github_full_name: "o/r-<uniq>", project_name: ...,
  workspace_name: ..., workspace_path: "/tmp/<uniq>"}, tenant:, actor:)` — the envelope hands
  back the run, so no rediscovery. Assert: the `Project` and `Workspace` rows exist and are
  FK-linked; `run.status == :completed`; the `kind` sequence from `WorkflowEvent.for_run`
  starts `:run_started`, ends `:run_completed`, and contains `:step_started`/`:step_completed`
  for both steps; `Projection.project_status(events) == :completed`.
- **Forced failure → compensation/undo (the keystone test).** Force the **workspace** step to
  fail *after* the project step succeeds, by supplying an invalid required input
  (`workspace_name: nil` — `Workspace.name` is `allow_nil? false`, so the create changeset
  errors; confirmed Reactor validates input *presence*, not value, so nil reaches the step).
  Reactor walks the undo stack and runs the project step's `:reactor_undo` (a destroy).
  `{:error, _reason, run} = ReactorRunner.run(...)`. Assert: `Project.get_by_github_full_name(
  ...)` is now not-found (rolled back); no `Workspace` row persisted; the event sequence
  contains `:run_started`, `:step_failed` (workspace), `:step_undone` (project), and ends
  `:run_failed`; `run.status == :failed`. *(This is the whole point of Phase 1 — verify the
  undo→`:undo_complete`→`step_undone` chain end-to-end first.)*
- **Missing required input → no strand (P1 fix).** Call `ReactorRunner.run(ProjectRegistration,
  %{project_name: ..., workspace_name: ..., workspace_path: ...}, ...)` omitting
  `github_full_name`. `Reactor.run` fails in input validation *before* the middleware runs, so
  `init/1` never fires. Assert: returns `{:error, _reason, run}`; `run.status == :failed` (the
  runner's `finalize` backstop appended `run_failed`); the event sequence is `[:run_failed]`
  with **no** `:run_started` — i.e. the run is not stranded in `:pending`.
- **Missing `:tenant`/`:actor` opt → pre-run envelope (P2 contract).** Call `ReactorRunner.run(
  ProjectRegistration, %{...valid inputs...}, [])` (or omitting one of `:tenant`/`:actor`).
  Assert it returns `{:error, :missing_required_opt, nil}` — no run created, no raise — pinning
  the `run | nil` half of the public return contract.

### `reactor_middleware_test.exs`

Drive a tiny `Reactor.Builder` reactor (built in-test, one synchronous step) through the
middleware to unit-test the producer in isolation: success → `[:run_started, :step_started,
:step_completed, :run_completed]`; a `{:error, _}` step → terminal `:run_failed` with the
formatted error; a missing-context-shape run returns `{:error, _}` and appends nothing.
*(No redaction assertion here — the middleware appends through `WorkflowLog.append` →
`Allocate`, and Phase 0's `workflow_event_test` already proves that path redacts; the
middleware inherits it and manufacturing a sensitive payload would be artificial since
Phase-1 payloads are fixed `%{reactor|step|error: …}` shapes.)*

### `reactor_undo_authz_test.exs` (focused, P2)

Prove the private `:reactor_undo` destroy stays authorized under the normal tenant write
policy: seed a tenant + a `Workspace`, then call its `:reactor_undo` destroy directly with a
tenant-matching actor (`actor_for(tenant)`) and a stub `changeset:` argument; assert it
succeeds and the row is gone. Guards against `public?(false)` accidentally breaking the
Reactor undo path's authorization for the tenant-scoped resource (`Project`'s `always()` undo
is already exercised by the keystone failure test).

### Existing tests

`workflow_event_test.exs`, `workflow_recovery_test.exs`, `workflow_runner_test.exs` are
unchanged and must still pass (this slice adds a producer; it doesn't touch the append path,
recovery, or the cron runner).

## Verification (end-to-end)

1. `mix compile` clean (no new resources/migrations — `ProjectRegistration` is a reactor, not
   an Ash resource).
2. `mix test test/jido_claw/orchestration/` — the two new test files + the unchanged Phase 0
   suite.
3. Tidewave: after `ReactorRunner.run/3` via `project_eval`, `execute_sql_query` →
   `select seq, kind from workflow_events where workflow_run_id = '<id>' order by seq` shows
   `run_started → step_started → step_completed (×2) → run_completed`, and the run's `status`
   is `completed`. Re-run with `workspace_name: nil` and confirm the `step_undone` + `run_failed`
   tail and that the `projects` row is gone.
4. **`mix precommit` passes** — the bar for done.

## Precommit gate & risks

- **`reach.check --smells --strict` (zero today)**: the small payload-shape maps in
  `ReactorMiddleware` and the context-match maps may trip `fixed_shape_map`. Resolve per the
  documented policy — vary shapes, else `# reach:disable-for-this-file fixed_shape_map`, or add
  `"JidoClaw.Orchestration.ReactorMiddleware"` to the `.reach.exs` `fixed_shape_map.ignore`
  list (the Reactor context shape is an external-contract input, the same category already
  exempted there). Run `reach.check --smells --strict` and clear before committing.
  `reach.check --arch`: `Orchestration.*` is unconstrained, so the new modules need no layer
  rule — confirm with a run.
- **`dialyzer`**: full `@spec`s on every public function. Use Reactor's exported types
  (`Reactor.context()`, `Reactor.Step.t()`) in the middleware callback specs.
- **`credo --strict`**: real moduledocs (or `@moduledoc false`), bounded function length, no
  `TODO`s (phrase forward-notes as plain comments), `Logger.warning` not `Logger.warn`.
- **`jidoclaw.compile_check`**: no Ash resource added; the `ProjectRegistration` reactor and
  the middleware are plain modules — no new compile warnings expected, no allowlist change.
- **Reactor API facts (verified against the installed deps — no longer open risks):**
  (a) `Ash.Reactor` create-step `undo_action` must be a destroy/update taking exactly one
  `:changeset` argument — addressed by the `:reactor_undo` actions (§2/§4);
  (b) per-step domain is inferred from each resource via `Ash.Resource.Info.domain/1`, so the
  cross-domain (Projects + Workspaces) saga needs no per-step domain;
  (c) Reactor auto-undoes completed `undo: :always` steps on a downstream failure, and the Ash
  create-step `undo/4` surfaces as `:undo_complete` through `event/3` → `:step_undone`;
  (d) a nil required input reaches the Ash step (Reactor validates input *presence*, not
  value), so the forced-failure test needs no fault-injection hook.
- **JSON-safe payloads**: enforced by storing only identifiers/strings (no raw Ash structs) —
  see §1. The single most likely runtime footgun, designed out of this slice.
- **Terminal durability**: owned by the runner's `finalize` backstop (§3), not by middleware
  `error/2` alone — covers pre-`init` strands and failed terminal appends; boot recovery is
  the final net.
