# AR-2 Composer — Phase 2: the Durable Envelope

*Decomposition + the §15.3 resolution. Companion to [`AR-2-COMPOSER-PLAN.md`](AR-2-COMPOSER-PLAN.md).*

This doc owns the **delivery shape** of AR-2 §14's Phase 2. The parent plan (§6/§7/§14)
designs *what* the durable composer envelope is; this doc records *how it lands* — four
independently-committable sub-phases (**2a → 2b → 2c → 2d**), each ending `mix precommit`
green — and resolves the one decision (§15.3) that blocked Phase 2.

It does **not** re-open the architecture. Where the parent plan and this doc disagree, the
parent plan wins on *design*; this doc wins on *sequencing*.

---

## Why Phase 2 is decomposed

Phase 1 (`c7a428a`) shipped the single-run loop with **all composer state in GenServer
memory** — `live`, `artifacts`, `ran`, `prev_route`, `wave_index`. That is the §6
"per-wave runs only, no parent" *alternative*: a crash loses the route, resume is a blind
re-run, the dashboard can't render "the route," and the §10.1 cluster lease has nothing to
claim. Phase 2 (§14) makes **the run a pure function of durable state** (§6): a first-class
parent `WorkflowRun` whose append-only event log carries composer deltas, with each wave a
child `WorkflowRun` linked by `parent_run_id`. A rebooting node folds the parent log,
rebuilds state, and resumes mid-route.

That is far past one commit-ready unit. It touches the `WorkflowRun` schema, a brand-new
encrypted artifact resource, `ReactorRunner`, the `WorkflowEvent` kind enum and its
projection, the composer loop, and `WorkflowRecovery` — plus four distinct plaintext-at-rest
leaks. So it is sliced into four sub-phases, each green and committable on its own. **Nothing
in Phase 2 is dropped** — the later sub-phases are scoped in full below so this doc is
complete, and each gets its own focused plan against the prior sub-phase's landed code.

> **No deferrals within Phase 2.** The four sub-phases together deliver all of
> §6/§7/§14-Phase-2. Some composer event *kinds* (e.g. `wave_paused` / `route_rejected` /
> `stages_invalidated`) have their *producers* in later AR-2 phases by the parent plan's own
> design (gates → Phase 4, reruns → AR-4); Phase 2 builds and tests them at the
> **closed-set + projection + recovery** layer, so the durable substrate and
> crash-correctness are complete now even before those producers exist.

---

## §15.3 — RESOLVED: the `ComposerArtifact` encrypted ref-store

AR-2 §15.3 left two things open: **in-DB values vs refs to a blob store**, and
**encryption** for sensitive artifacts (an `approved-plan` / `diff` may carry secrets). Both
are now decided.

**Decision: an encrypted ref-store as a new Ash resource, `JidoClaw.Orchestration.ComposerArtifact`.**
Artifact *values* live only in this resource's **AshCloak-encrypted** `value` column; every
other surface — the in-memory store, `StageEmission.artifacts`, event payloads, and
`WorkflowRun.result` — carries an **opaque `art_<hex>` ref only**. No artifact value is ever
plaintext at rest. This models the two precedents already in-tree: `Conversations.ToolOutput`
(a ref + value table addressed by an opaque ref) and `WorkflowRun`'s own cloak block
(`workflow_run.ex:52-55`, encrypting `resume_checkpoint` / `replay_inputs`).

The resource is **hand-rolled `use Ash.Resource`** (not the `JidoClaw.Resource` macro — the
macro doesn't forward `extensions:`, exactly as `WorkflowRun` notes at `workflow_run.ex:9-13`),
scoped to the parent composer run, provenance-keyed `name → producer`:

```elixir
use Ash.Resource,
  otp_app: :jido_claw, domain: JidoClaw.Orchestration,
  data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer],
  extensions: [AshCloak]

cloak do
  vault(JidoClaw.Security.Vault)        # the same vault WorkflowRun/SecretRef already boot
  attributes([:value])                  # encrypt EVERY value; column becomes encrypted_value
end

# attrs: ref ("art_<hex>"), name, producer, value (:binary → encrypted), tombstoned (:boolean, false),
#        parent_run_id (:uuid), tenant_id (:string, plain attr — ToolOutput shape, no belongs_to :tenant)
# identity :unique_ref, [:tenant_id, :ref]
# index    [:tenant_id, :parent_run_id, :name]                       (per-run, per-name lookup)
# index    [:tenant_id, :parent_run_id, :name, :producer], unique,
#          where: "tombstoned = false"   (P3: ≤1 ACTIVE ref per {run,name,producer} — makes
#                                          invalidation/replay deterministic; a tombstoned row
#                                          leaves the partial index so a re-add inserts cleanly)
# tenant-scoped (multitenancy :attribute on tenant_id), plus a multitenancy(:bypass) by_id_global
```

- **`available` derives from the store.** A `name` is available iff ≥1 **non-tombstoned**
  producer row exists for it (AR-2 §2/§7). The in-memory store is `name → producer → ref`,
  and `available` is computed from it each tick, never stored independently.
- **Invalidation is a tombstone, not a delete.** `artifacts_invalidated {name, producer}` sets
  `tombstoned: true`. The value behind the ref stays — recovery's fold-replay and old child
  results / audit views hold refs into it (AR-2 §6); pruning ref targets is a separate
  retention concern off the routing path. The force-NULL discipline that the cloaked column
  needs *on update* does not apply: tombstoning flips a plain boolean, never the encrypted
  value.
- **The partial unique index (P3) is load-bearing.** It guarantees the in-memory
  `store[name][producer] = ref` maps to exactly one **active** row, so re-folding and
  crash-replay are deterministic; a tombstoned row leaves the partial index, so a re-add
  inserts cleanly.
- **Values decrypt only at the wave boundary.** `ArtifactContext` resolves a ref → decrypts
  the value → serializes it into the next wave's `:extra_context`. The open §15.3
  sub-question "stored vs reconstructed-from-environment" (e.g. a working-tree `diff`) is
  **out of scope for Phase 2** — everything is stored.

**The store implementation is Phase 2b.** This section records the decision; 2b builds it.

---

## The sub-phase table

Each sub-phase ends `mix precommit` green and is independently committable.

| Sub-phase | Scope | Key files | Done when (green) |
| --- | --- | --- | --- |
| **2a — Parent-run lineage + launch** *(landed by the plan that wrote this doc)* | `WorkflowRun` gains `belongs_to :parent_run` / `has_many :child_runs` (cross-tenant-guarded, indexed, migrated); `ReactorRunner.run/3` gains a `:parent_run_id` opt; a `RouteComposer` split launch (`create_parent_run/1` + `start_composer/2`) creates the parent as `workflow_type: "composer"` and appends its own `run_started`; waves run as children keyed `composer:<parent>:<wave_index>`. Composer state stays in memory. | `workflow_run.ex`, `reactor_runner.ex`, `route_composer.ex`, `workflow_recovery.ex` (no-op guard), migration + snapshot | A composer run creates a `:running` parent; every wave's child carries `parent_run_id` + the idempotency key; the parent reaches a terminal status on finish; a cross-tenant `parent_run_id` is rejected. |
| **2b — `ComposerArtifact` encrypted ref-store** | The §15.3 resource above (incl. the P3 partial-unique index) + migration; rewire `Fold` / `WaveCollect` / `StageEmission` / `ArtifactContext` / `DefaultMapper` so `WaveCollect` persists values→refs and emissions carry refs; in-memory store becomes `name → producer → ref`; `ArtifactContext` resolves+decrypts. **Close every plaintext-at-rest leak (P1) — four persistence points:** (i) `ReactorMiddleware.result_summary/1` writes raw `%StepResult{}` into `step_completed` payloads + `WorkflowStep.output` (`reactor_middleware.ex:365-372`); (ii) `AgentStep` injects the **decrypted** artifact `:extra_context` into `full_task` (`agent_step.ex:65`); (iii) `AgentRunner` persists that task + terminal result via `SubagentTranscript` (`agent_runner.ex:70`, `subagent_transcript.ex:125`); **(iv) the `Recorder` persists the subagent's tool calls/results/reasoning into `messages.content` *and* `messages.metadata`** (`recorder.ex:496,528,575`). Composer waves suppress/digest (i) **and** sanitize **all message writes (content + metadata)** for composer subagent request IDs into placeholder rows — (iii) **and** (iv). The mechanism is an explicit context marker (e.g. `suppress_transcript?: true`) set on the wave's step/tool context **before** child correlation (`agent_runner.ex:69`) and honored by `Recorder` + `SubagentTranscript`; write **sanitized placeholders, not row-suppression**, so durable subagent-context/compaction expectations stay intact (P2). **Narrowing the guarantee to orchestration-tables-only is not acceptable while lifting the fixtures rule** (P1): `messages.content` is **redacted-not-encrypted** (`message.ex:375`), so a narrowed guarantee would leak real sensitive artifacts plaintext in transcripts. So 2b sanitizes *all* subagent message writes into placeholder rows, *then* lifts Phase 1's "non-sensitive fixtures only" rule. | new `composer_artifact.ex`, `fold.ex`, `steps/wave_collect.ex`, `stage_emission.ex`, `artifact_context.ex`, `emit/default_mapper.ex`, `orchestration/reactor_middleware.ex`, `skills/steps/{agent_step,agent_runner}.ex` + `conversations/{subagent_transcript,recorder}.ex` | No artifact value is plaintext in the orchestration tables (WaveCollect return, event payloads, `WorkflowRun.result`, `step_completed`, `WorkflowStep.output`) **or** subagent transcripts (`messages.content` *and* `messages.metadata`); values encrypted at rest; the loop runs identically. |
| **2c — Composer event log + projection + durable loop** | Extend `WorkflowEvent.kind` with the composer kinds — additive (`route_composed`, `wave_started`, `wave_completed`, `signals_published`, `artifacts_produced`, `wave_paused`, `wave_resumed`), subtractive (`signals_retracted`, `stages_invalidated`, `artifacts_invalidated`), and **one parent-terminal kind per loop terminal (P2):** `route_converged`→`:completed`; `route_not_converged` / `route_deadlocked` / `route_budget_exhausted` / `route_failed`→`:failed`; `route_rejected` / `route_abandoned`→`:cancelled` + disposition. Extend `Projection` (`@status_authority_kinds`, `next_status/2`, `status_attrs/3`); add a composer-state fold replaying additive + subtractive deltas in `seq` order. Rewrite the loop to append `route_composed` → `wave_started` (pre-launch) → one-txn `wave_completed` + content events, folding via the existing `Fold.fold/2`. Supervised lifecycle: `DynamicSupervisor` + unique `Registry` keyed by `parent_run_id`, transient restart. | `workflow_event.ex`, `workflow_event/projection.ex`, new `route_composer/projection.ex` (composer-state fold), `route_composer.ex`, `application.ex` | The run's full state is durable in the parent log and re-projectable; in-memory state is a cache of the projection; **every loop terminal (`route_composer.ex` `finish/2`) maps to a distinct composer terminal kind**; an empty-emission wave still records `wave_completed`. |
| **2d — Crash recovery (the payoff)** | `WorkflowRecovery` gains a real `workflow_type: "composer"` branch (replacing 2a's no-op): rebuild state from the log, reconcile child waves first (a boot `:running` child is stranded→`:failed`, never observed), re-launch a `wave_started`-with-no-child wave under the same key, replay a dropped `wave_completed` fold from the completed child result + store, re-`compose_route`, resume from the next wave; synthesize `route_rejected` / `route_abandoned` for a gate decided-then-crashed. | `workflow_recovery.ex`, `route_composer/projection.ex`, tests | A killed mid-route run resumes from the next wave on reboot; subtractive deltas stay applied; a gate-terminal-then-crash synthesizes the parent terminal. |

---

## Cross-cutting guarantees the four sub-phases together must satisfy

These are the AR-2 §14 "done when" criteria for Phase 2, mapped onto the slices so none is
lost between them:

- **P1 — no plaintext artifact value at rest, anywhere.** 2b closes all four persistence
  points (orchestration tables *and* subagent transcripts) and only then lifts the
  non-sensitive-fixtures rule. 2a keeps the fixtures rule (inline values still transit the
  child `WorkflowRun.result`).
- **P2 — durable subagent context survives sanitization.** 2b writes **sanitized
  placeholders**, never row-suppression, so compaction/subagent-transcript expectations hold.
  And every loop terminal gets a **distinct** composer terminal kind (2c) — `:completed` /
  `:failed` / `:cancelled`+disposition — so a recovery fold (2d) can tell *why* a run ended.
- **P3 — deterministic invalidation/replay.** The `ComposerArtifact` partial-unique index
  (2b) guarantees ≤1 active ref per `{run, name, producer}`; the parent-terminal error string
  is formatted from the `{terminal, reason}` pair (2a `finish/2`), never `reason` alone, so a
  nil-reason terminal (`:not_converged` / `:deadlock`) never stores the literal `"nil"`.
- **Crash-correctness (2d):** a killed mid-route run resumes from the next wave; a finished
  child wave whose parent `wave_completed` never landed is reconciled by replaying the fold
  from the child result + store (matched by `wave_index`); a `wave_started` with no child row
  re-launches under the same `composer:<parent>:<wave_index>` key; a gate-terminal-then-crash
  synthesizes the parent terminal; subtractive deltas stay applied across the rebuild.

---

## Phase 2a — what landed

**Goal:** every composer run is a real (supervised-later, 2c) parent `WorkflowRun`
(`workflow_type: "composer"`, flipped to `:running` by its own `run_started`), and each wave
is a *child* run linked by `parent_run_id` and keyed by a deterministic
`composer:<parent>:<wave_index>` idempotency key. This establishes the lineage +
idempotent-wave correlation that 2b–2d build on. **State stays in memory** (event
log/projection = 2c; recovery = 2d). 2a keeps Phase 1's **non-sensitive-fixture-only** rule
(inline values still transit the child `WorkflowRun.result`); 2b removes inline values
entirely.

### Schema (`WorkflowRun`)

- `belongs_to :parent_run, __MODULE__` with `allow_nil?(true)` (mandatory — the style test +
  AshCredo) and `attribute_writable?(true)` (Ash's auto-defined `parent_run_id` FK is set at
  create; **no** `define_attribute?(false)`, unlike the tenant/user/project belongs_to — we
  *want* Ash to define this column). `has_many :child_runs, __MODULE__,
  destination_attribute: :parent_run_id`.
- `:parent_run_id` added to the `:create` accept list.
- A second `:create` change running `CrossTenantFk.validate/2` in a `before_action` (the
  `block.ex` `Changes.ValidateCrossTenant` precedent), spec
  `[{:parent_run_id, WorkflowRun, JidoClaw.Orchestration}]`. The validator loads through the
  existing `by_id_global` and **skips nil FKs**, so a root composer parent (no parent)
  passes.
- `index([:tenant_id, :parent_run_id])` in `postgres → custom_indexes`.
- Migration + snapshot generated by `ash_postgres.generate_migrations
  add_workflow_run_parent_lineage`.

### `ReactorRunner.run/3`

One additive opt: `parent_run_id: Keyword.get(opts, :parent_run_id)` threaded into
`create_run`'s attrs (`nil` for ordinary reactor runs → a root run). No spec change, no
change to the `idempotency_key` machinery (already complete).

### `RouteComposer`

- **Split launch (P1).** `create_parent_run/1` does the durable genesis in one
  `Ash.transact([WorkflowRun, WorkflowEvent], …)`: create the parent (`workflow_type:
  "composer"`, genesis `:pending`), append `run_started` (reusing
  `next_status(:pending, :run_started) → :running`, so **no composer-specific start kind** is
  needed and the parent never touches `ReactorMiddleware`), then reload to `:running`. A
  reload failure *after* `run_started` committed terminalizes the now-ownerless `:running`
  parent (`:composer_reload_failed`) before returning the error. `start_composer/2` starts the
  GenServer with `parent_run_id: parent.id` — **`run_sync` uses unlinked `GenServer.start/3` +
  `Process.monitor`**, while 2c's supervised path will use `start_link/1` under the
  `DynamicSupervisor`. The GenServer must never start before `create_parent_run/1` commits
  (`init/1` returns `{:continue, :tick}` and runs waves immediately). A start failure after
  the parent exists terminalizes it (`:composer_start_failed`).
- **`run_wave` threading.** Each wave runs with `parent_run_id: state.parent_run_id` and
  `idempotency_key: "composer:#{parent}:#{wave_index}"`. The return match is **total**: a
  `{:ok, {:existing_run, _id}, run}` hit (unreachable in 2a's linear loop, but reachable for
  2d) folds the child's durable emission iff `:completed`, else fails the wave.
- **`finish/2` appends the parent terminal FIRST, then notifies (P1).** `:converged` →
  reload-guarded `run_completed` (`%{result: summary_subset}` → `:completed`); every other
  terminal → reload-guarded `run_failed` (→ `:failed`), with the error string formatted from
  the `{terminal, reason}` pair (P3). A terminal-write failure notifies
  `{:terminalize_failed, reason}`, surfaced by `run_sync` as `{:error, {:terminalize_failed,
  reason}}` — never a falsely-successful `:done`. *(2c swaps these for the semantically-named
  `route_converged` / `route_not_converged` / `route_deadlocked` / `route_budget_exhausted` /
  `route_failed` kinds, all projecting onto the same statuses.)*
- **One reload-guarded parent-terminal helper (P2)**, modelled on
  `ReactorRunner.ensure_failed/3`: reload the parent, append the terminal only from a
  non-terminal status, an already-terminal reload is `:ok`. `WorkflowLog.append/4` *does* error
  on an already-terminal parent (the projection's `:illegal` transition rolls it back), so a
  raw append is **not** a harmless no-op — every parent-terminal write routes through the guard
  so a `finish`-vs-timeout race never double-writes. On the abnormal paths
  (reload/start/timeout/crash) the **original** error wins and a guard failure is logged
  loudly; only `finish/2`'s normal path surfaces `{:terminalize_failed, _}`.
- **`run_sync/1` contract widened (P2):** `{:ok, summary()} | {:error, :timeout} | {:error,
  {:start_failed, reason}} | {:error, {:crashed, reason}} | {:error, {:terminalize_failed,
  reason}}`. Unlinked + monitored, so a composer crash surfaces as a handled `:DOWN`, never a
  linked exit killing the caller. (A full node reboot — caller and composer both gone — is the
  one path 2a can't terminalize live; the §recovery no-op guard keeps boot recovery from
  *failing* such a parent, and 2d rebuilds + resumes it.)

### `WorkflowRecovery` minimal composer guard

A composer parent sits `:running` for the whole run with no checkpoint, which the shipped
`classify/1` would mis-classify as `:stranded → :failed` at boot. Until 2d's real
rebuild+resume branch, a **no-op guard scoped to `:running`** ahead of the status heads (a
`:pending`/`:awaiting_approval` composer falls through, so a never-started `:pending`
composer is still failed):

```elixir
defp classify(%WorkflowRun{workflow_type: "composer", status: :running}), do: :composer  # only the valid 2a state
# reconcile_branch(:composer, run) -> emit(run, :composer)              # observe-only
# pending/awaiting composer rows fall through to the status heads (a never-started :pending composer is still failed)
```

(Recovery is disabled in test, so this guards dev/prod, not the suite.)

---

## After 2a

2b–2d each get a **fresh focused plan** against the prior sub-phase's landed code, in order:
**2b** `ComposerArtifact` encrypted ref-store (the §15.3 implementation) → **2c** composer
event kinds + projection + durable append/project loop + supervised lifecycle → **2d**
`WorkflowRecovery` composer branch (resume mid-route on reboot). This doc carries their full
scope so nothing is dropped.
