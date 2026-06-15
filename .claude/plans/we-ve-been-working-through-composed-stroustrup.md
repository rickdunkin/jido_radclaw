# Plan: Resolve replay-diagnostics review findings (P1/P2/P3)

## Context

The V2-4 replay preflight diagnostics feature (plan
`please-review-docs-exploration-jidoka-fe-bright-map.md`) shipped, and a code
review found three issues — all in `lib/jido_claw/orchestration/replay/diagnostics.ex`.
I validated each against the live code; **all three are real**. They share one
root cause: `Diagnostics.diagnose/2`'s job is to report blockers equivalent to
those `Replay.replay/2` would refuse with — its stated "all reasons, not just the
first" contract — but in three spots it diverges from the gate: under-reporting a
blocker (P1, P2) or under-bounding the wire map (P3). (diagnose intentionally
*normalizes* where replay bubbles a raw error — see P1 — so "equivalent," not
byte-identical.)

Fixes are confined to **`diagnostics.ex`** plus two new tests in
`diagnostics_test.exs`. No production change is needed in `replay.ex` — and the
tool (`replay_workflow.ex`) and dashboard (`workflows_live.ex`) inherit the
corrected P2/P3 output for the refusal shapes they already diagnose
(definition-changed, irreversible-executed, `{:not_replayable, _}`). One caveat,
called out under **Scope & noted limitation** below: the rare P1 raw-read-error
refusal is not one of those shapes, so making the *tool/dashboard* attach P1
diagnostics on that path is an explicit, optional follow-up — out of scope for
these findings, which are about `diagnose/2`'s own correctness.

**Done = `mise exec -- mix precommit` passes.**

## The fixes

### P1 — irreversible-event read failure must be a blocker (`diagnose_irreversible/3`, ~line 331)

`Replay.replay/2` treats a failed `WorkflowEvent.for_run/3` as a hard refusal
(`replay.ex:232-233` bubbles `{:error, reason}`; moduledoc: "an unsafe replay is
never permitted on a failed check"). diagnose currently downgrades it to a
warning with **no blocker**, so `preflight_clear?` can read `true` when replay
would refuse. Add a blocker so `preflight_clear?` derives `false`:

```elixir
{:error, reason} ->
  # Replay bubbles this read failure as a hard refusal (replay.ex check_irreversible):
  # an unsafe replay is never permitted when the irreversible check can't run.
  # Normalize replay's raw bubbled error to a determinable blocker so
  # preflight_clear? cannot be true while replay would refuse. Keep the warning
  # for the underlying read-error detail.
  {false, [{:not_replayable, :irreversible_check_failed}],
   ["irreversible-event read failed: #{inspect(reason)}"]}
```

`irreversible_executed?: false` stays (no positive evidence observed); the blocker
+ warning carry the "could not verify" state. `{:not_replayable, _}` is the
established family for "not replayable" reasons; `normalize_blocker/1` already
handles it (→ `%{code: :not_replayable, detail: :irreversible_check_failed}`).

*Note on the only step read-failure branches left as warnings* (`load_steps`,
`diagnose_gates`): those stay warnings on purpose — they feed `failed_steps` /
`pending_gates` (health info), not a replay *safety gate*, so replay has no
corresponding refusal to mirror. Only the irreversible read maps to a refusal.

### P2 — hash-less runs must resolve before reporting `:no_hash` (`diagnose_kind/2`, ~line 281)

`replay.ex:125` calls `DefinitionResolver.resolve/2` *before* its `:no_hash` gate
(`replay.ex:202`). diagnose's `definition_hash: nil` clause short-circuits to
`:no_hash` and never resolves, so a hash-less legacy run whose skill/module is now
unavailable diagnoses `:no_hash` while replay refuses with the resolution error
(e.g. `{:not_replayable, :skill_unavailable}`). **Mirror the gate's
kind→resolve→hash order within the definition axis.**

Delete the `definition_hash: nil` clause; the surviving `diagnose_kind/2` clause
already resolves (its `rescue` is unchanged and now covers `stored == nil` too).
Add a *first* `classify_resolution/3` clause for "resolved OK but no stored hash":

```elixir
# kind present → resolve fresh, then classify. Replay resolves the definition
# BEFORE its no-hash gate, so a hash-less run whose skill/module is now
# unavailable must surface the resolution failure, not be masked by :no_hash.
defp diagnose_kind(%WorkflowRun{definition_hash: stored} = run, kind) do
  kind
  |> DefinitionResolver.resolve(run)
  |> classify_resolution(kind, stored)
rescue
  # ...unchanged rescue...
end

# resolve OK but no stored hash to compare → :no_hash. Replay reaches its
# no-hash gate only AFTER a successful resolve, so :no_hash applies only when
# resolution succeeds. We have the freshly-resolved hash in hand, so surface it
# as current_hash (no stored baseline to diff against, but useful diagnostic
# data). MUST precede the `when current == stored` clause.
defp classify_resolution({:ok, %{hash: current}}, kind, nil) do
  {definition_map(kind, :no_hash, nil, current, nil), [{:not_replayable, :no_hash}], []}
end
```

The existing `{:error, {:not_replayable, detail}}` clause then handles the
hash-less-and-unavailable case via `unavailable(kind, nil, detail)` →
`definition.status: :unavailable` + the real blocker. **Decision: within the
definition axis, report the first failing sub-gate (resolve), not a `:no_hash`
union** — this exactly mirrors replay's short-circuit and is consistent with how
`:no_definition_kind` is already reported before the hash gate. (Cross-axis —
terminal/definition/input/irreversible — diagnose still unions, unchanged.)

Verified safe against every existing definition-axis test: the
disallowed-module, deleted-skill, and `:no_definition_kind` cases all carry a
non-nil hash (or skip `diagnose_kind` entirely), so their output is unchanged;
the hash-less *valid* case still resolves OK → `:no_hash`. All use `in`
membership assertions, so the additive irreversible blocker (P1) is also safe.

Update the moduledoc `definition.status` precedence line (~`diagnostics.ex:63-67`),
which currently states "kind present + hash nil → `:no_hash`" unconditionally, to:
"kind present, resolve fails → `:unavailable` (reported even on a hash-less run,
since replay resolves before the hash gate); resolve OK + hash nil → `:no_hash`;
resolve OK + hash present → `:match`/`:changed`."

### P3 — byte-cap every string leaf in the wire map (`to_mcp_map/1`, ~line 195)

Count-capping the four lists to 10 doesn't bound an oversized string *inside* a
kept item: `failed_steps`/`unresolved_steps` carry `name`/`step_type`,
`pending_gates` carries `step_name`, and warnings carry raw `Exception.message/1`
/ `inspect(reason)` — so a refusal can still emit an oversized
`details.diagnostics` despite the "bounded MCP map" contract. (Only the
`step_view` *error* field is already ≤200 chars via `Visibility`;
`name`/`step_type`/`step_name` and warnings are not.) Cap all string leaves
uniformly, **after** `JsonSafe.encode/1` (so it walks the final string-keyed
shape), keeping the existing blocker/`definition.detail` pre-capping:

```elixir
# tail of to_mcp_map/1 (was: JsonSafe.encode(wire)):
wire
|> JsonSafe.encode()
|> cap_wire_strings()

# new private helper:
defp cap_wire_strings(map) when is_map(map),
  do: Map.new(map, fn {key, value} -> {key, cap_wire_strings(value)} end)

defp cap_wire_strings(list) when is_list(list),
  do: Enum.map(list, &cap_wire_strings/1)

defp cap_wire_strings(value) when is_binary(value), do: byte_cap(value)

defp cap_wire_strings(value), do: value
```

This subsumes the warning-only idea: warnings are now bounded in count by
`bound_list` (still needed for `warnings_omitted`) and in length by
`cap_wire_strings`, same as every other string leaf. The pre-encode
`normalize_blocker`/`bounded_definition` capping stays — it normalizes blocker
*shape*, not just length, and re-capping an already-≤512-byte string post-encode
is an idempotent no-op. `cap_wire_strings/1` is **private** — no new public
surface (no moduledoc/`@spec` obligation; matches `byte_cap/1`'s precedent).

Also update the now-stale docs/comments to match the split design: the
`to_mcp_map/1` `@doc` currently states "Bounding happens **before**
`JsonSafe.encode/1`", and the section comment reads `# -- MCP bounding (must
precede JsonSafe.encode) --`. Both must now say: *shape, list-count, and detail
bounds run before encode; the final string-leaf byte-cap runs after* (it walks
the encoded string-keyed shape).

## Files to change

- **`lib/jido_claw/orchestration/replay/diagnostics.ex`** — the three fixes above
  (P3 adds one new *private* `cap_wire_strings/1` helper) plus the moduledoc
  precedence-line update and the `diagnose_irreversible` inline comment. No new
  *public* functions, aliases, or module attributes (so no new
  `compile_check`/credo/reach obligations).
- **`test/jido_claw/orchestration/replay/diagnostics_test.exs`** — two new tests
  (below). Uses the existing `JidoClaw.Test.ReplayFixtures` helpers already
  imported.

## Test plan

Add to `diagnostics_test.exs`:

1. **P2 — hash-less + unavailable definition diagnoses `:unavailable`, not `:no_hash`** (in the "definition axis" describe). Forge a hash-less run with a disallowed-module config (no `definition_hash` key ⇒ `nil`):

   ```elixir
   run =
     forge_terminal_run!(
       %{name: "forge-nohash-unavailable",
         config: %{reactor: "Enum", definition_kind: "module"},
         replay_inputs: encode_inputs()},
       ctx
     )

   {:ok, reloaded} = WorkflowRun.by_id(run.id, tenant: ctx.tenant, actor: ctx.actor)
   assert reloaded.definition_hash == nil

   assert {:ok, diag} = Replay.diagnose(run.id, tenant: ctx.tenant, actor: ctx.actor)
   assert diag.definition.status == :unavailable
   assert diag.definition.detail == {:disallowed_module, "Enum"}
   assert {:not_replayable, {:disallowed_module, "Enum"}} in diag.blockers
   refute {:not_replayable, :no_hash} in diag.blockers   # pins "no :no_hash union"
   refute diag.preflight_clear?

   # Anti-drift: replay refuses with the SAME blocker (resolves before the no-hash gate).
   assert {:error, {:not_replayable, {:disallowed_module, "Enum"}}} =
            Replay.replay(run.id, tenant: ctx.tenant, actor: ctx.actor)
   ```

2. **P3 — `to_mcp_map/1` byte-caps oversized string leaves (list-item fields *and* warnings)** (in the "to_mcp_map/1" describe). Build a `%Diagnostics{}` directly (plain struct) with >512-byte strings in a warning, a `pending_gates` `step_name`, and a `failed_steps` `name` — the cleanest seam, no read-failure needed:

   ```elixir
   long = String.duplicate("x", 5_000)

   diag = %Diagnostics{
     run_id: Ash.UUID.generate(),
     warnings: [long],
     pending_gates: [%{id: Ash.UUID.generate(), step_name: long, kind: :approval, status: :pending}],
     failed_steps: [%{name: long, step_type: long, sequence: 0, status: :failed}],
     generated_at: DateTime.utc_now()
   }

   mcp = Diagnostics.to_mcp_map(diag)
   assert byte_size(hd(mcp["warnings"])) <= 512
   assert byte_size(hd(mcp["pending_gates"])["step_name"]) <= 512
   assert byte_size(hd(mcp["failed_steps"])["name"]) <= 512
   assert byte_size(hd(mcp["failed_steps"])["step_type"]) <= 512
   assert {:ok, _json} = Jason.encode(mcp)
   ```

   (The existing count-cap test — `failed_steps` truncates to 10 with `*_omitted`
   set — stays; this adds the per-leaf length cap.)

**P1 test gap (intentional, documented):** forcing `WorkflowEvent.for_run/3` to
return `{:error, _}` mid-`build/3` is not achievable cleanly — there is no mock
library in the project, and `replay_test.exs` leaves the identical
`check_irreversible` bubble-up branch untested for the same reason. The
blocker→`preflight_clear?: false` wiring the fix relies on is already covered by
the existing "executed irreversible step … `refute diag.preflight_clear?`" test.
I'll note this in the plan/PR rather than add Mox unprompted (scope creep). If the
team wants the branch pinned, adding `mox` + a behaviour seam is a follow-up.

No changes required to `replay_workflow_test.exs` or `workflows_live_test.exs`:
the findings live entirely in diagnostics, their existing diagnostics-attach
assertions still hold, and no new WorkflowsLive assign is introduced (so the
render-assigns triad is untouched).

## Scope & noted limitation

These findings are about `Replay.diagnose/2`'s own correctness (the blocker set,
the definition axis, the wire-map bound) — so the fix is confined to
`diagnostics.ex`. Direct `diagnose/2` callers and the dashboard's preflight panel
get the corrected `preflight_clear?` / `blockers` / `definition` immediately.

One consumer gap is **deliberately left as an optional follow-up**: the tool
(`replay_workflow.ex` `refusal_error/4`) and dashboard attach/stash diagnostics
only for enumerated refusal shapes (`{:definition_changed, _, _}`,
`:irreversible_steps_executed`, `{:not_replayable, _}`). The P1 path —
`WorkflowEvent.for_run/3` failing inside replay's `check_irreversible` — makes
`Replay.replay/2` bubble the *raw* read error, which is none of those shapes, so
the tool's catch-all returns a bare string (no diagnostics) there. Closing it is a
one-branch change in those two consumers, but it is out of scope for these
findings and often self-degrades anyway (the same DB fault would also fail
`diagnose/2`'s own event read, which degrades silently by design). Flagged so the
"inherit automatically" claim above isn't overread.

## Verification

Run via `mise exec -- mix` (project toolchain = mise latest, OTP 29 / Elixir 1.20).

1. Touched suites first:
   `mise exec -- mix test test/jido_claw/orchestration/replay/ test/jido_claw/orchestration/replay_test.exs test/jido_claw/tools/replay_workflow_test.exs test/jido_claw/web/live/workflows_live_test.exs`
2. Optional manual smoke (Tidewave `project_eval`): forge a hash-less run with a
   disallowed-module config, call `Replay.diagnose/2`, confirm
   `definition.status == :unavailable` (not `:no_hash`) and the matching blocker;
   build a `%Diagnostics{}` with a long warning and confirm `to_mcp_map/1` caps it.
3. **The gate (definition of done):** `mise exec -- mix precommit` run **bare**
   (never piped — `| tail` masks the exit code) in the background, then read the
   output tail. It runs `jidoclaw.compile_check`, `format --check-formatted`,
   `reach.check --smells --strict`, `credo --strict`, `dialyzer`, and `test`.
   **Not complete until `mix precommit` passes.**

Note: the Stop hook's `compile --warnings-as-errors` always fails on the 2
intentional `pull_request_coordinator` warnings — expected, **not** a signal from
this change; trust `jidoclaw.compile_check`/`precommit`, which tolerate exactly
those two.

## Suggested commit (do not run — leave unstaged)

After `mix precommit` passes, stage `diagnostics.ex` + `diagnostics_test.exs`:

```
fix: align replay diagnostics with the replay gate (review P1/P2/P3)

- irreversible-event read failure is now a blocker (was a warning only), so
  preflight_clear? can't read true while Replay.replay/2 would refuse on the
  same failed safety check
- hash-less runs resolve the definition before reporting :no_hash, so an
  unavailable skill/module surfaces its real blocker instead of being masked
  (mirrors replay's resolve-before-hash order)
- to_mcp_map/1 byte-caps every string leaf in the wire map (warnings plus
  list-item name/step_type/step_name fields), honoring the bounded-MCP-map
  contract
```
