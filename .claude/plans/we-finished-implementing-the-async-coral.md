# v0.6.4 Test Migration & New-Resource Coverage Plan

## Context

The v0.6.4 implementation moved tenant scoping from a column-on-attrs convention to Ash `:attribute` multitenancy with `global? false` on 14 resources. Three new resources (`Tenants.Tenant`, `Audit.Event`, `Cron.Job`) were added with no test coverage. ~29 existing test files (~60 actual Ash-action call sites, ~175 raw `tenant_id:` occurrences once you include scope-map literals) still embed `tenant_id:` inside attrs maps and will fail under the new contract. Two reasoning tests still assert on the deprecated `Outcome.workspace_id` and `Outcome.agent_id` string columns that telemetry no longer populates. The work is to rebuild the test suite around the v0.6.4 multitenancy contract, add coverage for the new resources and audit infrastructure, and update the reasoning tests to assert the deprecation.

The canonical migration shape is already applied at `test/jido_claw/conversations/recorder_test.exs:370-395` (`seed_session/1`):

```elixir
tenant_id = "tenant-..."
{:ok, _} = JidoClaw.Tenants.Tenant.ensure(tenant_id)        # FK parent
{:ok, ws} = Workspace.register(attrs_no_tenant_id, tenant: tenant_id)
{:ok, sn} = Session.start(attrs_no_tenant_id, tenant: tenant_id)
```

Three rules: (1) `Tenant.ensure/1` first; (2) `tenant: tenant_id` opt; (3) drop `tenant_id` from attrs.

## Approach

Six stages, executed in order:

1. Build a shared `JidoClaw.TenantCase` test support module with the canonical seed helpers.
2. Migrate `test/support/jido_claw/solutions_case.ex` (used by 3 solutions tests) to the new pattern.
3. Migrate the 28 remaining outdated test files by subsystem, swapping in `TenantCase` helpers.
4. Update reasoning tests to assert telemetry no longer populates the deprecated string columns.
5. Author full coverage for the three new resources.
6. Author tests for the new audit infrastructure (`AsyncWriter`, `SignalListener`, `Producers`) and the `auth_event` emission from `AuthController`.

After each stage run `mix test` and stop on failures. Format-check at the end of each stage.

---

## Stage 1 — `JidoClaw.TenantCase` Support Module

Create `test/support/jido_claw/tenant_case.ex`. This is the single API every migrated test will import.

Required surface:
- `unique_tenant_id/0` — `"tenant-#{System.unique_integer([:positive])}"` (matches `solutions_case.ex:39`)
- `unique_tenant_id/1` — same with a label prefix for grep-friendly fixtures
- `seed_tenant/0`, `seed_tenant/1` — generates id, calls `Tenants.Tenant.ensure/1`, returns the binary id
- `seed_workspace/2` — `(tenant_id, opts)` → `{:ok, ws}` via `Workspace.register/2`, threads `tenant:` opt; defaults `path:` and `name:` to unique values
- `seed_session/2` — `(tenant_id, workspace_id, opts)` → `{:ok, session}` via `Session.start/2`, threads `tenant:` opt
- `seed_full/1` — `opts` → `%{tenant_id, workspace, session}`; convenience for the common case

Setup callback: same Ecto sandbox checkout pattern as `solutions_case.ex:30-34` (shared mode unless `async`).

Critical references in code:
- `lib/jido_claw/tenants/resources/tenant.ex:128-131` — `ensure/1` semantics (idempotent, no-op on existing rows even if `:suspended`)
- `lib/jido_claw/conversations/resources/session.ex:69-77` — current `:start` accept list
- `lib/jido_claw/workspaces/resources/workspace.ex` — `:register` action signature

## Stage 2 — Migrate `solutions_case.ex`

`test/support/jido_claw/solutions_case.ex:45-58` (`workspace_fixture/2`) and `:77-108` (`solution_fixture/4`) embed `tenant_id:` in attrs. Migrate both:

- `workspace_fixture(tenant_id, opts)` → call `Tenants.Tenant.ensure(tenant_id)` first, then `Workspace.register(attrs_no_tenant_id, tenant: tenant_id)`.
- `solution_fixture(tenant_id, workspace_id, content, opts)` → drop `tenant_id` from attrs, pass via `Solution.store(attrs, tenant: tenant_id)`.
- Re-export `unique_tenant_id/0` from `TenantCase` rather than redefining.

After this stage the three solutions tests (`network_facade_test.exs`, `hybrid_search_sql_test.exs`, `matcher_test.exs`) inherit the new behavior with no further touches needed if they only consume the helpers.

## Stage 3 — Migrate Outdated Test Files (28 files)

For each file: search for `tenant_id:` keys passed to Ash actions, swap to the canonical pattern, replace ad-hoc seed helpers with `TenantCase` imports where it cleans things up. Scope-map literals (e.g., `Cache.put(_, %{tenant_id: ...})`) are NOT attrs and should be left alone.

**Order (by subsystem, smallest blast radius first):**

1. **Workspaces** (2 files): `workspaces/workspace_test.exs`, `workspaces/policy_transitions_test.exs` — pure resource tests, easy warm-up.
2. **Conversations** (4 files, recorder already done): `message_test.exs` (12 hits), `session_test.exs` (5), `history_test.exs` (5), `request_correlation_test.exs` (7). RequestCorrelation is `global? true` — confirm via `lib/jido_claw/conversations/resources/request_correlation.ex` and migrate any tenant attr writes anyway since they should now match the multitenancy strategy.
3. **Memory** (7 files): `block_test.exs` (7), `retrieval_test.exs` (17), `scope_test.exs` (6), `fact_test.exs` (2), `consolidator/run_server_test.exs` (6), `consolidator/policy_resolver_test.exs` (2), `consolidator/prompt_test.exs` (1). `block_test.exs:23-65` uses literal `"default"` — convert to `unique_tenant_id` per test.
4. **Workflows / Tools / Embeddings / Agent** (11 files): `workflows/scope_propagation_test.exs` (6), `workflows/step_action_test.exs` (2), `tools/recall_test.exs` (1), `tools/run_skill_test.exs` (4), `tools/mcp_scope_test.exs` (2), `tools/remember_test.exs` (1), `embeddings/backfill_worker_test.exs` (5), `embeddings/policy_resolver_test.exs` (4), `agent/prompt_snapshot_test.exs` (3), `tool_context_test.exs` (3), `tool_context_shape_test.exs` (2).
5. **Solutions** (3 files): `network_facade_test.exs`, `hybrid_search_sql_test.exs`, `matcher_test.exs` — verify they pass cleanly after Stage 2.

Run `mix test path/to/just_migrated_test.exs` after each file to catch regressions immediately rather than at end-of-stage.

## Stage 4 — Reasoning Deprecated-Column Tests

Two files, both writing to `Reasoning.Outcome` and asserting on the now-deprecated `workspace_id` / `agent_id` string columns:

- `test/jido_claw/reasoning/outcome_test.exs:27,40,65,76,81,88,95-96`
- `test/jido_claw/reasoning/telemetry_test.exs:63,69,78,82,88,97,104,111-112,136,140,145,147`

Per v0.6.4 §4: telemetry stops populating these columns; the schema fields persist with deprecation moduledoc. Required updates:

- For telemetry-driven writes, change assertions from `r.workspace_id == "ws-abc"` to `r.workspace_id == nil` (and same for `agent_id`).
- For direct `Outcome.create` calls in tests that intentionally set these columns to verify the schema still accepts the field, leave the writes but add a comment pointing at the deprecation moduledoc on `lib/jido_claw/reasoning/resources/outcome.ex` and an `@tag :deprecated_outcome_columns` so they can be deleted in one sweep when the columns are dropped.
- Also migrate the tenant-attr pattern in these files (~4 hits combined).

Verify `lib/jido_claw/reasoning/telemetry.ex` to confirm exactly which writers were neutered before locking in the assertions.

## Stage 5 — New Resource Test Files

Author three test files mirroring source structure. All three use `TenantCase`.

### `test/jido_claw/tenants/tenant_test.exs`
- `:register` upsert preserves `status`/`name`/`config` on second call (only `updated_at` changes); a `:suspended` tenant is NOT reactivated by re-register
- `ensure/1` is idempotent and returns the existing row
- `:suspend`, `:resume`, `:archive` state transitions and their guard rails
- `:by_id` returns the row; `:list` returns expected ordering
- No `:destroy` action exists (assert `Tenant` does not respond to a destroy call)
- Concurrent `ensure/1` calls collapse onto one row (Task.async_stream check, `n=20`)

Reference: `lib/jido_claw/tenants/resources/tenant.ex` for action list and accept lists.

### `test/jido_claw/audit/event_test.exs`
- `:record` requires `tenant:` opt; rejects writes without `tenant_id`
- `:record` accept list excludes `tenant_id` (assert at-call validation, not just attr filtering)
- Append-only: assert no `:update` or `:destroy` actions are exposed
- `:for_target` and `:for_actor` query actions return only matching rows under the supplied tenant
- Multitenancy boundary: a write under tenant A is invisible to a `:read` under tenant B; `:by_id_global` (if present — check) bypasses
- Each `event_kind` enum value (`:memory_write, :memory_consolidation, :solution_share, :session_start, :session_end, :tool_call, :auth_event`) accepts a representative payload
- Policies: a non-admin actor cannot read another tenant's rows even with the right id

Reference: `lib/jido_claw/audit/resources/event.ex` for full action set + policies.

### `test/jido_claw/cron/job_test.exs`
- `:upsert` on `[tenant_id, job_id]` identity: second call with same id updates rather than inserts
- `:upsert` accept list excludes `tenant_id` — pass via `tenant:` opt
- `:disable` sets `disabled_at`; `:enable` clears it
- `:remove` (destroy) removes the row
- `:by_id_global` bypasses tenancy; `:by_id` requires it
- `:by_job_id` and `:for_tenant` return correct subsets
- All three `schedule_kind` values (`:cron`, `:every`, `:at`) round-trip correctly
- Auto-disable behavior: simulate 3 worker failures, assert `disabled_at` is persisted (covers `lib/jido_claw/platform/cron/worker.ex`)

Reference: `lib/jido_claw/cron/resources/job.ex` and the `worker.ex` failure handling.

## Stage 6 — Audit Infrastructure & Auth Event

### `test/jido_claw/audit/async_writer_test.exs`
- `sync/1` writes inline and returns `:ok` even on Ash error (logs warning)
- `cast/1` spawns under `Audit.TaskSupervisor`; assert no exception escapes when the row insert fails
- Both shapes strip `tenant_id` from attrs and thread it via opt (assert by inspecting the actual created row)
- `do_record/1` with no `tenant_id` logs a warning and returns `:ok` without writing

Reference: `lib/jido_claw/audit/async_writer.ex` lines 24-79.

### `test/jido_claw/audit/signal_listener_test.exs`
- Subscribes to `ai.tool.started` on boot; survives `SignalBus` restarts (`:DOWN` → retry)
- Resolves scope via `Cache.lookup/1` first, falls back to `RequestCorrelation.lookup/1`, populates cache on Postgres hit
- Skips with `[:jido_claw, :audit, :tool_call, :skipped]` telemetry when `request_id` missing or correlation lookup fails
- Emits `:tool_call` audit event with `actor_kind: :agent`, `target_kind: :tool`, payload containing `request_id`/`session_id`/`arguments`/`tool_name`
- `safe_handle/1` swallows raises and throws

Reference: `lib/jido_claw/audit/signal_listener.ex` lines 56-178. Use `:telemetry.attach/4` in tests and a captured-PID receive pattern; subscribe a fake bus subscriber to validate event ordering.

### `test/jido_claw/audit/producers_test.exs`
- Each inline producer (memory writes, solution shares, session start/end) emits the right `event_kind` synchronously inside the action transaction
- Rolling back the outer action also rolls back the audit row (use `Ash.Changeset.before_action/2` injection or sandbox transaction control)
- Session `:start` emit fires exactly-once even with the resolver-level fallback path

Reference: `lib/jido_claw/audit/producers.ex` and the v0.6.4 notes' "Session `:start` switched from upsert to insert-only with resolver-level fallback so the audit emit fires exactly-once" claim.

### `test/jido_claw/web/controllers/auth_controller_test.exs` (extend if exists, else create)
- `sign_in` and `sign_out` paths emit `:auth_event` audit rows under the user's tenant
- The emit happens once per call; verify by counting rows after the action

Reference: `lib/jido_claw/web/controllers/auth_controller.ex` for the actor map shape.

---

## Critical Files

**New (will create):**
- `test/support/jido_claw/tenant_case.ex`
- `test/jido_claw/tenants/tenant_test.exs`
- `test/jido_claw/audit/event_test.exs`
- `test/jido_claw/audit/async_writer_test.exs`
- `test/jido_claw/audit/signal_listener_test.exs`
- `test/jido_claw/audit/producers_test.exs`
- `test/jido_claw/cron/job_test.exs`
- `test/jido_claw/web/controllers/auth_controller_test.exs` (or extend existing)

**To migrate:**
- `test/support/jido_claw/solutions_case.ex` (Stage 2)
- 28 test files listed in Stage 3
- 2 reasoning test files in Stage 4

**Read-only references (do NOT modify):**
- `test/jido_claw/conversations/recorder_test.exs:370-395` — canonical seed pattern
- `lib/jido_claw/tenants/resources/tenant.ex:128-131` — `ensure/1` semantics
- `lib/jido_claw/audit/{async_writer,signal_listener,producers}.ex` — behaviors under test
- `lib/jido_claw/cron/resources/job.ex` — action surface
- `lib/jido_claw/audit/resources/event.ex` — action surface + policies

## Reused Patterns

- `JidoClaw.SolutionsCase` (`test/support/jido_claw/solutions_case.ex:30-34`) — Ecto sandbox setup; copy into `TenantCase`.
- `recorder_test.exs:370-395` — canonical fixture shape; `TenantCase.seed_full/1` is a generalization.
- `:telemetry.attach/4` is already used elsewhere in the suite (verify by grepping `test/`); reuse the same captured-pid receive idiom for telemetry assertions in Stage 6.

## Verification

Run after each stage and at the end:

```bash
mix compile --warnings-as-errors    # compile clean
mix format --check-formatted        # formatting
mix test                            # full suite
```

Per-stage checks:
- **Stage 1**: `mix compile` only — no behavior to test yet (TenantCase has no callers).
- **Stage 2**: `mix test test/jido_claw/solutions/` to catch any regressions in the three solutions tests immediately.
- **Stage 3**: `mix test path/to/migrated_test.exs` after each file.
- **Stage 4**: `mix test test/jido_claw/reasoning/`.
- **Stage 5**: `mix test test/jido_claw/{tenants,audit,cron}/`.
- **Stage 6**: `mix test test/jido_claw/audit/ test/jido_claw/web/`.
- **Final**: full `mix test` plus `mix test/jido_claw/v064_file_store_sweep_test.exs` to confirm the v0.6.4 sweep guard still passes.

End-to-end smoke check: bring up the app once via `mix jidoclaw` and confirm a single CLI command runs without raising — exercises the full multitenancy + audit pipeline against a real tenant row.

## Out of scope

- **Step 5 actor threading** (per v0.6.4 completion notes): full `actor:` opt threading at every Ash call site. This plan tests the multitenancy boundary, not the policy boundary; policy tests on `Audit.Event` and `Cron.Job` in Stage 5 use bypass actions where applicable, not actor enforcement.
- **Dropping the deprecated `Outcome.workspace_id` / `agent_id` columns** — Stage 4 only flags the deprecation; the column-drop migration is a separate ticket.
- **Committing** — per AGENTS.md and saved feedback, do not run `git commit` without explicit instruction.
