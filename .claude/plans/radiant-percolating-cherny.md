# T1-3 Structured Output — Code Review Follow-ups

## Context

`46e1f87` and the `toasty-baking-kernighan.md` round both landed structured
output across all seven workers + the workflow consumer path. A subsequent
code review surfaced two P2 defects that survived the round; both validated
against the current tree.

**Finding 1 (P2) — Artifact "additional keys allowed" is a lie on the wire.**

The contract advertised to the LLM in three places —
- worker descriptions ("…plus any extra string runtime details — use `{}` if none") at
  `lib/jido_claw/agent/workers/coder.ex:6`, `docs_writer.ex:6`,
  `refactorer.ex:6`, `researcher.ex:6`, `test_runner.ex:6`
- the structured-JSON branch of `inject_produces_instruction/2`
  (`lib/jido_claw/workflows/step_action.ex:204`: *"known keys: url, port,
  files; additional keys allowed"*)
- the Zoi schemas, which use `unrecognized_keys: :preserve` on the `artifacts`
  sub-object

…does not match the JSON Schema the LLM actually sees. `Jido.AI.Output.instructions/1`
(`deps/jido_ai/lib/jido_ai/output.ex:154`) injects the JSON Schema produced
by `ReqLLM.Schema.to_json/1`, and that path's
`inject_zoi_metadata/2` for `%Zoi.Types.Map{}` at
`deps/req_llm/lib/req_llm/schema.ex:296` unconditionally sets
`"additionalProperties": false` on the emitted object, overwriting whatever
Zoi's own encoder would have produced for `:preserve`. Net effect: providers
that strictly enforce JSON Schema (OpenAI structured outputs, Gemini) will
reject extras; the LLM's prompt and our descriptions promise something
already forbidden one layer below.

**Finding 2 (P2) — String-keyed typed-output drops artifacts (and the whole typed map).**

`request_meta_output/1` (`lib/jido_claw/reasoning/output.ex:73-75`) was
written to accept both atom- and string-keyed meta shapes, but
`typed_request_output/1` (`output.ex:84-95`) immediately re-matches
`%{status: status}` with atom keys and atom-valued `:validated/:repaired`
— so a fully string-keyed shape (`%{"meta" => %{"output" => %{"status" =>
"validated"}}, "result" => ...}`) returns `nil` and the consumer falls back
to `request_result/1` + `extract_result/1`. Even if that were fixed,
`await_step/4` (`lib/jido_claw/workflows/step_action.ex:157`) reads
`Map.get(m, :artifacts, %{})` — atom-only — so a string-keyed `"artifacts"`
in the typed map would silently disappear.

A Tidewave eval reproduced the bug: input
`%{"summary" => "s", "artifacts" => %{"url" => "u"}}` produces the summary
but no artifacts.

**Definition of done**: `mix precommit` passes. The reviewer noted a single
flaky `test/jido_claw/trace_test.exs:486` failure that recovered on rerun
(unrelated telemetry-ordering test); we treat that as a verification-time
signal — see Verification below.

---

## Phase A — Align the artifact contract with what the schema actually enforces

Close the contract instead of opening the schema. Opening the schema would
require either patching the `req_llm` dep or wrapping `Jido.AI.Output.json_schema/1`
in our own code path; closing the contract is a 6-file text change and
matches what the wire already enforces.

Keep `unrecognized_keys: :preserve` on the Zoi schemas — that flag still
helps at *parse* time (a non-compliant LLM emitting an extra key won't fail
validation), but we stop *advertising* it.

### A1. Strip the "extra string runtime details" promise from all 5 worker descriptions

Files (all on line 6 of each):

- `lib/jido_claw/agent/workers/coder.ex`
- `lib/jido_claw/agent/workers/docs_writer.ex`
- `lib/jido_claw/agent/workers/refactorer.ex`
- `lib/jido_claw/agent/workers/researcher.ex`
- `lib/jido_claw/agent/workers/test_runner.ex`

Replace the fragment:

> `…optional `url`/`port`/`files` plus any extra string runtime details — use `{}` if none).`

with:

> `…optional `url`/`port`/`files` — use `{}` if none).`

### A2. Drop "additional keys allowed" from `inject_produces_instruction/2`

`lib/jido_claw/workflows/step_action.ex:196-213` — change line 203-204 from:

```
- If your final response is a structured JSON object, include them as
  string values in the `artifacts` field (known keys: url, port,
  files; additional keys allowed).
```

to:

```
- If your final response is a structured JSON object, include them as
  string values in the `artifacts` field (`url`, `port`, `files`).
```

The fenced-block fallback (lines 205-211) stays — it's still the path for
free-form workers that don't have a schema.

### A3. Update the T1-3 adoption doc to match the wire contract

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md:114` still describes
the artifact sub-object as accepting "any extra runtime detail the LLM
discovers" via `unrecognized_keys: :preserve`. That's true at parse time
inside Zoi but **false on the wire** — `ReqLLM.Schema` emits
`additionalProperties: false`. Rewrite the bullet so the wire contract
(`url` / `port` / `files` only) is what's documented, and call out
`unrecognized_keys: :preserve` as *internal parse-time tolerance* for
defiant LLM output, not an advertised capability.

Proposed replacement for the line-114 bullet:

> **Artifacts sub-object**: every workflow-touching worker (Coder,
> Researcher, TestRunner, Refactorer, DocsWriter) carries an `artifacts`
> sub-object with known optional keys (`url`/`port`/`files`) — that's the
> full wire contract the LLM sees (`ReqLLM.Schema` emits
> `additionalProperties: false`, so extras are forbidden by the JSON
> Schema injected into the prompt). The Zoi schema keeps
> `unrecognized_keys: :preserve` as **internal parse-time tolerance** so a
> defiant LLM emitting an unexpected key won't fail validation; the docs
> and prompt never promise that capability. Verifier and Reviewer omit
> the sub-object (evaluator/reviewer roles — no produces metadata). A
> `Zoi.map(key_type, value_type)` was tried first but crashes in
> `Jido.AI.Output`'s zoi-input normalizer
> (`deps/jido_ai/lib/jido_ai/output.ex:372` only recognises
> `Zoi.Types.Map` field-mode); the sub-object form side-steps that and
> still satisfies the existing `inject_produces_instruction` vocabulary.

If line 115's mention of `inject_produces_instruction/2` ("use the
`artifacts` field when emitting structured JSON") is still accurate after
A2 lands, leave it. If the wording shifts noticeably during A2, update
line 115's parenthetical to match the new prompt text.

---

## Phase B — Make string-keyed typed-output round-trips work end-to-end

### B1. `typed_request_output/1` — normalize status across atom/string shapes

`lib/jido_claw/reasoning/output.ex:84-95`. Today the function only matches
atom-keyed `%{status: status}` with atom values `:validated/:repaired`.
Rather than splitting into two near-identical clauses, normalize the
status value through a tiny helper so any mix of atom/string keys *and*
atom/string values is handled uniformly:

```elixir
def typed_request_output(request) when is_map(request) do
  case output_status(request_meta_output(request)) do
    status when status in [:validated, :repaired, "validated", "repaired"] ->
      typed_result(request)

    _ ->
      nil
  end
end

def typed_request_output(_), do: nil

defp output_status(meta) when is_map(meta),
  do: Map.get(meta, :status) || Map.get(meta, "status")

defp output_status(_), do: nil

defp typed_result(request) do
  case request_result(request) do
    result when is_map(result) -> result
    _ -> nil
  end
end
```

`request_result/1` already handles both atom and string keys
(`output.ex:63-65`), so a string-keyed request's `"result"` is recovered
for free. The single match list `[:validated, :repaired, "validated",
"repaired"]` keeps the contract explicit and accepts mixed shapes — a meta
map that uses atom `:status` with string value `"validated"` (or vice
versa) is harmless instead of silently returning `nil`.

### B2. `await_step/4` — read artifacts under either key

`lib/jido_claw/workflows/step_action.ex:155-159` — replace the atom-only
`Map.get(m, :artifacts, %{})` with a both-keys lookup:

```elixir
{text, typed_artifacts} =
  case typed do
    %{} = m ->
      artifacts = Map.get(m, :artifacts) || Map.get(m, "artifacts") || %{}
      {Output.extract_result(m), artifacts}

    _ ->
      {raw_text, %{}}
  end
```

`normalize_artifacts/1` (already in place at `step_action.ex:240-244`)
stringifies both keys and values, so downstream consumers see the same
shape regardless of which key the typed map used.

`Output.extract_result/1` already covers string-keyed `"summary"` /
`"reasoning"` (`output.ex:48,50`), so the text projection works for the
string-keyed case without further changes.

### B3. Harden `to_string_safe/1` against non-string artifact values

`lib/jido_claw/workflows/step_action.ex:248-250` currently has:

```elixir
defp to_string_safe(v) when is_binary(v), do: v
defp to_string_safe(v) when is_list(v), do: Enum.join(v, ", ")
defp to_string_safe(v), do: to_string(v)
```

Because we're keeping `unrecognized_keys: :preserve` on the Zoi schemas
(internal parse tolerance, see A3), a non-compliant LLM emitting an extra
artifact value as a map or nested object would reach
`to_string_safe(map)` and `to_string/1` raises a `Protocol.UndefinedError`
for `Map`. Add a map clause that falls back to `inspect/1` so a defiant
shape lands as a readable string instead of crashing the workflow:

```elixir
defp to_string_safe(v) when is_binary(v), do: v
defp to_string_safe(v) when is_list(v), do: Enum.join(v, ", ")
defp to_string_safe(v) when is_map(v), do: inspect(v)
defp to_string_safe(v), do: to_string(v)
```

Cheap defense-in-depth, paired with B2 — if A1/A2/A3's contract close is
ignored by the model and B2 surfaces the extras, we render them as text
instead of letting `String.Chars` blow up.

---

## Phase C — Tests

Extend the existing test files; do not create new directories.

### C1. `test/jido_claw/reasoning/output_test.exs`

Add a `describe "typed_request_output/1"` block covering:

1. Atom-keyed `:validated` shape → returns the typed result map (regression
   cover for the pre-existing path).
2. Atom-keyed `:repaired` shape → returns the typed result map.
3. **String-keyed `"validated"` shape** → returns the typed result map
   (new contract).
4. **String-keyed `"repaired"` shape** → returns the typed result map.
5. Missing meta (no `meta`/`"meta"` key) → returns `nil`.
6. `status: :error` → returns `nil`.

Sample for the new string-keyed case:

```elixir
test "extracts typed result from a fully string-keyed shape" do
  request = %{
    "result" => %{"summary" => "s", "artifacts" => %{"url" => "u"}},
    "meta" => %{"output" => %{"status" => "validated"}}
  }

  assert Output.typed_request_output(request) ==
           %{"summary" => "s", "artifacts" => %{"url" => "u"}}
end
```

### C2. `test/jido_claw/workflows/step_action_test.exs`

Add one fake agent server `StringKeyedFakeAgentServer` (mirroring the
existing `ArtifactsFakeAgentServer` at lines 378-401) that returns a
**fully string-keyed inner request map** — `meta`, `result`, `status` all
under string keys. The outer envelope `%{status: :completed, result:
inner}` stays atom-keyed because that's what
`Jido.AgentServer.await_completion` always produces; the *inner* request
map (`inner` here) is what `request_meta_output/1` /
`typed_request_output/1` / `request_result/1` actually pattern-match on,
and `request_meta_output/1` only handles fully-atom or fully-string at
that level (`output.ex:73-75`).

```elixir
defmodule StringKeyedFakeAgentServer do
  @moduledoc false

  # End-to-end string-keyed round-trip: the *inner* request map (meta +
  # result + artifacts) is fully string-keyed (the shape a JSON-decoded
  # request map produces). The outer envelope matches what
  # Jido.AgentServer.await_completion emits.
  def await_completion(_pid, _opts) do
    {:ok,
     %{
       status: :completed,
       result: %{
         "status" => "completed",
         "result" => %{
           "status" => "completed",
           "summary" => "Started server",
           "files_changed" => [],
           "notes" => "",
           "artifacts" => %{"url" => "http://localhost:4000", "port" => "4000"}
         },
         "meta" => %{"output" => %{"status" => "validated", "schema_kind" => "map"}}
       }
     }}
  end
end
```

Add one test in the existing `describe "run_step_async/7 — typed_output
capture"` block that wires this server in and asserts:

- `step_result.typed_output` is the passed-through string-keyed map —
  assert `Map.get(step_result.typed_output, "summary") == "Started
  server"` (the B1 normalizer returns the result map unchanged, it does
  not atomize keys).
- `step_result.result == "Started server"` (via `extract_result/1`'s
  existing string-keyed `"summary"` clause at `output.ex:48`).
- `step_result.artifacts["url"] == "http://localhost:4000"` and
  `step_result.artifacts["port"] == "4000"` (`normalize_artifacts/1`
  stringifies keys, so the assertion is by string key regardless of input
  shape).

This single test covers B1 + B2 end-to-end; if either is incomplete the
assertion fails. Together with the focused `typed_request_output/1`
cases from C1, that's enough to lock the contract.

---

## Phase D — Verification

1. `mix format` (formatter touches the edited lines).
2. `mix compile --warnings-as-errors`.
3. Focused suites first:
   `mix test test/jido_claw/reasoning/output_test.exs test/jido_claw/workflows/step_action_test.exs test/jido_claw/agent/workers/worker_output_schemas_test.exs`.
4. `mix precommit` — the bar for "done".
5. If `test/jido_claw/trace_test.exs:486` flakes (it did once in the prior
   review run, recovered on rerun), investigate the root cause rather than
   dismissing it as unrelated. Likely a `:telemetry.execute` propagation
   ordering issue (the test asserts strict filter applied before "latest"
   pick on rapid back-to-back emits). If reproducible, add a sync barrier
   between the two `:telemetry.execute` calls at `trace_test.exs:495,501`
   or strengthen `H.sync_collector/0`. Scope this as a sub-task only if it
   actually flakes during verification — do not pre-emptively change
   trace_test.

Manual smoke (not blocking): a Tidewave eval of `typed_request_output/1`
with the string-keyed shape from C1 should return the typed map (not `nil`),
and one of the structured-output workers run via `mix jidoclaw` should
still produce coherent typed output now that the prompt no longer promises
extras the schema forbids.

---

## What this plan deliberately does NOT do

- **Does not patch `req_llm` or wrap `Jido.AI.Output.json_schema/1`.**
  Opening the schema upstream is the alternate fix for Finding 1; we
  chose to close the contract instead because it's localized and matches
  the wire reality across providers.
- **Does not remove `unrecognized_keys: :preserve` from the Zoi schemas.**
  That flag is parse-time tolerance, not an advertised contract; keeping
  it means a defiant LLM emitting an unexpected key won't fail validation.
- **Does not touch `Tools.GetAgentResult`.** It calls `typed_request_output/1`
  but doesn't index `:artifacts` directly — fixing B1 fixes its string-keyed
  case transitively.
- **Does not pre-emptively fix `trace_test.exs:486`.** Scoped as a
  verification-time contingency only.

---

## Implementation order

A1 (5 worker descriptions) → A2 (step_action prompt) → A3 (adoption doc)
→ B1 (output.ex typed_request_output + status normalizer) → B2 (step_action
artifact lookup) → B3 (`to_string_safe/1` map clause) → C1 (output_test)
→ C2 (step_action_test fully string-keyed fake) → D (`mix precommit`).
