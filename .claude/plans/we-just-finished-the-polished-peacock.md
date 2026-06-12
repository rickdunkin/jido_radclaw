# Fix code-review findings P1 + P2 in OutputShaper / FetchOutput

## Context

The OutputShaper feature (plan: `last-night-we-were-breezy-pixel.md`) shipped with the safety property "compress the green, never the red — failures stay verbatim **and fetchable**". A code review found two violations; **both are verified real**:

- **P1 — Large all-signal outputs can be truncated with no recovery ref.** When a parser matches but returns `compressed?: false` (all-signal output, e.g. a big `mix compile` warning body where `byte_size(body) >= byte_size(text)` — `lib/jido_claw/tools/output_shaper/mix_compile.ex:62`), `dispatch_parsed/3` returns `:passthrough` (`lib/jido_claw/tools/output_shaper.ex:311`). Because `run_command` already captured up to 512KB (`shapeable?` held), the original then hits `OutputLimit`'s 32KB **head** cap (`lib/jido_claw/tools/action.ex:46`) with no `output_ref` — the tail (where later warnings/errors live) is gone and unrecoverable. Adjacent variant with the same root cause: a `compressed?: true` body can itself exceed 32KB (MixTest always keeps the first failure block whole — `mix_test.ex:299-301`; GitDiff's per-file stat header is unbounded for many-file diffs — `git_diff.ex:81-83`), in which case the ref is stored but OutputLimit blindly cuts the body **and** the inline footer carrying the ref hint.
- **P2 — `fetch_output` metadata lies after the cap.** `returned_lines` is computed from the slicer's selection (`lib/jido_claw/tools/fetch_output.ex:79`, e.g. grep at `:137`) **before** the shared wrapper's `OutputLimit.truncate_result` caps `content` at 32KB. A broad `grep` / `head: 20000` returns 32KB of content while metadata claims the full selection was returned — on the very tool that exists to drill into big output.

**Fix invariant (P1):** the shaper never hands `OutputLimit` something it would cut — oversized text is always stored under a ref and self-bounded to the cap, with the footer/ref intact inline. **Fix invariant (P2):** `fetch_output` self-caps content (byte-aware, direction-aware) and reports honest counts.

**Done bar: `mix precommit` succeeds** (compile_check, system_prompt.check, deps.unlock --unused, format check, `reach.check --arch --smells --strict`, `credo --strict`, dialyzer, full test suite — zero new findings).

## Changes

### 1. `lib/jido_claw/tools/output_shaper/generic.ex` — add `fit/2`

```elixir
@spec fit(binary(), non_neg_integer()) :: {:ok, String.t()} | :nocompress
def fit(text, budget_bytes)
```
- `:nocompress` when `byte_size(text) <= budget_bytes`.
- Else head+tail elision sized to fit **within** `budget_bytes` marker included: reserve a 64-byte marker allowance, split the usable budget tail-weighted `head = div(usable, 3)`, `tail = usable - head` (same 1:2 ratio as the 2KB/4KB generic defaults — errors live at the tail), delegate to existing `head_tail/3`.
- **Hard contract: the returned body is never larger than `budget_bytes` — and never end-trimmed to get there** (an end trim shaves the tail signal `fit` exists to preserve). The 64-byte marker allowance already exceeds the largest possible marker (~45 bytes even for absurd elided counts), so `head + tail + marker` cannot overshoot — assert that invariant in tests rather than adding a correction path. If a correction ever becomes necessary, recompute with the **head** budget reduced; never cut the tail. Degenerate budgets (smaller than the marker allowance) floor to a UTF-8-safe **suffix** via the existing `Generic.valid_utf8_suffix/1`, no marker — the tail is where errors/summaries live. Use guard-clause heads, not nested `if` (credo --strict).
- Spec takes `non_neg_integer()`; callers clamp with `max(budget, 0)` (dialyzer: the finish_shape budget arithmetic can go negative).

### 2. `lib/jido_claw/tools/output_shaper.ex` — close both P1 leaks

Add `alias JidoClaw.Tools.OutputLimit`.

**(a) Oversized passthrough → shape instead** (the no-ref leak). Thread the original text's byte size (`byte_size(text)` — passthrough emits the raw `text`, not `clean`, so the gate must be on `text`) as a 4th param through `shaped_body/3` → `dispatch_parsed/3` and into `generic_or_passthrough/1`:
- `compressed?: false` clause (`:311`): bind `body`/`summary` from the `Parsed`; if `original_size > OutputLimit.max_bytes()` return `{body, summary, fmt}` (routes into `finish_shape`: ref stored, body bounded by (b)); else `:passthrough` as today (backstop won't cut it — legacy behavior preserved for small all-signal output).
- `generic_or_passthrough/2`: on `:nocompress`, if `original_size > OutputLimit.max_bytes()` return `{clean, nil, :generic}`, else `:passthrough`. (Shared by the upstream-truncated path at `:287`, so both are covered by one change.)

**(b) Bound the shaped output** (the footer-cut leak). In `finish_shape/6`, after `delta` and `footer` resolve (post-`Store.put`, `:261-265`) and before composing `output` (`:267`):
```elixir
budget = OutputLimit.max_bytes() - byte_size(delta) - byte_size(footer)
body = case Generic.fit(body, max(budget, 0)) do
  {:ok, fitted} -> fitted
  :nocompress -> body
end
```
`store_attrs.content` stays the full `clean` (`:255`) — bounding never affects what's stored. `bytes_saved`/trace use the final `output` as today. Pathological case where `delta <> footer` alone exceed the cap: accept OutputLimit as the final net — the ref exists, so it's recoverable; document this in a comment.

**(c) Docs in code**: update the OutputShaper moduledoc and the `dispatch_parsed` comment (`:303-306`) with the new invariant; update `parsed.ex` moduledoc's `compressed?` bullet (`false` no longer guarantees passthrough when the original exceeds the inline cap).

Parsers (`mix_test.ex`, `mix_compile.ex`, `git_diff.ex`) are **unchanged** — only the shaper's reaction to `compressed?` changes, so the parser unit tests stay as-is.

### 3. `lib/jido_claw/tools/fetch_output.ex` — honest, self-capped slices

Add `alias JidoClaw.Tools.OutputLimit`.

- Restructure the four slicers (`:115-164`) to return **rendered line lists + keep-direction** instead of joined strings: grep (numbered `"#{n}: #{line}"` strings), head, window → `:head`; tail → `:tail`. Budget math must run on the rendered strings (grep's number prefix counts).
- One shared clip step: reserve a fixed marker allowance (~160 bytes), then accumulate lines (`byte_size(line) + 1` for the join newline) up to `OutputLimit.max_bytes() - allowance` — from the front for `:head`, from the back for `:tail` (tail semantics keep the **last** lines). Single line over budget: direction-aware UTF-8-safe cut — `:head` keeps the line's prefix (`OutputLimit.valid_utf8_prefix/1`), `:tail` keeps the line's **suffix** (`Generic.valid_utf8_suffix/1`, already public). Use `Enum.reduce_while` or recursive heads, not nested conditionals.
- When clipped, append a note line to content (bottom for `:head`, top for `:tail`): `[fetch_output clipped: showing first|last R of S selected lines — refine with grep/head/tail/offset+limit]`. The note is not counted in `returned_lines`.
- Result keys: `returned_lines` = lines actually present in content; new always-set `selected_lines` (pre-clip selection count) and `clipped` (boolean). Declare both in `output_schema` (optional entries, mirroring `truncated`/`captured_bytes`) — **required for MCP**: serve-mode validation (`anubis_tools_handler_patch.ex` → Peri strict) filters out result keys not in the schema. `total_lines` unchanged.
- Moduledoc: replace "OutputLimit backstops a greedy fetch at 32KB" with the self-cap + honest-metadata behavior.

### 4. Docs

- `AGENTS.md` Output Shaping bullet: one clause — oversized all-signal/compressed bodies are bounded with elision + ref (never ref-less truncated); `fetch_output` clips to the cap and reports `clipped`/`selected_lines`.
- `priv/defaults/system_prompt.md` **and** `.jido/system_prompt.md` (keep byte-identical) `fetch_output` block: one sentence — content is clipped to ~32KB with a note; when `clipped: true`, narrow with grep/head/tail/offset+limit. Safe: `jidoclaw.system_prompt.check` validates only the catalog count + tool name entries, not prose (verified in `lib/mix/tasks/jidoclaw.system_prompt.check.ex`).

## Tests

All config overrides **per-test** via `Application.put_env` + `on_exit` restore (both test modules are `async: false`; `:tool_output_max_bytes` is global). Existing fixtures (~2.5–13.5KB) stay under the default 32KB cap, so existing assertions are unaffected.

**`test/jido_claw/tools/output_shaper/generic_test.exs`** — `fit/2` units: fits → `:nocompress`; oversized → `byte_size(body) <= budget` incl. marker, head start + tail end + `"elided"` present, `String.valid?`; tail-weighted split; degenerate budget (e.g. 10) → `byte_size <= 10` **and the body is the tail of the input** (suffix floor); **`budget_bytes == 0`** → `{:ok, ""}` (or equivalent ≤ 0-byte result — pin the behavior so future refactors can't regress it); UTF-8 suffix floor with multi-byte input (e.g. `"€"` repeats).

**`test/jido_claw/tools/output_shaper_test.exs`** (existing `RunCommandEcho` runs the full pipeline incl. OutputLimit; `enable_shaping/0` helper exists). New fixture helper: all-signal mix-compile body (only `warning:` lines, no `Compiling` noise ⇒ `compressed?: false`). With `tool_output_max_bytes: 4096` put_env per test:
- **(a) review's exact case**: all-signal `mix compile` output > cap ⇒ `result.shaped`, `output_ref` present, `byte_size(result.output) <= 4096`, header + `... [elided` + footer-with-ref inline, stored row holds the full text (fetchable).
- **(b) small all-signal preserved**: body between `min_shape_bytes` (2048) and cap ⇒ byte-identical passthrough, no `shaped` key.
- **(c) compressed-but-oversized**: `mix test` with one huge first failure block (> cap via the `extra:` fixture knob) ⇒ output ≤ cap, footer with ref inline at the end.
- **(d) git_diff variant**: many-file diff whose stat header > cap ⇒ bounded + ref. Drive it with a tiny inline `GitDiffEcho` action (`use JidoClaw.Tools.Action, name: "git_diff"`, returning `{:ok, %{diff: ...}}` — same pattern as the existing `RunCommandEcho`), not the real `GitDiff` tool, so the test stays focused on wrapper/shaper behavior.
- In every fitted-output test ((a), (c), (d)) also `refute result.output =~ "[tool output truncated"` — proves `OutputLimit` stayed out of it, not just that the size happens to be under the cap.

**`test/jido_claw/tools/fetch_output_test.exs`** (`seed_output` helper exists). With a small `tool_output_max_bytes` (e.g. 512) put_env per test and a many-line seeded row:
- grep selecting more than fits ⇒ `byte_size(content) <= 512`, `clipped == true`, `selected_lines` = full match count, `returned_lines` = lines actually present (< selected), note at bottom.
- `tail` clip keeps the **last** lines (content ends with the final seeded line, note at top).
- In every clipped test also `refute result.content =~ "[tool output truncated"` — same proof as the shaper tests that the self-cap handled it, not `OutputLimit`.
- unclipped fetch ⇒ `clipped == false`, `selected_lines == returned_lines`.
- Existing 9 tests unchanged (tiny content never clips; new keys are additive).

## Gate watch-its

- **dialyzer**: `fit/2` spec `non_neg_integer()` + `max(budget, 0)` at the call site; no `@spec` exists on `shaped_body`/`dispatch_parsed` today, so the arity change is low-risk.
- **credo/reach strict**: pattern-match heads over nested conditionals; no new `rescue` anywhere (only `output_shaper.ex` has the file-level `bare_rescue` disable); if reach flags the fetch_output result shape, pin with an inline pragma.
- **compile_check**: watch unused-binding warnings when threading `original_size`.

## Verification

1. `mix format`
2. Targeted: `mix test test/jido_claw/tools/output_shaper_test.exs test/jido_claw/tools/output_shaper test/jido_claw/tools/fetch_output_test.exs`
3. **`mix precommit`** — must fully pass (the done bar).
4. Optional live check (Tidewave eval, mirrors the reviewer's repro): build a >32KB all-warnings string, run it through `RunCommandEcho`-style pipeline with shaping on ⇒ confirm `output_ref` present and `byte_size(output) <= OutputLimit.max_bytes()`.
