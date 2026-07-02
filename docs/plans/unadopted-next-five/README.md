# Plan: Next five items from the unadopted-ideas rollups

*A sequenced work queue — not new design. Selected 2026-07-02 from the three
UNADOPTED-IDEAS rollups
([gust](../../exploration/gust/UNADOPTED-IDEAS.md),
[jidoka](../../exploration/jidoka/UNADOPTED-IDEAS.md),
[alp-river](../../exploration/alp-river/UNADOPTED-IDEAS.md)), all compiled and
re-verified that same day.*

**Selection principle.** The rollups are trigger-disciplined, so this queue only
admits items that are either explicitly marked "do now" (one footnote) or whose
trigger is *satisfied by the act of deciding to work* — "next MCP work session,"
"next composer increment wanted," "next doctrine authoring pass," "next material
rewrite of the prompt surface." Everything gated on external circumstance or
missing evidence (WS6's second node, cron incidents, prompt-cost telemetry,
observed hangs) stays parked, per the rollups' own logic.

**Effort legend**: XS ≤ 2h · S ≤ 1 day · M 2–4 days · L ~1 week. File:line refs
are as-of 2026-07-02.

| # | Item | Source | Effort | Shape |
| --- | --- | --- | --- | --- |
| 1 | ✅ **DONE 2026-07-02** — `git push` approval pattern + footnote hygiene sweep | alp-river footnotes + jidoka footnote | XS–S (half-day) | One session |
| 2 | ✅ **DONE 2026-07-02** — G2-1b: Phase 0 spike → `jido://workflows/<stage>` resources | gust #1 | S–M (1–2 days green path) | Spike green same day; no dep patch |
| 3 | AR-9 judge-panel plan wave, pulling in tiering seam + premises threading | alp-river #2 + #1 + #3 | M–L (~1 week) | **Must be broken down — 4 PRs** |
| 4 | `code-doctrine` slice (riding #3's authoring pass) | alp-river #5 (slice half only) | S (≤1 day) | Single PR, or a commit inside #3 |
| 5 | Deterministic eval harness, minimal slice | jidoka #1 | M (2–3 days) | 2 parts |

**Sequencing.** Items 1 and 2 are independent of everything and of each other —
good first/filler work. Item 3 is the program centerpiece (its PR-1 can also
land immediately). Item 4 rides item 3. Item 5 deliberately comes last: items
3+4 are what fire its trigger, and it pins the surface they create. Each item
ends by reconciling the corresponding inventory/UNADOPTED entries — the whole
entry (gap, adoption sketch, cross-refs), not just the status line. Total
program: roughly 2–2.5 weeks of focused work.

---

## 1. `git push` gate + recorded one-liner sweep — XS–S — ✅ DONE 2026-07-02

> **Done 2026-07-02**, with two corrections to this entry's own claims: (a) step
> 1's "an *unresolved* git subcommand already falls to `{:opaque, scope: :git}`"
> was wrong — only `commit`/`config` were special-cased and an unknown
> subcommand was *benign*, so the gate needed a real `pushes?` invocation fact
> in `ShellCommand.Git`, not just a pattern line; (b) step 3's "three
> moduledocs" citing `Cases.retract/3` was four files. `Cases.retract/3` was
> deleted whole (incl. `commit_retract/5`, `ensure_not_resumed/3`, the
> `:approval_retracted` event kind + projection arms, `AgentCase.reopen`, the
> `:retracted` timeline kind). Step 4's count swap kept the label-dedup
> semantics via `Ash.Query.distinct(:label)` (a raw-row count would over-count).

The only thing across all three rollups marked immediately actionable
(the [alp-river rollup](../../exploration/alp-river/UNADOPTED-IDEAS.md)'s
minor footnotes: "its footnoted `git push` sibling: yes"): `tool_approval.ex` gates `git commit`
via the `{:effect, :git_commit}` require-pattern, but `run_command "git push"`
publishes to a remote ungated. Bundle the other two recorded opportunistic
one-liners into the same session.

**Plan:**

1. Add a `:git_push` effect to `JidoClaw.Security.ShellCommand` mirroring
   `commit_effect/1` (`shell_command.ex:626`) — the subcommand-resolution
   machinery (env prefixes, `-C`, `sudo`, abs-path, `sh -c`, multiline, alias
   resolution) already exists, and an *unresolved* git subcommand already falls
   to `{:opaque, scope: :git}`, which is gated. Add `{:effect, :git_push}` to
   `@require_patterns["run_command"]` (`tool_approval.ex:158`) and extend the
   known-effect list + moduledocs.
2. Red/green tests per bypass form (plain, `-C "dir"`, env-prefixed, `sudo`,
   `/usr/bin/git`, `sh -c "git push"`, multiline) plus negatives
   (`git log && echo push` stays unmatched) and the `:docker` skip unaffected.
3. AR-1 residuals: fix the false `gates/plan_gate.ex:11` moduledoc claim
   (retraction does not ride `Cases.retract/3`); sweep the three moduledocs
   citing `Cases.retract/3` as the race-fence anchor and delete it.
4. jidoka footnote: swap `blocks_count`'s load-all-`length/1` for `Ash.count/2`
   in Memory/Inspection.

**Breakdown:** none needed beyond 3 small commits (push gate / AR-1 cleanup /
count swap). Note push is pattern-only — there is no native `git_push` tool to
require-list.

## 2. G2-1b per-stage MCP catalog resources — S–M, spike-gated — ✅ DONE 2026-07-02

> **Done 2026-07-02.** The Phase 0 spike ran green on all four gate points
> (in-process drive of the anubis resources handlers against the real
> `JidoClaw.MCPServer`, frame via the generated `init/2`), so Phases 1+3 landed
> the same day and Phase 2 (dep patch) never fired. Status details in the
> [plan doc](../mcp-workflow-resources/README.md)'s header.

Gust's nearest item, "adopted-in-principle" with a complete plan at
[`../mcp-workflow-resources/README.md`](../mcp-workflow-resources/README.md).
The trigger is "the next MCP-server work session" — scheduling it *is* the
trigger. The risk is already isolated: whether jido_mcp's macro layer surfaces
an anubis `component` template resource is unverifiable on paper.

**Plan (follow the plan doc's phases verbatim):**

1. **Phase 0 spike (~half-day, its own commit/decision point):** minimal
   `component` with `uri_template: "jido://workflows/{name}"` inside
   `JidoClaw.MCPServer`; prove via live handshake test that it compiles, appears
   in `resources/templates/list`, routes `read/2` with parsed params, and the
   static catalog still reads first.
2. **Green → Phases 1+3 (S):** `workflow_stage.ex` template resource over
   `Catalog.get/1` + `Stage.to_map/1` (`:not_found` for unknown ids); tests
   asserting via `resources/templates/list` / `__components__(:resource)` —
   **never** `__publish__().resources` (documented false-green trap); update the
   AGENTS.md exposed-resources line and flip G2-1(b) in the gust inventory.
3. **Red → decide:** Phase 2's small additive jido_mcp `publish`-DSL patch
   (preferred over an anubis handler patch), or record a clean kill. That
   decision point is exactly why the spike stands alone.

## 3. AR-9 multi-plan + plan-arbiter, with its two riders — M–L

The [alp-river rollup](../../exploration/alp-river/UNADOPTED-IDEAS.md) names
this "the next substantive composer increment," to adopt "when a composer
increment is next wanted" — and explicitly says to pull #1 (tiering seam) and
#3 (premises) in with it. All substrate exists (AR-3 lens instantiation,
emission ⊆ `publishes` coherence, welded wave commits, stage-first personas);
the port is structurally safer than the source because critique-only challengers
simply never declare `plan-approved` in `publishes`, and the human plan-gate
stays the sole emitter. Full sketch:
[AR-9 in FEATURES-WORTH-BORROWING-V2.md](../../exploration/alp-river/FEATURES-WORTH-BORROWING-V2.md).

**This is the item that must be broken down. Suggested 4 PRs:**

1. **PR-1 — tiering seam (S, can land immediately):** `WaveBuilder` reads the
   existing-but-unwired `%Stage{}` `model`/`effort` fields at spawn time; absent
   fields keep today's uniform `:fast` byte-identically. Watch the present-nil
   `Map.get` trap in the spawn-opts builder (conditionally-put on write, test
   the real builder output — this bit `RouteComposer.build_start_opts` before).
2. **PR-2 — premises threading (S):** thread the run's `premises` list into
   stage task context in `wave_builder.ex`/`agent_runner.ex` so `scope-shift`
   self-reports cite an explicit list instead of reporting blind. Small
   prompt-threading change; use a dedicated context key, not an overloaded
   carrier.
3. **PR-3 — the plan wave itself (M, follow the V2 AR-9 sketch steps 1–5):**
   arming signal (`multi-plan` published only when `significant-build` is live
   and the design space is wide — never default); 2–3 lens planner stages over
   the existing planner template (lens folded into stage `task`, emitting
   `plan:<lens>`/`plan-drafted:<lens>`); critique-only challenger stages
   emitting `critique:<lens>`; a `plan_arbiter` worker with a Zoi decision-memo
   schema (**string** verdict enum `adopt|hybrid|revise_first`, per the Envelope
   round-trip rule) plus the arbiter persona and a tie-break doctrine slice;
   wire waves → the existing plan-gate (Adopt ⇒ gate presents the memo;
   Hybrid/Revise-first ride the existing `plan-rejected` re-plan edge — no new
   gate kind).
4. **PR-4 (or folded into PR-3):** arbiter stage declares high tier via PR-1's
   seam (sketch step 6 — the seam's designed first consumer); lens planners stay
   standard.

Opt-in arming is load-bearing: the single-plan default path must be
behavior-unchanged. Optional cheap rider: emit per-stage prompt-size telemetry
while in `wave_builder.ex`, so AR-11 (artifact handles) stays honestly
evidence-gated on real numbers.

## 4. `code-doctrine` slice — S, riding item 3

Alp-river #5's trigger is "the next doctrine authoring pass (cheapest moment to
write the slice)" — item 3's PR-3 *is* that pass (new arbiter persona +
tie-break doctrine slice). Author the `priv/defaults/doctrine/` code-doctrine
slice following the source's pattern (injected into every producer — the
coder/fixer/implementer-class templates), wire through the existing AR-5 seam,
add injection tests mirroring the existing 8 slices'. Explicitly defer the
READ_MAP half — still speculative. Mostly content authoring; single PR or a
commit inside item 3.

## 5. Deterministic eval harness, minimal slice — M, last

Jidoka's "closest to worth-it of the ten." Its own trigger is "the next material
rewrite of the doctrine slices" — items 3+4 fire it: a new persona, two new
doctrine slices, and a new prose-half/schema-half field contract (the arbiter
memo) are exactly the load-bearing prompt-as-data surface the entry says the
harness should protect.

**Plan:**

1. **Harness core:** lift `Jidoka.Eval.Case`'s shape (spec + request +
   assertions, runnable against fake or live capabilities) rather than accreting
   more one-off stubs — the fake-capability halves already exist in
   `test/support/` (`echo_stub`, `pass_stub`, `forge_stub`, `mcp_client_stub`,
   `front_door_composer_stub`, `strategy_test_helper`).
2. **Seed cases (~6–10):** doctrine-slice injection and content, stage-first
   persona resolution, the reviewer contract fields, confidence tagging, and the
   new arbiter decision-memo contract — pinning the post-AR-9 surface.

Keep it a harness plus a first case set, not an eval program. Two parts as
above.

---

## Deliberately not picked — and the first alternate

WS6 multi-node validation waits on the argus second node being imminent
(external circumstance —
[`../clustering/WS6-testing-and-ops.md`](../clustering/WS6-testing-and-ops.md)).
The cron async-dispatch + watchdog is incident-gated — **if a stuck cron job
shows up while this program runs, it replaces item 5**, and remember its
coupling: going async re-opens the `overlap: :skip|:allow` question, so adopt
them together. Artifact handles, milestone loop, idle watchdog, YAML
file-watch/catalog overlay, JSON-RPC runner protocol, disk-of-truth,
per-tool MCP overlay, boundary controls, agent-builder, `context_ref` lanes,
`forward_context` narrowing, `Chat.Stream`, and the effect journal are all
evidence-, demand-, or upstream-gated with zero carrying cost — the rollups'
verdicts hold.
