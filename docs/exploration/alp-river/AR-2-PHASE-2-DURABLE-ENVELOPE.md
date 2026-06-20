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
projection, the composer loop, and `WorkflowRecovery` — plus six distinct plaintext-at-rest
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
Artifact *values* live **at rest** only in this resource's **AshCloak-encrypted** `value` column; every
other **durable/platform-managed** surface — the in-memory store, `StageEmission.artifacts`, event payloads, and
`WorkflowRun.result` — carries an **opaque `art_<hex>` ref only**. (Live *execution* context is the deliberate
exception, handled explicitly below: a wave's `:extra_context` and the subagent's `full_task` transiently hold
the **decrypted** value while the wave runs — resolved at the wave boundary, never re-persisted; see the
decrypt-only-at-the-wave-boundary bullet.) The one surface that would
otherwise hold a *second* encrypted copy — a child wave's `WorkflowRun.replay_inputs`, which
captures the wave's `:extra_context` (`reactor_runner.ex:276`) — is **omitted for composer
waves** (see the wave-boundary bullet below). So no artifact value is ever plaintext at rest **in any
platform-managed store** (orchestration, conversation, audit, trace, tool-output), and no value is
duplicated outside the ref-store. This models the two precedents already
in-tree: `Conversations.ToolOutput` (a ref + value table addressed by an opaque ref) and
`WorkflowRun`'s own cloak block (`workflow_run.ex:52-55`, encrypting `resume_checkpoint` /
`replay_inputs`).

The resource is **hand-rolled `use Ash.Resource`** (not the `JidoClaw.Resource` macro — the
macro doesn't forward `extensions:`, exactly as `WorkflowRun` notes at `workflow_run.ex:9-13`; so,
like `WorkflowRun`, it must also hand-copy the tenant policy block the macro would otherwise generate —
`resource.ex:67-79`),
scoped to the parent composer run, provenance-keyed `name → producer`:

```elixir
use Ash.Resource,
  otp_app: :jido_claw, domain: JidoClaw.Orchestration,
  data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer],
  extensions: [AshCloak]

# Hand-rolled ⇒ the standard tenant policy block must be copied in (the `JidoClaw.Resource`
# macro's generated policies don't apply) — mirrors WorkflowRun (`workflow_run.ex:23-35`) and
# the macro template (`resource.ex:67-79`):
policies do
  bypass action([:by_id_global]) do
    authorize_if(always())
  end

  policy action_type([:create, :update, :destroy]) do
    authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
  end

  # `activate_for_wave` is a GENERIC action (type `:action`), matched by NEITHER clause above —
  # and under `Ash.Policy.Authorizer` an action matching NO policy is forbidden by default, so it
  # needs its own clause. `ActorTenantMatches` already handles the generic-action `Ash.ActionInput`
  # (`actor_tenant_matches.ex:29`); the commit helper builds the input with `tenant:`/`actor:`, so the
  # tenant match holds. (WorkflowRun — the copied precedent — has no generic action, so its block omits this.)
  policy action_type(:action) do
    authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
  end

  policy action_type(:read) do
    authorize_if(expr(tenant_id == ^actor(:tenant_id)))
  end
end

cloak do
  vault(JidoClaw.Security.Vault)        # the same vault WorkflowRun/SecretRef already boot
  attributes([:value])                  # encrypt EVERY value; column becomes encrypted_value
end

# attrs: ref ("art_<hex>"), name, producer,
#        value (:binary, allow_nil?: true → encrypted; a versioned `term_to_binary({@artifact_version, term})`
#               envelope, decoded via `binary_to_term(blob, [:safe])` + a version-tag match, and
#               size-capped by `composer_artifact_max_bytes`; mirrors the replay_inputs /
#               resume_checkpoint envelopes — NOT a raw `inspect`/`to_string`. The `[:safe]`
#               decode is sound only because the term is hard-normalized to carry no NOVEL atoms —
#               string keys, and non-JSON atom values coerced to strings (the no-novel-atom normalizer
#               bullet below); `true`/`false`/`nil` stay (always interned, so `[:safe]` accepts them),
#               but a user-defined atom would otherwise raise on a post-reboot decode (2d), where the
#               new VM holds only built-in/preloaded atoms),
#        state (:atom, one_of [:pending, :active, :tombstoned], default :pending),
#        child_run_id (:uuid), wave_index (:integer)   (provenance for promotion + recovery reconcile),
#        parent_run_id (:uuid), tenant_id (:string, plain attr — ToolOutput shape, no belongs_to :tenant)
# identity :unique_ref, [:tenant_id, :ref]
# index    [:tenant_id, :parent_run_id, :name]                       (per-run, per-name lookup)
# index    [:tenant_id, :parent_run_id, :name, :producer], unique,
#          name: "composer_artifacts_active_ref_index",
#          where: "state = 'active'"     (P3: AT MOST ONE active ref per {run,name,producer} — makes
#                                          invalidation/replay deterministic; pending AND tombstoned
#                                          rows leave the partial index, so an orphaned crash-attempt
#                                          row never blocks a re-launch and a re-add inserts cleanly.
#                                          A **named custom partial index, NOT an Ash identity-with-where**:
#                                          uniqueness is held by 2c's commit helper — `activate_for_wave`
#                                          tombstones the prior active row in the SAME transaction *before*
#                                          promoting the new one (the index is non-deferrable, so ordering
#                                          matters) — so a unique violation is never expected in normal
#                                          operation; the index is a backstop/invariant-enforcer, and a
#                                          violation signals a logic bug to surface, not a race to swallow)
# :create  validates parent_run_id belongs to tenant_id via `CrossTenantFk.validate/2`
#          ({:parent_run_id, WorkflowRun, JidoClaw.Orchestration}) in a before_action — the same
#          WorkflowRun-lineage (`validate_cross_tenant.ex`) / ToolOutput-session guard, so a confused
#          producer can't cross-link a parent run in another tenant
# tenant-scoped (multitenancy :attribute on tenant_id), plus a multitenancy(:bypass) by_id_global
#
# actions — single-transition row actions exposed through a `code_interface` and backed by focused
#           tests (the `Conversations.ToolOutput` precedent, not scattered ad-hoc `Ash.update`s),
#           plus ONE **internal-only** domain/generic action (`activate_for_wave`, marked **`public?(false)`** + not exposed via
#           `code_interface` for standalone use — see its note) orchestrating the multi-row wave
#           promotion inside 2c's `Ash.transact`:
#   create :store_pending     insert a :pending row {ref,name,producer,value,parent_run_id,
#                             child_run_id,wave_index}. The raw artifact term enters via a **separate,
#                             non-cloaked argument** (e.g. `:term`), NOT via `:value`: AshCloak rewrites the
#                             accepted cloaked `:value` into an argument of the **attribute type, `:binary`**
#                             (`set_up_encryption.ex:104`), so `:value` only ever carries the *encoded* blob —
#                             normalizing `:value` itself would be normalizing a binary. So the change (in its
#                             **`change/3` body**) normalizes `:term` (no-novel-atom), `term_to_binary`-encodes
#                             the versioned envelope, then **unconditionally** `Ash.Changeset.force_set_argument(:value, blob)`,
#                             overwriting any caller-supplied `:value`.
#                             **The cloaked `:value` attribute MUST be `allow_nil?: true` (P1 — load-bearing, not
#                             cosmetic)** — and **`:term` is itself `allow_nil?: true`**, with its *suppliedness* (not non-nil-ness) validated by the action via `fetch_argument/2` (see the nil-artifact note below). AshCloak rebuilds
#                             the accepted cloaked `:value` as an action argument carrying the attribute's own
#                             nullability (`set_up_encryption.ex:96-98`, `allow_nil?: attr.allow_nil?`), and Ash runs
#                             `require_arguments` (`changeset.ex:3317`) inside `handle_params` (`changeset.ex:3155`,
#                             called at `changeset.ex:2986`) **before** `run_action_changes` (`changeset.ex:2988`) — so
#                             a non-null `value` makes `:value` a **required argument**, and a `store_pending(term: …)`
#                             call (supplying only `:term`) is rejected with a `Required` error **before** the
#                             `change/3` body can fill `:value` from `:term`. With `allow_nil?: true` the rebuilt
#                             argument is optional and the change supplies it unobstructed; the not-null-in-practice
#                             guarantee is kept by **validating that `:term` was *supplied*** — `:term` is itself **`allow_nil?: true`** and its presence is checked with **`Ash.Changeset.fetch_argument(changeset, :term)`** (`:error` ⇒ absent ⇒ reject; `{:ok, term}` ⇒ supplied, *including a legitimate `{:ok, nil}`* ⇒ normalize + encode + `force_set` `:value`), **not** by a required `:term` argument nor a `get_argument/2`-nil check: `get_argument/2` returns `nil` for an absent *and* a supplied-`nil` `:term` alike (`changeset.ex:5283-5289`), and a required `:term` would reject a real `term: nil` call. **A `nil` artifact value is real, not hypothetical** — `DefaultMapper` emits `nil` whenever the chosen source (`typed_output` / `StepResult.artifacts`) holds `nil` (`coerce(nil) → nil`, `default_mapper.ex:160-162`), and it must round-trip to a stored `term_to_binary({@artifact_version, nil})` envelope rather than be rejected, so suppliedness and value-nullness stay orthogonal — enforced by (a validation / the change's own
#                             guard), not by a non-null `:value` — the value is always written, the column simply
#                             isn't DB-`NOT NULL` (`encrypted_value` inherits the attr's nullability,
#                             `set_up_encryption.ex:35-36`). Use **`force_set_argument/3`, not `set_argument/3`**: the
#                             latter routes through `maybe_already_validated_error!` (`changeset.ex:6515-6517`);
#                             `force_set_argument/3` (`changeset.ex:6579`) is the documented in-change/in-hook setter.
#                             NOTE the accept-list subtlety: AshCloak wires its encrypt change only for a cloaked attr
#                             **in the action `accept`** (`set_up_encryption.ex:88-91`), so `:value` **must stay in
#                             `store_pending`'s accept** (omit it ⇒ no encryption) — but the **`code_interface` exposes
#                             only `:term`**, and the change overwrites `:value` from the normalized `:term`, so a
#                             direct action caller can't smuggle an un-normalized/un-encoded value past encryption.
#                             Ordering is load-bearing: AshCloak **prepends** its `Encrypt` change, whose
#                             `before_action` reads `:value` via `fetch_argument` (`set_up_encryption.ex:88-128`,
#                             `changes/encrypt.ex:9-23`) — setting `:value` in `change/3` (which runs before any
#                             `before_action`, `changeset.ex:7115`) guarantees encrypt sees the encoded blob; an
#                             appended `before_action` would run AFTER encrypt, too late. Never
#                             `force_change_attribute(:value, …)` (post-transform `:value` is argument-on-write
#                             / decrypting-calc-on-read). WaveCollect's call, passing the raw `:term`.
#   action :activate_for_wave a multi-row promotion (a domain/generic action, NOT a single-record
#                             `update` — it spans rows): inside 2c's one `wave_completed` `Ash.transact`
#                             it reads the wave's :pending rows (`pending_for_wave`) and flips each
#                             :pending → :active, AND applies `:tombstone_active` to any superseded
#                             prior-:active row for the same {run,name,producer} (Fold's last-writer-wins,
#                             made durable) — the per-row transitions looped inside the one transaction
#                             (the `WorkflowLog.append` reduce-over-appends-in-`Ash.transact` precedent,
#                             `workflow_log.ex:50-53`), but opened over **`[WorkflowEvent, WorkflowRun,
#                             ComposerArtifact]`** — NOT the event-only `append_all/3` (see 2c); NOT
#                             `Ash.bulk_update` (no in-tree precedent).
#                             2c's wave_completed calls it; 2d's fold-replay calls it too (matched by
#                             wave_index/child_run_id). **It is invoked ONLY by 2c's composer-commit helper (and
#                             2d's fold-replay), inside the same `wave_completed` transaction that appends the parent
#                             event.** It is also marked `public?(false)` — the in-tree idiom for an internal-only mutation (`WorkflowRun.set_status`,
#                             `workflow_run.ex:129-131`), strictly stronger than merely omitting it from `code_interface`
#                             (P2): `public?(false)` also keeps it out of Ash API extensions (AshAdmin etc.) and signals
#                             internal-only intent, while the commit helper still invokes it directly via `Ash.ActionInput.for_action(ComposerArtifact, :activate_for_wave, args, tenant:, actor:) |> Ash.run_action()` (the **generic-action** call shape — an `Ash.ActionInput`, NOT a changeset) —
#                             the `public?(false)` idiom (not the call shape) is the only trait it shares with `set_status`, whose **update** action instead takes `Ash.Changeset.for_update/3` + `Ash.update`. **As a generic action it also needs the `policy action_type(:action)` clause added to the policy block above** — the copied tenant block otherwise covers only create/update/destroy + read, and an action matching no policy is **forbidden by default** under `Ash.Policy.Authorizer`. (Omitting `code_interface` alone drops only the convenience fns;
#                             the action still exists and stays callable via `Ash.ActionInput.for_action(...)` + `Ash.run_action/1`.) Promotion
#                             and the parent-log append are one indivisible step, so no caller can flip rows `:active`
#                             without the matching `wave_completed`/`artifacts_produced` event; the "active iff the log
#                             records its wave" invariant (below) can't be made false by a future standalone caller.
#   update :tombstone_active  :active → :tombstoned for {run,name,producer} (artifacts_invalidated)
#   read   :resolve_ref       ref → row, then `Ash.load(row, :value, tenant: tenant, actor: actor)` to
#                             materialize the AshCloak-decrypted `value` calc — **`tenant:`/`actor:` passed**,
#                             exactly as the cloaked-load precedent (`gate_resume.ex:136`, `replay.ex:165`),
#                             and behind a `code_interface` fn so callers don't hand-roll the load (a plain
#                             read leaves it `%Ash.NotLoaded{}`), IRRESPECTIVE of state (ArtifactContext's
#                             resolver — a :pending 2b row resolves like an :active one; safe because the
#                             in-memory fold, not the DB `state`, is the availability gate — see the
#                             decrypt-only-at-the-wave-boundary bullet)
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
  `wave_completed` + `artifacts_produced` append (2c) — the one place a real `Ash.transact` exists, opened over `[WorkflowEvent, WorkflowRun, ComposerArtifact]` (not the event-only `append_all/3`) —
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
  guarantees the in-memory `store[name][producer] = ref` maps to at most one **active** row, so
  re-folding and crash-replay are deterministic; pending and tombstoned rows leave the partial
  index, so an orphaned crash-attempt row never blocks a re-launch and a re-add inserts cleanly.
- **The whole artifact value is hard-normalized to carry no novel atoms — string keys, atom values
  coerced (P3).** The `[:safe]` decode raises only on an atom **absent from the post-reboot atom table**
  — i.e. any user-defined/novel atom; `true`/`false`/`nil` are always interned, so they are fine and
  `coerce/1` rightly preserves them (`default_mapper.ex:160`). So soundness needs the stored term to
  carry no *novel* atoms, key or value — but `DefaultMapper` (`emit/default_mapper.ex`) pulls each
  artifact value from three sources in precedence — `typed_output`, then `StepResult.artifacts`, then
  the fallback `StepResult.result` (`default_mapper.ex:111-122`) — and **only the first two flow through
  `coerce/1`**; the `result.result` fallback (`artifact_or_text/2`, `default_mapper.ex:121`) returns the
  value **raw**, and on the paths that *do* coerce, `coerce/1` already stringifies novel atom *values*
  via its `inspect/1` catch-all (`default_mapper.ex:170`) but `coerce_key/1` (`default_mapper.ex:172`)
  still preserves atom *keys*. `binary_to_term(blob, [:safe])` then raises on a novel atom (key or value)
  on a post-reboot decode (2d), where the new VM holds only built-in/preloaded atoms. So normalizing only
  `coerce_key`, or only the coerced paths, would still let novel atoms through; 2b instead normalizes the
  **whole emitted value across every source path to a JSON-safe-ish shape carrying no novel atoms**, in
  two places: `DefaultMapper` runs every `output_value` result (typed / artifacts / `result` fallback
  alike) through the recursive `coerce/1` (novel atom values → strings; `true`/`false`/`nil` kept) *and*
  a `coerce_key/1` that now stringifies atom keys via `Atom.to_string/1` (the no-atom-creation direction,
  never `String.to_atom/1`), and `store_pending`'s change re-asserts it over the **raw `:term`** (before `term_to_binary`
  + cloak encryption — in `change/3`, per the action note above) — a belt-and-suspenders guarantee the decode is never handed a novel atom, key or value,
  regardless of producer or source.
- **Values decrypt only at the wave boundary — and are not re-persisted.** `ArtifactContext`
  resolves a ref → decrypts the value (via `:resolve_ref`, which `Ash.load`s the AshCloak-decrypted
  `value` calc — `%Ash.NotLoaded{}` unless loaded — **irrespective of the row's `state`**, so a
  `:pending` 2b row resolves exactly like an `:active` 2c+ one) → serializes it into the next wave's
  `:extra_context`. **Any-state resolution does not undercut the orphaned-`:pending`-refs-are-inert
  guarantee** — *inert* is an availability-layer property, not a decryptability one: a ref is reachable
  only if it sits in the in-memory fold (the availability gate, AR-2 §2/§7), and `:resolve_ref`'s only
  callers (this resolver and 2d's fold-replay) only ever resolve refs already folded; an orphaned
  `:pending` row's ref never enters the fold *and* never reaches the parent log (its `wave_completed` /
  `artifacts_produced` never landed), so it has no holder and is never decrypted in practice. *Inert*
  therefore means never-folded → never-available → never-resolved, **not** that the row is
  cryptographically unreadable. Any-state decryption is *required*, not lax: in 2b nothing is `:active`
  yet, and 2d's fold-replay must decrypt a completed-but-unpromoted wave's still-`:pending` refs — so
  state-gating `:resolve_ref` on `:active` (the defense-in-depth alternative) would break **both** paths;
  the fold is the real gate. **(2c defense-in-depth refinement, recorded here:** the alternative just
  rejected is state-gating the *single* reader; a cleaner post-2c shape *splits* it instead — a public `:active`-only
  `:resolve_ref` for the routing path (which after 2c only ever resolves folded → `:active` refs) plus a
  **`public?(false)`** recovery-only reader for `:pending` rows keyed by `parent_run_id`/`wave_index`/`child_run_id`
  (2d fold-replay) — making the availability boundary **enforced by the action**, not merely caller-disciplined,
  *without* breaking either path. 2b keeps the single any-state reader only because nothing is `:active` until 2c;
  the split is a 2c+ hardening, not a 2b change.) That decrypted `:extra_context`
  must not flow back to rest, and 2b closes both paths that would leak it: (1) the *artifact-value*
  copy — composer waves pass a `ReactorRunner.run/3` opt that **omits `replay_inputs`**
  (`reactor_runner.ex:276`, the lone surface that would otherwise hold a second *encrypted* copy) — the
  opt must **bypass the `replay_inputs_attrs/3` call entirely** so the `create` attrs carry **no
  `replay_inputs` key** (an over-cap blob already OMITS the key the same way, `reactor_runner.ex:254-255`),
  **not** set `replay_inputs: nil` (AshCloak would encrypt a present `nil` argument into ciphertext-of-nil,
  not SQL NULL — the omit-key-for-NULL rule the `WorkflowRun` cloak block relies on, `workflow_run.ex:43-45`) —
  which costs nothing, since a composer wave carries no `definition_hash` and so is not
  standalone-replayable anyway; the parent run + event log is the sole replay/recovery unit (2d); and
  (2) the *derived* copies a subagent emits while working from that context — its task, tool
  calls/results, reasoning, and tool output — which land in the transcript, audit, trace, and
  tool-output sinks and are sanitized per P1's six durable persistence points (the 2b row). The open §15.3
  sub-question "stored vs reconstructed-from-environment" (e.g. a working-tree `diff`) is **out of
  scope for Phase 2** — everything is stored.

**The store implementation is Phase 2b.** This section records the decision; 2b builds it.

---

## The sub-phase table

Each sub-phase ends `mix precommit` green and is independently committable.

| Sub-phase | Scope | Key files | Done when (green) |
| --- | --- | --- | --- |
| **2a — Parent-run lineage + launch** *(landed by the plan that wrote this doc)* | `WorkflowRun` gains `belongs_to :parent_run` / `has_many :child_runs` (cross-tenant-guarded, indexed, migrated); `ReactorRunner.run/3` gains a `:parent_run_id` opt; a `RouteComposer` split launch (`create_parent_run/1` + `start_composer/2`) creates the parent as `workflow_type: "composer"` and appends its own `run_started`; waves run as children keyed `composer:<parent>:<wave_index>`. Composer state stays in memory. | `workflow_run.ex`, `reactor_runner.ex`, `route_composer.ex`, `workflow_recovery.ex` (no-op guard), migration + snapshot | A composer run creates a `:running` parent; every wave's child carries `parent_run_id` + the idempotency key; the parent reaches a terminal status on finish; a cross-tenant `parent_run_id` is rejected. |
| **2b — `ComposerArtifact` encrypted ref-store** | The §15.3 resource above (incl. the `:pending → :active → :tombstoned` lifecycle as the named actions `store_pending`/`activate_for_wave`/`tombstone_active`/`resolve_ref`, the active-keyed P3 partial-unique index, the versioned value-encoding envelope, the **no-novel-atom normalizer**, and the `parent_run_id` cross-tenant guard) + migration; rewire `Fold` / `WaveCollect` / `StageEmission` / `ArtifactContext` / `DefaultMapper` so `WaveCollect` persists values→refs as **`:pending`** rows (via `store_pending`) and emissions carry refs; in-memory store becomes `name → producer → ref`; `ArtifactContext` resolves+decrypts via `:resolve_ref` **irrespective of `state`** (so `:pending` 2b rows resolve identically to `:active` 2c+ ones). Availability still derives from the in-memory fold, so the loop runs identically even though nothing promotes rows to `:active` until 2c. **Composer waves omit `replay_inputs`** via a new `ReactorRunner.run/3` opt (`reactor_runner.ex:276`), so the decrypted `:extra_context` leaves no second encrypted copy at rest. **Close every plaintext-at-rest leak (P1) — seven points along the decrypted value's path (six durable sinks + one propagation seam, (ii)):** (i) `ReactorMiddleware.result_summary/1` writes raw `%StepResult{}` into `step_completed` payloads + `WorkflowStep.output` (`reactor_middleware.ex:365-372`); (ii) `AgentStep` injects the **decrypted** artifact value into the live `full_task` the subagent must consume (`agent_step.ex:66`) — the **propagation seam, not a durable sink**: it is LLM input, left **intact** (digesting it would break artifact consumption), and its durable copy is the one sanitized at (iii); (iii) `AgentRunner` persists that task + terminal result via `SubagentTranscript` (`agent_runner.ex:70`, `subagent_transcript.ex:125`); **(iv) the `Recorder` persists the subagent's tool calls/results/reasoning into `messages.content` *and* `messages.metadata`** (`recorder.ex:496,528,575`); **(v) `Audit.SignalListener` writes the subagent's tool-call `arguments` into `Audit.Event.payload`** (`signal_listener.ex:114-124`, a plain public `:map`); **(vi) `Trace` persists subagent span `measurements` *and* `metadata` into `trace_events`** (`trace/persistence.ex:157-158`; artifact prose rides `metadata`, but the sanitizer must cover and test **both** columns); **(vii) `OutputShaper.Store` writes the subagent's tool output into `ToolOutput.content` *and* the `command`/`summary` columns** (`tool_output.ex:175,180,206`; for `run_command` the `command` column is the `:command` param **pattern-redacted** (`Patterns.redact`, `store.ex:118,155`) — *not* verbatim, but pattern redaction catches **nothing** in artifact-derived prose, so an artifact-derived shell command still lands effectively plaintext there, and a `command_fingerprint` (sha256 of the *raw* command, `store.ex:119`) rides alongside — a durable raw-derived **equality oracle**, so for marked calls 2b computes the fingerprint over the **sanitized placeholder** (or stores a fixed sentinel), trading the dedup/equality purpose for no raw-derived signal at rest. **The same marker-aware fingerprint function must front both storage *and* the pre-store delta lookup** (`delta_line` → `Store.fingerprint(command)` → `latest_for_fingerprint`, `output_shaper.ex:594-599`, `tool_output.ex:115`), else a marked call would still *transiently* derive the raw fingerprint at lookup time **and** miss its own sentinel-keyed history (a raw-keyed lookup against a sentinel-keyed store always misses); the shaped `summary` map can likewise carry artifact-derived snippets) — both the native `run_command`/`git_diff` formatter path (`shapeable?/3`) *and* the **generic `mcp_*` proxy path** (`mcp_shapeable?/2` → `safe_shape_mcp/3` → `finish_shape`, `output_shaper.ex:188,317,345`), which ref-stores oversized MCP results the same way. Points (iv)–(vii) are **redacted-not-encrypted**, and for the artifacts in scope (`approved-plan`, `diff` — sensitive prose, not pattern-matchable secrets) redaction catches ~nothing, so each leaks as plainly as `messages.content`. Composer waves suppress/digest the orchestration-axis sink (i) **and** sanitize every derived write — (iii)–(vii) — for composer subagent request IDs into placeholders/digests; (ii) is the **propagation seam**, deliberately left intact so the subagent still sees the artifact. The mechanism is an explicit marker (`sanitize_sensitive_context: true`) that originates on the **wave's reactor context** (threaded in via a `ReactorRunner.run/3` opt). Reaching the child tool context means surviving **two builder boundaries that otherwise drop unknown keys**, so 2b threads it through both — exactly as `:agent_template` already is (`agent_runner.ex:60-61`): (1) `AgentRunner.resolve_scope/2` returns a **fixed literal map** (`agent_runner.ex:283`), so the marker is added to that map (read from the reactor context); and (2) `ToolContext.build/1` rebuilds from **`@canonical_keys` only** (`tool_context.ex:42,87`), so the marker is added to `@canonical_keys` as an **always-forwarded** key (kept out of `@policy_controlled_keys`, so no `forward_context` policy can strip it). Without both, the marker is silently dropped before `RequestCorrelation`, `SubagentTranscript`, and `OutputShaper` ever see it. **Because it rides `@canonical_keys`, `ToolContext.child/2` — the swarm-tool helper (`tool_context.ex:151,159`) — propagates it through *nested* spawned (`spawn_agent.ex:101`) and follow-up (`send_to_agent.ex:52`) agents too**, so a composer subagent that hands artifact-derived content to another agent keeps the boundary. This is **in scope** (2b names those two files and tests nested propagation), at the cost of coarsely marking a nested agent's whole turn even when only part is artifact-derived — the same per-subtree over-mark trade as the absent-row digest. It then reaches its sinks by **three carrier paths**, one per how each sink is wired. **(a) Async signal-consumer sinks** — `Recorder`→messages (iv) and `Audit.SignalListener`→audit (v) — resolve scope from a `request_id` and so read the marker *from the resolved scope*. That requires it to be **both** a **durable field on the `RequestCorrelation` row** (a **non-null boolean, `default false`** — the `subagent`/`agent_id` precedent, `request_correlation.ex:203-207` — added to its `:register` accept-list + the `register_child_correlation/1` → `register_correlation/6` scope map, `jido_claw.ex:305,370`) **and** mirrored into the **`RequestCorrelation.Cache` stored shape** (`cache.ex:22-41`), its cache writes, and the cache-miss rehydrate — in *both* `recorder.ex:797-820` *and* `signal_listener.ex:137-158`, **with the same `false` default applied on write and on rehydrate so an absent/nullable marker never reads as ambiguous** — exactly as `agent_id`/`subagent` already are. Both consumers hit the **cache first**, so a marker only on the durable row would be invisible on the normal cache-hit path; and the durable row is load-bearing for the cache-*miss* path, since a Recorder/listener restart between a tool signal and its write would otherwise rehydrate scope **without** the marker and write sensitive content plaintext. **(b) Inline execution-path sinks** — `ReactorMiddleware` (i), `SubagentTranscript` (iii), and `OutputShaper.Store` (vii) — run *inside* the wave/subagent execution and read the marker from the live context they already hold, no scope round-trip: the wave's **reactor context** for the orchestration-axis write — but `result_summary/1` (`reactor_middleware.ex:365`) is handed **no context**; the context-bearing seam is **`emit/3`** (`reactor_middleware.ex:396`, via `run_from(context)`), which holds the marker *and* runs **before** `WorkflowLog.append`. So 2b scrubs by transforming the `{kind, payload}` in `emit/3` (or threads context into `map_event/2`+`result_summary/1`) **before the append** — mandatory, because `WorkflowEvent`'s `Allocate` stashes the *raw* payload and projects it into `WorkflowStep.output` / `WorkflowRun.result` (`allocate.ex:107,120`), so any scrub at projection time is already too late and the subagent's **tool context** for the conversation-axis writes (`SubagentTranscript`, handed `tool_context` directly by `AgentRunner`, `agent_runner.ex:70,76`; `OutputShaper.Store` on the subagent's own tool calls, which inherit the marker because 2b propagates it into their per-tool context). **Under `serve_mode == :mcp` a second inline writer hits the same `messages` sink (iv):** `JidoClaw.Tools.MCPScope.do_wrap_recorded` (`mcp_scope.ex:108-176`), which fronts *every* tool via `Tools.Action` (`action.ex:53`), appends the call's `content` + `metadata.{arguments,result}` to `messages` **directly, bypassing the Recorder/signal path** — so it is a distinct carrier into (iv), not covered by (iv)'s async-scope resolution. It is an **inline (b) carrier** (it holds the subagent's `tool_context` `tc`, so it reads `sanitize_sensitive_context` straight off it, no scope round-trip), and 2b sanitizes its `content`/`metadata` writes for marked calls exactly as the Recorder path does. *(Belt-and-suspenders today: the composer is an internal orchestration loop, not launched through any MCP-exposed tool, so a composer wave never runs under a serve-mode node — but closing the path keeps the guarantee honest against future `run_skill`/MCP wiring that exposes composer routes.)* `AgentStep` is **not** here — it is the (ii) propagation seam that *builds* the live task, not a sink that reads the marker. **(c) Async telemetry sink** — `Trace` (vi) — is **neither** inline **nor** a signal consumer: it is telemetry-driven (`collector.ex:339` normalizes telemetry *metadata*; `persistence.ex:139` persists it) and **never receives the tool context**, and jido_ai's runtime telemetry metadata is a fixed map with no `tool_context` hook (`deps/jido_ai/.../react/strategy.ex:2437`). So `Trace` resolves the marker the **same way the (a) consumers do — by `request_id` against the durable `RequestCorrelation` field** — inside `collector.ex`'s `normalize_event` (which already lifts `request_id` from the telemetry metadata), and `Trace.Policy` + `collector` digest the span metadata of marked spans. This needs **no jido_ai patch**: it reuses the `RequestCorrelation` marker that carrier (a) already requires, staying contained in-tree, at the cost of a (cache-backed) lookup at normalize time. **The lookup fails OPEN** — a deliberate deviation from a strict privacy gate, kept as the intended contract. The marker resolver still returns `:marked | :unmarked | :unknown` for a request_id-bearing span (a `nil` request_id passes through untouched), but **only a confident `:marked` digests** the span; both a *found, unmarked* row **and** an `:unknown` result — an **absent** row or a faulting durable read — **pass through unredacted**. **Rationale:** (a) the two normative contracts below — the C4 abort-on-marked-write-failure and the C5 conservative `expires_at` ceiling — guarantee a genuinely-marked span stays resolvable as `:marked` throughout its realistic lifetime, so failing closed on `:unknown` would add nothing for marked data; (b) most legitimate *non-composer* telemetry carries a request_id whose correlation row has already expired (~600s TTL, `request_correlation.ex:218-223`) or was never registered, so digesting every `:unknown` would shred general observability. The residual gap — a marked span arriving after its C5 ceiling, or during a transient DB fault — is **accepted** as beyond the designed orphan-drain retention (the async sinks below still fail closed on unresolvable scope; only the Trace span passes through). **Two normative contract changes** (not mere mitigations) keep a marked composer span resolvable as `:marked` — correctly digested, never passed through under fail-open: (1) a marked composer-subagent registration whose durable `RequestCorrelation` write fails **returns an error / aborts the child turn before it starts** — never the current cache-only `:ok` fallback (`jido_claw.ex:392-398`) — so a marked row is always durable. This **widens `register_child_correlation/1`** (today a bare `String.t()`, `jido_claw.ex:304`) into a **consistently** tuple-returning helper — `{:ok, request_id}` on success, `{:error, reason}` on a marked durable-write failure — *not* a shape that varies by marker state (a footgun); the unmarked path stays effectively-infallible (always `{:ok, id}`, preserving today's "returns an id regardless"), and all three callers update to destructure. (A separate marked-only fallible helper is the rejected alternative — a caller can't tell statically whether its context is marked, so it would have to branch on the marker anyway.) It also forces **caller cleanup at all three call sites**, which today register *after* the child pid exists: `AgentRunner` (`agent_runner.ex:62` start → `:69` register) and `spawn_agent` (`spawn_agent.ex:107`) must **stop the freshly-spawned pid** on an abort (the `:agent_id_taken` reclaim at `spawn_agent.ex:127` is the precedent), while `send_to_agent` (`send_to_agent.ex:57`, a follow-up to a pre-existing tracked agent) simply **does not dispatch the turn**, leaving the running agent untouched. And (2) the marker row's TTL is bounded by the **parent composer run's own deadline**, not the default ~600s (`inserted_at + 600s`, `request_correlation.ex:218-223`) — making the source of truth concrete, since "max composer run duration" is otherwise undefined (`:deadline_ms` is **optional** on `start_composer`, `route_composer.ex:121`, and `:max_waves` is a count, not a wall-clock bound). A **marked composer run MUST carry a bounded `:deadline_ms`** (made **required for sensitive runs** — a normative contract change; an unbounded sensitive run is rejected, like the durable-write-failure abort above). **One durable wall-clock clock source.** The live composer `deadline` is **monotonic** (`now_ms() + deadline_ms` over `System.monotonic_time`, `route_composer.ex:642-645`) and so is meaningless across a reboot; the TTL's source of truth is instead a durable **wall-clock `deadline_at`** written to the parent run's `config` (`workflow_run.ex:237`) from a **single wall-clock read at genesis** (`deadline_at = t0 + deadline_ms`, `t0` read once in `create_parent_run/1`), so 2d recovery reads the *identical* `deadline_at` after a reboot and the same value governs the loop's `past_deadline?` bound — and so the run's lifetime, which (plus `T_wave` + orphan-drain) *is* the conservative `expires_at` ceiling for marker rows (see the corrected `T_wave` / retention note below). **Write path:** it is set in the `WorkflowRun.create` itself (`:config` is already in the `:create` accept-list) — **not** derived from the projection-stamped `started_at`, because `started_at` doesn't exist at create and its only writer `set_status` accepts `:started_at` but **not `:config`** (`workflow_run.ex:129-136`), and `WorkflowLog.append/4` passes no `:occurred_at` (`workflow_log.ex:25-34`), so no atomic "config = started_at + deadline_ms" seam exists; the ~microsecond genesis↔`run_started` gap is immaterial to a run-duration TTL (the same gap `request_correlation.ex:212-214` documents). **Explicit data path to the registration.** `register_child_correlation/1` today receives only the child `tool_context` (`jido_claw.ex:304-331`) and passes **no** `expires_at` (so the 600s default applies), and `ToolContext.build/1` keeps **only `@canonical_keys`** (`tool_context.ex:42`); so the precomputed **`expires_at` (the conservative absolute ceiling `deadline_at + T_wave + orphan-drain`, swept unchanged by the existing `:expired`/`sweep_expired` — see the corrected `T_wave` / retention note below) rides a new canonical key `:request_correlation_expires_at`** added to `@canonical_keys` + `AgentRunner.resolve_scope/2` — the **same builder path as the marker** — and `register_child_correlation/1` → `register_correlation/6` thread it to the `:register` action's `:expires_at` (`request_correlation.ex:118-132`,126). **Retention must outlive an in-flight wave's *orphaned* child work — which `T_wave` alone cannot bound (P1 — corrected).** `past_deadline?` is a **pre-launch** gate (`route_composer.ex:631-636`) and `ReactorRunner` runs each wave `timeout: :infinity` (`reactor_runner.ex:512`), so a wave launched just before `deadline_at` can keep emitting *after* it. Composer waves do add a **per-wave wall-clock timeout** `T_wave` — a new **`ReactorRunner.run/3` `:execution_timeout` opt** (default `:infinity`, threaded into `run_killable`'s currently-hardcoded `timeout:`, `reactor_runner.ex:512`, so **non-composer callers are unchanged**); on expiry the killable task is shut down → `run_killable` returns `{:exit, :timeout}` → the existing `ensure_failed` path (`reactor_runner.ex:521,533`) terminalizes the **child wave `:failed`**, and 2d re-dispatches that wave under a **fresh `wave_index`** (recovery rule 2). **But killing the wave executor is *not* a hard interrupt of its child side effects.** Composer waves run `async?: true` (`route_composer.ex:419`) with each stage step `async?: true` (`wave_builder.ex:86`), and Reactor schedules those via `Task.Supervisor.async_nolink` keyed on the executor pid, so killing the executor **orphans already-started async-step work — a spawned subagent, shell command, or external side effect runs to completion into the void** (`RunExecution`'s documented limitation, `run_execution.ex:41-48`: *nothing new* schedules after the kill, but in-flight subagents are **not** killed). So an orphaned subagent **can still write** to the transcript / audit / trace / tool-output sinks **after `deadline_at + T_wave`** — `T_wave` bounds the *executor* (liveness + rule-2 re-dispatch), **not** every child side effect. **Therefore the marker `expires_at` is a *conservative absolute ceiling*, not the false `deadline_at + T_wave` bound:** `expires_at = deadline_at + T_wave + orphan-drain`, where **`orphan-drain` covers the maximum realistic orphaned-subagent lifetime** (the subagent's own turn/LLM/tool timeouts — *not* `T_wave`, which bounds only the executor). It is a single fixed timestamp, stamped at registration and swept **unchanged** by the existing `:expired` read (`filter expr(expires_at < now())`, `request_correlation.ex:148-150`) + `sweep_expired/0` (`request_correlation.ex:280-297`); **no parent-run linkage and no status-coupled sweep is added** — the live `RequestCorrelation` is purely TTL-swept and cannot express "keep until parent terminal," so 2b does **not** pretend it does. Because the ceiling is keyed off the run-level `deadline_at` (shared by every wave's marker rows), a marked row stays alive across the **whole** run plus the orphan drain, so in the common case a late orphaned write still finds its marker durable and is sanitized (digested/placeholdered) rather than reading `:unknown` (which on the Trace path passes through, and on the async path skips). A *true* status-coupled run-terminal retention (prune only once the parent run is terminal + drain) is the **heavier alternative** — it would require adding a `composer_parent_run_id` linkage to `RequestCorrelation` plus an `:expired`/sweep rule that skips marked rows until that parent run is terminal. 2b deliberately takes the simpler **conservative-ceiling** path, because the retention window is, for the async sinks, only a **completeness** optimization: **those consumers still fail closed regardless** (below) — they skip a write whose scope can't resolve — so a slightly-too-short ceiling only *skips* a late async write, never leaking one. For **Trace**, which now fails *open* on `:unknown`, a too-short ceiling instead widens the accepted (bounded) fail-open window — an additional reason the ceiling is sized generously, so that in practice marked writes land while their marker still exists. (`T_wave` is retained purely as a liveness/recovery bound; basing retention on `deadline_at + T_wave` — the earlier framing — would under-retain exactly the orphaned-late-write case, since the kill never reaches orphaned children. A tight per-wave wall-clock retention bound would require cancellation propagation to actually kill the async child tree, which `RunExecution` explicitly does **not** do today.) **The async sinks still fail closed regardless:** when a *scope* is unresolvable at a late write (cache miss + an absent/faulting durable read), the `Recorder`/`Audit` consumers **skip the write** — they need a session/tenant to write any row — so nothing leaks there. **Trace, by contrast, fails open:** a late write whose marker reads `:unknown` (a faulting read, or a write landing past the conservative `expires_at` ceiling) **passes through** rather than being digested — the accepted residual gap above. What too-short retention regresses is **async transcript/audit completeness** (skipped writes) **and, on the Trace path, privacy** (a late marked span passing through the fail-open gate) — both bounded, which is exactly why the `expires_at` ceiling is sized to the **whole run** (`deadline_at` + `T_wave` + orphan-drain), not a per-wave wall-clock. The required bounded `:deadline_ms` for sensitive runs (above) stays load-bearing under this rule — it bounds the run's lifetime, and so the retention window. (The same found-and-unmarked-only rule governs the (a) consumers' durable-row read; and when scope *itself* is unresolvable they skip the write outright — the distinct unknown-scope mode noted below.) (Stamping the marker into jido_ai's emitted metadata via a strategy patch so it rides the span at emit is the rejected alternative — it would add a dependency-level patch and another builder boundary.) Every sink writes **sanitized placeholders/digests, never row-suppression** *on the sanitization path* — a marked, scope-resolved write becomes a digest, not a dropped row — so durable subagent-context/compaction expectations stay intact (P2). **One distinct, acknowledged exception (not marker-driven suppression):** the async consumers `Recorder` and `Audit` need a resolved scope (session/tenant) to write *any* row, so when scope itself is **unresolvable** (cache miss + durable read absent/faulting) they **skip the write entirely** (`recorder.ex:502,534,587` — the `with {:ok, scope} <-` falls through; `signal_listener.ex:128` — `skip(:correlation_missing)`). That is a **pre-existing, fail-safe** mode (no scope ⇒ no row ⇒ nothing leaks), orthogonal to the marker, and 2b must test it as a **separate outcome** ("unknown scope ⇒ skipped write"), not assume a placeholder is always written. **Test all three carriers:** (a) the signal-consumer scope resolution on cache-hit *and* cache-miss (evict + rehydrate) for `Recorder` and `Audit`; (b) the inline-context path (`ReactorMiddleware` + `SubagentTranscript` + `ToolOutput`); (c) `Trace`'s `request_id`→`RequestCorrelation` marker lookup in `normalize_event`. Plus the builder-boundary survival itself — assert the marker reaches the child `tool_context` through `resolve_scope/2` + `@canonical_keys`. **The guarantee is not narrowable** (P1): every durable sink above is **redacted-not-encrypted** (`message.ex:375` for `messages.content`; the audit/trace/tool-output sinks likewise), so any narrowing would leak real sensitive artifacts plaintext. So 2b sanitizes composer-subagent writes across *all six durable* sinks (the (ii) seam stays intact), *then* lifts Phase 1's "non-sensitive fixtures only" rule. | new `composer_artifact.ex`, `fold.ex`, `steps/wave_collect.ex`, `stage_emission.ex`, `artifact_context.ex`, `emit/default_mapper.ex`, `orchestration/{reactor_middleware,reactor_runner}.ex`, `route_composer.ex` (durable `deadline_at` + per-wave timeout for the TTL contract), `conversations/resources/request_correlation.ex` + `conversations/request_correlation/cache.ex` (+ `jido_claw.ex` correlation helpers), `tool_context.ex`, `skills/steps/{agent_step,agent_runner}.ex`, `conversations/{subagent_transcript,recorder}.ex`, `audit/signal_listener.ex`, `trace/{collector,policy}.ex`, `tools/{output_shaper,spawn_agent,send_to_agent,mcp_scope}.ex` | No artifact value is plaintext in the orchestration tables (WaveCollect return, event payloads, `WorkflowRun.result`, `step_completed`, `WorkflowStep.output`), subagent transcripts (`messages.content` *and* `messages.metadata`), **audit rows (`Audit.Event.payload`), trace events (`trace_events.metadata` *and* `measurements`), or the tool-output cache (`ToolOutput.content`/`command`/`summary`, native *and* `mcp_*`-shaped)**, nor — under `serve_mode == :mcp` — in `MCPScope`'s direct `messages` writes, for composer subagent request IDs, and no second *encrypted* copy survives in any child wave's `replay_inputs`; values encrypted at rest; `ComposerArtifact` rows insert `:pending` via `store_pending` and resolve via `:resolve_ref` regardless of state (promotion is 2c); the `sanitize_sensitive_context` marker survives the `resolve_scope/2` + `@canonical_keys` builder boundaries into the child tool context, is read from the cache on a hit, survives a Recorder/Audit/Trace cache-miss via the durable `RequestCorrelation` row, is read inline from the live reactor/tool context by ReactorMiddleware/SubagentTranscript/ToolOutput, and is resolved by request_id for Trace in the collector; an **absent or faulting** marker lookup fails open on the Trace path (the span passes through), while the async `Recorder`/`Audit` consumers still skip the write when *scope itself* is unresolvable, and unknown-scope skips are asserted as a distinct outcome; the marker propagates through nested `spawn_agent`/`send_to_agent` children, and a failed marked registration aborts the child turn (stopping any freshly-spawned pid); the loop runs identically. |
| **2c — Composer event log + projection + durable loop** | Extend `WorkflowEvent.kind` with the composer kinds — additive (`route_composed`, `wave_started`, `wave_completed`, `signals_published`, `artifacts_produced`, `wave_paused`, `wave_resumed`), subtractive (`signals_retracted`, `stages_invalidated`, `artifacts_invalidated`), and **one parent-terminal kind per loop terminal (P2; extends the parent plan's §9 set — see the P2 cross-cutting note):** `route_converged`→`:completed`; `route_not_converged` / `route_deadlocked` / `route_budget_exhausted` / `route_failed`→`:failed`; `route_rejected` / `route_abandoned`→`:cancelled` + disposition. Extend `Projection` (`@status_authority_kinds`, `next_status/2`, `status_attrs/3`); add a composer-state fold replaying additive + subtractive deltas in `seq` order. Rewrite the loop to append `route_composed` → `wave_started` (pre-launch) → one-txn `wave_completed` + content events, folding via the existing `Fold.fold/2`. **That same `wave_completed` + `artifacts_produced` transaction promotes the completed wave's `:pending` `ComposerArtifact` refs → `:active` via `activate_for_wave`** (tombstoning any superseded prior-active row for the same `{run, name, producer}`), so the projected active-row set is always a function of the durable log — a ref is active iff the log records its wave. **That transaction must be opened explicitly over all three resources** — `Ash.transact([WorkflowEvent, WorkflowRun, ComposerArtifact], fn -> … end)` (the multi-resource form `create_parent_run/1` already uses) — so it **cannot reuse `WorkflowLog.append_all/3` as-is**, which transacts `WorkflowEvent` only (`workflow_log.ex:53`); 2c adds a dedicated composer-commit helper (event append + projection status flip + `activate_for_wave`) so the ref state-flip never splits from the parent-log append. Supervised lifecycle: `DynamicSupervisor` + unique `Registry` keyed by `parent_run_id`, transient restart. | `workflow_event.ex`, `workflow_event/projection.ex`, new `route_composer/projection.ex` (composer-state fold), `route_composer.ex`, `composer_artifact.ex`, `application.ex` | The run's full state is durable in the parent log and re-projectable; in-memory state is a cache of the projection; a wave's refs flip to `:active` exactly when its `wave_completed` lands; **every loop terminal (`route_composer.ex` `finish/2`) maps to a distinct composer terminal kind**; an empty-emission wave still records `wave_completed`. |
| **2d — Crash recovery (the payoff)** | `WorkflowRecovery` gains a real `workflow_type: "composer"` branch (replacing 2a's no-op): rebuild state from the log, reconcile child waves first (a boot `:running` child is stranded→`:failed`, never observed), then re-launch by **two distinct rules** keyed on what the log + child rows show. **(1) `wave_started` resolving to no child row** — the BEAM died after the `wave_started` append but before `run/3` created the child — re-launches under the **same** `composer:<parent>:<wave_index>` key; `run/3` materializes it fresh and idempotently. **(2) `wave_started` whose child exists and recovered to `:failed`** is **not** re-runnable under that key — `ReactorRunner` returns the existing run on a key hit (`reactor_runner.ex:304`) — so, since a `:failed` child never wrote `wave_completed` and its stages are therefore absent from the rebuilt `ran`, re-`compose_route` re-derives those stages and dispatches them under a **fresh `wave_index`**, leaving the `:failed` child a harmless orphan told apart by `wave_index` (parent plan §recovery, `AR-2-COMPOSER-PLAN.md:593-596`). Replay a dropped `wave_completed` fold from the completed child result + store (which **promotes** that wave's `:pending` refs → `:active` via `activate_for_wave`, matched by `wave_index`/`child_run_id`), then resume from the next wave; synthesize `route_rejected` / `route_abandoned` for a gate decided-then-crashed. A crashed-mid-wave's orphaned `:pending` `ComposerArtifact` rows (refs inserted, but `wave_completed` never landed) are left **inert** — never promoted, never available, outside the active partial index — so the re-launch's `WaveCollect` re-inserts cleanly (under the same key for rule 1, under a fresh `wave_index` for rule 2). | `workflow_recovery.ex`, `route_composer/projection.ex`, `composer_artifact.ex`, tests | A killed mid-route run resumes from the next wave on reboot; a `wave_started`-with-no-child re-launches under the same key, while a `:failed` child re-dispatches its stages under a **fresh `wave_index`** (the old key would just return the existing `:failed` run); subtractive deltas stay applied; orphaned `:pending` artifact rows from a crashed wave never block re-launch and never surface as available; a gate-terminal-then-crash synthesizes the parent terminal. |

---

## Cross-cutting guarantees the four sub-phases together must satisfy

These are the AR-2 §14 "done when" criteria for Phase 2, mapped onto the slices so none is
lost between them:

- **P1 — no plaintext artifact value at rest in any platform-managed store, and no duplicated copy.**
  *(Scope: the guarantee covers the platform's own at-rest stores — orchestration, conversation, audit,
  trace, tool-output. It does **not** reach side effects a subagent deliberately produces from the
  artifact it legitimately consumes at the (ii) seam — a `write_file`/`edit_file` to the working tree, a
  `git_commit`, an external call — which are real artifact-derived writes outside any platform store: out of
  the envelope's scope, and controlled by the **approval/policy layer where configured** — `git_commit` is in
  the default require-list (`tool_approval.ex:116`), but `write_file`/`edit_file` are gated only via a
  template/config overlay, not by default — never a blanket guarantee.)* 2b closes all
  **six durable** persistence points — orchestration tables, subagent transcripts (`messages.content`
  *and* `messages.metadata`, written by the `Recorder` and — under `serve_mode == :mcp` — by
  `MCPScope`'s direct append), audit rows (`Audit.Event.payload`), trace events
  (`trace_events.metadata` *and* `measurements`), and the tool-output cache (`ToolOutput.content`/`command`/`summary`, native *and* `mcp_*`-shaped) — **omits
  `replay_inputs` for composer waves** (the lone surface that would otherwise hold a second
  *encrypted* copy outside the ref-store), carries the suppression marker through the tool-context
  builders (`resolve_scope/2` + `ToolContext.@canonical_keys`, else it is dropped before any sink sees
  it), and makes it **both a durable `RequestCorrelation` field *and* a mirror in the
  `RequestCorrelation.Cache`** so neither the normal cache-hit path nor a Recorder/Audit/Trace
  cache-miss rehydrate can silently un-suppress a sensitive write — and only then lifts the
  non-sensitive-fixtures rule. The marker reaches its sinks by **three carriers**, one per wiring: the
  **async signal consumers** (`Recorder`, `Audit.SignalListener`) read it from the resolved scope
  (cache → durable `RequestCorrelation` row); the **inline execution-path** sinks (`ReactorMiddleware`,
  `SubagentTranscript`, `OutputShaper` — plus, under `serve_mode == :mcp`, `MCPScope`'s direct `messages`
  writes, a second inline carrier into the transcript sink) read it from the live reactor/tool context they already hold;
  and **`Trace`** — telemetry-driven, never handed the tool context — resolves it by `request_id`
  against the same durable `RequestCorrelation` field in `collector`/`policy` (no jido_ai patch). The
  **lookup-based** carriers (the async consumers + Trace, resolving by scope/`request_id` against the
  `RequestCorrelation` row) **split by carrier**: a *found, marked* row → `:marked` (digested), a *found, unmarked* row
  passes, and an **absent** row (the cache-only-on-write-failure case, `jido_claw.ex:392-398`, or a
  post-`expires_at` expiry — the ~600s default for non-composer rows, `request_correlation.ex:218-223`, or the longer `deadline_at + T_wave + orphan-drain` ceiling for a marked composer row) or a faulting read → `:unknown`. **Trace fails open** — only a confident `:marked` digests, so an `:unknown` span passes through (the C4/C5 contracts keep a genuinely-marked span resolvable, losing nothing for marked data while preserving general observability); **the async consumers, orthogonally, still fail closed on scope** — when *scope itself* is unresolvable they skip the write, since they need a session/tenant to write any row. The **inline**
  carrier reads the marker off the live reactor/tool context (no row, no absent-row failure mode); its
  guarantee is the builder-boundary propagation assertion, not this lookup rule.
  `AgentStep` is the propagation seam that builds the live task, not a marker-reading sink. **Covering
  every one of these platform sinks is load-bearing**: each is
  **redacted-not-encrypted**, and the in-scope artifacts (`approved-plan`, `diff`) are sensitive prose
  that redaction does not catch — so a narrowed guarantee would leak them plaintext. 2a keeps the
  fixtures rule (inline values still transit the child `WorkflowRun.result`).
- **P2 — durable subagent context survives sanitization.** 2b writes **sanitized
  placeholders**, never row-suppression, on the sanitization path, so compaction/subagent-transcript
  expectations hold — with one acknowledged exception: when a scope is *unresolvable*, the async
  consumers (`Recorder`, `Audit`) skip the write rather than write a placeholder (they need
  session/tenant to write at all), a pre-existing fail-safe mode 2b tests separately.
  And every loop terminal (`route_composer.ex:87` — `:converged | :not_converged | :deadlock |
  :budget_exhausted | :failed`, plus the gate `:rejected` / `:abandoned`) gets a **distinct** composer
  terminal *kind* (2c), all projecting onto the existing `:completed` / `:failed` /
  `:cancelled`+disposition status set — so a recovery fold (2d) can tell *why* a run ended. **This
  extends the parent plan's §9 terminal vocabulary, deliberately:** the parent names only the four
  disposition/bound-bearing kinds (`route_converged` / `route_rejected` / `route_abandoned` /
  `route_budget_exhausted`, `AR-2-COMPOSER-PLAN.md:558`); Phase 2 adds `route_not_converged` /
  `route_deadlocked` / `route_failed` for the remaining `:failed` causes the loop actually produces.
  The extension is **purely additive** — new event *kinds*, no new statuses — so the parent still wins
  on *design* (the status set is unchanged) and §9's list reads as the disposition-bearing subset.
- **P3 — deterministic invalidation/replay.** The `ComposerArtifact` partial-unique index
  (2b, named `composer_artifacts_active_ref_index`, keyed `where state = 'active'`) guarantees ≤1
  active ref per `{run, name, producer}` — a backstop, never expected to fire, since 2c's commit
  helper tombstones the prior active row in the same transaction before promoting the new one; a
  violation signals a logic bug. A ref reaches `:active` **only** via the parent's `wave_completed`
  transaction (2c) — through the composer-commit helper's `activate_for_wave`, which is **`public?(false)` (the `WorkflowRun.set_status` idiom) and not exposed
  for standalone use**, so the active set is always a function of the durable log, never of a
  child-side insert a crash could strand or a stray caller could flip without the matching event. The parent-terminal error string is formatted from the `{terminal, reason}` pair (2a
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
