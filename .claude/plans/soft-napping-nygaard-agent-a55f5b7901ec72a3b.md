# Phase 3 — Skills on Reactor: Design Validation

Validated against reactor 1.0.2 source under deps/reactor/lib and the named project files.
Verdict: the design is sound with THREE required corrections (C1–C3) and several footgun
mitigations (F1–F9). The single-step iterative port is the right call.

## Reactor 1.0.2 API — confirmed facts
- `Reactor.run/4` accepts a `%Reactor{}` struct when `reactor.state in [:pending,:halted]` (reactor.ex:223). Builder.new/0 produces a struct with state `:pending` (the struct default). CONFIRMED.
- `Reactor.Builder.add_step(reactor, name, impl, arguments \\ [], options \\ [])`; impl may be `{Module, opts}` (builder/step.ex:221 `assert_is_step_impl({impl, opts})`). Options for the step go in the 5th arg keyword (async?, max_retries, context, guards, ref) — NOT inside the impl tuple. The impl-tuple `opts` arrive as the 3rd arg of `run/3`. CONFIRMED (step.ex:279-281, builder/step.ex:117).
- `Reactor.Argument.from_result/2,3`, `from_input/2,3`, `from_value/2,3` build `%Argument{}` structs; `add_step` accepts a list of these. CONFIRMED (argument.ex).
- `Reactor.Step.ReturnAllArguments.run/3` returns `{:ok, arguments_map}` — keys are the argument NAMES (atoms), values are the referenced step results. CONFIRMED (return_all_arguments.ex).
- Input validation (executor/init.ex:53) uses `MapSet.subset?(valid_input_names, provided)` + `Map.take` — declared inputs must be PROVIDED; EXTRA provided keys are dropped, not rejected. So a single `:extra_context` input is sound, and passing `%{extra_context: ctx}` satisfies it. CONFIRMED.
- Planner (planner.ex:101-122): a `from_result` arg referencing a NON-EXISTENT step name raises `PlanError` "cannot be found". Cycle check via `assert_graph_not_cyclic` (planner.ex:197). A step referenced only as a *dependency target* (others point to it) is a normal vertex — fine.
- `build_context` (step_runner.ex:478-489) does `deep_merge(step.context, reactor.context)` then merges current_step/etc. So `reactor.context` (tenant, actor, workflow_run, reactor) IS visible to every step's run/3 AND event/3. CONFIRMED.
- Step events `{:run_start,..}`/`{:run_complete,..}`/`{:run_error,..}` fire INSIDE `do_run` (step_runner.ex:166/180), which runs in the STEP's process — the async Task process when async (async.ex:66 `Task.Supervisor.async_nolink`). DECISIVE for sandbox + lock analysis.
- `async?: false` => `max_concurrency: 0`, everything runs in the caller process (state.ex:75). `async?: true` => steps run on `Reactor.TaskSupervisor` PartitionSupervisor. Default per-step `async?: true` (builder/step.ex:20).
- `run_id` defaults to `make_ref()` if not set (state.ex:92-98); ReactorRunner passes `run.id`. Fine.

## Required corrections

### C1 — Builder step impl options carry data; do NOT put step config in `add_step`'s 5th arg
The design says "options carry template/task/produces/step_name + :context_format hint". CORRECT
mechanism: pass them as the impl-tuple second element `{AgentStep, [template: .., task: .., produces: .., step_name: .., context_format: :preceding|:deps]}`. They arrive as `run/3`'s 3rd arg `options`. The 5th `add_step` arg (`options`) is reserved for `async?`, `max_retries`, `guards`, `context`, `ref` — putting business data there is wrong (Spark.Options.validate rejects unknown keys, builder/step.ex:91).

### C2 — Sequential ordering: use `from_result` args, NOT `wait_for`; synthesize names always
For sequential, naming unnamed steps `step_1..step_N` is MANDATORY (planner requires real names for any `from_result`). Each step N gets `from_result(:"prior_<k>", :"step_k")` for every k<N. This both (a) feeds AgentStep the full preceding history (matching SkillWorkflow.format_preceding_all) and (b) creates the linear dependency edges, so Reactor runs them in order even under `async?: true` (a step with N-1 deps can't start until all complete). You do NOT need `wait_for`. NOTE: argument NAMES must be unique atoms per step; reference them in AgentStep by collecting `arguments |> Map.values()` (they are `%StepResult{}` values), then sort into declared order using the step_name embedded in each StepResult.

### C3 — ReactorMiddleware async-safety MUST be addressed before skills run async
The middleware's moduledoc (reactor_middleware.ex:38-44) explicitly says it is synchronous and that "the async step-timeline Writer is a deferred follow-up for the first concurrent producer (the skills->Reactor compiler)." THIS DESIGN IS THAT PRODUCER. With `async?: true`, `event/3` runs in each async Task process and calls `WorkflowLog.append` synchronously, each taking the per-run `FOR UPDATE` lock (WorkflowEvent.Changes.Allocate). Analysis: this SERIALIZES, does not deadlock (single lock target = the run row; no lock-ordering inversion; each append is a short autonomous tx). But two real problems remain:
  - (a) Contention/latency: in a wide parallel phase (e.g. full_review's run_tests+review_code), both steps' step_started/step_completed serialize on the row lock. Acceptable for the step counts here (2–5), but it is real.
  - (b) Sandbox (see F2): the append runs in a non-owner Task process.
  Decision: ship `async?: true` for skills with the SYNCHRONOUS middleware for now (serialization is correct, just not maximally concurrent), OR run skills `async?: false` to sidestep both (a) and (b) entirely — sequential/dag step *fan-out* is then lost but every existing skill has ≤5 steps and the agent spawn dominates latency, not the orchestration. RECOMMENDATION: default skills to `async?: false` for the first cut (zero new concurrency surface, no sandbox change, middleware unchanged), and make `async?` an opt the compiler/runner threads so a later commit can flip dag/iterative to true once the async Writer lands. This de-risks the "Done when every skill runs through Reactor" bar.

## Exact Builder call sequences

### debug_issue (sequential — but note: it actually has name+depends_on so execution_mode/1 returns :dag!)
FLAW F5: `debug_issue` in skills.ex:142 HAS `name:` and `depends_on:` on every step, so `Skills.execution_mode/1` (skills.ex:336 via has_dag_steps?) returns `:dag`, NOT `:sequential`. A genuinely sequential skill is one with NO name and NO depends_on (e.g. the legacy 2-step `full_review` doc example, or a hand-built test skill). Pick a real sequential example: NONE of the shipped .jido defaults are sequential except via the bare-template form. Use a synthetic 2-step sequential skill for the compiler test, and treat debug_issue as a DAG (linear chain) example.

Sequential (2 unnamed steps), pseudo:
```
{:ok, r}  = Builder.new()
{:ok, r}  = Builder.add_input(r, :extra_context)
{:ok, r}  = Builder.add_step(r, :step_1,
              {AgentStep, [template: "researcher", task: "...", produces: nil,
                           step_name: "step_1", context_format: :preceding]},
              [Argument.from_input(:extra_context, :extra_context)],
              async?: false)
{:ok, r}  = Builder.add_step(r, :step_2,
              {AgentStep, [template: "coder", task: "...", produces: nil,
                           step_name: "step_2", context_format: :preceding]},
              [Argument.from_input(:extra_context, :extra_context),
               Argument.from_result(:prior_1, :step_1)],
              async?: false)
{:ok, r}  = Builder.add_step(r, :__collect__, Reactor.Step.ReturnAllArguments,
              [Argument.from_result(:step_1, :step_1),
               Argument.from_result(:step_2, :step_2)],
              async?: false)
{:ok, r}  = Builder.add_middleware(r, ReactorMiddleware)   # or let ReactorRunner wire it
{:ok, r}  = Builder.return(r, :__collect__)
```
Terminal returns `%{step_1: %StepResult{}, step_2: %StepResult{}}`.

### full_review (dag: run_tests, review_code, synthesize depends_on [run_tests, review_code])
```
{:ok, r} = Builder.new()
{:ok, r} = Builder.add_input(r, :extra_context)
{:ok, r} = Builder.add_step(r, :run_tests,
             {AgentStep, [template: "test_runner", task: "...", produces: nil,
                          step_name: "run_tests", context_format: :deps]},
             [Argument.from_input(:extra_context, :extra_context)], async?: false)
{:ok, r} = Builder.add_step(r, :review_code,
             {AgentStep, [template: "reviewer", task: "...", produces: nil,
                          step_name: "review_code", context_format: :deps]},
             [Argument.from_input(:extra_context, :extra_context)], async?: false)
{:ok, r} = Builder.add_step(r, :synthesize,
             {AgentStep, [template: "docs_writer", task: "...", produces: nil,
                          step_name: "synthesize", context_format: :deps]},
             [Argument.from_input(:extra_context, :extra_context),
              Argument.from_result(:run_tests, :run_tests),
              Argument.from_result(:review_code, :review_code)], async?: false)
{:ok, r} = Builder.add_step(r, :__collect__, Reactor.Step.ReturnAllArguments,
             [Argument.from_result(:run_tests, :run_tests),
              Argument.from_result(:review_code, :review_code),
              Argument.from_result(:synthesize, :synthesize)], async?: false)
{:ok, r} = Builder.return(r, :__collect__)
```
Reactor resolves topology natively (replaces PlanWorkflow's Kahn). For `context_format: :deps`, AgentStep must know which arg names are deps vs the extra_context input — embed the depends_on list in the impl opts so it filters `arguments` to dep results, then calls `ContextBuilder.format_for_deps(dep_results, depends_on)`. ARTIFACT context (`format_artifact_context`) needs the producer steps' `produces` maps + the dep StepResults; pass the relevant producers' static produces via opts OR (cleaner) attach `produces` into each StepResult upstream and let format_artifact_section read `.artifacts` only. Verify parity with PlanWorkflow.execute_step (plan_workflow.ex:329-335): it builds dep_context + artifact_context + build_task. Match exactly.

### iterative_feature (single IterativeStep)
```
{:ok, r} = Builder.new()
{:ok, r} = Builder.add_input(r, :extra_context)
{:ok, r} = Builder.add_step(r, :iterate,
             {IterativeStep, [skill: skill_struct, max_iterations: 5]},
             [Argument.from_input(:extra_context, :extra_context)], async?: false)
{:ok, r} = Builder.return(r, :iterate)
```
IterativeStep.run(%{extra_context: ctx}, context, opts) ports IterativeWorkflow.iterate/5 verbatim
using AgentRunner for gen/eval spawns; returns `{:ok, [gen, eval]}`. NO ReturnAllArguments needed (single step is already the return). The whole loop runs inside one step process — `async?` is irrelevant for the loop itself. CORRECT rejection of `recurse/5`: builder/recurse.ex requires an atom module inner reactor and IO-shape compatibility (output keys ⊇ input keys), which a gen/eval-with-feedback loop violates.

## Flaw / footgun list

- F1 (CONFIRMED OK) — Single `:extra_context` input reaches every step: each step that needs it declares `from_input(:extra_context)`. The input is validated once (init.ex). No per-step duplication issue. Sound.
- F2 (SANDBOX, MUST HANDLE) — With `async?: true`, AgentStep AND middleware `event/3` run in `Reactor.TaskSupervisor` Task processes that are NOT the test owner. Any DB write (the middleware append; the AgentRunner's SubagentTranscript writes; child-agent correlation rows) requires shared-mode sandbox. The established pattern is exactly `scope_propagation_test.exs:16` `Sandbox.start_owner!(JidoClaw.Repo, shared: true)`. If skills default to `async?: false` (C3 recommendation), the steps run in the CALLER process (the test owner) and NO shared sandbox is needed for the orchestration — only the existing child-agent-spawn shared-sandbox need (which the EchoStub integration tests already satisfy). Either way: any new async skill test MUST be `async: false` + shared owner.
- F3 (CHECKPOINT PATH, CONFIRMED UNREACHABLE) — For ungated skill structs there is NO GateStep, so no step returns `{:halt,_}`; `Reactor.run` returns `{:ok, map}` or `{:error,_}`, never `{:halted,_}`. finalize's `{:halted, reactor}` clause (reactor_runner.ex:242) is therefore never hit for skills, so `handle_gate_pause`/`safe_encode_checkpoint`/`encode_checkpoint` are unreachable. BUT: `safe_encode_checkpoint` does `Keyword.fetch!(opts, :reactor_module)` (reactor_runner.ex:291) — with `reactor_module: nil` for structs this is only reached on a halt, which can't happen. SAFE. Still, set the finalizer's `:reactor_module` to nil for structs and confirm no other code path calls fetch! on it (it doesn't — only the halt path).
- F4 (RESULT ORDERING, MUST HANDLE) — ReturnAllArguments returns a MAP keyed by argument name (unordered). build_result/2 needs the skill's DECLARED step order. Recover it: ReactorRunner returns the map as the run value; run_skill takes the map, and reorders by iterating the skill's normalized steps in order, looking up each by its synthesized/declared name. For iterative, the single step already returns the ordered `[gen, eval]` list — pass it straight to build_result (build_result already handles a list of StepResult). So run_skill needs a small `reorder(skill, value)` that: if value is a list -> use as-is; if a map -> `Enum.map(declared_step_names, &Map.fetch!(value, &1))` (drop the `:__collect__`-internal keys; only map declared step names). The `step_1..N` synthesized names for sequential must be regenerated identically in run_skill OR (cleaner) the Compiler returns BOTH the reactor AND the ordered step-name list as `{:ok, reactor, order}` — RECOMMEND threading the order list out of the compiler to avoid name-derivation drift.
- F5 (NO SHIPPED SEQUENTIAL SKILL) — see above; every .jido default has name+depends_on => :dag, or is iterative. The only sequential path is the bare-template form (no name). Compiler MUST still implement+test sequential (legacy YAML / hand-built skills hit it; SkillWorkflow is the current default for the 2-step doc form). Use a synthetic sequential skill in the compiler test.
- F6 (MISSING-ARG / CYCLE VERIFIERS) — A `from_result` to a non-existent step raises PlanError at run time (planner.ex:114). The compiler MUST guarantee every `depends_on` references a declared step name. PlanWorkflow.validate_deps (plan_workflow.ex:174) does this today; PORT that validation INTO the compiler so a bad YAML returns `{:error, "Undefined dependencies: ..."}` from `compile/1` rather than a raw PlanError from `Reactor.run`. Cycles: planner detects them (acyclic check) — but PlanWorkflow.validate_no_cycles gives a nicer message; port it too for a clean `{:error,_}` from compile.
- F7 (ASYNC + RETRY) — Builder default `max_retries: 100` (builder/step.ex:27). AgentStep/IterativeStep returning `{:error, binary}` would be RETRIED 100x by Reactor! StepAction errors are non-retryable (agent setup failed, step crashed). MUST set `max_retries: 0` on every AgentStep/IterativeStep `add_step` (5th-arg option). This is a real footgun the current drivers don't have (they don't retry). CRITICAL.
- F8 (STEP CRASH SEMANTICS) — StepAction rescues sub-agent crashes into `{:error, binary}` (step_action.ex:86-96). AgentRunner must preserve this (bare-rescue, reach:disable-next-line bare_rescue) so a crashing sub-agent becomes a step `{:error,_}` (which fails the run via the saga) rather than crashing the Task and surfacing as a `RunStepError` exception. With `async?: false` an uncaught raise would also be caught by ReactorRunner.execute/6's rescue, but the per-step transcript terminal row (record_terminal :system) would be lost — so keep the rescue IN AgentRunner.
- F9 (CONTEXT FORMAT PARITY) — sequential uses format_preceding_all (FULL history, chronological); dag uses format_for_deps (deps only) + format_artifact_context. The Reactor arg map is UNORDERED, but AgentStep can reconstruct chronological order for :preceding by sorting the dep StepResults by the step index encoded in their names (step_1..N). For :deps the order within a section is by depends_on list order (format_for_deps filters by MapSet membership; order is prior_results order — match PlanWorkflow which passes acc_results in completion order). Minor: format_for_deps iterates prior_results and filters; pass the dep StepResults in depends_on order to match. Validate against context_builder_test.exs expectations.
- F10 (ASH.REACTOR vs Builder MIDDLEWARE) — ProjectRegistration declares the middleware in its `middlewares do..end` block; ReactorRunner.build_runnable dedups via `ReactorMiddleware in base.middleware` (reactor_runner.ex:168). For a Builder-built struct that does NOT declare it, `add_middleware/2` succeeds. But the design has the Compiler call `add_middleware` AND ReactorRunner ALSO call it — `add_middleware/2` RETURNS AN ERROR if already present (builder.ex:298 assert_unique_middleware). So do NOT add it in BOTH. DECISION: let ReactorRunner be the sole wirer (its dedup check already handles the "already present" case) — the Compiler should NOT add the middleware. This keeps ReactorRunner the single envelope authority (matches its moduledoc) and avoids the double-add error.

## ReactorRunner changes (validated)
- `run/3` currently `@spec run(module(), map(), keyword())`. Widen to `run(module() | Reactor.t(), map(), keyword())`. Branch in `build_runnable/1`: if `is_struct(arg, Reactor)` -> dedup-check + maybe add_middleware on the STRUCT directly (skip `Spark.Dsl.is?`/`reactor_module.reactor()`); else current module path.
- `name` default `inspect(reactor_module)` breaks for structs (no module). For structs require/use the `:name` opt; set `config: %{reactor: name}` and context `reactor: name`. The moduledoc's "reactor never creates the run" invariant holds.
- Add opts: `:async?` (default false) -> thread into `Reactor.run(.., async?: Keyword.get(opts,:async?,false))`. NOTE current hardcode is `async?: false` (reactor_runner.ex:204) — change to read opt. `:context` (extra map) -> `Map.merge(extra, base)` with BASE winning (protect tenant/actor/workflow_run/reactor). Put it in `execute/6`'s context build.
- `:reactor_module` becomes nil for structs in finalize_opts — confirmed unreachable fetch! (F3). Keep `inputs:` in finalize_opts (harmless for the non-halt paths).
- VERIFY: nothing else assumes `reactor_module` is a real module post-run. `finalize {:ok,value}` ignores it; `ensure_failed`/`reload`/`append_failed` use run + tenant/actor only. SAFE.

## run_skill rewrite (validated)
- Compile cached skill -> `{:ok, reactor, order}` (or `{:ok, reactor}` + re-derive order). tenant/actor from tool_context: `tool_context[:tenant_id]` and `tool_context[:actor] || Actor.system(tenant_id)` (mirror MCPScope.actor_for/1, mcp_scope.ex:188). Gains a WorkflowRun row.
- Call `ReactorRunner.run(reactor, %{extra_context: extra_context}, tenant: tid, actor: actor, name: skill.name, async?: false, context: scope_context)`. (async?: false per C3.)
- Envelope is 3-tuple `{:ok, value, run}` | `{:error, reason, run|nil}` — UNWRAP: run_skill must pattern-match the 3-tuple (today it matches `{:ok, results}`/`{:error, reason}` 2-tuples from drivers). value = the result map (dag/seq) or list (iterative).
- reorder(skill, value) -> list of StepResult in declared order (F4) -> build_result/2 (unchanged; already handles StepResult list + legacy tuples).
- EDGE: if tool_context has no tenant_id, ReactorRunner returns `{:error, :missing_required_opt, nil}`. run_skill must surface that as `{:error, _}`. The current callers (agent tool path) always have a tenant in tool_context post-MCPScope; verify the non-tenant test path (mcp_server_test) still passes — it may need a tenant in the scope or the tool returns an error. CHECK mcp_server_test expectations.

## cron WorkflowRunner rewrite (validated)
- Thin `run(state)`: resolve skill -> compile -> ReactorRunner.run with cron scope. `workspace_id = "cron:#{state.id}:#{System.unique_integer([:positive])}"` (was run.id; ReactorRunner owns the run now, so use unique_integer — the existing test asserts only `String.starts_with?(ws, "cron:#{id}:")`, workflow_runner_test.exs:85, so a unique_integer suffix passes). tenant from `state.tenant_id`, `Actor.system(tenant_id)`. context: the cron scope map.
- Map ReactorRunner's 3-tuple envelope -> `:ok | {:error, term()}` (the `run(state)` contract + the `:cron_workflow_runner` seam). `{:ok,_,_}` -> :ok; `{:error, reason, _}` -> `{:error, format_reason(reason)}`.
- DELETE: dispatch/4, create_and_start/4, finalize_complete/finalize_fail, run_executor, broadcast (ReactorMiddleware + RunPubSub broadcasts now come from the run envelope — VERIFY the dashboard still gets run_started/completed; ReactorMiddleware appends events and the projection broadcasts? CHECK RunPubSub broadcast happens from the event append path, else the dashboard loses cron run updates). This is a BEHAVIOR DELTA: the old WorkflowRunner broadcast :run_started/:run_completed/:run_failed explicitly; ReactorMiddleware does NOT broadcast (it only appends events). MUST verify where the LiveView gets its updates — if from RunPubSub on explicit broadcast, the rewrite drops cron dashboard updates. If from WorkflowEvent inserts (PubSub on the event table), it's fine. THIS IS THE BIGGEST HIDDEN RISK — verify before deleting the broadcasts.
- REMOVE the `:cron_workflow_executor` seam (dispatch/4 gone). The dispatcher_test uses `:cron_workflow_runner` (StubRunner with `run(state)`) — that seam STAYS and the StubRunner contract is unchanged. workflow_runner_test uses `:cron_workflow_executor` (StubExecutor.dispatch/4) — that test must be REWRITTEN to stub at the ReactorRunner/skill level or deleted+replaced.

## Test-change map

DELETE:
- test/jido_claw/workflows/iterative_workflow_test.exs — but PORT its pure-function assertions:
  parse_verdict/extract_roles/cap_result -> test/jido_claw/skills/iterative_step_test.exs (these
  functions move to IterativeStep). build_step_params -> drop (internal). execution_mode tests ->
  KEEP (move to a skills_test or keep in a compiler_test; execution_mode stays on JidoClaw.Skills).
  RunSkill.build_result/2 label tests -> KEEP, move to run_skill_test.exs (build_result stays).
- test/jido_claw/workflows/step_action_test.exs — PORT every describe to
  test/jido_claw/skills/agent_runner_test.exs (the core moves to AgentRunner): resolve_scope/3
  (now reads Reactor context), register_child_correlation user_id propagation, forward_context
  policy, run_step_async typed_output capture, all the FakeAgentServer cases. Keep the
  EchoStub/EchoAskStub + `:step_agent_server` override pattern verbatim. (~18k of tests to move.)
- test/jido_claw/workflows/scope_propagation_test.exs — split:
  - resolve_scope/3 unit + scope_context plumbing describes -> agent_runner_test.exs.
  - SkillWorkflow/PlanWorkflow/IterativeWorkflow integration describes -> REWRITE as
    test/jido_claw/skills/compiler_integration_test.exs: compile each mode -> ReactorRunner.run
    (shared-sandbox, EchoStub) -> assert each step's tool_context carries parent scope. The
    parallel-DAG and gen+eval×2 assertions PORT directly (collect N tool_contexts). Keep
    `shared: true` owner (F2).

KEEP (unchanged):
- test/jido_claw/workflows/context_builder_test.exs — ContextBuilder kept.
- test/jido_claw/workflows/step_normalizer_test.exs — StepNormalizer kept.
- test/jido_claw/tools/run_skill_test.exs — scope_context/1 kept; ADD build_result/2 label tests
  ported from iterative_workflow_test; ADD a do_run integration test (compile+run a stub skill).
- test/jido_claw/cron/dispatcher_test.exs — uses `:cron_workflow_runner` StubRunner.run/1; contract
  unchanged. KEEP as-is.

REWRITE:
- test/jido_claw/orchestration/workflow_runner_test.exs — stubbed at `:cron_workflow_executor`
  (dispatch/4) which is DELETED. Rewrite to stub the skill/reactor level OR assert the end-to-end
  WorkflowRun via a stub skill + EchoStub. The 5 behaviors (completed/error/raise/unexpected/unknown)
  must be re-expressed. NOTE: "never stranded :running" + "event_kinds == [:run_started,
  :run_completed]" now come from ReactorMiddleware, so the event-kind assertions may include
  step_* events — UPDATE the expected kind lists (run_started, step_started×N, step_completed×N,
  run_completed). This is a meaningful rewrite.

ADD:
- test/jido_claw/skills/compiler_test.exs — for each mode: compile a representative skill, assert
  the built %Reactor{} has the expected inputs ([:extra_context]), step names (incl synthesized
  step_1..N for sequential, declared names for dag, single :iterate for iterative), the terminal
  return target, ReactorMiddleware NOT added by compiler (F10), max_retries: 0 on agent steps (F7),
  and that bad YAML (missing dep, cycle) returns {:error, _} (F6). Pure — no agent spawn.
- test/jido_claw/skills/agent_step_test.exs — AgentStep.run/3 with a FakeAgentServer: asserts it
  formats dep/preceding context from `arguments`, injects produces, calls AgentRunner, returns
  {:ok, %StepResult{}}; reads scope from Reactor context (tenant->tenant_id, actor).
- test/jido_claw/skills/iterative_step_test.exs — ported pure fns + a loop integration with EchoStub
  (gen+eval, never-PASS -> cap at max_iterations) under shared sandbox.
- test/jido_claw/skills/agent_runner_test.exs — the migrated StepAction core tests.

Canonical setup: `use JidoClaw.TenantCase, async: false` + `seed_tenant/1` + `actor_for/1` for
anything touching WorkflowRun/Ash. EchoStub via `:agent_templates_override`, capture via
`:echo_stub_target`, FakeAgentServer via `:step_agent_server` (rename env to e.g.
`:skill_step_agent_server` IF AgentRunner reads a new key — keep the SAME key to minimize churn).

## Build order (keep tree green at each boundary)

1. **AgentRunner + AgentStep + IterativeStep** (new files; nothing deletes yet). Extract the
   StepAction core into `JidoClaw.Skills.Steps.AgentRunner` (StepAction stays, can even delegate
   to it temporarily to prove parity). Add agent_runner_test + agent_step_test + iterative_step_test.
   Green: nothing removed; new modules + tests compile and pass.
2. **Compiler** (new `JidoClaw.Skills.Compiler`) returning `{:ok, reactor, order}`. Port
   validate_deps + validate_no_cycles for clean errors (F6). Add compiler_test (pure). Green.
3. **ReactorRunner struct support** (widen run/3, build_runnable/1, add :async?/:context opts,
   name-for-structs). Add a small ReactorRunner struct-path test (use a trivial Builder reactor).
   Green: ProjectRegistration module path unchanged; gate tests unchanged.
4. **run_skill rewrite** to compile->ReactorRunner.run->reorder->build_result, unwrap 3-tuple.
   Update run_skill_test (add build_result ported tests + integration). Verify mcp_server_test
   tenant path (may need a tenant in the test's tool_context). Green.
5. **cron WorkflowRunner rewrite** to thin adapter. FIRST verify the dashboard PubSub source
   (event-table PubSub vs explicit broadcast) — if explicit, ADD a broadcast in the new adapter or
   confirm ReactorMiddleware/projection covers it. Rewrite workflow_runner_test. Keep
   `:cron_workflow_runner` seam; dispatcher_test stays green. Green.
6. **DELETE drivers + StepAction** (iterative_workflow.ex, plan_workflow.ex, skill_workflow.ex,
   step_action.ex) and remove their aliases from run_skill/workflow_runner. DELETE/PORT the driver
   tests (iterative_workflow_test, step_action_test, scope_propagation_test integration describes).
   Update moduledocs (precommit surface below). Green: nothing references the deleted modules.

Temporary co-existence: steps 1–5 leave the old drivers in place but UNUSED by run_skill/cron after
step 4–5. Only step 6 deletes them. This keeps every boundary compilable. The one unavoidable
churn cut is workflow_runner_test (step 5) and step_action/scope_propagation tests (step 6), which
must move with their subjects.

## Precommit surface (mix jidoclaw.compile_check — zero non-allowlisted warnings)

Non-test files referencing deleted modules (must update on step 6):
- lib/jido_claw/tools/run_skill.ex — moduledoc lines 3,5,11-13 ("Workflow FSM", "StepAction",
  SkillWorkflow/PlanWorkflow/IterativeWorkflow), aliases lines 43-45, description string line 19
  ("via a Workflow FSM..."). Rewrite to describe Reactor execution. (Step 4 already removes the
  aliases when rewiring.)
- lib/jido_claw/orchestration/workflow_runner.ex — aliases 62-64, dispatch/4 92-93, moduledoc
  ("existing workflow drivers (Skill/Plan/Iterative)"). (Step 5.)
- lib/jido_claw/workflows/context_builder.ex — moduledoc lines 23,44,61 ("Used by PlanWorkflow /
  SkillWorkflow / IterativeWorkflow"). Reword to "Used by skill Reactor steps".
- lib/jido_claw/workflows/step_normalizer.ex — moduledoc lines 13-14 (driver names). Reword to
  "JidoClaw.Skills.Compiler + Steps".
- lib/jido_claw/conversations/subagent_transcript.ex — moduledoc lines 17,93 ("Workflows.StepAction").
  Reword to "Skills.Steps.AgentRunner".
- lib/jido_claw/reasoning/output.ex — moduledoc line 8 ("Workflows.StepAction"). Reword.
- lib/jido_claw/orchestration/reactor_runner.ex — moduledoc line 5 ("skill-DAG producer") — update
  to reflect WorkflowRunner is now a Reactor adapter too. ReactorMiddleware moduledoc lines 38-44
  ("Phase 1 runs async?: false ... deferred follow-up for ... the skills->Reactor compiler") — if
  shipping async?: false for skills, this note still holds; if async?: true, update it.
- dashboard_live.ex — NO direct driver references. CONFIRMED PubSub finding: dashboard_live.ex
  mounts `RunPubSub.subscribe_all()` (line 17) and handles `{:run_started|:run_completed|:run_failed,
  id, info}` (lines 99/104/109). These broadcasts come ONLY from the cron WorkflowRunner's explicit
  `RunPubSub.broadcast` calls (workflow_runner.ex:122/187/213). WorkflowLog.append deliberately does
  NOT broadcast (workflow_log.ex:93). ReactorMiddleware does NOT broadcast. ReactorRunner broadcasts
  ONLY `broadcast_gate` (reactor_runner.ex:265), NOT run lifecycle. => Deleting WorkflowRunner's
  broadcasts WILL drop cron-run dashboard updates. FIX: the rewritten cron adapter MUST re-broadcast
  `:run_started`/`:run_completed`/`:run_failed` (reading the reloaded run from the ReactorRunner
  envelope) — mirror the current broadcast/4 shape so dashboard_live_test + the LiveView keep working.
  (Note: ProjectRegistration-style ReactorRunner runs already DON'T broadcast lifecycle to the
  dashboard — a pre-existing gap; out of scope here, but the cron adapter must not regress cron.)

mix jidoclaw.system_prompt.check: pins ONLY (a) "## Tool Catalog (N tools)" count == tool_modules()
length and (b) `**toolname**` headers == registered names. run_skill STAYS so count + entries are
UNCHANGED — check passes untouched. The "Workflow FSM" PROSE in priv/defaults/system_prompt.md +
.jido/system_prompt.md is NOT pinned by the check (it only scans bold headers + count). prompt_test
line 231 only asserts `prompt =~ "run_skill"`. So updating the FSM prose is OPTIONAL for green, but
RECOMMENDED for accuracy (the run_skill description string at run_skill.ex:19 is rendered into the
prompt and currently says "via a Workflow FSM" — update for truthfulness; no test gates it).

Bare-rescue pragmas (reach:disable):
- AgentRunner: needs `# reach:disable-next-line bare_rescue` on the sub-agent crash rescue (ported
  from step_action.ex:87). REQUIRED (F8).
- Compiler: pure Builder calls; no rescue needed UNLESS you wrap Reactor.Builder errors — prefer
  returning {:error,_} from the with-chain, no bare rescue.
- ReactorRunner: already has file-level `reach:disable-for-this-file bare_rescue` (line 81) — covers
  the widened run/3.

Dialyzer specs for new Reactor.Step modules:
- AgentStep / IterativeStep: `use Reactor.Step` auto-defines can?/async?/nested_steps/backoff. Add
  `@impl true` + `@spec run(Reactor.inputs(), Reactor.context(), keyword()) :: Reactor.Step.run_result()`
  for run/3. run_result is `{:ok, any} | {:ok, any, [Step.t()]} | :retry | {:halt|:error|:retry, any}`
  — returning `{:ok, %StepResult{}}` and `{:error, binary}` both satisfy it. No dialyzer issue.
- Compiler: `@spec compile(JidoClaw.Skills.t()) :: {:ok, Reactor.t(), [String.t()]} | {:error, term()}`.

## Biggest risks (ranked)
1. cron dashboard PubSub (step 5) — CONFIRMED: dashboard_live subscribes to the explicit
   WorkflowRunner `RunPubSub.broadcast` lifecycle events (run_started/completed/failed); neither
   ReactorMiddleware nor ReactorRunner emits them. The cron adapter MUST re-broadcast these three
   after the envelope returns, else cron runs vanish from the dashboard. dashboard_live_test pins it.
2. max_retries default 100 (F7) — without `max_retries: 0`, a failing agent step retries 100x.
3. workflow_runner_test event-kind assertions (F4/middleware) — must expand to include step_* events.
4. Sandbox mode for any async skill test (F2) — defaulting async?: false (C3) removes this risk.
