# AR-2 Composer — Phase 2c: Composer Event Log + Projection + Durable Loop

## Context

Phase 1 (`c7a428a`) ran the composer with **all state in GenServer memory** — a crash lost
the route and resume was a blind re-run. Phase 2a (`92d63f2`) made every composer run a real
parent `WorkflowRun` (`workflow_type: "composer"`) with each wave a child linked by
`parent_run_id` and a deterministic `composer:<parent>:<wave_index>` idempotency key — but state
still lived only in memory. Phase 2b (`9495b19`) added the AshCloak-encrypted
`ComposerArtifact` ref-store (`store_pending`/`resolve_ref` live; `activate_for_wave` **defined
but unwired**) and closed every plaintext-at-rest leak.

**Phase 2c makes the run a pure function of durable state.** The parent's append-only
`WorkflowEvent` log carries composer deltas; composer state becomes *re-projectable* from that
log; a wave's `ComposerArtifact` refs flip `:pending → :active` exactly when its `wave_completed`
lands; and the composer becomes a **supervised** process that **rebuilds from the log and
resumes** after a live crash. This is the durable substrate 2d's boot-time crash recovery builds on.

**Decisions taken with the user:**
- **Wire live-restart resume in 2c** — `init/1` rebuilds composer state from the durable log via
  the new projection, so a supervised composer that crashes resumes correctly. Boot-time
  `WorkflowRecovery` scan + the two child-wave re-launch rules stay in **2d**.
- **Define + project + test the not-yet-produced kinds now; producers later** — 2c adds the full
  closed set and folds every kind in the projection (unit-tested via synthetic logs), but the
  **loop only produces** the additive events + the 5 in-loop terminals (+ `signals_retracted`
  on a verdict flip). Gate park/resume + reject/abandon producers are Phase 4;
  stage/artifact-invalidation producers are AR-4.

> Greenfield project — no data/path migration concerns. Nothing is committed; all changes stay
> unstaged. The plan is not "complete" until **`mix precommit`** is green.

---

## Scope: produced vs. defined-only

| Class | Kinds | 2c treatment |
| --- | --- | --- |
| **Additive — produced by the loop** | `route_composed`, `wave_started`, `wave_completed`, `signals_published`, `artifacts_produced` | enum + projection fold + **loop produces** |
| **Subtractive — produced via fold-diff** | `signals_retracted` | enum + projection fold + **loop produces** whenever the fold's paired-verdict LWW retracts a live signal (`clean:<lens>` ⇄ `findings:<lens>`, `fold.ex:58-74`) |
| **Parent-terminal — produced by the loop** | `route_converged`→`:completed`; `route_not_converged`/`route_deadlocked`/`route_budget_exhausted`/`route_failed`→`:failed` | enum + status projection + **loop produces** (the 5 `finish/2` terminals) |
| **Parent-terminal — defined only** | `route_rejected`/`route_abandoned`→`:cancelled`+disposition | enum + status projection + **unit-tested**; producer = Phase 4 gates |
| **Additive (gate) — defined only** | `wave_paused`, `wave_resumed` | enum + projection fold + **unit-tested**; producer = Phase 4 gates |
| **Subtractive — defined only** | `stages_invalidated`, `artifacts_invalidated` | enum + projection fold + **unit-tested** (synthetic logs); no 2c producer (reruns = AR-4; `Fold` does not tombstone the paired artifact today) |

17 new kinds total (7 additive + 3 subtractive + 7 parent-terminal). The loop produces the
5 additive + 5 in-loop terminals, **plus `signals_retracted`** when a paired-verdict flip retracts
a live signal. The remaining kinds (`route_rejected`/`route_abandoned`, `wave_paused`/`wave_resumed`,
`stages_invalidated`/`artifacts_invalidated`) are folded by the projection and exercised via
synthetic-log unit tests; their producers are Phase 4 / AR-4.

---

## Work breakdown

### 1. Event kinds — `lib/jido_claw/orchestration/workflow_event.ex`

Add the 17 composer kinds to the `kind` `one_of` constraint (`workflow_event.ex:100-119`).
**No migration** — `kind` is an Ash `:atom` with an app-level `one_of`, stored as text with no DB
check constraint (same as `WorkflowRun.status`). Verify with `mix ash.codegen --check` (expect no
diff); if it unexpectedly wants one, generate + squash per project convention.

### 2. Status projection — `lib/jido_claw/orchestration/workflow_event/projection.ex`

The single chokepoint for parent status. `Allocate` applies `next_status/2` + `status_attrs/3`
inside the append transaction for any kind in `@status_authority_kinds`.

- Add the **7 parent-terminal kinds** to `@status_authority_kinds` (`projection.ex:35-45`). The
  additive/subtractive kinds stay **out** → they persist as pure-log events (parent stays
  `:running` across a wave).
- `next_status/2` (`projection.ex:100-111`, before the `:illegal` catch-all): `route_converged`
  (`:running → :completed`); `route_not_converged`/`route_deadlocked`/`route_budget_exhausted`/
  `route_failed` (`@non_terminal → :failed`); `route_rejected`/`route_abandoned`
  (`@non_terminal → :cancelled`).
- `status_attrs/3` (`projection.ex:137-175`) — model on `:run_completed`/`:run_failed` (which lift
  `result`/`error` via `fetch/2`), **not** on `:run_cancelled` (which drops its payload,
  `projection.ex:157`): `route_converged` lifts `result`; the four `:failed` kinds lift `error`;
  `route_rejected`/`route_abandoned` get their **own** clauses → `:cancelled` lifting `result`
  (so `result.disposition` survives). All set `clear_checkpoint: true`.
- No new `WorkflowRun.status` atom — the 7 terminals reuse existing statuses (`workflow_run.ex:225-233`);
  `result`/`error`/`clear_checkpoint` are write-reachable via `set_status` (`workflow_run.ex:136,145`).
- **Abnormal-path terminals stay generic.** Only `finish/2` loop terminals become `route_*`; the
  crash/timeout/reload/start-failure path (`terminalize_parent/4`, `route_composer.ex:732`) keeps
  writing `:run_failed`. Both project to `:failed`, so `Projection.terminal_status?/1` covers both
  (see step 5 init guard + step 6).

### 3. Composer-state projection — NEW `lib/jido_claw/route_composer/projection.ex`

`JidoClaw.RouteComposer.Projection` (distinct from `WorkflowEvent.Projection`). The rebuild
capability 2c's `init/1` uses and 2d's `WorkflowRecovery` will reuse.

```
project(seed_state, events) -> %{live, artifacts, ran, premises, prev_route, wave_index}
```

- **Folds durable deltas onto the seed** in `seq` order — a *fresh* run (log = `[run_started]`)
  yields the seed unchanged; a *resumed* run yields seed + wave deltas. One code path, no
  fresh/resume branch:
  - `route_composed` → `premises` (latest-wins) + `prev_route` (snapshot route); its `live`/
    `available` snapshot is **legibility only**, never folded as authority
  - `wave_completed` → `ran = ran ∪ payload.stages`; advance `wave_index` to `max(_, idx + 1)`
  - `signals_published` → `live = live ∪ signals`; `signals_retracted` → `live = live \ signals`
  - `artifacts_produced` → `store[name][producer] = {:ref, ref}` (**tagged** to match the live
    `Fold` store, `fold.ex:82-90`); `artifacts_invalidated` → delete `store[name][producer]`
  - `stages_invalidated` → `ran = ran \ payload.stages`
- **Mirrors `Fold`'s net effect exactly** — including paired-verdict semantics: a `clean:<lens>`
  that retracts a live `findings:<lens>` arrives as a `signals_retracted` delta (emitted by the
  loop's diff, step 5), so applying union(`published`) + difference(`retracted`) reproduces
  `Fold`'s LWW (`fold.ex:58-74`). This is what makes the **equivalence invariant**
  `project(seed, log) == in-memory` true.
- `available` is derived via `Fold.available/1` (`fold.ex:42-45`), never folded.
- The seed (`request-received` / `request` artifact, from `init/1` opts) is the fold base, so the
  rebuilt state correctly merges seeds (not in the log) with wave deltas.
- **No custom terminal-scan helper** — `init`'s "don't resume a finished run" guard reuses
  `WorkflowEvent.Projection.terminal_status?/1` on the **reloaded parent status** (covers generic
  `:run_failed`/`:run_completed` *and* the new `route_*` terminals; see step 5).

### 4. Composer-commit helper — NEW `lib/jido_claw/route_composer/commit.ex`

`JidoClaw.RouteComposer.Commit.commit_wave(parent, wave_index, deltas, opts) :: :ok | {:error, reason}`
— the one place the ref state-flip is welded to the parent-log append. Mirrors the shipped
3-resource transact pattern (`workflow_log.ex:105` `gate_open/3`):

```elixir
case Ash.transact([WorkflowEvent, WorkflowRun, ComposerArtifact], fn ->
  with {:ok, locked} <- reload_for_update(parent, opts),                # Query.lock("FOR UPDATE"), allocate.ex:140
       :ok           <- refuse_if_terminal(locked),                     # {:error, :parent_terminal} before any write
       {:ok, _} <- WorkflowLog.append(locked, :wave_completed, %{wave_index:, stages:}, opts),
       :ok      <- append_each(locked, content_events, opts),           # signals_published / signals_retracted / artifacts_produced
       {:ok, _n} <- ComposerArtifact.activate_for_wave(locked.id, wave_index, opts) do
    :ok
  end
end) do
  {:ok, :ok}  -> :ok                  # Ash.transact WRAPS the fn result — :ok ⇒ {:ok, :ok}
  {:error, r} -> {:error, r}          # fn returning {:error, _} rolls the txn back
end
```

- **Parent-status guard (load-bearing).** `wave_completed`/content events are deliberately
  **non-status-authority**, so `Allocate` does **not** status-check them (`allocate.ex:160` guards
  authority kinds only) — it would happily append them, and `activate_for_wave` would promote refs,
  onto an **already-terminal** parent (e.g. an operator cancel landing while a child wave returns).
  So the helper **reloads the parent `FOR UPDATE`** inside the txn (the `Allocate.lock_run`
  precedent, `allocate.ex:140`) and returns `{:error, :parent_terminal}` **before** any append/
  activate if `Projection.terminal_status?`. The loop treats `:parent_terminal` as "the run already
  ended" → stop cleanly, **don't** re-terminalize (step 5).
- **Return unwrap.** `Ash.transact/3` wraps a successful fn result, so the `:ok`-returning fn yields
  `{:ok, :ok}`; normalize to `:ok` (a rolled-back fn stays `{:error, r}`), else the caller's `:ok`
  branch never matches.
- `wave_completed` is appended **unconditionally** (the fold-applied marker), even for an
  empty-emission wave — so recovery reads the marker, not presence-of-content, as "folded."
- `append_each([], _opts) → :ok` (empty content list is a success — empty-emission waves are
  explicitly supported). Content events list only the **non-empty** deltas.
- `activate_for_wave` (code interface, `composer_artifact.ex:128`) opens its own
  `Ash.transact([ComposerArtifact])` (`activate_for_wave.ex:28`) — nesting is fine because the
  outer list includes `ComposerArtifact` (shared `JidoClaw.Repo`, savepoint). **Any leg failing
  rolls back the whole wave commit** → no orphaned `:active` row, no half-written log; the active
  set is always a function of the durable log.
- Cannot reuse `WorkflowLog.append_all/3` — it transacts `WorkflowEvent` only (`workflow_log.ex:53`).
- The re-lock inside `Allocate` (`allocate.ex:140`) re-acquiring the same row within the txn is
  fine (Postgres `FOR UPDATE` is re-entrant per transaction); seqs allocate correctly and the
  parent stays `:running`.

### 5. Loop rewrite — `lib/jido_claw/route_composer/route_composer.ex`

- **Pre-launch appends** (in `run_wave`/`run_built_wave`, `route_composer.ex:442-470`, before
  `run_reactor`): append `route_composed` (the `compose_route` result + `premises` + `live` +
  derived `available`, **JSON-safe**) then `wave_started` (`wave_index`, `stages`, `route_hash`,
  `catalog_hash`). Compute the hashes as **canonical sha256 hex** over a normalized term (sorted
  stage names / catalog) — reuse `Orchestration.DefinitionFingerprint` or the
  `:crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))` pattern
  (`tool_approvals.ex:111-113`), **not** `:erlang.phash2`. They are **correlation /
  catalog-drift-detection metadata** (the `wave_index` + idempotency key are the identity), but a
  canonical hash keeps them robust if they later gain semantic weight
  (`feedback_canonical_fingerprint_term`). `wave_started` must commit **before**
  `ReactorRunner.run/3` (2d detects a pre-creation crash from it).
- **Durable commit on the `:completed` fold path** (`handle_wave_value/5`, `route_composer.ex:501-508`):
  1. compute `next = Fold.fold(state, emissions)` (pure; safe to compute before the commit);
  2. derive deltas by **diffing** pre/post state — `signals_published = next.live \ state.live`,
     **`signals_retracted = state.live \ next.live`** (captures paired-verdict flips — *not* assumed
     empty), `artifacts_produced = new {name,producer,ref} in next.artifacts`, `stages = dispatch`;
     the diff guarantees the durable log equals the in-memory fold by construction;
  3. `case Commit.commit_wave(parent, wave_index, deltas, opts) do`
     - `:ok` → `record_wave(next, …)` and continue the tick (`{:noreply, …, {:continue, :tick}}`);
     - `{:error, :parent_terminal}` → the run ended externally → `{:stop, :normal, state}` (don't
       fold/record, don't re-terminalize — `append_parent_terminal` already no-ops a terminal parent);
     - `{:error, reason}` → **`finish_failed(reason, run, …)`** — terminalize the parent
       `route_failed`; **do not** fold/record/continue from memory as if durable state landed.
- **`finish/2` — durable append first, then conditional notify** (`route_composer.ex:607-642`).
  Today the durable terminal append is *inside* the `send/2` argument (`route_composer.ex:611`), so
  guarding the send on `notify` presence would skip the write for supervised runs. Refactor:
  ```elixir
  defp finish(terminal, state) do
    {kind, reason} = classify_terminal(terminal)        # kind STAYS :converged | :failed | …
    summary = summary(kind, reason, state)
    payload = parent_terminal_notify(kind, reason, summary, state)  # durable append happens here
    maybe_notify(state, payload)                         # send ONLY if state.notify
    {:stop, :normal, %{state | terminal: kind, reason: reason, summary: summary}}
  end
  ```
  - Keep `classify_terminal/1` and `summary.terminal` as the bare symbols (`:converged`,
    `:not_converged`, …) — existing tests assert `summary.terminal == :converged`
    (`composer_loop_test.exs:87`) and `terminal_summary_subset/1` stores
    `Atom.to_string(summary.terminal)` (`route_composer.ex:759`). **Only the event kind changes.**
  - Inside `parent_terminal_notify/4`, map the symbol → `route_*` event kind (`:converged →
    :route_converged`, `:not_converged → :route_not_converged`, `:deadlock → :route_deadlocked`,
    `:budget_exhausted → :route_budget_exhausted`, `:failed → :route_failed`) and call the
    unchanged reload-guarded `append_parent_terminal/5` (`route_composer.ex:688-705`) with it.
  - `maybe_notify/2` = `if state.notify, do: send(state.notify, {:route_composer, state.ref, payload})`.
  - Extend `scrub_terminal_payload/3` (`route_composer.ex:717-722`) to redact `:error` on the four
    `route_*` error kinds **and** the abnormal-path `:run_failed`, for marked runs.
- **`init/1` resume** (`route_composer.ex:365-403`): build the seed state, return
  `{:ok, seed_state, {:continue, :rebuild}}`. New `handle_continue(:rebuild, state)`: reload the
  parent (`WorkflowRun.by_id`); if `WorkflowEvent.Projection.terminal_status?(parent.status)` →
  `{:stop, :normal, state}` (don't resume a finished run); else load events
  (`WorkflowEvent.for_run`), `state = Projection.project(seed, events)` →
  `{:noreply, state, {:continue, :tick}}`. Fresh runs (log = `[run_started]`) project to the seed
  unchanged — backward-compatible with `run_sync/1` and existing tests.
  - **Rebuild error handling (no tight restart loop).** A parent-reload or event-load **error**
    (transient DB blip) must not crash a `:transient` child into a restart loop. Factor the rebuild
    into a shared `do_rebuild/1` driven by **both** `handle_continue(:rebuild, state)` **and a new
    `handle_info(:rebuild_retry, state)`** — `Process.send_after/3` delivers as an info message, not
    a continue, so the retry needs its own `handle_info` head. On error, retry a small capped number
    of times via `Process.send_after(self(), :rebuild_retry, backoff)` (a `rebuild_attempts` counter
    in state); if still failing, **log loudly and `{:stop, :normal, state}`** — leaving the parent
    `:running` for 2d boot recovery / a future Pooler, **not** terminalizing a recoverable run. (The
    composer supervisor's `max_restarts: 10`/`max_seconds: 30` is a backstop, not the design.)
- **Dedupe-hit on a still-running child — bounded observe, not fail** (`handle_wave_result`,
  `route_composer.ex:480-486`). A live composer crash does **not** kill its in-flight wave: the
  wave runs `async_nolink` and survives to finish durably (`route_composer.ex:276-280`). So on a
  restart re-dispatch the dedupe-hit child may be `:running`/`:pending`. Today that branch
  `finish_failed`s — which would fail a *recoverable* route. Replace with:
  - `:completed` → fold its durable emission + `commit_wave` (recovers a dropped fold);
  - `:running`/`:pending`/`:awaiting_approval` → **bounded read-only observe**
    (`await_existing_child/3`: poll `WorkflowRun.by_id` until terminal or `state.wave_timeout_ms`,
    matching 2b's per-wave `T_wave` bound), then re-branch on the terminal status;
  - terminal `:failed`/`:cancelled`/`:abandoned`, or observe timeout → `finish_failed`
    (conservative; 2d's fresh-`wave_index` re-dispatch + gate-park handling extend this).

  This observe is a **targeted read-only poll reachable only on restart re-dispatch** (a fresh
  linear run never gets a dedupe hit), not the Phase-4 async-execution refactor.
- **Re-dispatch may re-append `route_composed`/`wave_started` for the in-flight `wave_index`** —
  harmless: the projection keys `ran` off `wave_completed` (not `wave_started`), the idempotency
  key dedups the child, and content deltas only land in the once-per-`wave_index` commit. 2d's
  correlation contract may dedupe these; 2c accepts the benign duplicate.
- **JSON-safe payload helper** — `MapSet → sorted list`, atom values → strings (e.g. `dropped`'s
  `:off_path`/`:unsatisfiable_input`) for every composer event payload; the projection reads
  tolerantly (string keys). Load-bearing — a `MapSet`/novel-atom payload fails to persist or
  round-trips wrong (`feedback_pin_types_at_ash_persistence_boundaries`).

### 6. Supervised lifecycle — `application.ex` + `route_composer.ex`

- **`application.ex`**: add to `infra_children` next to `RunRegistry`/`RunTaskSupervisor`
  (`application.ex:153-154`, always-started core group, no mode gate):
  `{Registry, keys: :unique, name: JidoClaw.RouteComposer.Registry}` and
  `{DynamicSupervisor, name: JidoClaw.RouteComposer.Supervisor, strategy: :one_for_one,
  max_restarts: 10, max_seconds: 30}` — the restart-intensity backstop the rebuild note references
  (DynamicSupervisor defaults to `3`/`5`; this matches the root supervisor's intensity).
- **`route_composer.ex`**: `start_link/1` (`route_composer.ex:153`) names via
  `{:via, Registry, {JidoClaw.RouteComposer.Registry, parent_run_id}}`. Add `ensure_started/2`
  (find-or-start keyed by `parent_run_id`): `Registry.lookup` → `DynamicSupervisor.start_child`
  with an explicit `restart: :transient` spec (`id: {__MODULE__, parent_run_id}`), collapsing
  `{:already_started, pid}` — mirroring `VFS.Workspace.start_fresh/2` (`vfs/workspace.ex:92-111`)
  + `CodeServer.ensure_project_runtime/1` (`code_server.ex:16-21`). The composer already exits
  `{:stop, :normal, state}` on every terminal, so `:transient` gives "crash → restart → init
  rebuilds + resumes; normal terminal → no restart."
- **Reuse the existing start-opt choreography** — `start_composer/2` threads `:parent_run_id` +
  the **stored durable `deadline_at_ms` from `parent.config`** (`route_composer.ex:244-247`); `init`
  derives the seed context (`request_correlation_expires_at`) from it. Factor that threading into a
  shared `build_start_opts(opts, parent)` used by **both** `start_composer/2` (unlinked) and
  `ensure_started/2` (supervised), so sensitive-run TTL/deadline behavior cannot drift across paths.
- Make `notify`/`ref` **optional** (supervised runs have no sync caller; the durable terminal is the
  source of truth) — `maybe_notify/2` (step 5) already guards the send. `run_sync/1`
  (`route_composer.ex:295-307`) stays the **unlinked + monitored** sync path, unchanged beyond the
  optional-notify guard.

### 7. `composer_artifact.ex` — no change

`activate_for_wave` + `set_active`/`tombstone_active` + the `composer_artifacts_active_ref_index`
partial-unique index shipped complete in 2b. 2c only **calls** `activate_for_wave` from the commit
helper. *(Optional 2c+ hardening, out of core scope: split `resolve_ref` into a public `:active`-only
reader + a `public?(false)` recovery-only `:pending` reader.)*

---

## Critical files

| File | Change |
| --- | --- |
| `orchestration/workflow_event.ex` | +17 kinds in the `kind` `one_of` |
| `orchestration/workflow_event/projection.ex` | +7 terminal kinds to authority set + `next_status/2` + `status_attrs/3` (disposition-lifting clauses) |
| `route_composer/projection.ex` *(new)* | composer-state fold `project(seed, events)` mirroring `Fold` (incl. paired-verdict via `signals_retracted`) |
| `route_composer/commit.ex` *(new)* | `commit_wave/4 :: :ok \| {:error, _}` — 3-resource atomic `wave_completed` + content + `activate_for_wave` |
| `route_composer/route_composer.ex` | pre-launch appends; durable commit + commit-failure branch; `finish/2` payload-first + conditional notify + `route_*` kinds; `init` resume; dedupe-hit observe; shared `build_start_opts`; supervised `start_link`/`ensure_started`; JSON-safe payloads; extend `scrub_terminal_payload` |
| `application.ex` | +`RouteComposer.Registry` + `RouteComposer.Supervisor` |

## Reuse (don't re-invent)

- `WorkflowLog.append/4` + the 3-resource `gate_open/3` transact pattern (`workflow_log.ex:105`).
- `Orchestration.DefinitionFingerprint` (canonical sha256 over a deterministic term,
  `definition_fingerprint.ex:75-80`) for `route_hash`/`catalog_hash`; the `Query.lock("FOR UPDATE")`
  reload (`Allocate.lock_run`, `allocate.ex:140`) for the commit-helper parent-status guard.
- `ComposerArtifact.activate_for_wave/2` code interface (`composer_artifact.ex:128`,
  `activate_for_wave.ex`) — tombstone-before-promote already correct.
- `WorkflowEvent.Projection.fetch/2` (atom/string tolerance) + `terminal_status?/1` (init guard);
  `StageEmission.from_map/1` (`stage_emission.ex:40-47`); `Fold.fold/2` + `Fold.available/1`.
- `ReactorRunner.ensure_failed/3` (`reactor_runner.ex:761-773`) — the reload-guard model
  `append_parent_terminal/5` already mirrors.
- Find-or-start idiom: `VFS.Workspace.start_fresh/2` (`vfs/workspace.ex:92-111`),
  `CodeServer.ensure_project_runtime/1` (`code_server.ex:16-21`).

---

## Tests

`use JidoClaw.TenantCase, async: false` for anything touching the singleton registry/supervisor;
sweep leaked supervised children in `on_exit` (`cancellation_test.exs:48-52`). Recovery is already
disabled in test (`config/test.exs:16`).

- **`WorkflowEvent.Projection`**: `next_status/2` + `status_attrs/3` for all 7 terminals, incl.
  `route_rejected`/`route_abandoned` lifting `result.disposition` (assert **not** dropped), and the
  reloaded **JSONB string-keyed** payload path.
- **`RouteComposer.Projection`** (synthetic logs): folds additive + subtractive/gate kinds;
  `project(seed, [run_started]) == seed`; **equivalence** — `project(seed, durable deltas)` equals
  the in-memory `Fold` result for a multi-wave run, **including a paired-verdict flip**
  (`clean:<lens>` retracting a live `findings:<lens>` round-trips via `signals_retracted`).
- **`Commit.commit_wave/4`**: `wave_completed` + content + `activate_for_wave` atomic (refs
  `:active` **iff** `wave_completed` landed); empty-emission wave still writes `wave_completed` and
  promotes zero rows (`append_each([])` ⇒ success); a forced leg failure rolls back **all**;
  **a parent already terminal ⇒ `{:error, :parent_terminal}`, no event appended, no ref promoted**
  (the `FOR UPDATE` reload guard).
- **Commit failure in the loop**: a `commit_wave` error does **not** fold/record/continue from
  memory — `{:error, reason}` → parent `route_failed` (no `:active` rows leak); `{:error,
  :parent_terminal}` → composer stops `:normal` without re-terminalizing.
- **Pre-launch append failure**: a failed `route_composed`/`wave_started` append terminalizes the
  parent (the wave does not silently launch un-recorded).
- **Rebuild failure (no tight loop)**: an injected parent-reload / `WorkflowEvent.for_run` error in
  `handle_continue(:rebuild)` retries up to the cap then stops `:normal` (parent left `:running`),
  never crash-looping.
- **Loop** (via `run_sync/1`): per-wave `route_composed → wave_started → wave_completed (+ content)`
  in order; each `finish/2` terminal maps to its `route_*` kind and projects the right
  `WorkflowRun.status`, while `summary.terminal` stays the bare symbol; marked-run
  `scrub_terminal_payload` redacts the new error kinds. Regression: a clean non-resumed run behaves
  identically to 2b.
- **Supervised resume**: `ensure_started/2` is single-owner per `parent_run_id`; start under the
  supervisor, kill the pid mid-route → transient restart → `init` rebuilds → resumes remaining waves
  → parent reaches a durable terminal; a still-`:running` dedupe-hit child is **observed to terminal
  then folded** (not failed); `terminal_status?` makes a restart-after-terminal stop `:normal`.
- **Supervised terminal without notify**: a supervised run (no `notify`/`ref`) still writes its
  durable parent-terminal event (the append is not skipped) and sends nothing.

## Verification

1. `mix ash.codegen --check` → **no pending migration** (greenfield safety net).
2. `mix test test/jido_claw/route_composer/ test/jido_claw/orchestration/` (+ new test files).
3. End-to-end via Tidewave / `mix jidoclaw`: drive a composer route with `run_sync`, then
   `mcp__tidewave__execute_sql_query` the `workflow_events` log (per-wave kind sequence + the
   `route_*` terminal) and `composer_artifacts` (rows `:active` only after their wave's
   `wave_completed`, ≤1 active per `{run,name,producer}`).
4. **`mix precommit` green** — the definition of done. Keep credo/reach strict at zero; build
   strings with `IO.iodata_to_binary` (not `<>`-around-`Enum.join`); avoid a 3rd identical
   contiguous `defp` seam across sibling modules (ExSlop clone check); never pipe precommit through
   `tail`.

## Notes / risks

- **Type-pinning at the JSONB boundary is the top risk** — composer payloads must be JSON-safe
  and the projection must read string-keyed; test the reloaded path, not just the live map.
- **Equivalence by construction** — the loop derives content deltas as a *diff* of pre/post `Fold`
  state, so `project(seed, log)` equals in-memory for any fold (incl. paired-verdict). `Fold` not
  tombstoning the paired *artifact* today (a possible §7 2b gap) does **not** break equivalence —
  the diff faithfully mirrors whatever `Fold` does; that gap is separate and out of 2c scope.
- **`wave_completed` is the resume boundary** — rebuild `wave_index` = completed-wave count; a
  dangling `wave_started` re-dispatches under its deterministic key → observe/fold-or-fail.
- **Abnormal-path terminals stay `:run_failed`** (generic), distinct from loop `route_*` terminals;
  both project to `:failed` and are covered by `terminal_status?/1`.
- **Leave the 2a recovery no-op intact** — `WorkflowRecovery.classify/1`'s composer guard
  (`workflow_recovery.ex:133`) + observe-only branch (`:244`) stay untouched; 2d replaces them.
