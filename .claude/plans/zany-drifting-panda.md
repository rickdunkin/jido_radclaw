# Compactor T1-2 Review Follow-up: Transcript Fidelity + Mode + Default Derivation

## Context

T1-2 (`JidoClaw.Reasoning.Compactor`, plan `.claude/plans/toasty-enchanting-muffin.md`) shipped and passed its own test suite. A code review surfaced three issues that contradict the plan and / or the module docs:

| ID | File / Line | Issue |
|---|---|---|
| **P1** | `lib/jido_claw/reasoning/compactor.ex:322-335` (`build_transcript/1` + `format_message_line/1`) | Summarizer transcript only renders `Message.content`. For `:tool_call`/`:tool_result` rows that field is a one-line preview (`read_file(path: "...")` / `read_file → ok`); the actual payload (file contents, search hits, command stdout, errors) lives in `metadata.arguments` / `metadata.result`. Once those request_ids are summarized and filtered out of the LLM window, the replacement summary cannot reconstruct what happened. **Correctness risk.** |
| **P2** | `lib/jido_claw/reasoning/compactor.ex:106-109` (`maybe_compact/3`) | The `mode: :off` short-circuit only handles `:off`. `mode: :manual` falls through to the automatic threshold path and triggers the summarizer from `on_before_cmd`. That contradicts the module docs at `config.ex:11-13` (":manual only runs when `Compactor.compact/3` is called explicitly"). |
| **P3** | `lib/jido_claw/reasoning/compactor/config.ex:122-138, 184-189` (`new/1` + `apply_derived_defaults/1`) | `new/1` seeds from `default/0` which already has `recompact_delta_threshold: 30`. `apply_derived_defaults/1` only recomputes when the *merged* value is `nil` or `:auto`. So `Config.new!(max_messages: 100).recompact_delta_threshold` returns `30`, not the documented `div(100, 2) == 50`. |

All three are local to `JidoClaw.Reasoning.Compactor` and its config; no callers, no telemetry schema change (new `reason: :manual_mode` / `stage: :load_snapshot` payload values are added under existing keys, but the event names, categories, and metadata key set are unchanged), no persisted JSONB shape change.

**Done** = `mix precommit` (compile --warnings-as-errors → jidoclaw.system_prompt.check → deps.unlock --unused → format → credo --strict → dialyzer --format short → test) is GREEN.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Tool-payload rendering location | New private helpers in `compactor.ex` (`format_tool_payload/2`, `render_envelope/1`, `truncate/2`). NOT a new public function in `ToolTranscript`. | Single consumer (the summarizer transcript). `ToolTranscript.summarize_args/2` and `result_summary/2` operate on raw tuples pre-normalization and are not the right shape. The compactor receives already-normalized envelopes from `metadata`. |
| Encoding for envelope payloads | `Jason.encode/1` first (envelopes are JSON-safe by construction — they round-trip through Postgres JSONB), fall back to `inspect(_, limit: :infinity, printable_limit: 800)` on `:error`. | Compact, deterministic, readable. Inspect would explode atoms-as-`":atom"` strings and tuple-as-`%{__tuple__: ...}` envelopes into hard-to-read shapes. |
| Per-tool-row payload budget | Hard `800` byte cap per call/result, with an `… (truncated, N bytes)` suffix when cut. | The whole transcript becomes the summarizer prompt body. A single 100KB file read shouldn't dominate. 800 bytes is roughly one paragraph — enough to preserve a short error message, a small file head, or a JSON object outline. The summarizer's `max_summary_chars` (4000) already constrains the output side. |
| Re-redaction | Skip. Metadata is redacted at `:append` time by `Message.Changes.RedactContent` (`message.ex:483-510`). | Documented idempotent but unnecessary. Avoids a pointless walk of every envelope on every compaction. |
| Atom-vs-string metadata keys | Read both: `Map.get(md, :arguments) \|\| Map.get(md, "arguments")` (same for `:result`). | Ash's `:map` attribute round-trips through JSONB; reads may return string keys depending on driver/codec. Defensive lookup matches the pattern already used by `RequestTransformer` at `compactor/request_transformer.ex` for `refs.request_id`. |
| `:manual` mode semantics in `maybe_compact/3` | Install the prior snapshot's `RequestTransformer` (so already-persisted summaries keep applying to live requests), emit `:skipped, reason: :manual_mode`, return `{:ok, mutated_action}`. Never invoke the summarizer. | Matches the docs. Preserves the "prior compaction still benefits this turn" property the auto path's below-threshold branch already has. `Compactor.compact/3` (the explicit entry) is unchanged and still works for manual runs. |
| `:manual` mode pattern-match style | Add a third head: `def maybe_compact(_agent, {:ai_react_start, params} = action, %Config{mode: :manual})`. Keep `:off` and `:auto` heads. | Mirrors the existing `:off` head shape. Easier to read than a `case config.mode` inside the body. Credo will not flag it. |
| `P3` fix location | `apply_derived_defaults/2` (arity bump) — takes the merged config + the *original overrides map*. Re-derives when `:max_messages` is in overrides but `:recompact_delta_threshold` is not. | The merged config has lost the information of "did the caller pass this key explicitly?" — we need the overrides map to know. Bumping the arity is the cleanest seam; the alternative (using a `nil` default in `default/0`) breaks `Config.default/0`'s contract that all fields are populated and would propagate through `validate!/1`. |
| Test mocking | All new tests use the existing `Application.put_env(:jido_claw, :compaction_summarizer, FakeBackend)` pattern from `compactor_test.exs:8-19`. | Established pattern. No new test infra. |

## Critical Files

| File | Change |
|---|---|
| `lib/jido_claw/reasoning/compactor.ex` | Add `:manual` clause for `maybe_compact/3` (P2). Rewrite `format_message_line/1` to dispatch on role and call new `format_tool_payload/2` + `render_envelope/1` + `truncate/2` + `utf8_safe_prefix/2` helpers (P1). |
| `lib/jido_claw/reasoning/compactor/config.ex` | Change `apply_derived_defaults/1 → /2`, pass `overrides_map` from `new/1`, re-derive `:recompact_delta_threshold` when caller overrode `:max_messages` without explicitly setting `:recompact_delta_threshold` (P3). |
| `test/jido_claw/reasoning/compactor/compactor_test.exs` | Add tests: (a) `:manual` mode in `maybe_compact/3` skips summarization, still installs transformer; (b) transcript renders `metadata.arguments` for `:tool_call` and `metadata.result` for `:tool_result` (uses a recording fake backend to capture the prompt). |
| `test/jido_claw/reasoning/compactor/config_test.exs` | Add tests for `new/1` derivation: passing only `max_messages: 100` → `recompact_delta_threshold: 50`; passing both (`max_messages` + `recompact_delta_threshold`) → caller value wins; passing only `max_messages: 7` (odd, with `keep_last_turns: 1, protect_first_n_turns: 0`) → `max(div(7,2), 1) == 3`; passing `max_messages: 2` with `keep_last_turns: 1, protect_first_n_turns: 0` → `recompact_delta_threshold: 1` (floor); existing `:auto` test continues to pass. |

No other files. No new modules. No migrations. No public-API changes (`Config.new/1` signature stays; `maybe_compact/3` signature stays).

## Implementation Steps

Each step independently green on `mix test`. Final gate is `mix precommit`.

### Step 1 — P3: Config default derivation

In `config.ex`:

1. Change `new/1` to capture `overrides_map` and pass it through:
   ```elixir
   def new(overrides) do
     base = default()
     overrides_map = normalize_overrides(overrides)
     config =
       base
       |> Map.from_struct()
       |> Map.merge(overrides_map)
       |> apply_derived_defaults(overrides_map)

     case validate(config) do
       :ok -> {:ok, struct!(__MODULE__, config)}
       {:error, _} = err -> err
     end
   end
   ```
2. Add a `normalize_overrides/1` helper (extract the existing `cond do` block).
3. Change `apply_derived_defaults/1` → `apply_derived_defaults/2`:
   ```elixir
   defp apply_derived_defaults(config, overrides_map) do
     explicit_rdt? = Map.has_key?(overrides_map, :recompact_delta_threshold)
     explicit_max? = Map.has_key?(overrides_map, :max_messages)
     rdt = Map.get(config, :recompact_delta_threshold)

     cond do
       explicit_rdt? and (is_nil(rdt) or rdt == :auto) ->
         Map.put(config, :recompact_delta_threshold, derive_rdt(config.max_messages))

       explicit_max? and not explicit_rdt? ->
         Map.put(config, :recompact_delta_threshold, derive_rdt(config.max_messages))

       true ->
         config
     end
   end

   defp derive_rdt(max_m) when is_integer(max_m) and max_m > 0,
     do: max(div(max_m, 2), 1)
   defp derive_rdt(_), do: 1  # validator will reject non-integer max_messages anyway
   ```

Tests in `config_test.exs` — keep each test's config valid against the capacity invariant (`max_messages > keep_last_turns + protect_first_n_turns`) by overriding the keep/protect defaults when shrinking `max_messages`:
- `Config.new!(max_messages: 100).recompact_delta_threshold == 50` (defaults: `keep_last_turns: 6, protect_first_n_turns: 2` → `100 > 8` ✓).
- `Config.new!(max_messages: 7, keep_last_turns: 1, protect_first_n_turns: 0).recompact_delta_threshold == 3` (odd → floor of `div(7, 2)`).
- `Config.new!(max_messages: 2, keep_last_turns: 1, protect_first_n_turns: 0).recompact_delta_threshold == 1` (floor → `max(div(2, 2), 1) == 1`).
- `Config.new!(max_messages: 100, recompact_delta_threshold: 11).recompact_delta_threshold == 11` (explicit wins over derivation).
- `Config.new!(max_messages: 60, keep_last_turns: 6).recompact_delta_threshold == 30` (unchanged when max not changed and rdt not passed).
- Existing `:auto` test (`config_test.exs:48-58`) continues to pass.

Do NOT use `max_messages: 1` — it fails the capacity invariant with any valid `keep_last_turns >= 1`.

### Step 2 — P2: `:manual` mode short-circuit

In `compactor.ex`, add a clause between the `:off` head (line 106) and the catch-all `Config{}` head (line 109):

```elixir
def maybe_compact(_agent, {:ai_react_start, params} = action, %Config{mode: :manual}) do
  ctx = Map.get(params, :tool_context) || %{}
  tenant_id = Map.get(ctx, :tenant_id)
  session_uuid = Map.get(ctx, :session_uuid)
  actor = Map.get(ctx, :actor)
  agent_id = Map.get(ctx, :agent_id)
  request_id = Map.get(params, :request_id) || generate_request_id()

  cond do
    is_nil(tenant_id) or is_nil(session_uuid) ->
      emit_skipped(:missing_context, agent_id, tenant_id, session_uuid, request_id)
      {:ok, action}

    existing_transformer_collision?(params) ->
      emit_skipped(:existing_request_transformer, agent_id, tenant_id, session_uuid, request_id)
      Logger.warning("[Compactor] skipping :manual install for session #{session_uuid}: " <>
                     "caller pre-set params[:request_transformer]")
      {:error, :existing_request_transformer}

    true ->
      base_metadata = %{
        tenant_id: tenant_id,
        session_uuid: session_uuid,
        agent_id: agent_id,
        request_id: request_id
      }

      case Storage.latest(session_uuid, tenant: tenant_id, actor: actor) do
        {:ok, snap} ->
          emit_skipped(:manual_mode, agent_id, tenant_id, session_uuid, request_id)
          {:ok, install_overrides(action, params, snap, request_id)}

        {:error, reason} ->
          Logger.warning(
            "[Compactor] (:manual) could not load snapshot for session " <>
              "#{session_uuid}: #{inspect(reason)}"
          )

          emit_error(:load_snapshot, reason, base_metadata)
          {:ok, install_overrides(action, params, nil, request_id)}
      end
  end
end
```

Telemetry consumers gain a new `reason: :manual_mode` value on the `:skipped` event AND a new `stage: :load_snapshot` value on the `:error` event for the storage-failure path; nothing pattern-matches on these enums. The failure path mirrors the `:auto` path at `compactor.ex:161-168` so consumers see a unified shape.

Tests in `compactor_test.exs`:
- New describe `"maybe_compact/3 — :manual mode"`:
  - Happy path: skips summarization (the recording summarizer backend receives no call); transformer is installed; with a prior snapshot present, the snapshot is threaded into `params.tool_context`; emits exactly one `event: :skipped, reason: :manual_mode`.
  - Storage failure: trigger via a valid-format-but-missing session uuid (`Ecto.UUID.generate()`) so `Storage.latest/2` returns `{:error, _}` from the real Ash read path (closer to a production storage failure than a malformed-id validation error); assert `{:ok, mutated_action}` with `request_transformer: RequestTransformer` and no snapshot in `tool_context`; assert an `event: :error, stage: :load_snapshot` was emitted (NOT `:skipped`); the summarizer is still not called.
  - Missing tool_context / collision paths return the same shapes as the `:auto` path's edge cases.

### Step 3 — P1: Tool-payload-aware transcript

In `compactor.ex`, replace `format_message_line/1` (lines 328-335) and `format_role/1` helpers with role-dispatching versions:

```elixir
@tool_payload_byte_budget 800

defp format_message_line(msg) do
  role = normalize_role(Map.get(msg, :role))
  seq = Map.get(msg, :sequence)
  seq_label = if is_integer(seq), do: "##{seq} ", else: ""
  body = format_body(role, msg)
  "[#{seq_label}#{role_label(role)}] #{body}"
end

defp format_body(:tool_call, msg) do
  content = Map.get(msg, :content) || ""
  payload = format_tool_payload(msg, [:arguments, "arguments"])
  if payload == "", do: content, else: content <> "\n  args: " <> payload
end

defp format_body(:tool_result, msg) do
  content = Map.get(msg, :content) || ""
  payload = format_tool_payload(msg, [:result, "result"])
  if payload == "", do: content, else: content <> "\n  result: " <> payload
end

defp format_body(_role, msg), do: Map.get(msg, :content) || ""

defp format_tool_payload(msg, keys) do
  case Map.get(msg, :metadata) do
    md when is_map(md) ->
      Enum.find_value(keys, "", fn k ->
        case Map.get(md, k) do
          nil -> nil
          val -> render_envelope(val)
        end
      end)

    _ ->
      ""
  end
end

defp render_envelope(value) do
  encoded =
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, limit: :infinity, printable_limit: @tool_payload_byte_budget)
    end

  truncate(encoded, @tool_payload_byte_budget)
end

defp truncate(text, max_bytes) when is_binary(text) do
  if byte_size(text) <= max_bytes do
    text
  else
    head = utf8_safe_prefix(text, max_bytes)
    extra = byte_size(text) - byte_size(head)
    head <> "… (truncated, #{extra} more bytes)"
  end
end

# UTF-8 codepoints are at most 4 bytes, so we back off at most 4 bytes
# before landing on a valid prefix. Guarantees String.valid?(prefix) so
# downstream JSON / provider encoders never see a malformed binary.
# Clamping max_bytes to byte_size(text) keeps direct callers (e.g. unit
# tests) from passing a budget larger than the binary into binary_part/3
# and crashing.
defp utf8_safe_prefix(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
  bounded = min(max_bytes, byte_size(text))
  do_utf8_safe_prefix(text, bounded)
end

defp do_utf8_safe_prefix(_text, n) when n <= 0, do: ""

defp do_utf8_safe_prefix(text, n) do
  candidate = binary_part(text, 0, n)
  if String.valid?(candidate) do
    candidate
  else
    do_utf8_safe_prefix(text, n - 1)
  end
end

defp normalize_role(role) when is_atom(role), do: role
defp normalize_role(role) when is_binary(role) do
  case role do
    "user" -> :user
    "assistant" -> :assistant
    "tool_call" -> :tool_call
    "tool_result" -> :tool_result
    "system" -> :system
    "reasoning" -> :reasoning
    _ -> :unknown
  end
end
defp normalize_role(_), do: :unknown

defp role_label(:unknown), do: "msg"
defp role_label(role), do: Atom.to_string(role)
```

Notes:
- Total per-line bytes are roughly `content + 800 + delimiter` — bounded.
- `truncate/2` is UTF-8-safe via `utf8_safe_prefix/2`: at most 4 bytes are backed off so the returned prefix always satisfies `String.valid?/1`. This is stricter than `summarizer.ex:142-149` `trim_to_max/2`, which does a raw byte cut; that's fine for the existing summary trim (output already comes from the LLM as valid UTF-8) but the tool-payload path also serializes arbitrary user content (file bodies, command output) where a mid-codepoint cut could later trip JSON / provider encoders.
- Empty / missing metadata → no payload appended → behaviour identical to today.

### Cross-process prompt capture for the transcript-fidelity test

The summarizer runs inside `Task.Supervisor.async_nolink(JidoClaw.TaskSupervisor, fn -> ... end)` (`summarizer.ex:81-84`) — a separate process. The test process's pid cannot be reached via `self()` from inside a fake backend, and the process dictionary does not cross process boundaries. Use the global `Application` env as the channel:

```elixir
defmodule PromptCaptureBackend do
  @behaviour JidoClaw.Reasoning.Compactor.Summarizer

  @impl true
  def summarize(prompt, _opts) do
    case Application.get_env(:jido_claw, :compaction_test_capture_pid) do
      pid when is_pid(pid) -> send(pid, {:compactor_prompt, prompt})
      _ -> :noop
    end

    {:ok, "FIXED-SUMMARY"}
  end
end
```

Setup in the test — save and restore any preconfigured values rather than blanket-deleting (mirrors the pattern at `compactor_test.exs:15-20`):

```elixir
setup do
  original_backend = Application.get_env(:jido_claw, :compaction_summarizer)
  original_capture = Application.get_env(:jido_claw, :compaction_test_capture_pid)

  Application.put_env(:jido_claw, :compaction_summarizer, PromptCaptureBackend)
  Application.put_env(:jido_claw, :compaction_test_capture_pid, self())

  on_exit(fn ->
    restore_env(:compaction_summarizer, original_backend)
    restore_env(:compaction_test_capture_pid, original_capture)
  end)

  :ok
end

defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)
```

Assertion: `assert_receive {:compactor_prompt, prompt}; assert String.contains?(prompt, "hello world")`. Tests using this backend MUST be `async: false` (already the case for `compactor_test.exs`) because the Application env channel is global.

Tests in `compactor_test.exs`:
- New describe `"transcript fidelity"` (uses `PromptCaptureBackend`, `async: false`):
  - Seed a session with a `:tool_call` row carrying `metadata: %{tool_name: "read_file", arguments: %{path: "/foo"}}` and a `:tool_result` row carrying `metadata: %{tool_name: "read_file", result: %{status: :ok, value: "hello world", error: nil, effects: nil, raw_inspect: nil}}`. Atom-key variant.
  - Assert the captured prompt contains both `"hello world"` (from the result envelope) AND `"/foo"` (from the arguments envelope).
  - **String-key variant**: seed a second pair with `metadata: %{"arguments" => %{"path" => "/bar"}}` and `metadata: %{"result" => %{"status" => "ok", "value" => "string-key payload"}}` (mirroring what JSONB hands back). Assert the captured prompt contains both `"/bar"` AND `"string-key payload"`.
  - Assert today's behavior STILL holds for plain `:user`/`:assistant` rows (content rendered as-is, no `args:` / `result:` suffix).
- Indirect truncation coverage (preferred — exercises the production path; do NOT expose `truncate/2` publicly for tests): seed a `:tool_result` row whose `metadata.result` envelope encodes to > 800 bytes (e.g. include a 2KB `value` string). Assert the captured prompt contains the `… (truncated, ` marker AND remains `String.valid?/1`, AND that the prompt's substring after the relevant `result:` delimiter is no longer than `800 + length(suffix)` bytes.
- Direct unit test for `utf8_safe_prefix/2` (kept defp; call via `Code.eval_string/1` in the test OR — cleaner — keep the function private and assert the UTF-8 invariant indirectly via a transcript line that includes a multi-byte codepoint near the boundary). Fixture: a string whose UTF-8 codepoint straddles the 800-byte cut. Assert: `String.valid?/1` is true on the returned prefix and `byte_size(prefix) <= 800`.

### Step 4 — `mix precommit` gate

Run the full suite locally:
```
mix precommit
```

If `credo --strict` complains:
- `Credo.Check.Refactor.Nesting`: the `:manual` clause has a `cond do` inside; if Credo flags nesting depth, factor a small `manual_install/4` helper.
- `Credo.Check.Refactor.LongQuoteBlocks`: not relevant (no macros touched).
- `Credo.Check.Design.AliasUsage`: `Jason` is already aliased project-wide via Elixir's default; no new aliases needed.

If `dialyzer --format short` complains:
- Specs on the new helpers are private (`defp`) so no `@spec` required, but the `format_message_line/1` return type is still `String.t()`; nothing changes for callers.

If `format --check-formatted` complains: `mix format` once.

If `compile --warnings-as-errors` complains: `Jason.encode/1`'s `{:ok, _} | {:error, _}` return — pattern matched explicitly above.

## Reused Utilities

- `Jason.encode/1` (transitively via the `jason` dep already in `mix.exs`) — envelopes are JSON-safe.
- `Map.get/3` with atom-then-string key lookup — matches `RequestTransformer`'s pattern.
- `Application.get_env(:jido_claw, :compaction_summarizer)` test seam — `compactor/summarizer.ex:137-140`.
- `emit_skipped/5`, `install_overrides/4`, `existing_transformer_collision?/1`, `generate_request_id/0` — already in `compactor.ex`.
- `Storage.latest/2` — already in `compactor.ex` for the `:auto` path; the `:manual` clause just calls it once.

## Verification

1. **Unit tests pass**:
   ```
   mix test test/jido_claw/reasoning/compactor/config_test.exs
   mix test test/jido_claw/reasoning/compactor/compactor_test.exs
   ```
2. **Integration tests still pass** (no expected behavior change for `:auto`):
   ```
   mix test test/jido_claw/reasoning/compactor/integration_test.exs
   mix test test/jido_claw/agent/defaults_compaction_test.exs
   ```
3. **Trace / persistence unaffected**:
   ```
   mix test test/jido_claw/trace_test.exs test/jido_claw/trace/persistence_test.exs
   ```
4. **Manual smoke check (optional)** via Tidewave:
   - Build a `Config{mode: :manual, ...}`; call `Compactor.maybe_compact(nil, {:ai_react_start, %{tool_context: %{tenant_id: t, session_uuid: s}}}, cfg)`; confirm the returned action has `request_transformer: RequestTransformer` and the summarizer was NOT invoked.
   - Seed a `:tool_result` row with a non-trivial `metadata.result` envelope; call `Compactor.compact/3`; inspect the persisted `Session.metadata["compaction"]["summary"]` — it should reference content that only existed in `metadata.result`.
5. **Done gate**:
   ```
   mix precommit
   ```
   Must exit 0. This is the completion criterion.

## Out of Scope

- Backfilling `refs.request_id` onto legacy untagged messages (T1-2 v1 limitation, documented).
- Introducing a public `ToolTranscript.render_envelope/1` for non-compactor callers (no consumer; refactor when one shows up).
- Changing the per-row 800-byte budget into a config opt (premature; revisit if telemetry shows a real need).
- Per-agent compaction keying for workers (v2, unrelated).
- Spark DSL conversion of `compaction:` opts (T3-7 rules it out).

## Risk

- **Token-budget regression**: tool-payload rendering inflates the prompt size. Budget per row is 800 bytes; with a typical 6-turn source slice × 2 tool rows per turn, worst case ~10KB additional prompt body. Within ReqLLM's request envelope. Monitor `[:jido_claw, :compaction, :event]` for `summarizer_timeout` increases after rollout.
- **`Jason.encode` failure on weird envelope**: handled — falls back to `inspect/2`. No path raises.
- **String keys from JSONB**: atom-then-string lookup covers it; no extra code path needed for either case.
