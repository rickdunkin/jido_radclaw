# Review fix — cron outcome contract vs `/cron add` upsert (item-9 P2 finding)

## Context

The code review of the uncommitted item-9 work (structured premises,
`please-review-docs-plans-unadopted-next-quizzical-creek.md`) raised one P2:
reusing a job id via operator `/cron add` after an agent-created job allegedly
**preserves** the stored `metadata["outcome_spec"]` (the CLI upsert at
`lib/jido_claw/cli/commands.ex:1683-1691` omits `metadata`), so the scheduler
(`lib/jido_claw/platform/cron/scheduler.ex:82`) would keep hydrating a stale
contract and the dispatcher would append stale success criteria at fire time —
contradicting the documented CLI exemption ("operator CLI jobs simply carry no
contract", `docs/system/structured-premises.md:113-117`).

**Done criterion (user-set): `mise exec -- mix precommit` passes.**

## Validation verdict: intent RIGHT, mechanics ALMOST CERTAINLY WRONG — fix by making the exemption explicit + pinned

Checked every premise of the finding:

- ✔ `schedule_task.ex:151` writes `metadata: %{"outcome_spec" => …}`;
  `scheduler.ex:82,92` hydrates it for every row; `/cron add`
  (`commands.ex:1683-1689`) omits `metadata`; identity is
  `(tenant_id, job_id)` so id collision between the two writers is real.
- ✘ The preservation claim rests on a **misreading of the `job.ex:87-91`
  comment** ("Omitted fields are preserved on conflict" means omitted *from
  the `upsert_fields` whitelist*, not from the changeset). Pinned dep source
  (ash 3.29.2 / ash_postgres 2.10.0) says the conflict SET-list is
  `upsert_fields ∩ attributes actually set on the changeset`
  (`deps/ash_postgres/lib/data_layer.ex:2717-2726`, shared by both the
  ON CONFLICT and PG17 MERGE paths), and **static attribute defaults ARE set
  on the changeset** (`deps/ash/lib/ash/changeset/changeset.ex:4079-4094`
  `force_change_attribute`). `metadata` has `default(%{})` + is whitelisted
  (`job.ex:86,279-283`) ⇒ a CLI re-add most likely **clobbers metadata to
  `%{}`** — i.e. the stale contract is already dropped, the exemption holds.
- However: **nothing pins that** (no test covers metadata-on-conflict; the
  `job_test.exs` helper always passes `metadata: %{}` explicitly), and the
  guarantee currently rides a three-way Ash subtlety (whitelist ∩
  default-application ∩ EXCLUDED semantics) that a dep bump could flip
  silently — plus a misleading comment that already misled one reviewer.

**Resolution** (identical code either way, so no plan fork): make the CLI
upsert pass `metadata: %{}` explicitly — the intent-revealing,
semantics-independent form, matching the existing precedent in
`lib/mix/tasks/jidoclaw.migrate.cron.ex:138` — and pin the operator-level
contract with tests. Step 1 below records the actual pre-fix behavior so the
finding's validity is settled empirically, not just from source reading.

Adjacent surfaces traced and benign: `metadata`'s only reader is scheduler
hydration, `"outcome_spec"` is its only key anywhere, and defaulted attrs
(`target`, `timezone`, `workflow_input`) already reset on CLI re-add by the
same mechanism, so no franken-row concern. Other Job writers: `schedule_task`
(writes the contract), migrate task (explicit `%{}`), system jobs (config-run,
never persisted — `scheduler.ex:374-402`). No other non-contract writer needs
touching.

## Changes

1. **Regression tests first** (they double as the empirical validation):
   - `test/jido_claw/cli/commands_cron_test.exs` — new test in the
     "/cron add validate-before-schedule" describe, following the
     `:84-117` pattern + the direct-`CronJob.upsert` seeding precedent at
     `:127-152`: seed a row under tenant `"default"` with
     `metadata: %{"outcome_spec" => <wire map>}` (shape precedent:
     `@spec_wire` in `test/jido_claw/cron/scheduler_idempotency_test.exs:133-138`),
     run `Commands.handle(~s|/cron add <same id> "<cron ~2 days out>" new task|)`,
     re-read the row and assert the contract-specific invariant:
     `refute Map.has_key?(row.metadata || %{}, "outcome_spec")` (and reuse
     the `:87-94` on_exit cleanup). Deliberately NOT exact
     `metadata == %{}` — the pin is **"CLI jobs carry no outcome
     contract"**, not "CLI clears all metadata"; a future CLI feature
     writing an unrelated metadata key must not break it.
   - `test/jido_claw/cron/job_test.exs` — new test in describe ":upsert"
     using the existing `upsert_attrs/1` helper (`:21-33`, already takes
     `metadata:`): upsert with `metadata: %{"outcome_spec" => …}`, re-upsert
     the same job_id with explicit `metadata: %{}`, assert cleared. Framed
     (name + comment) as "an explicit metadata clear replaces the stored
     value on conflict" — the mechanism the CLI fix relies on — NOT as
     evidence about omitted-metadata semantics.
   - Deliberately NOT pinning the *omitted*-metadata-on-conflict semantics:
     once the CLI is explicit it's not load-bearing, and such a pin would
     break spuriously on Ash bumps.

2. **Run the two new tests BEFORE the code change** (`mise exec -- mix test
   <both files>`) and record the outcome: CLI test green ⇒ finding's
   mechanics invalid (fix = hardening + pin); red ⇒ finding valid (fix =
   real). Either way proceed identically; record the verdict in step 5's
   done-note entry.

3. **The fix** — `lib/jido_claw/cli/commands.ex` `persist_cron_job/4`
   (`:1680-1689`): add `metadata: %{}` to `persist_attrs` with a short
   comment: operator CLI jobs carry no outcome contract (the documented
   item-9 exemption) — explicit so a re-add over an agent-created job id
   deterministically drops the stored contract instead of riding upsert
   default-application subtleties (same posture as the migrate task).

4. **Correct the misleading comment** — `lib/jido_claw/cron/resources/job.ex:87-91`:
   reword to state actual semantics: the conflict SET-list is
   `upsert_fields ∩ attributes set on the changeset` (static defaults count);
   a whitelisted-but-never-set field is preserved — why `disabled_at` needs
   both the whitelist entry AND `set_attribute`, and why contract-less
   writers must pass `metadata` explicitly to clear it.

5. **Docs (same change, house rule)**:
   - `docs/system/structured-premises.md` — in "The cron outcome contract"
     (`:192-205`): one sentence — `/cron add` sets `metadata: %{}` explicitly
     on its upsert, so re-adding an agent-created job id deterministically
     clears the stored contract (`verified:` already 2026-07-08; keep).
   - `docs/plans/unadopted-next-ten/README.md` item-9 done-note
     (`:884-922`): append correction **(h)** — the review P2, the dep-source
     verdict from step 2, and the explicit-clear + pins resolution.
   - Record any further deviations in that same (h) entry as they happen.

No SurfaceVersion bump (tool surface untouched), no `.jido/JIDO.md` regen (no
tool description change — `commands.ex` isn't a tool), no `system_prompt.md`
sync, no migration (metadata already accepted).

## Verification

1. Targeted: `mise exec -- mix test test/jido_claw/cli/commands_cron_test.exs
   test/jido_claw/cron/job_test.exs test/jido_claw/cron/scheduler_idempotency_test.exs
   test/jido_claw/tools/schedule_task_test.exs` (Postgres required; TenantCase
   suites are async:false).
2. `mise exec -- mix precommit` — **bare, in background, read the output
   tail** (never `| tail`; repo memory: pipes mask the gate's exit code).
   The plan is done only when it exits 0.
3. Hazards (repo memory): credo-strict (new code is a map entry + tests — no
   new public fns, so no `@spec` exposure); ExSlop EXS3004 (no wrapped
   comment line starting with "step"); flaky async:false suites (MCPServer,
   Prompt, PipelineStore, MultiSandbox) — verify any failure in ISOLATION
   before blaming this change; run `mise exec -- mix format` before the gate.

## Commit-readiness (no commits — user stages)

Folds into the pending **item-9 commit 2** (cron consumer thread). Its staged
list gains: `lib/jido_claw/cli/commands.ex`,
`test/jido_claw/cli/commands_cron_test.exs`, `lib/jido_claw/cron/resources/job.ex`,
`test/jido_claw/cron/job_test.exs` (+ the two doc files already in the lists).
Suggested message unchanged from the original plan, or append
`; /cron add explicitly clears the contract (review P2)`.
