# AR-2 Composer — Phase 2 (Durable Envelope): decomposition + Phase 2a

## Context

`docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md` designs a deterministic, signal-driven route
composer above the shipped Reactor envelope. **Phase 0** (pure router) and **Phase 1** (the
in-memory single-run loop) are committed (`012f17f`, `c7a428a`); the tree is clean. Phase 1's
`RouteComposer` GenServer turns the crank — seed → `compose_route` → `merge_sticky` → dispatch the
next unrun wave → run it on `ReactorRunner` → `Fold` → recompose → converge — but **all composer
state (`live`, `artifacts`, `ran`, `prev_route`, `wave_index`) lives only in GenServer memory.** A
crash loses it; resume would be a blind re-run; the dashboard can't show "the route"; the cluster
lease (§10.1) has nothing to claim.

**Phase 2 (§14) makes the run a pure function of durable state (§6):** a first-class parent
`WorkflowRun` whose append-only event log carries composer deltas, with each wave a child
`WorkflowRun` linked by `parent_run_id`. A rebooting node rebuilds state by folding the parent log
and resumes mid-route. Two decisions are now fixed:

- **§15.3 (the blocker) is resolved — encrypted ref-store.** A new `JidoClaw.Orchestration.ComposerArtifact`
  Ash resource (scoped to the parent run, provenance-keyed `name → producer`, **AshCloak-encrypting
  the entire `value` column**, tombstone flag, addressed by opaque `art_<hex>` refs). Emissions,
  event payloads, and `WorkflowRun.result` carry **refs only** — no artifact value is ever plaintext
  at rest. Models `ToolOutput` (`conversations/resources/tool_output.ex` — ref + value table) +
  `WorkflowRun`'s cloak block (`workflow_run.ex:52-55`).
- **Delivery — phased.** Phase 2 is far past one commit-ready unit, so it is decomposed into a
  **committed design doc** with sub-phases **2a → 2b → 2c → 2d**, each ending **`mix precommit`
  green** and independently committable. **This plan writes that design doc and implements Phase
  2a** (parent-run lineage + launch helper). 2b–2d each get a focused plan against the prior
  sub-phase's landed code. Nothing in Phase 2 is dropped — the later sub-phases are scoped below so
  the design doc is complete.

> **No deferrals within Phase 2.** The four sub-phases together deliver all of §6/§7/§14-Phase-2.
> Some composer event *kinds* (e.g. `wave_paused`/`route_rejected`/`stages_invalidated`) have their
> *producers* in later AR-2 phases by the doc's own design (gates → Phase 4, reruns → AR-4); Phase 2
> builds and tests them at the **closed-set + projection + recovery** layer so the durable substrate
> and crash-correctness are complete now.

---

## §15.3 — resolved: `ComposerArtifact` encrypted ref-store

A new Ash resource in the `JidoClaw.Orchestration` domain (durable orchestration data lives there —
`WorkflowRun`/`WorkflowEvent`/`AgentCase`). **Hand-rolled `use Ash.Resource`** (not the
`JidoClaw.Resource` macro — the macro doesn't forward `extensions:`, exactly as `WorkflowRun`
notes at `workflow_run.ex:9-13`):

```elixir
use Ash.Resource,
  otp_app: :jido_claw, domain: JidoClaw.Orchestration,
  data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer],
  extensions: [AshCloak]

cloak do
  vault(JidoClaw.Security.Vault)        # same vault as WorkflowRun/SecretRef — already booted
  attributes([:value])                  # encrypt EVERY value; column becomes encrypted_value
end

# attrs: ref ("art_<hex>"), name, producer, value(:binary→encrypted), tombstoned(:boolean,false),
#        parent_run_id(:uuid), tenant_id(:string, plain attr — ToolOutput shape, no belongs_to :tenant)
# identity :unique_ref, [:tenant_id, :ref]
# index    [:tenant_id, :parent_run_id, :name]                          (per-run, per-name lookup)
# index    [:tenant_id, :parent_run_id, :name, :producer], unique,
#          where: "tombstoned = false"   (P3: ≤1 ACTIVE ref per {run,name,producer} — makes
#                                          invalidation/replay deterministic; a tombstoned row
#                                          leaves the partial index so a re-add inserts cleanly)
# tenant-scoped (multitenancy :attribute on tenant_id), with a multitenancy(:bypass) by_id_global
```

`available` derives from the store: a `name` is available iff ≥1 **non-tombstoned** producer row.
`artifacts_invalidated {name, producer}` sets `tombstoned: true` (clearing follows the force-NULL
discipline only matters for the cloaked column on *update*; tombstoning flips a plain boolean, not
the encrypted value). The **partial unique index** (P3) guarantees the in-memory `store[name][producer]
= ref` maps to exactly one active row, so re-folding and crash-replay are deterministic. Refs flow through the in-memory store (`name → producer → ref`), through
`StageEmission.artifacts`, through event payloads, and through `WorkflowRun.result`; **values never
leave the encrypted column** except when `ArtifactContext` resolves+decrypts them for the next
wave's `:extra_context`. (Open sub-question "stored vs reconstructed-from-environment" — e.g. a
working-tree `diff` — is **out of scope for Phase 2**: everything is stored.) **The store
implementation is Phase 2b**; this decision is recorded here and in the design doc.

---

## The Phase 2 decomposition (→ committed design doc)

The first execution step of this plan is to write
**`docs/exploration/alp-river/AR-2-PHASE-2-DURABLE-ENVELOPE.md`** capturing this table (expanded),
so the architecture is committed alongside the code. Each sub-phase ends `mix precommit` green.

| Sub-phase | Scope | Key files | Done when (green) |
| --- | --- | --- | --- |
| **2a — Parent-run lineage + launch** *(THIS PLAN)* | `WorkflowRun` gains `belongs_to :parent_run`/`has_many :child_runs` (cross-tenant-guarded, indexed, migrated); `ReactorRunner.run/3` gains a `:parent_run_id` opt; a `RouteComposer` split launch (`create_parent_run/1` + `start_composer/2`) creates the parent as `workflow_type: "composer"` + appends its own `run_started`; waves run as children keyed `composer:<parent>:<wave_index>`. Composer state stays in memory. | `workflow_run.ex`, `reactor_runner.ex`, `route_composer.ex`, `workflow_recovery.ex` (no-op guard), migration + snapshot | A composer run creates a `:running` parent; every wave's child carries `parent_run_id` + the idempotency key; parent reaches a terminal status on finish; a cross-tenant `parent_run_id` is rejected. |
| **2b — `ComposerArtifact` encrypted ref-store** | New resource (above, incl. the P3 partial-unique index) + migration; rewire `Fold`/`WaveCollect`/`StageEmission`/`ArtifactContext`/`DefaultMapper` so `WaveCollect` persists values→refs and emissions carry refs; in-memory store becomes `name → producer → ref`; `ArtifactContext` resolves+decrypts. **Close every plaintext-at-rest leak (P1) — four persistence points, not one:** (i) `ReactorMiddleware.result_summary/1` writes raw `%StepResult{result, typed_output}` into `step_completed` payloads + `WorkflowStep.output` (`reactor_middleware.ex:365-372`); (ii) `AgentStep` injects the **decrypted** artifact `:extra_context` into `full_task` (`agent_step.ex:65`); (iii) `AgentRunner` persists that task + terminal result via `SubagentTranscript` (`agent_runner.ex:70`, `subagent_transcript.ex:125`); **(iv) the `Recorder` persists the subagent's tool calls, tool results, and reasoning into `messages.content` *and* `messages.metadata`** (`recorder.ex:496,528,575`). Composer waves must suppress/digest (i) **and** sanitize **all message writes (content + metadata) for composer subagent request IDs into placeholder rows** — (iii) **and** (iv). The mechanism is an explicit context marker (e.g. `suppress_transcript?: true`) set on the wave's step/tool context **before** child correlation (`agent_runner.ex:69`) and honored by `Recorder` + `SubagentTranscript`; write **sanitized placeholders, not row-suppression**, so durable subagent-context/compaction expectations stay intact (P2). **Narrowing the guarantee to orchestration-tables-only is not acceptable while lifting the fixtures rule** (P1): `messages.content` is **redacted-not-encrypted** (`message.ex:375`), so a narrowed guarantee would leak real sensitive artifacts plaintext in transcripts — so 2b sanitizes *all* subagent message writes into placeholder rows, *then* lifts Phase 1's "non-sensitive fixtures only" rule. | new `composer_artifact.ex`, `fold.ex`, `steps/wave_collect.ex`, `stage_emission.ex`, `artifact_context.ex`, `emit/default_mapper.ex`, `orchestration/reactor_middleware.ex`, `skills/steps/{agent_step,agent_runner}.ex` + `conversations/{subagent_transcript,recorder}.ex` | No artifact value is plaintext in the orchestration tables (WaveCollect return, event payloads, `WorkflowRun.result`, `step_completed`, `WorkflowStep.output`) **or** subagent transcripts (`messages.content` *and* `messages.metadata`); values encrypted at rest; loop runs identically. |
| **2c — Composer event log + projection + durable loop** | Extend `WorkflowEvent.kind` with the composer kinds — additive (`route_composed`, `wave_started`, `wave_completed`, `signals_published`, `artifacts_produced`, `wave_paused`, `wave_resumed`), subtractive (`signals_retracted`, `stages_invalidated`, `artifacts_invalidated`), and **one parent-terminal kind per loop terminal (P2):** `route_converged`→`:completed`; `route_not_converged`/`route_deadlocked`/`route_budget_exhausted`/`route_failed`→`:failed`; `route_rejected`/`route_abandoned`→`:cancelled`+disposition. Extend `Projection` (`@status_authority_kinds`, `next_status/2`, `status_attrs/3`); add a composer-state fold replaying additive+subtractive deltas in `seq` order. Rewrite the loop to append `route_composed` → `wave_started` (pre-launch) → one-txn `wave_completed` + content events, folding via the existing `Fold.fold/2`. Supervised lifecycle: `DynamicSupervisor` + unique `Registry` keyed by `parent_run_id`, transient restart. | `workflow_event.ex`, `workflow_event/projection.ex`, new `route_composer/projection.ex` (composer-state fold), `route_composer.ex`, `application.ex` | The run's full state is durable in the parent log and re-projectable; in-memory state is a cache of the projection; **every loop terminal (`route_composer.ex:55`) maps to a distinct composer terminal kind**; an empty-emission wave still records `wave_completed`. |
| **2d — Crash recovery (the payoff)** | `WorkflowRecovery` gains a real `workflow_type: "composer"` branch (replacing 2a's no-op): rebuild state from the log, reconcile child waves first (a boot `:running` child is stranded→`:failed`, never observed), re-launch a `wave_started`-with-no-child wave under the same key, replay a dropped `wave_completed` fold from the completed child result + store, re-`compose_route`, resume from the next wave; synthesize `route_rejected`/`route_abandoned` for a gate decided-then-crashed. | `workflow_recovery.ex`, `route_composer/projection.ex`, tests | A killed mid-route run resumes from the next wave on reboot; subtractive deltas stay applied; a gate-terminal-then-crash synthesizes the parent terminal. |

---

## Phase 2a — implementation (this plan)

**Goal:** every composer run is a real, supervised-later parent `WorkflowRun` (`workflow_type:
"composer"`, flipped to `:running` by its own `run_started`), and each wave is a *child* run linked
by `parent_run_id` and keyed by a deterministic `composer:<parent>:<wave_index>` idempotency key.
This establishes the lineage + idempotent-wave correlation that 2b–2d build on. **State stays in
memory** (event log/projection = 2c; recovery = 2d). 2a keeps Phase 1's **non-sensitive-fixture-only**
rule (inline values still transit the child `WorkflowRun.result`); 2b removes inline values entirely.

### 1 — `WorkflowRun` schema (`lib/jido_claw/orchestration/workflow_run.ex`)

- **Relationships** (`:356-378`) — add the self-relationship. `allow_nil?(true)` is mandatory
  (`test/jido_claw/style/belongs_to_allow_nil_test.exs` + AshCredo); `attribute_writable?(true)` lets
  Ash's auto-defined `parent_run_id` FK be set at create (do **not** add `define_attribute?(false)`
  — unlike the `tenant`/`user`/`project` belongs_to, we want Ash to define this column):

  ```elixir
  belongs_to :parent_run, __MODULE__ do
    allow_nil?(true)
    attribute_writable?(true)
  end

  has_many :child_runs, __MODULE__ do
    destination_attribute(:parent_run_id)
  end
  ```

- **`:create` accept list** (`:101-112`) — add `:parent_run_id`.
- **Cross-tenant guard** — add a second `change` to `:create` (beside `set_attribute(:status,
  :pending)` at `:114`) running `JidoClaw.Security.CrossTenantFk.validate/2` in a `before_action`,
  modelled exactly on `memory/resources/block.ex:340-356` (`Changes.ValidateCrossTenant`). Spec:
  `[{:parent_run_id, JidoClaw.Orchestration.WorkflowRun, JidoClaw.Orchestration}]`. `WorkflowRun`
  already exposes `by_id_global` (`:174-180`) the validator loads through, and it **skips nil FKs**
  (`cross_tenant_fk.ex:90`) so a root composer parent (no parent) passes.
- **Index** (`postgres → custom_indexes`, `:60-72`) — add `index([:tenant_id, :parent_run_id])`.
- **Migration** — `mise exec -- mix ash_postgres.generate_migrations add_workflow_run_parent_lineage`
  → migration in `priv/repo/migrations/` + snapshot in `priv/resource_snapshots/repo/workflow_runs/`
  (both committed; `mix test` runs `ash.setup` first).

### 2 — `ReactorRunner.run/3` (`lib/jido_claw/orchestration/reactor_runner.ex`)

One additive opt. In `create_run`'s attrs (the merged map at `:245-273`, currently hardcoding
`workflow_type: "reactor"` at `:256`), thread the FK:

```elixir
parent_run_id: Keyword.get(opts, :parent_run_id)   # nil for ordinary reactor runs → root run
```

No spec change (`run/3` already takes `keyword()`), no change to the `idempotency_key` machinery —
it is already complete: dedupe read (`:243`), create, unique-violation backstop, and the
`{:ok, {:existing_run, id}, run}` return on a hit (`:296`) with nothing executed.

### 3 — `RouteComposer` (`lib/jido_claw/route_composer/route_composer.ex`)

- **Split launch: `create_parent_run/1` + `start_composer/2` (P1)** — the two concerns are separated so
  the link policy is explicit, not contradictory.
  - **`create_parent_run/1`** does the durable genesis in **one `Ash.transact([WorkflowRun,
    WorkflowEvent], …)`** (the `Cases.commit_*` pattern): create the parent via
    `WorkflowRun.create(%{name: …, workflow_type: "composer"}, tenant:, actor:)` (genesis `:pending`),
    then `WorkflowLog.append(parent, :run_started, payload, tenant:, actor:)` — reusing the shipped
    status authority (`next_status(:pending, :run_started) → :running`, `projection.ex:101`), so **no
    composer-specific start kind** is needed and the parent never needs `ReactorMiddleware`. After the
    transaction commits, **reload** the parent (the `create` struct is still `:pending` — `WorkflowRun.by_id`)
    → `{:ok, running_parent}`. **If the reload fails after `run_started` committed** (P2), the parent is
    already `:running` and ownerless → `terminalize_parent(parent, :composer_reload_failed)` before
    returning the error.
  - **`start_composer/2`** then starts the GenServer with `parent_run_id: parent.id` — and is where the
    link policy lives: **`run_sync` uses the unlinked `GenServer.start/3`** path (+ `Process.monitor`),
    while **2c's supervised path uses `start_link/1` under the `DynamicSupervisor`** (`:93` stays). The
    GenServer must **never** start before `create_parent_run/1` commits — `init/1` returns
    `{:continue, :tick}` and runs waves immediately (`route_composer.ex:164`), so a wave could fire
    against an uncommitted parent. **If the start itself fails after the parent exists** (P2) →
    `terminalize_parent(parent, :composer_start_failed)` before returning `{:error, reason}`.
- **State** — add `:parent_run_id` to the GenServer state (seeded in `init/1`, `:142-165`). Everything
  else stays in memory.
- **`run_wave/3`** (`:185-203`, via `run_reactor/3` `:228-236`) — thread two opts into the
  `ReactorRunner.run/3` call:
  - `parent_run_id: state.parent_run_id`
  - `idempotency_key: "composer:#{state.parent_run_id}:#{state.wave_index}"`

  and make the return match **total** by adding an existing-run clause (a hit can't occur in 2a's
  linear single-process loop, but the key makes it reachable for 2d, and adding it now keeps the
  contract honest): `{:ok, {:existing_run, _id}, run}` → if `run.status == :completed`, feed
  `decode_emissions(run.result)` through the existing `handle_wave_value/5` success path; else
  `finish_failed(...)`. (The full status-branch table — `:awaiting_approval` park, live `:running`
  observe — is 2c/2d; 2a only needs `:completed`/other.)
- **`finish/2`** (`:286-295`) — **append the parent terminal FIRST, then notify** (P1; current
  `finish/2` sends *before* stopping, `:286`). Appending first makes the `:done` summary the caller
  receives match durable state, keeps `run_sync/1` tests from racing the DB write, and surfaces an
  append failure instead of hiding it behind a success the caller already saw. Use *existing* event
  kinds so the parent is correctly terminal (not left `:running`): `:converged` → a **reload-guarded**
  `run_completed` append (`%{result: summary_subset}` → `:completed`); every other terminal
  (`:not_converged`/`:deadlock`/`:budget_exhausted`/`:failed`) → a reload-guarded `run_failed` append
  (→ `:failed`) — both via the helper below. The `error` string is formatted from the **`{terminal,
  reason}` pair**, not `reason` alone (P3): `:not_converged`/`:deadlock` carry a **nil** `reason`, so
  `format(reason)` would store the literal `"nil"` — format the terminal (`"not_converged"`, `"deadlock"`,
  `"budget_exhausted: max_waves=20"`, `"failed: <reason>"`). `summary_subset` is a json-safe map
  (`terminal`, `wave_index`, route names) — **never artifact values**; `WorkflowRun.error` is a `:string`
  column (`workflow_run.ex:250`). If the terminal write fails, `finish/2` notifies `{:route_composer,
  ref, {:terminalize_failed, reason}}` (not `{:done, summary}`), which `run_sync/1` surfaces as
  `{:error, {:terminalize_failed, reason}}` — never a falsely-successful `:done`. *(2c replaces these appends with the semantically-named
  `route_converged` / `route_not_converged` / `route_deadlocked` / `route_budget_exhausted` /
  `route_failed` kinds — one per loop terminal, all projecting onto the same statuses — a localized swap.)*
- **`run_sync/1` = `create_parent_run/1` → `start_composer/2` (unlinked) → monitored receive** (P1 + P2).
  Because the composer is started **unlinked** (`GenServer.start/3`, the `start_composer` policy above) +
  `Process.monitor`ed, a crash surfaces as a `:DOWN` to handle, never a linked exit that kills the caller
  first (Phase 1 linked it, `route_composer.ex:93,113-135`). Then: on `{:route_composer, ref, {:done, _}}`
  → success (the composer appended its own terminal in `finish/2`); on **timeout** → kill the composer and
  `terminalize_parent(parent, :composer_timeout)` (stored as the string `"composer_timeout"`); on an
  **abnormal `{:DOWN, _, _, _, reason}`** (reason ≠ `:normal`) → `terminalize_parent(parent,
  {:composer_crashed, reason})`. **Widen the `run_sync/1` contract** (P2): its `@spec` allows only
  `{:ok, summary()} | {:error, :timeout}` today (`:112`); 2a adds `{:error, {:start_failed, reason}}`
  (create/reload/start failures from `create_parent_run`/`start_composer`), `{:error, {:crashed, reason}}`
  (abnormal `:DOWN`), and `{:error, {:terminalize_failed, reason}}` (a `finish/2` parent-terminal write
  that failed), each test-covered. (A full **node reboot** — caller and composer both gone — is the one path
  2a can't terminalize live; the §4 recovery no-op guard keeps boot recovery from *failing* such a parent,
  and 2d rebuilds + resumes it.)
- **One reload-guarded parent-terminal helper** (P2), modelled on `ReactorRunner.ensure_failed/3`
  (`reactor_runner.ex:706-718`): **reload** the parent and append the terminal **only from a non-terminal
  status**; an **already-terminal** reload returns `:ok` (success, not error). This is required because
  `WorkflowLog.append/4` *does* error on an already-terminal parent — the projection's `:illegal`
  transition rolls the append back, so a raw append is **not** a harmless no-op (correcting the earlier
  claim). **Every** parent-terminal write routes through it — `finish/2`, `create_parent_run/1`'s
  reload-failure, `start_composer/2`'s start-failure, and `run_sync/1`'s timeout/`:DOWN` paths — so a
  `finish`-vs-timeout race never double-writes. Failure
  reasons are **string-formatted** (`inspect`/`Reason.format`) before landing in the `:string` `error`
  column. **Failure-mapping (P3):** only `finish/2`'s normal path — where terminalization is the *sole*
  failure — surfaces `{:error, {:terminalize_failed, reason}}`; on the **abnormal** paths
  (reload/start/timeout/crash) the **original** error wins (`{:error, :timeout | {:start_failed, _} |
  {:crashed, _}}` is preserved) and a helper failure there is **logged loudly** — a parent left
  `:running` must be visible, never masked behind the root-cause error.

### 4 — `WorkflowRecovery` minimal composer guard (`lib/jido_claw/orchestration/workflow_recovery.ex`)

A composer parent sits `:running` for the whole run and carries no checkpoint. In-process abnormal
exits (timeout/crash) are now terminalized live by `run_sync/1` (P2 above), but a **node reboot**
leaves a genuinely-`:running` parent that the shipped `classify/1` (`:118-133`) would mis-classify as
`:stranded → :failed` at boot. Real composer recovery (rebuild + resume) is **2d**; until then, add a
**no-op guard** ahead of the status-based heads so boot recovery never clobbers a composer parent:

```elixir
defp classify(%WorkflowRun{workflow_type: "composer"}), do: :composer   # before the status heads
# reconcile_branch(:composer, run) -> emit(run, :composer)  # observe-only, like the :parked-with-case branch
```

This is the correct first cut (don't let reactor recovery touch the new run type), expanded into full
state-rebuild + resume in 2d. (Recovery is disabled in test — `:workflow_recovery` `:enabled?` false
— so this guards dev/prod, not the suite.)

### Tests (2a)

- **Integration** (`test/jido_claw/route_composer/composer_loop_test.exs`, `TenantCase`, `async:
  false`) — extend the existing convergence run: assert the parent `WorkflowRun` exists with
  `workflow_type: "composer"` and is `:running` mid-run / `:completed` at convergence; assert **every**
  wave's child run has `parent_run_id == parent.id` and `idempotency_key ==
  "composer:#{parent.id}:#{wave_index}"`; assert the findings and undeclared-signal variants take the
  parent to `:failed`; **extend the existing `run_sync` timeout test (the `BlockingAgentServer` case,
  `composer_stubs.ex`): assert `run_sync` returns `{:error, :timeout}` and the parent is terminalized to
  `:failed` with `error == "composer_timeout"` (the stored *string* — `error` is `:string`), not left
  `:running`** (P2/P3). Cover the widened contract — a start failure → `{:error, {:start_failed, _}}`
  with the parent terminalized, and (where inducible) an abnormal `:DOWN` → `{:error, {:crashed, _}}`.
  **The existing timeout helper is link-oriented (`composer_loop_test.exs:196`, e.g.
  `await_linked_composer` polling `Process.info(:links)`); rework it for the unlinked + monitored
  design** — capture the composer pid from the `start_composer/2` return (or a monitor ref), not the
  caller's link set.
- **Cross-tenant guard** (new unit test, model on existing `CrossTenantFk`/`block` tests) — creating a
  child run whose `parent_run_id` points at a parent in another tenant is rejected
  (`cross_tenant_fk_mismatch`).
- **Recovery no-op guard** (new test) — create a `workflow_type: "composer"` parent in `:running` with
  no checkpoint, call `WorkflowRecovery.reconcile_all/0` directly, and assert it **stays `:running`** —
  the composer branch observes, not the shipped `:running + no checkpoint → :stranded → :failed` branch
  (`workflow_recovery.ex:125`).
- **Style/AshCredo** — `belongs_to_allow_nil_test.exs` now scans `belongs_to :parent_run`; it has
  `allow_nil?(true)` → green. Compile before credo (the AshCredo-visibility note).

### Precommit / gate notes (2a)

`mise exec -- mix precommit` runs `jidoclaw.compile_check` (empty allowlist — zero non-allowlisted
warnings), `system_prompt.check`, `deps.unlock --unused`, `format`, `reach.check --arch --smells
--strict`, `credo --strict`, `dialyzer`, `test`. For 2a:

- **AshCredo gauntlet** — `WorkflowRun` is hand-rolled `use Ash.Resource`, so the `belongs_to`
  `allow_nil?` checks apply; satisfied. No new resource module in 2a (`ComposerArtifact` is 2b), so the
  full visibility gauntlet/`.credo.exs` precedent isn't needed yet.
- **reach `--smells`** — only an inline `Changes.ValidateCrossTenant` change module (block.ex
  precedent) + edits to existing modules; no new top-level lib module, so no `behaviour_candidate`
  expected. No `.reach.exs` edit anticipated.
- **Migration** — committed migration + snapshot; `mix test`'s `ash.setup` applies it. Run gates **bare
  in the background**, read the tail (never pipe — `| tail` masks the exit code).

### Files (2a)

**New:** `docs/exploration/alp-river/AR-2-PHASE-2-DURABLE-ENVELOPE.md` (the committed decomposition);
migration in `priv/repo/migrations/`; snapshot in `priv/resource_snapshots/repo/workflow_runs/`; a
cross-tenant guard test (e.g. `test/jido_claw/orchestration/workflow_run_parent_lineage_test.exs`).
**Modified (lib):** `orchestration/workflow_run.ex` (relationship + accept + guard + index),
`orchestration/reactor_runner.ex` (`:parent_run_id` opt), `route_composer/route_composer.ex`
(`create_parent_run/1` + `start_composer/2`, `terminalize_parent/2`, state, `run_wave` threading,
`finish` parent terminal), `orchestration/workflow_recovery.ex` (composer no-op guard).
**Modified (test):** `test/jido_claw/route_composer/composer_loop_test.exs`.

**Commit plan** (slicing guidance only — **do not commit; leave everything unstaged**). When 2a is
green: one commit `feat: composer Phase 2a — parent-run lineage + split launch` (split the design
doc into its own `docs:` commit if preferred).

---

## Verification (2a)

Run via `mise exec -- mix` (mise-latest toolchain). Gate commands **bare in the background**, read the
output tail.

1. `mise exec -- mix ash_postgres.generate_migrations add_workflow_run_parent_lineage` then
   `mise exec -- mix ecto.migrate` (or `ecto.reset`) — schema applies cleanly.
2. `mise exec -- mix format` (changed files).
3. Targeted: `mise exec -- mix test test/jido_claw/route_composer/composer_loop_test.exs
   test/jido_claw/orchestration/workflow_run_parent_lineage_test.exs` — convergence run shows the
   `:running`→`:completed` parent + child `parent_run_id`/idempotency-key linkage; cross-tenant FK
   rejected.
4. Suite-flaky note: re-run `composer_loop_test.exs` **in isolation** (not just `--seed 0`) to confirm
   the `async: false` `TenantCase` is stable.
5. Tidewave sanity (optional): in `project_eval`, drive `RouteComposer.run_sync/1` over the fixture
   catalog and inspect the parent `WorkflowRun` row + its `child_runs` (`parent_run_id` set, statuses
   correct).
6. **Done-criterion:** `mise exec -- mix precommit` — must be green.

## After 2a

2b–2d each get a **fresh focused plan** against 2a's landed code, in order:
**2b** `ComposerArtifact` encrypted ref-store (the §15.3 implementation) → **2c** composer event
kinds + projection + durable append/project loop + supervised lifecycle → **2d** `WorkflowRecovery`
composer branch (resume mid-route on reboot). The committed design doc carries their full scope so
nothing is dropped.
