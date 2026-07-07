# Exploration Corpus — Index & Conventions

This directory is where jido_radclaw studies other systems (and occasionally its own
future shape) and decides what — if anything — to take. One subject per directory. Every
doc opens with the same standing disclaimer for a reason: **exploration notes — not a
plan, not a commitment.** The goal is to make this project better, not to lift things for
the sake of lifting; "nothing worth borrowing" is a valid, useful outcome and several
docs below conclude close to it. What keeps the corpus honest is that entries are
*verifiable claims with lifecycles* — file:line evidence on both sides, dated
verification, statuses that get reconciled when work ships — not impressions.

Conventions live here so a new doc doesn't have to reverse-engineer them from exemplars.
For the end-to-end authoring workflow (research fan-out, collision checks, synthesis),
use the `explore-repo` skill; for periodically re-verifying existing docs against moved
source, use the `doc-reconcile` skill.

## Index

Each doc's own header is the authority for source paths, commits, and dates; headlines
below are abridged from each doc's Determination.

| Subject | Docs | What it is / headline verdict |
| --- | --- | --- |
| [ades](ades/) | landscape scan + all nine inventories (traycer, emdash, termic, CCC, muxara, Xantham; 2026-07-06 late additions t3code, herdr, cmux) + the cmux subscription-lane plan | Agent-cockpit/control-plane landscape feeding argus: three parallel-worktree desktop comparables (traycer, emdash, termic), two read-mostly attention dashboards (claude-command-center, muxara), one prompt blueprint (Xantham). Traycer deep-dive (TR-*) done 2026-07-03: closest *contract-layer* comparable (host closed-source; epic isn't a DAG) — headline borrows are the versioned-RPC skew layer + released-surface golden tests for argus §6.3 and worktree schema/affinity cribs for §3; edit-and-resume slot verified empty (argus §5 stays novel), plus one INDEPENDENT correction to the §5 `expectedSeq` sketch. Emdash deep-dive (EM-*) done same day: the *practice* half of the worktree reference (preservePatterns, idempotent provisioning — composes with traycer's schemas), shipped answers to two argus open questions (two-trigger notification taxonomy §6.2, attention fold + seen-flag), "speak ACP" costed at four methods + two callback families, three scan corrections (Plan Mode is deleted code; ACP is a 2-provider opt-in; emdash uses hooks, not scraping), edit-and-resume verified empty here too, one do-today item (EM2-3: gate `git worktree` mutations). Termic deep-dive (TM-*) same day, **AGPL patterns-only**: do-today TM1-1 — emit the work-done protocol from our own CLI (the agent CLIs already broadcast turn state over OSC when the host claims capability; termic listens, we can speak); cage trust rules for Forge + the crabbox CB1-1 fix shape (TM1-2: rc-delta withholding, config-outside-the-cage, per-agent cred dirs; TM2-3 monitor mode); Spotlight as the preview-worktree spec (TM1-3, gated on EM2-3); edit-and-resume verified absent — argus §5 novelty now checked across all three desktop comparables. CCC deep-dive (CC-*) same day: the attention layer is the haul — the prose soft-block rubric + `ended_blocked` transplant (CC1-1) and an attention-feed read-model with a do-today slice (CC1-2: LoopGuard halts, cron failures, and Forge `:needs_input` reach no operator surface today); the scan's mtime-409 precedent demoted to half-real (server contract convergent, client recovery never built — acceptance criteria for argus §5.4, CC1-3); trust posture = the corpus's sharpest negative reference for §4.4 (CSRF ≠ auth, Origin-less bypass, ungated GET); sleeper CC2-2 (managed-block co-ownership fixes the `system_prompt.md` upgrade chore); §5 edit-and-resume now verified empty across the entire six-repo set. Muxara deep-dive (MX-*) same day completes the dig set: the taxonomy lands as the **single-agent status contract** (MX1-1 — the per-agent enum EM2-1's fold and CC1-2's kinds compose over: sub-typed needs-input, plan-mode as modifier-not-state, honest `unknown`, asymmetric damping); its shipping attention-sort supplies the counterexample that seals badges-over-reordering (the selection ring binds to grid position and drifts across reorders — selection binds to identity, never position); worktree datapoints (agent-owned `claude -w` creation, dirty-check-blocked teardown) join the step-1 reading stack. Xantham deep-dive (XA-*) same day closes the set, the parked no-dig reversed when its named trigger (argus implementation beginning) fired: "contrast only" holds architecturally, but the Telegram gate lands as argus §4.4's second negative reference (the model inside the approval TCB, the ledger inside the agent's write reach), the notification set is the third §6.2 answer (+ infra alerts never ride the agent path), and the contrast exposed two our-side gate gaps (unconsumed approvals never expire XA2-1; no hard-block tier XA2-2) plus the do-today credential canary (XA2-3 — `Config.check_provider/1` exists, nothing schedules it); edit-and-resume verified absent, closing the §5 sweep across all six subjects. Late-addition **t3code** dug 2026-07-06 (TC-*), the corpus's first whole-product architectural peer: the scan-flagged push stack turned out to be pre-release Effect RPC plumbing, and the hauls sit above and below it — the durable `afterSequence` catch-up contract + client sync loop as argus slice 1's working reference (TC1-1), the corpus's first *positive* auth reference (scoped credentials, WS tickets, shipped QR pairing — TC1-2), five drivers over four vendor protocols with native codex `thread/resume` as the slice-6/executor-PR-2 spec (TC1-3), paired tree+conversation rewind (TC2-1); approvals die on restart (moat evidence); edit-and-resume verified absent at subject 27; six scan claims corrected. Late-addition **herdr** dug 2026-07-06 (HD-*, **AGPL patterns-only**): the terminal-native multiplexer's state engine lands as argus slice 1's rubric — authority-tiered multi-source arbitration + stale-reporter fences (HD1-1), damp-only-the-clear numbers + re-verify-at-delivery (HD1-2), seen-fold `done` + the identity-bound sorter existence proof (HD1-3) — with the corpus family's only server-side PTY broker banked for slice 8 (HD2-1) and the field's widest CLI resume argv table (14 vendors) riding the queued MC1-1 build (HD2-2); headline lesson: the field's best scraper retreated from hook-borne state to session-refs-only for its seven biggest CLIs (events-over-proxies validated); prose soft-blocks undetectable (CC1-1 stays unique); subject 25 empty; four scan claims corrected. Late-addition **cmux** dug 2026-07-06 (CM-*, **GPL patterns-only**, targeted): claude-teams driving resolves as a **tmux impersonation** on nine unguarded vendor assumptions (CM1-1 — slice 6's cost sheet for vendor-internal vs structured-surface driving, with the restore-argv sanitizer riding MC1-1), the scan's "thin" iOS companion corrects to ~75k LOC + four cloud services + APNs (CM2-1 — the §2.6 PWA choice upgraded to evidence-based; two FLOW §12 cross-device delivery rules ride free, CM1-4), the state engine is herdr's opposite pole (hook authority + mechanical fences, scrapers deleted — CM1-2), the typed feed classifier + decision-only soft-wait cards land as slice 6's ask-rule reference (CM1-3), and sweep subject 26 closes empty — finishing the §5 sweep across all 27 subjects in both corpora |
| [alp-river](alp-river/) | inventory, V2, unadopted rollup, AR-* program docs | Methodology layer above our engine; source of the AR-* program family (composer, sketch/system paths, multi-plan arbiter) |
| [amber](amber/) | inventory | Own code: nothing to adopt; the stack it demos: one high-value borrow (AM-1 code-mode pair — adopted 2026-07-03 as `lua_query`/`lua_docs`), one watch-with-trigger |
| [argus](argus/) | OVERVIEW, FLOW, SYNTHESIS, DECISIONS | Greenfield codename: tailnet-wide multi-agent control plane — architecture decisions + current-state audit (OVERVIEW), the product-layer draft (FLOW, newest where they disagree), the ades+pms corpus roll-up by argus concern (SYNTHESIS), and the one-page decisions-of-record snapshot for build kickoff (DECISIONS, 2026-07-07) |
| [camus](camus/) | inventory | Claude Code plan/loop/review product; engine no (ours supersets it), judgment layer nearly wholesale (deterministic verify, honest statuses, git evidence) |
| [cc-dynamic-workflows](cc-dynamic-workflows/) | inventory | Claude Code's dynamic-workflows feature itself (blog + firsthand harness operation — the corpus's first non-repo subject; camus is a product built *on* it). Runtime/durability SKIP: their script double-duties as control flow + durability unit (deterministic-replay resume), and our Reactor + envelope split supersedes it — camus's engine verdict extends from its use of the feature to the feature. The haul is the three-layer dynamic-flows program: DW-1 Lua `reduce:`/`when:` computation glue between steps (builds on AM-1; standalone value for committed skills today — the operator-flagged headline), DW-2 inline skill definitions through the compiler that was already built for LLM-authored YAML (OQs decided 2026-07-07: gate-every-run at launch + gated-struct checkpoint/resume pulled into the slice; `run_pipeline` inline-stages precedent), DW-3 `fan_out:` over runtime lists (Reactor 1.0.2 already ships `map`/step-emission — expose, don't build); plus DW-4 per-run token budget pool (OH2-1's sibling; all our budgets are count-denominated today) and do-now DW-5 quarantine-as-precommit-invariant (researcher/sketch/system templates already practice reader/actor separation; nothing enforces it). Adversarial-verify / loop-until-done / laziness countermeasures / model routing all Already Covered by stronger mechanisms (Verdict, ReviewIndependence, Verify authority, IterativeStep caps, honest terminals, AR-9 tiering) |
| [empirica](empirica/) | inventory | Deliberately short list: negative knowledge with decision-point re-surfacing + confidence-calibration ledger |
| [gepa](gepa/) | inventory | Prompt-evolution algorithm; "best borrow-per-line so far" — we own the substrate, lack the four load-bearing pieces |
| [gust](gust/) | inventory, unadopted rollup | Full workflow platform ("Airflow competitor, not a Reactor competitor"); one valuable pattern, MCP catalog resources shipped from it |
| [hermes](hermes/) | inventory | Nous Research Python self-improving agent platform; the longest-living inventory (46 items, three review passes) |
| [jidoka](jidoka/) | inventory, V2 inventory, unadopted rollup, plan | Elixir agent runtime by jido's creator; V2 = functional-core/effect-journal rewrite; origin of the tool-approval gate |
| [optimal-engine](optimal-engine/) | inventory | Epistemics engine (bitemporal facts, provenance); smallest borrow list yet — its headline territory is where we're strongest |
| [osa](osa/) | inventory | Elixir "Signal Theory" agent app; strongest per-entry list since hermes, first subject where "borrow" sometimes means lifting Elixir directly |
| [osa-claude-code](osa-claude-code/) | inventory | Non-running Elixir transliteration of Claude Code; SKIP as a codebase, reference-grade for Claude Code's contract shapes |
| [ouroboros](ouroboros/) | inventory | Python loop-owner agent; borrows concentrated at the composer's two weak ends (front-door triage, convergence) |
| [pms](pms/) | landscape scan + dig briefs + multica, symphony-lineage, Chorus, orca, bosun, pad, myrlin-workbook & OpenHelm inventories + MC/SY/CH/OR/PD/OH first-wave queues + 2026-07-04 connective pass | Agent-era project-management landscape feeding argus (the ades sibling corpus: boards/trackers/pipelines agents attach to — multica, Chorus, symphony+OpenSymphony, orca, bosun, myrlin, pad, OpenHelm). Multica priority dig (MC-*) done 2026-07-04: the strongest whole-product comparable — pinned placement / visible-skip automation / task-scoped credentials independently validate four argus FLOW decisions; headline borrows are the CLI session-resume stack (MC1-1 — our Forge runners re-send accumulated prompts instead of native `--resume`, a live gap), task-schema field reference + status-kind evidence (MC1-2), stage-barriers→parent-agent dispatch with the dead `issue_dependency` table as the negative half (MC1-3), and the 21-reason run-failure taxonomy with retryable/resume-unsafe subsets (MC1-4); §5 edit-and-resume verified empty at all four layers (16th subject) and the field's most agent-native tracker still has no gates, no push, and a ~two-level severity model — argus's differentiators survive their strongest test. Symphony+OpenSymphony joint read (SY-*) done 2026-07-04: the philosophical inverse of argus (unattended, gateless, daemon never writes the board) carrying the corpus's most liftable code — same language, Apache-2.0; headline borrows are the Codex app-server client (SY1-1, supersedes hermes T2-13, composes with MC1-1), the reconcile-before-dispatch/backoff/stall hygiene bundle (SY1-2, joins MC2-5), the DB-less validated-config contract for FLOW §9 (SY1-3), and multi-account rotation + the shipped XA2-3 rate-limit probe (SY1-4); scan's "cached bare repo" corrected (non-bare), §5 verified empty at subjects 17–18. Chorus dig (CH-*) done 2026-07-04, **AGPL patterns-only**: the §5-design reference — the corpus's first shipped **plan-layer promote-the-edit** (human draft edits materialize verbatim, correcting scan observation 1(b)'s every-edit-re-prompts claim; execution layer verified empty at subject 19, so argus's novelty narrows honestly to execution-layer head-promotion), with Chorus's two missing fences (approve idempotency, revision history) as §5.4 acceptance criteria (CH1-1); the reverse-control scan claim corrected to **boundary delivery, never mid-turn** — and the seams pass found our mailbox already queues mid-turn messages while the dep's true `steer/inject` sits unwired, so the gap is affordances not engine (CH1-2, do-now: the Forge needs-input reply loop closing CC1-2's dead-end); pinned-wake hard/soft degradation ladder + read-only-not-rerouted sessions validate FLOW §2 nothing-migrates and the identity/liveness instance split is OVERVIEW §3.3's node-row schema reference (CH1-3/-4); differentiators survive a third tracker (yolo default, no gates, no run-state triggers, no push, no durable catch-up). Orca dig (OR-*) done 2026-07-04, closing the pms first wave: the corpus's best reference-schema donor per line read — the review-verdict payload reference (OR1-1: `approve|revise|reject` + `blocking|advisory` + anchors with the schema-not-just-prompt and validate-at-boundary lessons + the anchor-fidelity taxonomy, feeding argus §5.3 / next-ten #6), catch-up staleness + resolution-as-proposal validating FLOW §6/§10 (OR1-2), queue-then-release with canceled-keeps-blocked shipped (OR1-3), the worktree toolchain-init table + init-status split (OR1-4), and the `GIT_IS_IMPLEMENTATION.md` vocabulary rubric (OR2-1); two adoptable-now items queued (OR-FIRST-WAVE: our step-projection rebuild IOU, the non-interactive env floor); §5 execution layer verified empty at subject 20 while scan observation 1(b) corrects a second time — orca's Accept **promotes** edits verbatim, so plan-layer promote-the-edit exists twice in the field; six scan claims corrected (server-minted command_id, dead correlation/causation columns, prompt-only anchors dead-rendered at HEAD, implementer→auditor default chain, armed auto-queue, leaky vocabulary enforcement). Bosun dig (BO-*) done 2026-07-04, closing the corpus's named reads: the feature-superset comparable survives as the most instructive wreck survey — the two-way sync engine was **deleted in production** (FLOW §7's rejection now counterexample-backed), gate poll-loops re-open approved gates on restart (our AgentCase+GateResume strictly stronger), the risky-action gate is default-off with timeout-means-proceed, and approvals are decidable only in the Mini App; what verification left standing is the haul — the corpus's only shipped interrupted-run auto-resume (BO1-1: qualification fences + unresumable-reason taxonomy, the reference for our reclaim machinery's documented-missing resume path), a 13-type agent-anomaly taxonomy + off-process sentinel watchdog (BO1-2), the field's richest phone delivery shapes (BO1-3: immediate-vs-digest split, live digest, pinned status board), the deleted-sync-engine design checklist + independent 7-state task-machine convergence (BO1-4), and the field's one shipped mid-turn steer (BO2-4: Claude agent-SDK streaming input — CH1-2's "never mid-turn" gains its honest asterisk); §5 verified empty at subject 21; nine scan claims corrected. Pad dig (PD-*) done 2026-07-04, the complement-not-competitor: the field's best agent-surface contract-discipline donor — headline borrows are the served-surface stability contract fused with traycer TR1-2a as a do-today PR (PD1-1; the seams pass caught our own MCP server advertising a hardcoded `0.2.0` on an `0.6.4` app — pad's enforcement-rot lesson live in our tree), the closed-at-the-boundary error contract with typed self-correction hints (PD1-2, camus C1-3's tool-surface sibling), the FLOW §7 task-schema reference (PD1-3: workspace-global computed refs, binary-terminal counterexample pro-seven-kinds, advisory-locked open-children guard, inert-`blocks` as the corpus's third dead-dependency datapoint), and shipped validation for FLOW §13's import-copy workflow-YAML seam incl. the removed-auto-upgrade negative result (PD1-4); §5 verified in its strongest form (subject 22 — pad contains no LLM code at all); five scan claims corrected (attribution split not unified, Redis bridge SSE-only/collab single-node, PWA installable-only, playbook "lifecycle" is a mutable status field, `blocks` inert). Myrlin-workbook dig (MY-*) done 2026-07-04, **AGPL patterns-only**, closing the corpus's planned reads: the ades-bridge cockpit whose PM layer mostly dissolves on contact — dependencies inert (fourth dead-dependency subject), concurrency caps client-side-only, auto-advance-on-merge manual-refresh-only, QR pairing shipped-broken at HEAD (a missed call site in a helper refactor — PD1-1's rot lesson at the auth layer), and of five declared push events exactly **two fire** (emdash's EM1-3 set re-derived; the `fileConflicts` push is dead code in the product that named the trigger — FLOW §12's citation corrected in place); what survives is the haul — the **credential lineage guard** (MY1-1: cross-machine OAuth refresh-token theft found and fixed, rotation write-back, three-state token health — the file-mechanics half of SY1-4 for FLOW §5's multi-node credential sync), three storm-tested delivery rules the EM/TM/XA stack lacked (MY1-3: replay suppression, focus-ack-consumes, min-signal re-arm), the conflict-detector shapes (MY1-2 — ours becomes a query over durable tool-call rows), the enrollment ladder for OVERVIEW §4.4 (MY1-4, plus our own zero-key-minting gap: do-now `mix jidoclaw.api_key`), and the severed-consumer lesson (MY2-1: the field's third plan-layer promote-the-edit promotes into a record nothing consumes — §5.4 must prove head-promotion end-to-end); §5 verified empty at subject 23. OpenHelm dig (OH-*) done 2026-07-04, **BUSL patterns-only**, the corpus's recorded no-dig reversed on operator request as argus implementation begins — and the reversal paid: **both** recorded scan citations were wrong at HEAD (the per-tool risk-1–5 gate is dead code — the live shape is an autonomy dial × action-class taxonomy × apply-with-undo, OH1-2, whose dead numeric-scorer corpse answers classes-vs-scores in advance; the run-snapshot-for-resume is write-only — zero read callers, resume re-resolves live, surviving as OH2-4 TRACK since our resume has the same hole); headline haul is the cron-health breaker family with an adoptable-now our-side slice (OH1-1 — the seams pass found our cron failures invisible today: in-memory counter reset by reconcile, disabled rows vanishing from listings, status-blind telemetry, a dormant `:schedule` Trace channel), the charge-before-call automation budget ledger (OH2-1, FLOW §8's doom-loop-budget shape + the v1 users-disabled-it-for-burning-tokens anti-pattern), attention storm mechanics (OH2-2: infra-incident collapse, guaranteed escalation, additive email-on-attention), and third-source convergence on the queued verification program recorded as riders on next-ten #5/#6/#9/#10 (OH1-3: required outcome contracts, fresh-context judge with read-only DB tools, fabrication as claimed-vs-observed); §5 verified empty at **subject 24**, closing the pms corpus with argus's differentiators (durable mid-run pause, leases, event-sourced runs, head-promotion) intact against all nine subjects. A same-day intra-corpus **connective pass** (2026-07-04) then stitched what the sequential digs couldn't see of each other — pms README observations 9–13 (the gate family's five defect axes as §5.4 acceptance criteria; the delivery-mechanics stack BO1-3 + OH2-2 + MY1-3 + CH2-3 under CC1-2's read-model; the teardown spectrum orca→myrlin→bosun→multica→SY2-4; the health shelf with MC1-4 as the shared taxonomy seam every classifier feeds; the wiring-mortality census with its two laws) — plus a combined first wave rolling up the six do-now queues + two inline items, and dated connective notes back into the inventories (incl. bosun/OpenHelm riders added to MC-FIRST-WAVE) |
| [sandboxes](sandboxes/) | landscape scan, nono + ysa + coderunner + ghostty_ex + pi-sbx-llamacpp + agentos + openshell + crabbox inventories | Multi-repo sandbox landscape; nono deep-dive is the corpus's first **ADOPT-AS-TOOL** verdict; ysa deep-dive is mostly SKIP (wrong tier, superseded by nono) with two narrow borrows; coderunner is a **trial-scoped adopt-as-tool** (config-only MCP consumption) whose durable ideas are the stateful-executor and agent-skills patterns; ghostty_ex is the corpus's first **ADOPT-AS-DEP** (scoped: render-only dashboard terminal is the gating consumer; emulation kept out of the redaction root); pi-sbx-llamacpp is pure **BORROW-REFERENCE** (a zero-code guide — the mechanics + spike spec for the sbx backend's allowedDomains and host-inference features, plus dig-surfaced deniedDomains floors / serviceAuth / a decorative-base_url fix); agentos (dug together with its pinned `secure-exec` engine sibling) is **SKIP-as-dep, richest concept donor** — its marketed claims shrink on contact with its own code/baselines, and the live borrows are the Forge transcript pair (persist-then-resume from the runner events we already parse) plus CI-guard discipline (spawn-site needle-scan, bounded-by-default limits audit); openshell (NVIDIA) is **TRACK-as-platform with three Tier-1 pattern borrows** — placeholder-credential brokering reference (its seams pass surfaced our claude_code login-file exposure), the deny→propose→human-gate policy loop, and the OCSF audit rubric for our `audit_events`; crabbox is **SKIP-as-dep, borrow the security discipline** — a team-scale remote-exec control plane on the scale-out (not isolation) axis, but the dig found two present-day defects its patterns fix (CB1-1 credential-destination provenance — an LLM editing `.jido/config.yaml` can redirect a host-env SSH password; CB1-2 ownership proof before the `forge-*` sandbox reaper) plus CB2-1's capsule-replay taxonomy folding into camus C1-3 |
| [squidie](squidie/) | inventory, plan docs | Three-workflow-engine comparison that produced the Reactor adoption (event log, gates, replay) |

## Doc types

- **`FEATURES-WORTH-BORROWING.md`** — the default deliverable for an external subject: a
  tiered inventory of what's worth taking, with per-entry evidence and adoption sketches.
  Anatomy below.
- **`FEATURES-WORTH-BORROWING-V2.md`** — a *new* inventory when a subject ships a major
  rewrite. Covers only what V2 added or reshaped enough to warrant active follow-up. The
  V1 doc's statuses stand and are never re-litigated; V2 reshapes of already-adopted
  borrows live in the V1 doc as dated notes (jidoka is the exemplar).
- **`UNADOPTED-IDEAS.md`** — a companion rollup of the **live remainder** only: ideas
  deferred or put on watch, not rejected. Per item: where it stands in code today,
  "adopt now?", and the named trigger that would change the verdict. Ordered by trigger
  proximity. Settled items (shipped, rejected, chosen divergences) are excluded — the
  inventory records those. Create one when an inventory's open tail is big enough that
  "what's still live?" needs its own answer (gust, jidoka, alp-river).
- **`OVERVIEW.md`** — for greenfield/codename subjects (a design exploration, not a
  repo): vision, "where we landed" decisions, data-model/API implications, open
  questions, with the file:line audit of current state as an appendix (argus).
- **`PORT-<entry-id>.md`** — a pre-implementation semantics map, required when an
  adoption's correctness depends on matching the source's semantics. Lives in the
  subject dir; anatomy below.
- **Plan docs** — when an entry graduates to real work: named after the entry/program ID,
  living either in the subject dir (`alp-river/AR-2-COMPOSER-PLAN.md`,
  `squidie/T1-1-WORKFLOW-EVENT-LOG-PLAN.md`) or under `docs/plans/<program>/` when the
  program spans subjects (`docs/plans/unadopted-next-five/`).

## Anatomy of a FEATURES-WORTH-BORROWING doc

**Header block** (first paragraph, before any heading): the standing disclaimer sentence
verbatim; inventory date; source path and subject identity/self-description; **both
commits pinned** (subject @ sha, jido_radclaw @ sha) — the newer docs' phrasing is the
model: *"Cites are firsthand reads of both trees, accurate to within a few lines"*; the
subject's shape (language, LOC, structure) and maturity signals (commit count, releases,
contributor tail, activity, license); and an explicit note when something was **read but
not executed** (nono: "runtime claims are per-docs until the install spike"). Non-repo
subjects (a feature or publication — cc-dynamic-workflows is the precedent) pin **URL +
date + harness version** in place of a subject sha, and a re-review re-operates the
surface instead of re-reading a tree. Follow with
a **companion docs** paragraph cross-linking the sibling explorations this one interacts
with, and — where relevant — the threat-model weighting note (personal, tailnet-only:
LLM-misbehavior containment and leakage hygiene over external-attacker hardening).

**Determination (TL;DR)** — the headline verdict first, then a table mapping each part of
the subject → "as a dependency?" → "what to take." Follow with the argued section it
implies: "Why not adopt as a dependency" (the common case) or its inverse when adoption
is on the table (nono).

**How to read this document** — the recommendation vocabulary in use, tier definitions
*scoped to this codebase*, per-entry fields, and the ID scheme.

**Tiered entries** (Tier 1 / 2 / 3), each carrying:
- **Recommendation** (vocabulary below) — plus **Status** lines from the first re-review
  onward (never in the initial inventory).
- **Where in <subject>** — file:line refs, "start here, not gospel" (accurate to within a
  few lines beats no ref).
- **What** — the mechanism/contract in their terms.
- **Gap in jido_radclaw** — verified against our source, with file:line and the
  verification date. This is the field that keeps the doc honest.
- **Why it matters** — for *this* project's threat model and roadmap, not in general.
- **Adoption sketch** — concrete enough to start from (modules, seams, config, staging),
  loose enough not to be a plan.

**Skip / Already Covered** — one line each; an ALREADY-COVERED must cite the local
equivalent it's covered *by*. **Open questions** (OQ-n) — decisions deferred, each framed
so a future session can answer it. **Cross-references and dependencies** — an ASCII
dependency graph plus a suggested first wave, with collision notes against the current
work queues. **Bottom line** — the two-to-four ideas that must not slip.

## Anatomy of a PORT map

When an entry graduates to implementation **and its correctness depends on matching the
source's semantics** — the BORROW-PATTERN/BORROW-REFERENCE class where a real mechanism
is being translated (the LoopGuard port is the motivating precedent) — write
`PORT-<entry-id>.md` in the subject dir and get sign-off **before any code**. Rubric
lifts, garnishes, and BUILD-ON items don't need one. The point is to catch silent
divergence at the design layer, where a correction costs a sentence: the map must be
complete enough that a semantic error is visible without reading the eventual
implementation.

- **Header** — the inventory entry it implements (ID + link), both shas pinned, date.
- **What the source actually does** — plain-English mechanism summary, subsystem by
  subsystem, in *their* terms.
- **Side-by-side shapes** — the load-bearing pairs: source excerpt ↔ planned
  jido_radclaw shape (module/seam level), each divergence annotated with why.
- **Behaviors table** — every observable behavior sorted **preserved exactly /
  deliberately changed / dropped**, each with its reason. The "deliberately changed"
  and "dropped" columns are what keep a reviewer from reading divergence as oversight.
- **Edge cases** — a table anchored to the source's own test names where they exist:
  their test ↔ our planned equivalent ↔ expected behavior on both sides.
- **Sign-off gate** — the open questions for the operator, presented as options;
  implementation starts only after semantics are confirmed. After shipping, the
  subsystem's `docs/system/` page cites the map as port provenance, and the inventory
  entry reconciles per the lifecycle below.

## Vocabulary

**Recommendation verdicts** (initial inventory):

- **BORROW-PATTERN** — translate the contract/invariant into our idioms (OTP, Ash, Jido,
  the composer). The workhorse verdict.
- **BORROW-REFERENCE** — read their implementation as the spec for something we build.
- **BORROW-RUBRIC** — lift evaluative criteria/prompt text, not machinery.
- **BUILD-ON** — ours to design; the subject supplies the enabling guarantee or precedent.
- **ADOPT-AS-TOOL** — shell out to the subject's binary/CLI as-is (earned first by nono).
- **ADOPT-AS-DEP** — take the subject as a library dependency (first used by ghostty_ex).
- **FOLD-IN** — absorb into an existing planned item rather than standing alone.
- **INDEPENDENT** — worth doing regardless of the subject; the doc is just where it surfaced.
- **TRACK** — parked with a **named trigger** (never a bare "later").
- **ALREADY-COVERED** — we have an equal-or-better shape; cite it; take at most a garnish.
- **SKIP** — not applicable, superseded by a local decision, or below the quality bar.

New axes must be *earned and explained*, not silently invented — camus explicitly noted
its missing ADOPT-AS-DEP axis; nono argued ADOPT-AS-TOOL into existence. Deviating from
the standard skeleton is likewise legitimate when the subject demands it, stated up
front: osa-claude-code led with an honesty-calibration section because the subject didn't
run; nono inverted "why not adopt" into "why adopt-as-tool is on the table."

**Status values** (added at first re-review, always dated): **ADOPTED** (feature or clear
functional equivalent lives here — strict bar: any deferral or placeholder keeps it
PARTIAL) / **PARTIAL** / **NOT_ADOPTED** / **SUPERSEDED** (gap closed by a different,
usually native, shape) / **N/A** (entry was a skip). Subject-side refresh lines (e.g.
`Hermes (2026-06-04):`) appear only when the subject's code moved materially.

**IDs**: `<prefix><tier>-<seq>` with a stable per-doc prefix (C for camus, N for nono,
G for gust, OS for osa, T for hermes, V2- for jidoka V2, AR- for alp-river programs);
`S-n` for skip entries, `OQ-n` for open questions. IDs are load-bearing — plan docs,
queues, and cross-references cite them — so never renumber.

## Evidence and honesty rules

1. **File:line on both sides.** Every claim about the subject and every Gap claim about
   us carries a ref. Refs are "start here" pointers, tolerant to a few lines of drift.
2. **Pin both trees.** Subject sha and jido_radclaw sha in the header; date every
   verification pass inline (`verified 2026-07-03`).
3. **Say how you know.** Firsthand read vs executed vs per-their-docs are different
   epistemic states; the doc must distinguish them (nono's "not installed or executed"
   note is the model).
4. **Maturity signals are evidence** — commits, releases, contributor tail, doc/code
   drift found while reading. Record drift you find; it calibrates trust either way.
5. **Finding nothing is a finding.** Short lists with verified-empty slots (empirica,
   optimal-engine) are better products than padded tiers.
6. **Trigger discipline.** Parked/TRACK items name the event that revisits them; the
   UNADOPTED rollups and work queues select only trigger-satisfied items.
7. **No laundering.** Statuses never round up (deferral ⇒ PARTIAL); an aggregate that
   contains deferred risk says so — the same honest-terminal-status doctrine we borrowed
   from camus applies to our own docs.

## Lifecycle

1. **Initial inventory** — no Status lines, dated, both shas pinned.
2. **Re-review passes** — add the Status legend, per-entry dated Status lines, and a
   dated **re-review summary at the top** (newest first) recording movement on both
   sides since the prior pass (hermes is the exemplar).
3. **Porting** — when a fidelity-critical entry graduates to implementation, a
   `PORT-<entry-id>.md` semantics map precedes code (anatomy above); sign-off on the
   map is the gate.
4. **Shipping reconciliation** — when an item ships, reconcile the **whole entry** (gap,
   sketch, cross-refs), not just the status line, and update the companion rollup/queue
   entries the same day (the rule the `unadopted-next-five` queue states from its side).
5. **Rollup** — spin up `UNADOPTED-IDEAS.md` when the live tail warrants it.
6. **Re-verification** — run `doc-reconcile` when either tree has moved enough that the
   refs are suspect.

## Creating a new exploration

Invoke the **`explore-repo`** skill with the subject path — it encodes the workflow
(style calibration, parallel subject readers + a local seams mapper, maturity signals,
collision pass against this corpus and the queues, synthesis, index updates). Calibration
exemplars: **camus** for the canonical skeleton, **nono** for earning a new verdict axis
and for the read-vs-executed discipline, **osa-claude-code** for leading with honesty
calibration when the subject is broken.
