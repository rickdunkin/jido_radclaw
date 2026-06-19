# Fix: narrow the Phase 2a composer recovery guard to `:running` only

## Context

The just-landed AR-2 Composer **Phase 2a** added a boot-recovery guard so `WorkflowRecovery`
wouldn't mis-classify a long-lived composer parent (which sits `:running` for the whole route with
no checkpoint) as `:stranded → :failed`. A code review flagged one **[P3]** issue, which I have
**validated as a real latent bug**:

`workflow_recovery.ex:123` —

```elixir
defp classify(%WorkflowRun{workflow_type: "composer"}), do: :composer   # FIRST classify head
```

— matches a composer run in **any** status, not just the intended `:running` parent. Because
`WorkflowRun.create/1` is public (`code_interface` `define(:create)`, `workflow_run.ex:85`) and
stamps `status: :pending` (`:118`), a `:pending` composer row is trivially creatable — the lineage
test does exactly this (`workflow_run_parent_lineage_test.exs:22,46,65`). `list_non_terminal_global`
scans `[:pending, :running, :awaiting_approval]` (`workflow_run.ex:176`), so a stranded `:pending`
composer **is** picked up at boot, and the broad guard observes it (`emit/2`, a no-op) **forever** —
directly contradicting the documented recovery contract (`workflow_recovery.ex:41-42`: "`:pending` +
no checkpoint → `run_recovered` + `run_failed`"). The reconciler exists precisely to guarantee every
non-terminal run reaches a terminal; a perpetually-`:pending` composer defeats that and would surface
in every future non-terminal scan and dashboard view.

The happy path (`create_parent_run/1`, `route_composer.ex:152-162`) commits create + `run_started` in
one transaction so it never *itself* leaves a `:pending` composer — but the contract must hold for
every way a row can reach `:pending`, and the public `create/1` makes that reachable.

**Intended outcome:** the guard protects only the one legitimate 2a state (a `:running` composer
parent); every other composer status falls through to the existing status-based branches, so a
never-started `:pending` composer is still failed. The fix must leave `mix precommit` green.

## Approach

The reviewer's suggested narrowing is correct and forward-compatible with 2d (which replaces this
interim no-op with a full rebuild+resume branch). Add `status: :running` to the guard pattern.

> **Deliberately not** adding `encrypted_resume_checkpoint: nil`: a `:running` composer carrying a
> checkpoint is not reachable in 2a (composers don't gate/checkpoint), and if one ever existed it
> should stay *observed*, not fall through to `:decision_recorded`'s `GateResume.resume/2`, which
> decodes a reactor checkpoint envelope a composer never wrote. Keeping the guard at `status:
> :running` keeps every `:running` composer in the safe observe branch.

### 1 — `lib/jido_claw/orchestration/workflow_recovery.ex`

- Narrow the guard head (`:123`):

  ```elixir
  defp classify(%WorkflowRun{workflow_type: "composer", status: :running}), do: :composer
  ```

- Update the inline comment above it (`:118-122`) to state the guard is scoped to the valid
  `:running` parent, and that `:pending`/`:awaiting_approval` composer rows fall through to the
  existing branches (so a never-started `:pending` composer is still correctly failed — the
  contract is preserved, not bypassed for the whole `workflow_type`).
- Add a one-line composer bullet to the moduledoc recovery-contract list (`:17-45`) so the
  documented contract stays complete: a `:running` composer parent is observed (2d does the real
  rebuild+resume); any other composer status follows the status-based branches above.

The `reconcile_branch(:composer, run)` branch (`:231-234`) is unchanged — it still observes the
`:running` parent.

### 2 — `test/jido_claw/orchestration/workflow_run_parent_lineage_test.exs`

Keep the existing positive test (`reconcile_all leaves a :running composer parent untouched`,
`:75-89`) — it still passes (a `:running` composer matches the narrowed guard → observed). Add a
negative test in the same `describe` block that locks the narrowed contract, mirroring the existing
test's structure, plus `alias JidoClaw.Orchestration.WorkflowEvent` (not yet aliased in this file):

```elixir
test "reconcile_all fails a never-started :pending composer parent" do
  tenant = seed_tenant("lineage-pending")
  actor = actor_for(tenant)

  # A composer row from the public create/1 (NOT create_parent_run) never gets
  # its run_started, so it sits :pending with no checkpoint — the narrowed guard
  # lets it fall through to the :stranded branch instead of observing it forever.
  {:ok, parent} =
    WorkflowRun.create(%{name: "stranded-composer", workflow_type: "composer"},
      tenant: tenant,
      actor: actor
    )

  assert parent.status == :pending
  assert :ok = WorkflowRecovery.reconcile_all()

  assert {:ok, reloaded} = WorkflowRun.by_id(parent.id, tenant: tenant, actor: actor)
  assert reloaded.status == :failed

  # Assert the recovery audit, not just the terminal status — this locks the
  # intended fall-through to fail_stranded/2 → WorkflowLog.append_recovery/2,
  # which writes the pair in seq order (`:for_run` sorts seq ascending). A
  # directly-created :pending run has no prior events, so these are the only two.
  assert {:ok, events} = WorkflowEvent.for_run(parent.id, tenant: tenant, actor: actor)
  assert Enum.map(events, & &1.kind) == [:run_recovered, :run_failed]
end
```

(The assertions check only this parent, so they are robust regardless of any other rows the
tenant-blind `reconcile_all/0` scan touches. `reconcile_all/0` is the directly-driven path the
existing test already uses — no `owns_recovery?` gate.)

### 3 — `docs/exploration/alp-river/AR-2-PHASE-2-DURABLE-ENVELOPE.md`

Keep the committed design doc in sync with the code. Update the snippet at `:223-226` (and a clause
in the prose at `:219-221`) to show the narrowed guard and note the fall-through:

```elixir
defp classify(%WorkflowRun{workflow_type: "composer", status: :running}), do: :composer  # only the valid 2a state
# reconcile_branch(:composer, run) -> emit(run, :composer)              # observe-only
# pending/awaiting composer rows fall through to the status heads (a never-started :pending composer is still failed)
```

(The historical executed plan `please-review-docs-exploration-alp-river-fuzzy-token.md:238` is left
as-is — it is the record of what was executed, not living architecture.)

## Why the fall-through is correct (per composer status, after narrowing)

| Composer status | classify → branch | Outcome | Correct? |
| --- | --- | --- | --- |
| `:running` (no checkpoint) | `:composer` | observed (no-op) | ✓ the valid 2a state |
| `:running` + checkpoint | `:composer` | observed | ✓ not reachable in 2a; observe is safe |
| `:pending` (no checkpoint) | `:stranded` | `run_recovered` + `run_failed` → `:failed` | ✓ matches contract |
| `:pending` + checkpoint | `:corrupt_pending` | fail-with-audit → `:failed` | ✓ matches contract |
| `:awaiting_approval` + checkpoint | `:parked` | **follows existing gate semantics** — parks/observes (no-op) if a pending `AgentCase` exists, else cancels; not necessarily terminal | ✓ not reachable in 2a |
| `:awaiting_approval` + no checkpoint | `:dangling_gate` | `run_recovered` + `run_failed` → `:failed` | ✓ not reachable in 2a |

## Verification

Run via `mise exec -- mix` (mise-latest toolchain). Run gates **bare in the background** and read the
output tail — never pipe (`| tail` masks the exit code).

1. `mise exec -- mix format` (changed files).
2. Targeted: `mise exec -- mix test test/jido_claw/orchestration/workflow_run_parent_lineage_test.exs`
   — the existing `:running`-observed test and the new `:pending`-failed test both pass.
3. Regression: `mise exec -- mix test test/jido_claw/route_composer/composer_loop_test.exs` — the
   convergence/terminalize runs are unaffected (this change touches only the `:pending`/`:awaiting`
   composer classification, which those tests don't exercise). Re-run **in isolation** (not just
   `--seed 0`) per the suite-flaky note, since it is `async: false` `TenantCase`.
4. **Done-criterion:** `mise exec -- mix precommit` — must be green (compile_check, format,
   reach `--strict`, credo `--strict`, dialyzer, full test). The change is a guard-pattern
   narrowing + a comment/doc touch + one test, so no new warnings, no new module (no reach/credo
   surface), no migration.

## Files

**Modified (lib):** `lib/jido_claw/orchestration/workflow_recovery.ex` (narrow guard + comment +
moduledoc bullet).
**Modified (test):** `test/jido_claw/orchestration/workflow_run_parent_lineage_test.exs` (new
`:pending`-composer-failed test).
**Modified (docs):** `docs/exploration/alp-river/AR-2-PHASE-2-DURABLE-ENVELOPE.md` (sync the guard
snippet).

**Commit plan** (slicing guidance only — **do not commit; leave everything unstaged**). When green,
fold into the existing 2a change set or commit as `fix: scope composer recovery guard to :running`.
