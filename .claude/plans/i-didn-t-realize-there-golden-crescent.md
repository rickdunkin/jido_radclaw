# Plan: Resolve Credo categories #4, #5, #6

## Context

New AshCredo checks were recently added to `.credo.exs`. `mix credo --format json` surfaces 170 violations across 6 categories. This plan tackles the three smallest categories — 20 issues total across ~14 files — as a low-risk first wedge before tackling the larger paired categories (`MissingCodeInterface` + `UseCodeInterface`, 121 issues) and `RaisingCall` (29 issues), which are deferred to a separate effort.

Targets:
- **#4 `AshCredo.Check.Design.MissingPrimaryAction`** — 11 issues, 10 files
- **#5 `AshCredo.Check.Design.MissingTimestamps`** — 5 issues, 5 files
- **#6 `AshCredo.Check.Refactor.DirectiveInFunctionBody`** — 4 issues, 2 files

End state: `mix credo --format json | jq '.issues | length'` reports **150** (170 − 20), with these three categories at zero.

---

## Category #6 — DirectiveInFunctionBody (4 issues, 2 files)

Pure code-motion: move `require Ash.Query` from function bodies to the top of the module so it applies file-wide.

### `lib/jido_claw/memory/consolidator.ex`
- **Add** `require Ash.Query` at line 31 (after `require Logger`, before the `alias` lines).
- **Delete** line 156 (`require Ash.Query` inside `read_workspaces/0`).
- **Delete** line 210 (`require Ash.Query` inside `active_session_scopes/1`).
- The 4 `Ash.Query.*` call sites (lines 159, 160, 215, 216) remain covered by the new top-of-module require.

### `lib/jido_claw/memory/hybrid_search_sql.ex`
- **Add** `require Ash.Query` at line 69 (after `require Logger`, before the `alias` lines).
- **Delete** line 240 (`require Ash.Query` inside `load_fact_map/2`).
- **Delete** line 769 (`require Ash.Query` inside `load_facts/3`). This is dead code — `load_facts/3` itself contains zero `Ash.Query.*` calls; the macro usage lives in `load_fact_map/2`, called at line 800. The new top-of-module require keeps `load_fact_map/2` covered.

---

## Category #5 — MissingTimestamps (5 issues → 4 files to edit, 1 file to exclude)

### Per-file approach

Two of the offending resources already have an existing `create_timestamp` and only need an `update_timestamp` added beside it — adding `timestamps()` would create a **duplicate create-side column**. The others get explicit `create_timestamp` + `update_timestamp` pairs to preserve metadata.

All four edited resources use `AshPostgres.DataLayer`, so a migration is required.

| File | Current state | Change |
|------|--------------|--------|
| `lib/jido_claw/reasoning/resources/outcome.ex` | Has domain `started_at` / `completed_at`; no row-creation timestamps | Add `create_timestamp(:inserted_at)` and `update_timestamp(:updated_at)` to `attributes do` |
| `lib/jido_claw/forge/resources/event.ex` | Already has `create_timestamp(:timestamp)` at line 94 | Add **only** `update_timestamp(:updated_at)`. Keep `:timestamp` — AshCredo already counts it as the create side |
| `lib/jido_claw/forge/resources/checkpoint.ex` | Already has `create_timestamp(:created_at)` at line 76 | Add **only** `update_timestamp(:updated_at)`. Keep `:created_at` (it's indexed and queried via `sort: [created_at: :desc]`) |
| `lib/jido_claw/conversations/resources/request_correlation.ex` | Has a plain `attribute :inserted_at, :utc_datetime_usec` at lines 184–189 with `public?: true`, `writable?: true`, `allow_nil?: false`, `default: &DateTime.utc_now/0` | **Replace** the plain `attribute :inserted_at` block with `create_timestamp(:inserted_at, public?: true)` and add `update_timestamp(:updated_at, public?: true)` beside it. AshCredo's `MissingTimestamps` check only recognizes `create_timestamp` (non-writable + default) as the create side — keeping the plain attribute would leave the file flagged. Dropping `writable?: true` is consistent with the file's documented contract that `:register` does not accept `inserted_at`. Do **not** swap to bare `timestamps()` — that would silently drop `public?: true` |

### File to exclude

`lib/jido_claw/audit/resources/event.ex` is intentionally append-only (moduledoc states "No `:update`, no `:destroy`"). Adding `update_timestamp` is semantically wrong. Add a per-file exclusion to the `MissingTimestamps` check in `.credo.exs`:

```elixir
{AshCredo.Check.Design.MissingTimestamps,
 [files: %{excluded: ["lib/jido_claw/audit/resources/event.ex"]}]},
```

### Migration workflow

1. `mix ash_postgres.generate_migrations add_missing_timestamps`
2. **Hand-edit the generated migration** before running it. Ash's generator will default `updated_at` (and `inserted_at` on `reasoning_outcomes`) to the migration-run time for existing rows, which is wrong. Add explicit backfill `UPDATE` statements before any `NOT NULL` constraint is applied:

   - `forge_events`: `UPDATE forge_events SET updated_at = timestamp;`
   - `forge_checkpoints`: `UPDATE forge_checkpoints SET updated_at = created_at;`
   - `request_correlations`: `UPDATE request_correlations SET updated_at = inserted_at;`
   - `reasoning_outcomes`: `UPDATE reasoning_outcomes SET inserted_at = started_at, updated_at = COALESCE(completed_at, started_at);` (use `started_at` for the create side; `completed_at` if non-null else `started_at` for the update side)

   If the generator emits the columns as `NOT NULL` from the start, change it to nullable + backfill + `ALTER ... SET NOT NULL`. Otherwise the migration will fail on tables with existing rows.

3. `mix ecto.migrate`

Snapshots under `priv/resource_snapshots/repo/<table>/` update automatically.

---

## Category #4 — MissingPrimaryAction (11 issues → 9 files to edit, 1 file to exclude)

### Footgun caveat

A primary action is what `Ash.create/update/destroy/run_action(resource)` resolves to when no action name is supplied. Marking a destructive/terminal action as primary means a bare `Ash.update(record)` will execute that destructive transition. Phase 1 exploration confirmed **no current caller** relies on implicit primary resolution for any of these resources — they all name the action — but the picks below still bias toward the **least destructive** option among the candidates to harden against future accidents.

### Files to edit

| File | Offending kind | Mark primary | Reasoning |
|------|---------------|-------------|-----------|
| `lib/jido_claw/folio/action.ex` | `update` | `:complete` | Among `:complete` / `:defer` / `:wait`, `:complete` is the happy-path terminal step. All three are intentional state transitions; none is generic. Caveat: terminal — accept the risk or open a follow-up to add a true generic `:update` action |
| `lib/jido_claw/folio/inbox_item.ex` | `update` | `:process` | Happy path among `:process` / `:discard`; first in code_interface |
| `lib/jido_claw/folio/project.ex` | `update` | `:complete` | First in code_interface among `:complete` / `:defer` / `:reactivate`. Caveat: terminal — same as folio/action |
| `lib/jido_claw/orchestration/approval_gate.ex` | `update` | `:approve` | Positive default vs. `:reject`; first in code_interface |
| `lib/jido_claw/orchestration/workflow_run.ex` | `update` | `:start` | Entry point of the lifecycle. None of `:start` / `:await_approval` / `:resume` / `:complete` / `:fail` / `:cancel` is a safe no-op; `:start` matches the workflow_step convention |
| `lib/jido_claw/orchestration/workflow_step.ex` | `update` | `:start` | Entry point; first in lifecycle order |
| `lib/jido_claw/tenants/resources/tenant.ex` | `update` | **`:resume`** | Among `:suspend` / `:resume` / `:archive`, `:resume` is the least destructive (sets status back to `:active`). `:archive` was the previous pick but is terminal (`status = :terminating`) — a footgun if defaulted to. If a true generic update is needed, a follow-up could add `update :update do accept([:name, :config]) end` and mark that primary instead — left out of this scope to keep the diff minimal |
| `lib/jido_claw/forge/resources/session.ex` | `update` | `:update_phase` | Most generic of `:update_phase` / `:mark_failed` / `:complete` / `:cancel` / `:set_sandbox_id`; the others are specializations of it |
| `lib/jido_claw/accounts/user.ex` (two violations) | `update` + `action` | `:change_password` (update) + `:request_magic_link` (action) | The file-declared updates are `:change_password` and `:reset_password_with_token`; AshAuthentication also injects `:confirm` at compile time, but only file-declared actions are editable here. `:change_password` is the user-initiated default; `:reset_password_with_token` is token-bound. For generic actions, the file declares `:request_password_reset_token` and `:request_magic_link` (AshAuthentication also injects `:log_out_everywhere`). Both file-declared options are explicitly wired into AshAuthentication strategies — the pick of `:request_magic_link` is arbitrary among them. Either would work; this picks `:request_magic_link` for consistency with the magic_link strategy DSL ordering |

### File to exclude

`lib/jido_claw/accounts/token.ex` has only `actions do defaults([:read, :destroy]) end` in its body — no `:create`. The "multiple create" actions Credo flags are injected at compile time by the `AshAuthentication.TokenResource` extension transformer and aren't editable from this file. Add a per-file exclusion to the `MissingPrimaryAction` check in `.credo.exs`:

```elixir
{AshCredo.Check.Design.MissingPrimaryAction,
 [files: %{excluded: ["lib/jido_claw/accounts/token.ex"]}]},
```

---

## Files modified

**Code:**
- `lib/jido_claw/memory/consolidator.ex`
- `lib/jido_claw/memory/hybrid_search_sql.ex`
- `lib/jido_claw/reasoning/resources/outcome.ex`
- `lib/jido_claw/forge/resources/event.ex`
- `lib/jido_claw/forge/resources/checkpoint.ex`
- `lib/jido_claw/conversations/resources/request_correlation.ex`
- `lib/jido_claw/folio/action.ex`
- `lib/jido_claw/folio/inbox_item.ex`
- `lib/jido_claw/folio/project.ex`
- `lib/jido_claw/orchestration/approval_gate.ex`
- `lib/jido_claw/orchestration/workflow_run.ex`
- `lib/jido_claw/orchestration/workflow_step.ex`
- `lib/jido_claw/tenants/resources/tenant.ex`
- `lib/jido_claw/forge/resources/session.ex`
- `lib/jido_claw/accounts/user.ex`

**Config:**
- `.credo.exs` (per-check excludes: `MissingTimestamps` → audit/event.ex; `MissingPrimaryAction` → accounts/token.ex)

**Generated:**
- One new file under `priv/repo/migrations/` (from `mix ash_postgres.generate_migrations add_missing_timestamps`), **hand-edited for backfill**
- Snapshot diffs under `priv/resource_snapshots/repo/<table>/`

---

## Verification

After **each** category:

```bash
mix format                                                              # normalize whitespace before checks
mix credo --format json | jq '[.issues[] | select(.check == "AshCredo.Check.Refactor.DirectiveInFunctionBody")] | length'
mix credo --format json | jq '[.issues[] | select(.check == "AshCredo.Check.Design.MissingTimestamps")] | length'
mix credo --format json | jq '[.issues[] | select(.check == "AshCredo.Check.Design.MissingPrimaryAction")] | length'
mix compile --warnings-as-errors
```

End-to-end test runs:
- **Category #6:** `mix test test/jido_claw/memory/`
- **Category #5:** `mix test test/jido_claw/audit/ test/jido_claw/reasoning/ test/jido_claw/conversations/request_correlation_test.exs test/jido_claw/forge/`
- **Category #4:** `mix test test/jido_claw/web/controllers/auth_controller_test.exs test/jido_claw/web/plugs/api_key_auth_test.exs test/jido_claw/tenants/tenant_test.exs test/jido_claw/policy_authz_test.exs test/jido_claw/workflows/ test/jido_claw/forge/` (the `accounts/`, `orchestration/`, and `folio/` test dirs don't exist — coverage for those resources lives under the listed paths)
- **Final:** `mix test` (full suite)

For category #5, after `mix ecto.migrate`, verify backfills via Tidewave's `execute_sql_query`:
```sql
-- forge_events
SELECT COUNT(*) FILTER (WHERE updated_at IS NULL) AS nulls,
       COUNT(*) FILTER (WHERE updated_at <> timestamp) AS mismatches
FROM forge_events;
-- expect 0 / 0

-- forge_checkpoints
SELECT COUNT(*) FILTER (WHERE updated_at IS NULL) AS nulls,
       COUNT(*) FILTER (WHERE updated_at <> created_at) AS mismatches
FROM forge_checkpoints;
-- expect 0 / 0

-- request_correlations
SELECT COUNT(*) FILTER (WHERE updated_at IS NULL) AS nulls,
       COUNT(*) FILTER (WHERE updated_at <> inserted_at) AS mismatches
FROM request_correlations;
-- expect 0 / 0

-- reasoning_outcomes (backfill: inserted_at = started_at, updated_at = COALESCE(completed_at, started_at))
SELECT COUNT(*) FILTER (WHERE inserted_at IS NULL OR updated_at IS NULL) AS nulls,
       COUNT(*) FILTER (WHERE inserted_at <> started_at) AS inserted_mismatches,
       COUNT(*) FILTER (WHERE updated_at <> COALESCE(completed_at, started_at)) AS updated_mismatches
FROM reasoning_outcomes;
-- expect 0 / 0 / 0
```

Final overall check: `mix credo --format json | jq '.issues | length'` should report **150**.

---

## Commit plan (slicing only — not an instruction to commit)

Three slices, one per category, in this order to minimize blast radius:

1. **#6 DirectiveInFunctionBody** — code-motion only, no behavioral change
2. **#5 MissingTimestamps** — resource edits + hand-edited migration + `.credo.exs` exclude for audit/event.ex
3. **#4 MissingPrimaryAction** — resource edits + `.credo.exs` exclude for accounts/token.ex
