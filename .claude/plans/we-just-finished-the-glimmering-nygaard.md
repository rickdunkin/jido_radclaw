# Plan: Eval-harness review remediation (P2 crash class + P3 silent no-op)

## Context

The eval-harness slice (plan `please-review-docs-plans-unadopted-next-adaptive-micali.md`)
shipped and was code-reviewed. The review found two defects in
`lib/jido_claw/eval.ex`, both now **verified** — statically and by live repro
on the dev node (Tidewave, pure calls):

| Finding | Verdict | Live repro |
|---|---|---|
| P2: malformed assertion list items crash `run_case/2` (`field_equals` items :216, artifact triples :240) | **CONFIRMED** | `field_equals: [:bad_tuple]` → `FunctionClauseError` escapes `run_case/2` |
| P2 class is wider than the review stated | **NEW** | `field_equals: [{"overall", :comment}]` (2-tuple, non-list path) → `Protocol.UndefinedError` via `access_path/1`; a non-binary token in `prose_contains_tokens` raises during evaluate; `resolve_artifact/4` (impure DB read) can raise |
| P3: `put_path/3` silent no-op on out-of-range list index (:160, `List.update_at/3`) | **CONFIRMED — worse** | coherence case with `field: ["findings", 5, "confidence"]` returned `status: :passed` — a **false green**, not just "parses the unmodified sample" |

Root cause of the crash class: `evaluate/3` runs in `build_run/3`
(`eval.ex:326`) **outside** `execute`'s rescue (`eval.ex:79-89`), so any raise
during assertion evaluation crashes the caller — violating the harness's own
totality contract (moduledoc + the `:invalid_assertion_value` catch-all at
`eval.ex:281-283`, whose comment says "must not silently pass either").

Review's open question — the unstaged `docs/exploration/argus/OVERVIEW.md`
rewrite: inspected; it is a date-refresh of the clustering/control-plane
exploration doc, unrelated prior work. **Out of scope, untouched** (see below).

**Done means: full `mix precommit` passes.**

## Fixes — all in `lib/jido_claw/eval.ex` (Case/Run structs untouched)

Fix B goes one step beyond the two review-named sites; it is included
deliberately because the class provably extends past them (non-binary token,
impure `resolve_artifact`) and mirrors `execute`'s existing "total by design"
rescue.

### Fix A — precise per-item records (P2, both sites)

- `apply_assertion(:schema, :field_equals, pairs, ...)` (:216-226): body
  becomes `Enum.map(pairs, &field_equals_record(&1, result))`. New defps in
  the helper region (near `parse_samples`/`access_path`):
  - `defp field_equals_record({path, expected}, result) when is_list(path)` —
    existing :218-224 body verbatim.
  - `defp field_equals_record(other, _result), do:
    record(:invalid_assertion_value, false, :field_equals, other)` — catches
    non-tuples AND tuples with non-list paths.
- `apply_assertion(:composer, key, triples, ...)` (:240-252): body becomes
  `Enum.map(triples, &artifact_record(key, &1, summary, opts))`.
  - `defp artifact_record(key, {name, producer, value}, summary, opts)` —
    existing :243-250 body verbatim.
  - `defp artifact_record(key, other, _summary, _opts), do:
    record(:invalid_assertion_value, false, key, other)`.
- Record shape matches the existing catch-all convention (:281-283):
  `expected:` = the assertion key, `actual:` = the bad item.
- Keep the two fallbacks inline (no shared one-liner helper — reach
  trivial-forwarder smell). Clause order: guarded good clause first, fallback
  second. The whole-value case (`field_equals: :everything`) still falls to
  the existing :281 catch-all (its `is_list` guard fails first) — existing
  test at `eval_test.exs:210` stays green.

### Fix B — evaluation totality net (`:assertion_raised`)

In `evaluate/3`, change the dispatch at :174 to `apply_assertion_safely/5`,
defined right after `evaluate/3`:

```elixir
defp apply_assertion_safely(kind, key, value, result, opts) do
  apply_assertion(kind, key, value, result, opts)
rescue
  # reach:disable-next-line bare_rescue
  exception ->
    # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
    [record(:assertion_raised, false, key, Exception.message(exception))]
end
```

- Same two-disable sandwich as `execute` (:85-88); replicate exactly.
- Not a trivial forwarder (it adds the rescue). ExSlop: the differing final
  line vs `execute`'s rescue breaks contiguity — eyeball the ExSlop output
  anyway.
- Scope note: `rescue` catches raises only — a DBConnection ownership **exit**
  still propagates, matching `execute`'s behavior (infra failure ≠ malformed
  input).

### Fix C — `put_path/3` bounds check (P3)

Replace the list clause (:160-163):

```elixir
defp put_path(container, [index | rest], value)
     when is_list(container) and is_integer(index) do
  len = length(container)

  if index >= 0 and index < len do
    List.update_at(container, index, &put_path(&1, rest, value))
  else
    raise ArgumentError, "put_path list index #{index} out of range (list length #{len})"
  end
end
```

- The raise lands in `execute`'s rescue → `status: :error` run with that
  message. Negative indices (currently `-1` silently updates from the end)
  become loud too — paths were always `["findings", 0, ...]`-shaped.
- Accepted residual: a non-integer list index still yields a bare
  `FunctionClauseError` → `:error` run (loud, just less descriptive).

## Regression tests — red first (must fail against current code)

### `test/jido_claw/eval_test.exs` (async, pure)

New file-local fixtures to stay clone-safe: `verdict_with_finding/0`
(= `clean_verdict()` + one valid finding — also reuse it from the existing
`field_equals` test at :61-79, replacing its inline finding) and
`coherence_case/3` (field, tokens, assertions → full coherence case map with
`slice: :confidence_tagging`, `module: Reviewer`,
`base_sample: verdict_with_finding()`, `non_token: "maybe"`).

- **T1** (describe "unknown assertion keys fail loudly"):
  `schema_case(%{field_equals: [:bad_tuple, {"overall", :comment}]})` →
  `{:ok, run}`, `run.status == :failed`, exactly two
  `:invalid_assertion_value` records with `actual` `:bad_tuple` and
  `{"overall", :comment}`. RED today: crashes (`FunctionClauseError`).
- **T2** (describe "error mapping"):
  `coherence_case(["findings", 5, "confidence"], ["likely"],
  %{schema_accepts_tokens: true})` → `run.status == :error`,
  `run.error.reason == :execution_raised`,
  `run.error.message =~ "out of range"`. RED today: `status == :passed`
  (the false green).
- **T3** (describe "unknown assertion keys fail loudly"):
  `coherence_case(["findings", 0, "confidence"], [123],
  %{prose_contains_tokens: true})` → `run.status == :failed` with an
  `:assertion_raised` record, `expected: :prose_contains_tokens`. RED today:
  crashes (`ArgumentError` in backtick concat). Verified precondition:
  `Output.parse/2` is total (non-binary sample values → error tuple, no
  raise), so execute survives and evaluate is reached.

### `test/jido_claw/eval/composer_case_test.exs` (TenantCase, async: false)

- **T4**: second test after X1, distinct id (`"x1-malformed-assertions"`),
  identical `request`, assertions
  `%{terminal: :converged, artifact_contains: ["not-a-triple"],
  artifact_equals: [{"plan", "planner"}]}`. Full gate dance is mandatory
  (execute runs the real armed composer before evaluate crashes):
  `RunPubSub.subscribe_gates()` BEFORE the run → `Task.async` →
  `assert_receive {:gate_requested, ...}` → `await_paused_then_approve/3` →
  `Task.await` → `settle_run_registry(2_000)` (reuse the existing file-local
  helpers). Assert `{:ok, run}`, `run.status == :failed`, exactly two
  `:invalid_assertion_value` records, `:terminal` record `:passed`. The
  malformed items short-circuit before `resolve_artifact` — no artifact
  resolution dependency. RED today: `Task.await` re-raises the
  `FunctionClauseError`.
- Use `assert match?(pat, x), "msg"` wherever a message is wanted (never
  `assert pat = x, "msg"`).

## Doc edits (accuracy only)

1. `eval.ex` `put_path` comment (:151-153): says `Map.fetch!` where the code
   uses `Map.update!`; rewrite to name `Map.update!` (KeyError on a typo'd
   key) + the new list-index bounds raise.
2. `eval.ex` moduledoc Assertions paragraph (:36-39): one sentence — a
   malformed assertion value **or list item** fails via
   `:invalid_assertion_value`, and any evaluator raise fails via
   `:assertion_raised`; a broken assertion always fails the run, never
   crashes.
3. `AGENTS.md` Deterministic Eval Harness bullet: extend the fail-loud
   parenthetical with one tight clause: malformed value/item →
   `:invalid_assertion_value`, evaluator raise → `:assertion_raised`.

## Out of scope

- `docs/exploration/argus/OVERVIEW.md` — unrelated prior work; do not touch.
  When the eval work is eventually committed (only on request), stage only:
  `lib/jido_claw/eval*`, `test/jido_claw/eval*`, `AGENTS.md`,
  `docs/exploration/jidoka/{UNADOPTED-IDEAS,FEATURES-WORTH-BORROWING-V2}.md`,
  `docs/plans/unadopted-next-five/README.md` — never the argus doc.
- No changes to `lib/jido_claw/eval/{case,run}.ex` or any seed-case file
  (`prompt_cases_test.exs`, `schema_coherence_cases_test.exs` stay untouched).

## Gate traps (project memory)

- Zero credo strict / reach findings; reach scans `test/support` too (we add
  nothing there). ExSlop: watch the new rescue vs `execute`'s (differing tail
  line breaks contiguity); keep fixtures extracted so T1–T3 don't clone C3.
- No trivial-forwarder defps; `apply_assertion_safely` wraps with rescue, so
  it is not one.
- Run gates bare — never piped through tail/head/grep; report exact exit
  codes and counts verbatim.
- `MemoryExportTest` is a known full-suite capture_log flake — re-run in
  isolation if it trips; not a regression.

## Implementation order

1. Write T1–T4. Run `mix test test/jido_claw/eval_test.exs
   test/jido_claw/eval/composer_case_test.exs` → confirm the four fail RED
   for the expected reasons (T1/T3 crash, T2 wrong status, T4 Task re-raise).
2. Apply Fix A + Fix B + Fix C + doc edits 1–2 in `eval.ex`; AGENTS.md edit.
3. Targeted GREEN: `mix test test/jido_claw/eval_test.exs test/jido_claw/eval`
   (the reviewer's invocation — eval_test.exs plus the whole seed dir, which
   is what the 28-test baseline covers; expect 28 → 32 tests, 0 failures).
4. Full **`mix precommit`** — must pass (format, compile_check, credo strict
   zero, reach zero, ExSlop, dialyzer, full suite). Fix anything surfaced;
   re-run until clean. Report the exact verdict lines.

## Files touched

- `lib/jido_claw/eval.ex` (fixes A/B/C + comment/moduledoc)
- `test/jido_claw/eval_test.exs` (T1–T3 + fixture extraction)
- `test/jido_claw/eval/composer_case_test.exs` (T4)
- `AGENTS.md` (one-clause bullet extension)
