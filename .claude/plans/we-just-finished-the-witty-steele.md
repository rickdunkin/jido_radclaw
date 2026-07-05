# Plan: resolve the 3 post-item-5 review findings (verify authority)

## Context

The item-5 deterministic-verify work (plan `please-review-docs-plans-unadopted-next-pure-hennessy.md`)
just landed unstaged; a code review found three issues. All three are **validated against source**:

- **P1 (valid)** — `JidoClaw.Config.verify/1` (`lib/jido_claw/core/config.ex:135-140`) collapses any
  non-map `verify:` YAML value to `nil`, so `Verify.Config.resolve_configured/1`
  (`lib/jido_claw/orchestration/verify/config.ex:114-119`) sees `{nil, nil}` and falls through to
  autodetect. `verify: mix format` + a `mix.exs` silently certifies `mix test` — the wrong command,
  violating the module's own "loud, never silent" posture (its moduledoc is the OQ-4 design note).
- **P2 (valid)** — `verified_integrity` is a single latest-wins certificate
  (`lib/jido_claw/route_composer/projection.ex:215-224`), but `stale_verified_cleans/1`
  (`lib/jido_claw/route_composer/route_composer.ex:1229-1239`) checks **every** live verify clean
  against it via `vi.stage == stage`. A catalog with two `{:verify, _}` stages in different Kahn
  levels (the validator at `catalog_validator.ex:337` only requires a lens; the
  `{:verify_must_be_solo_wave, _}` WaveBuilder backstop only covers same-level cohorts) ping-pongs
  retract/re-verify until the rerun budget terminalizes. **User-ratified fix: reject >1 verify
  stage at catalog load** (single-verify-authority design; multi-check needs are served by one
  stage's named `checks:`).
- **P3 (valid)** — one tampered engine verify bumps `jido_claw.verify.total` **twice**: the reactor's
  `emit_verify(result)` (`lib/jido_claw/orchestration/reactors/verify_stage.ex:250`) and the
  composer's post-commit `emit_verify(:tampered_committed)`
  (`lib/jido_claw/route_composer/route_composer.ex:2218`). The metric is documented as one count per
  engine verify with tags `:green/:red/:inconclusive/:tampered` (`lib/jido_claw/core/telemetry.ex:76-79`).
  No test pins the second emission. Fix: drop the composer-side counter, keep its post-commit Trace.

Done = `mix precommit` passes (run directly, exit code + counts verbatim, never piped). Nothing
gets committed; pre-existing unstaged work stays untouched.

## Fix 1 — P1: non-map `verify:` refuses loudly

1. `lib/jido_claw/core/config.ex` — make `verify/1` a raw pass-through like `verify_cmd/1`:
   `def verify(config), do: Map.get(config, "verify")`, `@spec` → `term() | nil`, doc updated to
   say the raw value is preserved so `Verify.Config` can refuse a bad shape loudly (never a silent
   fall-through to autodetect).
2. `lib/jido_claw/orchestration/verify/config.ex` — add a non-map clause after
   `checks_from_block(%{} = block)`:
   `defp checks_from_block(other), do: {:error, {:invalid_verify_config, "verify: must be a map (cmd/env/timeout_ms or checks:) — a bare command belongs under verify_cmd:, got: #{inspect(other)}"}}`
   (existing `format_error({:invalid_verify_config, detail})` already renders it; the reactor
   already channels every resolution error into the loud inconclusive envelope on the infra lane).
   Moduledoc chain step 2 gains one sentence: a non-map `verify:` is a loud
   `{:invalid_verify_config, …}`, never autodetect.
   Note: `verify_cmd:` + a non-map `verify:` both present now correctly hits the existing
   `:ambiguous_verify_config` arm (also loud).
3. **Tests (red first)** — `test/jido_claw/orchestration/verify/config_test.exs`, in the existing
   "config.yaml (chain step 2)" describe, using the existing `write_yaml!` helper:
   - `verify: mix format` (scalar) **with a `mix.exs` present** → asserts
     `{:error, {:invalid_verify_config, msg}}` with `msg =~ "verify_cmd"`. Red today: resolves
     `{:ok, [%{name: "mix:test", …}]}` — the exact wrong-command certification from the report.
   - a YAML **list** under `verify:` → same refusal.
   - (nil / absent `verify:` keeps falling through — existing autodetect tests already pin that.)

## Fix 2 — P2: validator rejects >1 `{:verify, _}` stage per catalog

1. `lib/jido_claw/route_composer/catalog_validator.ex` — add a catalog-level check in the
   coherence phase, ahead of the graph check (`validate/1`'s clean-structural branch becomes
   `coherence(catalog) ++ single_verify(catalog) ++ cycle(catalog)` — "multi-verify unsupported"
   stays invariant 10, cycle stays the final graph check): collect
   `{:verify, _}`-unit stage names; >1 → one problem string in the `cycle` convention, e.g.
   `"catalog: at most one {:verify, _} stage is supported (found: [\"verify\", \"verify2\"]) — the composer retains a single verify certificate"`
   (names sorted). Fold the rule into the moduledoc's invariant 10 bullet (heading "1–10 + cycle"
   stays true).
2. Comment touch-ups (now that load refuses multi-verify, the runtime paths become
   defense-in-depth): `lib/jido_claw/route_composer/loop.ex:86` (`defer_solo_verify` doc's
   multi-verify sentence), the `wave_builder.ex` classify comment, and
   `projection.ex:211-214`'s "latest wins" note (single stage guaranteed by the validator).
   No behavior change in any of those — the `{:verify_must_be_solo_wave, _}` backstop and the
   per-stage `vi.stage == stage` re-check stay as written.
3. **Tests (red first)** — `test/jido_claw/route_composer/catalog_validator_test.exs`, new
   describe "verify-unit invariants (invariant 10)":
   - two-verify catalog → flagged. Build `Fixtures.verify_fixture_catalog()` + a `"verify2"` clone
     (`unit: {:verify, "default"}`, `lens: "verify2"`, `sub: ["code-written"]`,
     `pub: ["clean:verify2", "findings:verify2", "scope-shift"]`, `routes: ["code"]`) so the new
     rule is the **only** problem; assert the message. Red today: `validate/1` returns `[]`.
   - the single-verify fixture stays clean (`validate(verify_fixture_catalog()) == []`).
   - cheap gap-close while here: a lens-less verify stage is flagged (invariant 10 had no direct
     validator test).
   - Existing WaveBuilder backstop tests (`wave_builder_test.exs:152-165`) drive `build_wave/1`
     directly and stay valid.

## Fix 3 — P3: one counter bump per engine verify

1. `lib/jido_claw/route_composer/route_composer.ex:2218` — delete the
   `JidoClaw.Telemetry.emit_verify(:tampered_committed)` line from
   `emit_tampered_observability/2`; the post-commit `:composer` Trace (`event: :verify_tampered`)
   stays. The reactor-side `emit_verify(result)` remains the single documented count per engine
   verify (`telemetry.ex:76-79` becomes accurate again). This also kills a second double-count
   vector: a restart's dedupe-observe path re-folds the tampered emission through
   `emit_tampered_observability` without re-running the reactor.
2. **Test (red first)** — in `test/jido_claw/route_composer/verify_stage_test.exs`'s tampered
   scenario: `:telemetry.attach/4` on `[:jido_claw, :verify]` with a **unique handler id**
   (`"verify-telemetry-#{System.unique_integer([:positive])}"`), forwarding `metadata.result`
   to the test pid, detached via `on_exit`; **drain the mailbox** of any pending
   `{:verify_telemetry, _}` messages before the tamper run (a prior in-file test could have
   left one hanging), then assert exactly one `:tampered` event and `refute_receive` any second
   `[:jido_claw, :verify]` event. Red today: `:tampered_committed` arrives as a second event.
   (Only the reactor emits on this event name, and only `verify_stage_test` drives the reactor,
   so no cross-file async bleed.)

## Docs

- `AGENTS.md` Deterministic Verify Authority bullet — two tight amendments: a non-map `verify:`
  value refuses loudly (never silent autodetect), and at most one verify stage per catalog
  (validator-enforced; `verified_integrity` is a single certificate).

## Verification

1. Red-first per fix: run the new tests before each code change, confirm the documented failure,
   then green: `mix test test/jido_claw/orchestration/verify/config_test.exs
   test/jido_claw/route_composer/catalog_validator_test.exs
   test/jido_claw/route_composer/verify_stage_test.exs`.
2. `mix format`, then the full gate **run directly**: `mix precommit` — report exact exit code +
   test counts verbatim. Known posture: one unrelated timing flake (MemoryExport/collector/:pg)
   per full run → rerun, not a regression.
3. `git status --short` at the end shows only these files changed on top of the existing unstaged
   item-5 work; nothing committed.

## Gate hazards

- Zero credo/reach findings required: the new `checks_from_block/2` clause and `single_verify/1`
  are plain pattern-matched functions (no trivial forwarders, no contiguous clone seams).
- `@spec verify(map()) :: term() | nil` keeps dialyzer quiet at the accessor.
- Validator problem string follows the existing `"catalog: …"` prefix + sorted-names convention
  (drift guards compare name sets, not counts).
