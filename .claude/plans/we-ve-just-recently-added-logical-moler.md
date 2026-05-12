# Credo Tier 1 cleanup

## Context

We recently added Credo to the project and the baseline report at
`docs/reports/credo-baseline-2026-05-12.md` flagged ~26 Tier 1 issues — small,
mostly mechanical fixes that represent real correctness or readability hazards
rather than stylistic noise. The aim of this work is to land them in a single
focused PR so the baseline drops cleanly before we move on to the larger Tier 2
investigation (`DualKeyAccess`, complexity outlier).

After exploring the actual sites:

- The 6 rescue blocks are all legitimate best-effort boundaries (audit,
  telemetry, persistence-on-recovery). Sites in `lib/jido_claw/reasoning/telemetry.ex`
  and `lib/jido_claw/audit/producers.ex` establish the pattern of "best-effort
  boundary returning sentinel values" (`nil` / `:ok` / `:error`); rescues there
  are mostly broad, so we're tightening — not strictly matching — that
  precedent. Narrowing to specific exception types silences Credo while keeping
  today's `nil` / `:error` contract. Reraising is wrong here: callers depend on
  the sentinel to mean "no data, continue."
- The 13 `length(list) > 0` checks are all over confirmed lists (`Enum.reject`
  results, function returns documented as lists, or guarded by `is_list/1`).
  Production sites get `list != []`; test sites get `assert [_ | _] = list`
  (more idiomatic for asserting "must be a list, must be non-empty").
- The 4 negated conditions are pure expressions with no side-effect ordering
  concerns — branches can be swapped directly.
- The 4 large numbers just need underscores. (The baseline named 3 sites but
  `cli/commands.ex:1112` has a second `86400` on the adjacent line — must fix
  both or Credo will just shift the report to whichever stayed.)

Plus one bonus: an identical sibling rescue at `audit/ash_tracer.ex:210` in
`reason_summary/1` (not flagged at this priority but same pattern) — sweep it
while we're in the file. It's outside the 26-issue baseline count, so the
Credo delta stays at exactly **26**.

Total: **28 edits** across **19 files** (27 from Tier 1 + 1 bonus sweep).

## Approach

One PR. Order doesn't matter — every change is local and independent. Run
`mix format` and `mix credo` after to confirm the baseline drops by exactly 26.

### A. Narrow rescue clauses (7 sites, 5 files)

Replace `rescue _ -> ...` / `rescue e -> ...` with `rescue _ in [Type1, Type2] -> ...`.
Keep the existing return value and log level on every site. The only change is
naming the exception types we expect.

For the Ash/DB-touching sites, use the broader infrastructure list:
`[Ash.Error.Invalid, Ash.Error.Unknown, Ash.Error.Query.NotFound, DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error]`.
The longer list keeps today's "best-effort" semantics intact — narrowing too
aggressively risks letting a real DB error escape these recovery paths and
break resume/recovery flows.

> **Deliberate inclusion of `DBConnection.OwnershipError`.** This exception
> typically indicates a sandbox-ownership / test-setup mistake rather than
> production failure. We include it knowingly so the production recovery path
> stays best-effort; if it starts swallowing real test bugs we should revisit
> and drop it from the list.

| File | Line | Function | Current | Fix |
|------|------|----------|---------|-----|
| `lib/jido_claw/forge/persistence.ex` | 364 | `find_session` | `rescue _ -> nil` | Narrow to the Ash/DB list above. |
| `lib/jido_claw/forge/persistence.ex` | 262 | `latest_checkpoint` | `rescue e -> Logger.warning(...); nil` | `rescue e in [...] -> Logger.warning(...); nil` — same Ash/DB list. **Keep `Logger.warning`** per user decision. |
| `lib/jido_claw/forge/persistence.ex` | 348 | `context_for_resume` | `rescue e -> Logger.warning(...); nil` | Same Ash/DB list. Keep `Logger.warning`. |
| `lib/jido_claw/audit/ash_tracer.ex` | 225 | `error_summary` (private) | `rescue _ -> nil` | `rescue _ in [Protocol.UndefinedError, FunctionClauseError, ArgumentError] -> nil` |
| `lib/jido_claw/audit/ash_tracer.ex` | ~210 | `reason_summary` (private) | `rescue _ -> "forbidden"` (sibling, **returns `"forbidden"`, NOT `nil`**) | `rescue _ in [Protocol.UndefinedError, FunctionClauseError, ArgumentError] -> "forbidden"` — same exception list as 225, **keep the existing `"forbidden"` return value**. **Bonus sweep — not in baseline list, does not affect the -26 delta.** |
| `lib/jido_claw/platform/session/worker.ex` | 331 | `lookup_telemetry` | `rescue _ -> :error` | `rescue _ in [ArgumentError] -> :error` (only realistic cause: ETS table missing during boot) |
| `lib/jido_claw/forge/harness.ex` | 663 | `load_checkpoint` | `rescue _ -> nil` | Narrow to the same Ash/DB list. |

Why narrow rather than remove or reraise: every caller of these functions
already pattern-matches on `nil` / `:error` as the "no data" sentinel. `Let it
crash` would block resume flows, recovery, and audit emission for non-essential
bookkeeping. Narrowing is the minimum change that silences both
`ExSlop.Check.Warning.BlanketRescue` and
`ExSlop.Check.Warning.RescueWithoutReraise` while preserving today's
semantics.

**Optional follow-up (NOT in this PR):** Several of these `rescue` blocks are
guarding bang-form Ash calls (`Ash.read!`, `Ash.get!`) for an *expected*
absence case (no session, no checkpoint, etc.). The idiomatic fix is to swap
to the non-bang form with `not_found_error?: false` and drop the rescue
entirely. Leave that as a separate refactor — it touches code paths and
contracts beyond the scope of a Credo cleanup PR.

### B. Replace `length(list) > 0` (13 sites)

Every site uses `length(...) > 0` or `length(...) >= 1` (no `== 0` cases). All
operate on confirmed lists.

**lib/ — substitute `list != []` directly (5 sites)**

- `lib/jido_claw/forge/sandbox_init.ex:63` — `orphans`
- `lib/jido_claw/display.ex:760` — `children`
- `lib/jido_claw/display.ex:781` — `children`
- `lib/jido_claw/cli/commands.ex:64` — `children`
- `lib/jido_claw/forge/resource_provisioner.ex:112` — `r[:vault_keys]`

**test/ — rewrite as `assert [_ | _] = <expr>` (8 sites)**

`assert [_ | _] = list` is preferred over `assert list != []` in test files —
it asserts "is a list AND non-empty" in one match, which preserves the
implicit type contract that `length/1` had.

- `test/jido_claw/tools/remember_test.exs:72` — `results`
- `test/jido_claw/solutions/matcher_test.exs:75` — `results`
- `test/mix/tasks/jidoclaw_memory_export_test.exs:106` — `facts`
- `test/jido_claw/solutions/fingerprint_test.exs:42` — `fp.search_terms`
- `test/mix/tasks/jidoclaw_conversations_export_test.exs:123` — `redactions`
  — **preserve the custom assertion message** attached to this `assert`; do
  not drop it during the rewrite. If the existing form is
  `assert length(redactions) > 0, "custom message"`, convert via an
  intermediate explicit match: `assert [_ | _] = redactions, "custom message"`.
- `test/jido_claw/skills_test.exs:168` — `skill.steps`
- `test/jido_claw/solutions/hybrid_search_sql_test.exs:47` — `results`
- `test/jido_claw/solutions/hybrid_search_sql_test.exs:80` — `results`

If a test uses the value in an expression context (not directly inside
`assert`), fall back to `<expr> != []`.

### C. Invert negated conditions (4 sites)

Flip `if not cond do A else B end` → `if cond do B else A end`. Pure branches,
safe swap.

- `lib/jido_claw/solutions/matcher.ex:150` — `if not is_nil(explicit_embedding)`
- `lib/jido_claw/embeddings/rate_pacer.ex:148` — outer `if not (is_integer(rpm) and rpm > 0)`
- `lib/jido_claw/embeddings/rate_pacer.ex:155` — inner `if not (is_integer(tpm) and tpm > 0)`
- `lib/jido_claw/memory/retrieval.ex:141` — `if not is_nil(explicit_embedding)`

### D. Add underscores to large numbers (4 sites)

- `lib/jido_claw/core/cluster.ex:77` — `45892` → `45_892`
- `lib/jido_claw/core/cluster.ex:121` — `45892` → `45_892`
- `lib/jido_claw/cli/commands.ex:1111` — `86400` → `86_400`
- `lib/jido_claw/cli/commands.ex:1112` — `86400` → `86_400` (adjacent line;
  must also be fixed or Credo will keep reporting it)

The `3600`s nearby stay as-is (under Credo's 5-digit threshold).

## Critical files to modify

```
lib/jido_claw/forge/persistence.ex        # 3 rescue sites
lib/jido_claw/audit/ash_tracer.ex         # 2 rescue sites (1 bonus)
lib/jido_claw/platform/session/worker.ex  # 1 rescue site
lib/jido_claw/forge/harness.ex            # 1 rescue site
lib/jido_claw/forge/sandbox_init.ex       # length check
lib/jido_claw/display.ex                  # 2 length checks
lib/jido_claw/cli/commands.ex             # 1 length check + 2 large-number literals
lib/jido_claw/forge/resource_provisioner.ex  # length check
lib/jido_claw/solutions/matcher.ex        # negated condition
lib/jido_claw/embeddings/rate_pacer.ex    # 2 negated conditions
lib/jido_claw/memory/retrieval.ex         # negated condition
lib/jido_claw/core/cluster.ex             # 2 large numbers
test/jido_claw/tools/remember_test.exs
test/jido_claw/solutions/matcher_test.exs
test/mix/tasks/jidoclaw_memory_export_test.exs
test/jido_claw/solutions/fingerprint_test.exs
test/mix/tasks/jidoclaw_conversations_export_test.exs
test/jido_claw/skills_test.exs
test/jido_claw/solutions/hybrid_search_sql_test.exs
```

## Verification

After all edits:

1. `mix format` — auto-format (enforced per AGENTS.md).
2. `mix compile --warnings-as-errors` — confirms the narrowed exception lists
   resolve (`Ash.Error.*` modules exist; `DBConnection.ConnectionError` from
   `db_connection`; `Postgrex.Error` if any test substitutes that).
3. `mix credo --format json | jq '[.issues[] | select(.check | test("BlanketRescue|RescueWithoutReraise|ExpensiveEmptyEnumCheck|NegatedConditionsWithElse|LargeNumbers"))] | length'`
   — should drop to **0**. The baseline count for these five checks is 26;
   we're touching 27 sites because of the bonus sibling rescue in
   `ash_tracer.ex`, but that one is not counted in the baseline at this
   priority — so the measurable delta is exactly **−26**.
4. `mix credo` total issue count should drop from 969 → 943.
5. `mix test` — full suite. The 8 test-file changes are pure assertion
   refactors; nothing about test semantics changes. Watch for any failure in:
   - `test/jido_claw/solutions/hybrid_search_sql_test.exs` (touched twice)
   - the `embeddings/rate_pacer` paths if there's a unit test exercising the
     `init/1` validation branches.
6. Smoke-check the runtime paths that use narrowed rescues — these only matter
   if Tidewave is connected:
   - `mcp__tidewave__project_eval` with `JidoClaw.Forge.Persistence.find_session("bogus")` should still return `nil`, not crash.
   - `error_summary/1` and `reason_summary/1` are **private** in
     `ash_tracer.ex`. Two notes on testing them:
     - `error_summary/1` does **not** return `nil` when `Exception.message/1`
       fails — it falls back to the struct module name. So a
       `%Ash.Error.Forbidden{errors: [%URI{}]}` (URI doesn't implement
       `Exception`) should emit a payload `reason` like `"URI"`, not crash and
       not be `nil`. The narrowing here just stops swallowing unrelated raises.
     - `reason_summary/1` is harder to exercise via the public surface — the
       only public emit path, `set_handled_error/2`, only fires for
       `%Ash.Error.Forbidden{}`. The cleanest verification is a focused unit
       test in `test/jido_claw/audit/ash_tracer_test.exs` that calls the
       private function (via `apply/3` in test or by adding a `@doc false`
       public wrapper used only by tests). If we don't want to expose it,
       skip the smoke step here and rely on the compile-time check that the
       narrowed exception list still includes the cases actually hit by the
       protocol/function/argument failures it's meant to absorb.

## Out of scope

- Tier 2 issues (`DualKeyAccess` × 80, the `cli/repl.ex` complexity-23
  function, the `background_process/registry.ex` GenServer-as-KV question).
  These go in a separate session per the report's sequencing.
- Tier 3 noise (`AliasUsage`, `ModuleDoc`, etc.) — config decision, not in
  this PR.
- No new exception types, behavior changes, or refactors beyond what each
  Credo rule strictly requires.
