# Plan: Resolve Structured-Error Contract Code-Review Findings

## Context

The Structured Error Contract (commit `0ad7dc3`) shipped `JidoClaw.Tools.Error` to normalize tool failures into the wire shape `%{code: atom, message: String.t(), details: map}`. A subsequent code review surfaced four findings. Audit (see `lib/jido_claw/tools/error.ex`, `test/jido_claw/error/tools_wire_format_test.exs`, `test/jido_claw/tools/spawn_agent_test.exs`) shows the reviewer's specific line numbers are off, but **three of the four findings cover real bugs**, plus one adjacent leak the reviewer didn't flag but their Tidewave repro likely hit.

| # | Reviewer finding | Validation |
| --- | --- | --- |
| F1 | Wire `details` can stop being a map | **Real (nested only).** Top-level `sanitize_details/1` stays a map (existing test at `tools_wire_format_test.exs:169`); `cap_collection/1` at `error.ex:340-346` returns a STRING for nested oversized maps/lists, breaking type stability of nested values. |
| F2 | String truncation can produce invalid UTF-8 | **Misdiagnosed, but a broader leak exists.** `truncate_string/1` already pipes through `OutputLimit.valid_utf8_prefix/1` (`error.ex:331-336`) and a multi-byte test at `tools_wire_format_test.exs:183` passes. The real gaps are unbounded **message strings** in `wire.message` (foreign `exception_message/1`, class `JidoClaw.Error.format/1`, etc.) AND unbounded `Exception.message`/`inspect` in `child_error_summary/1` / `safe_exception_message/1`. A 3 KB `RuntimeError` reaches the LLM via `wire.message`, not `wire.details`, so the original F2 hypothesis pointed at the right symptom but the wrong path. |
| F3 | PID/ref/port handling stringifies runtime handles | **Misdiagnosed.** PIDs/refs/ports are dropped via `@drop` sentinel at `error.ex:284-285`. Inside tuples they become atom `:dropped_runtime_handle` (line 311) — a placeholder atom, not a runtime handle, not a string. The current behavior matches the plan's security intent. Doc clarification only. |
| F4 | Incomplete tool migration | **Real, wrong line numbers.** `send_to_agent.ex:72`, `kill_agent.ex:40`, `spawn_agent.ex:56` are already migrated. But `spawn_agent.ex:150,153` return bare atoms `{:error, :max_children}` / `{:error, :max_depth}` which produce a lossy wire shape with no limit/current details. |

## Changes

### Commit A — `Tools.Error`: preserve container type + cap nested binaries

Both fixes are in `lib/jido_claw/tools/error.ex` and share test scaffolding in `test/jido_claw/error/tools_wire_format_test.exs`.

**F1 — `cap_collection/1` (lines 340-346):** branch on map vs list, return container-typed placeholders aligned with the top-level summary shape:

```elixir
defp cap_collection(collection) when is_map(collection) do
  if approximate_byte_size(collection) > @max_collection_bytes do
    %{truncated: true, description: describe(collection)}
  else
    collection
  end
end

defp cap_collection(collection) when is_list(collection) do
  if approximate_byte_size(collection) > @max_collection_bytes do
    [%{truncated: true, description: describe(collection)}]
  else
    collection
  end
end
```

The placeholder shape mirrors the top-level `%{truncated: true, description: ..., kept: ...}` at `error.ex:259-263` (minus `kept`, since there is no allow-list at depth). `describe/1` already self-labels via `"map with N keys"` / `"list with N items"`.

**F2 — wrap every unbounded binary route, both `wire.message` and `wire.details`:**

The contract is "wire messages and detail strings are byte-bounded." Two layers need fixing:

*Top-level `wire.message` (10 sites in `normalize/1`)*. Each path that assigns `message:` from a user/foreign-supplied binary gets wrapped with `truncate_string/1`. Atom-derived messages (`humanize_atom/1` on lines 163, 167) are bounded and left alone.

| Line | Path | Wrap |
| --- | --- | --- |
| 84 | first-party leaf | `truncate_string(Exception.message(error))` |
| 94 | first-party class container — calls `JidoClaw.Error.format/1`, which concatenates all child `message/1` strings | `truncate_string(JidoClaw.Error.format(error))` |
| 110 | pre-normalized passthrough — user-supplied `message` | `truncate_string(message)` |
| 116 | foreign exception fallback | `truncate_string(exception_message(reason))` |
| 128 | map with `:message` atom key | `truncate_string(message)` |
| 136 | map with `"message"` string key | `truncate_string(message)` |
| 145, 153 | map with `:error` / `"error"` key | `truncate_string(message(error))` (the `defp message/1` helper) |
| 159 | binary fallback | `truncate_string(reason)` |
| 171 | other fallback | `truncate_string(inspect(reason))` |

*`wire.details` nested binary routes*:
- `sanitize_value/1` for exceptions (line 276-278): wrap `safe_exception_message(exception)` with `truncate_string/1`.
- `child_error_summary/1` (lines 229-239): wrap each of the three `Exception.message`/`inspect` call sites with `truncate_string/1`. Three clauses, three additions.

`truncate_string/1` already calls `OutputLimit.valid_utf8_prefix/1` so UTF-8 safety is inherited everywhere it lands; no separate UTF-8 plumbing needed.

**Scope note — legacy detail paths intentionally untouched.** The `normalize/1` clauses at lines 108-156 (`%{code, message, details}`, `%{message: ..., extra: huge}`, `%{error: _}`, tagged tuples, and the catch-all `inspect/1` fallback at line 171's `details.reason`) deliberately skip `sanitize_details/1` per the existing comment at lines 104-107: "OutputLimit and OutputRedaction already walk plain maps." Detail strings on those paths get bounded later by the `OutputLimit` pass in the tool wrapper — not by this module. This plan does **not** change that boundary.

Update the moduledoc (lines 2-23) to match the actual coverage: "Both `wire.message` and string values inside structured/exception `wire.details` are capped at `@max_string_bytes` (2 KB) and UTF-8 trimmed at the truncation boundary. Legacy plain-map detail strings are handled by the downstream `OutputLimit` pass in the tool wrapper, not here." — i.e., don't overclaim that *every* detail string is bounded inside `Tools.Error`.

**Tests** in `test/jido_claw/error/tools_wire_format_test.exs`:
- "oversized nested map stays a map" — `details: %{nested: <oversized 200-key map>}`; assert `is_map(wire.details.nested)` and `wire.details.nested.truncated == true`.
- "oversized nested list stays a list" — `details: %{items: <oversized list>}`; assert `is_list(wire.details.items)`, hd is `%{truncated: true, description: _}`.
- **"top-level message is truncated for first-party leaf"** — `Error.execution_error(String.duplicate("x", 3_000))`; assert `String.ends_with?(wire.message, "... (truncated)")` and `byte_size(wire.message) < 3_000`.
- **"top-level message is truncated for class container"** — `Error.to_class([Error.execution_error(String.duplicate("y", 1_500)), Error.execution_error(String.duplicate("z", 1_500))])`; the class `format/1` output exceeds 2 KB; assert `String.ends_with?(wire.message, "... (truncated)")` and `String.valid?(wire.message)`.
- **"top-level message is truncated for foreign exception"** — `JidoClaw.Tools.Error.normalize(RuntimeError.exception(String.duplicate("€", 1_000)))`; assert `String.valid?(wire.message)`, `String.ends_with?(wire.message, "... (truncated)")`, `byte_size(wire.message) < 3_000`. (Routes through line 116 — the `def normalize(%module{} = reason)` clause.)
- **"top-level message is truncated for binary fallback"** — `normalize(String.duplicate("x", 3_000))`; assert `wire.message` is truncated.
- "nested exception message inside details is truncated" — embed a `RuntimeError` whose `message/1` returns 3 KB in a first-party leaf's `details:`; assert `String.ends_with?(wire.details.<key>.message, "... (truncated)")`.
- "class container child summary message is truncated" — same as previous but for `wire.details.errors` produced by `child_error_summary/1`.

### Commit B — `Tools.Error`: document tuple drop-sentinel behavior

Doc-only change in `lib/jido_claw/tools/error.ex`. No behavior change. No test change.

- Moduledoc (lines 2-23): add one sentence to the existing `OutputRedaction`/`OutputLimit` paragraph clarifying that PIDs/refs/ports are **dropped** from maps and lists, and replaced with atom `:dropped_runtime_handle` inside tuples (where positional structure can't tolerate missing elements).
- Add a **regular code comment** (single-line `#`) immediately above the `sanitize_value/1` tuple clause at line 306 explaining the design choice: positional data like `{:ok, pid}` from `GenServer.start_link` preserves the `:ok` discriminator; wholesale tuple-replacement would lose it. **Do NOT use `@doc false` here** — module attribute doc tags on a private `defp` raise a compile-time warning and break `compile --warnings-as-errors`.

### Commit C — `SpawnAgent`: structured spawn-limit errors

`lib/jido_claw/tools/spawn_agent.ex` already aliases `JidoClaw.Error` (line 37). Replace `enforce_spawn_limits/1` at lines 147-158. **Compute `current`/`limit`/`depth` once per branch** so the message string and `details` map stay internally consistent (avoids `child_count()` racing between the guard and the message build):

```elixir
defp enforce_spawn_limits(context) do
  current_children = agent_tracker().child_count()
  child_limit = max_children()
  current_depth = swarm_depth(context)
  depth_limit = max_depth()

  cond do
    current_children >= child_limit ->
      {:error,
       Error.execution_error(
         "Maximum concurrent child agents reached (#{current_children}/#{child_limit}).",
         phase: :spawn_limit,
         details: %{reason: :max_children, limit: child_limit, current: current_children}
       )}

    current_depth >= depth_limit ->
      {:error,
       Error.execution_error(
         "Maximum swarm depth reached (#{current_depth}/#{depth_limit}).",
         phase: :spawn_limit,
         details: %{reason: :max_depth, limit: depth_limit, depth: current_depth}
       )}

    true ->
      :ok
  end
end
```

Rationale: `phase: :spawn_limit` slots next to the existing `phase: :spawn` for runtime spawn failures (line 59-62). `details.reason` preserves the original atom so any downstream consumer keying on `:max_children`/`:max_depth` keeps working. `phase: :spawn_limit` lands at `wire.details.phase` after `error_details/1` overlays it (see `error.ex:209-213`).

**Tests** at `test/jido_claw/tools/spawn_agent_test.exs:63-79`: update the two tests. `JidoClaw.Tools.Action` (the `use` macro that wraps `SpawnAgent`) applies `Tools.Error.normalize_result/1` to the return of `run/2`, so direct callers of `SpawnAgent.run/2` receive `{:error, wire_map}` — not a struct. Assert the **wire shape**:

- Line 63 ("rejects spawning when the child cap is reached"): replace
  `assert {:error, %{code: :max_children, message: "max children", details: %{}}} = ...`
  with:
  ```elixir
  assert {:error, wire} =
           SpawnAgent.run(%{template: "coder", task: "do work"}, %{tool_context: %{}})

  assert wire.code == :execution_error
  assert wire.message =~ "Maximum concurrent child agents reached (0/0)"
  assert wire.details.reason == :max_children
  assert wire.details.limit == 0
  assert wire.details.current == 0
  assert wire.details.phase == :spawn_limit
  ```
- Line 70 ("rejects spawning when swarm depth is reached"): same pattern with `:max_depth`, `wire.details.depth == 1`, `wire.details.limit == 1`, and the appropriate message substring.

No separate "round-trip" test is needed — the existing tests already exercise `run/2` through the wrapper, which IS the wire contract.

## Critical files

| File | Why |
| --- | --- |
| `lib/jido_claw/tools/error.ex` | F1, F2, F3 land here |
| `lib/jido_claw/tools/output_limit.ex` | Reuse `valid_utf8_prefix/1` (already wired via `truncate_string/1`) — read-only reference |
| `lib/jido_claw/tools/spawn_agent.ex` | F4 lands here |
| `test/jido_claw/error/tools_wire_format_test.exs` | F1, F2 new tests |
| `test/jido_claw/tools/spawn_agent_test.exs` | F4 test updates |

## Verification

Plan is "done" when `mix precommit` (alias in `mix.exs`) passes end-to-end:

```bash
mix precommit
```

This runs in order: `compile --warnings-as-errors`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format`, `credo --strict`, `dialyzer --format short`, `test`.

Gate-specific watches:

- **`compile --warnings-as-errors`**: no new aliases needed (`OutputLimit` already at `error.ex:25`, `Error` already at `spawn_agent.ex:37`).
- **`format`**: multi-clause `cap_collection/1` will reflow; benign.
- **`credo --strict`**: `enforce_spawn_limits/1` grows two `cond` branches but clause count is unchanged. If line-count or `Refactor.LongQuoteBlocks` trips, extract `max_children_error/0` and `max_depth_error/1` helpers.
- **`dialyzer --format short`**: `cap_collection/1` return type changes from `String.t() | map() | list()` to `map() | list()` — strictly narrower, callers at lines 292 and 302 stay valid. `truncate_string/1` is `String.t() -> String.t()` so wrapping `safe_exception_message/1`'s string output is clean.
- **`test`**: the two existing `spawn_agent_test.exs` tests at lines 63-79 currently pin the lossy bare-atom shape and **must be updated in Commit C** or `test` will fail.

Targeted runs during iteration:

```bash
mix test test/jido_claw/error/tools_wire_format_test.exs
mix test test/jido_claw/tools/spawn_agent_test.exs
```

End-to-end manual check (after all three commits land): a 3 KB multi-byte foreign exception's message lands in `wire.message`, not `wire.details`. Confirm via `iex -S mix`:

```elixir
err = RuntimeError.exception(String.duplicate("€", 1_000))
wire = JidoClaw.Tools.Error.normalize(err)

String.valid?(wire.message)                                # expect: true
String.ends_with?(wire.message, "... (truncated)")          # expect: true
byte_size(wire.message) < 3_000                             # expect: true
is_map(wire.details)                                        # expect: true
```

Also confirm that a class container with many oversized children produces a bounded `wire.message`:

```elixir
huge = String.duplicate("x", 1_500)
err  = JidoClaw.Error.to_class([
  JidoClaw.Error.execution_error(huge),
  JidoClaw.Error.execution_error(huge)
])
wire = JidoClaw.Tools.Error.normalize(err)

String.ends_with?(wire.message, "... (truncated)")          # expect: true
```

## Commit sequencing

Three commits, each compiling and `mix test` green on its own:

1. **A — `Tools.Error`: cap unbounded message + detail strings, preserve container type** — F1 + F2 together. Single file (`error.ex`) plus `tools_wire_format_test.exs`. Cohesive "everything that reaches the LLM is bounded" theme; shared test scaffolding.
2. **B — `Tools.Error`: document tuple drop-sentinel behavior** — F3 doc-only. Moduledoc paragraph + one inline comment. Separate so reviewers can ack the no-op fix without scrolling through A.
3. **C — `SpawnAgent`: structured spawn-limit errors** — F4 in `spawn_agent.ex` + `spawn_agent_test.exs`. Independent of A/B; could land in any order, but listed last so the wire-shape assertions exercise the post-A normalizer.

Per saved guidance: **do not commit without explicit user authorization** — these are slicing boundaries for the implementation pass, not blanket commit approval.
