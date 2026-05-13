# Credo Tier 3 Cleanup Plan

## Context

We recently added credo. The baseline at `docs/reports/credo-baseline-2026-05-12.md` flagged 969 issues; Tiers 1–2 are shipped (the Tier 2 follow-ups like `DualKeyAccess` and `GenserverAsKvStore` no longer appear in the current output). **Current state (fresh run, `/tmp/credo_fresh.json`): 857 issues remain**, all accounted for by the checks and deferred buckets listed below. This plan resolves the in-scope checks and documents deferrals.

Decisions captured from scoping:
- **AliasUsage (439)**: bulk-add aliases across all affected files.
- **Duplicate code (67)**: top **4** hotspots (the ExDNA priority-24/25 cluster includes a fourth item the prior plan missed); defer the rest.
- **Nesting (101) + borderline complexity**: top concentrations only.

Current `.credo.exs` runs `strict: true`, sets `Design.AliasUsage` to `if_nested_deeper_than: 2`, and disables `Design.DuplicatedCode` in favor of `ex_dna`. **No config changes** in this plan — we fix code.

Because long-tail nesting, borderline complexity, and most duplicate-code findings are explicitly deferred, **the success criterion is "targeted checks driven to zero, with documented remaining categories" — not a green `mix credo` overall**.

## Scope (against fresh `/tmp/credo_fresh.json`)

**Drive to zero (mechanical, ~635 hits):**

| Hits | Check | Notes |
|---:|---|---|
| 439 | `Design.AliasUsage` | Bulk-add (Phase 3) |
| 86 | `Readability.ModuleDoc` | `@moduledoc false` for internal modules (Phase 1) |
| 20 | `Refactor.CondStatements` | `cond` → `if` (Phase 4b) |
| 18 | `Readability.AliasOrder` | Mechanical reorder (Phase 2 + Phase 3 follow-up) |
| 17 | `Refactor.AppendSingleItem` | `list ++ [x]` → `[x \| acc]` + `Enum.reverse/1` (Phase 5) |
| 14 | `Readability.PreferImplicitTry` | Drop redundant `try` (Phase 4c) |
| 9 | `ExSlop.Readability.StepComment` | Remove/rewrite "# Step 1:" comments (Phase 4d) |
| 8 | `ExSlop.Readability.ObviousComment` | Delete obvious restatements (Phase 4d) |
| 6 | `Refactor.FunctionArity` | Collapse arity-9 signatures to opts maps/structs (Phase 6d) |
| 5 | `Readability.StringSigils` | `~s"…"` for embedded quotes (Phase 4d) |
| 4 | `ExSlop.Refactor.IdentityPassthrough` | Inline trivial passthroughs (Phase 4d) |
| 3 | `ExSlop.Refactor.WithIdentityElse` | Drop trivial `else error -> error` branches (Phase 4d) |
| 3 | `Refactor.RejectReject` | Combine into single predicate (Phase 4d) |
| 1 each | `CaseTrueFalse`, `MapIntoLiteral`, `ReduceMapPut` | Mechanical (Phase 4d) |

**Drive to zero with judgment (28 hits):**
- `ExSlop.Readability.DocFalseOnPublicFunction` (28) — per-site decision (Phase 4a). Apply in priority order:
  1. **Make private** if no external callers exist.
  2. **Move into a small internal module with real docs** if it's a pure formatting/parsing helper used only by adjacent modules (clearer than a `@doc false` public fn, and the new module's `@doc` documents the contract honestly).
  3. **Add a real `@doc` starting `"Test seam: ..."`** as a fallback for genuinely-public-for-tests cases — e.g. `cli/repl.ex` lines 482, 496, 517 (the inline comment at 515–516 already documents the contract: *"Public (via @doc false) so the REPL test suite can assert on the string"*).

**Targeted (not full sweeps):**
- `Refactor.Nesting` — fix only `cli/commands.ex` (11) and `forge/harness.ex` (7). Other ~83 hits remain (Phase 6a–b).
- `Refactor.CyclomaticComplexity` — fix the 7 functions scoring ≥12 (one handled inside Phase 6b, the other 6 in Phase 6c); the 19 in 10–11 range remain.
- `ExDNA.Credo` — fix four hotspots chosen by priority then mass (Phase 7). All four are priority 24 or 25. **Other priority-24 clusters still remain** (notably `forge/runners/{claude_code,codex}.sync_file` and `memory/hybrid_search_sql.load_facts`) — they are deferred for this plan; ~57 lower-mass items also stay.

**Explicit deferrals (out of scope for this plan):**
- Long-tail `Refactor.Nesting` outside the two named files.
- `CyclomaticComplexity` in the 10–11 range.
- ExDNA duplicate-code findings beyond the top 4.
- Any Tier 2 follow-ups (`DualKeyAccess`, `GenserverAsKvStore`).
- `.credo.exs` config tuning.

## Phase plan

Refresh `/tmp/credo_fresh.json` at the start of each phase (don't rely on the baseline markdown):

```bash
mix credo --format json --mute-exit-status > /tmp/credo_fresh.json
```

After each phase: `mix format`, `mix compile --warnings-as-errors`, `mix test`. Add `mix ash_postgres.generate_migrations --check` for Phases 7c and 7d, and for any other phase that ends up touching Ash resource DSL.

### Phase 1 — `ModuleDoc` sweep (86)

Add `@moduledoc` to every flagged module. Default `@moduledoc false`; promote to real prose docs for: `JidoClaw.Forge` (2 hits — top-level subsystem), `JidoClaw.Accounts`, and a small set of public-API entry points to be identified during the sweep. Zero risk — purely additive.

### Phase 2 — `AliasOrder` initial sweep (18)

Alphabetize alias blocks. Mechanical. **Note**: Phase 3 will add aliases and may reintroduce order issues; the Phase 3 plan handles this by alphabetizing as each file is touched, with a final re-check before finishing the phase.

### Phase 3 — `AliasUsage` bulk-add (439)

Add missing `alias JidoClaw.<Module>` directives. **When editing each file, place new aliases in alphabetical order to avoid reintroducing `AliasOrder` violations.** At the end of the phase, re-run credo and fix any AliasOrder regressions in a small follow-up commit.

Slicing by file (commits sized for review):

| Slice | File(s) | Hits |
|---|---|---|
| 3a | `lib/jido_claw/cli/commands.ex` | 40 |
| 3b | `test/jido_claw/forge/clustering_test.exs` | 36 |
| 3c | `lib/jido_claw/memory/resources/fact.ex` | 20 |
| 3d | `lib/jido_claw.ex` | 14 |
| 3e | `lib/jido_claw/solutions/resources/solution.ex` | 12 |
| 3f | `test/jido_claw/forge/multi_sandbox_test.exs` | 12 |
| 3g | `test/jido_claw/audit/event_test.exs` | 11 |
| 3h | `lib/jido_claw/shell/session_manager.ex` | 9 |
| 3i | `test/jido_claw/conversations/recorder_test.exs` | 9 |
| 3j | `lib/jido_claw/cli/repl.ex` | 8 |
| 3k | Remaining files (long tail, ~270) | grouped by subsystem |
| 3z | AliasOrder regression cleanup | — |

Risk: very low. Compile after each slice catches alias collisions.

### Phase 4 — Trivial style sweeps

Each sub-phase is its own commit. No behavior changes.

**4a — `DocFalseOnPublicFunction` (28)** — Per-site decision, in priority order (same as the scope section above):
1. **Make private** if no external callers exist.
2. **Move into a small internal module with real docs** if it's a pure formatting/parsing helper used only by adjacent modules.
3. **Add a real `@doc` starting `"Test seam: …"`** as a fallback for genuinely-public-for-tests cases. Applies to `cli/repl.ex:482, 496, 517` (already documented in comments at lines 515–516) and likely a few others discovered during the sweep.

**4b — `CondStatements` (20)** — `cond` with single non-`true` branch → `if`. 16 files affected, ≤3 per file.

**4c — `PreferImplicitTry` (14)** — Drop explicit `try` when the function body is entirely a try. Top hit: `forge/harness.ex` (2).

**4d — Long-tail mechanical sweeps (~40 combined, one commit each)**:
- `StepComment` (9): remove "# Step 1:" / "# Step 2:" comments, mostly in `cli/setup.ex` (8 of 9).
- `ObviousComment` (8): delete comments that just restate the next line.
- `StringSigils` (5): swap to `~s"…"` where the string contains escaped quotes.
- `IdentityPassthrough` (4): inline `def foo(x), do: x`-style wrappers (sites: `forge/sandbox/docker.ex`, `forge/sandbox/local.ex`, `cli/commands.ex:1570`).
- `WithIdentityElse` (3): drop trivial `else error -> error` branches.
- `RejectReject` (3): merge into a single predicate.
- `CaseTrueFalse`/`MapIntoLiteral`/`ReduceMapPut` (1 each): straightforward rewrites.

Risk: very low. Tests catch any accidental semantic shift.

### Phase 5 — `AppendSingleItem` (17)

`list ++ [x]` is O(n). General transformation: rewrite the accumulator to prepend (`[x | acc]`) and `Enum.reverse/1` once at the end. **But `memory/consolidator/staging.ex` is not that shape.**

`staging.ex:add/3` is a bucket-storage call (`%Staging{} = stage |> ... |> Map.update!(:bucket, &(&1 ++ [args]))`). There is no natural "end" inside `add/3` to insert an `Enum.reverse/1`. Direct consumers in `memory/consolidator/run_server.ex` (`apply_block_updates:817`, `apply_fact_adds:882`, `apply_fact_updates:915`, `apply_fact_deletes:999`, `apply_link_creates:1024`) iterate the buckets in stored order. The risk if order silently reverses is **proposal-order/determinism in the apply functions and in emitted hint/id ordering** — the accumulators in those `Enum.reduce` calls assume buckets read in append order.

Two acceptable strategies for `staging.ex`:
- **Store reversed, reverse on read**: prepend in `add/3`, but every consumer in `run_server.ex` must call an accessor (e.g. `Staging.entries/2`) that returns the reversed list. Requires touching all six consumer sites and any other readers.
- **Provide bucket accessors and route all reads through them**: add `Staging.entries(stage, bucket)` that returns the list in append order. Any external reader that bypasses the accessor must be migrated. Preferred if multiple readers exist outside `run_server.ex`.

Pick the second; it localizes the invariant.

Other sites:
- `display/swarm_box.ex` (3), `memory/hybrid_search_sql.ex` (3) — apply the standard prepend + `Enum.reverse/1` pattern unless inspection shows order is irrelevant (then prepend-only is fine).
- 5 single-site files (`cli/commands.ex`, `forge/context_builder.ex`, `forge/sandbox/docker.ex`, `platform/jido_md.ex`, `tools/search_code.ex`) — case-by-case.

Risk: moderate. Tests cover the consolidation flow; if `mix test` passes after `staging.ex` and its consumers are migrated together, order is preserved.

### Phase 6 — Top nesting & complexity concentrations

**6a — `lib/jido_claw/cli/commands.ex` nesting (11)** — Extract per-command private helpers from the deepest handlers; the top-level dispatch stays flat. Also handles the complexity-10 `handle/2` at `:597`.

**6b — `lib/jido_claw/forge/harness.ex` nesting (7) + complexity 13 at `recover_runner/_` (:721)** — Extract step functions for recovery; convert nested `case` to `with`.

**6c — Other functions scoring ≥12 (6 functions; harness `recover_runner` is handled in 6b)**:
- `lib/jido_claw/conversations/recorder.ex:642` — `extract_telemetry` (16) — worst remaining; decompose by telemetry-event type.
- `lib/jido_claw/tools/list_directory.ex:45` — `do_list` (14).
- `lib/jido_claw/tools/project_info.ex:25` — `do_run` (14).
- `lib/jido_claw/cli/branding.ex:43` — `boot_sequence` (13).
- `lib/mix/tasks/jidoclaw.migrate.solutions.ex:72` — `migrate_solutions` (12).
- `lib/jido_claw/solutions/fingerprint.ex:130` — `extract_target` (12).

**6d — `FunctionArity` (6, all arity 9 > limit 8)** — Collapse to opts maps/structs. Sites: `tools/run_pipeline.ex:272`, `workflows/iterative_workflow.ex:171,187`, `tools/run_command.ex:131,153`, `reasoning/telemetry.ex:159`. Each requires updating all internal callers.

Note: `cli/repl.ex:36` is **no longer flagged** for cyclomatic complexity (drop from scope — the prior baseline was stale).

Risk: moderate. One commit per function. Run full suite after each.

### Phase 7 — Four duplicate-code extractions (chosen by priority, then mass)

The fresh ExDNA output has one priority-25 finding plus a cluster of priority-24 findings. The four below are the top of that list sorted by priority then mass. **Other priority-24 clusters remain in the codebase** — notably `forge/runners/{claude_code,codex}.sync_file` and `memory/hybrid_search_sql.load_facts` — and are explicitly deferred for this plan.

**7a — `shell/session_manager.ex` receive-loop (mass 42, priority 25)** — Lines 1260 (`do_collect/5`) and 1380 (`do_collect_ssh/6`) share a block credo flags, **but the surrounding clauses intentionally differ**:

| Behavior | `do_collect/5` | `do_collect_ssh/6` |
|---|---|---|
| `{:command, :exit_code}` for remote non-zero | folds into generic error → returns `exit_code: max(code, 1)` | preserves real remote code |
| `Jido.Shell.Error` | soft fail returns `:ok` | formats through `SSHError.format(error, entry)` |
| `:start_failed` / `:crashed` | not specially routed | preserved raw for retry classification |

Strategy: **do not over-genericize the `receive`.** Leave both receive blocks largely explicit. Extract only the small, pure helper functions used for **result construction** — concretely: output-limit preview formatting, cancellation/crash string assembly, and timeout finalization (`finalize_output/n`). Each receive clause continues to do its own pattern matching and routing, but calls these shared helpers to build the result tuple. This is enough to reduce mass without flattening the intentional divergence; the ExDNA flag may or may not fully clear — if mass stays above threshold, document the residual as intentional.

**Add targeted tests covering**: SSH non-zero exit, SSH transport errors, command timeout, cancellation mid-flight, and output-limit preview rendering — both functions must behave correctly after extraction.

**7b — `shared_resolve_embedding` (mass 53, priority 24)** — `lib/jido_claw/solutions/matcher.ex:147` ↔ `lib/jido_claw/memory/retrieval.ex:138`. The flagged block (the `resolve_embedding/3` private function) is functionally identical; the divergence is in their `compute_voyage` helpers (matcher uses `RatePacer`, retrieval does not). `retrieval.ex:128–137` already has a comment acknowledging the duplication.

Strategy: extract `JidoClaw.Memory.EmbeddingResolver` (or similar) with `resolve_embedding(query, workspace_id, opts, compute_fn)` taking a callback for the provider-specific compute step. Each caller passes its own `compute_voyage/3` (rate-paced for matcher, lean for retrieval).

**7c — `handle_by_id_global` trio (mass 49, priority 24)** — `conversations/resources/{request_correlation, session, message}.ex`. These live inside Ash resource action blocks. Strategy: plain helper module `JidoClaw.Conversations.Resources.GlobalLookup` containing the lookup function. Only add `require Ash.Query` if the extracted code actually builds Ash filters — confirm during implementation; lookups by primary key often don't need it. A `__using__` macro is not needed. If the duplicated logic turns out to live inside a `change` or `prepare`, the more idiomatic alternative is a parameterized `Ash.Resource.Change` / `Ash.Resource.Preparation` module — evaluate during implementation.

**7d — `shared_apply_scope_filter` trio (mass 69, priority 24)** — `memory/resources/{fact, episode, consolidation_run}.ex`. The flagged functions (`fact.ex:943`, `episode.ex:339`, `consolidation_run.ex:379`) are byte-identical: `Ash.Query.filter(...)` matching on `scope_kind` and FK. Strategy: extract `JidoClaw.Memory.Resources.ScopeFilter` with `apply_scope_filter/2` — plain module that **must** `require Ash.Query` (the helper builds filters via the macro). Callers already require the macro, so no caller-side change. Sibling helpers `apply_since_filter/3` and `apply_sources_filter/2` (only in `fact.ex`) stay where they are.

Risk per extraction: moderate. Tests around Ash queries and the conversations resources cover the behaviour; add the SSH-specific tests called out in 7a.

## Files modified (high-level)

- **`lib/jido_claw/`**: ~140 files (the bulk of AliasUsage, ModuleDoc, the harness/commands refactors, Phase 7 extractions).
- **`test/`**: ~50 files (AliasUsage, AliasOrder, a handful of style hits, plus new tests for Phase 7a).
- **New files (Phase 7)**: up to three — `lib/jido_claw/memory/embedding_resolver.ex`, `lib/jido_claw/conversations/resources/global_lookup.ex` (or an `Ash.Resource.Change` module), `lib/jido_claw/memory/resources/scope_filter.ex`. Names finalized during implementation.
- **No changes** to `.credo.exs`, `.formatter.exs`, or other config.

## Verification

After each phase:
```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --format json --mute-exit-status > /tmp/credo_fresh.json
mix test
```

For phases touching Ash resources (5 partial, 7c, 7d):
```bash
mix ash_postgres.generate_migrations --check
```

For Phase 7a (shell receive-loop):
```bash
mix test test/jido_claw/shell/   # plus the new SSH error/timeout/cancellation/preview tests
```

End-of-plan acceptance criteria:
- **Driven to zero**: `Design.AliasUsage`, `Readability.AliasOrder`, `Readability.ModuleDoc`, `Refactor.CondStatements`, `Refactor.AppendSingleItem`, `Readability.PreferImplicitTry`, `StepComment`, `ObviousComment`, `StringSigils`, `IdentityPassthrough`, `WithIdentityElse`, `RejectReject`, `CaseTrueFalse`, `MapIntoLiteral`, `ReduceMapPut`, `FunctionArity`.
- **Driven to zero with judgment**: `DocFalseOnPublicFunction` — zero remaining hits; any intentional test seams carry real `@doc` strings documenting the contract.
- **Targeted reductions** (not zero): `Refactor.Nesting` reduced by ~18 (commands + harness); long tail (~83) remains. `Refactor.CyclomaticComplexity` reduced by ~7 (functions ≥12); 10–11 range (~19) remains. `ExDNA.Credo` reduced by the four hotspots; ~57 lower-priority items remain.
- **No behavior changes** — `mix test` stays green throughout.
- **No config changes** — `.credo.exs` unchanged.

`mix credo` will not be green at the end; the remaining issues are the deferrals listed above. A short note in the eventual commit/PR description should enumerate them so reviewers don't expect a clean run.

## Commit-slicing guidance (not authorization)

Suggested grouping for review — commits happen only when explicitly requested:
1. Phase 1 — one commit.
2. Phase 2 — one commit.
3. Phase 3 — one commit per slice from the table above (~12 commits) plus the 3z follow-up.
4. Phase 4 — one commit per sub-phase (4a, 4b, 4c, 4d).
5. Phase 5 — one commit (staging.ex separate if it grows large).
6. Phase 6 — one commit per file/function (6a, 6b, 6c-each, 6d-each).
7. Phase 7 — one commit per extraction (7a, 7b, 7c, 7d), with 7a's tests included in that commit.
