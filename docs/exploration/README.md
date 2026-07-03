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
| [alp-river](alp-river/) | inventory, V2, unadopted rollup, AR-* program docs | Methodology layer above our engine; source of the AR-* program family (composer, sketch/system paths, multi-plan arbiter) |
| [amber](amber/) | inventory | Own code: nothing to adopt; the stack it demos: one high-value borrow, one watch-with-trigger |
| [argus](argus/) | OVERVIEW | Greenfield codename: tailnet-wide multi-agent control plane — decisions + open questions, not a subject repo |
| [camus](camus/) | inventory | Claude Code plan/loop/review product; engine no (ours supersets it), judgment layer nearly wholesale (deterministic verify, honest statuses, git evidence) |
| [empirica](empirica/) | inventory | Deliberately short list: negative knowledge with decision-point re-surfacing + confidence-calibration ledger |
| [gepa](gepa/) | inventory | Prompt-evolution algorithm; "best borrow-per-line so far" — we own the substrate, lack the four load-bearing pieces |
| [gust](gust/) | inventory, unadopted rollup | Full workflow platform ("Airflow competitor, not a Reactor competitor"); one valuable pattern, MCP catalog resources shipped from it |
| [hermes](hermes/) | inventory | Nous Research Python self-improving agent platform; the longest-living inventory (46 items, three review passes) |
| [jidoka](jidoka/) | inventory, V2 inventory, unadopted rollup, plan | Elixir agent runtime by jido's creator; V2 = functional-core/effect-journal rewrite; origin of the tool-approval gate |
| [optimal-engine](optimal-engine/) | inventory | Epistemics engine (bitemporal facts, provenance); smallest borrow list yet — its headline territory is where we're strongest |
| [osa](osa/) | inventory | Elixir "Signal Theory" agent app; strongest per-entry list since hermes, first subject where "borrow" sometimes means lifting Elixir directly |
| [osa-claude-code](osa-claude-code/) | inventory | Non-running Elixir transliteration of Claude Code; SKIP as a codebase, reference-grade for Claude Code's contract shapes |
| [ouroboros](ouroboros/) | inventory | Python loop-owner agent; borrows concentrated at the composer's two weak ends (front-door triage, convergence) |
| [sandboxes](sandboxes/) | landscape scan, nono inventory | Multi-repo sandbox landscape; nono deep-dive is the corpus's first **ADOPT-AS-TOOL** verdict |
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
not executed** (nono: "runtime claims are per-docs until the install spike"). Follow with
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

## Vocabulary

**Recommendation verdicts** (initial inventory):

- **BORROW-PATTERN** — translate the contract/invariant into our idioms (OTP, Ash, Jido,
  the composer). The workhorse verdict.
- **BORROW-REFERENCE** — read their implementation as the spec for something we build.
- **BORROW-RUBRIC** — lift evaluative criteria/prompt text, not machinery.
- **BUILD-ON** — ours to design; the subject supplies the enabling guarantee or precedent.
- **ADOPT-AS-TOOL** — shell out to the subject's binary/CLI as-is (earned first by nono).
- **ADOPT-AS-DEP** — take the subject as a library dependency (axis exists; unused so far).
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
3. **Shipping reconciliation** — when an item ships, reconcile the **whole entry** (gap,
   sketch, cross-refs), not just the status line, and update the companion rollup/queue
   entries the same day (the rule the `unadopted-next-five` queue states from its side).
4. **Rollup** — spin up `UNADOPTED-IDEAS.md` when the live tail warrants it.
5. **Re-verification** — run `doc-reconcile` when either tree has moved enough that the
   refs are suspect.

## Creating a new exploration

Invoke the **`explore-repo`** skill with the subject path — it encodes the workflow
(style calibration, parallel subject readers + a local seams mapper, maturity signals,
collision pass against this corpus and the queues, synthesis, index updates). Calibration
exemplars: **camus** for the canonical skeleton, **nono** for earning a new verdict axis
and for the read-vs-executed discipline, **osa-claude-code** for leading with honesty
calibration when the subject is broken.
