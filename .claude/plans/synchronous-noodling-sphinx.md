# AR-2 Composer — Phase 2d: Crash Recovery (the payoff)

## Context

Phases 2a/2b/2c have landed (see git log). The composer is now a first-class parent
`WorkflowRun` whose append-only `WorkflowEvent` log carries composer deltas, with each wave a
child run linked by `parent_run_id`, and 2c's supervised `JidoClaw.RouteComposer` GenServer
**already rebuilds state from the log and resumes** (`init/1` → `{:continue, :rebuild}` →
`do_rebuild/1` (`route_composer.ex:550`) folds `WorkflowEvent.for_run` via
`RouteComposer.Projection.project/2` → `{:continue, :tick}`).

Phase 2d delivers the payoff the durable envelope was built for: **a node that reboots
mid-route resumes from durable state instead of stranding or blind-re-running.** Today,
`WorkflowRecovery.classify/1` (`workflow_recovery.ex:133`) routes a `:running` composer parent
to a no-op observe (`reconcile_branch(:composer, run) → emit(...)`, `:244`) — the explicit 2a
placeholder. 2d replaces that with a real rebuild+resume branch.

**The cold-boot gap that makes 2d more than a recovery branch.** A *warm* (same-VM) supervisor
restart already works (the child spec retains the launch opts; tested at
`composer_durable_test.exs:401`). But on a **full node reboot** the supervisor's child specs are
gone, and exploration confirmed the composer's launch inputs — the **catalog** (the input to
`compose_route`) and the **seed** (`live` / `artifacts` / `premises`) — are *not durable
anywhere*; only `deadline_at_ms` and `sanitize_sensitive_context` survive in the parent
`config`. So 2d must first make those inputs durable at genesis, then have `WorkflowRecovery`
reconstruct them and restart the supervised composer (whose existing rebuild loop then resumes).

**Two decisions (locked with the user):**
1. **Catalog → serialized into the parent `config`** (add `Catalog`/`Stage` to_map/from_map;
   self-contained, sidesteps catalog drift; `catalog_hash` stays a round-trip integrity check).
2. **Seed artifacts → encrypted ref-store** (P1 stays intact: config/state carry only refs,
   values live encrypted in `ComposerArtifact`).

**Durability mechanism (reuses the existing fold — projection unchanged).** At genesis,
`create_parent_run/1` records the seed the same way a wave does: a genesis `signals_published`
event (seed `live`) and a genesis `artifacts_produced` event (seed `artifacts`, ref-stored).
`init/1` still seeds `live`/`artifacts` from opts at launch; `do_rebuild` folds the genesis
events onto that seed — **idempotent** because signal-fold is set-union and artifact-fold
overwrites `store[name][producer]` (validated by the red-team, H5). At recovery, recovery passes
no `live`/`artifacts` opts (init defaults to empty) and the genesis events rebuild them. So
launch and recovery converge with no double-count and no projection change. The catalog and seed
`premises` go in `config` (seed premises in config closes the pre-first-wave gap — `route_composed`
only carries premises *after* the first wave's marker is appended, so a crash between genesis and
the first wave would otherwise lose non-empty seed premises; premises still also folds latest-wins
from `route_composed` once waves run).

This plan incorporates a red-team pass. The most important holes it caught and this plan fixes:
- **H23 (P1 security):** a recovered *sensitive* run would lose its `sanitize_sensitive_context`
  marker (and `wave_timeout_ms`/`max_waves`) → plaintext leak on recovery. `build_start_opts`
  must restore them from `config`.
- **H8:** rule 2 (re-derive a `:failed` child under a fresh `wave_index`) must apply **only** to
  the `handle_wave_result` existing-run hit, **not** the warm-restart observe path (where a
  `:failed` is a genuine just-now wave failure that must still fail the route).
- **H1/H2/H9/H10:** concrete blockers (a pinned test breaks on nullable `child_run_id`; the
  lineage guard rejects a nil child instead of skipping; four `finish`-chain seams for
  `:rejected`/`:abandoned`; the disposition must be a JSONB-safe string).

---

## Done-when (the 2d acceptance criteria)

1. A killed mid-route run resumes from the next wave on reboot.
2. A `wave_started`-with-no-child re-launches under the **same** `composer:<parent>:<wave_index>`
   key (rule 1).
3. A child recovered to `:failed` re-dispatches its stages under a **fresh `wave_index`** (rule 2).
4. Subtractive deltas (`signals_retracted` / `stages_invalidated` / `artifacts_invalidated`)
   stay applied across the rebuild.
5. Orphaned `:pending` `ComposerArtifact` rows from a crashed wave never block re-launch and
   never surface as available.
6. A gate-decided-then-crash synthesizes the parent terminal (`route_rejected` /
   `route_abandoned` → `:cancelled` + disposition).
7. **`mix precommit` passes** (the plan is not complete until it does).

---

## Implementation

### Step 0 — Catalog serializer (new) — `lib/jido_claw/route_composer/catalog.ex` + `stage.ex`

Add `Catalog.to_map/1` and `Catalog.from_map/1` (delegating per-stage to `Stage.to_map/1` /
`Stage.from_map/1`).

- `Stage.to_map/1`: stringify the **closed enums only** — `unit` tuple
  (`{:worker_template, n}` → `%{"tag" => "worker_template", "name" => n}`), `emit`
  (`:default` → `"default"`, `{:mapper, n}` → `%{"mapper" => n}`), `guard`/`model`/`effort`
  (→ string or nil), `input` (→ `%{"required" => …, "optional" => …}`), `lock`
  (→ `[%{"while" => …, "until" => …}]`). All free strings/lists (`name`, `task`, `lens`,
  `routes`, `output`, `subscribes`, `publishes`, lock `while`/`until` *values*) pass through —
  they stay strings (`stage.ex:18` atom-safety invariant).
- `Stage.from_map/1`: rebuild via `struct(Stage, fields)` so struct defaults (`stage.ex:100-107`)
  fill absent keys. Coerce the closed enums back via a **hardcoded whitelist match**
  (`case`/map lookup), **never** `String.to_atom`/`String.to_existing_atom` on free input
  (user-decision-1; mirrors `Envelope`'s `[:safe]` rationale). The whitelist must be
  **exhaustive over every closed variant** (finding #3): `unit` tags `:seed` / `:worker_template`
  / `:skill` / `:gate` (the built-in catalog has a `:seed` stage, `stage.ex:57`), `emit`
  (`:default` / `{:mapper, _}`), and the `guard` / `model` / `effort` / input-key / lock-key
  enums. An **unknown closed tag fails the whole decode** — `from_map` returns `nil`, never a
  created atom, a kept string, or a partial `%Stage{}` (so the recovery guard in Step 6 treats a
  malformed catalog identically to an absent one).
- `Catalog.from_map(nil) → nil` (**load-bearing**, H12 — the supervised-lifecycle tests fall
  back to opts when `config` has no catalog). `from_map` is **total + nil-on-failure**, never
  `{:error, _}` (H18 — the `|| opts[:catalog]` fallback breaks on a truthy error tuple).
- **Round-trip integrity (H13c):** a unit test asserts `from_map(to_map(c)) == c` for both
  `Catalog.all()` and `TestFixtures.phase1_catalog()`. This is the de-facto `catalog_hash`
  check (nothing compares the rebuilt hash at runtime; the projection never folds `wave_started`).
- **reach (H16a):** if the per-stage map shape trips `fixed_shape_map` cross-file with `Stage`,
  add `# reach:disable-for-this-file fixed_shape_map` (the single-file idiom), not the global
  ignore list.

### Step 1 — `ComposerArtifact`: nullable `child_run_id` + seed support — `composer_artifact.ex`, `composer_artifact/changes/validate_cross_tenant_fk.ex`, migration

Seeds reuse `store_pending` (no separate action) with `child_run_id: nil`, `producer: "seed"`,
and a `wave_index` sentinel `-1` (so `pending_for_wave`/`activate_for_wave` for real waves
`N ≥ 0` never touch seeds — they stay `:pending` forever, invisible to the `WHERE state='active'`
partial index, resolvable state-agnostically by `resolve_value`; validated H3a).

- `child_run_id` → `allow_nil?(true)` (`composer_artifact.ex:281-284`). Update the moduledoc
  ("The only nullable attribute…", `:266`, `:281`) — value **and** `child_run_id` are now
  nullable.
- `ValidateCrossTenantFk.assert_lineage/1` (`validate_cross_tenant_fk.ex:45`): add an explicit
  **nil-guard head** — `if is_nil(child_run_id), do: cs` (skip the `by_id_global` lineage check),
  else the existing logic. **Required** (H2): `by_id_global` has `allow_nil?: false`, so a nil
  child currently *rejects* (`child_run_not_found`), not skips. Keep the `errors != []`
  short-circuit head first. (`CrossTenantFk.validate` already skips nil FKs, so the parent check
  is unaffected.) Update the change's moduledoc.
- **Migration (project "Ash codegen --dev then squash" convention):** `mix ash.codegen --dev`
  → verify it's a pure `alter column child_run_id drop not null` (+ snapshot update), no data
  migration (greenfield) → squash to one named migration
  (`mix ash.codegen make_composer_artifact_child_nullable`). *(Non-readonly; the implementer
  runs it.)*

### Step 2 — Genesis durability — `route_composer.ex` `create_parent_run/1`

`create_parent_run` already receives the full opts on the `run_sync` path (it's called with
`base_opts`); the minimal `create_parent_run(tenant:, actor:)` test callers pass no
catalog/seed, so every addition below is **guarded on presence** and those callers are unchanged
(H5b).

- Extend `parent_config/2` to also merge (when present in opts): `catalog` (via
  `Catalog.to_map`), `max_waves`, `wave_timeout_ms`, and **seed `premises`** (closes the
  pre-first-wave durability gap, finding #3). Run the premises map through the existing
  **`json_safe/1`** boundary (`route_composer.ex:933`) before storing — the same discipline
  `route_composed_payload/2` already uses — so atom values or stray structs never reach JSONB
  (`feedback_pin_types_at_ash_persistence_boundaries`). `WorkflowRun.create` already accepts
  `:config` (`workflow_run.ex:112`).
- Extend the genesis `Ash.transact` to `[WorkflowRun, WorkflowEvent, ComposerArtifact]`. In the
  `with`, **after** `WorkflowRun.create` + `run_started` (order matters — read-your-writes for
  the seed rows' parent FK, H11b):
  - if seed `live` present → append a genesis `signals_published` with `%{signals: Enum.sort(live)}`;
  - if seed `artifacts` present → flatten `name → producer → value` (the seed store shape, H14),
    `store_pending` each value as a seed row (`child_run_id: nil`, `producer:`, `wave_index: -1`,
    `term: value`), collect `%{name, producer, ref}` triples, append **one** genesis
    `artifacts_produced` with `%{artifacts: triples}`.
- No `unwrap_transact`/spec change: the fn still returns bare `parent` on success → `{:ok, parent}`;
  seed-insert failures flow the existing `{:error, reason}` channel → `{:start_failed, reason}`
  (H11a; respects the "Ash.transact + Dialyzer error channel" learning — no atom routed through
  the success channel).
- **Seed-is-inline doc sweep (finding #4):** after genesis, `do_rebuild` folds the genesis
  `artifacts_produced` event, which **overwrites the inline seed with a `{:ref, ref}` entry**
  (`RouteComposer.Projection` `produce_artifact`, `projection.ex:140`). So a folded/recovered seed
  artifact is a **ref**, and `ArtifactContext.resolve_entry/4` resolves+decrypts it
  (`artifact_context.ex:119-120`). But `ArtifactContext`'s moduledoc currently states a seed is
  "an untagged inline value … not by ref-storage" (`artifact_context.ex:12-21`) — now true **only**
  for the minimal-launch (no-genesis-event) path. Update that moduledoc to describe both cases
  (folded/recovered seed → ref; minimal-launch seed → inline), and `rg` for any other
  "seed is inline"/"not ref-stored" claims (e.g. `composer_artifact.ex` moduledoc) and reconcile
  them (false-invariant sweep).

### Step 3 — `build_start_opts/2` reconstructs from config — `route_composer.ex:369-373`

Shared by `start_composer/2` (launch) and `ensure_started/2` (launch + recovery), so config is
authoritative with opts fallback:

- `catalog = Catalog.from_map(config["catalog"]) || opts[:catalog]` — **config wins** (keeps the
  serialized catalog authoritative / drift-proof; a stale opts catalog never overrides config).
  The redundant decode (recovery also decoded in Step 6 to guard) is a negligible boot/launch
  one-shot, so recovery does **not** need to pass the catalog in opts. Falls back to `opts[:catalog]`
  only when `config` has none — the lifecycle tests' minimal-`create_parent_run` path (H12). Relies
  on `Catalog.from_map(nil) → nil`.
- `premises = config["premises"] || opts[:premises] || %{}` — restore seed premises from config at
  recovery (finding #3), fall back to opts at launch.
- `max_waves = config["max_waves"] || opts[:max_waves] || @default_max_waves`.
- `wave_timeout_ms = config["wave_timeout_ms"] || opts[:wave_timeout_ms] || @default_wave_timeout_ms`
  (H23 — the sensitive-run TTL ceiling in `seed_wave_context` depends on it).
- **`sanitize_sensitive_context: config["sanitize_sensitive_context"] == true`** (H23 — **the
  critical P1 fix**: a recovered sensitive run must keep its marker, else its waves write
  plaintext. Safe for launch too — config was set from the launch marker at genesis).
- Keep `parent_run_id` + `deadline_at_ms` (existing). `live`/`artifacts` ride opts (present at
  launch, absent at recovery — the genesis events rebuild them). `premises` is restored from config
  (above), then `route_composed` takes over latest-wins once waves run.

### Step 4 — RouteComposer recovery terminal handling — `route_composer.ex`

Change **only** the existing-run hit `handle_wave_result({:ok, {:existing_run, _id}, run}, …)`
(`:703-714`), splitting the current `_terminal` catch-all (`:712`):

- `:completed` → fold (UNCHANGED — the dropped-fold replay that promotes `:pending` refs via
  `Commit.commit_wave` → `activate_for_wave`; already correct in 2c).
- `:failed` → **rule 2:** `{:noreply, %{state | wave_index: state.wave_index + 1}, {:continue, :tick}}`.
  The re-tick re-composes (the failed wave's stages are still not in `ran`, since no
  `wave_completed` landed), dispatches under `composer:<parent>:<N+1>` (a key **miss** → a real
  fresh run); the old `:failed` child is a harmless orphan told apart by `wave_index` (H3b/H7).
- `:cancelled` → `finish({:rejected, {:child_cancelled, run.id}}, state)` (gate-decided-then-crash).
- `:abandoned` → `finish({:abandoned, {:child_abandoned, run.id}}, state)`.

**Do NOT** unify this with `observe_existing_child` (`:970-987`) — leave its non-completed
terminal on `finish_failed` (H8). The observe path is the warm-restart in-flight child; a
`:failed` there is a *genuine* just-now wave failure that must fail the route, not silently
retry. The two terminal sites deliberately differ on `:failed`. (A genuine in-loop failure is a
key *miss* → `{:error, reason, run}` → `finish_failed`, never an existing-run hit, so the normal
failure path is untouched, H7b.)

*Non-looping (H7):* the rule-2 re-dispatch is a fresh run; its own genuine failure surfaces as
`{:error, _, run}` → `finish_failed`. Repeated mid-recovery crashes walk `wave_index` forward,
bounded by `max_waves` (which thus doubles as a crash-loop circuit-breaker — document, no code).

### Step 5 — `finish` chain for `:rejected` / `:abandoned` — `route_composer.ex`

The 2c projection already maps `route_rejected`/`route_abandoned` → `:cancelled` and lifts
`result.disposition` (`workflow_event/projection.ex:140-141, 212-213`), so 2d only adds the
**producer** (four seams, H9):

- `@type terminal` (`:175-176`): add `| :rejected | :abandoned` (dialyzer, H9.4).
- `classify_terminal/1` (`:1096-1098`): add `({:rejected, r}) → {:rejected, r}` and
  `({:abandoned, r}) → {:abandoned, r}` before the `is_atom` catch-all.
- `parent_terminal_notify/4` (`:1075`): a dedicated clause `when kind in [:rejected, :abandoned]`
  that appends `route_rejected`/`route_abandoned` (kind→event inline) with payload
  **`%{result: %{disposition: Atom.to_string(kind)}}`** — a **string** disposition (H10:
  JSONB-safe, matching the `terminal_summary_subset`/`json_safe` stringify-atoms discipline);
  **not** `%{error: …}`. Place before the catch-all.
- `@scrubbable_error_kinds` (`:167-173`) unchanged — these carry a disposition, no error string,
  no artifact value.

### Step 6 — `WorkflowRecovery` composer branch — `workflow_recovery.ex`

Keep `classify(%WorkflowRun{workflow_type: "composer", status: :running}) → :composer`
(`:133`) **intact** (H20 — preserves the `:pending`-composer fall-through to `:stranded`).
Replace the `reconcile_branch(:composer, run)` body (`:244`):

1. **Decode-and-guard the catalog (findings #2/#3, H6d):** `Catalog.from_map(run.config["catalog"])`.
   A `nil` result — the key is **absent** (e.g. a parent created via the public
   `WorkflowRun.create`) **or the serialized catalog is malformed** (`from_map` is total +
   nil-on-any-malformation, unknown closed tags included) — means the parent is un-recoverable:
   `Logger.warning` + `emit(run, :composer)` + leave `:running`. Do **not** `ensure_started` — a
   composer started with `catalog: nil` would not raise (`build_start_opts` puts the key) but would
   crash/loop inside `compose_route`. (A presence-only check would let a present-but-bad catalog
   through; decode first.)
2. Else (valid `catalog`): `tenant = run.tenant_id; actor = Actor.system(tenant)`.
   `Ash.load(run, :child_runs, tenant:, actor:)`; **filter to non-terminal**
   (`status in [:pending, :running, :awaiting_approval]`, H6a). For each, run
   `reconcile_branch(classify(child), child)` — children are `workflow_type: "reactor"`, so this
   reuses the shipped reactor branches (`:running` no-checkpoint → `:stranded` → `:failed`; gated
   `:running` + decision → `:decision_recorded` → `GateResume`, synchronous; a parked
   `:awaiting_approval` + pending case → `:parked` → **no-op by design**, `workflow_recovery.ex:156`
   — the human still owns the gate). Collect handled child ids.
3. **Start only when every child is terminal (findings #1 + #2 unified, the robust rule):** after
   reconciling, **reload** the children (`Ash.load(:child_runs)` fresh — statuses changed) and
   check `Enum.all?(children, &Projection.terminal_status?(&1.status))`. If **any** child is still
   non-terminal — a legitimately parked `:awaiting_approval` gate (the `:parked` no-op left it,
   `workflow_recovery.ex:156`), OR a child the `:parked` branch left awaiting after a **transient
   `AgentCase.pending_for_run/2` error** (`workflow_recovery.ex:160`), OR any `:running`/`:pending`
   child reconciliation didn't terminalize — do **NOT** `ensure_started`. A restarted composer
   would re-dispatch that wave, hit `{:existing_run, <non-terminal>}`, and `observe_existing_child`
   would poll the now-executorless child until `wave_timeout_ms` then **fail the parent**
   (`route_composer.ex:708,993,1000`). Instead leave the parent `:running` + `Logger.info` +
   `emit(run, :composer)` and retry next boot. *(Phase-2 note: no gate producers exist yet
   (Phase 4), so a parked composer child cannot arise naturally — this is forward-correctness. The
   durable **wake-the-composer-after-the-gate-decision** story belongs to Phase 4 gate-in-composer
   wiring (§9); 2d must not fail a parked/inconclusive parent, and must not start a composer that
   would.)*
4. Otherwise (all children terminal) `RouteComposer.ensure_started([tenant: tenant, actor: actor],
   run)` (no `catalog:` opt — `build_start_opts` reconstructs it config-authoritatively, Step 3).
   `{:ok, _}` → `emit(run, :composer)`. `{:error, reason}` → `Logger.warning` + leave `:running`
   for the next boot (H19 — a transient supervisor blip must not fail a recoverable route).

Then partition `reconcile_all/0` (`:105-115`): split the global non-terminal list into composer
parents vs others; process composer parents first (collecting handled child ids into a
`MapSet`); then `Enum.reject(others, &MapSet.member?(handled, &1.id))` before
`reconcile_run/1` each (H6b — children must be reconciled *before* the composer re-dispatches, or
it observes a corpse for ~5 min; and excluded from the `others` loop to avoid stale-`:running`
double-reconcile `:illegal` warnings). Extract small helpers to keep the branch lean (credo,
H16c). Update the moduledoc (`:46-51`) — the no-op bullet becomes the real rebuild+resume branch.

### Critical files

- `lib/jido_claw/route_composer/route_composer.ex` (genesis durability, build_start_opts,
  recovery terminal handling, finish chain)
- `lib/jido_claw/route_composer/catalog.ex` + `stage.ex` (serializer)
- `lib/jido_claw/orchestration/composer_artifact.ex` + `composer_artifact/changes/validate_cross_tenant_fk.ex` (nullable child + lineage skip)
- `lib/jido_claw/orchestration/workflow_recovery.ex` (composer branch + partition)
- Migration + snapshot under `priv/repo/migrations/` + `priv/resource_snapshots/`

No change needed to `RouteComposer.Projection`, `WorkflowEvent.Projection`, or `Commit` — they
already handle the genesis events, the `route_*` terminals, and the activate-on-fold promotion.

---

## Tests

Recovery is disabled in test (`config :workflow_recovery, enabled?: false`); craft stranded
state via Ash actions and call `WorkflowRecovery.reconcile_all/0` directly. Composer tests run
under `JidoClaw.TenantCase, async: false` with stub workers (no LLM) and an `on_exit` sweep of
the singleton Registry/Supervisor (`composer_durable_test.exs` setup). Cold boot is simulated by
crafting a `:running` parent (+ children/events) with **no live composer process**, then
`reconcile_all/0`.

**Async terminal — poll, don't assert synchronously (finding #5).** `reconcile_all/0` returns
once `ensure_started/2` has *started* the supervised composer process (`route_composer.ex:341`),
**not** when the route finishes. Every "→ parent `:completed` / `:cancelled`" assertion below
must therefore **poll** for the terminal using the existing `await_status` helper from
`composer_durable_test.exs` (e.g. `await_status(parent.id, ctx, :completed, 30_000)`), never read
the status immediately after `reconcile_all/0`.

**New tests (one per done-when):**
1. *Resume from next wave* — a parent with wave 0 `wave_completed` + completed child, left
   `:running`, no live process → `reconcile_all/0` → parent `:completed`, `:route_converged` in
   kinds.
2. *Rule 1 (no child)* — parent with `wave_started` (wave 0) but no child row → `reconcile_all/0`
   → exactly one wave-0 child materialized under `composer:<parent>:0`, run converges. Asserts
   the genesis seed events rebuilt `live`/`artifacts` (recovery passed no seed opts).
3. *Rule 2 (failed child)* — parent with `wave_started` (wave 0) + a `:running` wave-0 child;
   `reconcile_all/0` fails the child → re-dispatch hits `:failed` → rule 2 → fresh wave-1 child,
   converges; original child stays `:failed`; `active_for_run` has ≤1 active per `{name, producer}`.
4. *Subtractive deltas survive* — a log with `signals_published` then `signals_retracted`;
   recovered `live` reflects the net (retracted signal absent) and `compose_route` honors it.
5. *Orphaned `:pending` inert* — a crashed-mid-wave parent whose `WaveCollect` inserted `:pending`
   rows but no `wave_completed`; re-launch inserts new `:pending` rows cleanly (no unique
   violation), orphans never promoted (`active_for_run` excludes them), `Fold.available` never
   surfaces the orphan. Plus a **seed-row test**: `store_pending(child_run_id: nil, wave_index: -1,
   producer: "seed")` inserts `:pending`, excluded from `active_for_run`/`pending_for_wave(p, 0)`,
   resolvable via `resolve_value`.
6. *Gate synthesis* (two tests, reject + abandon — no Phase-2 gate producers, so **craft** the
   child terminal): a wave-0 child appended to `:cancelled` (reject) / `:abandoned` (via
   `approval_requested` then `run_abandoned`, since `run_abandoned` requires `:awaiting_approval`,
   H6/projection.ex:123). `reconcile_all/0` → existing-run hit → synthesize → parent `:cancelled`,
   `:route_rejected`/`:route_abandoned` in kinds, `parent.result["disposition"] ==
   "rejected"/"abandoned"` (string, H10).
7. *Parked child blocks restart (forward-safety pin, findings #1/#2)* — a parent with a child left
   `:awaiting_approval` (a parked gate with a pending `AgentCase`). `reconcile_all/0` → the child
   stays `:awaiting_approval` (the `:parked` no-op) → the "all children terminal" guard fails → the
   composer is **NOT** started → assert the parent is still `:running`, no composer process is
   registered for it (`Registry.lookup` empty), and the gate child is untouched. Pins that recovery
   never restarts a composer into an observe-timeout fail.
8. *Seed premises survive a pre-first-wave crash (finding #3)* — `create_parent_run` with a
   **non-empty** seed `premises`, then recover via `reconcile_all/0` **before any `route_composed`
   marker exists** (genesis only). Assert the resumed run's **first** `route_composed` payload
   carries those premises (i.e. the recovered composer's state seeded premises from config, not
   from the lost in-memory opts). Pins the config-restore path.

**New unit tests:** `Catalog.from_map(to_map(c)) == c` for `Catalog.all()` and
`phase1_catalog()` (round-trip integrity over **all** unit variants incl. the `:seed` stage);
`from_map(nil) == nil`; a malformed/unknown closed tag → `from_map` returns `nil` and creates no
atom (H13a, finding #3). An **`ArtifactContext.build/4` seed-ref test** (finding #4): build a
store holding a folded seed as `{:ref, ref}` (a real ref-stored seed row) and assert
`build/4` resolves+decrypts it into the `:extra_context` — not just `resolve_value/2` in
isolation. A **sensitive-run recovery test** (H23): `create_parent_run(sanitize_sensitive_context:
true, deadline_ms: …)` → recover via `reconcile_all/0` → assert the recovered composer still
carries the marker (guards the P1 plaintext-leak-on-recovery fix).

**Tests to UPDATE:**
- `composer_artifact_test.exs:199` — remove `:child_run_id` from the `for missing` non-null list
  (H1) + add the positive seed-row insert.
- `workflow_run_parent_lineage_test.exs:76-90` + moduledoc — replace the 2a-no-op assertion: a
  recoverable `:running` composer (config catalog present) is rebuilt+resumed; a no-catalog
  `:running` composer is left `:running` with a logged warning (H6d/H20). Keep `:92-117`
  (`:pending` composer → `:failed`) unchanged.
- `composer_durable_test.exs` — re-run the lifecycle tests (356/378/391/408): they pass unchanged
  given `from_map(nil) → nil` + the config-or-opts fallback (add a regression assertion that
  `ensure_started` after a minimal `create_parent_run` still works via the opts catalog). Re-check
  the kind-sequence tests (137-160): the new genesis `signals_published`/`artifacts_produced`
  sit at the genesis position; the `markers` filter excludes them and `hd(ks) == :run_started`
  holds, so they stay green — confirm no exact-position/exact-count assertion breaks.

---

## Verification

1. **Targeted tests** as written: `mix test test/jido_claw/route_composer/`
   `test/jido_claw/orchestration/{workflow_recovery,workflow_run_parent_lineage,composer_artifact}_test.exs`.
2. **Migration** sanity: `mix ecto.reset` then `mix test` (the suite runs `ash.setup` first); the
   migration is a pure `drop not null`, no data migration.
3. **`mix precommit`** — the completion gate. Watch the high-risk gates the red-team flagged:
   - **dialyzer** — `@type terminal` widened (H9.4); `Catalog.from_map` total + nil-only
     (never `{:error, _}`, H18); genesis seed inserts stay on the existing error channel (H11a).
   - **reach `--strict`** (`fixed_shape_map`) — the serializer's per-stage shape; scope with the
     single-file disable or reuse the existing `%{name:, producer:, ref:}` shape
     (`route_composer.ex:917`) for seed triples (H16a).
   - **credo `--strict`** — keep the recovery branch + partition in small helpers; interpolate in
     logs (H16c).
   - **`jidoclaw.compile_check`** (warnings-as-errors) — note the missing `:rejected`/`:abandoned`
     `finish`-chain clauses are *runtime* FunctionClauseErrors, surfaced by the done-when-6 tests,
     not compile warnings (H17).
4. **Manual (optional)** via Tidewave `project_eval`: build a parent with a real config catalog +
   one completed wave, kill nothing, call `WorkflowRecovery.reconcile_all()`, and inspect that the
   parent reaches a terminal and a fresh child wave ran.

## Notes / scope

This is a large but single coherent unit: the recovery branch plus the genesis-durability
prerequisites (catalog serializer, seed ref-store, `create_parent_run`/`build_start_opts`
threading) that 2c left in memory and recovery cannot do without. Per the parent doc, 2d is one
sub-phase ending `mix precommit` green and is independently committable. Nothing is deferred.
Per the session constraints: everything stays unstaged; do not commit.
