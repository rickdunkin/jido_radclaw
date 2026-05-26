# T1-3 Structured Final Output — Round 2 (revised after review)

## Context

Commit `46e1f87 Structured Final Output` landed the engine: it adopted upstream
`Jido.AI.Output` (via `output: %{schema, retries, on_validation_error}` on
`use Jido.AI.Agent`) and gave **two** workers structured-output schemas —
Verifier and Reviewer. T1-3 calls out the rollout to Coder + Researcher; the
user picked all five remaining workers (Coder, Researcher, TestRunner,
Refactorer, DocsWriter).

### Why the original plan was rejected (preserved for context)

The reviewer surfaced three real defects in the first draft. Summarized so
this revision can be checked against them:

1. **Workflow consumer regression.** `Jido.AI.Output` enforces a single JSON
   object with no extra text (`deps/jido_ai/lib/jido_ai/output.ex:160-163`) and
   the runner replaces `state.result` with the parsed map
   (`deps/jido_ai/lib/jido_ai/reasoning/react/runner.ex:949`). Workflow steps
   still derive `StepResult.result` via `Output.extract_result/1`
   (`lib/jido_claw/workflows/step_action.ex:121,153`), which only matches
   `:last_answer | :answer | :text | binary` and otherwise falls through to
   `inspect/1` (`lib/jido_claw/reasoning/output.ex:41-46`). Net effect for a
   schema'd Coder: `StepResult.result` becomes `"%{status: :completed, …}"`
   instead of useful prose. Downstream consumers:
   - `ContextBuilder.format_all` / `format_for_deps` / `format_preceding_all`
     thread `result` into the **next step's task prompt**
     (`lib/jido_claw/workflows/context_builder.ex:128-141`) — gibberish in,
     gibberish out.
   - `RunSkill.build_result` joins `result` into the final synthesis prompt
     (`lib/jido_claw/tools/run_skill.ex:133-161`).
2. **ARTIFACTS extraction silently breaks.** `inject_produces_instruction`
   asks the agent to append a free-form `ARTIFACTS:` block
   (`lib/jido_claw/workflows/step_action.ex:187-199`). Structured output
   forbids extra text, so a schema'd worker can't comply — either it ignores
   the schema (→ validation fails, repair triggers, possibly succeeds and
   drops ARTIFACTS) or it follows the schema (→ artifacts never emitted).
   `extract_artifacts/1` regex never matches in either case
   (`lib/jido_claw/workflows/step_action.ex:207-222`).
3. **`Certificates.parse_verdict/1` doesn't exist.** The typed verdict parser
   is `JidoClaw.Workflows.IterativeWorkflow.parse_verdict/1`
   (`lib/jido_claw/workflows/iterative_workflow.ex:144-165`).
   `JidoClaw.Reasoning.Certificates` only owns `parse_certificate/1` for
   fenced certificate JSON (`lib/jido_claw/reasoning/certificates.ex:301-310`)
   — a different artifact type used by `Tools.VerifyCertificate`. The
   original plan's doc-update section had this wrong.

### Revised approach

Fix the consumer path **first**, then roll out schemas. The artifact handling
becomes a first-class part of the schema for workflow-touching workers. Add
tests that cover the typed/repaired path end-to-end (not just Zoi roundtrips,
which would be Zoi's tests, not ours).

Definition of done: `mix precommit` passes.

---

## Phase A — Fix the workflow consumer path

These changes are independent of which workers get schemas. They have to
land before (or with) the schema rollout to avoid a transcript / artifact
regression on the workflow-touching workers (Coder, Refactorer, DocsWriter,
TestRunner — Researcher too, in skills that use it as a generator step).

### A1. `Output.extract_result/1` — pick up `:summary` and `:reasoning` on typed maps

`lib/jido_claw/reasoning/output.ex` — add clauses **before** the
binary/inspect fallback so a parsed schema map projects to a useful
transcript string. Two key fallbacks: `:summary` for the five new
schemas (and Reviewer), and `:reasoning` for the Verifier schema (which
has no `:summary` — its longest prose field is `:reasoning`):

```elixir
def extract_result(%{summary: summary}) when is_binary(summary), do: summary
def extract_result(%{"summary" => summary}) when is_binary(summary), do: summary
def extract_result(%{reasoning: reasoning}) when is_binary(reasoning), do: reasoning
def extract_result(%{"reasoning" => reasoning}) when is_binary(reasoning), do: reasoning
```

Order matters: existing `:last_answer | :answer | :text` clauses keep
priority (those are the upstream-produced shapes); `:summary` and
`:reasoning` are new ground this plan introduces. `:summary` precedes
`:reasoning` so workers that emit both (e.g. hypothetical future schemas)
display the summary line. String-keyed variants cover JSON-decoded shapes
that come back through `meta`/storage paths.

### A2. `StepAction` — source result text and artifacts from `typed_output`

`lib/jido_claw/workflows/step_action.ex` — the async path is the relevant
one (sync path only hits when a test stub omits `ask/3`).

In `await_step/4` (around line 144-162), when `typed_request_output/1`
returns a map, prefer it as the source for both `result:` and `artifacts:`:

```elixir
{:ok, %{status: :completed, result: request}} when is_map(request) ->
  typed = Output.typed_request_output(request)
  raw_text = Output.extract_result(Output.request_result(request))

  {text, typed_artifacts} =
    case typed do
      %{} = m ->
        artifacts = Map.get(m, :artifacts) || Map.get(m, "artifacts") || %{}
        {Output.extract_result(m), artifacts}

      _ ->
        {raw_text, %{}}
    end

  artifacts = Map.merge(extract_artifacts(raw_text), normalize_artifacts(typed_artifacts))

  {:ok,
   %JidoClaw.Workflows.StepResult{
     name: step_name,
     template: template_name,
     result: text,
     typed_output: typed,
     artifacts: artifacts
   }}
```

The `Map.get(m, :artifacts) || Map.get(m, "artifacts")` form is cheap
robustness — Zoi.object parses known fields to atom keys, but JSON-decoded
shapes from `meta`/storage paths can come back string-keyed.

`normalize_artifacts/1` is a small private helper that stringifies values
(and drops nils, since the artifact sub-schema has all optional fields —
see Phase B) so the merged artifact map matches the existing free-form
regex shape (`%{"url" => "...", "port" => "...", "files" => "..."}`):

```elixir
defp normalize_artifacts(map) when is_map(map) do
  map
  |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  |> Map.new(fn {k, v} -> {to_string(k), to_string_safe(v)} end)
end
defp normalize_artifacts(_), do: %{}

defp to_string_safe(v) when is_binary(v), do: v
defp to_string_safe(v) when is_list(v), do: Enum.join(v, ", ")
defp to_string_safe(v), do: to_string(v)
```

(The sync path at line 121 doesn't see typed maps — `ask_sync` returns
`state.last_answer`. Leave it alone to keep test-stub behavior stable.)

### A3. `inject_produces_instruction` — schema-aware artifact reporting

`lib/jido_claw/workflows/step_action.ex:187-199` currently appends a
free-form `ARTIFACTS:` block instruction. With Zoi schemas enforcing
`additionalProperties: false` on the top-level object, a schema'd worker
can't satisfy both. (The artifact sub-object specifically uses
`unrecognized_keys: :preserve` to allow extra runtime keys — see Phase B.)

**Resolution**: schemas for workflow-touching workers carry an
`artifacts` sub-object with known `url/port/files` fields plus preserved
extras (see Phase B). The instruction is rewritten so the LLM picks the
right shape based on its output mode (ASCII bullets only):

```elixir
def inject_produces_instruction(task, _produces) do
  task <>
    "\n\n" <>
    """
    If you discover runtime details (URLs, ports, generated file paths) that
    differ from the expected configuration, report them:
      - If your final response is a structured JSON object, include them as
        string values in the `artifacts` field (known keys: url, port,
        files; additional keys allowed).
      - Otherwise, append an ARTIFACTS: key/value block at the end of your
        response:

        ARTIFACTS:
        url: <actual URL>
        port: <actual port>
        files: <comma-separated file paths>
    """
end
```

This avoids passing the template module through every caller (cleaner than
A1/A2's bookkeeping) and lets a free-form worker still emit the ARTIFACTS
block.

### A4. Tests for Phase A

Add to existing files; do not create new test directories.

- `test/jido_claw/reasoning/output_test.exs` — add cases for
  `extract_result/1` on `%{summary: "x"}` and `%{"summary" => "x"}`. If the
  file doesn't exist yet, create it; otherwise extend.
- `test/jido_claw/workflows/step_action_test.exs` — using the existing
  `EchoAskStub` + `ValidatedFakeAgentServer` doubles, add cases for:
  1. `typed_output` present with `:summary` → `StepResult.result` becomes
     that summary string (not `inspect(map)`).
  2. `typed_output[:artifacts]` non-empty → `StepResult.artifacts` includes
     those keys (stringified).
  3. Free-form path (no `typed_output`) still pulls artifacts from
     `ARTIFACTS:` regex (regression cover for the unchanged path).
  4. `meta.output.status == :repaired` round-trip — assert the repaired
     typed map flows through to `typed_output` (the user explicitly
     called this out).

---

## Phase B — Schema rollout (5 workers)

Each worker file mirrors the Verifier/Reviewer pattern (output: %{schema,
retries, on_validation_error} added to the existing `use JidoClaw.Agent.Defaults`
keyword list) and a small description update so the LLM knows the shape.

### B1. `lib/jido_claw/agent/workers/coder.ex`

```elixir
output: %{
  schema:
    Zoi.object(%{
      status: Zoi.enum([:completed, :partial, :blocked]),
      summary: Zoi.string(),
      files_changed: Zoi.array(Zoi.string()),
      notes: Zoi.string(),
      artifacts:
        Zoi.object(
          %{
            url: Zoi.string() |> Zoi.optional(),
            port: Zoi.string() |> Zoi.optional(),
            files: Zoi.string() |> Zoi.optional()
          },
          unrecognized_keys: :preserve
        )
    }),
  retries: 1,
  on_validation_error: :repair
}
```

Description: add *"Return a structured result with `status`
(`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list
of paths), `notes` for caveats, and `artifacts` (an object
with optional `url`/`port`/`files` plus any extra string runtime details —
use `{}` if none)."*

### B2. `lib/jido_claw/agent/workers/researcher.ex`

Includes an `artifacts` field for uniformity with the other
workflow-touching workers — once Researcher is schema'd it can't fall back
to the free-form `ARTIFACTS:` block, so the schema must carry the field
even though Researcher rarely produces runtime artifacts.

```elixir
output: %{
  schema:
    Zoi.object(%{
      summary: Zoi.string(),
      confidence: Zoi.enum([:low, :medium, :high]),
      findings:
        Zoi.array(
          Zoi.object(%{
            topic: Zoi.string(),
            detail: Zoi.string(),
            references: Zoi.array(Zoi.string())
          })
        ),
      artifacts:
        Zoi.object(
          %{
            url: Zoi.string() |> Zoi.optional(),
            port: Zoi.string() |> Zoi.optional(),
            files: Zoi.string() |> Zoi.optional()
          },
          unrecognized_keys: :preserve
        )
    }),
  retries: 1,
  on_validation_error: :repair
}
```

Description: add *"Return a structured result with a top-line `summary`,
`confidence` (`low`/`medium`/`high`), a list of `findings` (each with a
`topic`, `detail`, and `references` — file paths or symbols), and
`artifacts` (an object with optional `url`/`port`/`files` plus any extra
string runtime details — use `{}` if none)."*

### B3. `lib/jido_claw/agent/workers/test_runner.ex`

Non-negative integer refinement on the counts per reviewer feedback. Use
`Zoi.gte/2` since that's the documented Zoi refinement (verified to be in
the API — used elsewhere; if Zoi prefers `Zoi.min/2` for integers, switch
during implementation, both are non-breaking).

```elixir
output: %{
  schema:
    Zoi.object(%{
      status: Zoi.enum([:passed, :failed, :error]),
      summary: Zoi.string(),
      passed_count: Zoi.integer() |> Zoi.gte(0),
      failed_count: Zoi.integer() |> Zoi.gte(0),
      failures:
        Zoi.array(
          Zoi.object(%{
            test: Zoi.string(),
            error: Zoi.string()
          })
        ),
      artifacts:
        Zoi.object(
          %{
            url: Zoi.string() |> Zoi.optional(),
            port: Zoi.string() |> Zoi.optional(),
            files: Zoi.string() |> Zoi.optional()
          },
          unrecognized_keys: :preserve
        )
    }),
  retries: 1,
  on_validation_error: :repair
}
```

Description: add *"Return a structured result with `status`
(`passed`/`failed`/`error` — `error` for test-runner crashes/setup failures
distinct from `failed` for test assertions), a one-line `summary`,
`passed_count` / `failed_count` (non-negative), a list of `failures` (each
with the failing `test` name and its `error` message), and `artifacts`
(an object with optional `url`/`port`/`files` plus any extra string runtime
details — use `{}` if none)."*

### B4. `lib/jido_claw/agent/workers/refactorer.ex`

```elixir
output: %{
  schema:
    Zoi.object(%{
      status: Zoi.enum([:completed, :partial, :blocked]),
      summary: Zoi.string(),
      files_changed: Zoi.array(Zoi.string()),
      improvements: Zoi.array(Zoi.string()),
      artifacts:
        Zoi.object(
          %{
            url: Zoi.string() |> Zoi.optional(),
            port: Zoi.string() |> Zoi.optional(),
            files: Zoi.string() |> Zoi.optional()
          },
          unrecognized_keys: :preserve
        )
    }),
  retries: 1,
  on_validation_error: :repair
}
```

Description: add *"Return a structured result with `status`
(`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list
of paths), `improvements` (bullets of what got better — structure,
readability, perf, etc.), and `artifacts` (an object
with optional `url`/`port`/`files` plus any extra string runtime details —
use `{}` if none)."*

### B5. `lib/jido_claw/agent/workers/docs_writer.ex`

Per reviewer: `kinds` (plural array) instead of single `kind`.

```elixir
output: %{
  schema:
    Zoi.object(%{
      status: Zoi.enum([:completed, :partial, :blocked]),
      summary: Zoi.string(),
      files_changed: Zoi.array(Zoi.string()),
      kinds: Zoi.array(Zoi.enum([:moduledoc, :typespec, :readme, :guide, :inline_comment, :other])),
      artifacts:
        Zoi.object(
          %{
            url: Zoi.string() |> Zoi.optional(),
            port: Zoi.string() |> Zoi.optional(),
            files: Zoi.string() |> Zoi.optional()
          },
          unrecognized_keys: :preserve
        )
    }),
  retries: 1,
  on_validation_error: :repair
}
```

Description: add *"Return a structured result with `status`
(`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list
of paths), `kinds` (one or more of
`moduledoc`/`typespec`/`readme`/`guide`/`inline_comment`/`other`), and
`artifacts` (an object with optional `url`/`port`/`files` plus any extra
string runtime details — use `{}` if none)."*

### B6. Tests for Phase B

One smoke test per worker, covering **all seven** worker templates
(Verifier and Reviewer from 46e1f87 + the five from this round) so the
"every worker has a structured contract" invariant is asserted in one
place. File: `test/jido_claw/agent/workers/worker_output_schemas_test.exs`.

Introspection uses the existing public surface from `use Jido.Agent` —
`WorkerModule.strategy_opts/0` returns a keyword list with `:output`
already populated as a compiled `%Jido.AI.Output{}`
(`deps/jido/lib/jido/agent.ex:720`, populated from
`deps/jido_ai/lib/jido_ai/agent.ex:427`). No new accessor or module
attribute on the worker side.

```elixir
defmodule JidoClaw.Agent.Workers.OutputSchemasTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Workers.{Coder, Researcher, TestRunner, Refactorer,
                                DocsWriter, Verifier, Reviewer}

  defp output_for(module), do: module.strategy_opts() |> Keyword.fetch!(:output)

  test "Coder schema parses a valid sample" do
    assert {:ok, parsed} = Jido.AI.Output.parse(output_for(Coder), %{
      "status" => "completed",
      "summary" => "Implemented foo",
      "files_changed" => ["lib/foo.ex"],
      "notes" => "n/a",
      "artifacts" => %{"url" => "http://localhost:4000"}
    })
    assert parsed.status == :completed
    assert is_map(parsed.artifacts)
    # Known field `url` parses to atom key; the assertion form below is
    # tolerant of either, since Zoi/output-normalizer behavior on the
    # known-field path is what we want to verify at implementation time.
    url = Map.get(parsed.artifacts, :url) || Map.get(parsed.artifacts, "url")
    assert url == "http://localhost:4000"
  end

  # ... one test per worker, with shape-appropriate sample payloads.
end
```

Each test parses one valid sample for that worker's schema via
`Jido.AI.Output.parse/2` and asserts atom-typed enum fields come back as
atoms. This catches drift (someone deletes a field, mis-types an enum) and
is closer to a contract check than a Zoi unit test.

**Why not a module attribute / `__output_schema__/0` accessor on the
worker?** Reviewer flagged that placing `@output_schema` inside the
`output:` opt is risky with the current `JidoClaw.Agent.Defaults` →
`Jido.AI.Agent` macro stack (the attribute is read during macro expansion
and can fail). `strategy_opts/0` is the documented public path; no need
to add new surface.

---

## Phase C — Docs

### C1. Update T1-3 in `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md`

Replace the `Status (2026-05-18): NOT_ADOPTED` block (lines 99–141) with an
`Status (2026-05-26): ADOPTED` block following the T1-2 Compaction update
style (lines 63–94). Key facts to capture:

- Engine: upstream `Jido.AI.Output` consumed directly via `use Jido.AI.Agent,
  output: %{...}` — no `JidoClaw.Agent.Output` behaviour was ported (T1-3's
  adoption sketch suggested one; this was the judgment call in 46e1f87).
- All 7 workers covered: Verifier, Reviewer (46e1f87) + Coder, Researcher,
  TestRunner, Refactorer, DocsWriter (this round).
- Per-worker schemas are Zoi objects with `retries: 1` and
  `on_validation_error: :repair`. All workflow-touching workers (Coder,
  Researcher, TestRunner, Refactorer, DocsWriter) include an `artifacts`
  sub-object (known optional keys `url`/`port`/`files` plus
  `unrecognized_keys: :preserve` for extras) for uniform artifact
  extraction; Verifier and Reviewer omit it (evaluator/reviewer roles, no
  produces metadata). `Zoi.map(key_type, value_type)` was tried first but
  crashes in `Jido.AI.Output`'s zoi-input normalizer
  (`deps/jido_ai/lib/jido_ai/output.ex:373`); the sub-object form
  side-steps that and still satisfies the existing
  `inject_produces_instruction` vocabulary.
- Validation lives in `Jido.AI.Reasoning.ReAct.Runner.finalize_output/4`
  (not Jidoka's `on_after_cmd` placement) — same semantics.
- Trace events `[:jido, :ai, :output, :start | :validated | :repair |
  :error]` wired in `Trace.Collector` (`lib/jido_claw/trace/collector.ex`).
- `Tools.GetAgentResult` consumes typed output via
  `JidoClaw.Reasoning.Output.typed_request_output/1` and
  `request_meta_output/1`.
- **Typed verdict parsing lives in
  `JidoClaw.Workflows.IterativeWorkflow.parse_verdict/1`** (NOT
  `Certificates.parse_verdict/1` — `Certificates` only owns
  `parse_certificate/1` for fenced certificate JSON, a different artifact).
- Workflow path: `StepAction.run_step_async` projects `typed_output[:summary]`
  to `StepResult.result` and merges `typed_output[:artifacts]` into
  `StepResult.artifacts`. `inject_produces_instruction` is schema-agnostic
  and works whether the worker has a schema or not.

Keep a "Prior state" paragraph (T1-2 precedent) describing the original
NOT_ADOPTED inventory so the doc remains a useful historical record.

### C2. Update the cross-reference graph if needed

Lines 333–339 ("Tier 1 four cluster") — likely no changes since T1-3's
dependency arrows are unchanged. Verify in passing.

---

## What this plan deliberately does NOT do

- **No `JidoClaw.Agent.Output` module.** Engine sticks with upstream
  `Jido.AI.Output` (46e1f87 decision retained).
- **No changes to `Tools.GetAgentResult`.** It already projects typed output
  correctly post-46e1f87 (`lib/jido_claw/tools/get_agent_result.ex:60-82`).
- **No system-prompt edits.** Per-request schema instructions are injected
  by `Jido.AI.Output.apply_instructions/2`.
- **No `Certificates.parse_verdict/1` addition.** That function never
  existed; the original plan misattributed it. The typed verdict path
  lives in `IterativeWorkflow.parse_verdict/1` and is already complete.
- **No changes to `ContextBuilder.format_*`** — once `StepResult.result` is
  the `:summary` string instead of `inspect(map)`, the downstream
  formatters already do the right thing.

---

## Verification

`mix precommit` (from `mix.exs:234`) is the bar. Steps:

1. `compile --warnings-as-errors`
2. `jidoclaw.system_prompt.check`
3. `deps.unlock --unused`
4. `format`
5. `credo --strict`
6. `dialyzer --format short`
7. `test`

Manual smoke check (not blocking): run a workflow skill end-to-end via
`mix jidoclaw` (REPL) and inspect a step transcript to confirm summaries
read like prose (not inspected maps). The existing
`test/jido_claw/workflows/iterative_workflow_test.exs` and
`step_action_test.exs` cover the regression paths once Phase A is in.

---

## Open questions for the reviewer

None outstanding — the three round-2 revisions (drop
`__output_schema__/0` in favor of `strategy_opts/0`; add `artifacts` to
Researcher; add `:reasoning` fallback to `extract_result/1`; expand B6 to
all 7 workers) are baked in. Implementation may still need minor on-the-fly
adjustments if Zoi's API for `gte/0` differs from expectation (unlikely —
confirmed available).

Implementation order: A1 → A2 → A3 → A4 (Phase A tests) → B1–B5 (workers) →
B6 (Phase B tests — all 7 workers) → C1–C2 (docs) → `mix precommit`.
