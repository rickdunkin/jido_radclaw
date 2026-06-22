# AR-2 Composer Phase 4 — code-review fixes (P1 retry crash, P2 gate-peel bypass)

## Context

The Phase 4 plan (`please-review-docs-exploration-alp-river-sequential-blossom.md`)
shipped human gates in the route composer. A code review of the unstaged changes
surfaced two defects. I validated both against the current source — **both are real**.
This plan fixes them surgically, each by mirroring a proven pattern already in the
same module, and adds regression tests. **Done = `mise exec -- mix precommit` green.**

---

## P1 — a delayed `{:retry_wave_paused}` crashes the composer after the gate resolves

**Confirmed.** When the durable `wave_paused` append fails transiently, the park point
schedules a retry: `Process.send_after(self(), {:retry_wave_paused, attempt + 1}, …)`
(`route_composer.ex:1556`). The handler is unconditional:

```elixir
def handle_info({:retry_wave_paused, attempt}, state), do: attempt_wave_paused(state, attempt)  # :955
```

`attempt_wave_paused(%{parked: park} = state, attempt)` (`:1538`) → `wave_paused_payload(park)`
(`:1717`) → `%{wave_index: park.wave_index, …}`. The map-pattern head `%{parked: park}`
matches **even when `parked` is `nil`** (the key is set to `nil`, never deleted — see
`fold_resumed_gate` `:1667`, `terminalize_gate_disposition` `:1705/1707/1712/1715`). So
if the operator's decision lands inside the ≥100 ms retry backoff window, the gate
resolves (`parked → nil`), the queued retry fires, and `wave_paused_payload(nil)`
evaluates `nil.wave_index` → runtime exception → **the composer GenServer crashes**.

The neighboring wake handler already guards against exactly this and is the template:

```elixir
def handle_info({:gate_resolved, run_id, _info}, state) do          # :944
  if match?(%{child_run_id: ^run_id}, state.parked), do: resolve_parked_gate(state), else: {:noreply, state}
end
```

### Fix — carry the parked child identity in the retry message + guard on it

Two edits in `lib/jido_claw/route_composer/route_composer.ex`, both internal (no test
sends this message; grep-confirmed the only producer is line 1556):

1. **Handler (`:955`)** — match a 3-tuple and guard, mirroring `:gate_resolved`:

   ```elixir
   # Retry a transient `wave_paused` append (Phase 4b) — ONLY while still parked on
   # that exact child. A decision (approve/reject/abandon) clears `parked` to nil (or
   # re-parks on a later gate); a delayed retry firing into a resolved park would deref
   # a nil park in `wave_paused_payload/1` and crash. Mirrors the `:gate_resolved` guard.
   def handle_info({:retry_wave_paused, child_run_id, attempt}, state) do
     if match?(%{child_run_id: ^child_run_id}, state.parked) do
       attempt_wave_paused(state, attempt)
     else
       {:noreply, state}
     end
   end
   ```

2. **Scheduling site (`:1556`)** — `park` is bound by the `attempt_wave_paused/2`
   head, so stamp its child id into the message:

   ```elixir
   Process.send_after(self(), {:retry_wave_paused, park.child_run_id, attempt + 1}, rebuild_backoff(attempt))
   ```

`attempt_wave_paused/2`'s head stays `%{parked: park}` (both callers — `park_gate/5` and
the now-guarded handler — guarantee a map, so no crash and no over-restrictive guard
needed there). This also fixes the latent variant the bare-`is_map` option would miss:
a stale retry for gate A firing while re-parked on gate B no longer re-appends a spurious
`wave_paused` for B (the `child_run_id` won't match).

### P1 regression tests

Add to `test/jido_claw/route_composer/composer_durable_test.exs` (it already has
`start_and_park_gate/1`, `wave_paused_count/2`, the `@registry`, and `Cases.decide`).

**The "primary" test must use the OLD 2-tuple shape, not the new 3-tuple.** The crash
lives in the 2-tuple path that the fix removes; a 3-tuple sent at the buggy code never
matches `handle_info({:retry_wave_paused, attempt}, …)` and is swallowed by the catch-all
(`:962`), so a 3-tuple test passes against buggy code and proves nothing. Reproduce the
literal crash condition (nil park) with the message shape the buggy handler matches:

- **PRIMARY — literal current-bug regression (fails before the fix, passes after).**
  `{parent, _case_id} = start_and_park_gate(ctx)`; `[{pid, _}] = Registry.lookup(@registry,
  parent.id)`; then:

  ```elixir
  :sys.replace_state(pid, &%{&1 | parked: nil})   # gate resolved out from under an in-flight retry
  send(pid, {:retry_wave_paused, 3})              # the OLD 2-tuple shape the buggy handler matches
  :sys.get_state(pid)                             # barrier: handled AFTER the info message (mailbox order)
  assert Process.alive?(pid)
  ```

  - Against the **buggy code**: the 2-tuple matches → `attempt_wave_paused(%{parked: nil},
    3)` → `wave_paused_payload(nil)` derefs `nil.wave_index` → composer crashes →
    `:sys.get_state` exits → **test fails**.
  - Against the **fixed code**: the handler is a 3-tuple, so the obsolete 2-tuple falls
    through to the catch-all (`:962`) and is dropped → process survives → **test passes**.

- **SECONDARY — locks the new child-id guard (catches future guard removal).**
  `{parent, case_id} = start_and_park_gate(ctx)` (one `wave_paused`); look up the live pid;
  `send(pid, {:retry_wave_paused, Ecto.UUID.generate(), 3})` (a foreign child, the new
  3-tuple shape); then `Cases.decide(case_id, :approve, …)` and await `:completed` /
  `:route_converged`. Assert `wave_paused_count(parent.id, ctx) == 1`. With the `if match?`
  guard removed (but the 3-tuple kept), the foreign retry re-appends a second `wave_paused`
  against the real park (count → 2) → fails. Also exercises the "stale retry for gate A
  while parked on gate B" case the bare-`is_map` option would miss. Messages are
  mailbox-ordered, so the retry is handled before the decision broadcast — deterministic.

---

## P2 — `split_solo_gate/2` peels one gate from a multi-gate cohort, bypassing the backstop

**Confirmed.** `lib/jido_claw/route_composer/loop.ex:60`:

```elixir
defp peel_gate([gate | _], [_, _ | _]), do: [gate]   # peels the FIRST gate whenever
defp peel_gate(_gates, dispatch), do: dispatch        # gates ≥ 1 AND dispatch ≥ 2 stages
```

`[gate | _]` matches a gates-list of **any** length, so a `[g1, g2]` or `[g1, g2, w]`
cohort is reduced to `[g1]` before `WaveBuilder.build_wave` ever sees it
(`route_composer.ex:931` feeds the peeled result straight into `run_wave`). WaveBuilder's
`classify/1` then only ever receives a solo gate → its `{:error, {:gate_must_be_solo_wave,
names}}` arm (`wave_builder.ex:88`) is **unreachable** for multi-gate cohorts. The surplus
gate(s) carry no `ran` mark and silently re-compose on later ticks — contradicting the
documented invariant (`wave_builder.ex:24-28`: "a gate mixed with any other stage, **or
more than one gate**, is rejected").

Multi-gate-per-level is genuinely unsupported: the composer holds a **single** `state.parked`
map, and `derive_park`/recovery assume one parked gate at a time. Nothing in
`CatalogValidator` forces gates into separate Kahn levels, so two independent gates land
in one cohort for any catalog that declares them (shipped catalog has only `plan-gate`;
AR-8c adds system gates). Failing loudly per the documented invariant is correct until
multi-gate is explicitly designed.

### Fix — peel only a lone gate; let multi-gate fall through to the backstop

One pattern edit + doc in `lib/jido_claw/route_composer/loop.ex`:

```elixir
# A LONE gate in a cohort of ≥2 stages → peel that gate; a cohort with no gate, an
# already-solo gate, OR >1 gate passes through unchanged. A multi-gate cohort then hits
# WaveBuilder's `{:gate_must_be_solo_wave, names}` backstop (wave_builder.ex) — multi-gate-
# per-level is unsupported (one `state.parked` at a time). Pattern-matched, not `length/1`.
defp peel_gate([gate], [_, _ | _]), do: [gate]
defp peel_gate(_gates, dispatch), do: dispatch
```

Only change: `[gate | _]` → `[gate]` (exactly one gate). Case-by-case: all-workers →
passthrough; 1 gate + ≥1 worker → `[gate]` (unchanged behavior); solo gate → passthrough →
WaveBuilder solo-gate; **≥2 gates (± workers) → passthrough → WaveBuilder backstop rejects**
→ `run_wave`'s existing `{:error, reason}` arm (`route_composer.ex:1085`) →
`finish_failed/5` → parent terminalizes (the same path `{:unsupported_unit, …}` already
uses — no route_composer change). Update the `split_solo_gate/2` `@doc` (`loop.ex:40-51`)
to state the precise contract (exactly one gate + ≥1 other stage → peel; multi-gate →
backstop). `@spec` is unchanged.

### P2 regression tests (pure, no fixture catalog needed)

- `test/jido_claw/route_composer/loop_test.exs`, in the `split_solo_gate/2` describe —
  build a tiny inline catalog of two gate stages + a worker via `TestFixtures.stage(name:
  …, unit: {:gate, …})` / `{:worker_template, …}` and add:
  - `passes a multi-gate cohort through unchanged (so the WaveBuilder backstop rejects it)`
    → `split_solo_gate(["gate-a", "gate-b"], catalog) == ["gate-a", "gate-b"]`
  - `passes a multi-gate + worker cohort through unchanged`
    → `split_solo_gate(["gate-a", "gate-b", "worker"], catalog) == ["gate-a", "gate-b", "worker"]`
  - keep the existing three (1-gate-mixed peels, solo passthrough, worker-only passthrough).
- `test/jido_claw/route_composer/wave_builder_test.exs` — add a gate+gate rejection beside
  the existing gate+worker test: `build_wave([gate("gate-a"), gate("gate-b")])` →
  `{:error, {:gate_must_be_solo_wave, names}}`, `Enum.sort(names) == ["gate-a", "gate-b"]`.
  This pins the now-reachable `>1`-gate arm.

---

## Files

| File | Change |
| --- | --- |
| `lib/jido_claw/route_composer/route_composer.ex` | P1: 3-tuple guarded `{:retry_wave_paused, child_run_id, attempt}` handler (`:955`) + stamp `park.child_run_id` at the scheduling site (`:1556`); update the `:952-954` comment |
| `lib/jido_claw/route_composer/loop.ex` | P2: `peel_gate([gate], …)` (was `[gate \| _]`); update the `split_solo_gate/2` `@doc` + inline comment |
| `test/jido_claw/route_composer/composer_durable_test.exs` | P1 regression test (stale-retry dropped) |
| `test/jido_claw/route_composer/loop_test.exs` | P2: two multi-gate passthrough tests |
| `test/jido_claw/route_composer/wave_builder_test.exs` | P2: gate+gate `:gate_must_be_solo_wave` rejection |

No new public functions → no new `@spec`/Dialyzer surface. No new map literals → no
`reach` `fixed_shape_map` risk. The retry message stays a tuple. No WorkflowsLive assigns.

## Verification

1. `mise exec -- mix test test/jido_claw/route_composer/loop_test.exs test/jido_claw/route_composer/wave_builder_test.exs`
   — P2 unit fixes.
2. `mise exec -- mix test test/jido_claw/route_composer/composer_durable_test.exs`
   — P1 regression + the existing park/resume/recovery suite still green.
3. `mise exec -- mix test test/jido_claw/route_composer/composer_loop_test.exs`
   — the gate happy-path/abandon integration tests unaffected.
4. **`mise exec -- mix precommit`** — run **bare in the background** and read the output
   tail; never pipe through `tail` (it masks the gate's exit code). Gates:
   `jidoclaw.compile_check` (zero non-allowlisted warnings), `format`, `reach.check
   --arch --smells --strict`, `credo --strict`, `dialyzer`, `test`.

If an async-singleton test (MCPServer/Prompt/PipelineStore/MultiSandbox) flakes under the
full run, re-verify it in isolation — not at `--seed 0` — before attributing it here.
