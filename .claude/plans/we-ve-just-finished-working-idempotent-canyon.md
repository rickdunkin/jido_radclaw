# v0.6 Phase 4 — Code Review Follow-up

## Context

Phase 4 of v0.6 promoted `tenant_id` to a real FK across resources and
added Ash read policies (`tenant_id == ^actor(:tenant_id)`) to
`Solution`, `Reputation`, and `Workspace`. Three call sites still
issue reads without an actor, and the new policies silently filter
those reads to zero rows. Symptoms:

1. **Shell solution lookup** always reports `:not_found` even when
   the solution exists.
2. **Trust recomputation** silently falls back to neutral reputation
   `0.5` instead of using the agent's actual score — even when the
   parent update was made with a valid actor, because the change
   ignores context and re-issues the `Reputation.get` without one.
3. **System-import paths** (the Phase 4 legacy migration tasks)
   leave migrated rows at `embedding_status: :pending` even when
   the workspace's `embedding_policy` is `:disabled` — so the
   embedding backfill worker will pick them up and run work that
   the workspace explicitly opted out of.

The reviewer's verification (`mix test --max-failures 10`,
`mix compile --warnings-as-errors`) passed cleanly — these are
correctness/security gaps, not compile-time failures. All three
fixes are confined to small, well-scoped changes inside Solution,
Memory, and Shell code paths. Each gets a regression test that
locks in the policy contract.

All three findings verified against the current tree (no drift
between review and HEAD).

## Approach

All three are missing-actor bugs introduced by the Phase 4 read
policies. The fix in every case is to pass an actor the read policy
accepts — either the actor already present in context, or a
tenant-bound system actor via
`JidoClaw.Authorization.Actor.system(tenant_id)`. The system actor
returns `%{kind: :system, user_id: nil, tenant_id: tenant_id}`
which satisfies `tenant_id == ^actor(:tenant_id)` without granting
cross-tenant access.

### Fix 1 — Shell solution lookup (`lib/jido_claw/shell/commands/jido.ex:114`)

Pass `actor: JidoClaw.Authorization.Actor.system(tenant_id)` to
`Solution.by_signature/5` alongside the existing `tenant:` opt. The
shell command already resolves the tenant via `default_scope/0`, so
constructing the system actor is a one-line addition.

```elixir
JidoClaw.Solutions.Solution.by_signature(
  fingerprint,
  workspace_uuid,
  [:local, :shared, :public],
  [:public],
  tenant: tenant_id,
  actor: JidoClaw.Authorization.Actor.system(tenant_id)
)
```

### Fix 2 — Trust recomputation (`lib/jido_claw/solutions/resources/solution.ex:647-677`)

`Changes.RecomputeTrustScore` currently ignores the change context
(`_context` is underscored at line 652). Capture the actor from
context, fall back to `Actor.system(record.tenant_id)` when context
didn't carry one, and thread it into the `Reputation.get/2` call.

```elixir
def change(changeset, _opts, context) do
  context_actor = Map.get(context, :actor)

  Ash.Changeset.before_action(changeset, fn cs ->
    record = cs.data
    ...
    actor =
      context_actor ||
        (record.tenant_id && JidoClaw.Authorization.Actor.system(record.tenant_id))

    agent_rep_score =
      case JidoClaw.Solutions.Reputation.get(record.agent_id || "unknown",
             tenant: record.tenant_id,
             actor: actor
           ) do
        ...
      end
    ...
  end)
end
```

### Fix 3 — Embedding-policy resolution under system imports

Both `Changes.ResolveEmbeddingStatusFromPolicy` in
`lib/jido_claw/memory/resources/fact.ex:660-705` and
`lib/jido_claw/solutions/resources/solution.ex:561-611` have the
same shape. Add a system-actor fallback inside
`resolve_status_from_policy`: when `actor` is nil but `tenant_id`
is known, derive `JidoClaw.Authorization.Actor.system(tenant_id)`
for the nested workspace lookup call. This is defensive — any
future system import path that uses `authorize?: false` is
automatically covered.

**Style note (matches existing aliases):**

- `solution.ex` already does `alias JidoClaw.Workspaces.Workspace,
  as: WorkspaceResource` (line 64) and calls `WorkspaceResource.by_id/2`.
  Patch keeps that name.
- `fact.ex` calls `JidoClaw.Workspaces.Workspace.by_id/2`
  fully-qualified (no alias). Patch keeps that style.
- Neither file aliases `JidoClaw.Authorization`. Use the
  fully-qualified `JidoClaw.Authorization.Actor.system(tenant_id)`
  in both, consistent with how `Authorization.Checks.ActorTenantMatches`
  is referenced fully-qualified in the existing policy blocks
  (`solution.ex:55`, `fact.ex:84`).

Pseudocode shape (substitute the right `Workspace` name per file):

```elixir
defp resolve_status_from_policy(cs, workspace_id, actor) do
  tenant_id = cs.tenant || Ash.Changeset.get_attribute(cs, :tenant_id)

  effective_actor =
    actor ||
      (tenant_id && JidoClaw.Authorization.Actor.system(tenant_id))

  result =
    if tenant_id do
      opts = [tenant: tenant_id]
      opts = if effective_actor, do: Keyword.put(opts, :actor, effective_actor), else: opts
      WorkspaceResource.by_id(workspace_id, opts)   # or fully-qualified in fact.ex
    else
      WorkspaceResource.by_id_global(workspace_id)  # or fully-qualified in fact.ex
    end
  ...
end
```

The migration tasks (`lib/mix/tasks/jidoclaw.migrate.memory.ex:185`
and `lib/mix/tasks/jidoclaw.migrate.solutions.ex:98-100`) keep
their existing `authorize?: false` semantics — the change supplies
its own actor for the nested read.

## Files to modify

- `lib/jido_claw/shell/commands/jido.ex` — fix 1, single call site
  at line 114.
- `lib/jido_claw/solutions/resources/solution.ex` — fix 2
  (`Changes.RecomputeTrustScore`, ~line 652) and fix 3
  (`Changes.ResolveEmbeddingStatusFromPolicy`, ~line 587).
- `lib/jido_claw/memory/resources/fact.ex` — fix 3
  (`Changes.ResolveEmbeddingStatusFromPolicy`, ~line 663).

## Reused helpers (no new code)

- `JidoClaw.Authorization.Actor.system/1` at
  `lib/jido_claw/authorization/actor.ex:31-33` — returns the
  tenant-bound system actor.
- `JidoClaw.Workspaces.Workspace.by_id_global/1` already exists for
  the `tenant_id == nil` branch — no change needed there.
- `JidoClaw.Solutions.Reputation.get/2` and
  `JidoClaw.Solutions.Solution.by_signature/5` both already accept
  `:actor` through Ash's generated opts — no resource-side changes
  needed.

## Tests

One focused regression test per fix, each pinning the policy
contract that broke. Test layout follows the existing tree
(`test/jido_claw/<subsystem>/...` without a `resources/` segment).

1. **Shell solution lookup** — new file
   `test/jido_claw/shell/commands/jido_test.exs`. Mark the test
   module `async: false` (it mutates global `:jido_claw` app env
   via `Application.put_env/3`). Drive the public command via
   `JidoClaw.Shell.Commands.Jido.run(nil, %{args: ["solutions",
   "find", fingerprint]}, emit)`.

   - **Capture the emit shape exactly.** `emit_line/2` invokes
     `emit.({:output, line <> "\n"})` (`jido.ex:226`). Capture by
     sending `{:output, _}` tuples to the test process from a
     closure: `emit = fn msg -> send(test_pid, msg) end`. Then
     collect via `assert_receive {:output, line}` (with a timeout)
     or `flush_output/0` helper that drains the mailbox.
   - Seed a `Workspace` + matching `Solution` under tenant
     `"default"` with a known signature. **Use the same
     `(tenant_id, workspace_id)` pair** for both the seeded row
     and the `default_scope/0` override below.
   - Snapshot the prior value (e.g. `prior =
     Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)`),
     set the test value via `Application.put_env/3`, and restore
     it in `on_exit` — call `Application.put_env(:jido_claw,
     :jido_claw_mcp_default_scope, prior)` if `prior` was set,
     otherwise `Application.delete_env/2`.
   - Assert one of the captured `{:output, line}` tuples contains
     the solution presenter signature (whatever
     `Presenters.solution_lines/1` renders for an `{:ok, sol}`),
     and that no captured tuple matches the not-found line.

   Without fix 1, this test fails because `by_signature` returns
   zero rows and the presenter renders the not-found path.

2. **Trust recompute uses real reputation** — new file
   `test/jido_claw/solutions/solution_test.exs` (or add to an
   existing sibling such as `trust_test.exs` if it's a better
   fit). Setup:
   - Seed `Reputation` for `(tenant_id, agent_id)` with a
     non-neutral score (e.g. `0.9`). Snapshot the value before
     the update — the action runs a `RecordReputationOutcome`
     after-transaction change that mutates the reputation row
     based on the verification status, so any expected-score
     computation must use the **pre-update** reputation.
   - Seed a `Solution` under the same `(tenant_id, agent_id)`
     with a known verification baseline.
   - Compute the expected score:
     `expected = JidoClaw.Solutions.Trust.compute(
       %{solution | verification: new_verification},
       agent_reputation: 0.9   # pre-update value
     )`.
   - Call
     `JidoClaw.Solutions.Solution.update_verification_and_trust(
       solution,
       %{verification: new_verification},
       tenant: tenant_id,
       actor: JidoClaw.Authorization.Actor.system(tenant_id)
     )`.
   - Assert the returned `trust_score == expected`. Floating-point
     equality should be safe here because both calls run
     `Trust.compute/2` deterministically on the same inputs — but
     use `assert_in_delta` with a small epsilon if the test
     proves flaky.

   Without fix 2, the change re-issues `Reputation.get` without
   threading the context actor, so the read sees zero rows, the
   change uses the `0.5` neutral fallback, and the assertion
   fails. This test runs through the real policy stack with a
   valid actor — the bug is in the change discarding it.

3. **System-import embedding status under disabled workspace** —
   two tests:
   - Add to existing `test/jido_claw/memory/fact_test.exs`:
     seed a `Workspace` under tenant `T` with `embedding_policy:
     :disabled`, capture its `id`, call `Fact.import_legacy(attrs,
     tenant: T, authorize?: false)` where `attrs` carries
     `workspace_id: <that exact id>` and **does not** include
     `embedding_status` (so the resolution path runs). Assert the
     inserted row has `embedding_status: :disabled`.
   - Add to `test/jido_claw/solutions/solution_test.exs`
     (created above): same setup against
     `Solution.import_legacy(attrs, tenant: T, authorize?: false)`,
     same `(tenant_id, workspace_id)` pairing, same omission of
     `embedding_status`, same assertion.

   Two preconditions both tests must satisfy:
   - Omitting `embedding_status` is essential — the existing
     change short-circuits when status is already set
     (`solution.ex:574`/`fact.ex:667`), so a test that supplies
     it would pass even without the fix.
   - Workspace and record must share the **exact same tenant +
     workspace_id pair** the change reads. If the seeded
     `Workspace.id` doesn't match the `workspace_id` on `attrs`,
     the nested lookup misses for a different reason and the
     test passes for the wrong reason.

   Without fix 3, both tests land at `:pending` (the attribute
   default at `fact.ex:420`/`solution.ex:371`) because the nested
   `Workspace.by_id` read returns nothing under the system
   import's missing-actor context.

## Verification

End-to-end check sequence:

```bash
mix compile --warnings-as-errors
mix format lib/jido_claw/shell/commands/jido.ex \
           lib/jido_claw/solutions/resources/solution.ex \
           lib/jido_claw/memory/resources/fact.ex \
           test/jido_claw/shell/commands/jido_test.exs \
           test/jido_claw/solutions/solution_test.exs \
           test/jido_claw/memory/fact_test.exs
mix test test/jido_claw/shell/commands/jido_test.exs \
         test/jido_claw/solutions/solution_test.exs \
         test/jido_claw/memory/fact_test.exs
mix test                              # full suite to catch regressions
```

`mix format --check-formatted` is intentionally omitted — this
repo's `.formatter.exs` has no `inputs` configured, so the bare
check fails immediately on unrelated grounds (reviewer flagged
this).

**Static guard against the same pattern recurring.** After the
patch, run:

```bash
rg -n "by_signature\(|Reputation\.get\(|Workspace\.by_id\(" lib/jido_claw
```

This is a **review step, not scope creep.** Inspect every hit;
fix only clearly related instances (same shape: tenant-scoped
call with no `actor:` and no `authorize?: false`). Broader
cleanup — auditing every Phase 4 policy-protected resource for
missing actors — is a separate pass and intentionally out of
scope here.

Manual REPL sanity check for fix 1 (after seeding a solution under
`"default"` tenant): `mix jidoclaw` → `/jido solutions find
<fingerprint>` should now return the solution row instead of "not
found."

## Out of scope

- Auditing every other call site that passes `tenant:` without
  `actor:` beyond the three the reviewer flagged. The ripgrep
  check above is the cheap version; a full audit is its own task
  if hits surface unrelated regressions.
- Updating the migration tasks themselves
  (`jidoclaw.migrate.memory.ex`, `jidoclaw.migrate.solutions.ex`)
  to use proper actors instead of `authorize?: false`. The Change-
  level fallback in fix 3 makes that strictly optional, and
  changing the migration tasks risks behavior drift on a path that
  the reviewer didn't flag.
- Adding/fixing `.formatter.exs` so `mix format --check-formatted`
  works. Separate cleanup, not a code-review follow-up.
