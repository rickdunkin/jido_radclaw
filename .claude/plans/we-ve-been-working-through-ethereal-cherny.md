# Post-review fixes for Phase 4 (fingerprint + replay)

## Context

The Phase 4 plan (`please-review-docs-exploration-squidie-f-starry-raven.md`) shipped and a code review flagged two issues. **Both were validated as real bugs** by code-path tracing:

**Finding 1 — iterative skill saga metadata is dropped (safety hole).** `IterativeStep.normalize_step/1` (`lib/jido_claw/skills/steps/iterative_step.ex:243`) strips `retry`/`compensate`/`irreversible` from the generator/evaluator role maps, and `Compiler.build_iterative/1` (`lib/jido_claw/skills/compiler.ex:222-246`) never puts `irreversible:` into the loop step's impl options. Consequences:
- `ReactorMiddleware.irreversible_flag/1` (`reactor_middleware.ex:295-299`) reads `:irreversible` from the step's impl options → never stamps `irreversible` into `step_*` payloads for iterative skills → `Replay`'s irreversible gate (`replay.ex:309-331`, scans `payload["irreversible"] == true`) **never blocks replaying an iterative skill with `irreversible: true`**.
- `retry: step_retry(gen)` / `max_retries: step_retry(gen)` in `build_iterative` always evaluate to `0` because `gen` lost its `:retry` field — a declared generator retry budget is silently dropped.
- `DefinitionFingerprint.canonical_step/1` hashes all three fields for every mode, so the *hash* is sensitive to flags the iterative *runtime* ignores — the asymmetry the review demonstrated.

Note: the compiler moduledoc (`compiler.ex:37-48`) **already claims** the correct behavior ("For an `:iterative` skill the generator's `retry:` budget applies to the whole loop step. `irreversible:` additionally rides into the `step_*` event payloads") — the fix aligns code with documented intent. No middleware/replay changes needed.

**Fingerprint corollary (user review of this plan):** since `compensate` and evaluator `retry` stay deliberately inert for iterative skills, they must not remain fingerprint-semantic there — otherwise `DefinitionFingerprint` violates its own "canonical semantic term mirrors compiler semantics" contract (`definition_fingerprint.ex:25-26`): a no-op edit like adding `compensate:` to the evaluator would trip `:definition_changed`. The iterative canonical term must mirror what the compiler actually consumes (Fix 1c below).

**Finding 2 — dashboard cannot override both replay gates (UI deadlock).** `WorkflowsLive` stores one blocked-reason atom per run (`replay_blocked[run_id]`, `workflows_live.ex:58,67`), the two override buttons are mutually exclusive (`:if={... == :definition_changed}` / `== :irreversible`) and each hardcodes only its own flag (`workflows_live.ex:133-154`), and `replay_opts/2` reads flags only from the inbound click's params. Since `Replay.do_replay/5` checks the definition gate **before** the irreversible gate, a run with both problems ping-pongs forever: force-click → `:irreversible_steps_executed`; replay-anyway-click → `:definition_changed` again. Module-level `Replay.replay/2` with both flags works fine — only the UI can't emit them together.

**Completion bar (per user): `mise exec -- mix precommit` passes.**

## Fix 1 — thread iterative saga metadata (3 files)

Implementation order matters: **1a first** — both 1b and 1c read the `retry`/`irreversible` fields off the role maps that `extract_roles/1` returns.

### 1a — `lib/jido_claw/skills/steps/iterative_step.ex`

`normalize_step/1` additionally preserves:

```elixir
# Saga metadata — preserved so the compiler can thread retry/irreversible
# onto the loop step (values validated by Compiler.validate_step_metadata/1).
retry: Map.get(step, :retry),
irreversible: Map.get(step, :irreversible) == true
```

- `retry` passes through raw — `Compiler.step_retry/1` (`compiler.ex:387-392`) already guards non-integers; single normalization source.
- `irreversible` normalizes to a strict boolean (`== true`), so downstream `or` aggregation is safe even when `extract_roles/1` is called outside `Compiler.compile/1`'s validation.
- `compensate` stays dropped **deliberately**: `IterativeStep` has no cleanup/undo (moduledoc: "the loop declares no cleanup, so it never reports `:undo`"); carrying it would imply support. `depends_on` stays dropped (meaningless for the fixed gen→eval loop).
- Moduledoc: extend the options sentence (line 13-16) to mention `:irreversible` (OR over the role steps); note in `extract_roles/1` @doc which fields role maps carry.

### 1b — `lib/jido_claw/skills/compiler.ex`

In `build_iterative/1`'s impl options (after `retry: step_retry(gen)`):

```elixir
# The loop step is the only execution-tracked unit — re-running it repeats
# every member step's effects, so it is irreversible iff ANY role step is.
irreversible: gen.irreversible or eval.irreversible
```

The existing `retry: step_retry(gen)` / `max_retries: step_retry(gen)` need no edit — they start working once `gen` carries `:retry`. Middleware then stamps `irreversible` into `step_*` payloads and the replay gate fires, all unchanged.

### 1c — `lib/jido_claw/orchestration/definition_fingerprint.ex` (required per plan review)

For iterative skills, fingerprint the **loop semantics** the compiler actually consumes, not the raw step list. Make the `steps:` entry of `canonical_term/1` mode-dispatched (keep `mode_extras/2` carrying `max_iterations` as today):

```elixir
steps: canonical_steps(skill, mode),

# :iterative — mirror the compiler exactly: only the resolved generator and
# evaluator run (IterativeStep.extract_roles/1), the generator's retry budget
# governs the loop, irreversible is OR'd onto the single loop step, and
# compensate / evaluator-retry / depends_on / extra roleless steps / YAML
# step order are all runtime-inert, so fingerprint-inert.
defp canonical_steps(skill, :iterative) do
  case IterativeStep.extract_roles(skill) do
    {:ok, gen, eval} ->
      [
        evaluator: canonical_role(eval),
        generator: canonical_role(gen),
        irreversible: gen.irreversible or eval.irreversible,
        retry: canonical_retry(gen.retry)
      ]

    # Roleless iterative skills never compile (Compiler.validate/3 calls
    # extract_roles), so no run ever stores this hash — but for_skill/1 is
    # pure and total, so fall back to the generic step list.
    {:error, _} -> generic_steps(skill)
  end
end

defp canonical_steps(skill, _graph_mode), do: generic_steps(skill)

defp generic_steps(skill),
  do: skill.steps |> StepNormalizer.normalize() |> Enum.map(&canonical_step/1)
```

- `canonical_role/1` = fixed-order pair list over `consumes` (`canonical_list/1`), `name`, `produces` (`canonical_produces/1`), `role`, `task`, `template` — exactly the fields `IterativeStep.run/3` + `ContextBuilder` consume. No `retry`/`irreversible`/`compensate`/`depends_on` per role.
- Depends on 1a: `gen.retry`/`gen.irreversible`/`eval.irreversible` only exist on the role maps once `normalize_step/1` preserves them. Alias `JidoClaw.Skills.Steps.IterativeStep` (no dep cycle — IterativeStep doesn't reference orchestration).
- **Keep the `:v1` tag.** The iterative term shape change can only *invalidate* old iterative hashes (refusal-safe, `force:` recovers — fine greenfield), never falsely *equate* two definitions: the new keyword shape (`{:evaluator, _}` tuples) cannot collide with the generic shape (a list of pair-lists), and graph-mode terms are untouched. Bumping to `:v2` would needlessly invalidate every dag/sequential run too. Amend the moduledoc's "bump on any algorithm change" sentence accordingly (bump when a change could make different definitions hash equal), and rewrite the "Canonical semantic term" section to document the iterative branch.
- Existing fingerprint tests stay green: the `dag_skill(mode: "iterative")` mode-flip test has roleless steps → falls back to `generic_steps/1` → still differs from `:dag` via the `mode:` entry; the `max_iterations` tests use a proper gen/eval fixture → new path, same equalities.

## Fix 2 — dashboard carries granted overrides forward (1 file)

### `lib/jido_claw/web/live/workflows_live.ex`

**State shape**: `replay_blocked[run_id]` changes from an atom to a map of the latest refusal reason + every flag the *next* click must emit (= flags the failing click carried ∪ the flag for the new refusal):

```elixir
{:error, {:definition_changed, _stored, _current}} ->
  blocked = %{reason: :definition_changed, force: true,
              allow_irreversible: params["allow_irreversible"] == "true"}

{:error, :irreversible_steps_executed} ->
  blocked = %{reason: :irreversible, allow_irreversible: true,
              force: params["force"] == "true"}
```

stored via the existing `update(:replay_blocked, &Map.put(&1, run_id, blocked))`. Success still `Map.delete`s. Deriving carried grants from the failing click's params (not accumulated history) self-corrects stale grants — a plain Replay re-click resets them.

**HEEx** (inside the run comprehension): keep the two buttons and their ids (`replay-force-#{run.id}` / `replay-irreversible-#{run.id}`); switch visibility to `blocked.reason` and add the carried flag — HEEx omits attributes whose value is `false`/`nil`:

```heex
<% blocked = @replay_blocked[run.id] %>
... existing plain Replay button ...
<button :if={blocked && blocked.reason == :definition_changed} ...
  phx-value-force="true"
  phx-value-allow_irreversible={blocked.allow_irreversible && "true"}>Force replay</button>
<button :if={blocked && blocked.reason == :irreversible} ...
  phx-value-allow_irreversible="true"
  phx-value-force={blocked.force && "true"}>Replay anyway</button>
```

**Flash copy**: when the blocked map carries the *other* grant, append it, e.g. irreversible refusal after a force click → `"This run executed irreversible steps — \"Replay anyway\" will repeat them (keeping the definition override)"`. Symmetric suffix for the reverse race (definition edited between clicks).

`replay_opts/2` is untouched (stays param-driven); the handler's `"replay"` clause comment (lines 40-43) gets a sentence about grant carry-forward.

## Tests

### `test/jido_claw/orchestration/definition_fingerprint_test.exs` — iterative loop semantics (per plan review)

Using the existing `iterative_skill/1` fixture helper (steps override per case):
- **generator `retry` changes the hash** (`retry: 2` on gen vs absent → differ).
- **evaluator `retry` is inert** (`retry: 5` on eval vs absent → equal; the generator's budget governs the loop).
- **`compensate` is inert for iterative** (on either role vs absent → equal) — paired with a **contrast case: `compensate` on a `dag_skill` step DOES change the hash** (graph mode runs it via `AgentStep`; currently unpinned anywhere).
- **`irreversible` on either role changes the hash** (gen-true ≠ none; eval-true ≠ none) — and gen-true ≡ eval-true (both OR to the same single loop flag).
- One combined inertness case: swapping gen/eval YAML order, adding `depends_on` to a role, and appending an extra roleless step all hash identically (extract_roles resolves by `role:` field; extra steps never run).

### `test/jido_claw/skills/steps/iterative_step_test.exs` — extend `describe "extract_roles/1"`
- Role maps preserve `retry` and `irreversible` (declare `retry: 2` on generator, `irreversible: true` on evaluator; assert both; assert absent → `retry: nil`, `irreversible: false`). Include a string-keyed step to show `StepNormalizer` canonicalization feeds through.

### `test/jido_claw/skills/compiler_test.exs` — extend `describe "structure"`
- Iterative skill with generator `retry: 2` + evaluator `irreversible: true` → loop step impl options carry `retry: 2`, `irreversible: true`, and the step's `max_retries == 2` (extends the existing test at line 88's pattern). Both-flags-absent → `irreversible: false`, `max_retries == 0`.

### `test/jido_claw/orchestration/replay_test.exs` (house patterns already in file)
1. **THE regression test** (new test in `describe "irreversible gate"`): iterative fixture with `mode: iterative`, `max_iterations: 1`, generator step `irreversible: true`, evaluator step plain. EchoStub returns no VERDICT token → evaluator fails → loop caps at 1 iteration → run completes. Assert: `event(original, :step_started, ctx).payload["irreversible"] == true`; `Replay.replay/2` → `{:error, :irreversible_steps_executed}`; with `allow_irreversible: true` → `{:ok, replayed}`.
2. **Both-gates module-level test**: irreversible single-step fixture, run, then semantic disk edit. `force: true` alone → `{:error, :irreversible_steps_executed}`; `allow_irreversible: true` alone → `{:error, {:definition_changed, _, _}}`; both → `{:ok, run}` stamping the new hash.
3. **Dashboard seam updates** (`describe "dashboard seam (WorkflowsLive)"`):
   - Update line 355's assertion to the new shape: `assert %{reason: :definition_changed} = blocked.assigns.replay_blocked[original.id]`.
   - New bounce test: irreversible fixture + disk edit; click 1 (no flags) → blocked `%{reason: :definition_changed, force: true, allow_irreversible: false}`; click 2 (`%{"force" => "true"}`, what the force button emits) → blocked `%{reason: :irreversible, force: true, allow_irreversible: true}` (force grant carried); click 3 (`%{"force" => "true", "allow_irreversible" => "true"}`, what the armed button now emits) → "Replay launched" flash, block cleared.
   - Render assertion: extend `render_workflows/1` helper to accept `replay_blocked` (default `%{}`); with the click-2 blocked state, the `replay-irreversible-*` button HTML contains **both** `phx-value-force="true"` and `phx-value-allow_irreversible="true"`; with `force: false` it omits `phx-value-force`.

Fixture note: reuse `tmp_project_dir!`/`write_fixture!`/`launch_fixture!` helpers — they take YAML overrides; all fixtures keep `name: replay_fixture` (tmp dirs isolate per test).

## Docs

- `docs/exploration/squidie/REACTOR-ADOPTION.md` §4.7 implementation note: two sentences — the iterative loop step carries `irreversible` OR-aggregated from its generator/evaluator (and the generator's `retry` budget now actually threads), so the replay irreversible gate covers iterative skills; the iterative fingerprint hashes the resolved loop semantics (gen/eval roles, generator retry, OR'd irreversible, max_iterations) rather than the raw step list.
- No AGENTS.md change (MCP tool list/override posture unchanged). Compiler + IterativeStep + DefinitionFingerprint moduledocs per Fix 1.

## Verification

1. Targeted: `mise exec -- mix test test/jido_claw/orchestration/definition_fingerprint_test.exs test/jido_claw/skills/steps/iterative_step_test.exs test/jido_claw/skills/compiler_test.exs test/jido_claw/orchestration/replay_test.exs`
2. Tidewave sanity (`project_eval`): compile an iterative skill with an irreversible generator → assert loop step impl options include `irreversible: true` (the review's own repro inverted).
3. `mise exec -- mix format` then **`mise exec -- mix precommit` — must pass (completion bar)**. Run it bare in background (no pipe — tail's exit code masks the gate) and read the output tail. Known flaky singletons (MCPServer, Prompt, PipelineStore, MultiSandbox) move under load: verify any failure in isolation before attributing it to this change.

## Out of scope

- `compensate` support for iterative skills (loop has no undo — documented limitation, validation still accepts it; per Fix 1c it is now correctly fingerprint-inert for iterative mode).
- Evaluator retry budgets as real behavior (documented semantic: the generator's budget governs the loop; per Fix 1c evaluator `retry` is fingerprint-inert).
- MCP `replay_workflow` override flags (deliberately dashboard-only, unchanged).
