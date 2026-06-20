# AR-2 Composer — Phase 2b: the `ComposerArtifact` encrypted ref-store + P1 leak closure

## Context

Phase 1 (`c7a428a`) and Phase 2a (`92d63f2`) shipped the composer loop with a first-class
parent `WorkflowRun` and child-wave lineage, but **artifact values still live inline** — in the
in-memory store (`name → %{producer => value}`, `route_composer.ex:33-34`), in `WaveCollect`'s
durable terminal return (→ child `WorkflowRun.result`), and in the subagent task. Phase 2a
therefore keeps a **non-sensitive-fixtures-only** rule: no real `diff`/`approved-plan` may flow,
because it would be written **plaintext at rest** in ~half a dozen durable stores.

**Phase 2b removes inline artifact values entirely and lifts that rule.** Values move into a new
AshCloak-encrypted `JidoClaw.Orchestration.ComposerArtifact` resource; every other durable surface
carries only an opaque `art_<hex>` ref. The decrypted value surfaces *only* at the wave boundary
(into `:extra_context` → the subagent's task), and a `sanitize_sensitive_context` marker is threaded
to every durable sink the subagent's derived output reaches so none of it lands plaintext. This is
the §15.3 resolution made real (DURABLE-ENVELOPE doc lines 42-305) and the AR-2 §6/§7/§14-Phase-2
"no plaintext artifact value at rest" guarantee (P1).

**Scope decision:** the whole of 2b lands as **one plan, one `mix precommit`-green gate** (per the
user's choice). It is organized below into three themes (A: store + rewiring; B: marker + sinks; C:
TTL/deadline contract). Nothing is deferred. The non-sensitive-fixtures rule is lifted only at the
very end, after all six sinks are closed and tested.

**Use subagents for each theme:** because of the size of this plan, it's recommended that you act as
an orchestrator and leverage subagents to implement each distinct unit of work, then you review the
work as each subagent completes its assigned theme.

> **Greenfield:** no data/path migration concerns. The new resource + migration are created
> from scratch; no backfill.

---

## Cross-cutting guarantees (the acceptance frame)

- **P1 — no plaintext artifact value at rest, no duplicated copy.** Six durable sinks closed
  (orchestration tables, subagent transcripts, audit rows, trace events, tool-output cache, +
  `MCPScope` under `serve_mode == :mcp`); `replay_inputs` omitted for composer waves; values
  encrypted at rest in `ComposerArtifact` only.
- **P2 — durable subagent context survives sanitization.** Sinks write **sanitized
  placeholders/digests, never row-suppression** — except the one pre-existing fail-safe (unresolvable
  scope ⇒ async consumers skip the row), tested as a distinct outcome.
- **P3 — deterministic invalidation/replay.** `ComposerArtifact` ships the full
  `:pending → :active → :tombstoned` lifecycle + the active-keyed partial-unique index, even though
  *promotion* (`activate_for_wave` wiring) is 2c. 2b inserts `:pending`, resolves via `:resolve_ref`
  regardless of state; availability still derives from the in-memory fold.

---

## Theme A — the encrypted ref-store + artifact-flow rewiring

### A1. New resource: `JidoClaw.Orchestration.ComposerArtifact`

New file `lib/jido_claw/orchestration/composer_artifact.ex`, **hand-rolled `use Ash.Resource`**
(the `JidoClaw.Resource` macro doesn't forward `extensions:`, so AshCloak can't ride it — same
reason `WorkflowRun` hand-rolls, `workflow_run.ex:16-22`). Mirror these in-tree precedents:

- **Ref+value-by-opaque-ref table:** `Conversations.ToolOutput`
  (`conversations/resources/tool_output.ex`) — its `ref :string` + `:by_ref` get-action +
  `OutputShaper.Store.generate_ref/0` (`out_<12-hex>`, `store.ex:157-159`). `art_<hex>` mirrors this.
- **Tenant shape:** **plain `tenant_id :string` attr, NO `belongs_to :tenant`** — the **ToolOutput**
  shape (`tool_output.ex:155-158`), *not* WorkflowRun's (which adds a tenants FK). The doc commits the
  ToolOutput shape explicitly (DURABLE-ENVELOPE line 119: "plain attr — ToolOutput shape, no
  belongs_to :tenant"). Multitenancy `strategy(:attribute)` on `tenant_id`, `global?(false)`, plus a
  `multitenancy(:bypass)` `:by_id_global`.
- **Cloak block + vault:** copy `WorkflowRun`'s `cloak do vault(JidoClaw.Security.Vault);
  attributes([:value]) end` (`workflow_run.ex:52-55`; note the doc's "43-55" points at the comment).
  `value :binary, allow_nil?: true` → column becomes `encrypted_value`.
- **Hand-copied tenant policy block:** copy the macro's generated block (`resource.ex:67-79`) — the
  `ActorTenantMatches` write policy + the `tenant_id == ^actor(:tenant_id)` read policy + the
  `by_id_global` bypass — **plus a `policy action_type(:action)` clause** (`ActorTenantMatches`) for the
  generic `activate_for_wave` action, which matches neither create/update/destroy nor read and is
  forbidden-by-default under `Ash.Policy.Authorizer`.
- **Cross-tenant guard (both FK columns):** a `:create` change `Changes.ValidateCrossTenantFk`
  running `CrossTenantFk.validate(cs, [{:parent_run_id, WorkflowRun, JidoClaw.Orchestration},
  {:child_run_id, WorkflowRun, JidoClaw.Orchestration}])` in a `before_action` — the exact
  extracted-module precedent (`workflow_run/changes/validate_cross_tenant.ex:18-25`). **Both**
  `parent_run_id` *and* `child_run_id` are `WorkflowRun` refs, so both need the tenant check (a
  bad internal call could otherwise attach an artifact to another tenant's child run). **Plus a
  lineage assertion** in the same `before_action`: load the child via `WorkflowRun.by_id_global`
  and reject unless `child.parent_run_id == parent_run_id` (the child wave must belong to this
  composer parent) — a focused custom error, not a generic FK mismatch. (`store_pending`'s caller,
  `WaveCollect`, reads `child_run_id` from `context.workflow_run`, whose `parent_run_id` FK *is*
  the composer parent, so the assertion always holds for a correct producer and only catches a
  confused one.)

**Attributes** (Ash defaults nullable, so call out `allow_nil?: false` explicitly — only `value` is
nullable, load-bearing per the AshCloak note below):
- `ref` (`:string`, `art_<hex>`) — **`allow_nil?: false`** (always generated)
- `name` (`:string`) — **`allow_nil?: false`**
- `producer` (`:string`) — **`allow_nil?: false`**
- `value` (cloaked `:binary`) — **`allow_nil?: true`** (the only nullable attr; load-bearing, see A1's
  encoding note)
- `state` (`:atom`, `one_of [:pending, :active, :tombstoned]`) — **`allow_nil?: false`**, `default: :pending`
- `child_run_id` (`:uuid`) — **`allow_nil?: false`** (`WaveCollect` always has the wave's child run in
  `context.workflow_run`)
- `wave_index` (`:integer`) — **`allow_nil?: false`**
- `parent_run_id` (`:uuid`) — **`allow_nil?: false`**
- `tenant_id` (`:string`) — **`allow_nil?: false`** (the multitenancy attr)

`store_pending`'s `accept` list + the action thus **require** every non-`value` attribute (a missing one
is rejected at create), and the generated migration carries the matching `NOT NULL` constraints (verify
in the migration SQL, per the user's verify-in-artifact rule).

**Identity + indexes** (in `postgres → custom_indexes`):
- `identity :unique_ref, [:tenant_id, :ref]`
- `index [:tenant_id, :parent_run_id, :name]`
- **named partial unique index** `composer_artifacts_active_ref_index` on
  `[:tenant_id, :parent_run_id, :name, :producer]`, `where: "state = 'active'"` — a **custom index,
  NOT an Ash identity-with-where**; it is a backstop invariant-enforcer (2c's commit helper holds
  uniqueness by tombstoning-before-promoting in one txn). Confirm the `WHERE state = 'active'` clause
  lands in the generated migration SQL (per the user's "verify pattern in generated artifact" rule).

**Actions** (single-transition row actions via `code_interface`, the `ToolOutput` precedent):

| Action | Type | Role (2b wiring) |
| --- | --- | --- |
| `store_pending` | create | insert a `:pending` row; **the raw term enters via a separate non-cloaked `:term` argument** (see below). `WaveCollect` calls it. **Wired in 2b.** |
| `resolve_ref` | read (`get?`) | ref → row, then `Ash.load(row, :value, tenant:, actor:)` to materialize the decrypted calc (the cloaked-load precedent: pass `tenant:`/`actor:`). Resolves **irrespective of `state`**. `ArtifactContext` calls it. **Wired in 2b.** |
| `pending_for_wave` / `active_for_run` | read | recovery/fold reads. Defined in 2b; consumed by 2c/2d. |
| `by_id_global` | read (`multitenancy(:bypass)`) | cross-tenant guard lookup. |
| `activate_for_wave` | **generic action** (`type :action`), **`public?(false)`** | multi-row `:pending → :active` promotion + tombstone-supersede. **Defined in 2b, wired in 2c.** `public?(false)` is the `WorkflowRun.set_status` idiom (`workflow_run.ex:129-131`). |
| `tombstone_active` | update | `:active → :tombstoned`. Defined in 2b, wired in 2c. |

**The `store_pending` encoding subtlety (load-bearing — follow exactly):**
- AshCloak rewrites the accepted cloaked `:value` into an argument of the **attribute type
  `:binary`** (`set_up_encryption.ex:104`), so `:value` only ever carries the *encoded* blob.
- So `store_pending` accepts a **separate non-cloaked `:term` argument** (the raw artifact value) —
  but its `accept` MUST still include `:value` (AshCloak only wires its Encrypt change for a cloaked
  attr **in the accept list**, `set_up_encryption.ex:88-91`); the `code_interface` exposes **only
  `:term`**.
- In `change/3` (runs before any `before_action`, so the Encrypt `before_action` sees the encoded
  blob): normalize `:term` (no-novel-atom, A5), `term_to_binary`-encode a **versioned envelope**
  `{@artifact_version, normalized_term}`, then `Ash.Changeset.force_set_argument(:value, blob)`
  (**`force_set_argument/3`, not `set_argument/3`** — the latter trips
  `maybe_already_validated_error!`, `changeset.ex:6515`).
- **`:value` MUST be `allow_nil?: true`** (P1 — load-bearing): AshCloak rebuilds the cloaked `:value`
  argument carrying the attribute's nullability (`set_up_encryption.ex:96-98`); `require_arguments`
  runs **before** `change/3`, so a non-null `value` would reject a `term:`-only call before the change
  fills it. `:term` is also `allow_nil?: true`; its **suppliedness** (not non-nil-ness) is validated
  via `Ash.Changeset.fetch_argument(cs, :term)` (`:error` ⇒ absent ⇒ reject; `{:ok, nil}` ⇒ a real
  `nil` artifact, normalize + encode + `force_set`). A `nil` artifact value is real — `DefaultMapper`
  emits `nil` when the chosen source is nil — and must round-trip to a stored
  `term_to_binary({@artifact_version, nil})`, not be rejected. (See the user's "AshCloak: omit key for
  NULL" memory for the inverse pitfall.)

**Envelope decode** (used by `resolve_ref` consumers / 2d): `binary_to_term(blob, [:safe])` matching
`{@artifact_version, term}` with a version guard, rescuing `ArgumentError` — sound only because A5
guarantees no novel atoms. Mirror `Replay.decode_blob/1` (`replay.ex:191-201`) and
`encode_checkpoint`/`@checkpoint_version` (`reactor_runner.ex:705-708`). Add a
`composer_artifact_max_bytes` cap (default mirror the 1 MB `@default_replay_inputs_cap`).

**Migration:** `mix ash.codegen --dev` while iterating, then **squash to one named codegen**
(`mix ash.codegen add_composer_artifact`) before precommit (per the user's "Ash codegen --dev then
squash" memory). Register the resource in the `JidoClaw.Orchestration` domain.

### A2. Rewire the artifact flow: values → refs

| File | Change |
| --- | --- |
| `route_composer/fold.ex` | `fold_artifacts/3` (`fold.ex:74-81`) stores a **ref** (`store[name][producer] = ref`), not the value. `available/1` (`fold.ex:41-43`) is unchanged — still "≥1 producer entry". |
| `route_composer/steps/wave_collect.ex` | After running each stage's mapper, **persist each artifact value → a `:pending` row via `ComposerArtifact.store_pending`** (passing `:term`, `parent_run_id`, `child_run_id` from `context.workflow_run`, `wave_index`, `name`, `producer`) and put the returned **ref** into the emission's `artifacts` map. The terminal return stays the same JSON-safe shape (`%{"wave_index", "emissions" => [%{"stage","signals","artifacts" => %{name => ref}}]}`) — now ref-valued. |
| `route_composer/stage_emission.ex` | `artifacts` now `%{name => ref}` (string ref); `from_map/1` unchanged (still atom/string tolerant). |
| `route_composer/artifact_context.ex` | `section/3` / `to_text/1` (`artifact_context.ex:53-68`) now **resolve+decrypt** each ref via `ComposerArtifact.resolve_ref` (tenant/actor threaded from `run_wave`'s `state`) before formatting. **`build/4` changes its return contract to `{:ok, text} \| {:error, reason}`** — a missing ref, corrupt envelope, wrong-tenant ref, or decrypt failure becomes a **controlled wave failure**, never a crash or silent omission. Keep the per-value/total caps. |
| `route_composer/emit/default_mapper.ex` | Apply the **no-novel-atom normalizer** (A5). |
| `route_composer.ex` | `run_wave/3` (`route_composer.ex:342-357`) calls `ArtifactContext.build` with tenant/actor and **branches on its `{:ok, text} \| {:error, reason}`**: an `{:error, reason}` routes to `finish_failed(reason, nil, dispatch, display, state)` (no reactor ran — same shape as the `build_wave` failure clause at `:354-355`), so a resolve/decrypt failure terminates the wave cleanly. `summary/3` (`route_composer.ex:531`) and the `@type summary` artifacts field now carry refs. Moduledoc lines 33-34 / 596 comments updated. |

### A3. Omit `replay_inputs` for composer waves

- `ReactorRunner.run/3` gains an opt **`:omit_replay_inputs`** (boolean, default `false`). When set,
  the `Map.merge(..., replay_inputs_attrs(...))` at `reactor_runner.ex:276` **bypasses
  `replay_inputs_attrs/3` entirely** so the create attrs carry **no `replay_inputs` key** (NOT
  `replay_inputs: nil` — AshCloak would encrypt a present nil into ciphertext-of-nil; the omit-key
  rule, `workflow_run.ex` cloak + the user's AshCloak memory). Same shape as the over-cap branch
  (`replay_inputs_attrs/3` already returns `%{}`, `reactor_runner.ex:372-386`).
- `route_composer.ex:run_reactor/3` passes `omit_replay_inputs: true`. Costs nothing — a composer
  wave carries no `definition_hash` and isn't standalone-replayable; the parent log is the replay unit.

### A4. The decrypted value never re-persists

`ArtifactContext` (A2) decrypts only into the wave's `:extra_context` (live execution). A3 closes the
one orchestration-axis at-rest second copy (`replay_inputs`). The subagent-derived copies are Theme B.

### A5. No-novel-atom normalizer (two places, P3)

`binary_to_term(blob, [:safe])` raises on any atom absent from the post-reboot table (a novel/user
atom); `true`/`false`/`nil` are always interned and stay. `DefaultMapper.coerce/1`
(`default_mapper.ex:160-170`) already stringifies novel atom *values* via its `inspect` catch-all, but
`coerce_key/1` (`:172-173`) **preserves atom keys**, and the `result.result` fallback
(`artifact_or_text/2:121`) returns the value **raw** (no coerce). So:
1. **`DefaultMapper`** — run **every** `output_value` source (typed / artifacts / `result` fallback)
   through `coerce/1`, and change `coerce_key/1` to stringify atom keys via `Atom.to_string/1` (the
   no-atom-creation direction, **never** `String.to_atom/1`).
2. **`store_pending`'s `change/3`** (A1) re-asserts the same normalizer over the raw `:term` before
   `term_to_binary` — belt-and-suspenders so the decode is never handed a novel atom regardless of
   producer/source.

---

## Theme B — the `sanitize_sensitive_context` marker + six sink closures

### B1. Marker origin + the two builder boundaries

- **Origin:** `ReactorRunner.run/3` gains an opt **`:sanitize_sensitive_context`** (boolean, default
  `false`), injected into the merged **reactor context** (`reactor_runner.ex:285-291`, in the
  base map that wins over `extra_context`). The composer's `run_reactor/3` passes it
  (`true` for a sensitive run). This single reactor-context key feeds both the AgentRunner boundary
  (below) and the inline `ReactorMiddleware` read (B4-i).
- **Boundary #1 — `AgentRunner.resolve_scope/2`** (`agent_runner.ex:282-296`, a fixed literal map):
  add `sanitize_sensitive_context: context[:sanitize_sensitive_context] || false`. (This is the same
  pattern `:agent_template` follows, set just after at `agent_runner.ex:61`.)
- **Boundary #2 — `ToolContext.@canonical_keys`** (`tool_context.ex:42-54`, the only keys `build/1`
  keeps): add `:sanitize_sensitive_context`. Keep it **out of `@policy_controlled_keys`**
  (`tool_context.ex:76`) so no `forward_context` policy can strip it (always-forwarded). Because it's
  canonical, `child/2` (`tool_context.ex:150-160`) propagates it to **nested** `spawn_agent`
  (`spawn_agent.ex:101`) and `send_to_agent` (`send_to_agent.ex:52`) children automatically (it is not
  force-overwritten like `:subagent`/`:agent_template`). `ensure_nested/1` lift also keeps it.

### B2. Durable `RequestCorrelation` field + cache mirror (for the lookup-based carriers)

The async consumers (Recorder, Audit) and Trace resolve by scope/`request_id`, so the marker must be
both durable and cached — following the `agent_id`/`subagent` precedent exactly:

- **`conversations/resources/request_correlation.ex`**: add attribute `sanitize_sensitive_context
  :boolean, allow_nil?: false, public?: true, default: false` (mirror `subagent`,
  `request_correlation.ex:201-207`); add it to the `:register` accept list
  (`request_correlation.ex:118-132`). Migration via the same `--dev`-then-squash codegen (fold into the
  A1 codegen).
- **`jido_claw.ex`**: `register_correlation/6` (`:347-399`) — add the marker to the `scope` map
  (`:370-377`) **and** the `RequestCorrelation.register(%{…})` attrs (`:379-387`), sourced from a new
  `opts` key. `register_child_correlation/1` (`:304-331`) forwards
  `sanitize_sensitive_context: Map.get(c, :sanitize_sensitive_context, false)` (mirroring `subagent:`
  at `:323`). The cache-only fallback (`:392-398`) already re-puts `scope`, so the marker survives a
  write failure for free **for unmarked rows** (the marked-write-failure path becomes an abort — C4).
- **`conversations/request_correlation/cache.ex`**: schemaless `:ets` — no code change; update the
  `@moduledoc` shape example (`cache.ex:22-41`) to list the new key.
- **Rehydrate maps** (cache-miss path) must add the marker explicitly or it silently drops:
  `recorder.ex:805-812` (already builds agent_id/subagent) and `signal_listener.ex:145-150` (a **4-key**
  map today that already drops identity flags — add the marker here too).

### B3. The placeholder/digest policy (one centralized module)

New tiny module (e.g. `JidoClaw.RouteComposer.Sanitize` or `Orchestration.SensitiveScrub`) so every
sink applies one consistent, testable policy:
- **Whole-write sanitization when marked** (coarse — the doc's accepted per-subtree over-mark trade);
  never drop the row (P2).
- **Type-preserving placeholders (P3-1 — a string in a `:map` column breaks the cast/consumers):** the
  module exposes **typed** helpers so each field keeps its shape:
  - `redacted_text/0 → "[composer-sensitive:redacted]"` — for string fields (`messages.content`,
    `ToolOutput.content`/`command`, the `result`/`output` text leaves).
  - `redacted_map/0 → %{"redacted" => true}` — for `:map` fields (`messages.metadata`,
    `Audit.Event.payload`'s `arguments`, `WorkflowStep.output`/`WorkflowRun.result` sub-maps, trace
    `metadata`/`measurements`, `typed_output`).
  - `redacted_summary/0` — a shape-valid `ToolOutput.summary` map placeholder.
  Each sink (B4) applies the helper matching the column/field type it writes — never a bare string into
  a map column.
- **`command_fingerprint` — disable deltas for marked commands (P3-2):** a *fixed shared sentinel* would
  make all marked `run_command` calls in a session compare against each other's unrelated history
  (spurious deltas). Instead, for a **marked** command **skip the delta path entirely**: the pre-store
  `delta_line` (`output_shaper.ex:594-607`) returns `""` **without** computing `Store.fingerprint` (so
  the raw command is never even hashed at lookup time), and `Store.do_put` (`store.ex:119`) stores
  **`command_fingerprint: nil`** (no equality oracle, no cross-contamination). A `nil` fingerprint
  already short-circuits both `delta_line`'s `is_binary` guard and `latest_for_fingerprint`, so this is
  the minimal, leak-free choice — trading the delta/dedup feature (acceptable for sensitive commands)
  for zero raw-derived signal at rest.

### B4. The six sinks (+ MCPScope), by carrier

**Carrier (a) — async signal consumers, read marker from resolved scope:**
- **(iv) `Recorder`** — `messages.content`/`messages.metadata`. Gate the content/metadata built in
  `record_tool_call` (`recorder.ex:496-522`), `record_tool_result` (`:528-569`), `record_reasoning`
  (`:575-601`) on `scope[:sanitize_sensitive_context]` → placeholder. Scope comes from
  `resolve_scope/1` (`recorder.ex:794-825`, cache-hit carries marker automatically; cache-miss
  rehydrate per B2).
- **(v) `Audit.SignalListener`** — `Audit.Event.payload`. Gate the `arguments` written into the
  payload map (`signal_listener.ex:111-126`) on `scope[:sanitize_sensitive_context]` → placeholder.
  Add the marker to the rehydrate map (B2). (Note `skip(:correlation_missing)` at `:129`, not 128.)

**Carrier (b) — inline execution-path, read marker from live context:**
- **(i) `ReactorMiddleware`** — `step_completed` payload `:output`, `run_completed` `:result`, and
  `run_failed` `:error` (→ `WorkflowStep.output` / `WorkflowRun.result` / the run's error column). **The
  single chokepoint is the private `append(run, kind, payload, context)`** (`reactor_middleware.ex:410-415`)
  — `emit/3` (step events, `:263`), `complete/2` (`run_completed`, `:211`), **and** `error/2`
  (`run_failed`, `:240`) **all** funnel through it, and it already holds the reactor `context` (with the
  B1 marker). **Correction (P1):** `run_completed` is appended **directly from `complete/2` via
  `result_payload/1`**, *not* through `event/3 → emit/3`, so scrubbing only in `emit/3` would miss it.
  Add a shared **`sanitize_payload(kind, payload, context)`** invoked at the top of `append/4` when the
  context is marked, keyed by `kind` **and the destination column type (P1 — don't put a string in a map
  column):**
  - `run_completed` `:result` → **`redacted_map/0`** (it is the `WaveCollect` emission **map**, projected
    into `WorkflowRun.result`, a **`:map`** column — `workflow_run.ex:250`).
  - `step_completed` `:output` → **`redacted_map/0`** (a map → `WorkflowStep.output`, a `:map` column).
  - `run_failed` `:error` → **`redacted_text/0`** (a string → the run's `:string` `error` column).

  Keep each map column a map so the projection's cast still succeeds (B3-P3-1). **Must be
  pre-append** — `Allocate` stashes the **raw** payload (`allocate.ex:120`) and projects it raw into
  `WorkflowStep.output`/`WorkflowRun.result` (`allocate.ex:287-294`, status_attrs `projection.ex:141-147`),
  so a projection-time scrub is too late. (`append/4` as the one site also covers any future content-bearing
  kind automatically.)
- **(iii) `SubagentTranscript`** — `do_append/6` (`subagent_transcript.ex:118-143`) reads the marker off
  the `tool_context` it's handed (`record_task` carries the injected-artifact `full_task`; `record_terminal`
  the result text) → placeholder `content` when marked.
- **(vii) `OutputShaper.Store`** — `ToolOutput.content`/`command`/`summary`. In `finish_shape/6`
  (`output_shaper.ex:414-466`, `store_attrs` at `:422-430`) read marker off `tc` (`:417`) →
  `redacted_text/0` for `content`/`command`, `redacted_summary/0` for `summary`, and
  **`command_fingerprint: nil` with the delta path skipped** (B3-P3-2). Covers **both** the native
  `shapeable?/3` path **and** the generic `mcp_shapeable?/2 → safe_shape_mcp/3 → shape_mcp_payload/3`
  path (both funnel through `finish_shape`). No new `ToolOutput` attribute — sanitize at write; the
  doc requires the *content* sanitized, not the flag persisted.
- **(viii) `MCPScope`** (under `serve_mode == :mcp` only) — `do_wrap_recorded/5`
  (`mcp_scope.ex:108-177`) appends `content` + `metadata.{arguments,result}` to `messages` directly,
  bypassing the Recorder. Reads marker off `tc` (the subagent's tool_context it already holds) →
  placeholder. (Belt-and-suspenders: the composer never runs under serve-mode today, but close it so a
  future MCP-exposed composer route stays honest.)

**Carrier (c) — async telemetry (Trace), resolve by `request_id`, fail open on `:unknown`:**
- **(vi) `Trace`** — `trace_events.metadata` *and* `measurements`. The collector never gets the tool
  context, so resolve the marker by `request_id` (already lifted in `normalize_event`,
  `collector.ex:344`) against `RequestCorrelation` (cache → durable), inside `normalize_event`
  (`collector.ex:339-378`), then digest `sanitized_metadata`/`sanitized_measurements` (`:342-343`)
  **only when confidently `:marked`** (an `:unknown` span passes through — fail-open).
- **Fail-open semantics (a deliberate deviation — the intended contract):** a new
  resolver `marker_status(request_id) :: :marked | :unmarked | :unknown` — **only a found, marked**
  row digests; a **found, unmarked** row **and** an **absent** row or a **faulting** read (both
  `:unknown`) **pass through unredacted**. Fail-open because (a) the C4 abort-on-marked-write-failure +
  C5 conservative `expires_at` ceiling keep a genuinely-marked span resolvable as `:marked` throughout
  its realistic life, so failing closed buys nothing for marked data; (b) most non-composer telemetry
  carries a `request_id` whose row has expired (~600s TTL) or was never registered, so digesting
  `:unknown` would shred general observability. The residual gap (a marked span past its C5 ceiling, or
  a transient DB fault) is accepted as beyond the designed orphan-drain retention.
- **Scope the lookup to request_id-bearing spans (P2-3 — skip the marker query for no-`request_id` telemetry):**
  the collector handles much telemetry with **no `request_id`** (workflow-level spans, output
  telemetry). `marker_status` is consulted **only for spans that carry a `request_id`**; a **`nil`
  request_id passes through** (treated as `:unmarked`; under fail-open an `:unknown` would pass too, so
  no-`request_id` telemetry is never digested either way — the scoping just avoids a needless query).
  Looking up request_id-bearing spans still matters: that is how a **marked** span is caught. This rests on the invariant
  that a composer subagent's telemetry **always carries its registered `request_id`** (it is registered
  via `register_child_correlation` before the turn runs, C4), so a *sensitive* span always has one to
  look up. **Test both directions:** a request_id-bearing span with a **marked** row **is** digested, while
  unrelated no-request telemetry **and** a request_id-bearing span with an **absent/faulting** (`:unknown`)
  row **pass through** (not digested).

**Not a sink:** `AgentStep` (`agent_step.ex:66`) is the **(ii) propagation seam** that *builds* the
live `full_task` — left **intact** (digesting it breaks artifact consumption); its durable copy is
sanitized at (iii).

### B5. Lift the non-sensitive-fixtures rule (the payoff)

Only after B1-B4 + Theme C land and test green: remove Phase 1/2a's non-sensitive-fixtures restriction
(`route_composer.ex` moduledoc lines 57-62; the fixture-catalog tests) and add tests that route a
**sensitive** `diff`/`approved-plan` end-to-end and assert it appears **nowhere plaintext** across all
six sinks.

---

## Theme C — the TTL / deadline contract

The decrypted value can outlive the wave (orphaned async subagents write after the executor dies —
`run_execution.ex:41-48`), so the marker row must outlive realistic late writes, and a marked row must
always be durable.

### C1. Durable wall-clock deadline `config["deadline_at_ms"]` (one clock source)

The live composer `deadline` is **monotonic** (`route_composer.ex:642-645`) — meaningless across a
reboot. Add a durable **wall-clock `deadline_at_ms`** (unix-epoch milliseconds, **integer**) to the
parent run's `config` under the string key `config["deadline_at_ms"]` (`WorkflowRun.create` accepts
`:config`), written in `create_parent_run/1` (`route_composer.ex:146-168`) from a **single
`System.os_time(:millisecond)` read at genesis** (`deadline_at_ms = t0_ms + deadline_ms`).
**`create_parent_run/1` is the sole clock read.**

**The wiring (P2-1 — close the second-read gap):** today `init/1` recomputes its own deadline from
opts via `deadline_at(Keyword.get(opts, :deadline_ms))` over **monotonic** `now_ms()`
(`route_composer.ex:312,642-645`). That must change: `create_parent_run/1` adds `:deadline_ms` to
what it reads, computes `deadline_at_ms`, and writes it to `config`; `start_composer/2` then passes the
**reloaded `:running` parent** (which carries `config["deadline_at_ms"]`) through, and **`init/1` reads
`config["deadline_at_ms"]` straight from the parent `config`** — *no* second wall-clock read and *no*
monotonic recompute. The loop's `past_deadline?/1` (`route_composer.ex:635-636`) switches to compare
`System.os_time(:millisecond)` vs that stored integer, so the live loop and 2d recovery read the
**identical** value. When `:deadline_ms` is absent (unmarked runs), `config["deadline_at_ms"]` is absent
⇒ unbounded, as today.

**Why an integer (P2 — `config` is JSONB):** a `DateTime` written to a JSON map comes back a **string**
after reload; an **integer** round-trips cleanly (no parse ambiguity) and makes `past_deadline?` a plain
numeric compare. **Test the reloaded-parent path explicitly:** create the parent, reload it, and assert
`init/1` reads back the integer `config["deadline_at_ms"]` and the loop honors it. (ISO8601-string +
parse-on-read is the alternative; unix-ms is chosen for the trivial comparison and zero parse step.)

### C2. Bounded `:deadline_ms` required for marked runs (normative contract change)

A **marked composer run MUST carry a bounded `:deadline_ms`** — an unbounded sensitive run is
**rejected** at launch (`create_parent_run/1` / `start_composer/2` / `run_sync/1`), mirroring C4's
durable-write-failure abort. (Unmarked runs keep `:deadline_ms` optional.) This makes the retention
ceiling's source-of-truth concrete.

### C3. Per-wave wall-clock timeout (`T_wave`) + the `run_killable` mechanism

- `ReactorRunner.run/3` gains opt **`:execution_timeout`** (ms | `:infinity`, default `:infinity`, so
  **non-composer callers are unchanged**). `route_composer.ex:run_reactor/3` passes a composer
  `wave_timeout_ms` (new composer config, documented default ~5 min).
- **The real mechanism (corrects the doc's "thread into the hardcoded `timeout:`"):** the hardcoded
  `timeout: :infinity` at `reactor_runner.ex:512` is passed to **`Reactor.run`**, not to the yield;
  `run_killable` blocks on `Task.yield(task, :infinity)` (`run_execution.ex:113`) which can never
  produce a timeout. So add a **bounded yield + shutdown** in `run_killable`: pop a new
  `:yield_timeout` opt (default `:infinity`), then `Task.yield(task, yield_timeout) ||
  Task.shutdown(task, :brutal_kill)` and match the combined result:
  ```elixir
  case Task.yield(task, yield_timeout) || Task.shutdown(task, :brutal_kill) do
    {:ok, {@registration_conflict, pid}} -> {:duplicate, pid}
    {:ok, result} -> {:reactor, result}   # completed (via yield OR the shutdown race)
    {:exit, reason} -> {:exit, reason}
    nil -> {:exit, :timeout}               # genuinely killed at the deadline
  end
  ```
  **The `{:ok, result}` arm is the race fix (P1-3):** after `yield` returns `nil` the task can still
  finish before the kill, and `Task.shutdown/2` then returns `{:ok, result}` — a wave whose child run
  *actually completed* must fold as `{:reactor, result}`, **never** be collapsed to `{:exit,
  :timeout}`. Only a genuinely-killed task (`shutdown` → `nil`) is the timeout. `execute/6`
  (`reactor_runner.ex:506-514`) passes `yield_timeout: execution_timeout`. The existing
  `{:exit, _} → handle_exit → ensure_failed` path (`reactor_runner.ex:520-521,543-553`) then
  terminalizes the child wave `:failed`. **Default `:infinity` ⇒ byte-identical to today** for every
  existing caller (`Task.yield(_, :infinity)` never returns `nil`, so `Task.shutdown` is never
  reached). (Killing the executor does **not** kill in-flight async subagents — orphan-drain, C5.)

### C4. Tuple-returning `register_child_correlation/1` + caller cleanup

- Widen `register_child_correlation/1` (`jido_claw.ex:304-331`) from bare `String.t()` to a
  **consistently** tuple-returning helper: `{:ok, request_id}` on success, `{:error, reason}` on a
  **marked** failure. The unmarked path stays effectively-infallible (`{:ok, id}` always). **Two
  distinct marked-failure causes — both must abort (P2-2):**
  - **Missing scope.** Today the `_ -> :ok` fallback clause (`jido_claw.ex:308`, hit when
    `session_uuid`/`tenant_id` is absent) **skips registration but still returns the id** — so a
    *marked* run would have **no durable marker row at all**, silently undermining the
    Recorder/Audit/Trace guarantees. For a **marked** context that clause must instead return
    `{:error, :missing_correlation_scope}`; unmarked keeps the `{:ok, id}` skip.
  - **Durable-write failure.** `register_correlation/6` (`:347-399`): for a **marked** registration a
    Postgres write failure surfaces `{:error, reason}` (NOT the cache-only `:ok` fallback at
    `:392-398`); unmarked keeps cache-only `:ok`.
- **Three callers destructure + clean up on abort:** `AgentRunner` (`agent_runner.ex:69`, registers
  after spawn at `:62`) and `spawn_agent` (`spawn_agent.ex:107`, after the tracker register) **stop the
  freshly-spawned pid** on `{:error, _}` (the `:agent_id_taken` reclaim at `spawn_agent.ex:123-128` is
  the precedent); `send_to_agent` (`send_to_agent.ex:57`, a follow-up to a pre-existing agent) simply
  **does not dispatch the turn**, leaving the running agent untouched.

### C5. The conservative `expires_at` ceiling

- Marker `expires_at_ms = deadline_at_ms + T_wave_ms + orphan_drain_ms` — all **unix-ms**, computed from
  the durable `config["deadline_at_ms"]` (C1) — where `orphan_drain` covers the max realistic
  orphaned-subagent lifetime (the subagent's own turn/LLM/tool timeouts), a fixed config constant,
  **not** `T_wave`. **Convert to the field type before registering (P2):** `RequestCorrelation.:expires_at`
  is **`:utc_datetime_usec`** (`request_correlation.ex:212-223`), so the composer computes the ms ceiling
  and passes **`DateTime.from_unix!(expires_at_ms, :millisecond)`** — not the raw integer — into the
  registration. It is one fixed timestamp, stamped at registration, swept **unchanged** by the existing
  `:expired` read (`request_correlation.ex:148-152`) + `sweep_expired/0` (`:279-309`); **no parent-run
  linkage, no status-coupled sweep** added.
- **Data path:** the precomputed `expires_at` rides a **new canonical key
  `:request_correlation_expires_at`** added to `@canonical_keys` + `AgentRunner.resolve_scope/2` (same
  builder path as the marker), and `register_child_correlation/1 → register_correlation/6` thread it to
  the `:register` action's `:expires_at` (`request_correlation.ex:126`). The composer computes it from
  the durable `config["deadline_at_ms"]` (C1) — ms ceiling → `DateTime.from_unix!/2` — and seeds the
  resulting `DateTime` into the wave's reactor context alongside the marker.

---

## New / changed files

**New:** `lib/jido_claw/orchestration/composer_artifact.ex`,
`lib/jido_claw/orchestration/composer_artifact/changes/validate_cross_tenant_fk.ex` (extracted, like
WorkflowRun's), a small sanitizer module, the generated migration + resource snapshot.

**Changed (by theme):**
- **A:** `route_composer/{fold,stage_emission,artifact_context}.ex`,
  `route_composer/steps/wave_collect.ex`, `route_composer/emit/default_mapper.ex`,
  `route_composer.ex`, `orchestration/reactor_runner.ex` (omit-replay_inputs opt), domain registration.
- **B:** `orchestration/reactor_runner.ex` (marker opt), `orchestration/reactor_middleware.ex`,
  `tool_context.ex`, `skills/steps/{agent_step,agent_runner}.ex`,
  `conversations/{subagent_transcript,recorder}.ex`, `conversations/resources/request_correlation.ex`,
  `conversations/request_correlation/cache.ex` (moduledoc), `jido_claw.ex`, `audit/signal_listener.ex`,
  `trace/collector.ex`, `tools/{output_shaper,output_shaper/store,mcp_scope,spawn_agent,send_to_agent}.ex`.
- **C:** `route_composer.ex`, `orchestration/{reactor_runner,run_execution}.ex`,
  `conversations/resources/request_correlation.ex`, `jido_claw.ex`, `tool_context.ex`.

---

## Testing strategy (maps to P1/P2/P3 + the doc's "done when")

- **`ComposerArtifact` (A1)** — focused resource tests (the `ToolOutput` test precedent): `store_pending`
  inserts `:pending` + round-trips a value (incl. a **`nil` artifact**) through encrypt/decrypt via
  `resolve_ref` regardless of state; **both** the `parent_run_id` *and* `child_run_id` cross-tenant
  guards reject; **the lineage assertion rejects a `child_run_id` whose `parent_run_id ≠` the supplied
  parent** (P1-1); the named partial unique index allows multiple `:pending`/`:tombstoned` but ≤1
  `:active` per `{run,name,producer}` (**assert the `WHERE state = 'active'` clause is in the generated
  migration SQL**, per the user's verify-in-artifact rule); a novel-atom term decodes safely after
  normalization; **`store_pending` rejects a missing required (non-null) attribute** (P2 — ref / name /
  producer / state / child_run_id / wave_index / parent_run_id / tenant_id).
- **Rewiring (A2/A5)** — the loop runs identically with refs: `Fold` indexes refs;
  `ArtifactContext` resolves+decrypts; `DefaultMapper` stringifies atom keys + coerces every source;
  no inline value in `WaveCollect`'s return / event payloads / `WorkflowRun.result`.
- **`ArtifactContext` error contract (A2/P1-2)** — a **missing ref**, **corrupt envelope**, and
  **wrong-tenant ref** each make `build/4` return `{:error, reason}` and drive the wave to a controlled
  `finish_failed` (the parent goes `:failed`), never a crash or a silently-omitted artifact.
- **Marker boundaries (B1)** — assert the marker reaches the child `tool_context` through
  `resolve_scope/2` + `@canonical_keys`, and propagates through nested `spawn_agent`/`send_to_agent`.
- **Three carriers (B4)** — (a) Recorder + Audit on cache-hit **and** cache-miss (evict + rehydrate);
  (b) inline `ReactorMiddleware` (assert **all three** kinds through the shared `append/4` are
  sanitized — `step_completed` `:output`, **`run_completed` `:result`**, `run_failed` `:error` — the
  P1 chokepoint) + `SubagentTranscript` + `OutputShaper` (native **and** `mcp_*`); (c)
  `Trace`'s `request_id` lookup in `normalize_event` — **separately** assert confident-marked-digest vs
  `:unknown` (absent/faulting row) **pass-through** (fail-open), **and** that **unrelated no-`request_id`
  telemetry is NOT digested** (P2-3). Assert the **unknown-scope skip** (Recorder/Audit) as a distinct outcome
  from a placeholder write (P2). Assert **type preservation** (P3-1): a digested **map** column
  (`WorkflowRun.result`, `WorkflowStep.output`, `messages.metadata`, `Audit.Event.payload`, trace
  `measurements`) stays a valid map (the row casts/persists), not a bare string — and the `run_failed`
  `:string` error column stays a string.
- **Marked `run_command` fingerprint (B3/P3-2)** — a marked command stores `command_fingerprint: nil`,
  computes no raw hash, and produces no delta against prior marked history.
- **TTL contract (C)** — `create_parent_run/1` is the **sole** clock read; the parent is **reloaded**
  and `init/1` reads back the integer `config["deadline_at_ms"]` (not a recompute, and surviving the
  JSONB round-trip as an integer) and the live loop honors it (P2-1 + serialized-shape); a marked run without a
  bounded `:deadline_ms` is rejected (C2); `:execution_timeout` fires `{:exit, :timeout}` → child
  `:failed`, **and a wave that completes in the `yield`→`shutdown` gap folds as completed, not failed**
  (P1-3), and `:infinity` is byte-identical to today; a marked registration aborts the child turn and
  stops the spawned pid on **both** a durable-write failure **and** missing scope
  (`:missing_correlation_scope`, P2-2) — use a deterministic test-only seam to force each failure (per
  the user's "prove the race test fails without the fix" rule, not a probabilistic test); a marked
  registration's persisted `RequestCorrelation.expires_at` is a valid **`:utc_datetime_usec`** derived
  from `deadline_at_ms + T_wave + orphan_drain` (`DateTime.from_unix!/2`, not a raw integer).
- **P1 end-to-end (B5)** — route a **sensitive** `diff`/`approved-plan` and assert it is absent
  plaintext from: `WaveCollect` return, event payloads, `WorkflowRun.result`, `step_completed`,
  `WorkflowStep.output`, `messages.content`+`metadata`, `Audit.Event.payload`,
  `trace_events.metadata`+`measurements`, `ToolOutput.content`/`command`/`summary` — and that no second
  *encrypted* copy survives in any child wave's `replay_inputs`.

---

## Verification

- **`mix precommit` must pass** — this is the completion gate. Per the user's standing rules: run the
  **full** `precommit` (credo + reach strict kept at **zero** findings; never pipe through `tail`); watch
  the ExSlop clone check when adding the marker-read seam across sibling sink modules (keep the small
  identical `get` seams **non-contiguous**); resolve any credo/reach string-building ping-pong with
  `IO.iodata_to_binary`.
- **Targeted suites:** `mix test test/jido_claw/orchestration/composer_artifact_test.exs`,
  the `route_composer` suite, and the per-sink suites (recorder/audit/trace/output_shaper/mcp_scope).
- **Tidewave smoke checks:** `mix ecto.reset` then exercise `ComposerArtifact.store_pending` /
  `resolve_ref` via `project_eval` to confirm encrypt-at-rest (query the raw `encrypted_value` column
  with `execute_sql_query` and confirm it is ciphertext, not plaintext); run a sensitive-fixture
  composer route via `run_sync/1` and `execute_sql_query` the six sink tables to confirm no plaintext.
- **Style/regression:** `mix format --check-formatted`; the `belongs_to_allow_nil` style test (the
  new resource has no `belongs_to`, so it's clean, but confirm).

---

## Resolved implementation decisions & doc corrections (review before approving)

1. **`run_killable` per-wave timeout + the shutdown race (C3)** — the doc's "thread into the hardcoded
   `timeout:`" is imprecise: that `timeout:` reaches `Reactor.run`, while the gating yield is
   `Task.yield(task, :infinity)`. I add a **bounded `Task.yield(task, t) || Task.shutdown(task,
   :brutal_kill)`** (new `:yield_timeout` opt, default `:infinity` ⇒ unchanged for all current callers),
   and crucially handle `Task.shutdown`'s **`{:ok, result}`** return so a wave that completes in the
   yield→kill gap folds as completed rather than a false `{:exit, :timeout}`. Only a genuinely-killed
   task (`shutdown → nil`) is the timeout.
2. **The deadline becomes wall-clock durable (C1)** — Phase 2a's monotonic `deadline` is kept for
   liveness but the **TTL source of truth + the loop's `past_deadline?`** move to a durable wall-clock
   **`config["deadline_at_ms"]`** (unix-ms integer, JSONB-safe) in parent `config`, so the loop and 2d
   recovery agree across a reboot.
3. **Normative contract changes (C2/C4)** — a marked run **requires** a bounded `:deadline_ms` (else
   rejected), and a marked durable-write failure **aborts the child turn** (no cache-only fallback).
   These are the doc's committed contracts, surfaced here because they change Phase 2a launch behavior.
4. **Tenant shape resolved (A1)** — `ComposerArtifact` uses the **ToolOutput** tenant shape (plain
   `tenant_id` string, no `belongs_to :tenant`), per DURABLE-ENVELOPE line 119, *not* WorkflowRun's
   tenants-FK shape (the explorers flagged the two precedents diverge).
5. **Sanitization is whole-write + centralized (B3)** — coarse per-write placeholder when marked (the
   doc's accepted over-mark trade), one shared sanitizer module, marker-aware `command_fingerprint`
   fronting both storage and the delta lookup.
6. **`activate_for_wave`/`tombstone_active` are defined now, wired in 2c** — the resource ships
   complete in 2b (with isolated tests); promotion stays a 2c concern.
7. **Stale doc line refs corrected** (verified against the tree): `parent_run_id` threads at
   `reactor_runner.ex:274` only (not 245/281/292); `run_config/4` at `:465-471` (not 457); the cloak
   block at `workflow_run.ex:52-55` (not 43-55); the real `resolve_scope/1` at `recorder.ex:794-825`
   (the doc/`signal_listener.ex:6` "280-288" is stale); Audit `skip` at `signal_listener.ex:129`.
8. **Review findings folded in** — this revision incorporates the 8 plan-review findings at their
   sections: **P1-1** `child_run_id` cross-tenant guard + `child.parent_run_id == parent_run_id`
   lineage assertion (A1); **P1-2** `ArtifactContext.build/4` `{:ok,_}|{:error,_}` contract → controlled
   wave failure (A2); **P1-3** `Task.shutdown` `{:ok, result}` race (C3, item 1); **P2-1** single clock
   source — `init/1` reads stored `config["deadline_at_ms"]`, no recompute (C1); **P2-2** marked registration aborts
   on missing scope *and* write failure (C4); **P2-3** Trace marker lookup scoped to request_id-bearing
   spans (nil ⇒ pass, B4-c); **P3-1** type-preserving placeholders (`redacted_text`/`redacted_map`/
   `redacted_summary`, B3); **P3-2** marked `run_command` disables deltas + stores `nil` fingerprint
   (B3). The AshCloak choreography, `action_type(:action)` policy, and `omit_replay_inputs` aim were
   confirmed sound in review and are unchanged.
9. **Second review round folded in** — (a) **`run_completed` chokepoint** retargeted from `emit/3` to
   the shared private `append/4` (which `complete/2`/`error/2`/`emit/3` all funnel through), via a
   `sanitize_payload(kind, payload, context)` covering `step_completed`/`run_completed`/`run_failed`
   (B4-i); (b) **the deadline serialized as a unix-epoch-ms integer** under `config["deadline_at_ms"]`
   (JSONB-safe; wall-clock `past_deadline?`), with the reloaded-parent path tested (C1); (c)
   **`ComposerArtifact` non-null contract made explicit** — every attribute except `value` is
   `allow_nil?: false`, required by `store_pending`, with `NOT NULL` verified in the migration (A1).
10. **Third review round folded in (type correctness at the column boundary)** — (a) `sanitize_payload`
    is keyed by **destination column type**: `run_completed` `:result` and `step_completed` `:output`
    are `:map` columns → `redacted_map/0`; only `run_failed` `:error` (a `:string` column) takes
    `redacted_text/0` (B4-i); (b) the marker `expires_at` is computed in unix-ms then **converted with
    `DateTime.from_unix!(ms, :millisecond)`** before `RequestCorrelation.register`, whose `:expires_at`
    is `:utc_datetime_usec` (C5).
11. **Trace fails open on `:unknown` (B4-c — code-review follow-up, the final contract)** — the original
    plan/design specified the Trace marker resolver fail **closed** (digest on `:marked` *and* `:unknown`);
    the implementation instead ships fail **open** — only a confident `:marked` digests, while `:unknown`
    (an absent or faulting row) passes through. Per the user's decision this is the **intended** contract:
    the C4 abort-on-marked-write-failure + C5 conservative `expires_at` ceiling keep a genuinely-marked span
    resolvable as `:marked` throughout its realistic life (so fail-closed buys nothing for marked data),
    while digesting the common legitimate `:unknown` non-composer span would shred general observability.
    This doc and `AR-2-PHASE-2-DURABLE-ENVELOPE.md` §15.3 are reconciled to match. The async
    `Recorder`/`Audit` fail-safe — skip a write when *scope itself* is unresolvable — is **unchanged** and
    orthogonal to the marker.
