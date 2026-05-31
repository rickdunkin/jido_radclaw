# T2-5 — Schedule kind switch (`:agent | :workflow | :mfa`), with cron as the first `WorkflowRun` producer

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` audits features borrowed from the sibling `jidoka` project into jido_radclaw. Tier-1 (Trace, Compaction, Output, Error) and most of Tier-2 (Handoff, Subagent context-visibility, Inspection) are ADOPTED. The two remaining live items are **T2-2 AgentView** (a 3–4 week multi-axis redesign — too large for one "complete" plan) and **T2-5 Schedule kind** (the doc's "small ergonomic win, can ship anytime").

This plan implements **T2-5**. Today `Cron.Job` conflates two concerns in `mode` (`:main`/`:isolated` = chat dispatch, `:system_job` = MFA dispatch) and can only fire chat turns or MFA. The doc's adoption sketch asks for a separate execution-**target** dimension (`:agent | :workflow | :mfa`), dispatched through a small adapter, plus durability counters (`run_count`).

Per the user's chosen direction, the new `:workflow` target does **not** just re-run a named skill — it becomes the **first real producer** of the `JidoClaw.Orchestration.WorkflowRun` Ash state machine. That state machine exists today (`create → start → complete/fail/cancel`, with `RunPubSub` + `RunSummaryFeed` + `DashboardLive` already wired to consume events) but **nothing in `lib/` drives it** (confirmed: zero `WorkflowRun.create/.start/.complete` calls). Cron-fired workflows will create/start/complete/fail durable run rows and broadcast the events the dashboard already listens for.

**Outcome:** a cron job can be scheduled with `target: :workflow` + a skill name; on fire it drives a tracked `WorkflowRun` (visible on the dashboard) around the existing workflow drivers. Existing `:agent`/`:mfa` behavior is unchanged. The plan is complete only when `mix precommit` passes.

> This revision incorporates review feedback: the `target: :mfa` reload bug, a shared per-run `workspace_id`, raise-safe error formatting, a fully-atomic `record_run`, an invalid-workflow-job invariant, prompt/doc updates, and a corrected verification step.

## Key design decisions (and why)

- **Legacy-first dispatch, no data backfill.** `Cron.Dispatcher.resolve_target/1` checks `mode == :system_job → :mfa` *before* consulting `target`. This keeps every existing `:system_job` row working and protects the in-memory memory-consolidator system job (scheduled via `Scheduler.start_system_jobs/0` with `mode: :system_job` and **no** DB row), without an `UPDATE cron_jobs ...` migration. New rows default `target: :agent`; legacy rows ignore `target` in favor of `mode`. Keeps `persistent_disable_test.exs` / `policy_authz_test.exs` green untouched.
- **`:mfa` target is real (reload fixed), not a trap.** `:mfa` stays in the enum (doc parity). The reload path is corrected so a persisted `target: :mfa` row (even with default `mode: :main`) builds its MFA and dispatches correctly — see the `scheduler.ex` change below. A dedicated reload test pins this.
- **Shared per-run `workspace_id` for cron workflows.** The runner builds a **deterministic** `workspace_id = "cron:#{job_id}:#{run.id}"` and passes it as both the `workspace_id:` driver opt and the `scope_context[:workspace_id]` key — exactly as `RunSkill` does (`run_skill.ex:57,74`). Without it, `StepAction` falls back to a unique per-step `"wf_#{tag}"` (`step_action.ex:310`), so steps in the same cron workflow would **not** share shell/VFS state. The shared id fixes that.
- **Minimal identity scope, no Session/Workspace resolution.** Beyond `workspace_id`, the runner uses `%{tenant_id, project_dir: File.cwd!(), actor: Actor.system(tenant_id)}` and does **not** resolve a `Conversations.Session`/`Workspaces.Workspace`. Trade-off: no `Conversations.Message`/correlation rows for cron workflows — observability lives in the `WorkflowRun` row + `RunPubSub` + cron telemetry, matching the "drive WorkflowRun" intent. Documented in the runner moduledoc. **Main design caveat:** `File.cwd!()` makes cron workflow execution *project-global* (the app's boot-time cwd). This is acceptable for v1 (cron is a single-project concern today); if MCP/web multi-workspace cron becomes a requirement, persist a `project_dir` on the `Cron.Job` row and thread it through — listed in follow-ups.
- **Use the *started* run struct; keep DB terminal state and PubSub consistent.** `WorkflowRun.start/1` returns the updated (`:running`) record — `complete/2`/`fail/2` validate `status == :running`, so the runner threads the **started** struct (not the original pending one) into finalization, or those transitions fail validation. Broadcasts are emitted **only after** the terminal Ash update returns `{:ok, _}` — never broadcast `:run_completed`/`:run_failed` against a row that's still `:running` (that would desync `RunSummaryFeed`/the dashboard). A `complete` persistence failure returns `{:error, {:terminal_persist_failed, reason}}` (surfaces to the cron failure-counter); a `fail` persistence failure is logged (no broadcast) and the original failure reason is still returned.
- **Raise-safe error formatting.** `WorkflowRunner.run/1` has `@spec ... :: :ok | {:error, term()}` and never raises: the executor call is wrapped in `try/rescue`, and every error (tuple, map, exception, binary) is normalized through a local `format_reason/1` (`Exception.message/1` for exceptions, binaries as-is, `inspect/1` fallback) **before** calling `WorkflowRun.fail/2`. No `to_string(reason)` (which raises on arbitrary tuples/maps).
- **Invalid-job invariants (defense in depth).** `:upsert` validations so bad rows can't silently always-fail: `present(:workflow_name)` where `target == :workflow`; **and** `present([:mfa_module, :mfa_function])` where `target == :mfa`, plus the same where `mode == :system_job` (both existing `:system_job` test upserts already supply MFA, so this is regression-safe). Backed by `Scheduler.build_persistent_opts/1` reload guards (skip+log) and up-front `ScheduleTask` rejection (which also verifies the skill exists).
- **Atomic `record_run` action.** `change atomic_update(:run_count, expr(run_count + 1))` + `change atomic_update(:last_run_at, expr(now()))` — both atomic, no `require_atomic? false`. The *action* loads no record; the worker does one `Job.by_job_id` read first to obtain the record to update (acceptable at cron cadence). Fallback if `expr(now())` won't compile atomically: capture form `set_attribute(:last_run_at, &DateTime.utc_now/0)` with `require_atomic? false` — single-writer per job, race-free.
- **Two new modules, not three.** Skill resolution + mode dispatch is inlined in the runner; `RunSkill` is **not** refactored into a shared `Workflows.Runner`. We reuse the already-public `JidoClaw.Tools.RunSkill.build_result/2` to shape the run's `result` map (or inline a 5-line equivalent if the cross-namespace dependency feels wrong).
- **Deferred (to honor the doc's strict ADOPTED bar — no placeholder fields):**
  - `skip_count` — the synchronous GenServer worker processes ticks serially and cannot overlap, so there is no producer. Adding it now would be a dead field. Documented rationale; revisit if dispatch becomes async with an overlap policy.
  - `WorkflowStep` row population — drivers return only `{:ok, [%StepResult{}]}` on success / `{:error, reason}` on failure, so steps can't be reconstructed on the failure path; success-only would be asymmetric. Proper fix is driver-level step persistence (separate story). `has_many :steps` returns `[]` for v1.
  - Durable session/message recording for cron workflows (see "minimal identity scope").
  - Stale-`:running` sweep job (for the rare case a terminal transition's DB write fails).

## Files to create

### `lib/jido_claw/platform/cron/dispatcher.ex` (NEW, ~35 LOC)
Pure routing (telemetry stays in the worker). Spec loosely as `dispatch(map()) :: term()` (verbatim passthrough; the worker's existing `case result` already handles `:ok | {:ok,_} | {:error,_} | _other`).

```elixir
def dispatch(%{mode: :system_job} = s), do: run_mfa(s)
def dispatch(%{target: :workflow} = s), do: run_workflow(s)
def dispatch(%{target: :mfa} = s), do: run_mfa(s)
def dispatch(s), do: run_agent(s)
```
- **No `mfa`-present fallback clause.** MFA dispatch fires *only* for `mode: :system_job` or `target: :mfa`. Today `:main`/`:isolated` rows ignore any `mfa` field (`worker.ex:122`); a `when not is_nil(mfa)` fallback would change that behavior, so it is deliberately omitted.
- `run_agent/1` and `run_mfa/1` are the existing `:main`/`:isolated`/`:system_job` arm bodies, lifted verbatim from `Worker.execute_job/1` (`worker.ex:122-142`).
- `run_workflow/1` calls `Application.get_env(:jido_claw, :cron_workflow_runner, JidoClaw.Orchestration.WorkflowRunner).run(s)`.

### `lib/jido_claw/orchestration/workflow_runner.ex` (NEW, ~100 LOC)
First `WorkflowRun` driver. `@spec run(map()) :: :ok | {:error, term()}` — never raises. Small private fns (credo nesting ≤ 2):

```elixir
def run(%{workflow_name: name} = state) do          # read tenant via state.tenant_id (no unused bind)
  input = Map.get(state, :workflow_input) || %{}
  with {:ok, skill}   <- JidoClaw.Skills.get(name, File.cwd!()),
       {:ok, started} <- create_and_start(name, skill, state, input) do
    execute_and_finalize(skill, input, state, started)   # :ok | {:error, _}
  else
    {:error, reason} -> {:error, format_reason(reason)}   # unknown skill etc. (no orphan run)
  end
rescue
  e -> {:error, Exception.message(e)}
end
```
- `create_and_start/4`: `{:ok, created} <- WorkflowRun.create(%{name: name, workflow_type: to_string(Skills.execution_mode(skill)), config: %{trigger: "cron", cron_job_id: state.id, skill: name, input: input}})`, then `{:ok, started} <- WorkflowRun.start(created)`, then `broadcast(:run_started, started)`, and **returns `{:ok, started}`** (the `:running` record). Finalization uses `started` so `complete/2`/`fail/2` see `status == :running`.
- `execute_and_finalize/4`: builds `workspace_id = "cron:#{state.id}:#{started.id}"`, `extra = Map.get(input, "context", "")`, `scope = %{tenant_id: state.tenant_id, workspace_id: workspace_id, project_dir: File.cwd!(), actor: Actor.system(state.tenant_id)}`, `opts = [workspace_id: workspace_id, scope_context: scope]`. Calls the executor seam (wrapped in its own `try/rescue`):
  - success → `finalize_complete(started, RunSkill.build_result(skill, steps))`: `case WorkflowRun.complete(started, %{result: result}) do {:ok, done} -> broadcast(:run_completed, done); :ok; {:error, reason} -> {:error, {:terminal_persist_failed, reason}}` (no broadcast on persist failure).
  - error / rescue → `finalize_fail(started, reason)`: `case WorkflowRun.fail(started, %{error: format_reason(reason)}) do {:ok, failed} -> broadcast(:run_failed, failed); {:error, e} -> Logger.warning(...)` (no broadcast), then return `{:error, format_reason(reason)}`.
- Executor seam (default = this module's `dispatch/4`): `Application.get_env(:jido_claw, :cron_workflow_executor, __MODULE__).dispatch(skill, extra, File.cwd!(), opts)`, where `dispatch/4` branches by `Skills.execution_mode/1` to `IterativeWorkflow`/`PlanWorkflow`/`SkillWorkflow`.
- `format_reason/1`: `%{__exception__: true}=e → Exception.message(e)`; binary → as-is; else `inspect/1`.
- **PubSub `info` maps** (match `dashboard_live.ex:95-107` / `run_summary_feed.ex`; `cron_job_id` is an extra correlation key — `name` is the skill name and is *not* unique, so consumers/tests key on `cron_job_id`, and unknown keys are ignored by the existing consumers):
  - `:run_started` → `%{name:, workflow_type:, status: :running, cron_job_id: state.id}`
  - `:run_completed` → `%{name:, workflow_type:, status: :completed, result:, completed_at:, cron_job_id: state.id}`
  - `:run_failed` → `%{name:, workflow_type:, error:, completed_at:, cron_job_id: state.id}` (feed forces `status: :failed`)

## Files to modify

### `lib/jido_claw/cron/resources/job.ex`
- Add attributes (all `public?(true)`): `target` (`:atom`, `one_of: [:agent, :workflow, :mfa]`, `default: :agent`, `allow_nil?: false`), `workflow_name` (`:string`, `allow_nil?: true`), `workflow_input` (`:map`, `default: %{}`, `allow_nil?: true`), `run_count` (`:integer`, `default: 0`, `allow_nil?: false`), `last_run_at` (`:utc_datetime_usec`, `allow_nil?: true`).
- Extend `:upsert` `accept` **and** `upsert_fields` with `:target, :workflow_name, :workflow_input` (NOT `run_count`/`last_run_at` — system-managed).
- Add `:upsert` validation invariants (Ash `where:` ANDs its conditions, so the `:mfa`/`:system_job` requirement is two statements to get OR semantics):
  ```elixir
  validate(present(:workflow_name), where: [attribute_equals(:target, :workflow)])
  validate(present([:mfa_module, :mfa_function]), where: [attribute_equals(:target, :mfa)])
  validate(present([:mfa_module, :mfa_function]), where: [attribute_equals(:mode, :system_job)])
  ```
  (Verified regression-safe: both `:system_job` upserts in `persistent_disable_test.exs` already pass `mfa_module`/`mfa_function`; `policy_authz`/`audit` upserts are `:main` mode.)
- Add a `:record_run` update action + `define(:record_run, action: :record_run)`:
  ```elixir
  update :record_run do
    accept([])
    change(atomic_update(:run_count, expr(run_count + 1)))
    change(atomic_update(:last_run_at, expr(now())))
  end
  ```
- Update the moduledoc paragraph about `mode: :system_job` to mention `target` as the forward-compat dispatch dimension.

### `lib/jido_claw/platform/cron/scheduler.ex`
- **Fix the `target: :mfa` reload bug.** In `build_persistent_opts/1` (`:60`), thread the new fields into `base`: `target: job.target, workflow_name: job.workflow_name, workflow_input: job.workflow_input`. Change the `build_mfa/1` "no MFA needed" guard (`:76`) from `when mode != :system_job` to require MFA for **either** condition:
  ```elixir
  defp build_mfa(%Job{mode: mode, target: target}) when mode != :system_job and target != :mfa,
    do: {:ok, nil}
  # ...remaining clauses (missing-module error + resolve) unchanged
  ```
- Add a reload guard (clause on `build_persistent_opts/1`) that skips invalid workflow rows: `defp build_persistent_opts(%Job{target: :workflow, workflow_name: nil}), do: {:error, :missing_workflow_name}` — `try_schedule_job/2`'s existing `{:error, :build_opts, reason}` branch (`:30`) logs + skips it.

### `lib/jido_claw/platform/cron/worker.ex`
- Extend the defstruct + `init/1` with `:target` (`Keyword.get(opts, :target, :agent)`), `:workflow_name`, `:workflow_input`. **Do not** add an in-memory `run_count` (the row is the source of truth).
- Replace the `case state.mode do ... end` body inside `execute_job/1`'s `try` (`worker.ex:122-142`) with `JidoClaw.Cron.Dispatcher.dispatch(state)`. Keep the telemetry emits and the `case result do` block exactly as-is.
- After `emit_cron_stop`, call a best-effort `record_run(state)` (mirrors `persist_disabled/1`, `worker.ex:227-243`): `Job.by_job_id(state.id, ...)` → if `{:ok, job}`, `Job.record_run(job, ...)`; `{:error,_}` → no-op; wrap in `rescue` and log at `:debug`. This increments durable `run_count`/`last_run_at` for **any persisted job** (agent/workflow/mfa, including persisted `:system_job` rows) and safely skips only non-persisted jobs (e.g. the in-memory memory-consolidator, which has no row).

### `lib/jido_claw/tools/schedule_task.ex`
- Add two params to the tool's `Jido.Action` `schema` (keyword-list form): `target` (`type: :string`, optional, doc: `"'agent' (default, runs a chat turn) or 'workflow' (runs a named skill as a tracked workflow run)"`) and `workflow` (`type: :string`, optional, doc: `"Skill name to run when target is 'workflow' (see /skills)"`).
- In `run/2`: parse `target` via a strict `parse_target/1` that accepts only `"agent"`/`"workflow"` (and `nil` → `:agent`) and **returns `{:error, ...}` on anything else** — do NOT mirror `parse_mode/1`'s silent fallback (`schedule_task.ex:173`), so `target: "workflwo"` errors rather than silently scheduling an agent job. When `:workflow`: require non-blank `workflow`, and validate the skill exists via `JidoClaw.Skills.get(workflow, project_dir)` **before** scheduling. Build `persist_attrs`/`schedule/2` opts with `target`, `workflow_name: workflow`, `workflow_input: %{"context" => params.task}`. Agent path unchanged (`target: :agent`). No `:system_job`/`:mfa` exposure (agents can't schedule MFA).
- Fix the stale moduledoc line ("Persists to `.jido/cron.yaml`") → Postgres.

### `lib/jido_claw/tools/list_scheduled_tasks.ex`
- Add `target` (and `workflow_name` for workflow targets) to the per-job formatted line — both are in worker state.

### `lib/jido_claw/cli/commands.ex`
- Update `print_cron_job/1` (rendered by the `/cron` handler at `:584`) to display `target`/`workflow_name` alongside the existing fields.

### `priv/defaults/system_prompt.md` **and** `.jido/system_prompt.md`
- Update the `schedule_task` entry (`priv/defaults/system_prompt.md:241-247`) to document the new `target`/`workflow` parameters and correct the stale "Persists to `.jido/cron.yaml`" line → "Persisted to Postgres — survives restarts." Apply the **same** edit to `.jido/system_prompt.md` (the runtime-loaded copy; not gitignored) so agents actually learn the params. Tool count/names are unchanged, so `mix jidoclaw.system_prompt.check` (which only reads `priv/defaults/system_prompt.md`, keyed on count + names) stays green.

### `lib/mix/tasks/jidoclaw.migrate.cron.ex`
- The legacy `.jido/cron.yaml` → Postgres migrator's `legacy_to_attrs/1` (`:108`) builds upsert attrs with **no** MFA fields (legacy YAML never carried them). With the new `mode == :system_job` MFA invariant, a legacy `system_job` row would now fail the upsert mid-batch with an opaque validation error. Make `legacy_to_attrs/1` return `:invalid` for `mode: "system_job"` — a clear skip, counted in the existing `failed`/skip tally and logged. Legacy cron YAML only ever held agent-mode tasks, so this is the correct semantics. Extend `test/mix/tasks/jidoclaw_migrate_cron_test.exs` to cover the skip.

## Migration

After the resource edits, generate the migration + snapshot in one step (do **not** hand-edit; no data backfill):
```
mise exec -- mix ash.codegen add_cron_target_and_counters
```
Adds 5 columns to `cron_jobs` with correct Postgres defaults (`target='agent'`, `run_count=0`, `workflow_input='{}'`) so existing rows stay valid, and writes a new `priv/resource_snapshots/repo/cron_jobs/<ts>.json`. Commit the resource change together with its codegen output (never split — `mix test` runs `ash.setup` and fails on snapshot/DB drift).

## Reused existing code (do not reinvent)

- `JidoClaw.Tools.RunSkill.build_result/2` (`run_skill.ex:133`, public) — shapes the `WorkflowRun.result` map.
- `JidoClaw.Skills.get/2` + `execution_mode/1` (`platform/skills.ex:278,332`) — skill resolution + mode.
- Workflow drivers `{Skill,Plan,Iterative}Workflow.run/4` (`lib/jido_claw/workflows/`) — execution.
- `JidoClaw.Orchestration.{WorkflowRun, RunPubSub}` — state machine + broadcast.
- `JidoClaw.Authorization.Actor.system/1` — cron actor.
- Best-effort persistence pattern from `Worker.persist_disabled/1` — copied for `record_run/1`.
- `Application.get_env(:jido_claw, key, Default)` swap pattern (`spawn_agent.ex`) — for the two test seams (`:cron_workflow_runner`, `:cron_workflow_executor`).

## Implementation steps (ordered; each step keeps `mix test` green)

1. **Job resource**: 5 attributes + `:upsert` accept/upsert_fields + the three invariant validations (workflow-name + MFA presence) + `:record_run` action/interface + moduledoc.
2. **Migration**: `mix ash.codegen add_cron_target_and_counters`; confirm columns + snapshot.
3. **Worker**: defstruct + `init/1` fields; best-effort `record_run/1`.
4. **Scheduler**: thread new fields in `build_persistent_opts/1`; fix `build_mfa/1` guard for `target: :mfa`; add invalid-workflow reload guard.
5. **Dispatcher** (new): lift `:agent`/`:mfa` arm bodies; `run_workflow/1` returns `{:error, :not_implemented}` initially; switch `Worker.execute_job/1` to `Dispatcher.dispatch/1`. (`mix test` green.)
6. **WorkflowRunner** (new): create→start→complete/fail + 3 broadcasts + shared `workspace_id` + `format_reason/1` + executor seam; wire `Dispatcher.run_workflow/1`.
7. **ScheduleTask**: `target`/`workflow` params + skill-exists validation + persist/schedule threading + moduledoc fix.
8. **Display + docs + migrator**: `ListScheduledTasks` line, `commands.ex print_cron_job/1`, both `system_prompt.md` files, and the `jidoclaw.migrate.cron` legacy-`system_job` skip.
9. **Tests** (below).
10. **`mix precommit`**: decompose for credo nesting, `@spec` every new public fn, dialyzer/format/test green.

## Tests (new)

Use `JidoClaw.TenantCase` (Ecto sandbox + `seed_tenant/1` + `actor_for/1`). `Application.put_env`-based tests are `async: false` and **must snapshot + restore env in `on_exit`** (follow `spawn_agent_test.exs`'s `restore_env/2` pattern). `WorkflowRun` is not tenant-scoped (no `tenant:`/policies) but still needs the sandbox.

- `test/jido_claw/cron/job_target_test.exs` — `target` defaults to `:agent`; accepts `:workflow`/`:mfa`; `workflow_name`/`workflow_input` round-trip; `:record_run` increments `run_count` and stamps `last_run_at`; **upsert with `target: :workflow` and no `workflow_name` is rejected**; **upsert with `target: :mfa` and no `mfa_module`/`mfa_function` is rejected**.
- `test/jido_claw/cron/dispatcher_test.exs` — routing matrix via stubbed `:cron_workflow_runner`: `mode: :system_job` → mfa; `target: :workflow` → runner; `target: :mfa` → mfa; default → agent; **a `mode: :main` row carrying an `mfa` field still routes to `:agent`** (no mfa-present fallback). Asserts legacy precedence.
- `test/jido_claw/cron/mfa_reload_test.exs` — persist a `target: :mfa, mode: :main` row with a test MFA (`JidoClaw.Cron.TestSupport`), `Scheduler.load_persistent_jobs/2`, then `Worker.trigger` and assert the MFA actually ran (mirrors `persistent_disable_test.exs` Contract 3 but for the `:mfa` target).
- `test/jido_claw/orchestration/workflow_runner_test.exs` — stub `:cron_workflow_executor` (a module with `dispatch/4`); pass a **unique `state.id`** so events are addressable. Success → `WorkflowRun` row reaches `:completed` with a `result`, plus `assert_receive {:run_started, _, %{cron_job_id: ^unique_id}}` / `{:run_completed, _, %{cron_job_id: ^unique_id}}` (subscribe via `RunPubSub.subscribe_all/0`, match on `cron_job_id` — `name` is the skill name and is not unique); **assert the stub received a non-nil `workspace_id` opt matching `"cron:" <> _`** (shared-scope guarantee); failure → row `:failed` with `error` + `{:run_failed, ...}`; an executor that **raises** → still `:failed`, never stranded `:running`; unknown skill → `{:error,_}` and **no** run row created.
- `test/jido_claw/tools/schedule_task_test.exs` (new file) — `target: "workflow"` without `workflow` → error; with an unknown skill → error; valid `target: "workflow"` persists a row with `target: :workflow` + `workflow_name` (use a far-future cron so the started worker never ticks); legacy `target: "agent"` path unchanged.
- Confirm `persistent_disable_test.exs` and `policy_authz_test.exs` still pass unmodified.

## Verification

Run mix via mise (OTP 28.5) — the shell-default OTP forces a failing dep recompile:

1. **Migration applies cleanly**: `mise exec -- mix ecto.migrate` (or rely on `mix test`'s `ash.setup`); `mise exec -- mix ash.codegen --check` shows no drift.
2. **Full gate (the completion bar)**: `mise exec -- mix precommit` — fully green (`compile --warnings-as-errors`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format`, `credo --strict`, `dialyzer --format short`, `test`).
3. **End-to-end (Tidewave `project_eval` / iex)**:
   - Direct runner: `JidoClaw.Orchestration.WorkflowRunner.run(%{id: "demo", tenant_id: tid, workflow_name: "explore_codebase", workflow_input: %{}})` → `:ok`; then read the row back with **`JidoClaw.Orchestration.WorkflowRun.list/0`** (NOT `list_active/0` — that filters out completed rows) and confirm a `:completed` row with a populated `result`. (`list_active/0` is correct only to observe a run *while* it is pending/running.)
   - Via cron: schedule a `target: :workflow` job (`ScheduleTask` or `Cron.Scheduler.schedule/2`), then `Cron.Scheduler.trigger(tenant_id, job_id)`; confirm the `WorkflowRun` row + that `run_count` incremented on the `Cron.Job` row.
   - `:mfa` reload: persist a `target: :mfa, mode: :main` row with a real MFA, reload, trigger, confirm it dispatches (regression for the fixed bug).
   - Dashboard: load `DashboardLive`; confirm the run appears in active/recent (consumes the `RunPubSub` events the runner now emits — the `dashboard_live.ex:93` "not yet broadcast" comment becomes obsolete).
   - Regression: a legacy `target: :agent` cron job still fires a chat turn unchanged.

## Commit slicing (guidance only — do not commit without an explicit request)

Suggested commits: (1) resource attrs + validation + migration/snapshot; (2) worker + scheduler threading/MFA-reload fix + record_run; (3) Dispatcher + worker switchover; (4) WorkflowRunner + dispatcher wiring; (5) ScheduleTask + display + prompt docs; (6) tests. Conventional prefix `feat:`.

## Out of scope / follow-ups

- `skip_count` + overlap policy (needs async dispatch).
- `WorkflowStep` row population (needs driver-level step persistence).
- Durable Conversations.Message recording for cron workflows.
- Stale-`:running` sweep for the rare terminal-transition write failure.
- Routing `Tools.RunSkill` through `WorkflowRun` too (tool-invoked skills as tracked runs).
- `T2-2 AgentView` multi-axis redesign (separate, larger effort).
