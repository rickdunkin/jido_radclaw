# Resolve `ExSlop.Check.Refactor.LengthComparison` credo issues

## Context

`.credo.exs` was just edited (currently uncommitted) to enable `ExSlop.Check.Refactor.LengthComparison` (EXS4027), which flags any `length(list) <op> <integer literal>` comparison in any context — `length/1` walks the whole list just to answer a size question. `mix credo` now reports **118 issues, all from this one check** (the rest of the suite is clean): **2 in `lib/`, 116 in `test/`** across 50 files. Goal: rewrite every flagged site so `mix credo` exits clean, using the hybrid style the user picked (pattern matching for small counts, `Enum.count` for large ones), then commit the fixes together with the `.credo.exs` change.

Note: the check only flags `length/1` vs a literal. `Enum.count/1` comparisons, `length(a) == length(b)`, and bare `length/1` as a value are not flagged, and no other enabled ExSlop check flags `Enum.count`.

## Fix rules (user-approved hybrid)

| Flagged shape | Replacement | Sites |
|---|---|---|
| `assert length(x) == 1` | `assert [_] = x` — or `assert [item] = x` when the test then uses `hd(x)` / `List.first(x)` / `Enum.at(x, 0)`; replace those uses with `item` | ~38 |
| `assert length(x) == 2` / `== 3` | `assert [_, _] = x` / `assert [_, _, _] = x` | ~53 |
| `length(x) >= 2` / `>= 3`, no message | `assert [_, _ \| _] = x` / `assert [_, _, _ \| _] = x` (or `match?/2` outside assert position) | 5 |
| `>= n` **with a custom message** | `assert match?([_, _ \| _], x), "message"` — see hard rule below | 2 |
| `== n` for n ≥ 4 (`4,5,7,9,20,300`), `<= 3`, `<= 100`, `>= 8` | `assert Enum.count(x) == n` (or `<=`/`>=`) | ~18 |

Implementation cautions:
- **Hard rule — custom-message assertions must never become bare pattern assignments.** `assert [_, _ | _] = x, "message"` loses the message and raises `MatchError` instead of a labeled assertion failure. Use `assert match?(pattern, x), "message"` (or `Enum.count` for large n). Exactly 3 flagged sites carry messages; all are named in the special cases below.
- Bind-when-used applies **broadly**, not just to a couple of showcase sites: whenever a `== 1` (or small-n) assertion is followed by `hd(x)` / `List.first(x)` / `Enum.at(x, 0)` on the same list, bind the element(s) in the pattern and drop the repeated head calls. Check every site for this before writing `[_]`.
- Only bind `assert [item] = x` when `item` is actually used afterward — otherwise use `[_]` (unused-variable warnings fail the precommit gate).
- Run `mix format` after edits; some rewrites shorten lines.

## 1. Production code (2 sites)

- `lib/jido_claw/reasoning/classifier.ex:258` — in `mentions_multiple_files?/1`:
  `length(Regex.scan(@path_pattern, prompt)) >= 2` → `match?([_, _ | _], Regex.scan(@path_pattern, prompt))`.
  This mirrors the existing idiom in `enumerated?/1` two lines above (line 253).
- `lib/jido_claw/tools/schedule_task.ex:241` — in `parse_schedule/1`:
  `if length(fields) == 5 do` → `if match?([_, _, _, _, _], fields) do`. Keep the surrounding `if/else` and the explanatory comment as-is.

## 2. Test sweep (116 sites, 48 files)

Mechanical application of the fix rules above. Regenerate the authoritative worklist at implementation time:

```bash
mix credo --format=json | jq -r '.issues[] | select(.check | endswith("LengthComparison")) | "\(.filename):\(.line_no)"' | sort
```

(Currently these are the only credo issues, so plain `mix credo --format=oneline` shows the same list.)

Heaviest files (rest have 1–3 sites each): `test/jido_claw/tools/run_pipeline_test.exs` (11), `test/jido_claw/memory/retrieval_test.exs` (9), `test/jido_claw/reasoning/compactor/request_transformer_test.exs` (7), `test/jido_claw/memory/consolidator/staging_test.exs` (6), `test/jido_claw/reasoning/compactor/turn_grouping_test.exs`, `test/jido_claw/forge/harness_resources_test.exs`, `test/jido_claw/trace_test.exs`, `test/jido_claw/tools/mcp_scope_test.exs` (5 each).

### Special cases (handle individually)

- **Custom-message `>=` assertions → `match?` form** (the hard rule above):
  - `test/jido_claw/audit/producers_test.exs:228` → `assert match?([_, _, _ | _], memory_writes), "expected three :memory_write audit rows (record + promote + invalidate)"`
  - `test/jido_claw/audit/producers_test.exs:292` → `assert match?([_, _ | _], writes), "expected :memory_write audit rows for both write and invalidate"`
- `test/jido_claw/agent/recorder_plugin_coverage_test.exs:41` — `assert length(good) >= 8, """...heredoc message..."""` → `assert Enum.count(good) >= 8, """..."""` (preserve the message; `Enum.count` is fine here, message intact).
- `test/jido_claw/tool_context_shape_test.exs:133` — the only non-assert site: an anonymous-function **guard** inside `Macro.prewalk`. Move the arity check into the clause head and bind the last arg directly: `{{:., _, [_module, fn_name]}, _meta, [_, _, opts]} = node` with the guard reduced to `when fn_name in [:ask, :ask_sync, :ask_stream]`. This removes `opts = Enum.at(args, -1)`, and the body's `{fn_name, length(args)}` becomes `{fn_name, 3}` (arity is proven by the head).
- `== 1` + head-use sites — bind instead of repeating `hd`/`List.first` (named examples; sweep all sites for this shape):
  - `test/jido_claw/reasoning/outcome_test.exs:180` — `assert [row] = rows; assert row.execution_kind == :strategy_run`
  - `test/jido_claw/memory/retrieval_test.exs:367` — `assert [row] = preference_rows; assert row.content == ...`
  - `test/jido_claw/reasoning/compactor/turn_grouping_test.exs:57-58` — collapses two flagged lines: `assert [nil_turn] = nil_turns; assert [_, _] = nil_turn.messages`
  - `test/jido_claw/trace_test.exs:194` — `assert [span] = spans` then `span.category` / `span.status`
  - `test/jido_claw/forge/harness_resources_test.exs:75` — `assert [reason] = reasons` then `reason =~ ...` twice
- Large exact counts stay numeric via `Enum.count`: `test/jido_claw/mcp_server_test.exs:60` (`== 20`), `test/jido_claw/trace_test.exs:266` (`== 300`), `test/jido_claw/trace_test.exs:236` (`<= 100`), `test/jido_claw/trace/persistence_test.exs:305` (`<= 3`), `test/jido_claw/templates_test.exs:165` (`== 7`), `test/jido_claw/reasoning/compactor/{request_transformer_test.exs:223, compactor_test.exs:157}` (`== 9`).

## Verification

1. `mix format` then `mix format --check-formatted`.
2. `mix credo` — must report **0 issues** (the 118 were the only ones).
3. `mix jidoclaw.compile_check` — project's strict compile gate; catches unused `[item]` bindings.
4. `mix test` — full suite (PostgreSQL required; suite runs `ash.setup --quiet` first). The rewrites touch assertions in 48 test files, so a full green run is the real proof nothing changed semantically.

## Commit

Single commit including the pending `.credo.exs` change plus all fixes, following the precedent of `9bffcc4` ("Enable two new `AshCredo` checks and fix warnings"): e.g. `Enable ExSlop LengthComparison check and fix warnings`.

Stage deliberately, not with `git add -A`: run `git status --short` first, review for unrelated working-tree changes, and stage only `.credo.exs` plus the files touched by this cleanup so nothing else gets swept into the commit.
