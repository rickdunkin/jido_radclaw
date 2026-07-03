# Review remediation: bound the premises block globally + finish the README entry sweep

## Context

The AR-9 unit-1 plan (velvet-seahorse: tiering seam PR-1 + premises threading PR-2) is
implemented and was code-reviewed. The review produced two findings and one open
question. I verified all three against the working tree:

**Finding 1 [P2] — VALID.** `PremisesContext.render/1`
(`lib/jido_claw/route_composer/premises_context.ex`) bounds *values* (inspect limits +
600-byte clip) but nothing else: `key_text(key) when is_binary(key), do: key` (:58)
passes binary keys through unbounded, every top-level entry renders (no count cap,
:49-53), and there is no total block cap. `compose_extra_context/2`
(`route_composer.ex:1516`) prepends the whole block to **every worker wave**, so a large
premises map or one with huge keys floods every stage prompt — the moduledoc's "one
oversized premise cannot flood a stage prompt" claim (:19-21) doesn't hold for the
whole-map/huge-key cases. The sibling `ArtifactContext` has the missing half of the
pattern: per-value cap (4_000) **plus** `@total_cap 16_000` applied to the joined block
(`artifact_context.ex:47-48,66`).

**Finding 2 [P3] — VALID.** `docs/plans/unadopted-next-five/README.md` item 3's DONE
blockquote (:113-135) corrects the old claims, but the live "Suggested 4 PRs" bullets
still carry them: :149-150 "reads the existing-but-unwired `%Stage{}` … fields **at
spawn time**" (no such seam exists — the correction is the whole point of the
blockquote), :154-155 points PR-2 threading at `wave_builder.ex`/`agent_runner.ex` (it
landed in `route_composer.ex`/`PremisesContext`), and the trailing rider paragraph
(:175-177) still says the telemetry goes "while in `wave_builder.ex`" (it landed in
`agent_step.ex`). Repo-wide sweep (`rg "unwired|spawn time|spawn-time|never threaded|never reads"`)
confirms every other doc already carries dated corrections — only these live bullets
were missed. This is the "doc status flip → sweep whole entry" pattern: reconcile every
now-false present-tense claim, not just add the status note.

**Open question — untracked `docs/exploration/{gepa,osa,osa-claude-code}/` (698 lines):
no action.** They are standalone explorations written the same evening, unrelated to
AR-9. This unit stages/commits nothing (same constraint as velvet-seahorse), so there is
no change to keep them out of. Leave untracked and untouched.

**Constraints**: nothing gets committed — all changes stay unstaged.
Done = `mix precommit` passes (run bare, never piped; report exact exit + counts).

---

## Fix 1 — globally bound the premises block (premises_context.ex)

Add three bounds to `PremisesContext` so the rendered block is bounded **by
construction** for any input, while small/typical premises render **byte-identically**
to today (the exact-equality unit test and both `composer_loop_test.exs` AR-9
integration tests must stay green untouched):

New module attributes (names final, values my recommendation):

```elixir
@key_byte_budget 120        # keys are markdown labels; front-door keys are ~15 chars
@max_entries 32             # realistic premises are <10 entries
@block_byte_budget 6_000    # whole block incl. header + instruction + omission marker
                            # (proportionate to ArtifactContext's 16_000 total cap)
@omitted_marker_prefix "…[" # marker line: "- …[N premises omitted]"
```

Changes in `render/1` (non-empty-map clause):

1. **Key clip**: generalize the existing budget-fixed `clip_value/1` into `clip/2`
   (`clip(text, budget)` — guard clause ≤ budget passes through, else the existing
   UTF-8-safe `clip_at/2` walk-back, unchanged). Values clip at `@value_byte_budget`
   (600, as today); rendered key text clips at `@key_byte_budget`. **Sort by the full
   (unclipped) `key_text/1`** so ordering stays exactly today's, render the clipped key.
2. **Count cap**: after sorting, `Enum.take(@max_entries)`.
3. **Total cap — structural, never a tail byte-clip; two-pass so the marker
   reservation can never cause the omission it marks**:
   - *Pass 1 (no marker)*: render the count-capped sorted lines; if the count cap
     omitted nothing AND header + lines + instruction fit ≤ `@block_byte_budget`, emit
     as-is — a near-budget block that fits exactly is never truncated merely because
     marker space was pre-reserved.
   - *Pass 2 (omission actually forced — the count cap dropped entries, or pass 1
     overflowed)*: re-fold the lines in sorted order, keeping each while the running
     total (header + separators + kept lines + the omission-marker line + the
     instruction) stays ≤ `@block_byte_budget`; drop the rest.

   A tail byte-clip of the joined block would amputate the `@instruction` line — the
   actionable `scope-shift` part — so elision drops whole trailing entries and the
   header + instruction always survive. By construction a max-fat line is < ~800 bytes
   (120 key + 600 value + markup + two elision marks), so ≥ 7 lines always fit — no
   empty-block edge case.
4. **Omission marker**: whenever entries were omitted (by either cap), append one line
   `- …[N premises omitted]` (N = `map_size(premises)` − kept) before the instruction.
   Nothing omitted ⇒ no marker ⇒ byte-identical output to today.
5. **Moduledoc**: strengthen the bounded-renderer paragraph to the real property — keys
   clipped, entry count capped, whole block ≤ `@block_byte_budget` with the instruction
   line always intact; a hostile/huge premises map cannot flood a stage prompt.

Invariant to pin in tests: `byte_size(render(anything)) <= 6_000`. The attribute is
private to the module, so tests duplicate the value as an explicit local
`block_budget = 6_000` (with a comment naming `@block_byte_budget` as its source) —
never implied access to the attribute.

### Tests (red first) — `test/jido_claw/route_composer/premises_context_test.exs`

Confirm each new test **fails against the current renderer** before implementing:

- many premises: 500 small entries → block ≤ 6_000 bytes, omission marker with the
  right count, header + instruction line both present, `String.valid?`;
- huge binary key: one 50KB key → key elision-clipped (full key absent from output),
  block bounded, valid UTF-8;
- total-cap fold: enough max-size values (per-value cap individually respected) that the
  joined block would exceed the budget → trailing (sort-order) entries dropped, kept
  set is the deterministic sorted prefix, marker + instruction intact;
- adversarial combo: many entries × huge keys × huge values →
  `byte_size(text) <= block_budget` against the explicit local `block_budget = 6_000`;
- near-budget fit (green guard for the two-pass property, not red-first — the current
  unbounded renderer also passes it): a map whose full render lands just under the
  budget **without** a marker → emitted whole, no entry dropped, no omission marker
  (pins "reservation never causes the omission");
- byte-identity guard: the existing exact-equality render test stays green **unchanged**,
  plus an explicit "no omission marker when everything fits" assertion.

Existing tests (totality, sorting, UTF-8 clip, nested-map bounding) all stay green.

## Fix 2 — README item-3 whole-entry reconciliation

`docs/plans/unadopted-next-five/README.md`, item 3 only (the DONE blockquote :113-135
already carries the full corrected mechanism — the bullets just need flipping to match):

- **:147 lead-in**: "**This is the item that must be broken down. Suggested 4 PRs
  (PR-1/PR-2 landed 2026-07-02 — see the progress note above):**"
- **:149-153 PR-1 bullet**: mark **DONE 2026-07-02** and replace the false claim with
  the real seam, e.g.: "landed — not as the sketched spawn-time read (no such seam
  exists): `WaveBuilder` carries the `%Stage{}` tier into the stage step's options,
  applied per turn via the composed `Compactor.RequestTransformer`; absent fields stay
  byte-identical. (The present-nil `Map.get` trap note held — tier opts are
  conditionally-put.)"
- **:154-158 PR-2 bullet**: mark **DONE 2026-07-02**; threading landed in
  `route_composer.ex` (`compose_extra_context/2`) via the new
  `JidoClaw.RouteComposer.PremisesContext` renderer — not
  `wave_builder.ex`/`agent_runner.ex`; premises ride the wave's `:extra_context` under
  the dedicated block, gate waves excluded.
- **:174-177 trailing rider paragraph**: flip to past tense with the real location —
  the telemetry rider landed in `agent_step.ex` (`[:jido_claw, :composer,
  :stage_prompt]`); the assembled prompt only exists there, not in `wave_builder.ex`.
- PR-3/PR-4 bullets stay as-is (still pending; PR-4's "via PR-1's seam" is now true).

No other file needs edits: the sweep shows `UNADOPTED-IDEAS.md`, both
FEATURES-WORTH-BORROWING docs, `AR-2-COMPOSER-PLAN.md`, `stage.ex`, and AGENTS.md
already carry the dated corrections, and AGENTS.md makes no premises-bounding claim
(Fix 1 changes no behavior it describes — empty premises stay byte-identical).

---

## Verification

1. Red first: add the Fix-1 tests, run
   `mix test test/jido_claw/route_composer/premises_context_test.exs`, confirm the new
   tests fail for the right reason (unbounded output), existing ones pass.
2. Implement Fix 1 → same file green; then
   `mix test test/jido_claw/route_composer/composer_loop_test.exs` — the two AR-9
   premises integration tests (:513, :548) stay green (small premises render
   byte-identically; the `refute task =~ "### Premises"` byte-identity guard holds).
3. Fix 2 is docs-only — no test surface.
4. `mix precommit` — run bare, read its own verdict lines, report exact exit code and
   test counts verbatim. Known flake: `MemoryExportTest` (capture_log race in full
   suite) — rerun in isolation if it trips; do not chase.
5. `git status --short` — nothing staged, no commits; explicitly call out in the final
   report that the three untracked `docs/exploration/{gepa,osa,osa-claude-code}/` docs
   remain untracked and untouched (pre-existing exploration output, not remediation
   output).

## Risks → gates

- **credo strict**: moduledoc updated with the new property; helpers stay small; no new
  public functions (all `defp`; constants are module attributes).
- **reach**: `clip/2` keeps a real guard clause (not a trivial forwarder); the line-fold
  helper does real conditional work.
- **ExSlop clones**: the fold-lines-under-budget shape is novel (≠ `ArtifactContext`'s
  join-then-cap, ≠ the clip walk-back); `clip/2` replaces `clip_value/1` in place —
  no third contiguous cap-helper trio appears.
- **dialyzer**: pure `String.t()` helpers; `render/1` spec unchanged.
- **Zoi / tool-error retryability**: untouched.

## Files touched

| File | Change |
| --- | --- |
| `lib/jido_claw/route_composer/premises_context.ex` | key clip, entry-count cap, structural total cap + omission marker, moduledoc |
| `test/jido_claw/route_composer/premises_context_test.exs` | red-first bounding tests + no-marker byte-identity guard |
| `docs/plans/unadopted-next-five/README.md` | item-3 bullets/lead-in/rider flipped to DONE with corrected seam + locations |
