# Plan: Workflow Enhancements — Context Flow, Iterative Evaluation, Artifact Interaction

## Context

Inspired by Anthropic's "Harness Design for Long-Running Apps" article, this plan enhances JidoClaw's workflow system in three interconnected ways:

1. **Steps currently run in isolation** — prior results are accumulated but never passed to downstream steps (`_ = prior_results` in `plan_workflow.ex:229`, `_context` discarded in `step_action.ex:22`). This means a Reviewer step has no idea what the Coder step just did.
2. **No iteration loops** — skills are single-pass. If the evaluator finds problems, the skill is done. The article demonstrates generator-evaluator loops that iterate until quality passes.
3. **Evaluators can't interact with artifacts** — the Reviewer only reads code/diffs. It can't start a server, hit an endpoint, or run the built thing. The evaluator needs to know *what was built* and *how to interact with it*.

These three changes layer: (1) enables (2) and (3).

---

## Phase A: Context Builder + Wiring Prior Results

### A1. Create `lib/jido_claw/workflows/context_builder.ex`

New module with pure functions for formatting prior step results. All functions return `""` for nil/empty inputs (backward-compatible). All functions accept a `max_chars` option (default 4000) to truncate individual results, appending `\n[truncated]` when exceeded.

- `format_for_deps(prior_results, depends_on, opts \\ [])` — filters step results to only those matching `depends_on` names, formats as structured markdown section. Used by PlanWorkflow. Accepts `%StepResult{}` structs (see A5).
- `format_preceding_all(results, opts \\ [])` — formats ALL prior results (reversed from prepend-style list). Used by SkillWorkflow so later steps can see the full chain, not just the immediately preceding step.
- `format_all(results, opts \\ [])` — formats all results as-is (no reversal). Used by IterativeWorkflow for full feedback history.
- `format_artifact_context(step, all_steps, prior_results)` — looks up `produces` blocks from steps listed in the consumer's `consumes` field, merges with dynamic `artifacts` from `%StepResult{}`, formats artifact metadata. Added in Phase C.
- `build_task(task, extra_context, dep_context, artifact_context)` — pure function that assembles a full task prompt from parts, rejecting empty strings. Extracted so task assembly is unit-testable without spawning agents.

### A2. Modify `lib/jido_claw/workflows/plan_workflow.ex`

**`assign_step_names/1` (line 55)** — two changes:
1. Extract `produces` and `consumes` fields from raw YAML steps
2. **Use strings instead of atoms** for step names and dependency names. Replace `String.to_atom/1` calls at lines 63 and 86 with string comparisons. The `to_atom_dep/1` helper becomes identity for strings. This eliminates the atom table leak risk from user-controlled YAML input.

```elixir
# Before (line 63): String.to_atom(n)
# After: n  (keep as string)

# Before (line 86): String.to_atom(dep)
# After: dep  (keep as string)
```

All downstream code that matches on step names (phase grouping, dep filtering, result lookups) stays string-based.

**`execute_phases/4` (line 167)** — pass `named_steps` through to `execute_phase` and `execute_step` (change arities to /5) so artifact context can look up producer metadata.

**`execute_step/4` (line 209)** — replace `_ = prior_results` with:
- Call `ContextBuilder.format_for_deps(prior_results, step.depends_on)` for dependency context
- Call `ContextBuilder.format_artifact_context(step, named_steps, prior_results)` for artifact context (Phase C)
- Use `ContextBuilder.build_task(task, extra_context, dep_context, artifact_context)` to assemble

**`compute_phases/1` (line 95)** — add cycle detection. Currently `step_depth/4` at line 139 silently returns 0 on cycles. Add a `validate_no_cycles/2` check that detects cycles via the `visiting` set and returns `{:error, "Cyclic dependency detected: step_a -> step_b -> step_a"}`.

### A3. Modify `lib/jido_claw/workflows/skill_workflow.ex`

**`execute_loop/5` (line 78)** — after extracting `template_name` and `task`, call `ContextBuilder.format_preceding_all(results)` and append via `ContextBuilder.build_task/4`. Since `results` is built with `[new | rest]`, `format_preceding_all` reverses the list to present results in chronological order. This gives later steps visibility into the full chain of prior work.

### A4. Per-step shell workspace isolation

**Problem:** `RunCommand` defaults to `workspace_id: "default"` (`run_command.ex:16`). Concurrent steps in a DAG phase share shell state (CWD, env vars).

**Fix in `lib/jido_claw/workflows/step_action.ex`:**
- Generate a unique `workspace_id` per step execution: `"wf_#{tag}"` (the tag is already unique per step)
- Pass it through `tool_context`: `tool_context: %{project_dir: project_dir, workspace_id: workspace_id}`

**Fix in `lib/jido_claw/tools/run_command.ex` (line 22-24):**
- Read `workspace_id` from `context` before falling back to params default:
```elixir
def run(%{command: command} = params, context) do
  timeout = Map.get(params, :timeout, 30_000)
  workspace_id = get_in(context, [:tool_context, :workspace_id]) || Map.get(params, :workspace_id, "default")
```
Backward-compatible: agents spawned outside workflows still use `"default"`.

### A5. Richer internal step result shape

**Problem:** Workflows accumulate `{name, result_text}` tuples (`plan_workflow.ex:231`, `skill_workflow.ex:105`). This discards the `artifacts` map that `StepAction` will produce (Phase C1), making `format_artifact_context/3` unable to access dynamic artifacts.

**Solution:** Define a lightweight struct used internally during workflow execution:

```elixir
# In context_builder.ex or its own file
defmodule JidoClaw.Workflows.StepResult do
  defstruct [:name, :template, :result, artifacts: %{}]
end
```

- **Workflow accumulators** store `%StepResult{}` instead of `{name, text}` tuples
- **ContextBuilder functions** accept `[%StepResult{}]` — `format_for_deps` matches on `.name`, uses `.result` for text and `.artifacts` for dynamic metadata
- **`RunSkill.build_result/2`** converts at the boundary: `Enum.map(results, fn %{name: n, result: r} -> {n, r} end)` — the public output contract stays `[{label, text}]`

This keeps the richer shape internal to execution and converts only at the final output boundary.

---

## Phase B: IterativeWorkflow (Approach B)

### B1. Extend Skills struct and parser

**`lib/jido_claw/platform/skills.ex`**

- Add `:mode` and `:max_iterations` to `defstruct` (line 44):
  ```elixir
  defstruct [:name, :description, :steps, :synthesis, :mode, :max_iterations]
  ```
- Extract them in `parse_skill_file/1` (line 300-308)
- Add `execution_mode/1`:
  ```elixir
  def execution_mode(%__MODULE__{mode: "iterative"}), do: :iterative
  def execution_mode(%__MODULE__{} = skill) do
    if has_dag_steps?(skill), do: :dag, else: :sequential
  end
  ```

### B2. Update RunSkill routing

**`lib/jido_claw/tools/run_skill.ex` (lines 39-44)**

Replace the `if has_dag_steps?` with `case execution_mode(skill)` routing to three executors.

**`build_result/2` (line 60)** — convert `%StepResult{}` structs to `{label, text}` tuples at this boundary (see A5).

### B3. Create `lib/jido_claw/workflows/iterative_workflow.ex`

**`run(skill, extra_context, project_dir)`** — entry point. Extracts generator and evaluator steps by `role` field.

**`extract_roles(skill)`** — finds steps with `role: "generator"` and `role: "evaluator"`. Validates both have `name` fields (required for `consumes` resolution). Returns `{:ok, generator, evaluator}` or `{:error, reason}`.

**`normalize_step(step)`** — extracts `name`, `template`, `task`, `role`, `produces`, `consumes` from raw YAML maps (handling both string and atom keys). All names stay as strings (no atom conversion).

**`iterate/7`** — the core loop:
1. Build generator context: first iteration = extra_context only; subsequent = extra_context + latest evaluator feedback only (clean handoff)
2. Run generator step via `StepAction.run/2`
3. Build evaluator context: generator output + artifact metadata from static `produces` + dynamic `artifacts`
4. Run evaluator step via `StepAction.run/2`
5. Parse verdict
6. On `:pass` -> return final result
7. On `:fail` -> recurse with `iteration + 1`
8. When `iteration > max_iter` -> return last result (graceful cap)

**`parse_verdict(text)`** — regex-based, case-insensitive:
- `~r/VERDICT:\s*PASS/i` -> `:pass`
- `~r/VERDICT:\s*FAIL/i` -> `:fail`
- No match -> `:fail` (conservative default)

### B4. IterativeWorkflow output contract

IterativeWorkflow returns a **curated result list**, not raw history:
- `{:ok, [%StepResult{name: gen_name, ...}, %StepResult{name: eval_name, ...}]}` — always exactly 2 entries
- The generator result is from the final (passing or max-iteration) run
- The evaluator result is from the final evaluation
- `build_result/2` converts to `[{label, text}]` and sees 2 steps, matching the skill definition
- Iteration metadata (count, pass/fail) is embedded in the evaluator's result text naturally

**YAML format for iterative skills:**
```yaml
name: robust_feature
description: Implement with iterative refinement
mode: iterative
max_iterations: 5
steps:
  - name: implement
    role: generator
    template: coder
    task: "Implement the feature following project patterns"
    produces:
      type: elixir_module
      files:
        - "lib/my_app/feature.ex"
        - "test/my_app/feature_test.exs"
      verification_criteria:
        - "All tests pass"
        - "No compiler warnings"
  - name: evaluate
    role: evaluator
    template: verifier
    task: "Verify: run tests, check for warnings, review code quality. End with VERDICT: PASS or VERDICT: FAIL."
    consumes: [implement]
synthesis: "Present final implementation after iterative refinement"
```

---

## Phase C: Artifact Interaction Context

### C1. Structured step result contract + producer-side instruction

**Extend `StepAction` result** to carry structured metadata alongside the text result:
```elixir
%StepResult{name: step_name, template: template_name, result: text, artifacts: %{}}
```

**`extract_artifacts/1`** — if the agent's text output contains a fenced `ARTIFACTS:` block, parse key-value pairs:
```
ARTIFACTS:
url: http://localhost:4000
port: 4000
files: lib/my_app/feature.ex, test/my_app/feature_test.exs
```
Simple key-value parser (not full YAML). Steps without an `ARTIFACTS:` block get `artifacts: %{}`.

**Producer-side prompt injection:** When a step has a `produces` block, `StepAction` (or the workflow executor before calling `StepAction`) appends an output contract to the task prompt:

```
If you discover runtime details (URLs, ports, generated file paths) that differ from the
expected configuration, report them using this format at the end of your response:

ARTIFACTS:
url: <actual URL>
port: <actual port>
files: <comma-separated file paths>
```

This instruction is only appended when `step.produces` is non-nil. Without it, `artifacts: %{}` is the steady state and the `ARTIFACTS:` convention would never fire.

### C2. Create `lib/jido_claw/agent/workers/verifier.ex`

New worker template combining Reviewer's read tools with TestRunner's execution:

- Tools: `ReadFile`, `SearchCode`, `GitDiff`, `GitStatus`, `RunCommand`, `ListDirectory`
- Max iterations: 20 (more tool calls for interactive verification)
- Tool timeout: 60s (server startup may take time)
- Description includes `VERDICT: PASS / VERDICT: FAIL` instruction

### C3. Register verifier across the codebase

Add `"verifier"` to ALL locations that enumerate templates:

| File | Line | Change |
|---|---|---|
| `lib/jido_claw/agent/templates.ex` | 9 | Add entry to `@templates` map |
| `lib/jido_claw/tools/spawn_agent.ex` | 4 | Add `verifier` to description and schema doc strings |
| `lib/jido_claw/platform/jido_md.ex` | 68 | Add `### verifier` section to generated agent template docs |
| `priv/defaults/system_prompt.md` | 106 | Add verifier row to template table + update counts |
| `test/jido_claw/templates_test.exs` | 6 | Add `"verifier"` to `@valid_names`, update count 6->7, add module assertion |
| `test/jido_claw/prompt_test.exs` | 222 | Update "all 6 agent templates" -> "all 7", add `assert prompt =~ "verifier"` |

### C4. Extend ContextBuilder with `format_artifact_context/3`

Accepts `[%StepResult{}]` and the consuming step's `consumes` list. Merges:
- Static `produces` metadata from YAML (type, start_command, url, health_check, files, verification_criteria)
- Dynamic `artifacts` from `%StepResult{}` (runtime-discovered values override static ones)
- The actual step output text

Truncation applies per-section (configurable max_chars).

### C5. Wire artifact context into PlanWorkflow

Already covered in A2: `execute_step` calls `ContextBuilder.format_artifact_context`.

### C6. Wire artifact context into IterativeWorkflow

In `build_evaluator_context`, look up the generator step's `produces` metadata + dynamic `artifacts` from the generator `%StepResult{}`. Format via ContextBuilder and include in the evaluator's task.

### C7. Add default iterative skill YAML + docs

**Scoping for existing workspaces:** `ensure_defaults/1` (`skills.ex:199`) only copies when `.jido/skills/` has no YAML files. `Prompt.ensure/1` and `JidoMd.ensure/1` skip if files already exist. This means existing workspaces will NOT automatically get the new skill or updated docs.

**Decision:** Scope new defaults to fresh workspaces only. For existing workspaces, users can:
- Delete `.jido/skills/` and re-run to get new defaults
- Delete `.jido/JIDO.md` and `.jido/system_prompt.md` to regenerate
- Or manually create `iterative_feature.yaml`

This avoids a migration mechanism that could overwrite user customizations.

Add `iterative_feature.yaml` to `@default_skills` in `skills.ex` and add iterative skill documentation to `system_prompt.md`.

---

## Files Summary

### New files (6)
| File | Purpose |
|---|---|
| `lib/jido_claw/workflows/step_result.ex` | `%StepResult{}` struct (name, template, result, artifacts) |
| `lib/jido_claw/workflows/context_builder.ex` | Shared context formatting with truncation + `build_task` |
| `lib/jido_claw/workflows/iterative_workflow.ex` | Generate-evaluate loop executor |
| `lib/jido_claw/agent/workers/verifier.ex` | Interactive verification worker |
| `test/jido_claw/workflows/context_builder_test.exs` | Unit tests for all formatting + truncation + `build_task` |
| `test/jido_claw/workflows/iterative_workflow_test.exs` | Unit tests (parse_verdict, extract_roles, output contract) |

### Modified files (10)
| File | Change |
|---|---|
| `lib/jido_claw/workflows/plan_workflow.ex` | Wire dep results + artifact context, extend `assign_step_names` with produces/consumes, string-based names (no atoms), thread `named_steps`, add cycle detection, use `%StepResult{}` accumulators |
| `lib/jido_claw/workflows/skill_workflow.ex` | Wire all preceding step results via `format_preceding_all`, use `%StepResult{}` accumulators |
| `lib/jido_claw/workflows/step_action.ex` | Add `workspace_id` to tool_context, return `%StepResult{}`, add `extract_artifacts/1`, inject `ARTIFACTS:` instruction when step has `produces` |
| `lib/jido_claw/tools/run_command.ex` | Read `workspace_id` from `tool_context` before falling back to params default |
| `lib/jido_claw/platform/skills.ex` | Add `:mode`/`:max_iterations` to struct + parser, add `execution_mode/1`, add default iterative skill |
| `lib/jido_claw/tools/run_skill.ex` | 3-way routing via `execution_mode/1`, convert `%StepResult{}` -> `{label, text}` in `build_result/2` |
| `lib/jido_claw/agent/templates.ex` | Add `"verifier"` template entry |
| `lib/jido_claw/tools/spawn_agent.ex` | Add `verifier` to description and schema doc strings |
| `lib/jido_claw/platform/jido_md.ex` | Add verifier section to generated docs |
| `priv/defaults/system_prompt.md` | Add verifier to template table, add iterative skill to skills docs |

### Modified test files (2)
| File | Change |
|---|---|
| `test/jido_claw/templates_test.exs` | Add `"verifier"` to `@valid_names`, update counts 6->7, add module assertion |
| `test/jido_claw/prompt_test.exs` | Update template count assertion, add verifier mention check |

---

## Implementation Order

1. **A5** — StepResult struct (no dependencies, needed by everything else)
2. **A1** — ContextBuilder module (pure functions, depends on StepResult)
3. **A4** — Shell workspace isolation in StepAction + RunCommand
4. **A2** — PlanWorkflow wiring + string names + cycle detection (depends on A1, A5)
5. **A3** — SkillWorkflow wiring (depends on A1, A5)
6. **B1** — Skills struct + parser extension
7. **B2** — RunSkill routing update + `build_result` conversion
8. **B3+B4** — IterativeWorkflow module (depends on A1, A5, B1, B2)
9. **C1** — Structured artifacts in StepAction + producer-side prompt injection
10. **C2+C3** — Verifier worker + registration across codebase
11. **C4** — ContextBuilder artifact extension (format_artifact_context)
12. **C5+C6** — Artifact wiring in PlanWorkflow + IterativeWorkflow
13. **C7** — Default iterative skill YAML + docs
14. **Tests** — context_builder_test (build_task, format_*, truncation), iterative_workflow_test (parse_verdict, extract_roles, output contract), templates_test updates, prompt_test updates, skills parsing/routing tests

---

## Verification

1. **Compile**: `mix compile --warnings-as-errors`
2. **Format**: `mix format --check-formatted`
3. **Existing tests pass**: `mix test` — all existing skills/workflows work unchanged
4. **ContextBuilder unit tests**: `mix test test/jido_claw/workflows/context_builder_test.exs`
   - `build_task/4` — assert exact prompt assembly from parts
   - `format_for_deps/3` — filters by dependency names, uses `%StepResult{}`
   - `format_preceding_all/2` — chronological order, full chain
   - `format_artifact_context/3` — merges static produces + dynamic artifacts
   - Truncation — verify cutoff at max_chars with `[truncated]` marker
5. **IterativeWorkflow unit tests**: `mix test test/jido_claw/workflows/iterative_workflow_test.exs`
   - `parse_verdict/1` — PASS/FAIL/missing cases
   - `extract_roles/1` — valid, missing generator, missing evaluator, missing name fields
   - Output contract — returns exactly 2 `%StepResult{}` entries
6. **Template tests**: `mix test test/jido_claw/templates_test.exs test/jido_claw/prompt_test.exs`
   - Verifier in @valid_names, count=7, correct module
   - Verifier mentioned in generated prompt
7. **Skills parsing**: Verify `execution_mode/1` returns `:iterative`/`:dag`/`:sequential`; verify `parse_skill_file` extracts `mode` and `max_iterations`
8. **Manual — context flow**: Run `implement_feature` skill via `mix jidoclaw`, inspect agent output to confirm Reviewer/TestRunner steps receive Coder's output
9. **Manual — iterative**: Run `iterative_feature` skill, confirm generate-evaluate loop terminates on PASS or max iterations
10. **Manual — templates**: `spawn_agent` with `template: "verifier"`, confirm it spawns and has RunCommand + read tools available
11. **Shell isolation**: Run a DAG skill with parallel RunCommand steps, confirm separate workspace_ids in SessionManager
