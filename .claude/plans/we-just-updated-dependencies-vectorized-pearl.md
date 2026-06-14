# Resolve `mix credo --strict` findings surfaced by the dependency update

## Context

A dependency bump (in `mix.lock`, under unchanged `mix.exs` constraints) made `mix credo --strict`
exit non-zero. `credo --strict` is the 6th step of the `precommit` alias (`mix.exs:246`), so this
blocks `mix precommit` locally (there is no CI gate — no `.github/`). Two independent symptoms:

1. **`** (config) Ignoring an undefined check: AshCredo.Check.Warning.NoActions`**
   `ash_credo` 0.14.0 → 0.15.0 **removed** `AshCredo.Check.Warning.NoActions` (its CHANGELOG lists this
   under BREAKING CHANGES, no replacement). Our `.credo.exs:28` still enables it → undefined-check warning.

2. **26 "Duplicate code" findings** — emitted by **`ExDNA.Credo`** (`.credo.exs:22`), *not* core
   `Credo.Check.Design.DuplicatedCode` (disabled at `.credo.exs:132`, "ExDNA handles this better").
   `ex_dna` 1.5.2 → 1.5.3 **changed its default duplicate detection** (notably a new variable-normalization
   pass in fingerprinting), so structural boilerplate the 1.5.2 default tolerated now matches. The findings
   are exact-match clones (output labels them `exact`; fuzzy/Type-III detection stays off — `min_similarity`
   defaults to `1.0`). None of the flagged code is new — it's pre-existing app code the detector now sees.

**Chosen strategy** (confirmed with the user): **fix the genuine duplication, suppress the coincidental
boilerplate, and unify the two YAML stores now.** Outcome: `credo --strict` exits 0, `precommit` green,
plus a latent error-list drift fixed along the way.

### Key facts that shape the approach

- **Suppression mechanism** (`deps/ex_dna/lib/ex_dna/ast/annotator.ex`): the project's pragma is
  `# ex_dna:disable-for-next-line` (already used at `pipeline_store.ex:134`, `strategy_store.ex:178`).
  **`strip_suppressed` only removes *definition forms* (`def/defp/defmacro/defmacrop`) whose own line is
  suppressed.** So the pragma works for `start_link`/`init` (defs) but is a **no-op for module attributes
  and alias runs** — those must be *extracted* or have the run *broken*, or (last resort) the whole file
  suppressed with `# ex_dna:disable-for-this-file`.
- **The shared `@db_errors` list has drifted.** 10 files carry an `Ash.Error.Invalid…`-led list:
  **8 use the canonical 7-item list (incl. `Ash.Error.Forbidden`)**; **`forge/persistence.ex` and
  `forge/harness.ex` use a 6-item list missing `Forbidden`** (persistence: the `@db_errors` attribute
  *plus* 4 inline copies at lines 381/485/518/542; harness: 1 inline at 792). The Forge sibling
  `forge/manager.ex:12` *does* include `Forbidden`, so the 6-item omission is **drift**, not an intentional
  Forge policy.
  (Its 6≠7 element count is also why ExDNA didn't flag persistence — it isn't an exact match of the others.)
- **`JidoClaw.Reasoning.YamlStore` already exists** (`lib/jido_claw/reasoning/yaml_store.ex`) as a small
  `fetch_name/1` helper both stores alias. The unification *grows* it, not creates it.

## Changes

### 1. Config hygiene — `.credo.exs`
Delete line 28 `{AshCredo.Check.Warning.NoActions, []},`. (Removed in ash_credo 0.15.0, no replacement;
the other 19 `AshCredo.Check.*` entries still resolve.) Clears symptom #1.

### 2. Consolidate the DB-error list onto a tested `JidoClaw.Core.AshErrors.db_errors/0`  *(genuine; fixes drift)*
A constant helper — not a `__using__` macro — is the clearer fit (and `rescue … in @db_errors` is happy
to populate the attribute from a compile-time function call). **Preserve** `AshErrors`'s existing
`unique_violation?/2` focus; this is additive.
- In `lib/jido_claw/core/ash_errors.ex` add:
  ```elixir
  @doc "Canonical Ash/DB exception structs the rescues narrow on (`rescue _ in @db_errors`)."
  @spec db_errors() :: [module()]
  def db_errors,
    do: [
      Ash.Error.Invalid, Ash.Error.Unknown, Ash.Error.Forbidden,
      Ash.Error.Query.NotFound, DBConnection.ConnectionError,
      DBConnection.OwnershipError, Postgrex.Error
    ]
  ```
  Expand the module doc to cover both the classifier and this list; add a unit test asserting the exact list.
- In each of the **8** modules with the 7-item list, replace the literal with
  `@db_errors JidoClaw.Core.AshErrors.db_errors()` (the attribute is populated at compile time, so the
  `rescue _ in @db_errors` sites are unchanged): `agent_view.ex`, `memory.ex`, `tools/handoff.ex`,
  `memory/consolidator.ex`, `memory/consolidator/run_server.ex`, `agent/handoff/router.ex`,
  `agent/prompt.ex`, `forge/manager.ex`. Keep each call site's one-line why-this-module comment.
  Resolves the `@db_errors`-driven findings: cluster D (mass 31), G (mass 33), the
  `manager:3 ↔ run_server:25` mass-34, and the `@db_errors` portion of `handoff ↔ router` mass-46.
- **Forge drift (recommended fix, flagged as a behavior change):** point `forge/persistence.ex` and
  `forge/harness.ex` at the same `db_errors/0` — persistence's `@db_errors` attribute *and* its 4 inline
  `rescue … in [ … ]` copies (381/485/518/542), and harness's inline copy (792; add a
  `@db_errors JidoClaw.Core.AshErrors.db_errors()` and use it). This fixes the drift and removes
  persistence's intra-file duplication. **This adds `Ash.Error.Forbidden` to those best-effort read/persist
  rescue sites** (they currently let it propagate); aligning with the other 9 modules is almost certainly
  correct, but it *is* a behavior change — verify under tests (§Verification). *Alternative:* if Forge
  should stay narrower, leave those two files on a documented 6-item set and note the intent; do not silently
  diverge.

### 3. Extract `retry_budget` → `JidoClaw.Skills.Steps.RetryBudget`  *(genuine)*
`retry_budget/1` + the `positive_remaining?/1` trio are byte-identical in `skills/steps/agent_step.ex`
(110/117-119) and `skills/steps/iterative_step.ex` (82/89-91).
- New `lib/jido_claw/skills/steps/retry_budget.ex` exposing both as public functions (moved verbatim).
- In both step modules, `import JidoClaw.Skills.Steps.RetryBudget, only: [retry_budget: 1, positive_remaining?: 1]`
  (calls are bare, so `import` keeps call sites unchanged; the explicit `only:` keeps the shared helper
  visible and avoids future import collisions); delete the local `defp` copies. Resolves cluster B (mass 49).

### 4. Unify the YAML stores → grow `JidoClaw.Reasoning.YamlStore` into a base  *(genuine; user opted in)*
Add a `__using__/1` macro to `yaml_store.ex` (keep the existing `fetch_name/1`) that injects the shared
machinery, parameterized by `subdir:` (`"pipelines"`/`"strategies"`) and `label:` (log tag), using a
generic state key (e.g. `:entities`):
- Client API: `start_link/1`, `list/0`, `get/1`, `all/0`, `reload/0`
- Server: `init/1`, `handle_continue(:load, _)`, `handle_call` for `:all|:list|:get|:reload`
- Loading: `load_from_disk/1`, `parse_file/1`, `dedupe_by_name/1`, `*_dir/1`

**Keep `validate/1` private.** The injected `parse_file/1` calls **bare `validate(data)`**, which resolves
to the using module's own `defp validate/1` — do **not** declare an Elixir `@callback` or call
`__MODULE__.validate/1` (either would force `validate` public and break "public API unchanged").
Migrate both stores to `use JidoClaw.Reasoning.YamlStore, subdir: …, label: …`, keeping each module's
`defstruct`, `@type t`, `defp validate/1`, and store-specific helpers/constants (StrategyStore's
`@prompt_keys_by_base`, prompts/prefers parsing, etc.). Drop the now-obsolete
`# ex_dna:disable-for-next-line` on `load_from_disk` (it moves into the base). **Public API and return
shapes stay identical** — only the internal state-key name changes. Resolves cluster E (mass 34) and the
pipeline/strategy members of cluster A.

### 5. Suppress coincidental def-form boilerplate
`# ex_dna:disable-for-next-line` (textbook OTP idioms; macro-wrapping them is an anti-pattern).
**Placement matters:** ExDNA only strips a def whose *own* line is suppressed, so the pragma goes on the
line **immediately above the `def`**, *after* any `@spec`/`@impl` (e.g. between `@impl GenServer` and
`def init`, never above `@impl`).
- `def start_link` in `shell/profile_manager.ex:78` and `shell/server_registry.ex:121` (cluster A's
  non-store members — the only remaining `start_link` pair after step 4).
- `def init` in `conversations/recorder.ex:186` and `audit/signal_listener.ex:42` (cluster C). Note: if
  ExDNA flagged a *window* of consecutive callbacks (`init`+`handle_continue`+`handle_info`), the pragma
  may be needed on more than one `def` — confirm via the re-run (§7).

### 6. Resolve the coincidental alias overlap (non-def)
Cluster F: `inspection.ex:38` ↔ `agent_view.ex:44` share an identical 5-`alias` run (same projection
subsystems — coincidental, and aliases can't be extracted/line-suppressed). **Preferred:** break the run
in `inspection.ex` by dropping 1-2 of the least-used shared aliases (`CompactorStorage`, `Trace.Event`,
etc.) and fully-qualifying their few call sites, shortening the identical consecutive run below ExDNA's
window/mass threshold — this keeps ExDNA coverage on the rest of the file. **Fallback** (only if thinning
doesn't drop it): `# ex_dna:disable-for-this-file` on `inspection.ex` with an explicit rationale (it already
carries `# reach:disable-for-this-file bare_rescue`), accepting the loss of file-wide ExDNA coverage.

### 7. Verify and mop up residuals
After the structural changes a few borderline coincidental fragments *may* remain (most likely the
`handoff ↔ router` `require Logger` + 3-alias overlap once `@db_errors` is gone). Re-run credo and clear
any residual: def-form → `# ex_dna:disable-for-next-line` (placed per §5); non-def coincidental → break the
run (per §6) or, last resort, `# ex_dna:disable-for-this-file`. Iterate until clean.

## Critical files
- `.credo.exs` — delete the `NoActions` line
- `lib/jido_claw/core/ash_errors.ex` — add tested `db_errors/0`; 8 `@db_errors …db_errors()` sites (§2);
  plus the Forge drift sites in `forge/persistence.ex` (attr + 4 inline) and `forge/harness.ex` (1 inline)
- `lib/jido_claw/skills/steps/retry_budget.ex` (new) + `agent_step.ex`, `iterative_step.ex`
- `lib/jido_claw/reasoning/yaml_store.ex`, `pipeline_store.ex`, `strategy_store.ex`
- Suppression/alias sites: `shell/profile_manager.ex`, `shell/server_registry.ex`,
  `conversations/recorder.ex`, `audit/signal_listener.ex`, `inspection.ex`

## Verification
Run via `mise exec -- mix` (toolchain is mise-latest):
1. `mix credo --strict` → **must exit 0** with no "Ignoring an undefined check" line. Iterate per §7.
2. `mix jidoclaw.compile_check` (the project's strict compile gate — not `--warnings-as-errors`, per AGENTS.md) → no new warnings.
3. `mix format --check-formatted`.
4. Targeted tests, then full suite:
   `mix test test/jido_claw/core/ test/jido_claw/reasoning/ test/jido_claw/skills/ test/jido_claw/memory/ test/jido_claw/forge/`
   then `mix test`. (Heed the known async-singleton flakiness — verify any store/MCP failures in isolation, not under load.)
5. **Confirm the Forge behavior change** (§2): `forge/persistence.ex` + `forge/harness.ex` now also swallow
   `Ash.Error.Forbidden` at their best-effort rescue sites — check Forge tests still pass and that this is the
   desired contract; back out to a documented narrower set if not.
6. **Final gate:** `mix precommit` — must pass end-to-end (it runs `credo --strict`, format, compile-check,
   dialyzer, and the suite together). This is the authoritative confirmation the blocker is cleared.

## Commit (per repo git policy — do NOT commit; user stages/commits)
Stage: `.credo.exs`, `lib/jido_claw/core/ash_errors.ex`, the 8 `@db_errors` sites + the 2 Forge files,
`lib/jido_claw/skills/steps/retry_budget.ex` + the 2 step files, the 3 reasoning store files, and the
suppression/alias sites.

Suggested message:
```
fix: clear credo --strict findings after dep bump (ex_dna 1.5.3, ash_credo 0.15)

- .credo.exs: drop removed AshCredo.Check.Warning.NoActions check
- consolidate DB-error rescue list onto JidoClaw.Core.AshErrors.db_errors/0;
  fix Forge drift (persistence.ex/harness.ex were missing Ash.Error.Forbidden)
- extract retry_budget/positive_remaining? to Skills.Steps.RetryBudget
- unify PipelineStore/StrategyStore on a JidoClaw.Reasoning.YamlStore base
- suppress coincidental OTP boilerplate (start_link, init, alias run) via ex_dna pragmas

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
