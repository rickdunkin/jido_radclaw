# AR-2 Phase 2b — code-review follow-up: nil-marker crash (P1) + Trace fail-open doc reconciliation (P2)

## Context

A code review of the just-completed AR-2 Phase 2b plan
(`please-review-docs-exploration-alp-river-mellow-lagoon.md`) raised two findings. I verified both
against the tree; **both are valid**.

- **P1 (crash bug).** An unmarked child correlation registration crashes with `FunctionClauseError`
  whenever the `tool_context` came through `ToolContext.build/1`/`child/2` — i.e. essentially every
  real sub-agent/workflow turn. This is a live regression introduced by 2b and must be fixed in code.
- **P2 (code-vs-design divergence).** The Trace collector fails **open** on an `:unknown`
  sensitivity marker (only a confident `:marked` digests), but both the plan doc and the committed
  `AR-2-PHASE-2-DURABLE-ENVELOPE.md` design doc specify fail **closed** (digest on `:marked` *and*
  `:unknown`). The implementation carries an explicit comment calling this "a deliberate deviation."
  **Decision (user): keep the code as-is (fail-open) and update the docs** to match — the fail-open
  rationale (C4/C5 guarantee a marked span is never `:unknown` within its retention window, and
  fail-closed would over-digest the common legitimate `:unknown` non-composer span) is the intended
  contract.

**Completion gate:** `mix precommit` must pass (the full pipeline — see Verification).

---

## Finding P1 — coerce the marker to a strict boolean at the registration boundary

### Root cause (verified, fully static — the chain is unambiguous)

1. `ToolContext.build/1` (`tool_context.ex:99`) writes **every** canonical key, present-as-`nil`
   when absent: `Map.new(@canonical_keys, fn key -> {key, Map.get(scope, key)} end)`. Since 2b added
   `:sanitize_sensitive_context` to `@canonical_keys` (`tool_context.ex:63`), an **unmarked** child
   context carries `sanitize_sensitive_context: nil` (the key is *present* with a nil value — the
   moduledoc states this is by design: "Absent keys are written as `nil`").
2. `register_child_correlation/1` (`jido_claw.ex:314`): `Map.get(ctx, :sanitize_sensitive_context,
   false)` returns **`nil`**, not `false` — a `Map.get` default fires only for an *absent* key, never
   for a present-nil one. So `marked = nil`.
3. `register_correlation/6` (`jido_claw.ex:385`): `Keyword.get(opts, :sanitize_sensitive_context,
   false)` is likewise `nil`; the create attrs carry `sanitize_sensitive_context: nil`.
4. `RequestCorrelation.register/1` rejects it — the attribute is `allow_nil?: false`
   (`request_correlation.ex:215-219`); an explicit nil is *not* defaulted (the user's "AshCloak: omit
   key for NULL" rule). The create returns `{:error, _}`.
5. `register_failure(marked, ...)` (`jido_claw.ex:430-435`) is called with `marked = nil`; its only
   clauses are `true` and `false` → **`FunctionClauseError`**.

Why existing tests miss it: the C4 tests in `composer_ttl_contract_test.exs` use `%{}` (line 82) or
maps with the marker key **absent** (line 100) for their unmarked cases — never the `build/1` shape
where the key is present-as-nil. The crash only manifests for a present-nil marker.

**Blast radius is exactly the two sites the reviewer named.** A sweep of every marker read site in
`lib/` confirms all others are already nil-safe (they treat nil as falsy/unmarked, which is correct):
`output_shaper.ex:478` already uses `Map.get(...) == true`; `agent_runner.ex:320` uses `... || false`;
`recorder.ex:776`, `mcp_scope.ex:207`, `subagent_transcript.ex:157`, `signal_listener.ex:172` use
`if Map.get(..., false)` (nil falsy); `collector.ex`, `reactor_middleware.ex:430`, `store.ex:161`
pattern-match `true`/`false` with a fallback. Only the two `jido_claw.ex` sites crash, because they
alone (a) flow the marker into the `allow_nil?: false` Ash field and (b) feed `register_failure/4`.

### Fix (`lib/jido_claw.ex`) — apply the established `== true` idiom

| Site | Before | After |
| --- | --- | --- |
| `register_child_correlation/1` (`:314`) | `marked = Map.get(ctx, :sanitize_sensitive_context, false)` | `marked = Map.get(ctx, :sanitize_sensitive_context) == true` |
| `register_correlation/6` (`:385`) | `marked = Keyword.get(opts, :sanitize_sensitive_context, false)` | `marked = Keyword.get(opts, :sanitize_sensitive_context) == true` |

`== true` coerces `nil`/`false`/absent → `false` and only `true` → `true`, so `marked` is always a
strict boolean. This matches the in-tree idiom at `output_shaper.ex:478`. Coercing at **both**
boundaries (defense-in-depth, per the finding): boundary 1 also fixes its own `_ when marked ->`
guard (`jido_claw.ex:341`) so a present-nil unmarked context cleanly takes the `{:ok, id}` skip rather
than relying on nil being incidentally falsy; boundary 2 fixes the attrs/scope/`register_failure`
path even for a direct `register_correlation/6` caller.

No other code changes — every downstream sink already handles nil correctly.

### Regression tests (`test/jido_claw/route_composer/composer_ttl_contract_test.exs`)

Add a new describe block, e.g. `"P1 regression — present-nil marker coerced to false"`. Both tests
are **deterministic** and fail *before* the fix (FunctionClauseError) / pass *after* — satisfying the
"prove the test fails without the fix" rule:

1. **End-to-end through the real canonical path (the exact path that regressed).** Build the child
   context via `ToolContext.build/1` + `ToolContext.child/2` rather than hand-rolling the nil shape —
   this guards the actual builders that emit the present-nil marker, not just a map that mimics their
   output. Seed a session+tenant with `seed_full/1` (existing helper); register under the **same**
   tenant so the cross-tenant FK passes and the create reaches success (add
   `alias JidoClaw.ToolContext` to the test):
   ```elixir
   %{tenant_id: tenant, session: session} = seed_full(tenant_label: "ttl-p1-nil")

   parent = ToolContext.build(%{tenant_id: tenant, session_uuid: session.id})
   ctx = ToolContext.child(parent, "child")
   # Precondition: the canonical builders really do emit a present-nil marker.
   assert ctx.sanitize_sensitive_context == nil

   assert {:ok, request_id} = JidoClaw.register_child_correlation(ctx)
   assert {:ok, row} = RequestCorrelation.lookup(request_id)
   assert row.sanitize_sensitive_context == false
   ```
2. **Direct `register_correlation/6` (isolates boundary 2).** Different call shape (positional args
   vs map) so it is structurally distinct from test 1 and from the existing C5 test — avoids tripping
   the ExSlop clone check:
   ```elixir
   %{tenant_id: tenant, session: session} = seed_full(tenant_label: "ttl-p1-nil-direct")
   request_id = Ecto.UUID.generate()

   assert :ok =
            JidoClaw.register_correlation(request_id, session.id, tenant, nil, nil,
              sanitize_sensitive_context: nil)
   assert {:ok, row} = RequestCorrelation.lookup(request_id)
   assert row.sanitize_sensitive_context == false
   ```

---

## Finding P2 — document the fail-open Trace policy (docs only, no code/test change)

The collector code (`collector.ex:613-669`) and the test (`collector_test.exs:410`) already implement
and lock fail-open — **leave them unchanged**, including the existing self-documenting comment at
`collector.ex:600-612`. The work is reconciling the two design docs.

### The contract the docs must now state (Trace sink only)

- The Trace marker resolver still returns `:marked | :unmarked | :unknown` and is consulted **only for
  request_id-bearing spans** (a `nil` request_id passes through — unchanged in both docs).
- **Only a confident `:marked` digests.** `:unknown` (absent row or faulting durable read) now
  **passes through (fail-open)**, alongside `:unmarked`.
- **Rationale to fold in:** (a) the C4 abort-on-marked-write-failure + C5 conservative `expires_at`
  ceiling guarantee a genuinely-marked span is resolvable (`:marked`) throughout its realistic
  lifetime, so fail-closed adds nothing for marked data; (b) most legitimate non-composer telemetry
  carries a request_id whose correlation row has expired (~600s TTL) or was never registered, so
  digesting `:unknown` would shred general observability. The residual gap — a marked span arriving
  after its C5 ceiling, or during a transient DB fault — is accepted as beyond the designed
  orphan-drain retention.
- **Do NOT weaken the async-consumer fail-safe.** The doc prose currently couples
  "digest (Trace) / skip (async)". These are *different* mechanisms: the async consumers
  (`Recorder`/`Audit`) skip a write when **scope itself is unresolvable** (they need session/tenant to
  write any row) — a scope-resolution fail-safe orthogonal to the marker, which **stays**. Only the
  **Trace** half flips from "digest on absent/faulting" to "pass-through on absent/faulting." Decouple
  the sentence rather than blanket-editing it.

### Exact edit locations

**`docs/exploration/alp-river/AR-2-PHASE-2-DURABLE-ENVELOPE.md`** (authoritative design doc):
- **Line 316** (the big §15.3 "2b" table row) — three Trace fail-closed statements inside it:
  1. The "**The lookup fails CLOSED** … only a *found, explicitly-unmarked* row passes through …
     **Both `:marked` and `:unknown` digest** the span …" block → rewrite to "Trace digests only a
     confident `:marked`; `:unknown` passes through (fail-open)…" with the rationale above.
  2. "**Privacy still fails closed regardless:** … the lookup reads `:unknown` and the write is
     digested (Trace) / skipped (async) …" → change the **Trace** clause to pass-through; keep the
     **async** skip.
  3. The "done-when" prose near the row's end: "an **absent or faulting** marker lookup fails closed
     (Trace digests; the async `Recorder`/`Audit` consumers skip the write)…" → Trace passes through;
     async skip unchanged.
- **Lines 352-358** (the P1 cross-cutting bullet, "The **lookup-based** carriers … **fail closed**:
  … or a faulting read → `:unknown` — both digest (Trace) / skip (async)…") → split the carriers:
  async skips on unresolvable scope (unchanged); Trace fails open on `:unknown`.

**`.claude/plans/please-review-docs-exploration-alp-river-mellow-lagoon.md`** (the completed plan doc,
staged in this change set — update for record consistency, per the reviewer's explicit request and the
"doc status sweep" rule):
- **Lines 316-336 (B4-c, "Carrier (c)")** — retitle "fail closed:" → "fail open on `:unknown`:";
  rewrite the `marker_status` paragraph (lines 323-327) so only `:marked` digests and `:unknown`
  passes; fix "**Both `:marked` and `:unknown` digest**" and the "**Test both directions**" lines
  (335-336) so a marked row digests while an absent/faulting (`:unknown`) row **passes through**.
- **Lines 503-504 (testing strategy)** — "…confident-marked-digest vs fail-closed unknown-digest
  (absent/faulting row)…" → "…confident-marked-digest vs `:unknown` (absent/faulting) pass-through
  (fail-open)…".
- Optionally add a one-line note to the "Resolved implementation decisions" section recording the
  fail-open deviation as the final, intentional contract.

Markdown edits do not affect any `mix precommit` step (no markdown linter in the pipeline), so P2 is
precommit-neutral; the gate is carried entirely by the P1 code fix + tests.

---

## Files changed

- **Code:** `lib/jido_claw.ex` (two one-line coercions).
- **Tests:** `test/jido_claw/route_composer/composer_ttl_contract_test.exs` (one new describe block,
  two deterministic tests).
- **Docs:** `docs/exploration/alp-river/AR-2-PHASE-2-DURABLE-ENVELOPE.md`,
  `.claude/plans/please-review-docs-exploration-alp-river-mellow-lagoon.md`.

No migration, no resource/schema change, no public API change.

---

## Verification

**Completion gate — full `mix precommit` (the 8-step pipeline, must be green):**
`jidoclaw.compile_check` → `jidoclaw.system_prompt.check` → `deps.unlock --unused` →
`format --check-formatted` → `reach.check --arch --smells --strict` → `credo --strict` →
`dialyzer --format short` → `test`. Run the **full** command (never piped through `tail`); credo + reach
strict stay at **zero** findings (per the standing precommit rule).

Notes on the gate for this change:
- `dialyzer`: the fix narrows `marked` from `boolean() | nil` to strict `boolean()`, which is
  consistent with `register_failure/4`'s `true`/`false` clauses — no new warning expected.
- `reach --smells`: keep the two new tests structurally distinct (different call shapes) so the
  ExSlop clone check (min_mass 30) does not flag them against each other or the existing C5 test.

**Targeted (fast inner loop):**
```
mix test test/jido_claw/route_composer/composer_ttl_contract_test.exs
mix test test/jido_claw/trace/collector_test.exs        # P2 unchanged — must still pass (fail-open)
```

**Prove the tests catch the bug (per "prove the test fails without the fix"):** boundary 2
(`register_correlation/6:385`) is the crash-critical coercion — once `register_child_correlation/1`
coerces (boundary 1), it passes a real `false` downstream, so reverting *one* coercion does not always
reproduce the crash. Cleanest proof: revert **boundary 2** and run **test 2** (the direct
`register_correlation/6` test) — it errors with `FunctionClauseError` in `register_failure/4`; restore
→ green. **Test 1** (end-to-end) reproduces the crash only with **both** coercions reverted (it drives
the full canonical path). So: revert the *relevant* coercion per test, or simply rely on the two tests
+ review.

**Optional smoke (Tidewave `project_eval`):** call
`JidoClaw.register_child_correlation(%{session_uuid: <id>, tenant_id: <t>,
sanitize_sensitive_context: nil})` against a seeded session and confirm `{:ok, _}` with a durable row
where `sanitize_sensitive_context == false`.
