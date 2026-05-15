# Resolve AshCredo violations from new rules

## Context

`.credo.exs` recently enabled three AshCredo checks: `Design.MissingCodeInterface`, `Refactor.UseCodeInterface`, and `Refactor.RaisingCall`. `mix credo --format json` currently surfaces **150 issues across 51 distinct files**. We need to bring the codebase into compliance so credo passes cleanly under the new ruleset.

The issues fall into three distinct buckets, each with a different ideal fix:

| Check | Count | Files | Disposition |
|---|---|---|---|
| `Design.MissingCodeInterface` | 63 | 21 | Add `code_interface` defines; exclude AshAuth-managed resources |
| `Refactor.UseCodeInterface` | 58 | 18 | Add missing read/list/get_by defines; route callers through interfaces |
| `Refactor.RaisingCall` | 29 | 12 | Rewrite bang calls (raw + code-interface) to tuple form with `case` |

User decisions captured:
- AshAuth-managed `User`/`Token` → exclude from `MissingCodeInterface` (26 issues)
- Test file `UseCodeInterface` violations → refactor with new `define(:list)` defines (37 issues)
- All `RaisingCall` → refactor to tuples, including the mix task (use `case` + `Mix.raise/1`)

Key constraint to honor throughout: **`RaisingCall` flags Ash code-interface bangs too** (e.g. `Fact.list!`, `Session.set_next_sequence!`). In `lib/` always use the non-bang form with `case`. `RaisingCall` excludes `test/` paths by default, so bangs in tests are fine.

## Phase 1 — `.credo.exs` exclusion (eliminates 26 issues)

**File:** `.credo.exs`

Replace the bare `MissingCodeInterface` entry with a per-rule exclusion (mirrors the existing `MissingPrimaryAction` exclusion at line 34-35):

```elixir
{AshCredo.Check.Design.MissingCodeInterface,
 [files: %{excluded: ["lib/jido_claw/accounts/user.ex", "lib/jido_claw/accounts/token.ex"]}]},
```

Rationale: every action on these two resources is invoked by AshAuthentication's strategy dispatcher, plugs, or the `TokenResource` extension — never by direct project code. Code-interface defines would be dead weight.

Note: this exclusion targets `MissingCodeInterface` only. The `UseCodeInterface` violation in `test/jido_claw/web/plugs/api_key_auth_test.exs:108` (which uses `Ash.Changeset.for_create(User, :register_with_password, …)` directly) is **not** resolved by this exclusion — it's resolved by Phase 2 adding one targeted `User` code interface, see below.

## Phase 2 — Add `code_interface` defines (eliminates 37 MissingCodeInterface + enables Phase 3/4/5)

Per-resource defines, organized by resource. Pattern reference: `lib/jido_claw/projects/project.ex:14-19`.

### Resources needing `define(:read)` + `define(:destroy)` (13 files × 2 = 26 issues)

Boilerplate is the same per file:

```elixir
code_interface do
  define(:read, action: :read)
  define(:destroy, action: :destroy)
end
```

Files (preserve any *existing* defines in these resources — only add the missing ones):

- `lib/jido_claw/embeddings/resources/dispatch_window.ex`
- `lib/jido_claw/folio/action.ex` *(already has `list_next_actions` — add `read` + `destroy`)*
- `lib/jido_claw/folio/inbox_item.ex` *(already has `list_unprocessed` — add `read` + `destroy`)*
- `lib/jido_claw/folio/project.ex` *(already has `list_active` — add `read` + `destroy`)*
- `lib/jido_claw/forge/resources/event.ex`
- `lib/jido_claw/forge/resources/exec_session.ex`
- `lib/jido_claw/forge/resources/session.ex`
- `lib/jido_claw/github/issue_analysis.ex`
- `lib/jido_claw/orchestration/approval_gate.ex`
- `lib/jido_claw/orchestration/workflow_step.ex`
- `lib/jido_claw/reasoning/resources/outcome.ex`
- `lib/jido_claw/security/secret_ref.ex` *(merge into existing code_interface)*
- `lib/jido_claw/solutions/resources/reputation_import.ex`

Resources with `:read`/`:destroy` MissingCodeInterface that also need extra defines (covered in separate sections below): `forge/resources/checkpoint.ex`, `orchestration/workflow_run.ex`, `conversations/resources/request_correlation.ex`.

### `lib/jido_claw/accounts/api_key.ex` (4 issues)

Plain Ash (no AshAuth dispatch concerns):

```elixir
code_interface do
  define(:create, action: :create, args: [:user_id])
  define(:revoke, action: :revoke)
  define(:read, action: :read)
  define(:destroy, action: :destroy)
end
```

### `lib/jido_claw/accounts/user.ex` — targeted add despite Phase 1 exclusion

The `MissingCodeInterface` rule is excluded for this file, but `api_key_auth_test.exs:108` calls `Ash.Changeset.for_create(User, :register_with_password, …)` — a `UseCodeInterface` violation that is **not** filtered by the Phase 1 exclusion. Add a single define so the test refactor in Phase 5 has a target:

```elixir
code_interface do
  define(:register_with_password, action: :register_with_password)
end
```

We deliberately don't add the other 13 — AshAuth dispatches the rest.

### `lib/jido_claw/forge/resources/checkpoint.ex` — `:read` + `:destroy` + get-by

The `MissingCodeInterface` complaint is `:read`/`:destroy`. Add a get-by so `forge/harness.ex:679` can use it:

```elixir
code_interface do
  define(:read, action: :read)
  define(:destroy, action: :destroy)
  define(:get_by_id, action: :read, get_by: [:id])
end
```

### `lib/jido_claw/conversations/resources/request_correlation.ex` (1 issue)

Add the missing default `:read` define (existing defines cover `register`, `complete`, `expired`, `lookup`, `record_telemetry`):

```elixir
# inside the existing code_interface block (line 100)
define(:read, action: :read)
```

There is **no** `:destroy` action on this resource (only `destroy :complete` which is named and already defined). Do not add `bulk_destroy_*` defines — `Ash.bulk_destroy/4` is called directly in `sweep_expired/0` and returns `%Ash.BulkResult{}` (handled in Phase 3).

### `lib/jido_claw/orchestration/workflow_run.ex` (2 MissingCodeInterface + needs unfiltered list)

Merge into the existing code_interface block (line 13). `define(:list, action: :read)` simultaneously satisfies the `:read` MissingCodeInterface and gives the `workflows_live.ex:7` caller an unfiltered list interface:

```elixir
define(:list, action: :read)
define(:destroy, action: :destroy)
```

Do **not** rewrite the LiveView to call existing `list_active` — that would narrow behavior from "all runs" to "active runs".

### Resources needing `define(:list, action: :read)` only — drives Phase 4 + Phase 5

These resources have a default `:read` action but no plain-list define. Add it so lib callers and tests can route through the code interface:

- `lib/jido_claw/memory/resources/fact.ex` — `define(:list, action: :read)`
- `lib/jido_claw/memory/resources/block.ex` — `define(:list, action: :read)`
- `lib/jido_claw/memory/resources/block_revision.ex` — `define(:list, action: :read)`
- `lib/jido_claw/memory/resources/consolidation_run.ex` — `define(:list, action: :read)`
- `lib/jido_claw/memory/resources/link.ex` — `define(:list, action: :read)`
- `lib/jido_claw/conversations/resources/session.ex` — `define(:list, action: :read)` *(for `consolidator.ex:213` caller)*
- `lib/jido_claw/workspaces/resources/workspace.ex` — merge `define(:list, action: :read)` into the existing code_interface block at line 42 *(for `consolidator.ex:158` caller)*
- `lib/jido_claw/solutions/resources/solution.ex` — `define(:list, action: :read)` *(for `solutions/hybrid_search_sql.ex:263` caller)*

### Single-action additions on resources with existing interfaces

- `lib/jido_claw/projects/project.ex` — add the one missing define (current credo message will show which action; likely `:destroy`)
- `lib/jido_claw/tenants/resources/tenant.ex` — add the one missing define

## Phase 3 — Refactor `RaisingCall` to tuple-based (eliminates 29 issues)

Rule of thumb: use non-bang form + `case`. **Code-interface bangs (`Resource.list!`, `Resource.foo!`) are also flagged**, so prefer `Resource.list(...) → {:ok, _} | {:error, _}` everywhere in `lib/`.

### `lib/jido_claw/forge/persistence.ex` (11 issues)

In-file template at line 104-109 (`claim_via_start/1`) shows the pattern. Rewrite each:

- `record_session_started/2` (line 18) — `case Ash.create(Session, attrs, action: :start, authorize?: false)`
- `record_execution_complete/6` (lines 147, 164) — `case Ash.create(ExecSession, …)` then `case Ash.update(exec, …)`
- `log_event/4` (line 189) — `case Ash.create(Event, …)`
- `update_session_phase/2` (line 205) — `case Ash.update(…)`
- `record_sandbox_id/2` (line 221) — `case Ash.update(…)`
- `save_checkpoint/4` (line 235) — `case Ash.create(Checkpoint, …)`
- `latest_checkpoint/1` (line 260) — `case Ash.read(…)`
- `get_events/2` (line 304) — `case Ash.read(…)`
- `find_session/1` (line 378) — `case Ash.read(…)`
- `latest_exec_output/1` (line 423) — `case Ash.read(…)`

Each becomes:
```elixir
case Ash.create(Resource, attrs, action: :foo, authorize?: false) do
  {:ok, record} -> record
  {:error, e} ->
    Logger.warning("[Forge.Persistence] failed: #{inspect(e)}")
    nil
end
```

Keep the existing DB-level `rescue` blocks on `Postgrex.Error`/`DBConnection.*` — those exceptions are not surfaced by Ash as `{:error, _}` and the rescues catch crashes the `case` won't.

### `lib/jido_claw/memory.ex` (4 issues at lines 313, 324, 335, 346)

Four `Ash.read!` calls at the tail of `defp facts_at_label/4` clauses. Each becomes `case Ash.read(query, …) do {:ok, facts} -> facts; {:error, _} -> [] end`. The outer `Enum.each` in `invalidate_at_label/4` no-ops on `[]` — preserves the always-`:ok` write contract.

### LiveView mounts (5 issues)

Convert each `Ash.read!(…)` in `mount/3` to handle the error case with both **a logger call and an error assign** (per user feedback — don't silently swallow DB/auth failures). None of these three LiveViews currently have `require Logger` — add it to each.

- `lib/jido_claw/web/live/folio_live.ex` lines 9, 12, 14 — `Folio.InboxItem.list_unprocessed/0`, `Folio.Action.list_next_actions/0`, `Folio.Project.list_active/0` (interfaces already exist)
- `lib/jido_claw/web/live/projects_live.ex` line 7 — `Projects.Project.read/0` (interface already exists)
- `lib/jido_claw/web/live/workflows_live.ex` line 7 — `Orchestration.WorkflowRun.list/0` (added in Phase 2; do **not** swap to existing `list_active` — current behavior is "all runs")

Template:
```elixir
{items, error} =
  case Folio.InboxItem.list_unprocessed(actor: socket.assigns.current_user, authorize?: false) do
    {:ok, items} -> {items, nil}
    {:error, e} ->
      Logger.warning("[FolioLive] inbox list failed: #{inspect(e)}")
      {[], "Could not load inbox"}
  end
```

Optionally surface the error assign in the template; at minimum log it.

### `lib/jido_claw/conversations/resources/request_correlation.ex` (2 issues)

`sweep_expired/0` (lines 254-270) uses `Ash.read!` then `Ash.bulk_destroy!`. Rewrite as a plain `case` (this file currently has no `require Logger` — add it at the top of the module):

```elixir
@spec sweep_expired() :: {:ok, non_neg_integer()}
def sweep_expired do
  query =
    __MODULE__
    |> Query.for_read(:expired)
    |> Query.limit(@sweep_batch)

  case Ash.read(query, authorize?: false) do
    {:ok, []} ->
      {:ok, 0}

    {:ok, expired} ->
      do_bulk_destroy(expired)

    {:error, reason} ->
      Logger.warning("[RequestCorrelation] sweep read failed: #{inspect(reason)}")
      {:ok, 0}
  end
end

defp do_bulk_destroy(expired) do
  case Ash.bulk_destroy(expired, :complete, %{}, authorize?: false, return_errors?: true) do
    %Ash.BulkResult{status: :success, records: records} ->
      {:ok, length(records || expired)}

    %Ash.BulkResult{status: status, error_count: errors} when status in [:partial_success, :error] ->
      Logger.warning("[RequestCorrelation] sweep destroy partial: status=#{status} errors=#{errors}")
      {:ok, length(expired) - (errors || 0)}
  end
end
```

`Ash.bulk_destroy/4` returns a `%Ash.BulkResult{}` (not a tuple) — handle `status`/`error_count`/`records` directly. The `Query.for_read` call can also become `__MODULE__.query_to_expired()` per the credo `UseCodeInterface` message — that's the Phase 4 conversion for line 258.

### Single-call refactors

- `lib/jido_claw/forge/harness.ex:679` (`Ash.get!`) → `case Checkpoint.get_by_id(checkpoint_id, authorize?: false) do {:ok, c} -> c; {:error, _} -> nil end` (uses define added in Phase 2). Drop the surrounding `rescue` since the case covers Ash errors; **keep** the `rescue` for `DBConnection.*`/`Postgrex.Error` if those bubble unwrapped — easier path: leave the rescue, the case is inside it.
- `lib/jido_claw/memory/consolidator.ex` lines 160, 215 (2 `Ash.read!`) → `case Ash.read(query, …) do {:ok, list} -> list; {:error, _} -> [] end`. Already in a function with `rescue _ -> []`.
- `lib/jido_claw/memory/hybrid_search_sql.ex` line 242 → case + tuple.
- `lib/jido_claw/solutions/hybrid_search_sql.ex` line 263 → case + tuple.

### Mix tasks

- `lib/mix/tasks/jidoclaw.export.memory.ex` (1 `Ash.read!` + 1 `UseCodeInterface`) → `case Fact.list(...) do {:ok, facts} -> render(facts); {:error, reason} -> Mix.raise("export failed: #{inspect(reason)}") end`
- `lib/mix/tasks/jidoclaw.migrate.conversations.ex:144` (`Session.set_next_sequence!`) → replace with:
  ```elixir
  case Session.set_next_sequence(session, next, authorize?: false) do
    {:ok, _} ->
      Mix.shell().info("    imported up to sequence=#{max_seq}; next_sequence=#{next}")

    {:error, reason} ->
      Mix.raise("    set_next_sequence failed: #{inspect(reason)}")
  end
  ```
  This preserves CLI failure semantics and satisfies credo without a disable comment.

## Phase 4 — Refactor lib `UseCodeInterface` (eliminates 21 issues, shares files with Phase 3)

Always use **non-bang** code interfaces in `lib/` (bangs would trigger `RaisingCall`). Per-file conversions, driven by the exact suggestions in credo messages:

| File | Before | After |
|---|---|---|
| `web/live/folio_live.ex:9` | `Ash.read!(InboxItem, …)` | `case Folio.InboxItem.list_unprocessed(…) do …` |
| `web/live/folio_live.ex:12` | `Ash.read!(Action, …)` | `case Folio.Action.list_next_actions(…) do …` |
| `web/live/folio_live.ex:14` | `Ash.read!(Project, …)` | `case Folio.Project.list_active(…) do …` |
| `web/live/projects_live.ex:7` | `Ash.read!(Project, …)` | `case Projects.Project.read(…) do …` |
| `web/live/workflows_live.ex:7` | `Ash.read!(WorkflowRun, …)` | `case Orchestration.WorkflowRun.list(…) do …` (new define) |
| `forge/persistence.ex:259` | `Query.for_read(:latest_for_session, …)` | `Checkpoint.query_to_latest_for_session(…) \|> Ash.read(…)` *(already exists, just call it)* |
| `forge/persistence.ex:303` | `Query.for_read(:for_session, …)` | `Event.query_to_list_for_session(…) \|> Ash.read(…)` |
| `forge/harness.ex:679` | `Ash.get!(Checkpoint, …)` | `Checkpoint.get_by_id(…)` (new in Phase 2) |
| `memory.ex:307,318,329,340` | `for_read(:read) \|> Query.filter(…) \|> Ash.read!` | `Fact.query_to_list(…) \|> Query.filter(…) \|> Ash.read(…)` |
| `memory/consolidator.ex:158` | `for_read(:read) \|> Query.filter(…)` | `Workspaces.Workspace.query_to_list(…) \|> Query.filter(…) \|> Ash.read(…)` |
| `memory/consolidator.ex:213` | `for_read(:read)` | `Conversations.Session.list(…)` (no filter) |
| `memory/hybrid_search_sql.ex:242` | `for_read(:read) \|> Query.filter(…)` | `Fact.query_to_list(…) \|> Query.filter(…) \|> Ash.read(…)` |
| `solutions/hybrid_search_sql.ex:263` | `for_read(:read) \|> Query.filter(…)` | `Solutions.Solution.query_to_list(…) \|> Query.filter(…) \|> Ash.read(…)` |
| `conversations/resources/request_correlation.ex:258` | `Query.for_read(:expired)` | `__MODULE__.query_to_expired()` |
| `workspaces/resolver.ex:56` | `Ash.Changeset.for_create(:register, …)` | `Workspaces.Workspace.changeset_to_register(…)` *(already exists)* |
| `mix/tasks/jidoclaw.export.memory.ex:62` | `Query.for_read(:read)` | `Fact.list(…)` |

Phases 3 and 4 share most files — do them together file-by-file so each file is touched once.

**Note on filtered reads**: `Resource.list(...)` returns `{:ok, list} | {:error, _}` — you cannot pipe it into `Ash.Query.filter`. For filtered reads, use the generated `Resource.query_to_list(...)` (which returns an `%Ash.Query{}`) and then pipe through `Query.filter |> Ash.read(...)`. Alternatively, use `Resource.list(query: [filter: [...]], …)` for simple filters.

## Phase 5 — Refactor test `UseCodeInterface` (eliminates 37 issues)

`RaisingCall` excludes `test/` paths, so use the **bang** code interfaces here for terser test code. Pattern reference: `test/jido_claw/memory/block_test.exs:30,123`.

Common rewrites:
- `Ash.read!(Fact, tenant: t, actor: a)` → `Fact.list!(tenant: t, actor: a)`
- `Ash.read!(Block, …)` → `Block.list!(…)`
- `Ash.read!(ConsolidationRun, …)` → `ConsolidationRun.list!(…)`
- `Ash.get!(Fact, id, …)` → `Fact.by_id!(id, …)` *(define already exists)*
- `Ash.Changeset.for_create(Session, :start, …) |> Ash.create(domain: …)` → `Session.start(…)` *(non-bang to match existing patterns, or `start!`)*
- `Ash.Changeset.for_create(Fact, :record, …) |> Ash.create()` → `Fact.record(…)` or `Fact.record!(…)`
- `Ash.Changeset.for_update(seeded, :transition_embedding_status, …) |> Ash.update!()` → `Fact.transition_embedding_status!(seeded, …)`
- `Ash.Changeset.for_create(User, :register_with_password, attrs) |> Ash.create(authorize?: false)` → `User.register_with_password(attrs, authorize?: false)` *(define added in Phase 2)*
- `Ash.Changeset.for_create(ApiKey, :create, %{user_id: user.id}) |> Ash.create(authorize?: false)` → `ApiKey.create(user.id, authorize?: false)` *(define added in Phase 2 with `args: [:user_id]`, so `user_id` is positional)*

Files:

- `test/jido_claw/memory/retrieval_test.exs` (20) — bulk of work; mechanical
- `test/jido_claw/memory/consolidator/run_server_test.exs` (8) — Fact/Block/ConsolidationRun lists
- `test/jido_claw/memory/fact_test.exs` (5)
- `test/jido_claw/workspaces/policy_transitions_test.exs` (3) — all 3 are `Fact.record` rewrites
- `test/jido_claw/web/plugs/api_key_auth_test.exs` (2) — User + ApiKey code interfaces
- `test/jido_claw/memory/block_test.exs` (1) — one outlier

## Verification

1. `mix credo --strict` exits clean for the three target checks. Verify by:
   ```bash
   mix credo --format json | jq '[.issues[] | select(.check | startswith("AshCredo.Check.Design.MissingCodeInterface") or startswith("AshCredo.Check.Refactor.UseCodeInterface") or startswith("AshCredo.Check.Refactor.RaisingCall"))] | length'
   # → 0
   ```
2. `mix compile --warnings-as-errors` succeeds — new `code_interface` entries compile.
3. `mix test` passes — Phase 5 rewrites preserve behavior; Phase 3 fallback paths (`[]`/`nil` on `{:error, _}`) match what callers expect.
4. **LiveView smoke check**: `mix jidoclaw` or the Phoenix dashboard — confirm `/folio`, `/projects`, `/workflows` render. Force a DB error (e.g. temporarily revoke a permission) to confirm error-path logs and renders gracefully rather than crashing the LiveView.
5. **Sweeper smoke check**: confirm `RequestCorrelation.sweep_expired/0` still returns `{:ok, integer}` — start the app, insert an expired correlation row, wait for sweeper tick.
6. `mix format --check-formatted` clean.

## Suggested commit slicing

Each phase is independently testable and reviewable. Suggested ordering (not authorization to commit — each commit requires explicit user request):

1. `chore(credo): exclude AshAuth resources from MissingCodeInterface` — Phase 1
2. `feat(ash): add code_interface defines to N resources` — Phase 2 (no caller changes)
3. `refactor(forge): replace raising Ash calls with tuple handling in Persistence` — Phase 3, just `persistence.ex`
4. `refactor(memory/web): tuple-handle Ash read calls` — Phase 3 + Phase 4 for the remaining lib files
5. `refactor(test): use Memory code interfaces in tests` — Phase 5 (biggest changeset, fully mechanical)

## Critical files to modify

**Config:** `.credo.exs`

**Resources gaining `code_interface` defines (Phase 2):** 21 files under `lib/jido_claw/{accounts,conversations,embeddings,folio,forge,github,memory,orchestration,projects,reasoning,security,solutions,tenants,workspaces}/`

**Lib refactors (Phase 3 + Phase 4):** `lib/jido_claw/{forge/{persistence.ex,harness.ex},memory.ex,memory/consolidator.ex,memory/hybrid_search_sql.ex,solutions/hybrid_search_sql.ex,conversations/resources/request_correlation.ex,workspaces/resolver.ex,web/live/{folio,projects,workflows}_live.ex}`, `lib/mix/tasks/jidoclaw.{export.memory,migrate.conversations}.ex`

**Test refactors (Phase 5):** `test/jido_claw/memory/{retrieval,fact,block}_test.exs`, `test/jido_claw/memory/consolidator/run_server_test.exs`, `test/jido_claw/workspaces/policy_transitions_test.exs`, `test/jido_claw/web/plugs/api_key_auth_test.exs`
