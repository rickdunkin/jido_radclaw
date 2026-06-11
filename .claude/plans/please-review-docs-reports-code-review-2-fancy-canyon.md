# Resolve code-review findings M11 + M12

## Context

`docs/reports/code-review-2026-06-10.md` has all 16 HIGHs and M1–M8 fixed. The report's priority list (item 6) names the remaining explicitly-tiered items: **M11** (cron one-shot `:at` jobs re-fire in a tight infinite loop after firing, and elapsed one-shots re-fire on every boot) and **M12** (the v0.5.x solutions migrator's reputation phase double-counts on interrupted re-run). Both confirmed unfixed at HEAD `c54ff86`.

User decisions: **M11 = defuse, keep `:at`** (disable-on-fire + skip-and-disable elapsed one-shots); **M12 = delete the whole migrator** (greenfield — no v0.5.x data exists; precedent: H14/H16 were fixed by removal). Done means `mix precommit` passes.

---

## Task A — M11: defuse the cron `:at` one-shot footgun

The bug: `lib/jido_claw/platform/cron/worker.ex:244-248` clamps a past `{:at, dt}` to delay 0 and re-arms unconditionally; the tick handler (line 153) equality-matches the same `dt` and re-fires forever. Nothing produces `:at` today (only `Scheduler.hydrate_schedule(:at, iso)` at `scheduler.ex:152-157` can hydrate it from a DB row), so this is a footgun defuse with permanent tests.

**Design: single locus in the worker** (covers both the DB-reload path and direct `Scheduler.schedule/2` calls; the reload path then starts a worker that immediately self-disables — same harmless idle-zombie semantics as the existing `:cron` config-error arm at `worker.ex:270-280`, and `Job.for_tenant`'s `is_nil(disabled_at)` filter excludes the row on the next reload). No Scheduler changes.

### Changes to `lib/jido_claw/platform/cron/worker.ex`

**1. Disable-on-fire** — in the matching-tick clause (lines 152-156), replace `{:noreply, schedule_next(state)}` with `{:noreply, after_fire(state)}` and add:

```elixir
# Already disabled by execute_job (3-failure auto-disable): don't re-arm,
# and clear the consumed window — execute_job sets status without touching
# next_run, and a dangling next_run would advertise a tick that never comes.
defp after_fire(%{status: :disabled} = state), do: %{state | next_run: nil}

# A one-shot :at fires exactly once, then disables (in-memory + persisted)
# and never re-arms. Recurring :cron/:every re-arm as before.
defp after_fire(%{schedule: {:at, _dt}} = state) do
  Logger.info("[Cron] One-shot :at job #{state.id} fired; disabling")
  persist_disabled(state)
  %{state | status: :disabled, next_run: nil}
end

defp after_fire(state), do: schedule_next(state)
```

The first clause also stops arming a pointless (always-swallowed) timer when a recurring job auto-disables mid-tick — strict improvement, no contract change.

**Disable contract (explicit):** once disabled, *scheduled* ticks stop permanently — no re-arm, and no worker-level `:enable` exists. But `handle_cast(:trigger, state)` (line 132) ignores `status` by design: manual `trigger/2` remains an **operator override** that still executes a disabled worker (the provenance test docstring pins "operator intent always runs"). Leave the trigger path untouched; the `after_fire` comments should not claim the disable is absolute.

**2. Skip-and-disable elapsed one-shots at arm time** — replace the `:at` clause of `schedule_next` (lines 244-248):

```elixir
defp schedule_next(%{schedule: {:at, %DateTime{} = dt}} = state) do
  now = DateTime.utc_now()

  case DateTime.compare(dt, now) do
    :lt ->
      # Elapsed one-shot at init/reload: must NOT fire at boot. Persist
      # disabled_at so for_tenant excludes the row on the next reload.
      Logger.info("[Cron] Skipping elapsed one-shot :at job #{state.id}; disabling")
      persist_disabled(state)
      %{state | status: :disabled, next_run: nil}

    _ ->
      delay = max(DateTime.diff(dt, now, :millisecond), 0)
      Process.send_after(self(), {:tick, dt}, delay)
      %{state | next_run: dt}
  end
end
```

`now` is bound once so the compare and the diff see the same instant — a `dt == now` boundary either disables (`:lt` next tick) or arms at delay 0 and fires exactly once; disable-on-fire makes both sides safe. `persist_disabled/1` (lines 288-304) is already rescued/best-effort, so the DB call inside `init` is safe. Do **not** touch the `:every`/`:cron` clauses, the swallow clause (163-165), or `execute_job`.

### Tests (required — footgun defuses get permanent committed tests)

**`test/jido_claw/cron/worker_fire_provenance_test.exs`** — new describe block reusing the existing `CapturingRunner` / `:cron_workflow_runner` app-env seam and `send(pid, {:tick, window})` idiom:
- *Fire-once*: schedule a worker with `schedule: {:at, future_dt}` (`target: :workflow`, `workflow_name: "explore_codebase"` — keep the fixture shape production-realistic; `future_dt` comfortably future — e.g. now + 1 day — so the natural timer can never fire on slow CI); `get_state` shows `status: :active, next_run == dt`; `send(pid, {:tick, dt})` → `assert_receive {:runner_ran, %{fire: {:scheduled, ^dt}}}`; `get_state` now shows `status: :disabled, next_run: nil`; second `send(pid, {:tick, dt})` → `refute_receive {:runner_ran, _}`. Schedule this worker inside the test body with its own `on_exit` unschedule (the setup-block `@far_future` worker stays untouched and keeps guarding the `:every` re-arm path through `after_fire`).

**`test/jido_claw/cron/persistent_disable_test.exs`** — new describe block; copy the CapturingRunner seam setup from the provenance test (needed to refute boot-time fires); reuse the existing `Job.upsert` + `Scheduler.load_persistent_jobs` + `wait_until_disabled/3` machinery:
- *Elapsed reload skip*: upsert a Job row with `schedule_kind: :at`, `schedule_value:` past ISO8601, `target: :workflow`, **`workflow_name: "explore_codebase"`** (required — `Job.upsert` validates workflow rows carry a name at `job.ex:108`, and reload skips malformed workflow rows at `scheduler.ex:64`) → `load_persistent_jobs` returns count 1 (worker starts, then self-disables — pin the nuance), with an `on_exit` `Scheduler.unschedule/2` for the idle disabled worker it leaves behind → `refute_receive {:runner_ran, _}` (never executed) → `wait_until_disabled` shows `disabled_at` set → second `load_persistent_jobs` returns 0.
- *Future reload arms normally*: upsert (same `target: :workflow` + `workflow_name` shape) with a **comfortably future** `dt` (e.g. now + 1 day, so slow CI can never cross the firing boundary) **truncated to `:second`** (ISO8601 round-trip loses microseconds) → `load_persistent_jobs` returns 1 (plus `on_exit` unschedule) → `get_state` shows `status: :active, next_run == dt` → `refute_receive`.

---

## Task B — M12: delete the legacy v0.5.x solutions migrator

**Load-bearing entanglement found:** `test/mix/tasks/jidoclaw_solutions_export_test.exs` seeds Postgres by *running the migrator* (lines 24-25, 33-34, 58-59). Redaction actually lives in the `:import_legacy` action (`RedactSolutionContent`), not the migrator — so the test is rewritten to seed via `Solution.import_legacy` directly, preserving its redaction round-trip coverage (same philosophy as the H8 fix: the action is the real seam).

### Steps (order matters for codegen)

1. **Delete** `lib/mix/tasks/jidoclaw.migrate.solutions.ex` (whole task; its `reach:disable-for-this-file bare_rescue` pragma dies with it — no `.reach.exs` entry exists).
2. **`lib/jido_claw/solutions/domain.ex`**: remove `resource(JidoClaw.Solutions.ReputationImport)` (line 23) and the moduledoc bullet (lines 12-13).
3. **Delete** `lib/jido_claw/solutions/resources/reputation_import.ex` (exists solely as the migrator's idempotency ledger; no other lib/ caller).
4. **Generate the drop migration**: `mix ash.codegen drop_reputation_imports` → new `priv/repo/migrations/<ts>_drop_reputation_imports.exs` (mirror of `20260610224818_drop_folio_tables.exs`) and removal of `priv/resource_snapshots/repo/reputation_imports/`. **Inspect the generated file** — it must contain only the `reputation_imports` drop; any bundled unrelated diff means drift, stop and investigate.
5. **Rewrite `test/mix/tasks/jidoclaw_solutions_export_test.exs`**: add a private `seed_solutions_from_fixture(project_dir)` helper — `Resolver.ensure_workspace("default", project_dir)`, read + `Jason.decode!` the fixture's `.jido/solutions.json`, then build the `import_legacy` action attrs **directly** per entry (id, problem_signature, solution_content, language, framework, runtime, agent_id, tags, verification, trust_score, `workspace_id: ws.id`, parsed timestamps — only the minimal coercion the fixtures need; `sharing` via a whitelist `coerce_sharing/1` with explicit `"local" -> :local` / `"shared" -> :shared` / `"public" -> :public` clauses, never `String.to_atom/1`). Do **not** port migrator-only plumbing: no `row_exists?/2` probe (fixtures are test-controlled), no tenant-in-attrs + `Map.delete` dance — pass `tenant: ws.tenant_id` only in the call opts. Use `Solution.import_legacy!(attrs, tenant: ..., actor: Actor.system(ws.tenant_id))` so a bad seed fails the test setup loudly.
   - Test 1 (byte-determinism): seed once, export twice, compare bytes (the migrate-twice idempotency semantic dies with the migrator).
   - Test 2 (redaction manifest): seed once, export with manifest, keep every assertion; update the "proves the migrate-time redaction fired" comment to say action-time (`:import_legacy`) redaction. Rename the describe (line 16). Both fixtures contain only `solutions.json` — no reputation handling needed.
6. **Comment/name re-justifications** (light touch — swap "migrator" rationale for "test-fixture plumbing"):
   - `lib/jido_claw/solutions/resources/solution.ex`: the `:store` accept comment ("Only `:import_legacy` may carry them (v0.5.x migration)") and the `AcceptLegacyTimestamps` moduledoc.
   - `test/jido_claw/solutions/solution_test.exs:68`: test name "(intentional contrast for the migrator)" → fixture rationale.
   - `test/support/jido_claw/solutions_case.ex`: check its `import_legacy` reroute comments for migrator mentions.
   - `lib/jido_claw/orchestration/workflow_event.ex:11`: cites `ReputationImport` as an example resource — swap the example or drop the parenthetical.
   - `test/jido_claw/policy_authz_test.exs:13`: moduledoc "(skip Audit.Event, ReputationImport)" → drop the `ReputationImport` mention.
7. **Delete `.jido/SOLUTIONS_DEPRECATION.md`** (git-tracked; its entire purpose is instructing v0.5.x users to run the now-deleted migrator; greenfield = no such users; the export task documents itself).
8. **Exploration-doc updates** (maintained status docs, not historical — surfaced by the repo-wide sweep):
   - `docs/exploration/hermes/FEATURES-WORTH-BORROWING.md:994` — drop `ReputationImport` from the current-state resource inventory list (`Solution/Reputation/ReputationImport` → `Solution/Reputation`).
   - `docs/exploration/squidie/FEATURES-WORTH-BORROWING.md:133` — the "(the `ReputationImport` precedent; …)" parenthetical: annotate "since removed" or swap to the same surviving example chosen for `workflow_event.ex:11` — keep the two edits consistent.

### Keep / do NOT touch (full classified reference list from `rg "ReputationImport|jidoclaw\.migrate\.solutions|reputation_imports|migrate\.solutions"`)
- `JidoClaw.Solutions.Reputation` (live counters used by `network/node.ex` and `solution.ex`) and `Solution.:import_legacy` + its changes (test fixtures route trust/verification overrides through it).
- The conversations/memory/cron migrators and the solutions **export** task + fixtures.
- Historical migrations referencing `reputation_imports` (`v061_solutions`, `v064_audit_tenant`, `v064b_tenant_fk_staged`) and `test/jido_claw/repo/v064b_migration_shape_test.exs:25` — they pin already-applied history; the new drop migration runs after them.
- Historical records — leave frozen: `docs/plans/v0.6/phase-1-solutions.md`, `docs/PLAN-v0.6-memory.md`, `docs/reports/credo-baseline-2026-05-12.md`, `docs/exploration/squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md` (plan-of-record for a shipped phase; its blockquote cites the precedent as it existed at decision time).
- `.claude/plans/*.md` — past session plan scratch files, never edited.

---

## Report update — `docs/reports/code-review-2026-06-10.md`

Follow the established per-finding convention:
- **M11 bullet (line 237)**: append `✅ fixed 2026-06-11` + note: disable-on-fire (tick handler branches by schedule kind via `after_fire/1`; `:cron`/`:every` unchanged) + skip-and-disable strictly-past `:at` at arm time in `schedule_next` (single locus in the worker, covers direct `Scheduler.schedule/2` too); manual `trigger/2` deliberately remains an operator override that executes regardless of disabled status; regression tests in `worker_fire_provenance_test.exs` + `persistent_disable_test.exs`.
- **M12 bullet (line 238)**: append `✅ fixed 2026-06-11 (by removal)` + note: migrator + `ReputationImport` ledger deleted (drop migration via ash.codegen, mirroring H16's `drop_folio_tables`); `Reputation` and `:import_legacy` kept (re-justified by fixture plumbing); export test reseeds via `Solution.import_legacy` preserving the redaction round-trip.
- **Priority-order item 6 (line 298)**: mark M11 + M12 done — the tier is now clear.

---

## Verification

1. `mix test test/jido_claw/cron/` — new M11 tests green; existing provenance tests (duplicate-tick, stale-window) prove `:cron`/`:every` re-arm unregressed.
2. `mix test test/mix/tasks/jidoclaw_solutions_export_test.exs test/jido_claw/solutions/ test/jido_claw/policy_authz_test.exs test/jido_claw/repo/v064b_migration_shape_test.exs` — rewritten seeding + kept `import_legacy` contract + untouched history pins.
3. Post-removal sweep: re-run `rg "ReputationImport|jidoclaw\.migrate\.solutions|reputation_imports|migrate\.solutions" --hidden -g '!.git' -g '!_build' -g '!deps'` — every surviving hit must be on the classified keep-list above (historical migrations + shape test, frozen docs, `.claude/plans/`, and the review report's own finding text).
4. **`mix precommit`** (the completion gate, `:test` env): `jidoclaw.compile_check`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format --check-formatted`, `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`, `test` (its alias runs `ash.setup --quiet`, applying the new drop migration to the test DB).

Risks: ash.codegen bundling unrelated drift (inspect step 4); dialyzer/credo after module deletion (only comment references remain — swept in step 6); unused aliases in the rewritten export test (compile_check/credo catch).

## Commits (targeted staging, change-related files only)

1. `fix: cron one-shot :at jobs disable after firing and skip elapsed at reload (M11)` — worker.ex + two cron test files + report edits for M11.
2. `refactor: remove legacy v0.5.x solutions migrator and ReputationImport ledger (M12)` — deletions, domain.ex, generated migration + snapshot removal, export-test rewrite, comment + exploration-doc sweep, `.jido/SOLUTIONS_DEPRECATION.md`, report edits for M12.
