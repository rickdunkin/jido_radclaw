# Resolve post-M11/M12 review finding (stale `reputation_import.ex` references)

## Context

The M11+M12 work from `.claude/plans/please-review-docs-reports-code-review-2-fancy-canyon.md` is complete in the working tree (uncommitted; the prior plan's two commits are still pending). A follow-up code review of that diff validated everything except one **P3**: `lib/jido_claw/resource.ex:36` still lists `reputation_import.ex` among the current non-standard-policy-shape resources, but M12 deleted that resource.

**Finding verified.** Root cause of the miss: the M12 post-removal sweep regex (`ReputationImport|...|reputation_imports|...`) matches only the CamelCase and plural snake_case forms — the singular filename `reputation_import.ex` is invisible to it. A corrected sweep (`rg --pcre2 "reputation_import(?!s)"`) over the repo found exactly **one more** same-class stale reference: `docs/exploration/argus/OVERVIEW.md:531`. Both fixes below. All other corrected-sweep hits are `.claude/plans/` scratch files (keep-list, never edited); supplementary sweeps for `Migrate\.Solutions` and `SOLUTIONS_DEPRECATION` are clean (only the review report's own M12 fix-note matches).

Done means `mix precommit` passes, then the pending commits land.

## Fixes (two one-line doc edits)

1. **`lib/jido_claw/resource.ex:35-37`** — the parenthetical list is doubly stale: `reputation_import.ex` was deleted (M12), and `global_lookup.ex` was never accurate there — it is a plain helper function module, not an Ash resource (its own moduledoc: "intentionally a plain function — not an `Ash.Resource.Change`"; it has no `use Ash.Resource`/`policies` at all). Only `request_correlation.ex` genuinely fits (verified: `use Ash.Resource` at :59, hand-written `policies do` at :80). Rewrite the sentence (user-confirmed wording):

   ```
   Resources with non-standard policy shapes, currently
   `request_correlation.ex`, keep their hand-written `use Ash.Resource`
   + `policies do` block.
   ```

2. **`docs/exploration/argus/OVERVIEW.md:531`** — maintained exploration doc (updated post-creation, same class as the hermes/squidie docs edited in M12). The line claims a `worktree` grep in `lib/` returns "one unrelated hit in `solutions/resources/reputation_import.ex`" — verified now zero hits. Drop the deleted filename entirely, keeping the doc current-state clean:
   - `Grep for `worktree` in `lib/` returns only one unrelated hit in `solutions/resources/reputation_import.ex`.` → `Grep for `worktree` in `lib/` returns no hits.`

**No report edit**: this P3 came from the follow-up review of the fix diff, not from `docs/reports/code-review-2026-06-10.md` — it has no bullet there to annotate.

## Verification

1. Corrected sweep goes to zero: `rg --pcre2 "reputation_import(?!s)" --hidden -g '!.git' -g '!_build' -g '!deps' -g '!.claude'` → **no hits** outside `.claude/plans/` scratch material (which the `-g '!.claude'` already excludes).
2. Original M12 sweep still clean (unchanged keep-list): `rg "ReputationImport|jidoclaw\.migrate\.solutions|reputation_imports|migrate\.solutions" --hidden -g '!.git' -g '!_build' -g '!deps'`.
3. **`mix precommit`** — the completion gate (`:test` env): `jidoclaw.compile_check`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format --check-formatted`, `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`, `test` (full suite; `ash.setup --quiet` applies the pending `20260611222823_drop_reputation_imports.exs` to the test DB). Both edits are comment/markdown-only, so the main risk is simply surfacing anything latent in the already-reviewed working tree — the review's targeted suite (216 tests) passed, but the full gate hasn't run this session.

## Commits (the prior plan's pending split, targeted staging)

1. `fix: cron one-shot :at jobs disable after firing and skip elapsed at reload (M11)` — `lib/jido_claw/platform/cron/worker.ex`, `test/jido_claw/cron/worker_fire_provenance_test.exs`, `test/jido_claw/cron/persistent_disable_test.exs`.
2. `refactor: remove legacy v0.5.x solutions migrator and ReputationImport ledger (M12)` — everything else change-related: the deletions (`lib/mix/tasks/jidoclaw.migrate.solutions.ex`, `lib/jido_claw/solutions/resources/reputation_import.ex`, `.jido/SOLUTIONS_DEPRECATION.md`, two `priv/resource_snapshots/repo/reputation_imports/*.json`), `lib/jido_claw/solutions/domain.ex`, `priv/repo/migrations/20260611222823_drop_reputation_imports.exs`, `lib/jido_claw/solutions/resources/solution.ex`, `lib/jido_claw/orchestration/workflow_event.ex`, `test/mix/tasks/jidoclaw_solutions_export_test.exs`, `test/jido_claw/solutions/solution_test.exs`, `test/jido_claw/policy_authz_test.exs`, both exploration FEATURES-WORTH-BORROWING docs, **plus this round's two edits** (`lib/jido_claw/resource.ex`, `docs/exploration/argus/OVERVIEW.md` — M12 fallout), the plan files (`.claude/plans/please-review-docs-reports-code-review-2-fancy-canyon.md`, this file — `.claude/plans/` is git-tracked, 127 files), and `docs/reports/code-review-2026-06-10.md`.
   - The report file rides in commit 2 because its priority-item-6 edit (line 298) covers M11 and M12 in a single hunk — it can't be split cleanly across the two commits.

Stage by explicit path per the targeted-staging convention; `git status --short` before each commit to confirm nothing unrelated is swept in.
