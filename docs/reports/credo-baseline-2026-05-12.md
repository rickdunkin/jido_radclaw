# Credo Baseline Report

**Date:** 2026-05-12
**Command:** `mix credo --format json`
**Total issues:** 969 across 257 files (206 in `lib/`, 51 in `test/`)

## TL;DR

The 969-issue count overstates the problem. Most volume is stylistic noise
(`Design.AliasUsage`, `Refactor.Nesting`, `Readability.ModuleDoc`). The
behaviorally-meaningful subset is roughly **~26 fixes** that should land
immediately, plus a follow-up wave focused on dual-key access hygiene and one
outlier function.

## Distribution

### By category

| Category    | Count |
|-------------|-------|
| design      | 506   |
| refactor    | 192   |
| readability | 171   |
| warning     | 100   |

### By priority bucket

| Bucket            | Count | Notes |
|-------------------|-------|-------|
| HIGH (≥10)        | 91    | 67 are duplicate-code findings (informational); 24 are real |
| NORMAL (1–9)      | 779   | Mostly `AliasUsage` (439) and `Nesting` (101) |
| LOW (<1)          | 99    | Pure readability nits |

### Top checks by volume

| Count | Check |
|------:|-------|
| 439   | `Credo.Check.Design.AliasUsage` |
| 101   | `Credo.Check.Refactor.Nesting` |
| 86    | `Credo.Check.Readability.ModuleDoc` |
| 80    | `ExSlop.Check.Warning.DualKeyAccess` |
| 67    | `ExDNA.Credo` (duplicate code) |
| 31    | `Credo.Check.Refactor.CyclomaticComplexity` |
| 28    | `ExSlop.Check.Readability.DocFalseOnPublicFunction` |
| 20    | `Credo.Check.Refactor.CondStatements` |
| 18    | `Credo.Check.Readability.AliasOrder` |
| 17    | `Credo.Check.Refactor.AppendSingleItem` |
| 14    | `Credo.Check.Readability.PreferImplicitTry` |
| 13    | `Credo.Check.Warning.ExpensiveEmptyEnumCheck` |

## Tier 1 — Fix immediately (real correctness / behavior risk)

Small in count, mostly mechanical, but each represents an actual hazard or a
trivial cleanup. Target: **one focused PR.**

### Blanket / silent rescues (6 sites)

These hide crashes and produce confusing prod debugging. Either re-raise, rescue
specific exception types, or let it crash.

- `ExSlop.Check.Warning.BlanketRescue` (priority 13):
  - `lib/jido_claw/forge/persistence.ex:364`
  - `lib/jido_claw/audit/ash_tracer.ex:225`
  - `lib/jido_claw/platform/session/worker.ex:331`
  - `lib/jido_claw/forge/harness.ex:663`
- `ExSlop.Check.Warning.RescueWithoutReraise` (priority 4): logs and discards
  - `lib/jido_claw/forge/persistence.ex:262`
  - `lib/jido_claw/forge/persistence.ex:348`

### Expensive empty-enum checks (13 sites)

`length(list) == 0` / `length(list) > 0` walks the entire list. Replace with
pattern match or `== []`.

Sites in `lib/`:
- `lib/jido_claw/forge/sandbox_init.ex:63`
- `lib/jido_claw/display.ex:760`
- `lib/jido_claw/display.ex:781`
- `lib/jido_claw/cli/commands.ex:64`
- `lib/jido_claw/forge/resource_provisioner.ex:112`

Sites in `test/`:
- `test/jido_claw/tools/remember_test.exs:72`
- `test/jido_claw/solutions/matcher_test.exs:75`
- `test/mix/tasks/jidoclaw_memory_export_test.exs:106`
- `test/jido_claw/solutions/fingerprint_test.exs:42`
- `test/mix/tasks/jidoclaw_conversations_export_test.exs:123`
- `test/jido_claw/skills_test.exs:168`
- `test/jido_claw/solutions/hybrid_search_sql_test.exs:47`
- `test/jido_claw/solutions/hybrid_search_sql_test.exs:80`

### Negated conditions with else (4 sites)

Flip the branches; trivial readability fix.

- `lib/jido_claw/solutions/matcher.ex:150`
- `lib/jido_claw/embeddings/rate_pacer.ex:148`
- `lib/jido_claw/embeddings/rate_pacer.ex:155`
- `lib/jido_claw/memory/retrieval.ex:141`

### Large numbers (3 sites)

`45892` → `45_892`. 30 seconds of work.

- `lib/jido_claw/core/cluster.ex:77`
- `lib/jido_claw/core/cluster.ex:121`
- `lib/jido_claw/cli/commands.ex:1111`

## Tier 2 — Fix soon (may hide bugs, worth investigating)

### `DualKeyAccess` × 80

Code is checking maps for both `:atom` and `"string"` keys, signaling upstream
data hygiene problems — signals/JSON crossing module boundaries without
normalization. Each instance is a candidate for a bug where one branch silently
fails to find data. Recommended approach: normalize at the boundary (one call
to `Map.new/1` with a key conversion), not at every read site.

Top clusters:

| Count | File |
|------:|------|
| 7 | `lib/jido_claw/solutions/trust.ex` |
| 6 | `test/jido_claw/audit/producers_test.exs` |
| 5 | `lib/jido_claw/workflows/plan_workflow.ex` |
| 5 | `lib/jido_claw/forge/harness.ex` |
| 5 | `lib/mix/tasks/jidoclaw.migrate.solutions.ex` |
| 5 | `test/jido_claw/tools/reason_test.exs` |
| 5 | `test/jido_claw/tools/run_pipeline_test.exs` |
| 4 | `lib/jido_claw/workflows/iterative_workflow.ex` |
| 4 | `lib/mix/tasks/jidoclaw.migrate.cron.ex` |
| 4 | `lib/jido_claw/conversations/recorder.ex` |
| 4 | `lib/jido_claw/reasoning/telemetry.ex` |
| 4 | `lib/jido_claw/memory.ex` |

### Single complexity outlier

`lib/jido_claw/cli/repl.ex:36` — cyclomatic complexity **23** (limit 9). This
function is significantly more tangled than anything else in the codebase and
likely deserves decomposition.

Top 10 worst complexity scores (for context):

| Complexity | Location |
|-----------:|----------|
| 23 | `lib/jido_claw/cli/repl.ex:36` |
| 16 | `lib/jido_claw/conversations/recorder.ex:641` |
| 15 | `lib/jido_claw/forge/harness.ex:712` |
| 14 | `lib/jido_claw/tools/list_directory.ex:45` |
| 14 | `lib/jido_claw/tools/project_info.ex:25` |
| 13 | `lib/jido_claw/cli/branding.ex:43` |
| 12 | `lib/jido_claw/workflows/plan_workflow.ex:68` |
| 12 | `lib/mix/tasks/jidoclaw.migrate.solutions.ex:72` |
| 12 | `lib/jido_claw/solutions/fingerprint.ex:130` |
| 12 | `lib/jido_claw/forge/harness.ex:759` |

The 23 is the outlier worth fixing now. The remaining 10–16 range items are
borderline — either decompose opportunistically as those files are touched, or
raise the `max_complexity` threshold in `.credo.exs`.

### `GenserverAsKvStore` × 1

`lib/jido_claw/platform/background_process/registry.ex:73` — a GenServer is
reimplementing a key-value store. Worth a brief look to decide whether ETS or
`Agent` is a better fit, especially if this is on a hot path.

## Tier 3 — Can wait (style / config decisions)

These are real code-quality signals but represent either large mechanical
sweeps or check-tuning decisions, not behavioral risks.

| Count | Check | Recommendation |
|------:|-------|----------------|
| 439 | `Design.AliasUsage` | Bulk noise. Either dedicate a janitorial PR (40 alone in `cli/commands.ex`) or relax/disable the check. |
| 101 | `Refactor.Nesting` | Pure readability. Concentrates in `cli/commands.ex` (11) and `forge/harness.ex` (7) — addressed naturally when those files are refactored. |
| 86 | `Readability.ModuleDoc` | Add `@moduledoc false` for internal modules; only a handful warrant real prose docs. |
| 67 | `ExDNA.Credo` | Real duplication. Worth eventual extraction (top hits: `shell/session_manager.ex:1260↔1380`, the Ash resource scaffolding shared across 12 resource files, `forge/runners/{codex,claude_code}` overlap), but these are full refactors, not quick wins. |
| 31 | `Refactor.CyclomaticComplexity` | Only the complexity-23 outlier in Tier 2; remainder is borderline. |
| 28 | `Readability.DocFalseOnPublicFunction` | Style. |
| 20 | `Refactor.CondStatements` | Style. |
| 18 | `Readability.AliasOrder` | Style. |
| 17 | `Refactor.AppendSingleItem` | `list ++ [x]` → `[x \| list] \|> Enum.reverse()` etc. Real but minor. |
| 14 | `Readability.PreferImplicitTry` | Style. |

## Recommended sequencing

1. **Now (~30 min):** Land Tier 1 in a single small PR — the 6 rescue sites,
   13 `length/1` checks, 4 negated conditions, 3 large numbers. Each fix is
   localized and low-risk.
2. **Next session:** Walk through `DualKeyAccess` cluster by cluster, starting
   with `solutions/trust.ex` (highest count). Decompose `cli/repl.ex:36`.
   Decide on the `background_process/registry.ex` GenServer.
3. **Backlog or config:** Decide whether to schedule a janitorial PR for
   `AliasUsage` + `ModuleDoc` + `AliasOrder`, or relax those checks in
   `.credo.exs`. Most Elixir codebases don't enforce them at default
   strictness.

## Appendix — Reproducing this report

```bash
mix credo --format json > /tmp/credo_output.json
```

Raw JSON output was saved during this analysis to `/tmp/credo_output.json`.
