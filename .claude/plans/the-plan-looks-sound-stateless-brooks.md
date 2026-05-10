# v0.6 Phase 4 — Code Review Fix-up

## Context

Phase 4 (audit log + tenant promotion + cron migration) shipped behind `0b0d6e8 Memory: Cleanup Sprint`, but a follow-up review found five gaps: snapshots out of sync with resources, two CLI/Mix surfaces broken under the new `global? false` workspace/session resources, a Mix task that bypasses the `tenants.id` FK parent for new tenants, and a stray alias that breaks `mix test --warnings-as-errors`. All five were verified against current `main` and are accurate. This plan closes them with the minimum diff and adds regression coverage where the bug was a missed boundary the test suite wasn't asserting on.

Verification done in plan mode:

- `mix ash_postgres.generate_migrations --check` → `Pending Code Generation Detected for 19 files`. Dry-run preview shows real index/FK reshape ops on `messages`, `reasoning_outcomes`, etc., not pure churn.
- `lib/jido_claw/cli/commands.ex:1238` calls `Ash.get(JidoClaw.Workspaces.Workspace, uuid, domain: …)` with no `tenant:`. `Workspace` is `global? false` (`workspaces/resources/workspace.ex:42`). REPL state carries `tenant_id` (`cli/repl.ex:23`).
- `lib/mix/tasks/jidoclaw.export.conversations.ex:77` calls `Ash.get(Session, uuid, domain: …)` with no `tenant:`. `Session` is `global? false` (`conversations/resources/session.ex:99`). The downstream `Message.for_session(session.id, tenant: session.tenant_id)` already threads tenant correctly.
- `lib/mix/tasks/jidoclaw.migrate.cron.ex:32,80` accepts `--tenant` and upserts `Cron.Job` without ever calling `Tenants.Tenant.ensure/1`. `cron_jobs.tenant_id` FKs at `tenants.id`.
- `test/jido_claw/tools/mcp_scope_test.exs:19` aliases `Session` and never references it.
- `PolicyTransitions.apply_embedding/3` (`workspaces/policy_transitions.ex:26`, default `opts \\ []`) operates on raw SQL keyed by `workspace_id` — no tenant threading needed.
- `.formatter.exs` is not in git history. Restoring it is out of scope for this fix-up; flagged as follow-up below.

## Fixes

### 1. Codegen catch-up (P1)

Resource snapshots lag the resource definitions; the v064 migrations on disk were partially hand-rolled. Regenerate via the Ash workflow command, not the AshPostgres-direct one:

```
mix ash.codegen v064_audit_tenant_codegen_followup
```

Read the generated migration carefully before applying. The dry-run preview shows mainly:

- `messages` indexes dropped and recreated to lead with `tenant_id` (real schema work — these are the index-leading-column commitments from §0.5.2 that the v064 migrations missed).
- A handful of `modify(:fk_col, references(...))` no-op restatements — AshPostgres always re-emits these when the snapshot hash rebuilds; they apply cleanly to an existing constraint.

If review surprises us with anything destructive on data-bearing columns, stop and reconcile by amending the v064 migrations rather than shipping the followup.

Apply via `mix ash.migrate` (matches the `ash.codegen` workflow we just used) and commit the migration + the generated snapshot updates as one unit. Don't pin a count — the diff is the source of truth.

### 2. `/workspace embedding|consolidation` tenant-scope (P1)

`lib/jido_claw/cli/commands.ex:1236-1261` — replace `Ash.get` with the tenant-scoped code-interface read, and forward `tenant:` to the update actions.

```elixir
uuid when is_binary(uuid) ->
  with {:ok, workspace} <-
         JidoClaw.Workspaces.Workspace.by_id(uuid, tenant: state.tenant_id),
       {:ok, _} <- apply_policy_action(workspace, kind, policy, state.tenant_id) do
    # … unchanged …
  end
```

Update `apply_policy_action/3` → `apply_policy_action/4`:

```elixir
defp apply_policy_action(workspace, :embedding, policy, tenant),
  do: JidoClaw.Workspaces.Workspace.set_embedding_policy(workspace, policy, tenant: tenant)

defp apply_policy_action(workspace, :consolidation, policy, tenant),
  do: JidoClaw.Workspaces.Workspace.set_consolidation_policy(workspace, policy, tenant: tenant)
```

`apply_embedding_transition/2` and the call to `PolicyTransitions.apply_embedding/3` are unchanged — that path is raw SQL keyed by `workspace_id`.

No automated test added — there is no CLI command-handler harness for `/workspace` (existing `test/jido_claw/cli/commands_*` files cover only `/profile` and `/servers`). Validate manually via the REPL post-fix:

```
/workspace embedding default
/workspace consolidation default
```

### 3. `jidoclaw.export.conversations --session-uuid` (P2)

`lib/mix/tasks/jidoclaw.export.conversations.ex:75-90` — when the caller passes a raw UUID we have no tenant context yet; use `by_id_global/1` to fetch (it sets `multitenancy(:bypass)` per `session.ex:169-174`), then thread `session.tenant_id` for the message read at line 128 (already correct).

```elixir
uuid when is_binary(uuid) ->
  case Session.by_id_global(uuid) do
    {:ok, session} ->
      output_path = output_path(opts, session)
      {:ok, session, output_path}

    _ ->
      Mix.shell().error("session UUID not found: #{uuid}")
      :error
  end
```

**Test:** add a case to `test/mix/tasks/jidoclaw_conversations_export_test.exs` (mirrors existing pattern: `Ecto.Adapters.SQL.Sandbox`, `reenable!`, fixture-based migrate → export round-trip). After running `migrate.conversations`, look up the session UUID via `Session.by_external/4` (or `by_external` on the workspace) and call `export.conversations` with `--session-uuid <uuid>` and no `--tenant`. Assert the JSONL is produced.

### 4. `jidoclaw.migrate.cron` ensures tenant FK parent (P2)

`lib/mix/tasks/jidoclaw.migrate.cron.ex` — call `Tenants.Tenant.ensure/1` once before the upsert loop, **only when there are real jobs to write and not in dry-run**, so `--tenant brand_new --dry-run` and "no jobs in YAML" do not create a tenant row as a side effect.

```elixir
defp migrate_jobs([], _tenant, _dry_run?), do: :ok  # already short-circuited upstream; defensive

defp migrate_jobs(jobs, tenant, dry_run?) do
  unless dry_run? do
    case JidoClaw.Tenants.Tenant.ensure(tenant) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Mix.shell().error("tenant ensure failed: #{inspect(err)}")
        exit({:shutdown, 1})
    end
  end

  # … existing reduce …
end
```

The empty-jobs case at `jidoclaw.migrate.cron.ex:38-39` already returns before calling `migrate_jobs/3`, so the guard above is satisfied without further branching. Keep the FQN inline; one call site doesn't justify an alias.

**Semantic note:** the guard above ensures the tenant row whenever the job list is non-empty and we're not dry-running, even if every entry turns out to be `:invalid` after `legacy_to_attrs/1` and no upsert lands. Creating an unused tenant row in that pathological case is harmless (audit/Cron rows that never arrive would never have orphaned anyway), and pre-validating just to gate `Tenant.ensure/1` adds branching for marginal benefit. Leaving the simpler guard intentional.

**Test:** new file `test/mix/tasks/jidoclaw_migrate_cron_test.exs` (no existing test). Mirror `jidoclaw_conversations_export_test.exs` setup (Sandbox + `reenable!`). Use **two distinct tenant strings** so neither test leaks state into the other:

- `tenant_a = "migrate-cron-test-#{unique}"` — drive task non-dry, with a one-job `cron.yaml` fixture; assert (a) `Tenants.Tenant.by_id(tenant_a)` succeeds afterward, (b) `Cron.Job` count is 1 under that tenant.
- `tenant_b = "migrate-cron-dry-#{unique}"` — drive task with `--dry-run` against the same fixture; assert `Tenants.Tenant.by_id(tenant_b)` returns `{:error, _}` and `Cron.Job` count under `tenant_b` is 0.

(Order-independent. If we re-used one tenant, whichever assertion ran second would be meaningless because the first run already populated the FK parent.)

### 5. Drop unused `Session` alias (P2)

`test/jido_claw/tools/mcp_scope_test.exs:19`:

```elixir
alias JidoClaw.Conversations.{Message, Resolver}
```

That clears `mix test --warnings-as-errors`.

## Out of scope (flagged for follow-up)

- `.formatter.exs` is not present in the repo and never has been per `git log -- .formatter.exs`. The reviewer noted this prevents `mix format --check-formatted` from running. Restoring/authoring a formatter config is not a Phase 4 review finding — file a separate ticket once this fix-up lands.

## Order of execution

1. #5 — alias drop (clears warnings-as-errors so subsequent test runs are clean).
2. #2 — REPL `/workspace` policy fix.
3. #3 — export task `--session-uuid` fix + new test case.
4. #4 — `migrate.cron` tenant ensure + new test file.
5. #1 last — `mix ash.codegen v064_audit_tenant_codegen_followup`, review, migrate, snapshot+migration commit.

## Verification

End-of-task gates (all must pass):

- `mix compile --warnings-as-errors`
- `mix test --warnings-as-errors`  *(was aborting on #5)*
- `mix ash_postgres.generate_migrations --check`  *(must exit 0; this is the original P1 gate)*
- New tests in `test/mix/tasks/jidoclaw_conversations_export_test.exs` (UUID branch) and `test/mix/tasks/jidoclaw_migrate_cron_test.exs` (new-tenant branch + dry-run no-side-effect) pass.
- Manual REPL smoke: `/workspace embedding default` and `/workspace consolidation default` succeed without `TenantRequired`.
- Manual: `mix jidoclaw.migrate.cron --tenant brand_new` against a YAML with one job creates `tenants.brand_new` and the cron row.

## Files touched

| Fix | File | Action |
|---|---|---|
| 1 | `priv/repo/migrations/<ts>_v064_audit_tenant_codegen_followup.exs` | new (codegen) |
| 1 | `priv/resource_snapshots/repo/**/*.json` | regenerated (count per diff) |
| 2 | `lib/jido_claw/cli/commands.ex` | edit lines 1236-1261 |
| 3 | `lib/mix/tasks/jidoclaw.export.conversations.ex` | edit lines 76-85 |
| 3 | `test/mix/tasks/jidoclaw_conversations_export_test.exs` | add test case |
| 4 | `lib/mix/tasks/jidoclaw.migrate.cron.ex` | edit `migrate_jobs/3` head |
| 4 | `test/mix/tasks/jidoclaw_migrate_cron_test.exs` | new file |
| 5 | `test/jido_claw/tools/mcp_scope_test.exs` | edit line 19 |
