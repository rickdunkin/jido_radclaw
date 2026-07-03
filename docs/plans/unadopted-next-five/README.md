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
| 3 | ✅ **DONE 2026-07-03** (PR-1/PR-2 2026-07-02) — AR-9 judge-panel plan wave, pulling in tiering seam + premises threading | alp-river #2 + #1 + #3 | M–L (~1 week) | **Must be broken down — 4 PRs** |
| 4 | ✅ **DONE 2026-07-03** (slice half; READ_MAP still deferred) — `code-doctrine` slice (riding #3's authoring pass) | alp-river #5 (slice half only) | S (≤1 day) | Single PR, or a commit inside #3 |
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

## 3. AR-9 multi-plan + plan-arbiter, with its two riders — M–L — ✅ DONE 2026-07-03

> **PR-3 + PR-4 DONE 2026-07-03**, with three recorded deviations from the V2
> sketch (and from this entry's own PR-3 bullet): (a) sketch step 5's "arbiter →
> gate on Adopt; Hybrid/Revise-first ride `plan-rejected`" became **planner
> finalizes** — the arbiter is a pure adjudicator whose `decision-memo` carries
> the verdict INSIDE the artifact (no verdict-driven routing; hybrid/
> revise_first do NOT ride `plan-rejected`), and the single `planner` stage
> always finalizes `plan` from the memo + the competing plans + critiques as
> optional inputs, so the human-reject → re-plan machinery is untouched and the
> armed reject rerun set is provably `{planner}`. (b) "the gate presents the
> memo" was dropped — `GateStep` reads `details` from compile-time options
> shared with `SafetyGate`, so threading dynamic memo details would touch 5
> shared-gate-infra files for redundant value; the human approves the
> *finalized* plan and the memo stays an inspectable composer artifact
> (plan-gate byte-identical). (c) "lens planner stages over the existing
> planner template" became a dedicated composer-private **`plan_drafter`**
> template — the researcher's role text and `emit_signals` doctrine slice both
> instruct emitting `plan-ready` when a plan is drafted, and emitted signals
> are strictly checked against the stage's `publishes`, so a real LLM following
> the stale instruction on a lens stage would route-fail the wave; the
> `plan-drafted:<lens>` advisory signals were dropped entirely (all seven new
> stages publish only `scope-shift` — sequencing is artifact-driven via
> `plan:<lens>` → `critique:<lens>` → `decision-memo`). Arming is the triage
> `multi_plan` judgment ∧ `significant-build`, enforced in
> `FrontDoor.armed?/1`; armed runs seed `multi-plan` INSTEAD OF `plan-needed`
> (no config kill-switch). PR-4 shipped as designed: the `plan-arbiter` stage
> declares `model: :capable, effort: :high` — the tiering seam's first
> declarer, making the PR-1 note's "no catalog stage declares a tier yet"
> historical as of 2026-07-03.

> **PR-1 + PR-2 DONE 2026-07-02**, with two corrections to
> this entry's own claims: (a) PR-1's "`WaveBuilder` reads the fields **at spawn
> time**" described a seam that does not exist — worker model is compile-time
> (`use JidoClaw.Agent.Defaults, model:` wins at server init) and `ask/3` drops
> a `:model` opt; the only per-turn seam jido_ai provides is a
> `request_transformer` returning `%{model:, llm_opts:}` overrides. PR-1
> therefore lands as: `WaveBuilder` carries the `%Stage{}` tier into the stage
> step's options (conditionally-put, byte-identical when absent) → `AgentStep` →
> `AgentRunner.run/6` puts it in `tool_context` under
> `RequestTransformer.stage_tier_key()` and pre-sets the app's **composed**
> transformer (`JidoClaw.Reasoning.Compactor.RequestTransformer`, now
> compaction + tiering; same module ⇒ no Compactor collision), which emits
> `model:` / `llm_opts: [reasoning_effort: e]` per turn. (b) PR-2 threads at
> `route_composer.ex` (`compose_extra_context/2`) via the new
> `JidoClaw.RouteComposer.PremisesContext` renderer — not
> `wave_builder.ex`/`agent_runner.ex`; premises ride the wave's
> `:extra_context`, gate waves intentionally excluded. The telemetry rider
> landed too, in `agent_step.ex` (not `wave_builder.ex`) — the assembled prompt
> only exists there ([:jido_claw, :composer, :stage_prompt], `bytes` + stage/
> template metadata). Behavior today is unchanged (no catalog stage declares a
> tier; default premises `%{}` render to `""`); once a stage declares `effort`,
> `reasoning_effort` reaches the provider even while `:fast`/`:capable` point at
> the same model. *(2026-07-03: "no catalog stage declares a tier" is now
> historical — PR-4's `plan-arbiter` stage declares one.)*

The [alp-river rollup](../../exploration/alp-river/UNADOPTED-IDEAS.md) names
this "the next substantive composer increment," to adopt "when a composer
increment is next wanted" — and explicitly says to pull #1 (tiering seam) and
#3 (premises) in with it. All substrate exists (AR-3 lens instantiation,
emission ⊆ `publishes` coherence, welded wave commits, stage-first personas);
the port is structurally safer than the source because critique-only challengers
simply never declare `plan-approved` in `publishes`, and the human plan-gate
stays the sole emitter. Full sketch:
[AR-9 in FEATURES-WORTH-BORROWING-V2.md](../../exploration/alp-river/FEATURES-WORTH-BORROWING-V2.md).

**This is the item that must be broken down. Suggested 4 PRs (PR-1/PR-2
landed 2026-07-02, PR-3/PR-4 2026-07-03 — see the progress notes above):**

1. **PR-1 — tiering seam (S) — DONE 2026-07-02:** landed, though not as the
   sketched spawn-time read (no such seam exists — worker model is
   compile-time and `ask/3` drops a `:model` opt): `WaveBuilder` carries the
   `%Stage{}` `model`/`effort` tier into the stage step's options, applied
   per turn via the composed `Compactor.RequestTransformer`; absent fields
   stay byte-identical. (The present-nil `Map.get` trap note held — tier opts
   are conditionally-put, tested on the real builder output.)
2. **PR-2 — premises threading (S) — DONE 2026-07-02:** landed in
   `route_composer.ex` (`compose_extra_context/2`) via the new
   `JidoClaw.RouteComposer.PremisesContext` renderer — not
   `wave_builder.ex`/`agent_runner.ex`. Premises ride the wave's
   `:extra_context` under a dedicated `### Premises` block (gate waves
   excluded), so `scope-shift` self-reports cite an explicit list instead of
   reporting blind.
3. **PR-3 — the plan wave itself (M) — DONE 2026-07-03**, with deviations
   (a)–(c) recorded in the progress note above: arming = triage `multi_plan`
   judgment ∧ `significant-build` (front-door code, seeds `multi-plan` instead
   of `plan-needed`); three lens planner stages over a dedicated
   `plan_drafter` template (smallest-shippable / risk-first / reuse-first —
   NOT the researcher, whose prompt surface names `plan-ready`; no
   `plan-drafted:<lens>` signals exist); critique-only `plan_challenger`
   stages producing `critique:<lens>`; a `plan_arbiter` worker with the Zoi
   decision-memo schema (**string** verdict enum `adopt|hybrid|revise_first`,
   per the Envelope round-trip rule) plus the arbiter persona (the 10th) and
   the tie-break doctrine slice; the planner finalizes on every verdict and
   the plan-gate stays byte-identical.
4. **PR-4 — DONE 2026-07-03:** the `plan-arbiter` stage declares
   `model: :capable, effort: :high` via PR-1's seam (the seam's designed first
   consumer); lens planners stay standard.

Opt-in arming is load-bearing: the single-plan default path must be
behavior-unchanged (shipped: the unarmed compose and front-door seeding are
pinned byte-identical). The cheap per-stage prompt-size telemetry rider landed
with PR-1/PR-2, in `agent_step.ex` (`[:jido_claw, :composer, :stage_prompt]`)
— the assembled prompt only exists there, not in `wave_builder.ex` — so AR-11
(artifact handles) stays honestly evidence-gated on real numbers.

## 4. `code-doctrine` slice — S, riding item 3 — ✅ DONE 2026-07-03 (slice half)

> **Done 2026-07-03**, riding item 3's doctrine authoring pass as planned. The
> `code_doctrine` slice (`## Code craft` — match what's there, no drive-by
> refactors, handle the error paths, no dead weight, leave it verifiable)
> targets the three templates that WRITE application code — `coder`
> (implementer + test-author both ride it), `fixer`, `refactorer` — not
> literally "every producer": sketch builders are excluded (throwaway
> tracer-bullets — craft fights their speed purpose), `system_executor`
> (machine/config changes, not application code), and docs_writer/researcher/
> plan_drafter/plan_challenger/plan_arbiter (write no code). The registry now
> counts 11 slices (this entry's "the existing 8 slices" is historical). The
> READ_MAP half stays deferred — still speculative.

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
