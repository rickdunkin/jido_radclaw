# Cancellation review fixes — resume hard-stop, dashboard refresh, abandon audit

## Context

The live-run cancellation feature (plan: `please-review-docs-exploration-squidie-f-purrfect-treehouse.md`) went through code review, which surfaced three findings. All three are **validated against the code**:

- **[P1] Resume cancellation can run downstream steps in the spawn→register gap.** `RunExecution.run_killable/4` registers the executor *inside* the spawned task (`run_execution.ex:96-106`), so a cancel landing before registration skips the kill. The designed backstop is the middleware append failing on the now-`:cancelled` run — and `Projection.next_status(:cancelled, :run_resumed)` is indeed `:illegal` (`projection.ex:98`) — but `ReactorMiddleware.init_for_state/2`'s resume branch **logs the failed `run_resumed` append and returns `{:ok, context}`** (`reactor_middleware.ex:129-132`), so a resumed reactor proceeds to execute downstream steps against a cancelled run. The fresh-start branch already hard-stops (`{:error, reason}` aborts before any step); resumes need the same terminal hard-stop.
- **[P2] Cancel doesn't refresh the dashboard.** `Cancellation.finish/4` broadcasts `{:run_cancelled, ...}` on the runs topic (`cancellation.ex:195`), which `DashboardLive` receives (it subscribes via `RunPubSub.subscribe_all/0`) but swallows in the catch-all — only `run_started`/`run_completed`/`run_failed` are handled (`dashboard_live.ex:100-112`). **User decision: fix both Cancel-button paths** — the parked-run path delegates to `Cases.abandon/3`, which today broadcasts only `{:gate_resolved, ...}` on the gates topic DashboardLive doesn't subscribe to, so a parked-run cancel would stay stale even with the `run_cancelled` handler added.
- **[P3] Parked-run cancel loses the operator audit field.** `Cancellation.cancel_parked/4` delegates with only `%{cancellation_reason: reason}` (`cancellation.ex:121-124`), while the ApprovalsLive abandon path supplies `decided_by_id` from the actor (`approvals_live.ex:147-148`). `AgentCase.abandon` accepts `[:cancellation_reason, :decided_by_id]` (`agent_case.ex:125`). Same operator action, different audit row.

**Done means `mix precommit` succeeds** (run via `mise exec -- mix`, bare in background — never piped).

## Fix 1 (P1) — `lib/jido_claw/orchestration/reactor_middleware.ex`

In the resume branch of `init_for_state/2` (the `initial_state: :halted` clause, ~line 123): on a failed `run_resumed` append, **reload the run and hard-stop if it has reached a terminal status**; keep today's best-effort log-and-continue otherwise.

- Add a private `@terminal [:completed, :failed, :cancelled, :abandoned]` with the "mirrors `Projection`" comment — the same precedent as `Cancellation.@terminal` and `ReactorRunner.@non_terminal`.
- New private helper (called only from the failure path, so zero cost on the happy path):
  - Reload via `WorkflowRun.by_id(run.id, tenant: run.tenant_id, actor: context_actor(context, run))` (both already in the module).
  - Reloaded status terminal → return `{:error, {:run_already_terminal, status}}` — Reactor aborts before any step executes, mirroring the fresh-start abort.
  - Still-live or unreadable reload → `Logger.warning` + `{:ok, context}` (unchanged best-effort: a transient DB blip on a provenance append must not fail a healthy run).
- **No downstream changes needed** — verified: GateResume's `{:reactor, {:error, _}}` routes through `ReactorRunner.finalize({:error, _}, ...)` (`reactor_runner.ex:524-533`), which reloads first and maps a `:cancelled` run to the clean `{:error, :cancelled, run}`; any other terminal falls to `ensure_failed`, whose non-terminal guard no-ops (`reactor_runner.ex:652-659`). No new `rescue` (code-interface reads return tuples).
- Moduledoc: update the "`init/1` is the single producer" section — "a failed `run_resumed` on resume is best-effort" becomes "best-effort *while the run is live*; a terminal run hard-stops the resume (the cancel-before-register race: the durable decision wins)".

## Fix 2 (P2) — dashboard refresh on both cancel paths

**`lib/jido_claw/web/live/dashboard_live.ex`** — after the `run_failed` clause (~line 112), add two clauses mirroring it:

```elixir
def handle_info({:run_cancelled, _id, _info}, socket), do: {:noreply, schedule_overview_refresh(socket)}
def handle_info({:run_abandoned, _id, _info}, socket), do: {:noreply, schedule_overview_refresh(socket)}
```

**`lib/jido_claw/orchestration/cases.ex`** — in `abandon/3` (~line 130-144), after the commit + reload succeed, broadcast the run-lifecycle terminal on the runs topic alongside the existing gates-topic `broadcast_resolved/3`:

```elixir
RunPubSub.broadcast(run.id, {:run_abandoned, run.id,
  %{tenant_id: abandoned_run.tenant_id, name: abandoned_run.name,
    workflow_type: abandoned_run.workflow_type, status: :abandoned,
    completed_at: abandoned_run.completed_at}})
```

— payload built from the **reloaded** `abandoned_run` (the decision-time `run` snapshot predates the terminal flip, so its `completed_at` is nil; `run.id` for the topic/id is fine), mirroring `Cancellation.finish/4`'s payload shape (`cancellation.ex:195-205`). This covers the Workflows Cancel button on parked runs *and* ApprovalsLive's "Abandon run" button. Safe to add: DashboardLive is the only production runs-topic subscriber (verified); the two test subscribers (`workflow_runner_test.exs:46`, `compiler_integration_test.exs:48`) assert specific tags. Touch the Cases moduledoc's Abandon section (one line: abandon now emits the run-lifecycle broadcast).

**`lib/jido_claw/workflow_view.ex`** — add `:abandoned` to `@terminal_statuses` (line 15, currently `[:completed, :failed, :cancelled]`). Without it, the refresh fires but an abandoned run vanishes from the dashboard entirely (it leaves `active_runs` and never enters `recent_completions`) — both Cancel paths should show as terminal dashboard activity.

## Fix 3 (P3) — `lib/jido_claw/orchestration/cancellation.ex`

In `cancel_parked/4` (~line 121), thread the operator into the abandon attrs, mirroring ApprovalsLive:

```elixir
Cases.abandon(case_id, %{cancellation_reason: reason, decided_by_id: actor_user_id(actor)},
  tenant: tenant, actor: actor)
```

with a UUID-validating extractor — `decided_by_id` is a `:uuid` attribute (`agent_case.ex:222`), and forwarding an arbitrary `user_id` would make `cancel/2` brittle against internal/test actor shapes (a non-uuid would surface as a cast error from abandon):

```elixir
defp actor_user_id(%{user_id: id}) when is_binary(id) do
  case Ecto.UUID.cast(id) do
    {:ok, uuid} -> uuid
    :error -> nil
  end
end

defp actor_user_id(_actor), do: nil
```

Dashboard actors always carry a uuid `user_id` (`Actor.build/1`) → audit parity with ApprovalsLive; system actors (`user_id: nil`) and non-uuid internal/test actors → `nil` (attribute allows nil), never a cast failure. Moduledoc routing bullet: note the delegation carries the operator audit field.

## Tests

**`test/jido_claw/orchestration/reactor_middleware_test.exs`** (P1 — the file already drives Builder-built reactors through the middleware):

- Add two step fixtures in the test file (alongside `OkStep`): a `HaltStep` returning `{:halt, :paused}` and a `NotifyStep` that sends `{:downstream_ran, ...}` to a context-seeded test pid. Build the two-step reactor with `Reactor.Builder`, wiring the dependency as a **result argument** — `{:_, {:result, :halt}}` / `Argument.from_result/2` (Builder's option schema has no `wait_for`; the DSL's `wait_for` desugars to exactly this result argument).
- **Cancelled-resume hard-stop (the P1 pin):** first `Reactor.run` → `{:halted, halted_reactor}` (run is `:running`; `run_halted` is provenance-only). Append `run_cancelled` via `WorkflowLog.append` (legal from `:running`). Resume by calling `Reactor.run(halted_reactor, %{}, context, ...)` — Reactor seeds `initial_state: :halted`, exactly GateResume's mechanics minus encryption. Assert the narrow behavioral pin: resume returns `{:error, _}`; `refute_received {:downstream_ran, _}`; status stays `:cancelled`; and **no event for the downstream notify step specifically** was recorded after the `run_cancelled` event (filter by the step's payload identity — not a blanket "no `step_*` after cancel").
- **Positive control (proves the fixture resumes):** same shape without the cancel — resume returns `{:ok, _}`, downstream message received, kinds include `run_resumed` and end in `run_completed`.

**`test/jido_claw/web/live/dashboard_live_test.exs`** (P2): two tests mirroring the `run_failed` one — `{:run_cancelled, "r1", %{}}` and `{:run_abandoned, "r1", %{}}` arm a coalesced refresh.

**`test/jido_claw/workflow_view_test.exs`** (P2): pin `:abandoned` as terminal dashboard activity — create a run, force `status: :abandoned` + `completed_at` via the `set_status`/`authorize?: false` corruption-sim precedent already used in this file, assert it appears in `view.recent_completions`.

**`test/jido_claw/orchestration/cancellation_test.exs`** (P2+P3): in the parked-run delegation test, pass the cancel a web-shape actor `%{user_id: Ecto.UUID.generate(), tenant_id: tenant}` (the `approvals_live_test.exs:60` convention) and assert the abandoned `AgentCase.decided_by_id` round-trips to that uuid. (With the `Ecto.UUID.cast` guard, the existing `actor_for/1`-based tests keep passing — a non-uuid `user_id` simply yields `decided_by_id: nil` — the web actor is needed only to assert the positive case.) Also `RunPubSub.subscribe(run.id)` before the cancel and `assert_receive {:run_abandoned, ^run_id, %{status: :abandoned}}` to pin the new broadcast.

## Doc touch-ups (stale claims the fixes correct)

- `run_execution.ex` moduledoc "Cancel-before-register race": currently describes only the fresh-start `run_started` abort — add the resume leg (`run_resumed` append fails → middleware hard-stops on the terminal reload).
- `cancellation.ex` moduledoc, "Cancel before the executor registers" bullet: same addition.
- `docs/exploration/squidie/REACTOR-ADOPTION.md` shipped bullet (~line 27-48): one-line touch noting the resume-path hard-stop and the `run_abandoned` lifecycle broadcast.

## Verification

1. Focused suites: `mise exec -- mix test test/jido_claw/orchestration/reactor_middleware_test.exs test/jido_claw/orchestration/cancellation_test.exs test/jido_claw/web/live/dashboard_live_test.exs test/jido_claw/web/live/workflows_live_test.exs test/jido_claw/workflow_view_test.exs test/jido_claw/orchestration/gate_lifecycle_test.exs test/jido_claw/orchestration/workflow_recovery_test.exs` (recovery resumes via GateResume — confirms no regression from the middleware change).
2. **`mise exec -- mix precommit` — the completion gate.** Run bare in background and read the output tail (piping masks the exit code). Watch: ExSlop EXS3004 (no comment line starting with the word "step" — relevant since the new tests discuss steps), no new bare rescues (none needed), flaky async:false singletons (MCPServer/Prompt/PipelineStore/MultiSandbox) — verify in isolation before blaming these changes.

## Out of scope (noted, not built)

- Reject-path dashboard staleness: `Cases.commit_reject` appends `run_cancelled` but broadcasts only `{:gate_resolved, ...}` — a different button (gate decision), pre-existing, not flagged by the review.
- DashboardLive gates-topic subscription / `gate_requested` refresh (running↔awaiting_approval transitions), and WorkflowsLive PubSub live-updates — existing known follow-ups.
