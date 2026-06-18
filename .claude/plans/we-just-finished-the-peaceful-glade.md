# Plan: Resolve the two code-review findings on the MCP re-prep / re-discovery work

## Context

The just-finished plan (`please-review-docs-exploration-jidoka-fe-purring-cray.md`) shipped MCP `Consumer` crash-recovery re-prep + periodic re-discovery, and the replay raw-read normalization. A code review then flagged two issues. **Both are verified true** by reading the current code:

- **[P1 — real bug] Reconcile failures are silently dropped, so an agent can stay permanently out of sync.** In `lib/jido_claw/mcp/consumer.ex`, a no-op rediscovery tick (`maybe_reconcile(state, false, …)`, line 413) skips reconciliation entirely. But `reconcile_pid/3` (line 545) returns `:skip` (on a failed `list_tools`) or `:partial` (on a failed unregister/register), and `start_reconcile_task/3` (line 564) is fire-and-forget — that result is **dropped** (the `Enum.each` at 418 discards it). Meanwhile the `{:rediscovered}` handler **unconditionally** commits `state.modules`/`state.module_templates` to the new set (lines 340–346) *before* any reconcile task finishes. So once state holds the new module set, the next tick computes `tools_changed? == false` and the failed pid is **never revisited**. A single transient agent timeout strands that pid: added tools missing, removed tools still advertised, or a same-name redefined tool stuck on the old module atom — until some *future* genuine tool-set change happens to re-trigger reconcile. The code's own `reconcile_pid` comment ("retried next tick", lines 538–543) is therefore false. This same gap breaks the documented "stale tool from a late attach task is **pruned at the NEXT rediscovery**" recovery path (comment at 411–412): that pid (once it self-heals its mark) is `attached` but never reconciled on an unchanged tick.

- **[P3 — stale docs] The old terminal-`:mcp_unavailable` / "deferred re-discovery" invariants are still documented in several places** that now contradict the shipped work (and one self-contradicts within the same docstring). The replay raw-read path is *already* normalized in code (its comments are current), but the exploration doc still calls that normalization unshipped.

**Outcome:** reconcile becomes genuinely self-healing (a transient failure or a stale tool converges on the next tick, exactly as the comments claim), and every stale doc/comment is reconciled with reality. **Done only when `mix precommit` is green.** Greenfield; leave everything unstaged.

---

## Part 1 — Fix P1: make reconcile self-healing (`lib/jido_claw/mcp/consumer.ex`)

**Root cause:** the "keep a no-op tick cheap" optimization gates *reconcile* on `tools_changed?`, but reconcile is also the only mechanism that retries a failed pid and prunes a late-attach stale tool — neither of which a tool-set diff can see once `state.modules` is committed. The fix removes that gate for reconcile while keeping it for the two things that genuinely should be change-gated (the generation mark-fence and the policy republish), and makes `reconcile_pid` fully query-based so a retry needs no remembered diff state.

**Why reconcile-everyone-every-tick, not a tracked `dirty`/`unsynced` set?** A dirty-set (reconcile-task reports `:skip`/`:partial` back via a cast; Consumer retries only those pids) preserves the cheap no-op but is **both more complex and incomplete**: (1) it needs new state + a report-back message + mark-flow changes; (2) it still requires the query-based `reconcile_pid` of 1b anyway (a retry on a later unchanged tick can't recompute the atom-swap `changed` set); and (3) it does **not** fix the late-attach stale-tool prune — that pid never *failed* a reconcile (it was never reconciled), so it'd need a *second* "attached-since-last-reconcile" tracker. Reconcile-every-tick subsumes both bugs with **zero new state**, is idempotent and cheap when in sync (a `list_tools` + skipped registers, bounded by the 5-min interval and the supervised task pool), and makes the existing "retried next tick" / "pruned at the NEXT rediscovery" comments literally true. The micro-optimization it drops is precisely what caused the bug; a dirty-set refinement stays available later if attached-agent counts ever make per-tick `list_tools` calls matter.

### 1a. Reconcile every attached pid on every tick

Rewrite the `{:rediscovered, pid, new_modules, new_policy, new_templates}` handler (lines 326–349) so reconcile runs **unconditionally**, and split out two tiny helpers:

```elixir
def handle_info(
      {:rediscovered, pid, new_modules, new_policy, new_templates},
      %{rediscover_pid: pid} = state
    ) do
  Process.demonitor(state.rediscover_ref, [:flush])

  tools_changed? =
    new_modules != state.modules or new_templates != state.module_templates

  # Reconcile every attached pid on EVERY tick (query-based + idempotent): a
  # prior tick's failed reconcile (`:skip`/`:partial`) and a stale tool a late
  # attach task left both heal here — neither is visible to a `tools_changed?`
  # gate once `modules` is committed. Cheap when in sync (one `list_tools` +
  # skipped registers); only an out-of-sync pid is written. Empty `attached`
  # ⇒ a no-op, so a tick with no agents stays free.
  reconcile_attached(state.attached, new_modules, new_templates)

  reconciled =
    state
    |> bump_generation(tools_changed?)
    |> maybe_republish_policy(new_policy)

  applied = %{
    reconciled
    | modules: new_modules,
      module_templates: new_templates,
      rediscover_ref: nil,
      rediscover_pid: nil
  }

  {:noreply, arm_rediscovery(applied)}
end
```

- **New `reconcile_attached/3`** (replaces the body of `maybe_reconcile/4`): `Enum.each(attached, fn {pid, template} -> reach = modules_for_template(new_modules, new_templates, template); start_reconcile_task(pid, reach) end)`. (Own `pid` binding — no shadow of the handler's message `pid`.)
- **New `bump_generation/2`** (carries the old `maybe_reconcile`'s generation-fence rationale): `bump_generation(state, true) -> %{state | generation: make_ref()}`; `bump_generation(state, false) -> state`. The mark-fence stays change-gated (so an in-flight register task's mark is only dropped when the tool set actually moved); reconcile no longer is.
- **Delete `maybe_reconcile/4`** (both clauses) and **`changed_names/2`** (no longer needed — see 1b).

### 1b. Make `reconcile_pid` fully query-based (self-correcting, no `changed` arg)

The current `reconcile_pid/3` needs the Consumer-computed `changed` set to force-unregister a same-name atom-swap. That breaks retries: on a later unchanged tick `changed` recomputes to empty, so a previously-failed atom-swap can never be re-pruned (`register_modules` skips the present name). Fix by detecting the atom swap from the pid's **live** module list instead of a passed-in diff:

```elixir
@spec reconcile_pid(pid(), [module()]) :: :ok | :partial | :skip
defp reconcile_pid(pid, reach) do
  case list_mcp_modules(pid) do
    {:ok, current} ->
      reach_by_name = Map.new(reach, &{&1.name(), &1})
      to_unregister = stale_names(current, reach_by_name)
      unregistered? = unregister_names(pid, to_unregister)
      registered = register_modules(pid, reach)
      if unregistered? and registered == :ok, do: :ok, else: :partial

    :error ->
      :skip
  end
end

# Live mcp_* modules to drop: a name absent from `reach` (removed / now out of
# the template's reach) OR present under a DIFFERENT module atom than the target
# (a same-name content-addressed redefinition — register-by-name alone would
# skip the new atom, so the stale one must be unregistered first). Query-based:
# compares the pid's LIVE modules to the target, so it converges regardless of
# how the pid got out of sync (no remembered diff needed for a retry).
defp stale_names(current_modules, reach_by_name) do
  current_modules
  |> Enum.filter(fn module ->
    case Map.get(reach_by_name, module.name()) do
      nil -> true
      target -> target != module
    end
  end)
  |> MapSet.new(fn module -> module.name() end)
end
```

- **Keep the `if unregistered? and registered == :ok, do: :ok, else: :partial` result exactly as written** — it's load-bearing. Because `register_modules/3` checks presence **by name**, a *failed* unregister of a same-name atom-swap leaves the old atom present, so the subsequent `register` skips it; returning `:partial` (not `:ok`) on `unregistered? == false` is what keeps the half-updated pid eligible for the next tick's retry. (The retry then re-detects the swap via `stale_names/2` and re-tries the unregister.)
- **Replace `list_mcp_names/1` with `list_mcp_modules/1`** — same `safe_list_tools/1` wrapper, but return the filtered **modules** (`{:ok, Enum.filter(modules, &mcp_name?(&1.name()))}`), not their names, since the atom comparison needs the modules. Keep `safe_list_tools/1`, `mcp_name?/1`, `unregister_names/2`, `safe_unregister/2`, `warn_unregister/2`, `register_modules/3` unchanged.
- **`start_reconcile_task/2`** (drop the `changed` param): `Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> reconcile_pid(pid, reach) end)`.

This is exactly the "query-based, self-corrects to the pid's ACTUAL tools" behavior the moduledoc already *claims* (it currently only partially holds because of the passed-in `changed` diff). The `changed`-set test (consumer_test.exs:615) keeps passing — the observable unregister-then-register on an atom swap is preserved, just detected from live state.

### 1c. Reconcile the moduledoc + comments (these are part of the fix, not the P3 sweep)

Update the dense in-file docs to match the new behavior (rationale-only, to stay credo/ExSlop-clean):

- **`## Periodic re-discovery`** moduledoc (~lines 29–40): reconcile now runs **every tick** (query-based + idempotent), not gated on a diff; a changed tool is detected by **comparing the live module atom to the discovered one** (drop the "(the `changed` set)" phrasing).
- **Known limitations** bullet (~73–76): replace "handled via the `changed` set" with "handled by comparing the live module atom to the target (unregister-then-register)"; the orphaned-atom note stays. Eventual-consistency bullet (~77–81): add that reconcile runs every tick, so a transient `:skip`/`:partial` and a late-attach stale tool self-heal within one interval.
- The old `maybe_reconcile(false, …)` "pruned at the NEXT rediscovery" comment (411–412) and the `reconcile_pid` "retried next tick" comment (538–543) move into the new `reconcile_attached`/`reconcile_pid` and are now **true** (every tick reconciles).

**No config, no state-shape, no public-API changes.** `attached` stays `%{pid => template}`; the existing `rediscovery_interval_ms` timer drives the retry cadence (default 5 min; `0` still disables, consistent with re-discovery being off).

### 1d. Tests (`test/jido_claw/mcp/consumer_test.exs`)

- **Add a deterministic regression test that fails without the fix** (per memory [[feedback_prove_race_test_fails_without_fix]] / [[feedback_permanent_test_over_spot_check]]): *"a no-op tick prunes a stale tool left on an attached agent"*. Plant a stale tool by hand so it's race-free —
  - stub `list_tools -> {:ok, [ping_tool()]}` (discovery never changes); start Consumer; `ensure_attached(agent, "main")`; assert `has_tool?(agent, @tool_name)`.
  - Plant the stale tool: ``[pong_module] = ProxyGenerator.build_modules("stub", :stub, [pong_tool()]); Consumer.register_modules(agent, [pong_module])``; assert `has_tool?(agent, @pong_name)`.
  - `send(consumer, :rediscover)` (a **no-op** tick); `assert_eventually(fn -> not has_tool?(agent, @pong_name) end)`; assert `has_tool?(agent, @tool_name)` still true.
  - Without the fix: the no-op tick skips reconcile → `pong` persists → the `assert_eventually` times out (fails). With the fix: reconcile prunes it.
  - **This test already proves the retry mechanism** — "a no-op tick reconciles an attached pid" is exactly what makes a tick-N failure heal at tick N+1. An *explicit* failed-unregister-then-retry test is **optional** and not planned up front: there's no cheap deterministic seam to make the agent's own `Jido.AI.unregister_tool`/`list_tools` fail exactly once (killing the agent removes it from `attached`, so it isn't a live-pid retry). If a one-shot-failing wrapper turns out cheap during implementation, add it; otherwise the hand-planted stale-tool test stands as the regression (per the user's note that it's optional).
- **Update the existing no-op-tick test** (line 703, *"…spawns no reconcile (no generation bump)"*): the three assertions (`generation == gen_before`, `approval_policy() == policy_before`, `has_tool?(agent, @tool_name)`) all **still hold** (reconcile runs but is idempotent: no atom differs ⇒ no unregister, present tool ⇒ skipped register, no generation bump, no policy churn). Only retitle to *"…runs idempotent reconcile, no generation bump, tool set stable"* and fix the inline comment (it no longer "spawns no reconcile tasks").
- **Light comment touch** on the changed-tool test (line 615): it asserts observable outcome (`current_ping_module(agent) == mod_b`), which is unchanged; reword its comment from "the changed-set unregister-then-register" to "the atom-mismatch unregister-then-register".
- All other re-discovery tests (added/removed/changed/refresh/allowlist/in-flight-fence/stale-result/crash/auto-arm/`policy_changed?`) are unaffected — I traced each: the added/removed/changed/allowlist ticks are `tools_changed? == true` (reconcile runs as before, self-correcting reconcile gives identical observable results); the in-flight-fence test never attaches the agent before the tick (so `reconcile_attached` over empty `attached` is a no-op and the generation still bumps); the crash/stale-result tests never reach reconcile.

---

## Part 2 — Fix P3: stale-doc sweep

All edits are prose in comments/docs (compile_check/credo/format don't judge comment factual *content*), so they're **low risk** to the gate — not gate-exempt: still run the full `mix precommit` (e.g. `mix format` can react to comment whitespace; never assume a change category can't trip a check). They're primarily correctness-of-documentation. Per memory [[feedback_false_invariant_codebase_sweep]] / [[feedback_doc_status_sweep_whole_entry]], fix **every** restatement and reconcile whole entries.

- **`lib/jido_claw/mcp.ex`** `ensure_attached/3` docstring (lines 75–78): delete the false clause "`:mcp_unavailable`, which is **terminal until a Consumer/app restart re-preps** — later turns stay tool-less (no self-heal)". Keep the crash result as "returns `:mcp_unavailable` (tool-less for that turn)" and keep the already-correct paragraph at 85–90 (bounded re-prep + re-discovery) as the authoritative explanation. This removes the in-docstring self-contradiction.
- **`lib/jido_claw.ex`** call-site comment (line 218): "`:mcp_unavailable` (prep crashed — tool-less until a Consumer/app restart)" → "prep crashed — bounded re-prep recovers it on a later turn; only after retries exhaust does it persist until a restart". (Line 217's `:timeout` half is already correct.)
- **`AGENTS.md`** (line 87, the External MCP Tool Consumption entry): its trailing "Deferred: per-tool (vs per-server) approval overlay for `mcp_*`, reconnect/re-discovery." now over-states the deferral — drop "reconnect/re-discovery" (shipped: bounded crash re-prep + periodic re-discovery), leaving the per-tool approval overlay as the lone standing non-goal. Edit **`AGENTS.md` directly** — `CLAUDE.md` only pulls it in via `@AGENTS.md` (it holds no separate copy of the stale phrase, so there's no second edit).
- **`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md`** — reconcile the V2-2 and V2-4 entries whole:
  - Line 58 ("Deferred…"): remove "reconnect/re-discovery — including **no auto re-prep after a hard prep crash** (…until an app restart re-preps)"; keep only the per-tool approval overlay + per-server allowlist-granularity deferrals.
  - Line 60 (Shipped 2026-06-17): "This narrows V2-2's remaining deferrals to the per-tool approval overlay **and reconnect/re-discovery**." → drop the trailing clause; add a brief **Shipped** note that bounded crash-recovery re-prep + periodic re-discovery (with per-tick, query-based, self-healing reconcile) landed, leaving the per-tool approval overlay as V2-2's sole deferral.
  - Line 92 (V2-4): rewrite "One deferred follow-up remains — **P1 consumer-attach**… that path bubbles an *arbitrary* error… a clean version needs a `replay.ex` refusal-vocabulary normalization (surface `{:not_replayable, :irreversible_check_failed}`)" to record it as **shipped** — `replay.ex` now normalizes the read failure to `{:not_replayable, :irreversible_check_failed}` (so the MCP tool's `details.diagnostics` and the dashboard preflight attach), matching `diagnose/2`.
  - Line 155 (Program status): note that V2-2's reconnect/re-discovery and V2-4's raw-read consumer-attach follow-up have since shipped, so no V2 entry carries hidden pending work (the per-tool approval overlay and input/output-length controls remain the only deliberate standing deferrals).
- **No change** to `lib/jido_claw/orchestration/replay.ex`, `…/replay/diagnostics.ex`, `consumer.ex` moduledoc re-prep sections, `mcp/client.ex`, `mcp/client/live.ex` — verified already current/correct.

---

## Precommit risk notes (`mix precommit` = compile_check · system_prompt.check · deps.unlock · format · `reach.check --arch --smells --strict` · `credo --strict` · `dialyzer` · test)

- **Dangling refs after deletions (compile_check zero-warning gate):** deleting `maybe_reconcile/4` + `changed_names/2`, renaming `list_mcp_names → list_mcp_modules`, and dropping the `changed` arg from `reconcile_pid`/`start_reconcile_task` — all are private and used only in the reconcile flow; grep-confirm no other caller before finishing. Update the `@spec reconcile_pid/2`.
- **ExDNA clone check (`min_mass: 30`, the top risk):** `stale_names/2` resembles the deleted `changed_names/2` (filter + `MapSet.new` over a `case Map.get`), but `changed_names` is removed, so only one copy exists — no clone. `reconcile_attached/3`, `bump_generation/2`, `list_mcp_modules/1` are small and structurally distinct from siblings; the register/unregister helper pairs are untouched. No new contiguous `defp` seam is added (avoids the [[project_exslop_duplicate_clone_seams]] footgun). Never pipe precommit through `tail` ([[project_credo_reach_string_building]]).
- **Dialyzer:** `reconcile_pid/2 :: :ok | :partial | :skip`; `stale_names/2 :: MapSet.t()`; `list_mcp_modules/1 :: {:ok, [module()]} | :error`; `bump_generation/2` returns the state map. Reuses proven idioms; no `.dialyzer_ignore.exs` entry.
- **reach `--arch`/`--smells`:** no new cross-layer deps (`Jido.AI`, `Task.Supervisor`, `MapSet`/`Map`/`Enum` already in use); state updates stay `%{state | …}` (no new fixed-shape literals).
- **Doc edits (Part 2) are low-risk to precommit, not exempt** — comment/doc *content* isn't judged by compile_check/credo, but `mix format` still touches comment whitespace, so run the full gate and don't treat any edit category as gate-proof.
- Per memory [[project_precommit_zero_findings]]: run the **full** `mix precommit`, not just compile+test.

---

## Verification

1. **Targeted suite first (fast iteration):** `mix test test/jido_claw/mcp/consumer_test.exs` — the new stale-tool-prune test, the retitled no-op-tick test, and all existing re-discovery/re-prep tests green.
2. **Prove the regression test bites** (per [[feedback_prove_race_test_fails_without_fix]]): temporarily revert just the 1a reconcile-every-tick change (restore the `tools_changed?` gate on reconcile) and confirm the new *"no-op tick prunes a stale tool"* test **fails**; restore the fix and confirm it passes.
3. **Full gate:** `mix precommit` must be green (the completion bar). Fix every finding; re-run.
4. **Manual smoke (optional, Tidewave `project_eval`):** with a stub MCP server, `ensure_attached` an agent, hand-register an extra `mcp_*` proxy on it (`Consumer.register_modules/2`), `send(JidoClaw.MCP.Consumer, :rediscover)` (a no-op discovery), and confirm via `Jido.AI.list_tools/1` that the extra tool is pruned and the legit one remains — the P1 fix end-to-end.

---

## Critical files

| File | Part | Change |
|---|---|---|
| `lib/jido_claw/mcp/consumer.ex` | 1 | reconcile every tick (`reconcile_attached/3` + `bump_generation/2` replace `maybe_reconcile/4`); query-based self-correcting `reconcile_pid/2` (`stale_names/2`, `list_mcp_modules/1`); delete `changed_names/2`/`list_mcp_names/1`; reconcile moduledoc + comments |
| `test/jido_claw/mcp/consumer_test.exs` | 1 | add the deterministic stale-tool-prune-on-no-op-tick regression; retitle/fix the no-op-tick test; reword the changed-tool comment |
| `lib/jido_claw/mcp.ex` | 2 | drop the false "terminal/no-self-heal" clause from the `ensure_attached/3` docstring |
| `lib/jido_claw.ex` | 2 | fix the line-218 `:mcp_unavailable` call-site comment |
| `AGENTS.md` | 2 | drop "reconnect/re-discovery" from the MCP entry's Deferred list |
| `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` | 2 | reconcile V2-2 (lines 58/60) + V2-4 (line 92) + Program status (155) to shipped |

**Reused (not reinvented):** `modules_for_template/3`, `register_modules/3`, `unregister_names/2`/`safe_unregister/2`, `safe_list_tools/1`, `mcp_name?/1`, `arm_rediscovery/1`, `maybe_republish_policy/2` + `policy_changed?/2`, `start_reconcile_task` (signature trimmed), `Task.Supervisor`/`spawn_monitor` idioms, the existing `rediscovery_interval_ms` timer, the `counter_stub/3` + `ProxyGenerator.build_modules/3` + `has_tool?/2` test helpers.

> Side note (not actionable): `git status` shows the prior plan file and the new `event_reader.ex` untracked — expected; the user wants everything left unstaged.
