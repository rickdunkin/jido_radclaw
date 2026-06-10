# Fix `Credo.Check.Readability.OnePipePerLine` violations (97 issues)

## Context

`.credo.exs` was just modified (currently uncommitted) to enable `Credo.Check.Readability.OnePipePerLine`. `mix credo` now reports **97 readability issues across 64 files** (49 in `lib/`, 15 in `test/`) — all the same finding: *"Avoid using multiple pipes (`|>`) on the same line."* The goal is to fix every site so `mix credo --strict` (part of `mix precommit`, mix.exs:251) passes again, then commit the fixes together with the `.credo.exs` change — same pattern as recent commits ("Enable ExSlop LengthComparison check and fix warnings").

**User decision (confirmed):** uniform multi-line style — every flagged chain becomes one-pipe-per-line. No unpiping to nested calls.

Issue distribution: 90 lines have exactly 2 pipes (`a |> f() |> g()`), 7 have 3 pipes. 13 are `def/defp ..., do:` one-liners.

## Transformation rules (uniform multi-line)

Regenerate the authoritative site list at implementation time:
`mix credo --format=flycheck` (file:line:col per issue).

**1. Standalone expression / simple assignment** (most common shape):

```elixir
lang = language |> String.downcase() |> String.trim()
```
→
```elixir
lang =
  language
  |> String.downcase()
  |> String.trim()
```

**2. `def/defp ..., do:` one-liners** (13 sites, incl. guard clauses like `lib/jido_claw/trace/sanitize.ex:113`) → block form:

```elixir
defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
```
→
```elixir
defp pad(n, width) do
  n
  |> Integer.to_string()
  |> String.pad_leading(width, "0")
end
```

**3. Chain embedded in a larger expression** (tuple element, map/keyword value, `case` head, `assert` comparison) → extract to a well-named local variable bound via a multi-line pipe, then use the variable. Examples:
- `lib/jido_claw/shell/server_registry.ex:272` — `{:reply, state.servers |> Map.keys() |> Enum.sort(), state}` → extract `names`
- `lib/jido_claw/inspection.ex:690,712,721` / `lib/jido_claw/agent_view.ex:555` — `case events |> Enum.reverse() |> Enum.find(...) do` → extract before the `case`
- `lib/jido_claw/core/cluster.ex:32` — `uptime:` map value → extract above the map literal
- `lib/jido_claw/tools/inspect_agent.ex:118` — `memory:` map value → extract
- `test/jido_claw/orchestration/replay_test.exs:187`, `test/jido_claw/release_test.exs:21` — extract, then `assert var == ...`

**4. Keyword-form `if` branches** (`lib/jido_claw/trace/collector.ex:597`) → convert the `if` to block form and split the chain inside.

**5. Case-branch tail expressions** (`lib/jido_claw/web/controllers/webhook_controller.ex:13,16,19,23`, `lib/jido_claw/security/vault_config.ex:69`, `lib/jido_claw/reasoning/compactor/turn_grouping.ex:140`) → plain multi-line pipe as the branch body (standard Phoenix idiom for `conn |> put_status(...) |> json(...)`).

## Guardrails

- **Pure line-splitting only** — never change chain order, the chain's first segment, or semantics. `Credo.Check.Refactor.PipeChainStart` is enabled (.credo.exs:229), so never partially unpipe (e.g. `f(a) |> g()`). Line-splitting can't trip it since it analyzes the AST (e.g. `lib/jido_claw/inspection.ex:622` starts with a call today and passes; keep its start unchanged).
- Keep parentheses on all piped calls (`OneArityFunctionInPipe` is enabled).
- **`lib/jido_claw/trace/collector.ex:491` and `:597`**: keep the `Enum.reverse() |> then(&[x | &1]) |> Enum.reverse()` construction verbatim apart from line breaks — the adjacent comment documents that this shape intentionally satisfies ExSlop's `Refactor.AppendSingleItem`. Do **not** simplify to `++`.
- Touch only the flagged lines plus the minimal surrounding restructuring (do:→do/end conversion, variable extraction). No drive-by cleanups.
- Within each file, apply edits bottom-up (highest line number first) so the snapshot's line numbers stay valid.

## Execution steps

1. `mix credo --format=flycheck > /tmp/credo_issues.txt` — capture the site list.
2. Fix file by file (64 files), applying the rules above. Batch roughly by directory (`lib/jido_claw/tools/`, `reasoning/`, `trace/`, `shell/`, web, mix tasks, then `test/`); re-run `mix credo --format=flycheck` after each batch to confirm progress and catch shifted lines.
3. `mix format` — normalize all edited files.

## Verification

1. `mix credo --strict` → **0 issues** (baseline before this change was clean; the 97 were the only findings).
2. `mix jidoclaw.compile_check` → passes (project's warnings-as-errors gate with its documented allowlist).
3. `mix test` → full suite green (PostgreSQL required; alias runs `ash.setup --quiet` first). Changes are formatting-only, so failures would indicate a botched edit.
4. Optional full gate: `mix precommit` (adds dialyzer, reach.check, format check).

## Commit

- Review `git status --short`; stage **only** `.credo.exs` + the fixed files (no unrelated edits).
- Message follows the existing series style: `Enable Credo.Check.Readability.OnePipePerLine and fix warnings`.
