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
projection, the composer loop, and `WorkflowRecovery` — plus seven distinct plaintext-at-rest
sinks. So it is sliced into four sub-phases, each green and committable on its own. **Nothing
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
`WorkflowRun.result` — carries an **opaque `art_<hex>` ref only**. The one surface that would
otherwise hold a *second* encrypted copy — a child wave's `WorkflowRun.replay_inputs`, which
captures the wave's `:extra_context` (`reactor_runner.ex:276`) — is **omitted for composer
waves** (see the wave-boundary bullet below). So no artifact value is ever plaintext at rest,
and no value is duplicated outside the ref-store. This models the two precedents already
in-tree: `Conversations.ToolOutput` (a ref + value table addressed by an opaque ref) and
`WorkflowRun`'s own cloak block (`workflow_run.ex:52-55`, encrypting `resume_checkpoint` /
`replay_inputs`).

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

# attrs: ref ("art_<hex>"), name, producer,
#        value (:binary → encrypted; a versioned `term_to_binary({@artifact_version, term})`
#               envelope, decoded via `binary_to_term(blob, [:safe])` + a version-tag match, and
#               size-capped by `composer_artifact_max_bytes`; mirrors the replay_inputs /
#               resume_checkpoint envelopes — NOT a raw `inspect`/`to_string`. The `[:safe]`
#               decode is sound only because the term is hard-normalized to string keys at the
#               store boundary (the string-key-normalizer bullet below) — an atom key would
#               otherwise raise on a post-reboot decode (2d), where the new VM's atom table is empty),
#        state (:atom, one_of [:pending, :active, :tombstoned], default :pending),
#        child_run_id (:uuid), wave_index (:integer)   (provenance for promotion + recovery reconcile),
#        parent_run_id (:uuid), tenant_id (:string, plain attr — ToolOutput shape, no belongs_to :tenant)
# identity :unique_ref, [:tenant_id, :ref]
# index    [:tenant_id, :parent_run_id, :name]                       (per-run, per-name lookup)
# index    [:tenant_id, :parent_run_id, :name, :producer], unique,
#          where: "state = 'active'"     (P3: ≤1 ACTIVE ref per {run,name,producer} — makes
#                                          invalidation/replay deterministic; pending AND tombstoned
#                                          rows leave the partial index, so an orphaned crash-attempt
#                                          row never blocks a re-launch and a re-add inserts cleanly)
# :create  validates parent_run_id belongs to tenant_id via `CrossTenantFk.validate/2`
#          ({:parent_run_id, WorkflowRun, JidoClaw.Orchestration}) in a before_action — the same
#          WorkflowRun-lineage (`validate_cross_tenant.ex`) / ToolOutput-session guard, so a confused
#          producer can't cross-link a parent run in another tenant
# tenant-scoped (multitenancy :attribute on tenant_id), plus a multitenancy(:bypass) by_id_global
#
# actions — each ONE transition, exposed through a `code_interface` and backed by focused tests
#           (the `Conversations.ToolOutput` precedent, not scattered ad-hoc `Ash.update`s):
#   create :store_pending     insert a :pending row {ref,name,producer,value,parent_run_id,
#                             child_run_id,wave_index}; a before_action runs the string-key
#                             normalizer over `value` *before* the cloak encrypts it. WaveCollect's call.
#   update :activate_for_wave :pending → :active for a {parent_run_id, wave_index}, AND tombstone any
#                             superseded prior-:active row for the same {run,name,producer} (Fold's
#                             last-writer-wins, made durable). The one mutation 2c's wave_completed
#                             transaction calls; 2d's fold-replay calls it too.
#   update :tombstone_active  :active → :tombstoned for {run,name,producer} (artifacts_invalidated)
#   read   :resolve_ref       ref → row with the AshCloak-decrypted `value`, IRRESPECTIVE of state
#                             (ArtifactContext's resolver — a :pending 2b row resolves like an :active one)
#   read   :pending_for_wave / :active_for_run   recovery reconcile + fold rebuild (2c/2d)
#   read   :by_id_global      multitenancy(:bypass), for the cross-tenant guard lookups
```

- **`available` derives from the in-memory fold, not the DB `state` column.** A `name` is available
  iff the in-memory `name → producer → ref` store holds a live entry for it (AR-2 §2/§7) — computed
  from that store each tick (Phase 1's fold, rebuilt from the parent log in 2c), **never by scanning
  `ComposerArtifact` rows directly**. The DB `state` (`:pending`/`:active`/`:tombstoned`) is the
  *durability + recovery* record, deliberately decoupled from in-memory availability: 2b inserts refs
  `:pending` and the loop runs off the fold, so a crashed wave's not-yet-promoted rows can never
  surface as phantom-available; 2c then ties the two together, making a ref `:active` exactly when the
  fold's wave lands `wave_completed` in the log.
- **A ref's lifecycle is parent-log-gated (P1/P3).** `WaveCollect` inserts a ref **`:pending`** via
  `store_pending` as the wave's step runs — a plain insert, **not** part of any wave-spanning DB
  transaction (there is none: `ReactorRunner` runs the wave through `RunExecution.run_killable`
  (`reactor_runner.ex:508`), and the child's `run_completed` is appended by middleware *afterward*
  (`reactor_middleware.ex:209`)). No atomicity is needed there precisely because a `:pending` row is
  inert. The ref is promoted **`:pending → :active`** only in the parent's one-transaction
  `wave_completed` + `artifacts_produced` append (2c) — the one place a real `Ash.transact` exists —
  which also tombstones any superseded prior-active row for the same `{run, name, producer}` (Fold's
  last-writer-wins, made durable). So **a ref is active iff the parent log records its producing
  wave** — the same "state is a function of the durable log" discipline the whole envelope rests on,
  rather than a child-side insert the parent hasn't yet acknowledged. A wave that inserts pending rows
  then crashes before `wave_completed` leaves them inert (never active, never available, outside the
  active partial index); 2d reconciles them.
- **Invalidation is a tombstone, not a delete.** `artifacts_invalidated {name, producer}` moves
  the active row `:active → :tombstoned`. The value behind the ref stays — recovery's fold-replay
  and old child results / audit views hold refs into it (AR-2 §6); pruning ref targets is a
  separate retention concern off the routing path. The force-NULL discipline that the cloaked
  column needs *on update* does not apply: a state transition flips a plain atom, never the
  encrypted value.
- **The partial unique index (P3) is load-bearing.** Keyed `where state = 'active'`, it
  guarantees the in-memory `store[name][producer] = ref` maps to exactly one **active** row, so
  re-folding and crash-replay are deterministic; pending and tombstoned rows leave the partial
  index, so an orphaned crash-attempt row never blocks a re-launch and a re-add inserts cleanly.
- **String keys are hard-normalized at the store boundary (P3).** The `[:safe]` decode is sound
  only if no value carries atom keys — but `DefaultMapper.coerce_key/1` (`default_mapper.ex:172`)
  currently preserves atom keys, and `binary_to_term(blob, [:safe])` raises on an unknown atom on a
  post-reboot decode (2d), where the new VM's atom table is empty. So 2b adds a recursive string-key
  normalizer in two places: `DefaultMapper.coerce_key/1` stringifies atom keys via `Atom.to_string/1`
  (the no-atom-creation direction, never `String.to_atom/1`) so emissions are string-keyed end-to-end,
  and `store_pending`'s `before_action` re-asserts it over `value` before the cloak encrypts — a
  belt-and-suspenders guarantee the decode is never handed a novel atom regardless of producer.
- **Values decrypt only at the wave boundary — and are not re-persisted.** `ArtifactContext`
  resolves a ref → decrypts the value (via `:resolve_ref`, which loads the AshCloak-decrypted `value`
  **irrespective of the row's `state`**, so a `:pending` 2b row resolves exactly like an `:active`
  2c+ one) → serializes it into the next wave's `:extra_context`. That decrypted `:extra_context`
  must not flow back to rest, and 2b closes both paths that would leak it: (1) the *artifact-value*
  copy — composer waves pass a `ReactorRunner.run/3` opt that **omits `replay_inputs`**
  (`reactor_runner.ex:276`, the lone surface that would otherwise hold a second *encrypted* copy) —
  which costs nothing, since a composer wave carries no `definition_hash` and so is not
  standalone-replayable anyway; the parent run + event log is the sole replay/recovery unit (2d); and
  (2) the *derived* copies a subagent emits while working from that context — its task, tool
  calls/results, reasoning, and tool output — which land in the transcript, audit, trace, and
  tool-output sinks and are sanitized per P1's seven persistence points (the 2b row). The open §15.3
  sub-question "stored vs reconstructed-from-environment" (e.g. a working-tree `diff`) is **out of
  scope for Phase 2** — everything is stored.

**The store implementation is Phase 2b.** This section records the decision; 2b builds it.

---

## The sub-phase table

Each sub-phase ends `mix precommit` green and is independently committable.

| Sub-phase | Scope | Key files | Done when (green) |
| --- | --- | --- | --- |
| **2a — Parent-run lineage + launch** *(landed by the plan that wrote this doc)* | `WorkflowRun` gains `belongs_to :parent_run` / `has_many :child_runs` (cross-tenant-guarded, indexed, migrated); `ReactorRunner.run/3` gains a `:parent_run_id` opt; a `RouteComposer` split launch (`create_parent_run/1` + `start_composer/2`) creates the parent as `workflow_type: "composer"` and appends its own `run_started`; waves run as children keyed `composer:<parent>:<wave_index>`. Composer state stays in memory. | `workflow_run.ex`, `reactor_runner.ex`, `route_composer.ex`, `workflow_recovery.ex` (no-op guard), migration + snapshot | A composer run creates a `:running` parent; every wave's child carries `parent_run_id` + the idempotency key; the parent reaches a terminal status on finish; a cross-tenant `parent_run_id` is rejected. |
| **2b — `ComposerArtifact` encrypted ref-store** | The §15.3 resource above (incl. the `:pending → :active → :tombstoned` lifecycle as the named actions `store_pending`/`activate_for_wave`/`tombstone_active`/`resolve_ref`, the active-keyed P3 partial-unique index, the versioned value-encoding envelope, the **string-key normalizer**, and the `parent_run_id` cross-tenant guard) + migration; rewire `Fold` / `WaveCollect` / `StageEmission` / `ArtifactContext` / `DefaultMapper` so `WaveCollect` persists values→refs as **`:pending`** rows (via `store_pending`) and emissions carry refs; in-memory store becomes `name → producer → ref`; `ArtifactContext` resolves+decrypts via `:resolve_ref` **irrespective of `state`** (so `:pending` 2b rows resolve identically to `:active` 2c+ ones). Availability still derives from the in-memory fold, so the loop runs identically even though nothing promotes rows to `:active` until 2c. **Composer waves omit `replay_inputs`** via a new `ReactorRunner.run/3` opt (`reactor_runner.ex:276`), so the decrypted `:extra_context` leaves no second encrypted copy at rest. **Close every plaintext-at-rest leak (P1) — seven persistence points:** (i) `ReactorMiddleware.result_summary/1` writes raw `%StepResult{}` into `step_completed` payloads + `WorkflowStep.output` (`reactor_middleware.ex:365-372`); (ii) `AgentStep` injects the **decrypted** artifact `:extra_context` into `full_task` (`agent_step.ex:65`); (iii) `AgentRunner` persists that task + terminal result via `SubagentTranscript` (`agent_runner.ex:70`, `subagent_transcript.ex:125`); **(iv) the `Recorder` persists the subagent's tool calls/results/reasoning into `messages.content` *and* `messages.metadata`** (`recorder.ex:496,528,575`); **(v) `Audit.SignalListener` writes the subagent's tool-call `arguments` into `Audit.Event.payload`** (`signal_listener.ex:114-124`, a plain public `:map`); **(vi) `Trace` persists subagent span metadata into `trace_events.metadata`** (`trace/persistence.ex:139-159`); **(vii) `OutputShaper.Store` writes the subagent's `run_command`/`git_diff` output into `ToolOutput.content`** (`tool_output.ex:180`). Points (iv)–(vii) are **redacted-not-encrypted**, and for the artifacts in scope (`approved-plan`, `diff` — sensitive prose, not pattern-matchable secrets) redaction catches ~nothing, so each leaks as plainly as `messages.content`. Composer waves suppress/digest (i)–(ii) **and** sanitize every derived write — (iii)–(vii) — for composer subagent request IDs into placeholders/digests. The mechanism is an explicit marker (`suppress_transcript?: true`) set on the wave's step/tool context **before** child correlation (`agent_runner.ex:69`), reaching its sinks by **two carrier paths**. **(a) Async signal-consumer sinks** — `Recorder`→messages (iv) and `Audit.SignalListener`→audit (v) — resolve scope from a `request_id` and so read the marker *from the resolved scope*. That requires it to be **both** a **durable field on the `RequestCorrelation` row** (added to its `:register` accept-list + the `register_child_correlation/1` → `register_correlation/6` scope map, `jido_claw.ex:305,370`) **and** mirrored into the **`RequestCorrelation.Cache` stored shape** (`cache.ex:22-41`), its cache writes, and the cache-miss rehydrate — in *both* `recorder.ex:797-820` *and* `signal_listener.ex:137-158` — exactly as `agent_id`/`subagent` already are. Both consumers hit the **cache first**, so a marker only on the durable row would be invisible on the normal cache-hit path; and the durable row is load-bearing for the cache-*miss* path, since a Recorder/listener restart between a tool signal and its write would otherwise rehydrate scope **without** the marker and write sensitive content plaintext. **(b) Inline execution-path sinks** — `Trace` (vi) and `OutputShaper.Store` (vii) — run *inside* the subagent's tool/agent execution, so they read `suppress_transcript?` directly from the live tool/step context (no scope round-trip); 2b must **propagate** the marker into the subagent's per-tool context so its own tool calls inherit suppression. Every sink writes **sanitized placeholders/digests, never row-suppression**, so durable subagent-context/compaction expectations stay intact (P2). **Test both carriers:** the cache-hit path, the cache-miss path (evict + rehydrate, for *both* `Recorder` and `Audit`), and the inline-context path (`Trace` + `ToolOutput`). **The guarantee is not narrowable** (P1): every durable sink above is **redacted-not-encrypted** (`message.ex:375` for `messages.content`; the audit/trace/tool-output sinks likewise), so any narrowing would leak real sensitive artifacts plaintext. So 2b sanitizes composer-subagent writes across *all seven* sinks, *then* lifts Phase 1's "non-sensitive fixtures only" rule. | new `composer_artifact.ex`, `fold.ex`, `steps/wave_collect.ex`, `stage_emission.ex`, `artifact_context.ex`, `emit/default_mapper.ex`, `orchestration/{reactor_middleware,reactor_runner}.ex`, `conversations/resources/request_correlation.ex` + `conversations/request_correlation/cache.ex` (+ `jido_claw.ex` correlation helpers), `skills/steps/{agent_step,agent_runner}.ex`, `conversations/{subagent_transcript,recorder}.ex`, `audit/signal_listener.ex`, `trace/{collector,policy}.ex`, `tools/output_shaper.ex` | No artifact value is plaintext in the orchestration tables (WaveCollect return, event payloads, `WorkflowRun.result`, `step_completed`, `WorkflowStep.output`), subagent transcripts (`messages.content` *and* `messages.metadata`), **audit rows (`Audit.Event.payload`), trace events (`trace_events.metadata`), or the tool-output cache (`ToolOutput.content`)** for composer subagent request IDs, and no second *encrypted* copy survives in any child wave's `replay_inputs`; values encrypted at rest; `ComposerArtifact` rows insert `:pending` via `store_pending` and resolve via `:resolve_ref` regardless of state (promotion is 2c); the `suppress_transcript?` marker is read from the cache on a hit, survives a Recorder/Audit cache-miss via the durable row, and is read inline from the tool context by Trace + ToolOutput; the loop runs identically. |
| **2c — Composer event log + projection + durable loop** | Extend `WorkflowEvent.kind` with the composer kinds — additive (`route_composed`, `wave_started`, `wave_completed`, `signals_published`, `artifacts_produced`, `wave_paused`, `wave_resumed`), subtractive (`signals_retracted`, `stages_invalidated`, `artifacts_invalidated`), and **one parent-terminal kind per loop terminal (P2):** `route_converged`→`:completed`; `route_not_converged` / `route_deadlocked` / `route_budget_exhausted` / `route_failed`→`:failed`; `route_rejected` / `route_abandoned`→`:cancelled` + disposition. Extend `Projection` (`@status_authority_kinds`, `next_status/2`, `status_attrs/3`); add a composer-state fold replaying additive + subtractive deltas in `seq` order. Rewrite the loop to append `route_composed` → `wave_started` (pre-launch) → one-txn `wave_completed` + content events, folding via the existing `Fold.fold/2`. **That same `wave_completed` + `artifacts_produced` transaction promotes the completed wave's `:pending` `ComposerArtifact` refs → `:active` via `activate_for_wave`** (tombstoning any superseded prior-active row for the same `{run, name, producer}`), so the projected active-row set is always a function of the durable log — a ref is active iff the log records its wave. Supervised lifecycle: `DynamicSupervisor` + unique `Registry` keyed by `parent_run_id`, transient restart. | `workflow_event.ex`, `workflow_event/projection.ex`, new `route_composer/projection.ex` (composer-state fold), `route_composer.ex`, `composer_artifact.ex`, `application.ex` | The run's full state is durable in the parent log and re-projectable; in-memory state is a cache of the projection; a wave's refs flip to `:active` exactly when its `wave_completed` lands; **every loop terminal (`route_composer.ex` `finish/2`) maps to a distinct composer terminal kind**; an empty-emission wave still records `wave_completed`. |
| **2d — Crash recovery (the payoff)** | `WorkflowRecovery` gains a real `workflow_type: "composer"` branch (replacing 2a's no-op): rebuild state from the log, reconcile child waves first (a boot `:running` child is stranded→`:failed`, never observed), then re-launch by **two distinct rules** keyed on what the log + child rows show. **(1) `wave_started` resolving to no child row** — the BEAM died after the `wave_started` append but before `run/3` created the child — re-launches under the **same** `composer:<parent>:<wave_index>` key; `run/3` materializes it fresh and idempotently. **(2) `wave_started` whose child exists and recovered to `:failed`** is **not** re-runnable under that key — `ReactorRunner` returns the existing run on a key hit (`reactor_runner.ex:304`) — so, since a `:failed` child never wrote `wave_completed` and its stages are therefore absent from the rebuilt `ran`, re-`compose_route` re-derives those stages and dispatches them under a **fresh `wave_index`**, leaving the `:failed` child a harmless orphan told apart by `wave_index` (parent plan §recovery, `AR-2-COMPOSER-PLAN.md:593-596`). Replay a dropped `wave_completed` fold from the completed child result + store (which **promotes** that wave's `:pending` refs → `:active` via `activate_for_wave`, matched by `wave_index`/`child_run_id`), then resume from the next wave; synthesize `route_rejected` / `route_abandoned` for a gate decided-then-crashed. A crashed-mid-wave's orphaned `:pending` `ComposerArtifact` rows (refs inserted, but `wave_completed` never landed) are left **inert** — never promoted, never available, outside the active partial index — so the re-launch's `WaveCollect` re-inserts cleanly (under the same key for rule 1, under a fresh `wave_index` for rule 2). | `workflow_recovery.ex`, `route_composer/projection.ex`, `composer_artifact.ex`, tests | A killed mid-route run resumes from the next wave on reboot; a `wave_started`-with-no-child re-launches under the same key, while a `:failed` child re-dispatches its stages under a **fresh `wave_index`** (the old key would just return the existing `:failed` run); subtractive deltas stay applied; orphaned `:pending` artifact rows from a crashed wave never block re-launch and never surface as available; a gate-terminal-then-crash synthesizes the parent terminal. |

---

## Cross-cutting guarantees the four sub-phases together must satisfy

These are the AR-2 §14 "done when" criteria for Phase 2, mapped onto the slices so none is
lost between them:

- **P1 — no plaintext artifact value at rest, anywhere, and no duplicated copy.** 2b closes all
  **seven** persistence points — orchestration tables, subagent transcripts (`messages.content`
  *and* `messages.metadata`), audit rows (`Audit.Event.payload`), trace events
  (`trace_events.metadata`), and the tool-output cache (`ToolOutput.content`) — **omits
  `replay_inputs` for composer waves** (the lone surface that would otherwise hold a second
  *encrypted* copy outside the ref-store), and makes the suppression marker **both a durable
  `RequestCorrelation` field *and* a mirror in the `RequestCorrelation.Cache`** so neither the normal
  cache-hit path nor a Recorder/Audit cache-miss rehydrate can silently un-suppress a sensitive write
  — and only then lifts the non-sensitive-fixtures rule. The marker reaches its sinks by two carriers:
  the **async signal consumers** (`Recorder`, `Audit.SignalListener`) read it from the resolved scope
  (cache → durable row), while the **inline execution-path** sinks (`Trace`, `OutputShaper`) read it
  from the live tool context. "Anywhere" is load-bearing: every one of these sinks is
  **redacted-not-encrypted**, and the in-scope artifacts (`approved-plan`, `diff`) are sensitive prose
  that redaction does not catch — so a narrowed guarantee would leak them plaintext. 2a keeps the
  fixtures rule (inline values still transit the child `WorkflowRun.result`).
- **P2 — durable subagent context survives sanitization.** 2b writes **sanitized
  placeholders**, never row-suppression, so compaction/subagent-transcript expectations hold.
  And every loop terminal gets a **distinct** composer terminal kind (2c) — `:completed` /
  `:failed` / `:cancelled`+disposition — so a recovery fold (2d) can tell *why* a run ended.
- **P3 — deterministic invalidation/replay.** The `ComposerArtifact` partial-unique index
  (2b, keyed `where state = 'active'`) guarantees ≤1 active ref per `{run, name, producer}`, and
  a ref reaches `:active` **only** via the parent's `wave_completed` transaction (2c) — so the
  active set is always a function of the durable log, never of a child-side insert a crash could
  strand. The parent-terminal error string is formatted from the `{terminal, reason}` pair (2a
  `finish/2`), never `reason` alone, so a nil-reason terminal (`:not_converged` / `:deadlock`)
  never stores the literal `"nil"`.
- **Crash-correctness (2d):** a killed mid-route run resumes from the next wave; a finished
  child wave whose parent `wave_completed` never landed is reconciled by replaying the fold
  from the child result + store (matched by `wave_index`), which promotes that wave's `:pending`
  refs → `:active`; a crashed-mid-wave's orphaned `:pending` refs stay inert (never promoted,
  never available) so the re-launch inserts cleanly. Re-launch follows two rules: a `wave_started`
  with **no child row** re-launches under the **same** `composer:<parent>:<wave_index>` key (`run/3`
  materializes it idempotently), while a child that **exists and recovered to `:failed`** is
  re-dispatched by re-`compose_route` under a **fresh `wave_index`** — the same key would just return
  the existing `:failed` run (`reactor_runner.ex:304`), so the prior child is left a harmless orphan
  told apart by `wave_index`. A gate-terminal-then-crash synthesizes the parent terminal; subtractive
  deltas stay applied across the rebuild.

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
