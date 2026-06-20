# AR-2 Phase 2b — Code-review remediation (4 validated findings + 1 adjacent leak)

## Context

The Phase 2b plan (`please-review-docs-exploration-alp-river-mellow-lagoon.md`) shipped the
encrypted `ComposerArtifact` ref-store and the `sanitize_sensitive_context` marker that threads
through six durable sinks so a marked composer run leaves **no plaintext artifact value at rest**.
A post-merge code review found four gaps. I verified all four against the tree (Tidewave-free, by
reading the exact cited lines) and ran a completeness sweep that surfaced **one more leak in the
same chokepoint**. This plan closes all of them. The completion gate is **`mix precommit` green**
(strict compile / credo / reach at zero, format, tests).

**Validation summary (all confirmed real):**

| # | Severity | Finding | Verdict |
| --- | --- | --- | --- |
| P1a | P1 | Marked trace spans leak **every metadata-derived column** (`name`, `phase`, and the `trace_id`/`run_id`/`span_id` IDs) — only `metadata`/`measurements` maps are digested | ✅ confirmed (`collector.ex:353-373`, `persistence.ex:142-156`) |
| P1b | P1 | Marked composer **failure-reason** writes bypass the middleware scrub: parent terminal + runner backstop | ✅ confirmed (`route_composer.ex:728`, `reactor_runner.ex:769-772`) |
| +  | P1 | **(sweep) `step_failed` `:error` is unscrubbed** — routes through the middleware `append/4` chokepoint but has no `scrub_payload(:step_failed, …)` clause; carries the failed subagent step's `Reason.format(errors)` | ✅ confirmed (`reactor_middleware.ex:279`, `442` catch-all) |
| P2 | P2 | Inline seed values shaped `art_<hex>` are misread as refs (regex heuristic) → spurious wave failure | ✅ reproduced shape (`artifact_context.ex:114,122`) |
| P3 | P3 | `set_active`/`tombstone_active` have **no state precondition** — a `:pending` row can be tombstoned, a `:tombstoned` row reactivated | ✅ confirmed (`composer_artifact.ex:219-229`; test `…test.exs:87-101` tombstones a pending row) |

The reviewer's **kept deviation** (fail-**open** on trace `:unknown`, only `:marked` digests) is sound
and is **preserved** — every fix below redacts on `:marked` only, never on `:unknown`.

---

## P1a — Redact every metadata-derived column on marked trace spans

**Root cause.** `Collector.normalize_event/5` (`lib/jido_claw/trace/collector.ex:340-384`) digests only
`measurements`/`metadata` via `digest_if_sensitive/3`. **Every other scalar the `Event` struct derives
from raw metadata is also a sink:** `name` (`event_name_label/2` ← `metadata.name`/`tool_name`/… —
arbitrary string content), `phase` (`atom_value`), **and the ID columns** `trace_id`
(← `metadata.jido_trace_id`/`trace_id`), `run_id` (← `metadata.run_id`), `span_id`
(← `metadata.jido_span_id`/`span_id`), `parent_span_id`. These are persisted raw (`persistence.ex:142-156`).
A marked span stores content in `name`/`trace_id`/`span_id` while `metadata` reads `%{"redacted" => true}`.

**Trust boundary (the principle).** The *only* trusted ID on a marked span is **`request_id`** — it is
the registered correlation key the marker was looked up by (generated in `register_child_correlation`,
not free-form metadata content). Everything else metadata-derived is potentially tainted and must be
**collapsed to the trusted key** or **shape-gated**, not assumed structural.

**Fix (collector.ex).** Compute the marker **once** (`marker = marker_for(request_id)`,
`marker_for(nil) → :unmarked`, preserving the nil-request_id pass-through) and branch each derived
column when `:marked`:

- `measurements` / `metadata` → `redacted_map/0` (unchanged).
- `name` → `SensitiveScrub.redacted_text()`; `phase` → `nil`.
- `trace_id` → **`request_id`** and `run_id` → **`request_id`** (derive from the trusted key; ignore the
  metadata-derived values). Trace assembly keys on `request_id` first (`trace_key/1:675-676`), so
  collapsing keeps grouping coherent and never strands the span.
- `span_id` / `parent_span_id` → **kept only if `safe_generated_id?/1`** (a UUID / bounded-hex token
  shape — what `Ash.UUID.generate` / Jido span IDs produce), else **`nil`**. A free-form secret fails
  the shape gate and is dropped; a real generated span ID survives so the span graph stays useful.
- **Keep as-is** (genuinely non-content): `request_id` (trusted key), `status` (enum),
  `source`/`category`/`event` (atoms from the telemetry **event name**, not metadata), `at_ms`,
  `duration_ms` (numbers).
- `marker_status/1` stays the single ETS→durable lookup (no extra calls — it already ran once inside
  `digest_if_sensitive`). **Fail-open on `:unknown` is preserved** — only `:marked` redacts.

**Tests (`test/jido_claw/trace/collector_test.exs`).** Plant the secret in **each** derived column —
`metadata.agent_id` (→ `name`), `metadata.trace_id`, `metadata.span_id` — and for a **marked** span
assert: `event.name == "[composer-sensitive:redacted]"`, `event.phase == nil`, `event.trace_id ==
request_id`, `event.span_id == nil` (free-form secret), and `event.request_id == request_id` survives.
Add a case where `span_id` *is* a valid UUID and assert it is preserved (shape gate). Keep the unmarked
+ unknown controls (must still carry the raw `name`/`trace_id`).

---

## P1b — Redact marked failure-reason writes (3 sinks, all `:run_failed`/`step_failed`)

The child-wave reactor's `run_failed`/`run_completed`/`step_completed` are already scrubbed at the
middleware chokepoint (`reactor_middleware.ex:428-440`). Three sibling failure-reason writers are
**not**. Sweep confirmed these are the complete reachable-with-sensitive-content set (gate-pause /
gate-resume writers are unreachable for ungated composer struct-waves; the two recovery writers emit
constants).

### (i) Middleware `step_failed` clause — the one-line gap

`map_event({:run_error, errors}, step)` → `{:step_failed, %{… :error => Reason.format(errors)}}`
(`reactor_middleware.ex:279`) funnels through `append/4` but `scrub_payload/2` has **no
`:step_failed` clause**, so it hits the catch-all (`:442`) unredacted and projects into
`WorkflowStep.error` (a `:string` column). The step **is** the subagent stage — the highest-value
leak. **Fix:** add one clause beside the existing three:
`defp scrub_payload(:step_failed, payload), do: Map.replace(payload, :error, SensitiveScrub.redacted_text())`.

### (ii) Composer parent terminal — single chokepoint via durable marker

Both parent-terminal failure paths funnel through `append_parent_terminal/5`
(`route_composer.ex:663-678`), which already reloads the parent. The marker is **not** persisted on
the parent today (only in live GenServer state), so make it durable and scrub at this one site —
covering the normal `format_terminal_error(:failed, reason)` path **and** the abnormal
`format_terminalize_reason/1` path, and future-proofing 2c/2d recovery (which writes terminals from a
reloaded parent with no live state):

- `route_composer.ex` `parent_config/1` → `parent_config/2`: when `marked`, add
  `"sanitize_sensitive_context" => true` to the genesis `config` map (alongside `"deadline_at_ms"`).
  `create_parent_run/1` passes `marked` (already bound at `:175`). Boolean-in-JSONB round-trips
  cleanly (per the *pin-types-at-Ash-boundaries* rule).
- `append_parent_terminal/5`: after the reload + non-terminal check, when `kind == :run_failed` **and**
  the reloaded `parent.config["sanitize_sensitive_context"] == true`, replace `payload[:error]` with
  `SensitiveScrub.redacted_text()` before `WorkflowLog.append`. `:run_completed` is left alone (its
  `result` is already the opaque `terminal_summary_subset/1` — no artifact values).
- This is **coarse** (a marked `budget_exhausted`/`timeout` reason is also redacted) — consistent with
  the plan's documented "whole-write sanitization when marked / accepted over-mark" policy; the run
  `status: :failed` and event `kind: :run_failed` still convey the failure. `format_terminal_error`
  and `format_terminalize_reason` are **untouched** (they compute the string; the chokepoint discards
  it when marked).

### (iii) Reactor-runner backstop — thread the marker via `finalize_opts`

`append_failed/2` (`reactor_runner.ex:769-772`) writes `Reason.format(reason)` for a child run when
the middleware's `error/2` never fired (pre-`init/1` validation, `{:exit, _}` kill). Lower-risk for
the composer but cited and trivially closed:

- In `run/3`, add `sanitize_sensitive_context: Keyword.get(opts, :sanitize_sensitive_context, false)`
  to the `finalize_opts` keyword (`reactor_runner.ex:311-316`). All `ensure_failed`/`append_failed`
  call sites already receive `finalize_opts`.
- In `append_failed/2`, compute `formatted = if Keyword.get(opts, :sanitize_sensitive_context, false),
  do: SensitiveScrub.redacted_text(), else: Reason.format(reason)`. Both the durable append and the
  PubSub backstop broadcast then carry the redacted value. **Default `false` ⇒ byte-identical for
  every non-composer caller.**

**Tests.**
- `reactor_middleware` suite: a marked run's `step_failed` writes `WorkflowStep.error ==
  "[composer-sensitive:redacted]"`; an unmarked run keeps the real reason.
- `route_composer` suite: a marked composer wave that fails persists `parent.error ==
  "[composer-sensitive:redacted]"` and the secret reason is absent from the parent run + its
  `run_failed` event payload; assert the parent `config["sanitize_sensitive_context"] == true` at
  genesis; an unmarked run keeps the formatted reason.
- `reactor_runner` suite: a marked run forced to the backstop (pre-`init` failure) writes a redacted
  `error`; `:infinity`/unmarked default is unchanged.

---

## P2 — Explicit `{:ref, _}` tag instead of the `art_<hex>` regex heuristic

**Root cause.** `ArtifactContext.resolve_entry/3` (`artifact_context.ex:114-122`) distinguishes a
wave-produced ref from an inline seed value by regex `~r/\Aart_[0-9a-f]+\z/`. A seed value that merely
looks like `art_<hex>` (e.g. `%{"request" => %{"user" => "art_deadbeef"}}`) is misread as a ref and
fails the wave. Sweep confirms **`resolve_entry/3` is the only reader that inspects producer-map
values**; every other reader (`Fold.available/1`, `summary/3`, Router, Loop) is key/size-only or
pass-through, so tagging is safe.

**Fix (tag at the one write boundary, match the one read boundary).**

- `route_composer/fold.ex` `fold_artifacts/3` (`:75-82`): store `{:ref, ref}` (a tuple) instead of the
  bare `ref` string — every emission artifact value in Phase 2b **is** a ref, so wrap unconditionally.
  Seeds (which enter only via `init/1`'s `:artifacts` opt, never through fold) stay bare. The durable
  `StageEmission.artifacts` / `WaveCollect` emission shape is **unchanged** (still bare `art_<hex>`
  strings → JSON-safe) — only the in-memory fold store is tagged, so no migration / no durable-shape
  change.
- `route_composer/artifact_context.ex`: replace `resolve_entry/3` + delete `ref?/1` (it becomes unused
  — must be removed or strict compile fails). New shape:
  - `resolve_entry({:ref, ref}, tenant, actor) when is_binary(ref) → ComposerArtifact.resolve_value(ref, …)`
  - `resolve_entry(entry, _t, _a) → {:ok, entry}` (inline seed: any non-`{:ref,_}` term).
  - Widen `@type store` and refresh the moduledoc note (ref = `{:ref, String.t()}`, seed = inline).
- **Preserve the public summary contract (`route_composer.ex`).** `summary/3` (`:637-648`) returns
  `artifacts: state.artifacts`, which `run_sync/1` surfaces to the caller (public/test-facing). Tagging
  would leak `{:ref, ref}` tuples into that map. Add `artifacts: unwrap_refs(state.artifacts)` — a small
  helper mapping `{:ref, ref} → ref` and leaving seeds bare — so the summary keeps its existing bare-ref
  shape (it is display/notify only, never re-resolved). The durable parent `result`
  (`terminal_summary_subset/1`) already omits `artifacts`, so it is unaffected. The in-memory `history`
  entries (`emission_entry/1`) already carry bare refs straight from the emission, so they need no
  change.

**Tests (`test/jido_claw/route_composer/artifact_context_test.exs`).**
- Change the `store_ref/4` helper to return `{:ref, row.ref}`; the literal-ref cases (`:109` missing
  ref, and the wrong-tenant/corrupt cases) wrap as `{:ref, "art_…"}`. Error-tuple assertions become
  `{:artifact_resolve_failed, {:ref, "art_…"}, _}`.
- **Add a regression test:** a bare seed value `%{"request" => %{"user" => "art_deadbeef"}}` (no
  `{:ref,_}`) builds `{:ok, text}` rendering `"art_deadbeef"` verbatim — never resolved/failed.
- Check `test/jido_claw/route_composer/fold_test.exs` (if present) for any bare-ref store-shape
  assertion and update to `{:ref, _}`. **Audit `sensitive_route_test` (and any `run_sync` test asserting
  `summary.artifacts`)** — confirm the `unwrap_refs/1` step keeps those assertions seeing bare refs.

---

## P3 — Single-transition guards on `set_active` / `tombstone_active`

**Root cause.** Both actions are bare `change(set_attribute(:state, …))` with no precondition
(`composer_artifact.ex:219-229`), so a `:pending` row can be tombstoned and a `:tombstoned` row
reactivated. Wired only in 2c (via `ActivateForWave`), so blast radius is the resource + its test.

**Fix (new validation module + `require_atomic? false`).** Mirror the in-repo precedents:
`Fact.Validations.SourceForInvalidateByLabel` (`memory/resources/fact.ex:773-796`,
`use Ash.Resource.Validation` + `@impl … def validate(changeset, opts, _ctx)`) and the
extracted-sibling pattern (`composer_artifact/changes/validate_cross_tenant_fk.ex`):

- New file `lib/jido_claw/orchestration/composer_artifact/validations/require_state.ex` —
  `use Ash.Resource.Validation`. Implement **`init/1`** (`@impl …`): validate `opts[:expected]` is one
  of `[:pending, :active, :tombstoned]`, returning `{:ok, opts}` or `{:error, …}` so a bad wiring fails
  at compile, not runtime. `validate(changeset, opts, _context)` reads `changeset.data.state` (the
  **loaded** prior value, never the post-change attribute, so order-independent) and returns `:ok` iff
  it equals `opts[:expected]`, else `{:error, field: :state, message: "illegal transition from
  %{actual}", vars: […]}`. Extracted to its own file to keep the hand-rolled resource lean (avoids
  `AshCredo … LargeResource`).
- `composer_artifact.ex`:
  - `set_active`: add `require_atomic?(false)` + `validate({…Validations.RequireState, expected:
    :pending})`.
  - `tombstone_active`: add `require_atomic?(false)` + `validate({…Validations.RequireState, expected:
    :active})`.
  - `require_atomic?(false)` mirrors `WorkflowRun.set_status` and suppresses the non-atomic-validation
    compile warning (which strict `compile_check` would fail on). `ActivateForWave.promote_one/3`
    already calls these in-order (pending→active, active→tombstoned), so it is unaffected.

**Tests (`test/jido_claw/orchestration/composer_artifact_test.exs`).**
- Fix the existing "resolves irrespective of state" test (`:87-101`): chain `store_pending` (→ pending)
  → `set_active` (→ active) → `tombstone_active` (→ tombstoned) → `resolve_value` still works.
- **Add guard tests (fail without the fix):** `tombstone_active` on a `:pending` row → `{:error, _}`;
  `set_active` on a `:tombstoned` row → `{:error, _}`. (Satisfies the *permanent-test-over-spot-check*
  + *prove-the-fix* rules.)
- **Add an `activate_for_wave/3` happy-path test** (the real future consumer of the guarded actions):
  seed two `:pending` rows for a wave, call `activate_for_wave`, assert both become `:active`; seed a
  superseding `:pending` over an existing `:active` for the same `{name, producer}` and assert the old
  active is tombstoned and the new one is active (the partial-unique index is never violated) — proving
  the preconditions compose with `ActivateForWave.promote_one/3` rather than breaking it.

---

## New / changed files

**New:** `lib/jido_claw/orchestration/composer_artifact/validations/require_state.ex`.

**Changed (source):** `lib/jido_claw/trace/collector.ex` (P1a); `lib/jido_claw/orchestration/
reactor_middleware.ex` (P1b-i), `…/reactor_runner.ex` (P1b-iii), `lib/jido_claw/route_composer/
route_composer.ex` (P1b-ii), `…/fold.ex` + `…/artifact_context.ex` (P2),
`lib/jido_claw/orchestration/composer_artifact.ex` (P3).

**Changed (tests):** `collector_test.exs`, `reactor_middleware` test, `route_composer` test,
`reactor_runner` test, `artifact_context_test.exs` (+ `fold_test.exs` if it asserts store shape),
`composer_artifact_test.exs`.

No migration / no resource-snapshot change (P3 adds an action validation, not schema; P1b's config key
is a value in the existing `:map` column).

---

## `mix precommit`-green watch-list (the completion gate)

- **No unused private fn:** delete `ArtifactContext.ref?/1` when P2 stops calling it.
- **No non-atomic warning:** `require_atomic?(false)` on both P3 actions.
- **No string-building credo/reach ping-pong:** all redactions are whole-value replacements with the
  `SensitiveScrub.*` constants — no `<>`/`Enum.join` accumulation introduced.
- **ExSlop clone check:** P3 uses **one** parametrized `RequireState` validation (not two near-identical
  inline guards); P1b's three sink edits live in different modules and are not contiguous.
- Run the **full** `mix precommit` (never piped through `tail`); credo + reach kept at **zero**.

---

## Verification

1. **`mix precommit`** — the gate (compile strict, format, credo, reach, full test suite).
2. **Targeted suites:** `mix test test/jido_claw/trace/collector_test.exs
   test/jido_claw/orchestration/composer_artifact_test.exs
   test/jido_claw/route_composer/artifact_context_test.exs`, plus the
   reactor_middleware / reactor_runner / route_composer suites.
3. **Optional Tidewave smoke (non-destructive — never `mix ecto.reset` on a dev DB):** the committed
   sink tests above are the primary evidence. For a manual end-to-end check, drive a marked composer wave
   to failure via `project_eval` against the existing DB and `execute_sql_query` the parent
   `workflow_runs.error`, child `workflow_steps.error`, and `trace_events.name`/`trace_id`/`metadata` —
   confirm `"[composer-sensitive:redacted]"` / `{"redacted":true}` and the planted secret appears in
   **none** of the derived columns. Build an `ArtifactContext` store with a bare `art_<hex>` seed and
   confirm `{:ok, text}` (no spurious `:artifact_resolve_failed`). Insert/clean up your own rows; do not
   reset the database.
