# Phase 3 — Skills on Reactor

## Context

`docs/exploration/squidie/REACTOR-ADOPTION.md` §8 lays out a phased migration that makes
**Reactor the single workflow engine** wrapped in the Squidie-borrowed **durable envelope**
(append-only event log, status-as-projection, crash recovery, human gates). The last three
commits completed:

- **Phase 0** (`f825097`) — `WorkflowEvent` log + status projection + recovery foundation.
- **Phase 1** (`f4c6c04`) — first `Ash.Reactor` workflow + `ReactorMiddleware` event producer + `ReactorRunner`.
- **Phase 2** (`aa779be`) — human approval gates: durable halt → checkpoint → restart → resume (Strategy A, persist the halted struct).

**Next is Phase 3 — Skills on Reactor.** Today the LLM-authored skill surface (`.jido/skills/*.yaml`)
runs on three bespoke drivers entirely outside the durable envelope:

- `JidoClaw.Workflows.IterativeWorkflow` (generator/evaluator loop),
- `JidoClaw.Workflows.PlanWorkflow` (hand-rolled Kahn DAG + parallel phases),
- `JidoClaw.Workflows.SkillWorkflow` (sequential FSM via jido_composer),
- dispatched by `JidoClaw.Orchestration.WorkflowRunner` (cron) and `JidoClaw.Tools.RunSkill` (chat).

These have **no event log, no status, no recovery, no audit trail**. Chat-initiated skills
(`run_skill`) don't even create a `WorkflowRun` row. Phase 3 retires all of this: compile each
skill's YAML to a Reactor via `Reactor.Builder`, run it through the existing `ReactorRunner`
envelope, and **delete the bespoke drivers**. Outcome: every skill run gains a durable
`WorkflowRun` + event timeline + dashboard visibility + crash recovery, uniformly with
developer-authored reactors.

**Decisions for this plan:** (1) skills run **`async?: true`** to preserve PlanWorkflow's
parallel-phase behavior; (2) the **full phase ships as one `mix precommit`-green deliverable**.

**No schema changes / no migration** — Phase 3 reuses the Phase 0–2 resources (`WorkflowRun`,
`WorkflowEvent`, `AgentCase`) as-is. Greenfield: no compat layer, no data migration.

## Target architecture

One engine (Reactor), one envelope (`ReactorRunner` + `ReactorMiddleware` + `WorkflowEvent`),
**two front-ends**: developer-authored `Ash.Reactor` modules (shipped, e.g.
`lib/jido_claw/orchestration/reactors/project_registration.ex`) and **LLM-authored YAML skills
compiled to `%Reactor{}` structs at runtime**.

```
.jido/skills/*.yaml ──> JidoClaw.Skills (cache, unchanged)
                            │  %Skills{steps, mode, max_iterations, synthesis}
                            ▼
              JidoClaw.Skills.Compiler.compile/1  ──> {:ok, %Reactor{}}
                            │   Reactor.Builder: input(:extra_context),
                            │   AgentStep/IterativeStep per step, terminal CollectStep
                            ▼
   run_skill tool ─┐                          ┌─ cron WorkflowRunner.run/1 (thin adapter)
                   ▼                          ▼
            JidoClaw.Orchestration.ReactorRunner.run(reactor_struct, inputs, opts)
                   │  creates WorkflowRun · wires ReactorMiddleware · Reactor.run(async?: true)
                   ▼
            ReactorMiddleware ──> WorkflowEvent log ──> WorkflowRun.status (projection)
                   │              (+ persists CollectStep's JSON-safe result into run_completed)
                   └──> RunPubSub run-lifecycle broadcasts (dashboard) — AFTER each durable append
```

Reactor resolves the DAG topology + concurrency natively, replacing PlanWorkflow's Kahn algorithm.
Each compiled step spawns a templated sub-agent (today's `StepAction` behavior), now hosted in a
`Reactor.Step`.

## New modules (`lib/jido_claw/skills/`)

### `JidoClaw.Skills.Compiler`
`compile(%JidoClaw.Skills{}) :: {:ok, Reactor.t()} | {:error, term()}` — builds a `%Reactor{}` via
`Reactor.Builder` (`deps/reactor/lib/reactor/builder.ex`).

- **Internal atom-id mapping (critical — see C-NAMES):** generate positional atom ids `:step_1..:step_N`
  for Reactor step + argument names. **Never `String.to_atom/1` on YAML.** Keep each step's YAML
  string name (and `depends_on` strings) as **metadata in the step's options**. Build a
  `%{yaml_name => :step_id}` index; resolve `depends_on` strings through it.
- `Builder.new/0` → `Builder.add_input(:extra_context)` (the only runtime input — the user's
  additional instructions; every step references it).
- One `AgentStep`/`IterativeStep` per skill step; impl tuple `{Mod, opts}` (C-IMPL), `max_retries: 0` (C-RETRIES).
- Terminal **`CollectStep`** depending on **every** agent/iterative step (via `from_result` on **all**
  their atom ids — *not* only leaves: sequential's only leaf is the last step, so leaf-only would drop
  every prior result and report `steps_completed: 1`; current drivers accumulate all results,
  `skill_workflow.ex:153`/`plan_workflow.ex:264`); `Builder.return(:__collect__)`.
- **Does NOT add `ReactorMiddleware`** — `ReactorRunner` is the sole wirer (C-MIDDLEWARE).
- **Display label stays template-based.** The `:step_N` atom is the *internal Reactor id only*. Each
  step's `StepResult.name` keeps its YAML name **or `nil` when unnamed** — `Skills.Result.build/2` uses
  `name || template` (`run_skill.ex:137`), so unnamed steps still render readable labels (`reviewer`,
  `refactorer`, `test_runner`), never `step_3`.
- **Validation** (port from `plan_workflow.ex`): reject duplicate **non-nil** YAML step names (unnamed
  steps have `name: nil`, so they never collide), missing `depends_on` **and `consumes`** targets, and
  cycles → clean `{:error, …}` from `compile/1` instead of a raw `Reactor.Planner` `PlanError` at run time.

Three mode strategies (`JidoClaw.Skills.execution_mode/1` → `:sequential | :dag | :iterative`):

| Mode | Construction |
| --- | --- |
| **sequential** | Positional atom ids always. Step N takes `from_result` args for every prior step k<N (feeds full preceding history *and* forces linear order) + `from_input(:extra_context)`. `context_format: :preceding`. |
| **dag** | Wire `from_result(:step_id, :step_id)` args for **`depends_on` ∪ `consumes`** (a `consumes` target without a `depends_on` edge would otherwise never receive the producer's result — so `consumes` *is* a data-dependency edge here, ordering the consumer after its producer); Reactor derives topology + concurrency. + `from_input(:extra_context)`. `context_format: :deps`. AgentStep formats dep-context from `depends_on` and artifact-context from `consumes` (both present in `arguments`). |
| **iterative** | A single `IterativeStep` wired to `from_input(:extra_context)`, then the `CollectStep`. **Reject `Reactor.Builder.recurse/5`** — it needs an *atom* inner reactor + output⊇input IO-compatibility (`builder/recurse.ex:52,116`), an awkward fit for a generator/evaluator-with-feedback loop. The single-step port is faithful to `IterativeWorkflow`. |

### `JidoClaw.Skills.Steps.CollectStep` (`use Reactor.Step`)
The terminal step that **produces the run's durable result**. Options carry the ordered
`[{:step_id, yaml_name}]` list (**all** steps) + `skill_name` + `synthesis`. Receives **every** agent
step's `%StepResult{}` (dag/sequential) or the `[gen, eval]` list (iterative) as arguments; reorders by
the configured order; calls `JidoClaw.Skills.Result.build(skill_name, synthesis, results)` and returns the **JSON-safe** result map
(`%{skill, steps_completed, synthesis_prompt, results, message}`). `steps_completed` is the count of
agent results it received (so it's correct regardless of `:__collect__` itself appearing in the
`step_*` timeline — see C-COLLECT). This is the reactor's return value, which the middleware persists
(see Result persistence below).

### `JidoClaw.Skills.Result`
`build(skill_name, synthesis, results)` — relocated from `RunSkill.build_result/2` (the `%StepResult{}`
/ `{label, text}` → numbered-transcript formatter). Signature takes `skill_name` + `synthesis` directly
(not a `%Skills{}` struct) so `CollectStep` can call it from its options without reconstructing a
partial struct. Used by `CollectStep`. (Was a documented `RunSkill` test seam; its tests move here.)

### `JidoClaw.Skills.Steps.AgentRunner`
Shared "spawn templated agent, run task, capture result" **core ported verbatim from
`lib/jido_claw/workflows/step_action.ex`**: `Templates.get` → `JidoClaw.Jido.start_agent` → async
`module.ask/3` + `await_completion` (typed output) with `ask_sync` fallback →
`SubagentTranscript.record_task`/`record_terminal` → `{:ok, %StepResult{}} | {:error, binary}`. Keep
the bare-rescue (`step_action.ex:86-96`) so a sub-agent crash becomes a step `{:error,_}` + a
`:system` transcript terminal — annotate `# reach:disable-next-line bare_rescue`. Also home for
`resolve_scope/3`, `inject_produces_instruction/2`, `extract_artifacts/1`, now resolving scope from
**Reactor context** (`context[:tenant]`→`tenant_id`, `context[:actor]`→`actor`, plus merged
`workspace_id`/`project_dir`/`session_*`/`user_id`) with the **same precedence/fallback semantics**
as `StepAction.resolve_scope/3`.

### `JidoClaw.Skills.Steps.AgentStep` (`use Reactor.Step`)
`run(arguments, context, options)` — the sequential/dag leaf. `options`: `template`/`task`/`produces`/
`step_name` (the YAML string **or `nil` when unnamed**, → `StepResult.name`)/`context_format`/`upstream`
(ordered `[{:step_id, yaml_name}]`, the `depends_on` set)/`consumes` (producer YAML names, for artifact
context — also wired as `arguments` in dag mode). `arguments` is keyed by upstream `:step_id` →
`%StepResult{}` + `:extra_context`. Reconstruct **two result lists** from `arguments`: the
dependency/preceding results (from `options[:upstream]`, the `depends_on` set — for
`ContextBuilder.format_for_deps/3` in dag mode or `format_preceding_all/2` in sequential) **and** the
producer/artifact results (from `options[:consumes]` — for `format_artifact_context/3`, so downstream
steps see upstream artifacts, preserving `plan_workflow.ex:328` / `iterative_workflow.ex:236`). Both are
present in `arguments` now that `consumes` is wired as an argument edge. Inject produces +
`arguments.extra_context`; call `AgentRunner`. Returns `{:ok, %StepResult{}}`.

### `JidoClaw.Skills.Steps.IterativeStep` (`use Reactor.Step`)
Ports `iterative_workflow.ex` — `extract_roles/1`, `parse_verdict/1` (typed `%{verdict: :pass}` +
legacy `VERDICT: PASS|FAIL`), `cap_result/2`, `max_iterations` (default 3), **and its
`format_artifact_context/3` feedback path (`iterative_workflow.ex:236`)** — using `AgentRunner` for the
gen/eval spawns. Returns `{:ok, [gen_result, eval_result]}`.

## Modified modules

### `lib/jido_claw/orchestration/reactor_middleware.ex`
- **Result persistence (closes a regression):** today `complete/2` appends `run_completed` with `%{}`
  (`reactor_middleware.ex:128`), so `WorkflowRun.result` is always nil — but the *cron* path today
  persists `build_result` into `run_completed` (`workflow_runner.ex:159,182`). To not regress, extend
  `complete/2` to store `payload = %{result: result}` **only when `result` passes a recursive
  `json_safe?/1` guard** (binary/number/boolean/nil; lists thereof; maps with binary/atom keys and
  json-safe values — **no structs, tuples, pids, refs, funs**), else `%{}`. A bare `is_map and not
  is_struct` check is **insufficient**: `Transcript.redact/1` recurses but leaves non-JSON terms
  unchanged (`transcript.ex:64`), so a dev reactor returning `%{workspace: %Workspace{}}` (or a tuple
  value) would persist and then blow up on JSON encode. The CollectStep build_result map
  (strings/ints/nil) passes the guard; dev reactors returning Ash structs don't → stored `%{}` (still
  nil, no change). Then `Transcript.redact` (in `WorkflowEvent.Changes.Allocate`) scrubs it; the
  projection already maps `payload[:result]` → `WorkflowRun.result` (`projection.ex`
  `status_attrs(:run_completed, …)`).
- **Run-lifecycle broadcasts move here (fixes the timing race — see C-DASHBOARD):** after each
  **durable append** succeeds, broadcast via `RunPubSub`: `init/1` (initial-start branch only, after
  `run_started`) → `{:run_started, run.id, …}`; `complete/2` → `{:run_completed, …}`; `error/2` →
  `{:run_failed, …}`. Firing *after* the append means `run_started` only emits once the run is
  `:running`, never while still `:pending`. (Resume's `run_resumed` doesn't broadcast — `Cases.decide`
  already emits `{:gate_resolved, …}`.) The runner's terminal **backstop** also broadcasts `run_failed`
  (see ReactorRunner) — mutually exclusive with `error/2` via the non-terminal guard, so no double-fire.

### `lib/jido_claw/orchestration/reactor_runner.ex`
- **Ungated struct support (explicitly scoped):** accept a `%Reactor{}` struct for **compiled skills,
  which never halt** (no `GateStep`). Branch in `run/3` + `build_runnable/1` (struct path skips
  `Spark.Dsl.is?`; adds middleware via the existing membership-dedup check). For structs,
  `reactor:` context = the `:name` opt and `finalize_opts[:reactor_module] = nil`. A `{:halted,_}`
  from a struct is **out of scope**: it falls through `finalize/3`'s existing defensive
  `:unexpected_halt` → fail-with-audit. **This is not general struct support** — gated struct
  reactors would need checkpoint-identity design (the resume allowlist keys on a *module* name) and
  are a separate future item.
- New opts: **`:async?`** (default `false`; skills pass `true`) threaded into `Reactor.run/4`;
  **`:context`** (extra map merged into the base context — **base wins** so
  `tenant`/`actor`/`workflow_run`/`reactor` can't be clobbered).
- **Backstop broadcast only:** normal lifecycle broadcasts live in the middleware, but the runner
  still appends `run_failed` in backstop paths *after* `Reactor.run/4` returns — for failures **before
  `ReactorMiddleware.init/1`** (e.g. input validation, `executor.ex:69`) where `error/2` never fired,
  which would otherwise leave dashboard subscribers blind to the terminal failure. Broadcast
  `{:run_failed, …}` from `append_failed/3` **only when it actually writes** the backstop terminal.
  `ensure_failed` appends only when the run is still non-terminal (i.e. the middleware didn't
  terminalize), so this is mutually exclusive with the middleware's `error/2` — no double-fire.
  `broadcast_gate` stays as-is (only *after* the checkpoint persists).

### `lib/jido_claw/tools/run_skill.ex`
Replace the 3-arm driver dispatch (`run_skill.ex:67-95`) with: `Skills.get` → `Compiler.compile` →
`ReactorRunner.run(reactor, %{extra_context: ctx || ""}, tenant:, actor:, name: skill.name, async?: true, context: scope)`
→ return the reactor's value (the CollectStep result map) on `{:ok, value, _run}`. Gains a
`WorkflowRun` row. tenant from `tool_context.tenant_id`; actor from `tool_context.actor` falling back to
`Actor.system(tenant_id)`. **Never call `Actor.system(nil)`** — if `tenant_id` is missing after
`MCPScope.wrap/4`, resolve the default tenant explicitly or return a clean `{:error, :missing_tenant}`
(**verify-during-impl**: confirm `tool_context` reliably carries `tenant_id`; `scope_context/1` already
plucks it). Keep `scope_context/1` (test seam); **remove** `build_result/2`
(moved to `Skills.Result`). Update the moduledoc + the description string (`run_skill.ex:19`
"via a Workflow FSM").

### `lib/jido_claw/orchestration/workflow_runner.ex` (cron adapter)
Rewrite `run/1` to a thin adapter: `Skills.get(state.workflow_name, …)` → `Compiler.compile` →
extract `extra_context = Map.get(workflow_input, "context", "")` (a **string**, matching today's
`workflow_runner.ex:147`; the `extra_context` input must be a string for `ContextBuilder.build_task/4`,
not the raw input map) →
`ReactorRunner.run(reactor, %{extra_context: extra_context}, tenant: <from the tenant-scoped job>,
actor: Actor.system(tenant_id), name: skill.name, async?: true, context: %{workspace_id:
"cron:#{state.id}:#{System.unique_integer([:positive])}", project_dir: …})`. Map the envelope →
`:ok | {:error, term()}`. **Delete** `dispatch/4`, `create_and_start/4`, `finalize_complete/3`,
`finalize_fail/3`, the three driver aliases, and the direct `build_result` call (now in CollectStep,
persisted by the middleware). Keep the module name + `run(state)` contract so the `:cron_workflow_runner`
seam (`platform/cron/dispatcher.ex:81`) and `dispatcher_test`'s `StubRunner` are unaffected. No
broadcasts here (middleware emits them).

### Moduledoc / comment updates (keep `compile_check` warning-free)
`reason.ex:8`, `reactor_runner.ex` moduledoc (refs `WorkflowRunner`), `reactor_middleware.ex`
moduledoc, `web/live/dashboard_live.ex:97`, `workflows/context_builder.ex:23,44,61`,
`workflows/step_normalizer.ex:13-14`, `conversations/subagent_transcript.ex:17,93`,
`reasoning/output.ex:8`.

### System prompt (accuracy, not gated)
Update the `run_skill`/skills prose in `priv/defaults/system_prompt.md` **and** `.jido/system_prompt.md`
(replace "Workflow FSM"/driver language with "compiled to a Reactor; each run is a durable
WorkflowRun"). `mix jidoclaw.system_prompt.check` only pins the `## Tool Catalog (N tools)` count +
`**name**` headers — `run_skill` stays registered, so the count is unchanged and the check passes.
Refresh `.jido/.system_prompt.sync` if the sync task flags drift.

## Deletions
- `lib/jido_claw/workflows/iterative_workflow.ex`, `plan_workflow.ex`, `skill_workflow.ex`, `step_action.ex`.
- **Keep** (still used): `workflows/context_builder.ex`, `step_result.ex`, `step_normalizer.ex`
  (consumed by `platform/skills.ex`), `platform/skills.ex`, all `.jido/skills/*.yaml` (schema unchanged).

## Key Reactor 1.0.2 corrections (validated against `deps/reactor/`)

- **C-NAMES** *(critical)* — `Reactor.Argument.from_result/3` and `add_step` names require **atoms**
  (`argument.ex:100`), and the planner **raises** for a `from_result` to a non-existent step
  (`planner.ex:114`). Skill step names are **strings by design**. **Never `String.to_atom/1` on YAML**
  (atom-table leak). Generate positional internal atom ids (`:step_1`, …) for all Reactor names/args;
  keep YAML strings as display/dependency metadata in step options; resolve `depends_on` through a
  `%{yaml_name => :step_id}` index. Validate duplicate **non-nil** YAML names (unnamed sequential steps
  use positional display fallbacks, so they don't collide).
- **C-RESULT** *(critical — regression)* — the reactor's return value must reach `WorkflowRun.result`.
  Solved by the `CollectStep` (returns a JSON-safe `build_result` map) + the middleware `complete/2`
  capturing returns that pass a recursive **`json_safe?/1`** guard (not a bare `is_map` — see the
  middleware bullet) into the `run_completed` payload. `Reactor.Step.ReturnAllArguments`
  returns an *unordered* map, so ordering is owned by `CollectStep` (configured with the step order),
  not pushed to callers. `CollectStep` depends on **every** agent step (not just leaves) so no result
  is dropped.
- **C-COLLECT** — the middleware logs every Reactor step event (`reactor_middleware.ex:167`), so the
  synthetic `:__collect__` step emits its own `step_started`/`step_completed`. **Decision: don't filter
  it** (keeps the middleware free of skill-internal coupling); tests/UI **expect** it, and
  `steps_completed` is counted by `CollectStep` from agent results — so the user-facing count is
  unaffected by the infra step's presence. (Filtering by a `__`-prefix convention is a trivial
  follow-up if dashboard noise matters.)
- **C-DASHBOARD** *(critical — regression + timing)* — `WorkflowLog.append`/`ReactorMiddleware` don't
  broadcast today (`workflow_log.ex:93`); only the deleted `WorkflowRunner` did. Re-home lifecycle
  broadcasts to the **middleware, fired after the durable append** — never right after
  `WorkflowRun.create` (which would race the dashboard to a still-`:pending` run).
- **C-RETRIES** *(critical)* — `max_retries` **defaults to 100** (`builder/step.ex:27`); the current
  drivers never retry. **Set `max_retries: 0`** on every agent step (the 5th `add_step` arg).
- **C-MIDDLEWARE** — `Builder.add_middleware/2` **errors if already present** (`builder.ex:298`); not
  idempotent. The Compiler must **not** add it — `ReactorRunner.build_runnable/1` is the sole wirer.
- **C-IMPL** — step business config goes in the **impl tuple** `{AgentStep, [template:, …]}` (arrives
  as `run/3`'s 3rd arg). The 5th `add_step` arg is Spark-validated, accepting only
  `async?`/`max_retries`/`guards`/`context`/`ref` (`builder/step.ex:91`).
- **C-SANDBOX** — two reasons a test needs `Sandbox.start_owner!(Repo, shared: true)` (the established
  `scope_propagation_test.exs:16` pattern): (1) `async?: true` runs steps on `Reactor.TaskSupervisor`
  (non-owner processes); (2) **`AgentRunner` always writes** via `SubagentTranscript.record_task`/
  `record_terminal` + child-correlation, so *any* test executing `AgentRunner` with real tenant/session
  UUIDs hits the DB from spawned processes — even FakeAgentServer-stubbed ones. Only **pure
  compiler-build tests** (construct the `%Reactor{}`, never run it) can skip shared sandbox.

## Test changes
- **ADD:** `test/jido_claw/skills/compiler_test.exs` — pure: inputs declared, atom-ids generated
  (no YAML atomization), `max_retries: 0`, no middleware added, **`:__collect__` depends on every
  agent step**, duplicate-name/missing-dep/cycle → `{:error,_}`; **compile every committed
  `.jido/skills/*.yaml`** (incl. the unnamed-sequential
  `.jido/skills/refactor_safe.yaml` — confirmed still on disk — *and* the dag/iterative skills) and
  assert each yields a valid runnable reactor. Plus `collect_step_test`/`skills_result_test` (ports
  the `build_result` label tests — incl. unnamed step → `template` label), `agent_step_test`,
  `iterative_step_test`, `agent_runner_test`, `compiler_integration_test`. Also a **`json_safe?/1`
  unit test** (in `reactor_middleware_test`, where the guard lives): **rejects** a map containing a
  tuple/struct/pid, **accepts** the `CollectStep` build_result map — pins the persistence boundary.
- **`compiler_integration_test`** (shared sandbox, EchoStub agents) asserts, for all three modes, that
  every spawned child agent's `tool_context` receives the **full scope set** — `tenant_id`, `actor`,
  `session_uuid`, `workspace_uuid`, and a **shared `workspace_id` across steps** — preserving
  `StepAction.resolve_scope/3` semantics. Also assert **all step results accumulate** (`steps_completed`
  equals the agent-step count, *not* `1` for a sequential skill and *not* inflated by `:__collect__`),
  **result persistence** (`WorkflowRun.result` is the build_result map), and **broadcast timing** (a
  subscriber sees `run_started` only once status is `:running`, then `run_completed`).
- **DELETE + PORT:** `workflows/iterative_workflow_test.exs` → `iterative_step_test.exs` +
  `skills_result_test.exs`; `workflows/step_action_test.exs` → `agent_runner_test.exs` (resolve_scope,
  child-correlation, forward_context, FakeAgentServer cases); `workflows/scope_propagation_test.exs` →
  `compiler_integration_test.exs`.
- **REWRITE:** `orchestration/workflow_runner_test.exs` — re-express the 5 behaviors (success→completed,
  error→failed, raise→failed-not-stranded, unexpected-return→failed, unknown-skill→no-run) through the
  adapter; assert the timeline now includes `step_*` events and that `WorkflowRun.result` is populated.
- **KEEP:** `workflows/context_builder_test.exs`, `workflows/step_normalizer_test.exs`,
  `tools/run_skill_test.exs` (`scope_context/1`), `cron/dispatcher_test.exs` (StubRunner `run/1`
  contract unchanged), `mcp_server_test.exs:101`, `prompt_test.exs:228-232`.
- **VERIFY:** `web/live/dashboard_live_test.exs` still passes (broadcasts now from the middleware, same
  topic/shape); confirm **no** existing reactor test (`reactor_middleware_test`, `reactor_runner_test`,
  `project_registration_test`, `human_gates_test`) does `refute_receive` on run-lifecycle broadcasts —
  the new broadcasts are additive.
- **Canonical setup:** `use JidoClaw.TenantCase, async: false` + `seed_tenant/1` + `actor_for/1`; agent
  stubs via `:agent_templates_override` (EchoStub) and `:step_agent_server` (FakeAgentServer).

## Build order (keeps the tree compiling at each boundary; one deliverable)
1. `AgentRunner` + `AgentStep` + `IterativeStep` + `CollectStep` + `Skills.Result` (+ their tests).
   Old `StepAction` stays put.
2. `Skills.Compiler` (atom-id mapping, dep/cycle/duplicate validation, returns `{:ok, %Reactor{}}`) +
   `compiler_test` over the committed skills.
3. `ReactorMiddleware` changes (result capture in `complete/2`; lifecycle broadcasts after append) +
   `ReactorRunner` ungated-struct support + `:async?`/`:context` opts (+ tests).
4. `run_skill` rewrite (+ tests; verify tenant/actor path).
5. cron `WorkflowRunner` rewrite to thin adapter (+ rewrite `workflow_runner_test`).
6. **Delete** the 3 drivers + `StepAction`; port/delete their tests; update all moduledocs + system prompt.
7. Run `mix precommit` to green.

Steps 1–5 leave the old drivers in place but unused on the chat path; only step 6 cuts them, so every
boundary compiles.

## Precommit surface (`mix precommit` = the bar for "done")
Runs (`mix.exs:245-254`): `jidoclaw.compile_check` · `jidoclaw.system_prompt.check` ·
`deps.unlock --unused` · `format` · `reach.check --arch --smells --strict` · `credo --strict` ·
`dialyzer --format short` · `test` (`ash.setup --quiet` first).

- **compile_check** (zero non-allowlisted warnings) — fix every moduledoc/alias ref to a deleted
  module (list above). Don't touch the 3-entry allowlist (`lib/mix/tasks/jidoclaw.compile_check.ex:26-39`).
- **system_prompt.check** — passes untouched (`run_skill` stays; count/names unchanged).
- **reach/bare_rescue** — `AgentRunner` needs `# reach:disable-next-line bare_rescue` (ported);
  `ReactorRunner`'s file-level pragma already covers the widened `run/3`; `Compiler`/`CollectStep` use
  `with`-chains (no rescue).
- **dialyzer** — new `Reactor.Step` modules: `@spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
  {:ok, term()} | {:error, term()}`; `{:ok, %StepResult{}}`/`{:ok, map}`/`{:error, binary}` all satisfy it.
- **test** — full suite green, including the new skill tests and the rewritten workflow_runner test.

## Verification (end-to-end)
1. `mix precommit` green (the completion bar).
2. **Chat path** (Tidewave `project_eval` or REPL): run a DAG skill (`full_review`) via `run_skill`;
   confirm (a) a `WorkflowRun` row exists with a **non-nil `result`** (the build_result map), (b) its
   `WorkflowEvent` timeline is `run_started → step_started/step_completed per agent step + the
   `:__collect__` step → run_completed` projecting to `:completed` (and `result.steps_completed` counts
   only agent steps), (c) the two independent steps ran **concurrently** (`async?: true`), (d) `/workflows`
   dashboard shows the run, and `run_started` appears only once status is `:running`.
3. **Failure path:** force a step `{:error,_}` (stub agent) → assert `step_failed` + `run_failed`,
   status `:failed`, and (C-RETRIES) the step ran **once**, not 100×.
4. **Iterative:** run `iterative_feature`; the gen/eval loop caps at `max_iterations`, a `:pass` verdict
   stops early; result map matches `Skills.Result.build/2`.
5. **Sequential:** compile + run `refactor_safe` (unnamed sequential) — steps run in order, each sees
   full preceding history, shared `workspace_id`.
6. **Cron path:** schedule a `target: :workflow` job, tick it; it creates a run, executes the compiled
   reactor, persists `result`, and broadcasts to the dashboard.
7. **Tenant isolation:** a skill run's events are readable only within its tenant.

## Open risks / verify-during-impl
- **tenant/actor in `run_skill` tool_context** — the rewritten chat path now requires them for
  `ReactorRunner`. Confirm reliably present (fallback `Actor.system/1` + default-tenant resolution).
  The single real integration risk; everything else is mechanical.
- **`async?: true` + synchronous middleware** — correct (serializes step-event appends on the per-run
  `FOR UPDATE` lock; no deadlock). The async event-`Writer` (REACTOR-ADOPTION open Q#7) stays a
  **deferred performance** follow-up, not required for Phase 3.
- **Phase 4** (replay/fingerprint/recovery polish) and **Phase 5** (read-models) remain after this.
