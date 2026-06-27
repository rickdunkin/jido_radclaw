# WS1 lease — close the gate-halt fence gap (review P1)

## Context

The WS1 lease core makes a `WorkflowRun`'s owner durable and **fenced** so a
reclaimed ("zombie") executor can't write truth after losing its lease. The
shipped fence design enumerates *"three terminal-writing paths"* and claims
fence A (runner-side, reload-first token compare) + fence B (in-txn token guard
in `Allocate`) neutralize all three.

A code review found a **fourth** durable-write path the fence misses: the
**gate halt**. A `GateStep` opening a human-approval gate is a *status-authority*
write (`approval_requested` → `:awaiting_approval`) **plus** a durable
checkpoint write, and **neither fence covers it**. So a stale owner that reaches
a gate before its sidecar kills it can open a duplicate `AgentCase`, flip the run
to `:awaiting_approval`, and persist a stale resume checkpoint — breaking the
"rotated token owns truth" guarantee for gate workflows.

**Validity / severity.** Confirmed by full code trace (below). It is **not**
live-exploitable in WS1 as shipped — nothing rotates a token under a *live*
executor yet (reclaim/`claim_next` is unit-tested but WS3-triggered; gate-resume
only runs after the original executor halts). But WS1's contract is to ship the
fence *mechanism* complete ("unit-tested, not production-triggered until WS3"),
so this completeness hole belongs in WS1 — when WS3 ships reclaim, a zombie at a
gate goes live. **P1 within the WS1 fence scope.**

### Confirmed trace

1. `GateStep.run/3` (`gate_step.ex:62-65`) calls `WorkflowLog.gate_open/3` with
   only `tenant:`/`actor:` — **no `claim_fence_token`** — though the reactor
   context already carries `claim_token` (seeded at `reactor_runner.ex:317`,
   resume at `gate_resume.ex:166`).
2. `gate_open/3` (`workflow_log.ex:118-143`) appends `:approval_requested`
   (`:124-131`) with no fence token. It is the **sole production producer** of
   `approval_requested`; `GateStep` is its **sole production caller** (composer
   gate waves halt at the same `GateStep`, launched via `ReactorRunner.run/3` at
   `route_composer.ex:1186`, so they inherit the threaded token).
3. `Allocate.claim_fenced?` (`allocate.ex:153-162`) fences **only**
   `[:run_completed, :run_failed]`. `:approval_requested` slips through;
   `Projection.next_status(:running, :approval_requested)` → `:awaiting_approval`
   (`projection.ex:132`, status-authority at `:68`).
4. `finalize({:halted, reactor}, …)` (`reactor_runner.ex:731-740`) sees
   `:awaiting_approval` and persists the checkpoint via `handle_gate_pause`.
   **No `fenced?` check** on the halt clause — unlike `handle_exit` (`:632`) and
   `finalize({:error,_})` (`:717`).

## The fix (two parts, defense in depth)

**Part 1 — Fence B covers the gate flip (load-bearing).** Thread the held token
`GateStep → gate_open → approval_requested`, and broaden `Allocate.claim_fenced?`
from the hardcoded terminal pair to **any status-authority kind** via the
already-imported `Projection.status_authority?/1`. Once `approval_requested` is
fenced, the stale owner's whole `gate_open` transaction rolls back → `GateStep`
returns `{:error,_}` → the reactor *errors* (never halts) → the existing fence A
in `finalize({:error,_})` returns a clean `:fenced`. No `AgentCase`, no flip, no
checkpoint.

The broad rule is safe by construction: the fence only fires when a token is
**present AND mismatched**, which is only ever a reclaimed owner — operator,
recovery, and legacy appends pass no token (no-op), and a legit executor always
carries its own matching token (it stamped the row, incl. `run_started` /
`run_resumed`, which `ReactorMiddleware.append/4` already threads at
`reactor_middleware.ex:420`). It single-sources "what is status-authority" to the
projection, a function `Allocate` already calls at `:191`.

**Part 2 — Fence A on the halt path.** Add a `fenced?` guard to
`finalize({:halted, reactor}, …)`, ordered **after** the `:cancelled` check and
**before** `:awaiting_approval` (mirroring `handle_exit/3` /
`finalize({:error,_})`). Closes the append→checkpoint TOCTOU (token rotates
*after* a legit `approval_requested` commits but *before* the checkpoint write)
and the case where the reclaimer itself parked the run at a gate. No-op when
tokens match ⇒ byte-identical for single-node and every legit pause.

## File-by-file changes

### `lib/jido_claw/orchestration/workflow_event/changes/allocate.ex`
Replace the `claim_fenced?/2` kind guard with `Projection.status_authority?/1`
(the chosen broad form). Update its preceding comment + the moduledoc's fence-B
description to say "status-authority write" instead of "terminal." `Projection`
is already aliased (`:63`) and called (`:191`); no new dependency.

### `lib/jido_claw/orchestration/workflow_log.ex`
`gate_open/3`: forward `claim_fence_token: Keyword.get(opts, :claim_fence_token)`
to its internal `:approval_requested` `append/4` call only (not `AgentCase.create`
/ `case_event` — those aren't `WorkflowEvent` appends; the surrounding
transaction rolls them back on rejection). Additive opt → the two existing test
callers (`human_gates_test.exs:463`, `composer_durable_test.exs:1169`) stay green.
Update the `append/4` and `gate_open/3` docs to note the fence now covers the gate
flip.

### `lib/jido_claw/orchestration/gate_step.ex`
Pass `claim_fence_token: context[:claim_token]` in the `gate_open` call
(`:62-65`). `nil` for a degraded/legacy run ⇒ no-op.

### `lib/jido_claw/orchestration/reactor_runner.ex`
Convert the `finalize({:halted, reactor}, run, opts)` `if` (`:731-740`) to a
`cond` whose branch order mirrors `handle_exit/3` (`:625`) and
`finalize({:error,_})` (`:711`): **`:cancelled` first**, then
`fenced?(reloaded, opts) -> {:error, :fenced, reloaded}`, then the existing
`:awaiting_approval -> handle_gate_pause`, then the `:unexpected_halt` branch.
Putting `:cancelled` ahead of `fenced?` preserves the cancellation vocabulary
(a cancelled-during-halt run surfaces the clean `{:error, :cancelled, run}`
rather than `:fenced`/`:unexpected_halt`), consistent with the other two fence
paths. `fenced?` already exists (`:647`); `{:error, :fenced, run}` and
`{:error, :cancelled, run}` are already in `run_result()` — no spec change. Note
the fence in the "Gate pause" moduledoc section.

### `docs/plans/clustering/WS1-lease-core.md` (doc reconciliation)
The fence-stop design says "three terminal-writing paths." Reframe to
"status-authority + checkpoint writes" and record the gate-halt path as covered
by fence B (broadened to `status_authority?`) + fence A (halt-clause guard).

## Tests — `test/jido_claw/orchestration/workflow_lease_test.exs`

Add three tests beside the existing fence cases (the file already has the seeding
helpers `seed_run`, `stamp`, `rotate_token!`, `reload_global`, `scope`, and
aliases `Builder`; add aliases `GateStep`, `JidoClaw.Gates.TestIrreversibleWrite`,
`AgentCase`):

1. **Fence B rejects a stale `approval_requested`** (mirrors the existing
   fence-B test #7): `run_started` → stamp T → `rotate_token!` to T′ →
   `WorkflowLog.append(run, :approval_requested, %{agent_case_id: …},
   claim_fence_token: T)` → `{:error,_}`, status stays `:running`; with `T′` →
   succeeds, status `:awaiting_approval`.
2. **Fence A on a rotated-token halt writes no checkpoint**: `run_started` →
   stamp T → legit `approval_requested` (token T) → `:awaiting_approval` →
   `rotate_token!` to T′ → `ReactorRunner.finalize({:halted, Builder.new()},
   reloaded, Keyword.merge(scope(ctx), claim_token: T, inputs: %{},
   reactor_module: nil))` → `{:error, :fenced, _}`, and
   `encrypted_resume_checkpoint` still `nil`. **The `scope(ctx)` tenant/actor are
   required** — `finalize`'s internal `reload/2` (`:910`) reads
   `WorkflowRun.by_id(tenant:, actor:)` and falls back to the stale in-memory run
   on a nil-tenant miss, which would read the pre-rotation token and defeat the
   test. (The fence short-circuits before `handle_gate_pause`, so the reactor arg
   is inert.)
3. **End-to-end `GateStep.run/3` threading**: `run_started` → stamp T →
   `rotate_token!` to T′ → call `GateStep.run(%{}, %{workflow_run: run,
   actor: actor, claim_token: T}, gate_module: TestIrreversibleWrite,
   step_name: "gate", details: %{})` → `{:error,_}`; assert status stays
   `:running` and `AgentCase.pending_for_run/2` is `[]` (whole `gate_open`
   transaction rolled back).

Regression coverage for the **non-fenced** gate pause (checkpoint still written)
already exists in `gate_lifecycle_test.exs` / `plan_gate_test.exs`.

## Precommit hazards (completion bar = clean `mix precommit`)

- **Dialyzer** — no spec changes; `claim_fenced?` stays boolean,
  `{:error, :fenced, run}` already typed.
- **compile_check (zero warnings)** — no new aliases/imports in source
  (`Projection`/`fenced?` already present); inline the `Keyword.get`.
- **reach (clone/smells)** — token threading mirrors the existing
  `ReactorMiddleware.append/4` pattern; not a contiguous duplicate.
- **Broad-rule blast radius** — re-run the Allocate/Projection, gate-lifecycle,
  composer-durable, and recovery suites: the rule is a no-op without a token, and
  a legit executor's token always matches, so no existing path is wrongly fenced.
- **`mix format`**; **`mix ash.codegen --check`** (no schema change).

## Verification

1. Targeted: `mix test test/jido_claw/orchestration/workflow_lease_test.exs`
   (21 tests incl. the 3 new) + `…/gate_lifecycle_test.exs` +
   `…/route_composer/composer_durable_test.exs` +
   `…/workflow_event/` (Allocate/Projection).
2. `mix compile --warnings-as-errors` / `mix jidoclaw.compile_check`;
   `mix ash.codegen --check`.
3. **Completion bar:** full `mix precommit` passes. Nothing committed — left
   unstaged (consistent with the WS1 plan).

## Critical files

- `lib/jido_claw/orchestration/workflow_event/changes/allocate.ex` — fence B (`:146-162`).
- `lib/jido_claw/orchestration/workflow_log.ex` — `gate_open/3` (`:118-143`), `append/4` fence forwarding (`:32-51`).
- `lib/jido_claw/orchestration/gate_step.ex` — `gate_open` call (`:62-65`).
- `lib/jido_claw/orchestration/reactor_runner.ex` — halt finalize (`:731-740`), `fenced?` (`:647-655`).
- `lib/jido_claw/orchestration/workflow_event/projection.ex` — `status_authority?` (`:93-94`), `approval_requested` transition (`:132`).
- `test/jido_claw/orchestration/workflow_lease_test.exs` — fence test patterns (#7, #15) + raw-SQL seeding helpers.
