# T1-3 — Structured Final Output (native `Jido.AI.Output` adoption)

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` proposes lifting Jidoka's
`Output` module into JidoClaw. **First-draft plan was wrong**: `Jido.AI.Agent`
already accepts `:output` (`deps/jido_ai/lib/jido_ai/agent.ex:47, 354-357,
427`), and `Jido.AI.Output` (`deps/jido_ai/lib/jido_ai/output.ex`, 420 lines,
single file) already implements schema validation, repair-retry, system-prompt
instruction injection, telemetry, per-call `:raw` bypass, and result
replacement. The work for T1-3 is therefore **integration + plumbing fixes**,
not a port.

The Tier-1 doc reasoning still holds (Verifier's `VERDICT: PASS|FAIL` is parsed
by regex at `workflows/iterative_workflow.ex:244` and falls through to `:fail`
on any non-match; swarm results are stringified through
`Reasoning.Output.extract_result/1`). The corrected plan adopts the native
output path and fixes the four propagation regressions that prevent typed
output from reaching its consumers.

## What stays from the first draft

* Verifier + Reviewer canaries (user-confirmed).
* `verdict + confidence + reasoning` for Verifier (user-confirmed).
* Proposed Reviewer schema (subject to revision — see Open Questions).
* End-to-end verification via `mix precommit` + REPL smoke test.

## What's deleted from the first draft

The entire `JidoClaw.Reasoning.Output.{Config,Schema,Runtime,Telemetry,InstructionTransformer}`
greenfield module tree. `on_after_cmd/3` override. Macro `:output` pop in
`Agent.Defaults`. The existing `Reasoning.Output.extract_*` helpers stay
exactly as they are — they remain the fallback when no typed output is present.

## Design

### Worker wiring (uses native path)

`JidoClaw.Agent.Defaults` already forwards `:output` to `Jido.AI.Agent`
unchanged (the macro at `lib/jido_claw/agent/defaults.ex:51` only pops
`:compaction`). No macro change needed.

**`lib/jido_claw/agent/workers/verifier.ex`** — add:

```elixir
output: %{
  schema: Zoi.object(%{
    verdict: Zoi.enum([:pass, :fail]),
    confidence: Zoi.enum([:low, :medium, :high]),
    reasoning: Zoi.string()
  }),
  retries: 1,
  on_validation_error: :repair
}
```

Note `Zoi.enum/2` — pass plain atom values; **do NOT pass `enum_type: :atom`**
(Zoi 0.18.4 rejects it; the type is inferred from the values list, see
`deps/zoi/lib/zoi/types/enum.ex:25-47`). Top-level atom enums auto-coerce
`"pass" → :pass` in `Output.normalize_zoi_input/2` at
`deps/jido_ai/lib/jido_ai/output.ex:393`.

**Cleanup all VERDICT prompt fragments** — the native path injects
"return only JSON" instructions, so any legacy "End with VERDICT:" guidance
will fight it and drive unnecessary repair attempts. Five sites carry the
legacy text and all must be updated to ask for the structured shape instead:

* `lib/jido_claw/agent/workers/verifier.ex:8` — worker description.
* `lib/jido_claw/agent/templates.ex:42` — agent template descriptor.
* `lib/jido_claw/platform/skills.ex:195` — skills runtime prompt fragment.
* `lib/jido_claw/platform/jido_md.ex:103` — markdown agent prompt fragment.
* `.jido/skills/*.yaml` — any committed skill YAML mentioning VERDICT.
* `priv/defaults/system_prompt.md:90` — main agent system prompt
  (note: this file is auto-checked by `mix jidoclaw.system_prompt.check`;
  regenerate or hand-sync as appropriate — see Open Questions).

Replacement language across all sites: `"Return a structured verdict
(`pass`/`fail`), confidence (`low`/`medium`/`high`), and short reasoning."`

**`lib/jido_claw/agent/workers/reviewer.ex`** — add `output:` with a nested
schema that survives `Output.normalize_zoi_input/2`'s missing array-recursion
clause by combining `Zoi.object(..., coerce: true)` with Zoi's keyword enum
form (`[atom: "string", ...]`), which coerces inside nested objects:

```elixir
output: %{
  schema: Zoi.object(%{
    overall: Zoi.enum([:approve, :request_changes, :comment]),
    summary: Zoi.string(),
    findings: Zoi.array(
      Zoi.object(%{
        severity: Zoi.enum(info: "info", warning: "warning", error: "error"),
        description: Zoi.string()
      }, coerce: true)
    )
  }),
  retries: 1,
  on_validation_error: :repair
}
```

This returns `severity: :error` from a JSON `"error"` and preserves strict
enum validation — no custom recursive pre-pass needed. Update the description
to ask for the structured JSON shape.

### Trace.Collector native-event coverage

`lib/jido_claw/trace/collector.ex` listens for `[:jido_claw, :output, :event]`
at line 101, but native output emits four distinct telemetry events:
`[:jido, :ai, :output, :start | :validated | :repair | :error]` (per
`deps/jido_ai/lib/jido_ai/observe.ex:235` and
`react/strategy.ex:2485-2496`). Note: `:repaired` is **not** a telemetry
event — it's only a meta status value; the repair attempt is reported as
`:repair`. Three edits:

* Append the four `[:jido, :ai, :output, *]` events to `@base_jido_ai_events`
  (after line 90).
* Add `defp event_shape([:jido, :ai, :output, event], _m), do: {:ok, :jido_ai,
  :output, event}` — mirrors the existing `[:jido, :ai, :tool, :execute, _]`
  clause shape at line 358.
* Extend `event_status/3`: include `:validated` in the `:completed` clause at
  line 439, and map `:repair` to `:running`. `:error` already covers via the
  existing `:error`/`:failed` clause.

### Result propagation fixes

Today `Jido.Await.completion/2` uses default `result_path: [:last_answer]`,
which `compat_text/1` (`deps/jido_ai/lib/jido_ai/request.ex:425`) stringifies.
The typed map written by `runner.ex:945-956 finalize_output/4` lives at
`state.requests[request_id].result`. The native `Jido.AI.Request.await/2`
(`deps/jido_ai/lib/jido_ai/request.ex:294-305`) already demonstrates the
correct path triple — `status_path`, `result_path`, `error_path` — all keyed
under `[:requests, request_id, _]`. There is no `meta_path` option; to read
both `:result` and `:meta.output` we point `result_path: [:requests,
request_id]` (the whole request map) and destructure from there.

Three sites need edits:

1. **`lib/jido_claw/agent_tracker.ex`** — add `:request_id` to `AgentEntry`
   (currently `:tokens, :tool_calls, :status, :last_tool, :error`). Extend
   `register` to accept it (new arity or keyword opt).
2. **`lib/jido_claw/tools/spawn_agent.ex`** — three changes here:
   * **Registration ordering**: `register_spawned_agent/6` at line 71 calls
     `agent_tracker().register(tag, ...)` BEFORE
     `JidoClaw.register_child_correlation/1` creates the `request_id` at line
     77. Reorder: build child tool_context, call
     `register_child_correlation/1` to get `request_id`, **then**
     `AgentTracker.register(tag, pid, template_name, task, request_id: ...)`,
     then spawn the `ask_sync` task.
   * **Honor `ask_sync` errors**: line 87 currently calls
     `agent_tracker().mark_complete(tag, :done)` regardless of `ask_sync`
     return shape. Structured-output validation failures surface as
     `{:error, _}` from `ask_sync` and must be reflected in the tracker.
     Pattern-match: `{:ok, _} -> mark_complete(tag, :done)`,
     `{:error, _} -> mark_complete(tag, :error)`.
   * **Follow-up turns via `send_to_agent`**:
     `lib/jido_claw/tools/send_to_agent.ex:37` creates a *new* `request_id`
     per turn. Today's plan stores only the initial spawn `request_id` on the
     tracker entry, which means `get_agent_result` returns the initial task's
     typed output even after follow-up messages. **For v1**, document the
     limitation: `get_agent_result` reflects the initial task result. **For
     v2** (out of scope), `send_to_agent` updates a `latest_request_id` on
     the tracker entry and `get_agent_result` reads that instead.
3. **`lib/jido_claw/tools/get_agent_result.ex`** — extend the existing
   `await_module().completion(pid, timeout, opts)` path (preserve the
   `:jido_await` test injection at line 112; the fake at the test boundary
   needs to grow arity 3). When the tracker entry carries `request_id`, call:

   ```elixir
   await_module().completion(pid, timeout,
     status_path: [:requests, request_id, :status],
     result_path: [:requests, request_id],
     error_path:  [:requests, request_id, :error]
   )
   ```

   The injection seam `await_module().completion/3` resolves to
   `Jido.Await.completion/3`, which wraps `Jido.AgentServer.await_completion/2`
   and preserves its return shape. **It returns
   `{:ok, %{status: :completed, result: request_map}}` on success and
   `{:ok, %{status: :failed, result: reason}}` on failure** — both must be
   destructured explicitly. From the `request_map` on the `:completed` branch,
   pull `:result` (typed map or text) and `request.meta.output` (the meta bag).
   Surface the typed map under `:result` and meta under a new `:output_meta`
   field when present. Fall back to the existing two-arg
   `await_module().completion(pid, timeout)` + `Reasoning.Output.extract_result/1`
   path when the entry has no `request_id` (free-form workers, legacy spawns).
   Widen `output_schema:` at line 9-15 with `result: [type: {:or, [:string,
   :map]}]` — match the repo style at `verify_certificate.ex:20`. Add
   `output_meta: [type: {:or, [:map, nil]}]`.

### StepAction typed-output capture

`lib/jido_claw/workflows/step_action.ex:55-82` currently calls
`template.module.ask_sync(...)`. `ask_sync` returns only the normalized
result — it cannot expose `request.meta.output`. To capture typed output AND
meta, switch the step to the async path:

```elixir
{:ok, %{id: ^rid} = _handle} = template.module.ask(pid, task, request_id: rid, ...)

case Jido.AgentServer.await_completion(pid,
       timeout: timeout,
       status_path: [:requests, rid, :status],
       result_path: [:requests, rid],
       error_path:  [:requests, rid, :error]) do
  {:ok, %{status: :completed, result: request}} ->
    typed = typed_output(request)            # when request.meta.output[:status] in [:validated, :repaired]
    text  = Reasoning.Output.extract_result(request.result)
    {:ok, %StepResult{result: text, typed_output: typed, ...}}

  {:ok, %{status: :failed, result: reason}} ->
    {:error, ...}                            # preserve existing failure contract
  ...
end
```

Note the wrapper: `Jido.AgentServer.await_completion/2` returns
`{:ok, %{status: :completed | :failed, result: ...}}`, not the bare request
map. Destructure it. (`Jido.Await.completion/3` is the higher-level wrapper
used by `get_agent_result.ex` via the `await_module()` indirection — it
forwards to `await_completion/2` after merging `:timeout` into `opts`.)

Extend `JidoClaw.Workflows.StepResult` (find the struct definition;
`step_action.ex` is its primary writer) with `:typed_output :: map() | nil`.
Existing `:result` text stays for backwards-compat with `extract_artifacts/1`
regex consumers. The typed map is populated only when
`request.meta.output[:status]` is `:validated` or `:repaired`.

### `parse_verdict/1` typed-aware

`lib/jido_claw/workflows/iterative_workflow.ex` — current `parse_verdict/1`
is **public** (`def`, not `defp`) and tests already call it; keep `def`. The
binary clause matches at line 136, with a catch-all returning `:fail` at line
151. Add typed clauses BEFORE the binary clause:

```elixir
def parse_verdict(%{verdict: :pass}), do: :pass
def parse_verdict(%{verdict: :fail}), do: :fail
def parse_verdict(%{verdict: verdict}) when is_atom(verdict), do: verdict
```

Update the call site at line 244 to prefer the typed shape:
`case parse_verdict(eval_result.typed_output || eval_result.result) do`.

## Critical files to modify

* `lib/jido_claw/agent/workers/verifier.ex` — `:output` opt + description.
* `lib/jido_claw/agent/workers/reviewer.ex` — `:output` opt + description.
* `lib/jido_claw/agent/templates.ex` — drop VERDICT instruction (line 42).
* `lib/jido_claw/platform/skills.ex` — drop VERDICT instruction (line 195).
* `.jido/skills/*.yaml` — drop VERDICT instruction from any skill that
  delegates verification to the Verifier worker.
* `priv/defaults/system_prompt.md` — drop VERDICT instruction (line 90).
* `lib/jido_claw/agent_tracker.ex` — `:request_id` field on `AgentEntry`.
* `lib/jido_claw/tools/spawn_agent.ex` — registration ordering, pass
  `request_id` to tracker, honor `ask_sync` errors.
* `lib/jido_claw/tools/get_agent_result.ex` — request-scoped `await`
  paths via the existing `await_module()` indirection, surface typed result
  + meta, widen `output_schema`.
* `lib/jido_claw/workflows/step_action.ex` — switch from `ask_sync` to
  async `ask` + `await_completion`, capture `:typed_output`.
* `lib/jido_claw/workflows/step_result.ex` (or wherever the struct is defined) — add `:typed_output` field.
* `lib/jido_claw/workflows/iterative_workflow.ex` — typed `parse_verdict/1` clauses + call-site update.
* `lib/jido_claw/trace/collector.ex` — attach native output events + `event_shape`/`event_status` clauses.

## Tests

Note on fakes: `Application.put_env(:jido_claw, :jido_runtime, FakeJido)`
only stubs **swarm lookup/start** (`Jido.whereis`, `Jido.start_agent`); it
does **not** intercept the ReAct runner's `ReqLLM` calls, so it cannot drive
the structured-output instruction/validation/repair paths. The right test
shapes are:

* **Direct `Jido.AI.Output` tests** — exercise validation, repair, and
  instruction injection against the upstream module without needing a live
  agent. Use `Output.validate/2` / `Output.parse/2` for parsing tests, and
  `Output.repair/5` with an explicit `repair_fun:` option for repair tests
  (the native runner's real repair path goes through `ReqLLM.Generation`;
  `Application.put_env` cannot intercept it). This is where the heavy
  logic-level assertions belong (e.g., real nested JSON
  `%{"findings" => [%{"severity" => "error", "description" => "..."}]}`
  round-trips into atom `:severity => :error` with the `coerce: true`
  schema).
* **Focused JidoClaw plumbing tests** — exercise the integration points we
  *do* own:
  * `test/jido_claw/agent_tracker_test.exs` — extend to assert `:request_id`
    is stored and retrievable.
  * `test/jido_claw/tools/spawn_agent_test.exs` — assert registration happens
    AFTER `register_child_correlation/1` so `request_id` is present.
  * `test/jido_claw/tools/get_agent_result_test.exs` — extend the existing
    `FakeAwait` (the `:jido_await` injection seam) to stub
    `await_module().completion/3` returning
    `{:ok, %{status: :completed, result: request_map}}` with a typed result
    + `meta.output` map; keep the existing 2-arity stub for the free-form
    fallback. Assert correct passthrough vs. fallback.
  * `test/jido_claw/workflows/iterative_workflow_test.exs` — assert
    `parse_verdict/1` handles `%{verdict: :pass}`, `%{verdict: :fail}`, and
    the legacy `is_binary(text)` paths.
  * `test/jido_claw/trace/collector_test.exs` — emit each of the four
    `[:jido, :ai, :output, *]` events via `:telemetry.execute/3` and assert
    they land in the collector with the correct `status` (`:running` for
    `:start`/`:repair`, `:completed` for `:validated`, `:failed` for
    `:error`).
* **Full end-to-end integration** (one test) — install a fake ReqLLM
  provider/transport that returns scripted JSON + a deliberately broken
  payload, run `Verifier.ask/3` directly, assert the agent state carries
  the parsed map at `state.requests[rid].result` and meta at
  `state.requests[rid].meta.output[:status] == :validated`. Skip on CI if the
  ReqLLM-transport fake is too heavy; the prior layers already cover most
  failure modes individually.

## Verification

1. `mix compile --warnings-as-errors`
2. `mix format`
3. `mix credo --strict`
4. `mix dialyzer --format short` — `:request_id` field on `AgentEntry` is a
   new `String.t() | nil`; `:typed_output` on `StepResult` is `map() | nil`.
5. `mix test`
6. **End-to-end smoke**: `mix jidoclaw`, ask the main agent to spawn a
   Verifier on a real task ("verify the project compiles"). Confirm the result
   is `%{verdict: :pass | :fail, confidence: ..., reasoning: "..."}`. Confirm
   a Trace entry with `category: :output, event: :validated` shows in the
   dashboard.
7. **`mix precommit` — required to pass cleanly; plan is not complete until it does.**

## Open questions / risks

* **`jidoclaw.system_prompt.check`** — Verifier/Reviewer description changes
  may interact with `priv/defaults/system_prompt.md`. Check at implementation
  time; the worker description fields don't appear to be inlined in the main
  system prompt template (workers describe themselves via the SpawnAgent tool
  listing), but verify before declaring `mix precommit` green.
* **`AgentTracker.register` signature** — adding `:request_id` is a
  non-breaking extension (optional keyword or new arity), but it touches
  every caller. Verify the §G Recorder-coverage gate doesn't assert a specific
  arity.
* **`StepAction` await path** — switching from `ask_sync` to `ask` +
  `await_completion` is the right move for typed/meta capture but is a
  behavior change. Run the existing `IterativeWorkflow` test suite (and any
  `RunSkill` workflow tests) before declaring done; the contract for the
  spawned task lifecycle (errors, timeouts, cleanup) needs to remain
  identical.

## Out of scope (deferred)

* Wiring the remaining five workers (Coder, Researcher, Refactorer, TestRunner,
  DocsWriter).
* Recursive Zoi normalization for nested-array enums (the keyword-enum +
  `coerce: true` workaround covers v1; deeper coercion is upstream's call).
* **Follow-up turn tracking** — `send_to_agent` creates a new `request_id`
  per follow-up message, so `get_agent_result` reports only the initial spawn
  task. v2 should add `latest_request_id` to the tracker entry and have
  `send_to_agent` keep it current.
* Replacing `reasoning/certificates.ex::parse_certificate/1` regex parsing
  with typed output.
* Replacing `Reasoning.Output.extract_*` with a typed-only path (the fallback
  remains until all workers are typed).
* Per-call `output:` overrides at the JidoClaw CLI/REPL layer (native
  `Jido.AI.Agent.ask/3` already supports it; surfacing in the REPL is its own
  task).
