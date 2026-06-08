# Phase 2 — Human Approval Gates (durable halt → restart → resume)

## Context

`jido_radclaw` is adopting **Reactor as its single workflow engine, wrapped in a durable
"envelope"** borrowed from Squidie (append-only event log, status-as-projection, crash
recovery, human gates). The full direction is in
`docs/exploration/squidie/REACTOR-ADOPTION.md`; the event-log spec is in
`docs/exploration/squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md`.

Two phases are already committed:

- **Phase 0** — `WorkflowEvent` append-only log, `seq` allocated under a per-run
  `FOR UPDATE` lock, **projection-owned `WorkflowRun.status`** (written only by the append
  path via `WorkflowEvent.Projection`), `WorkflowLog` append seam, and a boot-time
  `WorkflowRecovery` reconciler (no-gate stranded-run case only).
- **Phase 1** — `ReactorRunner` (runs an `Ash.Reactor` under a `WorkflowRun`, auto-wires
  middleware, terminal-durability backstop), `ReactorMiddleware` (the sole event producer:
  `init`/`complete`/`error`/`event`, **no `halt/1`**), and the `ProjectRegistration` saga
  with durable undo.

The documented next step is **Phase 2 — human approval gates**. Its hard core is the one
genuinely difficult problem (REACTOR-ADOPTION §7): **a workflow that pauses for a human
decision must survive an application restart and resume correctly.** Today
`ReactorRunner.finalize({:halted, _}, ...)` treats *any* halt as a failure
(`reactor_runner.ex:190-195`), and `:awaiting_approval` is a status with no producer — the
gate machinery is stubbed but unreachable.

**Goal of this slice (keystone):** prove durable halt → persist → restart → resume on **one**
gate kind (`irreversible_write`), end-to-end, with operator approve/reject exposed across the
**code API, the CLI REPL, and the web dashboard**. Deliberately deferred: the T2-5 Spark
gate-DSL and the separate `AgentCaseEvent` timeline table (run-level gate facts live in the
existing `WorkflowEvent` log; the operator-facing record is the `AgentCase` row).

**Greenfield** — no backwards-compat or data-migration concern. The orphaned `ApprovalGate`
stub is deleted and replaced, not grown.

### Correction to the planning docs (verified)

The T1-1 / T2-2 / FEATURES docs repeatedly claim the redaction key-set is "suffix-only" and
**misses** bare keys (`password`, `secret`, `token`, `authorization`, `credential`) and
prescribe widening it. **This is stale** — `lib/jido_claw/security/redaction/env.ex:42,89-92`
already matches those exact keys (`@sensitive_exact`), with passing tests
(`test/.../redaction/env_test.exs:23-29`). The append path already redacts event
payload/metadata through the recursive `Redaction.Transcript`. **No redaction work is in
scope.**

---

## What this slice does NOT need (already in place / out of scope)

- Event payload redaction — done (above).
- `WorkflowEvent.kind` already enumerates `:approval_requested`, `:approval_resolved`,
  `:run_halted`, `:run_resumed`, `:run_recovered` (`workflow_event.ex:102-117`).
- `WorkflowRun.status` enum already includes `:awaiting_approval`; the projection already has
  `next_status(:awaiting_approval, :run_resumed) → {:ok, :running}` (`projection.ex:69`).
- `WorkflowLog.append_all/3` already gives atomic multi-event transactions (`Ash.transact`).
- **Out of scope** (documented follow-ups): Spark gate DSL (T2-5), `AgentCaseEvent` timeline,
  multi-gate-per-run, replay/fingerprint (Phase 4), deadlines / actor-visibility / cron
  idempotency (Phase 5), async event `Writer`, cron→Reactor bridge, checkpoint **encryption**
  (Decision 2), per-step idempotency keys (Decision 7 caveat). Do **not** touch
  `JidoClaw.Platform.Approval` — a separate in-process *tool-call* approval GenServer,
  unrelated to workflow gates.

---

## Key decisions (locked; flag at approval if you disagree)

1. **Halt-state strategy = (A) persist the halted struct** (REACTOR-ADOPTION §7). Verified
   feasible: a halted `%Reactor{}` from a **compiled DSL-module** reactor run `async?: false`
   is `:erlang.term_to_binary`-serializable — no live task refs (sync execution keeps them on
   the executor stack, not the struct), the `plan` is a pure term tree (survives `Macro.escape`
   at compile time), step values are plain Ash records. **Constraints for any gate-bearing
   reactor:** `async?: false`, no anonymous-fun step `transform`s (use remote captures
   `&Mod.fun/1`), downstream-of-gate steps read plain data. Strategy (B) stays an unproven
   follow-up.
2. **Checkpoint storage = a private plaintext `:binary` column on `WorkflowRun`**
   (`resume_checkpoint`, `public?: false`). **Encryption-at-rest via the existing
   `AshCloak`/`Vault` pattern (`security/secret_ref.ex`) is a documented fast-follow** — the
   blob holds unredacted inputs/results and the threat model weights leakage hygiene. (Encrypting
   means a sibling `WorkflowRunCheckpoint` resource since the `JidoClaw.Resource` macro can't add
   the AshCloak extension — deferred to keep the slice on the resume mechanic.)
3. **Reject appends a terminal directly, not `approval_resolved`.** `approval_resolved` is
   **approve-only** = "decision recorded, resuming" (→ `:running`). Reject appends `run_cancelled`
   (legal from `:awaiting_approval`) and records the decision on the `AgentCase` row. Avoids a
   never-observed ghost `:running` and makes recovery's signal clean.
4. **Runner keeps its 2-shape envelope.** A legitimate gate pause returns
   `{:ok, {:paused, agent_case_id}, run}` (run carries `status: :awaiting_approval`) — **not** a
   new tuple shape — so existing `ReactorRunner` callers/tests don't break.
5. **Recovery branches on projected status + checkpoint presence only** (DB-only, no event
   fold), equivalent to "decision recorded" given Decision 3's projection rules.
6. **Resume detection lives in `init/1`, keyed on `context.__reactor__.initial_state`**
   (verified: `reactor/.../executor/hooks.ex:15-24` injects it — `:pending` on first run,
   `:halted` on every resume). `init/1` appends `run_started` on `:pending` and `run_resumed`
   on `:halted`. This makes `init/1` the **single producer** of both, for *every* resume path
   (operator approve **and** boot recovery) — callers never append them. (Resolves the gap where
   resume would otherwise re-append `run_started`.)
7. **Checkpoint lifecycle is centralized in the projection.** The runner writes
   `resume_checkpoint` on pause; **every terminal event clears it** because the projection's
   `status_attrs/3` for `run_completed`/`run_failed`/`run_cancelled` sets `resume_checkpoint:
   nil` in the same transaction as the status flip. So a checkpoint exists *only* while a run is
   `:awaiting_approval` or `:running` (resume in flight) and is gone the moment it terminates —
   on completion, failure, reject, or recovery cancellation — with no per-call cleanup to forget.
   **Caveat:** a crash *mid-resume* re-runs the gate's downstream steps from the frozen gate-halt
   checkpoint, so downstream steps in gate reactors **should be idempotent**; per-step idempotency
   keys are the Phase-4/§4.11 follow-up.
8. **Gate hooks (`after_approved`/`after_rejected`) are best-effort notifications, NOT durable
   workflow steps.** Durable, must-happen work belongs in the reactor's downstream steps (which
   resume durably). The hooks run once on the **operator decision path** (post-commit,
   best-effort, logged on failure); on the **boot-recovery resume path** they are **skipped**
   (the decision already committed; re-running the reactor does the durable work). This is the
   honest contract — making hooks crash-exactly-once would require persisting per-hook execution
   state, which is out of scope. Tests assert hook markers only on the no-crash operator path.
9. **Reject cancels the run; it does not roll back completed *upstream* steps.** A gate is
   positioned **before** the irreversible downstream write: approve runs the downstream steps,
   reject prevents them and terminates the run `:cancelled`. Already-committed pre-gate steps are
   **left as-is** (saga-style undo-on-reject is a follow-up; place gates before irreversible work).
   The keystone test reactor keeps its pre-gate step pure (no DB write) so reject leaves nothing
   orphaned.

---

## Implementation steps (ordered)

### Step 0 — Delete the orphaned `ApprovalGate`
- Delete `lib/jido_claw/orchestration/approval_gate.ex` and its
  `priv/resource_snapshots/repo/approval_gates/*.json`.
- Remove `resource(JidoClaw.Orchestration.ApprovalGate)` from `orchestration.ex` and
  `has_many(:approval_gates, …)` from `workflow_run.ex:178`. (Drop migration → Step 9 codegen.)

### Step 1 — Projection: gate transitions + terminal checkpoint-clear (`workflow_event/projection.ex`)
- Extend `@status_authority_kinds` with `:approval_requested` and `:approval_resolved`.
- Transitions:
  - `next_status(:running, :approval_requested) → {:ok, :awaiting_approval}`
  - `next_status(:awaiting_approval, :approval_resolved) → {:ok, :running}` (approve = resuming)
  - `next_status(:running, :run_resumed) → {:ok, :running}` **(idempotent — required:** `init/1`
    appends `run_resumed` on resume, by which point approve already set `:running`; Decision 6).
- `:run_halted` stays **non-authority** (provenance, no status move).
- `status_attrs/3`: add `:approval_requested` (`%{status: :awaiting_approval}`) and
  `:approval_resolved` (`%{status: :running}`). **Add `resume_checkpoint: nil` to the three
  terminal clauses** (`run_completed`/`run_failed`/`run_cancelled`) so terminals clear the
  checkpoint atomically (Decision 7). `approval_resolved`/`run_resumed` (→`:running`) do **not**
  clear it (resume still needs it).
- Allocate (`changes/allocate.ex`) needs no change — it routes through these functions.

### Step 2 — `WorkflowRun`: checkpoint field + actions (`workflow_run.ex`)
- Add `attribute :resume_checkpoint, :binary, allow_nil?: true, public?: false`. The column holds
  a **single `:erlang.term_to_binary` blob** — the encoded checkpoint envelope defined in Step 5,
  **not** an Elixir map (the type is `:binary`, decoded only by `GateResume`, Step 6).
- Private `update :set_checkpoint` accepting `[:resume_checkpoint]` (runner writes the blob on
  pause; no status precondition).
- Extend the existing private `:set_status` accept list with `:resume_checkpoint` so the
  projection's terminal `status_attrs` can null it in the status-flip transaction (Decision 7).
- `list_non_terminal_global` already returns the row, so recovery reads `.resume_checkpoint`.

### Step 3 — `AgentCase` resource (`lib/jido_claw/orchestration/agent_case.ex`, new)
- `use JidoClaw.Resource, domain: JidoClaw.Orchestration` (tenant-scoped policies). **Must
  declare `read :by_id_global` with `multitenancy(:bypass)`** — the base macro injects a
  `bypass action(:by_id_global)` policy and won't compile without it (copy `workflow_run.ex:66`).
- Attributes: `tenant_id`, `belongs_to :workflow_run` (non-null), `step_name :string`,
  `kind :atom` (one_of `[:irreversible_write]`), `gate_module :atom`, `status :atom` (default
  `:pending`, one_of `[:pending, :approved, :rejected, :cancelled]`), `details :map`
  (operator-visible, redactor-safe), `decision :atom` (nullable), `decided_by_id :uuid`
  (**nullable** — CLI runs unauthenticated, `repl.ex:204`), `decided_at`, `decision_comment`,
  `cancellation_reason`, `timestamps()`.
- Actions: `create :create`; `read :pending_for_run`; `read :pending_for_tenant` (filter
  `status == :pending` — backs CLI/web inbox); `read :by_id_global`; `update :approve` /
  `update :reject` / `update :cancel`. **The race/idempotency fence must be database-level, not a
  validation over loaded data** — two concurrent approvers can both read `:pending`. Put a
  **`change filter(expr(status == :pending))`** on each decision update action (Ash's built-in
  `filter/1` change for update/destroy changesets — the compile-safe idiom that compiles to a
  DB-side `UPDATE … WHERE status = 'pending'`); exactly one writer wins and the loser gets a
  stale/`{:error, _}` (the idempotency + concurrency fence) — see Step 7.
- `code_interface`: `define` for all the above (copy the shape from the deleted
  `approval_gate.ex:13-20`). Add `has_many :agent_cases` to `WorkflowRun`; register in
  `orchestration.ex`.

### Step 4 — Gate behaviour + gate step + `gate_open` helper
- **`lib/jido_claw/orchestration/gate_context.ex`** (new) — a small struct/typed-map
  `%GateContext{run, agent_case, decision, tenant, actor}` passed to gate hooks. **Decouples
  hook callbacks from `Reactor.context()`** (reject builds no reactor context; approve runs the
  hook outside the resume context) — resolves the hook-contract inconsistency.
- **`lib/jido_claw/orchestration/gates.ex`** (new) — behaviour:
  `@callback after_approved(GateContext.t()) :: :ok | {:error, term()}`,
  `@callback after_rejected(GateContext.t())`, optional `field_metadata/0` + `presentation/0`
  with default impls via `__using__` (`use … kind: :irreversible_write`). **No Spark DSL.**
- **`lib/jido_claw/orchestration/gate_step.ex`** (new) — a `Reactor.Step`. `run/3` calls
  `WorkflowLog.gate_open(run, agent_case_attrs, opts)` then returns `{:halt, agent_case.id}`;
  `{:error, reason}` on failure (middleware appends `run_failed`).
- **`WorkflowLog.gate_open/3`** (`workflow_log.ex`, new) — one transaction over shared
  `AshPostgres`/`JidoClaw.Repo`, using **`with`/`else` that returns `{:error, reason}`** (never
  match-fail — an expected Ash error must roll back cleanly, not raise; mirror `append_all/3`'s
  `reduce_while` style). No `case` as a variable name. Shape:
  ```
  Ash.transact([AgentCase, WorkflowEvent], fn ->
    with {:ok, gate} <- AgentCase.create(attrs, opts),
         {:ok, _ev} <- append(run, :approval_requested, %{agent_case_id: gate.id, ...}, opts) do
      {:ok, gate}
    end                       # any {:error, reason} bubbles up → Ash.transact rolls back
  end)
  ```
  **No broadcast here** — the gate is not announced until its checkpoint exists (Step 5).

### Step 5 — Middleware `init/1` resume branch + `halt/1` + runner pause handling
- **`reactor_middleware.ex`**:
  - **`init/1`** — branch on `context[:__reactor__][:initial_state]`: `:pending` → append
    `run_started` (current behavior); `:halted` → append `run_resumed` (Decision 6). Keep the
    "fail loudly if append fails" behavior on the **initial** start; on resume, a failed
    `run_resumed` append is best-effort (provenance — the decision is already durable).
  - **`halt/1`** (new, `@impl true`) — resolve run, append `:run_halted` (provenance), **always
    return `{:ok, context}`** even on append failure (verified: a `halt/1` error turns the run
    into `{:error, _}` — `executor.ex:124-130`; `approval_requested` is the authoritative status
    event, so log + continue). Leave `{:run_halt, _}` in `map_event/2` as `:ignore`.
- **`reactor_runner.ex`**:
  - Thread **both `inputs` and `reactor_module`** from `run/3` through `execute/6` into the
    shared finalizer's opts (currently dropped) — the module is needed to re-encode a checkpoint
    if execution halts **again** at a later gate.
  - Rewrite `finalize({:halted, reactor}, run, inputs, opts)`: reload run; **legit gate halt iff
    `reloaded.status == :awaiting_approval`** (only the gate step's in-txn `approval_requested`
    reaches it). If legit: persist checkpoint via `WorkflowRun.set_checkpoint(reloaded,
    %{resume_checkpoint: encode_checkpoint(reactor, inputs, opts[:reactor_module])}, …)`; **then
    broadcast
    `{:gate_requested, …}`** (after the checkpoint exists — closes the approve-before-checkpoint
    race from the producer side); look up the pending `AgentCase`; return `{:ok, {:paused,
    case.id}, reload(...)}`. If not legit (status unchanged, or `{:halted}` from
    `max_iterations`): keep `ensure_failed(run, :unexpected_halt, opts)`.
  - **Checkpoint envelope is a binary with an explicit two-layer format** so the outer layer
    decodes with `[:safe]` *without* needing any module atoms loaded:
    `encode_checkpoint(reactor, inputs, module) ::
    :erlang.term_to_binary({@checkpoint_version, Atom.to_string(module), inner})` where `inner =
    :erlang.term_to_binary({reactor, inputs})`. The outer tuple is `{integer, string, binary}` —
    no custom atoms — so `GateResume` (Step 6) safely decodes it, resolves + `Code.ensure_loaded?`
    the module from the string, *then* decodes `inner`. This is why the column is `:binary`
    (Step 2), not a map.

### Step 6 — `GateResume` — the shared "run the persisted reactor" mechanism
- **`lib/jido_claw/orchestration/gate_resume.ex`** (new). `resume(run, opts)` is **pure
  deserialize + run + finalize — it appends no status event** (the `approval_resolved` flip is
  done atomically by `Cases.decide` before this is called; Step 7 / P1 atomicity). Steps:
  1. Reload; guard **`status == :running`** and `resume_checkpoint != nil` (after `Cases.decide`'s
     commit it is `:running`; recovery's decision-already-recorded case is also `:running` — there
     is no resume from any other status).
  2. **Two-stage decode** (matches the Step 5 envelope): outer `{version, module_string, inner} =
     :erlang.binary_to_term(blob, [:safe])` (no module atoms needed); reject an unknown `version`.
     **Constrained module resolution** (the only place DB content becomes an atom): require
     `module_string` to start with an allowlisted gate-reactor prefix (e.g.
     `"Elixir.JidoClaw.Orchestration.Reactors."`), else fail-with-audit — this bounds atom
     creation to our own namespace; then `module = String.to_atom(module_string)` (safe given the
     validated prefix + version) and `Code.ensure_loaded?(module)` → fail-with-audit if not loaded.
     **Then** `{reactor, inputs} = :erlang.binary_to_term(inner, [:safe])` (the reactor's atoms now
     exist because the module is loaded). Wrap the whole decode in a narrow rescue →
     fail-with-audit on any corrupt/undecodable/disallowed/unknown-module blob (may need a
     `# reach:disable-for-this-file bare_rescue` pragma like `reactor_runner.ex:66`).
  3. Read the **approved `AgentCase`** for the run; put its decision into `context[:approval]`
     (the decision is sourced from the durable row, not a parameter).
  4. `Reactor.run(reactor, inputs, %{tenant:, actor:, workflow_run: reloaded, reactor:, approval:
     decision}, run_id: run.id, async?: false, timeout: :infinity, max_iterations: :infinity)`.
  5. Pass through the shared `ReactorRunner.finalize` (extract it to a `@doc false` entry so the
     initial run and resume reuse one finalizer — completes, fails, or pauses again uniformly; the
     terminal clears the checkpoint via Decision 7). **Pass the decoded `reactor_module` in the
     finalizer opts** so a *second* halt during resumed execution can re-encode a valid checkpoint
     (Step 5's `encode_checkpoint(reactor, inputs, opts[:reactor_module])`).
- **Resume contract (document in moduledoc):** the halted gate step's stored result is the
  *halt value* (`case_id`), so downstream steps must read the decision from `context[:approval]`
  (declare `argument :approval, context: [:approval]`), never the gate step's result; and the
  full original input set must be re-supplied (Reactor re-validates declared inputs every run —
  `init.ex:53`). `init/1` appends `run_resumed` automatically (Decision 6), so `GateResume`
  never appends it.

### Step 7 — `Cases.decide/4` orchestrator + the three surfaces
- **`lib/jido_claw/orchestration/cases.ex`** (new) — `decide(case_id, :approve | :reject, attrs,
  opts)`, the single decision point all three surfaces funnel through (so the **decision is
  recorded once**). For both decisions: load case + run; **guard the run has a `resume_checkpoint`**
  (defends the approve-before-checkpoint race from the consumer side — return `{:error,
  :not_yet_resumable}` if absent; the producer-side broadcast delay in Step 5 normally prevents
  this). Each decision transaction uses **`with` returning `{:error, reason}`**, never match-fail:
  - **Approve:** **one transaction** — case decision and status event commit together or not at
    all (P1: no split):
    ```
    Ash.transact([AgentCase, WorkflowEvent], fn ->
      with {:ok, gate} <- AgentCase.approve(agent_case, attrs, opts),   # pending-guarded
           {:ok, _ev} <- WorkflowLog.append(run, :approval_resolved, %{...}, opts) do  # → :running
        {:ok, gate}
      end
    end)
    ```
    After commit: build a `GateContext`, run `gate_module.after_approved(ctx)` **best-effort,
    logged** (Decision 8 — not exactly-once), then `GateResume.resume(run)`.
  - **Reject:** **one transaction** `{ AgentCase.reject (pending-guarded) ; WorkflowLog.append
    (:run_cancelled → :cancelled, which clears the checkpoint via Decision 7) }`, same `with`
    shape. After commit, `gate_module.after_rejected(ctx)` (best-effort). No `GateResume`, no
    upstream undo (Decision 9).
  - The pending-only guard (Step 3) makes a duplicate `decide` a clean no-op/error (idempotent).
  - Broadcast `{:gate_resolved, …}` afterward.
- **7a Code API** — `Cases.decide/4` (exercised by tests).
- **7b CLI** — `cli/commands/approvals.ex` (new) + `"/gates …"` dispatch in `cli/commands.ex`
  (copy `/cron remove` `commands.ex:548-562`, `/profile` subdispatch `:733-739`): `/gates` lists
  `AgentCase.pending_for_tenant`; `/gates approve|reject <id> [comment]` → `Cases.decide/4` with
  `Actor.system(state.tenant_id)`.
- **7c Web** — `web/live/approvals_live.ex` (new) + `live("/approvals", ApprovalsLive)` in
  `web/router.ex:79-88` (inside `live_session :require_auth`). Copy `dashboard_live.ex` for
  `current_actor`/mount + `setup_live.ex` for `phx-click` → `handle_event` calling
  `Cases.decide/4`; reuse `<.status_badge>` (`core_components.ex:60-63`).
- **7d Gate PubSub** — extend `RunPubSub` with `{:gate_requested,…}`/`{:gate_resolved,…}` +
  `subscribe_gates/0`. `gate_requested` is broadcast from the runner **after** the checkpoint
  persists (Step 5); the inbox refreshes on both (debounced, per `dashboard_live.ex:115-131`).

### Step 8 — Recovery: gate-aware branches (`workflow_recovery.ex`)
Branch on `run.status` + `run.resume_checkpoint` (a checkpoint is written **only** after a run
reaches `:awaiting_approval`, so the legal `(status, checkpoint)` pairs are constrained):
- `:awaiting_approval` **+ checkpoint** → **parked**, no-op (correctly waiting; `AgentCase` open).
- `:awaiting_approval` **+ no checkpoint** → **dangling gate** (crash between `gate_open` commit
  and checkpoint persist): one transaction — append `{:run_cancelled, %{reason: "recovered:
  dangling gate"}}` **and** `AgentCase.cancel` the pending case (terminal auto-clears any
  checkpoint via Decision 7, though there is none here).
- `:running` **+ checkpoint** → **decision-already-recorded** (approve committed → `:running`,
  crash before/within resume): `GateResume.resume(run, recovered: true)` (reads the approved case,
  re-runs; `init/1` appends `run_resumed`; **`after_approved` is skipped** per Decision 8;
  idempotency caveat per Decision 7).
- `:running` **+ no checkpoint** → existing `WorkflowLog.append_recovery` (→ `:failed`).
- `:pending` **(any)** → existing `WorkflowLog.append_recovery` (→ `:failed`). A `:pending` run
  never started; **`:pending` + checkpoint is an impossible/corrupt state** (checkpoint is only
  written after `:awaiting_approval`) — fail-with-audit and `Logger.warning` the unexpected pair,
  **never** resume it.
- Extend telemetry metadata with a `:branch` tag. **No manual checkpoint clearing** — terminals
  clear it centrally (Decision 7).

### Step 9 — Test support + migration
- `test/support/jido_claw/gates/test_irreversible_write.ex` — behaviour impl recording
  `after_approved`/`after_rejected` to ETS (idempotent).
- `test/support/jido_claw/reactors/gated_test_reactor.ex` — 3-step reactor: a **pure pre-gate
  step** implemented as a **tiny named `Reactor.Step` module** (or a remote-capture step — **no
  inline anonymous transform**, per Decision 1's serialization constraint) with **no DB write**
  (so reject leaves nothing orphaned, Decision 9) → `GateStep` (`:irreversible_write`, test gate)
  → the post-gate **Ash create** (the "irreversible write") declaring `argument :approval,
  context: [:approval]`. Pattern the Ash step off `reactors/project_registration.ex`.
- One `mix ash.codegen add_human_gates && mix ecto.migrate` after Steps 0–3 (drops
  `approval_gates`, creates `agent_cases`, adds `workflow_runs.resume_checkpoint`).

### Step 10 — Tests (the "done" matrix, `test/jido_claw/orchestration/`)
`JidoClaw.TenantCase` + `seed_tenant`/`actor_for`.
1. **Happy path:** gated reactor → `{:ok, {:paused, id}, run}`, `:awaiting_approval`, checkpoint
   non-nil, events `run_started → step_* → approval_requested → run_halted` in `seq` order; then
   `Cases.decide(id, :approve)` → run `:completed`, **`run_resumed` (not a second `run_started`)**
   + `approval_resolved` present, workspace row exists, `after_approved` marker set, **and
   `resume_checkpoint` is nil** (terminal cleared it — Decision 7).
2. **Reject:** decide `:reject` → run `:cancelled`, `run_cancelled` present, **no**
   `approval_resolved`, **no** post-gate write (workspace row absent; pre-gate step is pure so
   nothing is orphaned — Decision 9), `after_rejected` marker set, checkpoint nil.
3. **Parked gate survives recovery:** halt; `reconcile_all()` → unchanged.
4. **Dangling gate cleaned:** `gate_open` without checkpoint; `reconcile_all()` → run
   `:cancelled`, case `:cancelled` (+ reason), `run_cancelled` appended.
5. **Decision-already-recorded resumes on boot:** drive approve up to the `approval_resolved`
   commit but skip the resume → `:running` + checkpoint + approved case; `reconcile_all()` →
   `:completed`, **post-gate write (workspace row) exists** (downstream durable work ran),
   `run_resumed` present, checkpoint nil. **`after_approved` marker is NOT set** — the hook is
   skipped on the recovery path (Decision 8); durability comes from the reactor steps, not the
   hook.
6. **Approve-before-checkpoint is guarded:** with a pending case but `resume_checkpoint == nil`,
   `Cases.decide(:approve)` returns `{:error, :not_yet_resumable}` and the case stays `:pending`.
7. **Serialization smoke test:** `Code.ensure_loaded?(mod)` then
   `binary_to_term(term_to_binary(halted_reactor), [:safe])`, assert `state == :halted`, key
   fields equal. **Caveat noted in the test:** a same-VM round-trip does not prove cross-boot
   atom/module availability — the real guard is the versioned envelope + `Code.ensure_loaded?`
   in Step 6 (a true separate-BEAM resume is a follow-up smoke test).
8. **Tenant isolation:** tenant B can't read tenant A's pending `AgentCase`.
9. **Illegal move:** `run_completed` from `:awaiting_approval` is rejected by the projection.
10. **Duplicate/concurrent decision (the key race):** after a successful `Cases.decide(id,
    :approve)`, a **second** `decide` (approve *or* reject) returns `{:error, _}`, the `AgentCase`
    stays `:approved`, and **no second `approval_resolved`/`run_cancelled` is appended** (assert the
    event count is unchanged). This directly exercises the DB-side `change filter(expr(status ==
    :pending))` fence (Step 3).
- Plus a CLI command test and a LiveView `handle_event` test (direct-socket style per
  `dashboard_live_test.exs`).

---

## Critical files

- Modify: `orchestration/workflow_event/projection.ex`, `orchestration/workflow_run.ex`,
  `orchestration/reactor_middleware.ex`, `orchestration/reactor_runner.ex`,
  `orchestration/workflow_recovery.ex`, `orchestration/workflow_log.ex`, `orchestration.ex`,
  `cli/commands.ex`, `web/router.ex`.
- New: `orchestration/agent_case.ex`, `orchestration/gate_context.ex`, `orchestration/gates.ex`,
  `orchestration/gate_step.ex`, `orchestration/gate_resume.ex`, `orchestration/cases.ex`,
  `cli/commands/approvals.ex`, `web/live/approvals_live.ex`, two `test/support` modules.
- Delete: `orchestration/approval_gate.ex` (+ snapshot).
- Reuse: `WorkflowLog.append_all/3` + `Ash.transact`, `Projection`
  (`status_authority?`/`next_status`/`status_attrs`), `Authorization.Actor.system/1`,
  `JidoClaw.Resource` macro + `:by_id_global` shape, `RunPubSub`,
  `CoreComponents.<.status_badge>`, `LiveUserAuth`/`current_actor`.

## Verification

**`mix precommit` must pass** (the completion bar). It runs, in order (`mix.exs:245-254`):
`jidoclaw.compile_check` (clean recompile, zero warnings beyond the 3-entry allowlist —
**don't add to it**), `jidoclaw.system_prompt.check` (**check whether adding `/gates` requires
updating `priv/defaults/system_prompt.md` + `.jido/system_prompt.md`**), `deps.unlock --unused`,
`format`, `reach.check --arch --smells --strict` (new modules smell-free; mind the `GateResume`
rescue pragma), `credo --strict`, `dialyzer --format short` (specs must be right), `test`.

Run incrementally: `mix compile --warnings-as-errors`,
`mix test test/jido_claw/orchestration/`, then full `mix precommit`.

**Manual end-to-end** (after migration): `iex -S mix`, run the gated test reactor via
`ReactorRunner.run/3`, confirm it pauses; then `mix jidoclaw` → `/gates` → `/gates approve <id>`
(or the web `/approvals` inbox) and watch it complete. Verify the timeline
(`WorkflowEvent.for_run/2`) shows `approval_requested → run_halted → approval_resolved →
run_resumed → run_completed`, and that `run.resume_checkpoint` is nil afterward.

## Risks / watch-items

- **§7(A) serialization** is load-bearing — retire it first via the smoke test (Step 10.7).
  Same-VM round-trip ≠ true cross-boot proof; the versioned envelope + `Code.ensure_loaded?`
  before `[:safe]` decode (Step 6) is the real guard, with a separate-BEAM resume test as a
  follow-up.
- **`mix ash.codegen`** must cleanly produce the drop+create+alter migration; review before
  `ecto.migrate`.
- **`reach.check` / `credo` / `dialyzer`** are real gates — budget spec + smell cleanup on the
  new `GateResume`/`Cases` modules and the decode rescue.
- **Crash mid-resume re-runs downstream steps** from the frozen gate-halt checkpoint — gate
  reactors' downstream steps must be idempotent for safe recovery (Decision 7 caveat); per-step
  idempotency keys are a Phase-4 follow-up.
- Keep the **single-gate-per-run** simplification explicit; multi-gate identification (reading
  the halted step name) is a follow-up.
