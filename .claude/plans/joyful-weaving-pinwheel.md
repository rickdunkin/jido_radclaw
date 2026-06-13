# Plan: Fix hard-prep-crash false-attach + stale policy in MCP Consumer

## Context

The V2-2 (External MCP Tool Consumption) work was completed and code-reviewed. The
review surfaced **one validated [P2] finding** plus a **missed doc update**. Both are
addressed here. Acceptance criterion: `mix precommit` green.

### Validated finding [P2] — hard prep failure leaves MCP consumption stuck ready-empty

`JidoClaw.MCP.Consumer` runs tool "prep" in an off-process, crash-isolated child.
Graceful failures are rescued and reported as success-empty (`{:prepared, [], %{}}`).
A hard, untrappable kill of the prep process — the *only* way prep dies without sending
`{:prepared}` — is handled by the `:DOWN` clause at `consumer.ex:142-150`, which:

1. replies `{:error, :mcp_unavailable}` to the *current* waiters (correct), then
2. sets `status: :ready, modules: []` — **indistinguishable from a successful zero-tool prep.**

Both consequences verified against the code:

- **Part 1 — false attach → permanently tool-less.** Any *later* `ensure_attached/2`
  hits the `status == :ready` branch (`consumer.ex:102`) → `{:ok, []}` →
  `Consumer.register_modules(pid, [])` returns `:ok` (empty `Enum.all?` is `true`,
  `consumer.ex:208-210`) → `do_ensure_attached` casts `{:mark_attached, pid}`
  (`mcp.ex:94-97`). The agent is marked `attached`, returns `:already` forever, and is
  tool-less until restart — contradicting the intended "later turn retries."
- **Part 2 — stale approval policy.** The `:DOWN` handler never republishes the policy
  to `:persistent_term`, unlike the `{:prepared}` handler (`consumer.ex:117`). A Consumer
  restart after a prior *successful* run retains the old policy, preserving stale trust
  decisions. An empty `%{}` policy is fail-closed (gated) for any `mcp_*` tool
  (`tool_approval.ex:138-151`: `:error` branch → `global_req` → `global_to_req(_) -> :gated`),
  so republishing `%{}` is the safe posture.

### Missed doc update

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` still marks V2-2 `NOT_ADOPTED`
(L52) and carries a now-false gap statement (L58: "agents cannot *consume* external MCP
servers … every capability must be hand-written as a `Jido.Action`"). `AGENTS.md` was
already updated; README and other docs are not stale.

## Approach

Introduce a distinct internal Consumer status `:failed`, so a hard prep crash is no longer
conflated with a successful zero-tool prep. The fix makes the failure **honest** —
consistent `:mcp_unavailable`, never falsely attached, fail-closed policy. It does **not**
add self-healing re-prep, because reconnect/re-discovery is an explicit project deferral
(`AGENTS.md` L87). Recovery is via Consumer/app restart (which re-preps).

Plus two restart-race hardening tweaks (from review): gate `:mark_attached` on `:ready`
(write path) **and** check `:failed` before the `attached` fast path (read path), so a
stale cross-incarnation `:mark_attached` cast can't re-introduce the same false-attach in
a restarted/failed Consumer.

Rejected alternatives (validated by the Plan agent): treating the crash as success-empty
(the current bug); making `register_modules(_, [])` return `:partial` (breaks the
legitimate zero-tool case — see the success-empty test at `consumer_test.exs:152-160` —
and ignores the stale policy); adding re-prep (out of scope — deferred reconnect/re-discovery).

## Changes

### 1. `lib/jido_claw/mcp/consumer.ex`

- **`:DOWN` prep-crash handler (`:142-150`):** publish an empty policy, transition to
  `:failed` (not `:ready`), and clear `pending` so the failed state is fully inert:
  ```elixir
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{prep_ref: ref} = state) do
    Logger.warning("[MCP] prep process died before completing (#{inspect(reason)}); tool-less until restart")
    :persistent_term.put(JidoClaw.MCP.policy_key(), %{})

    Enum.each(state.waiters, fn {from, _pid} ->
      GenServer.reply(from, {:error, :mcp_unavailable})
    end)

    {:noreply,
     %{state | status: :failed, modules: [], pending: %{}, waiters: [], prep_ref: nil, prep_pid: nil}}
  end
  ```
- **`{:modules_when_ready}` cond (`:97-108`):** add a `:failed` branch so *later* callers
  also get unavailable. Place it **first — before the `attached` fast-path** (defense-in-depth:
  a `:failed` Consumer reports unavailable even if a stale `attached` entry ever slipped in):
  ```elixir
  cond do
    state.status == :failed -> {:reply, {:error, :mcp_unavailable}, state}
    MapSet.member?(state.attached, pid) -> {:reply, :already, state}
    state.status == :ready -> {:reply, {:ok, state.modules}, ensure_monitored(state, pid)}
    true -> {:noreply, %{state | waiters: [{from, pid} | state.waiters]}}
  end
  ```
  `mcp.ex:99-100` already maps `{:error, :mcp_unavailable}` → `:mcp_unavailable` without
  marking attached — no facade logic change needed.
- **`handle_cast({:mark_attached, pid})` (`:111-113`):** honor the mark **only while
  `status == :ready`**; drop it otherwise (two clauses — `%{status: :ready} = state` then a
  catch-all no-op). This blocks a stale cross-incarnation race: a fire-and-forget
  registration task (under `JidoClaw.TaskSupervisor`, which survives a Consumer crash) can
  finish and cast `{:mark_attached, pid}` *by registered name* into a **restarted** Consumer
  that is `:preparing`/`:failed`, wrongly marking the pid attached. Within one incarnation
  every legitimate mark arrives while `:ready` (`:ready` never transitions to `:failed`), so
  nothing legitimate is dropped.
- **`{:attach}` case (`:84-95`):** add a `:failed` arm. **Required** — the case has no
  catch-all, so without it a post-crash `attach_to_agent/2` (REPL boot retry, rehydrate
  fan-out, worker attach) raises `CaseClauseError` and crashes the Consumer:
  ```elixir
  :failed ->
    {:reply, :ok, state}
  ```
- Add a short comment on the `:failed` status: honest semantics (tool-less until restart;
  auto re-prep is the deferred reconnect/re-discovery follow-up).

### 2. `lib/jido_claw/mcp.ex` — docstring honesty (no logic change)

Update the `ensure_attached/2` docstring (`:65-74`): post-crash `:mcp_unavailable` is
terminal-until-restart, not a self-recovering retry. Keep `:failed` **out** of
`@type attach_result` (`:30`) — it never escapes as a return value.

### 3. `lib/jido_claw.ex` — chat-path comment honesty (`:114-120`)

Refine the comment to distinguish `:timeout` (prep still running — a later turn genuinely
retries and may succeed) from `:mcp_unavailable` (prep crashed — tool-less until restart).
The `_ = JidoClaw.MCP.ensure_attached(...)` best-effort call itself is unchanged.

### 4. Tests — `test/jido_claw/mcp/consumer_test.exs`

Reuse existing helpers: `start_consumer!/1`, `start_agent!/0`, `blocking_list_tools/2`,
`assert_eventually/1`, `ping_tool/0`, `@server`, `stub/1`, alias `MCP`. **Crash recipe:**
pin prep via blocking `list_tools`, `assert_receive {:listing, _}`, read `prep_pid` from
`:sys.get_state(consumer)`, `Process.exit(prep_pid, :kill)`, then barrier on
`assert_eventually(fn -> :sys.get_state(consumer).prep_pid == nil end)` — a version-agnostic
"DOWN processed" signal (both fixed and unfixed clear `prep_pid`), so the tests fail at the
*meaningful assertion*, not a setup timeout.

- **Hygiene (file-level `setup`, `:17-21`):** snapshot the `:persistent_term` policy key
  and restore-or-erase it in `on_exit`. `:persistent_term` is global and unsandboxed, and
  the existing success-path tests already leak this key; this makes every Consumer-starting
  test hygienic and removes order-dependence.
- **Test A — later call after crash:** after the barrier,
  `assert :mcp_unavailable = MCP.ensure_attached(agent, 1_000)` (keep this as the **first**
  assertion — `mark_attached` is an async cast on unfixed code), then
  `refute MapSet.member?(:sys.get_state(consumer).attached, agent)`; optionally also assert
  `status == :failed` to pin the mechanism. Fails on unfixed code (returns `:ok`, marks attached).
- **Test B — fail-closed policy:** seed
  `:persistent_term.put(MCP.policy_key(), %{"mcp_stale_tool" => false})`, run the crash
  recipe + barrier, then `assert MCP.approval_policy() == %{}`. Fails on unfixed code
  (policy unchanged).
- **Test C — `attach_to_agent/2` after crash (guards the `:attach` `:failed` arm):** after
  the barrier, `assert :ok = MCP.attach_to_agent(agent, "main")`, then
  `assert Process.alive?(consumer)` and `assert :sys.get_state(consumer).status == :failed`.
  Pins that the new arm replies cleanly instead of raising `CaseClauseError`. This is a
  **guard** test for the new path — it does not fail on today's code (which never reaches
  `:failed`); it protects against a future removal of the arm.
- **Test D — stale `:mark_attached` cast dropped (guards the cast gating):** after the
  barrier (`:failed`), `GenServer.cast(consumer, {:mark_attached, agent})` then
  `refute MapSet.member?(:sys.get_state(consumer).attached, agent)` (the `:sys.get_state`
  call is a FIFO barrier that flushes the cast first). Fails on unfixed code (an ungated
  cast marks the pid attached).

Tests A, B, and D are proven to fail without the fix (per `feedback_prove_race_test_fails_without_fix`);
C is a guard for the new `:failed` arm.

### 5. Docs — `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md`

Mirror the V2-1 "stacked dated Status" convention (`:19-25`):
- **L52:** prepend `**Status (2026-06-13)**: PARTIAL — …` naming `JidoClaw.MCP` /
  `Consumer` / `ProxyGenerator` and the `use JidoClaw.Tools.Action` safety-pipeline
  inheritance; keep the old `**Status (2026-06-11)**: NOT_ADOPTED …` line beneath.
  (PARTIAL, not ADOPTED — the doc's strict bar at L11 makes any deferral keep an entry
  PARTIAL, consistent with V2-1.)
- Add a `**Deferred (keeps this PARTIAL)**:` line mirroring AGENTS.md's deferral list
  (per-template allowlist enforcement, worker/sub-agent sync, generic MCP output shaping,
  reconnect/re-discovery — the last now also covers "no auto re-prep after a hard prep crash").
- **L58:** rewrite the stale gap statement (agents *can* now consume; capabilities need not
  be hand-written `Jido.Action`s); fix "21 published tools" → "22".
- Optionally past-tense the forward-looking cross-refs (L44, L62, L134).

## Out of scope (noted, not fixed)

The **graceful** prep-failure path (`run_prep` rescue/catch → `{:prepared, [], %{}}`) stays
success-empty by the plan's documented best-effort design: a configured server whose
discovery fails gracefully is treated as zero-tool (attached-empty, no retry). Only the
hard-crash (`:DOWN`) path is corrected here. Distinguishing "configured-but-discovery-failed"
from "no tools" belongs to the deferred reconnect/re-discovery follow-up.

## Verification

1. **Baseline (uncommitted-tree caveat):** the MCP subsystem is currently untracked
   (`?? lib/jido_claw/mcp*`, `?? test/jido_claw/mcp/`), so `precommit` clean-recompiles and
   tests the whole uncommitted subsystem plus other staged edits. Run
   `mix jidoclaw.compile_check` **first** to establish a clean baseline, so the post-fix
   green/red delta is unambiguous.
2. **Targeted tests:** `mix test test/jido_claw/mcp/consumer_test.exs` — Tests A & B green;
   existing crash-flush (`:162-178`) and success-empty (`:152-160`) tests unaffected.
3. **Prove the tests catch the bug:** temporarily revert the `consumer.ex` changes → Tests
   A & B fail at their assertions; restore → green.
4. **Full gate (acceptance):** `mix precommit` green across all 8 gates — `jidoclaw.compile_check`,
   `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format --check-formatted`,
   `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`, `test`.
   The `:failed` arms compile warning-clean on Elixir 1.20/OTP 29 (the GenServer state is an
   untyped map parameter → `state.status` is `dynamic()` → no "will never match"; validated
   empirically by the Plan agent). `consumer.ex` already carries
   `# reach:disable-for-this-file bare_rescue`.
5. Per `project_precommit_zero_findings`, run the **full** `mix precommit` (not just
   compile+test), and never pipe it through `tail`. Do not commit unless asked.
