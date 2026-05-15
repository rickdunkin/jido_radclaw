# Plan: Resolve `AshCredo.Check.Readability.ActionMissingDescription` (83 issues)

## Context

New AshCredo rules were added to `.credo.exs`, producing 269 issues across 8 checks.
Of those, **83 are `Readability.ActionMissingDescription`** — every *explicitly
declared* Ash action on the listed resources lacks a human-readable
`description("...")`. The fix is purely additive: it improves API documentation
surfaced through `iex> Ash.Resource.Info.action/2`, generated docs, and
AshAdmin/JSON:API UIs, without altering behavior.

**Scope caveat**: `defaults([:read, :destroy])` lines compile to named `:read`/`:destroy`
actions at runtime, but AshCredo only scans explicit `read`/`create`/`update`/`destroy`
DSL entries — so the check passes at 0 without those defaults being annotated. This
plan does not add descriptions to `defaults(...)`-generated actions; resolving the
credo check is the goal, not full runtime-action documentation coverage.

The codebase already establishes the convention in three files
(`lib/jido_claw/accounts/user.ex`, `lib/jido_claw/accounts/api_key.ex`,
`lib/jido_claw/solutions/resources/solution.ex`) — this plan extends that convention
to the remaining 20 resources.

## Style guide (derived from existing usage)

- **Form**: `description("...")` — function-call style with parens, matching the
  surrounding DSL (`accept(...)`, `change(...)`, `filter(expr(...))`).
- **Placement**: First line inside the action `do ... end` block, before any
  `accept`/`argument`/`change`/`filter`/`prepare`.
- **Voice**: Imperative, describes WHAT the action does. Examples already in repo:
  - `description("Sign in a user with their email and password.")`
  - `description("Revoke an API key by setting revoked_at.")`
  - `description("Get a user by their AshAuthentication subject claim.")`
- **Length**: 5–12 words, single sentence, ending with a period.
- **No heredoc descriptions** — none exist in the codebase; do not introduce them.

Use the action name + body (filter expr, change calls, validations, `upsert_identity`,
arguments) as the source of truth for what each description should say. The action
names in this codebase are already meaningful (`:by_project`, `:list_active`,
`:mark_failed`), so a description that restates the verb in plain English is usually
the right move.

## Files & action counts

20 files, 83 actions. Grouped by subsystem for slicing.

### Folio (24)
- `lib/jido_claw/folio/action.ex` (9): `create`, `complete`, `defer`, `wait`,
  `next_actions`, `waiting`, `by_context`, `by_project`, `by_user`
- `lib/jido_claw/folio/inbox_item.ex` (5): `capture`, `process`, `discard`,
  `unprocessed`, `by_user`
- `lib/jido_claw/folio/project.ex` (6): `create`, `complete`, `defer`, `reactivate`,
  `active`, `by_user`
- `lib/jido_claw/projects/project.ex` (4): `create`, `read`, `update`, `destroy`
- (`lib/jido_claw/github/issue_analysis.ex` lives in its own slice below.)

### Orchestration (18)
- `lib/jido_claw/orchestration/workflow_run.ex` (9): `create`, `start`,
  `await_approval`, `resume`, `complete`, `fail`, `cancel`, `list_active`, `by_project`
- `lib/jido_claw/orchestration/workflow_step.ex` (5): `create`, `start`, `complete`,
  `fail`, `skip`
- `lib/jido_claw/orchestration/approval_gate.ex` (4): `create`, `approve`, `reject`,
  `pending_for_run`

### Forge (13)
- `lib/jido_claw/forge/resources/session.ex` (7): `start`, `update_phase`,
  `mark_failed`, `complete`, `cancel`, `set_sandbox_id`, `list_active`
- `lib/jido_claw/forge/resources/checkpoint.ex` (2): `create`, `latest_for_session`
- `lib/jido_claw/forge/resources/event.ex` (2): `create`, `for_session`
- `lib/jido_claw/forge/resources/exec_session.ex` (2): `start`, `complete`

### Tenants / Accounts / Security (11)
- `lib/jido_claw/tenants/resources/tenant.ex` (6): `register`, `suspend`, `resume`,
  `archive`, `by_id`, `list`
- `lib/jido_claw/security/secret_ref.ex` (4): `create`, `update`, `by_name`,
  `by_category`
- `lib/jido_claw/accounts/api_key.ex` (1): `create`

### Conversations / Audit / Reasoning / Embeddings / Solutions / GitHub (17)
- `lib/jido_claw/conversations/resources/request_correlation.ex` (5): `register`,
  `record_telemetry`, `complete`, `expired`, `lookup`
- `lib/jido_claw/audit/resources/event.ex` (3): `record`, `for_target`, `for_actor`
- `lib/jido_claw/reasoning/resources/outcome.ex` (2): `record`, `by_task_type`
- `lib/jido_claw/embeddings/resources/dispatch_window.ex` (1): `read_window`
- `lib/jido_claw/solutions/resources/reputation_import.ex` (2): `record_import`,
  `find_by_hash`
- `lib/jido_claw/github/issue_analysis.ex` (4): `create`, `update_status`, `by_repo`,
  `by_issue`

## Approach

For each file:

1. Open the file and locate each flagged action by name (line numbers from credo may
   shift as edits are made — match on `<kind> :<name> do` instead).
2. Insert `description("<imperative sentence>.")` as the first line inside the
   `do` block.
3. Derive the sentence from the action name, body expressions, and any surrounding
   context (e.g., `filter(expr(status == :active))` → "List active <thing>s.";
   `change(set_attribute(:revoked_at, ...))` → "Revoke ... by setting `revoked_at`.").
4. Save and move to the next file.

No code logic changes. No new dependencies. No moves between modules.

### Edge cases & wording traps

- **`defaults([:read, :destroy])`** entries are not flagged by AshCredo (it scans
  explicit DSL entries only), so leave them as-is. See scope caveat in Context.
- **`accounts/api_key.ex`** already has a description on `update :revoke` (the only
  flagged action is `create :create` at line 17).
- **`accounts/user.ex`** is NOT in the issue list — it already describes its actions.
  Use it as a style reference.
- **Generic `action :foo, :type do` actions** — exploration confirmed none exist
  in the affected files, so all 83 are `create`/`read`/`update`/`destroy`.

**Wording traps** — match the description to what the action actually does, not
just its name:

- `destroy :complete` in
  `lib/jido_claw/conversations/resources/request_correlation.ex:136` **deletes**
  the row. Do NOT write "Mark as completed." — try
  `"Delete a correlation row once the request finishes."` or similar.
- `create :start` in `lib/jido_claw/forge/resources/session.ex` uses `upsert?(true)`
  with an `upsert_identity`. Describe it as start-or-resume, not a fresh insert.
- `create :register` in `lib/jido_claw/tenants/resources/tenant.ex` is also
  `upsert?(true)`. Same guidance — phrase it as register-or-update.
- For each `read` with a `filter(expr(...))`, read the filter before writing the
  description (e.g. `:list_active` filters on phase; `:by_project` filters by
  `project_id` argument).

## Suggested commit slicing

One commit per subsystem keeps each diff scannable, gives clean credo deltas, and
lets review batch by domain owner. (Per memory: this is slicing guidance only —
do not commit without an explicit request.)

1. `docs: describe Folio Ash actions` — Folio + projects (24)
2. `docs: describe Orchestration Ash actions` — orchestration (18)
3. `docs: describe Forge Ash actions` — forge resources (13)
4. `docs: describe Tenants/Security/Accounts Ash actions` — tenant, secret_ref,
   api_key (11)
5. `docs: describe remaining Ash actions` — conversations, audit, reasoning,
   embeddings, solutions, github (17)

Total: 24 + 18 + 13 + 11 + 17 = **83**. Using `docs:` because these are
documentation strings consumed by AshAdmin / generated docs, not behavior changes.

If reviewers prefer one PR with logical commits, the same split works as a single
PR with 5 commits.

## Verification

While working, leave stderr visible so Mix/Credo errors aren't swallowed:

```bash
# global remaining count for this check — should drop after every subsystem
mix credo --format json \
  | jq '[.issues[] | select(.check == "AshCredo.Check.Readability.ActionMissingDescription")] | length'

# subsystem-scoped check (replace the path prefix per slice)
mix credo --format json \
  | jq '[.issues[]
         | select(.check == "AshCredo.Check.Readability.ActionMissingDescription")
         | select(.filename | startswith("lib/jido_claw/folio/"))] | length'
```

Some slices span more than one path prefix (e.g. the Folio slice also includes
`lib/jido_claw/projects/project.ex`; the Tenants/Security/Accounts slice spans
three subdirectories). Use multiple predicates in those cases, e.g.:

```bash
mix credo --format json \
  | jq '[.issues[]
         | select(.check == "AshCredo.Check.Readability.ActionMissingDescription")
         | select(.filename | startswith("lib/jido_claw/folio/")
                            or startswith("lib/jido_claw/projects/"))] | length'
```

At the end of the work:

```bash
# expect 0
mix credo --format json \
  | jq '[.issues[] | select(.check == "AshCredo.Check.Readability.ActionMissingDescription")] | length'

# the other 7 categories should still report the same counts (186 = 269 - 83)
mix credo --format json | jq '.issues | length'

mix compile --warnings-as-errors
mix format
mix format --check-formatted
mix test
```

Optional sanity check in `iex`:

```elixir
iex> Ash.Resource.Info.action(JidoClaw.Folio.Action, :complete).description
# => "Mark an action as completed."
```

## Critical files

All edits are confined to the 20 files listed under **Files & action counts** above.
No other files (including `.credo.exs`, mix files, tests, migrations) require changes.
