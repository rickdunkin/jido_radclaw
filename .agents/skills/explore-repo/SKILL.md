---
name: explore-repo
description: Research a subject repository and produce a house-convention exploration doc (docs/exploration/<subject>/FEATURES-WORTH-BORROWING.md) — parallel reader fan-out over the subject, a seams map of jido_radclaw's own integration points, tiered borrow/adopt verdicts with file:line evidence on both sides, and corpus index updates. Use this whenever the user asks to explore, review, deep-dive, or evaluate an external or sibling repo for ideas worth adopting — "what's worth borrowing from X", "should we adopt X", "review ~/workspace/research/<repo>", "anything in X worth lifting?", "deep-dive <project>" — even if they never say "exploration doc". Also drives re-review passes that refresh an existing inventory's statuses after either side has moved. Do NOT use for: pure fact-checking of existing docs against moved source with no verdict/status changes (that's doc-reconcile), reviewing PRs or working diffs (code-review), or integrating a dependency the user has already decided to adopt.
---

# Explore a Repo → Exploration Doc

Produce an entry in the exploration corpus: a tiered, evidence-backed inventory of what a
subject project has that jido_radclaw should borrow, adopt, or consciously skip. The
standing goal (the operator's phrasing): **make the project better, not lift random
things** — "nothing worth borrowing" is a valid, useful outcome, and a short list with
verified-empty slots beats a padded one.

**The format authority is `docs/exploration/README.md` — read it first, every time.** It
owns the doc types, anatomy, verdict/status vocabulary, evidence and honesty rules, and
lifecycle. This skill deliberately does not duplicate that content: the README evolves
with the corpus, and stale duplication here would fork the conventions. This file owns
the *workflow* — how to get from "here's a repo" to a doc that satisfies the README.

## Phase 0 — Orient (before touching the subject)

1. Read `docs/exploration/README.md` (conventions + index).
2. Decide the doc mode, which changes everything downstream:
   - **Initial inventory** — no subject dir exists. The default; the rest of this file
     assumes it.
   - **Re-review** — a FEATURES doc already exists. Jump to "Re-review mode" below.
   - **V2 inventory** — the subject shipped a major rewrite since its inventory
     (jidoka is the exemplar). New doc, only what the rewrite added; V1 statuses stand.
   - **Umbrella member** — the subject belongs to a themed scan family (e.g.
     `sandboxes/`): nest the doc under the umbrella dir and update the scan README
     rather than only the top index.
3. Skim **one** calibration exemplar with fresh eyes — camus (canonical skeleton), nono
   (adopt-as-tool axis; read-vs-executed discipline), or osa-claude-code (subject that
   doesn't run) — chosen by what the subject seems to be. The README specifies the
   format, but tone and judgment density only calibrate by example.
4. Collision sweep, so the doc lands in context instead of re-opening settled questions:
   current queue state (`docs/plans/unadopted-next-*/README.md`), a grep of
   `docs/exploration/` (and `docs/system/`, for subsystem truth already shipped) for the
   subject's core topics, and the memory index (MEMORY.md)
   for standing decisions (threat model, engine choices, deferred work).

## Phase 1 — Scope the subject

- Size and shape first: languages, LOC, docs tree, top-level layout. This decides the
  fan-out (below), so do it before spawning anything.
- Maturity signals (they're evidence, per the README): commit count, last-commit date,
  contributor tally, release cadence. **Note the git-guard**: `git shortlog` and
  `git tag` are blocked as mutations by name — use
  `git log --format='%an' --no-merges | sort | uniq -c | sort -rn` and read
  `CHANGELOG.md` for releases instead.
- Pin **both** shas now — subject HEAD and jido_radclaw main — they go in the doc
  header verbatim.
- Do **not** build or run the subject unless the user asked. The doc must distinguish
  read-verified claims from executed ones; "per their docs, not executed this review" is
  an honest and normal state (nono's install-spike note is the model).
- Reference-repo hygiene: only whitelisted repos may be refreshed, with exactly
  `git -C <abs-path> pull --ff-only`; otherwise review the clone as-is at its pinned sha.

## Phase 2 — Research fan-out

- Decide the split from Phase 1: for a substantial subject (roughly >50k LOC or a rich
  docs tree), 3–5 parallel **subject readers** split by subsystem or docs area, plus
  **always exactly one seams-mapper** over jido_radclaw scoped to the integration
  surfaces the subject plausibly touches. For a small subject, read it yourself — but
  still consider the seams-mapper; the "Gap in jido_radclaw" fields are the doc's
  hardest evidence and a dedicated pass keeps them honest.
- Spawn all agents **in one message** (they're independent; staggering wastes
  wall-clock). Use read-only Explore agents.
- Build prompts from `references/agent-prompts.md`. The properties that matter — dense
  factual final message, file:line for every claim, verbatim key config/schema blocks,
  honest not-founds, immaturity/platform-gating flags — are what make five reports
  synthesizable into one doc; prompts improvised without them return prose you can't
  cite.
- While readers run, do the work no reader owns: maturity signals, top-level
  doctrine/review docs (CONTRIBUTING, SECURITY, review guides — often the densest
  architecture summaries in the repo), license check. Don't duplicate files a reader
  was assigned.
- **Conflicting reports**: re-check the source directly yourself before writing. Never
  average two agents' claims or pick the more confident one — one of them is wrong, and
  the doc's credibility rides on which.

## Phase 3 — Synthesize

- Verdict first: write the Determination TL;DR and the as-a-dependency table before the
  entries. If the verdict resists one paragraph, the research isn't done.
- Structure per the README's anatomy. Adapt the skeleton when the subject demands it —
  and say so up front, citing the precedent (the README lists them). New verdict axes
  must be earned in the "why" section, not silently coined.
- Every entry's **Gap in jido_radclaw** carries our-side file:line and the verification
  date. Use the seams-mapper's refs; spot-check any that surprise you.
- Tier by impact × fit × adoption ease **for this project**, weighted by the house
  threat model (personal tailnet: LLM-misbehavior containment + leakage hygiene over
  external-attacker hardening).
- Be selective: drop reader material that doesn't change a verdict or sketch. The
  camus/nono band (~350–450 lines) fits most subjects; going long needs the subject's
  justification, not the research volume's.
- Parked items get **named triggers**, never "later". Skip/Already-Covered entries cite
  the local equivalent they're covered by.

## Phase 4 — Wire it into the corpus

- Add/refresh the subject's row in the `docs/exploration/README.md` index table
  (headline abridged from the Determination).
- Umbrella member: update the scan README — check off the next-step item, link the doc,
  one-line verdict; correct any scan claims the deep-dive overturned.
- Add companion-doc cross-links in sibling exploration docs only where a real
  interaction exists (an entry that grafts onto, supersedes, or is gated by something in
  the other doc) — not reciprocal-linking ceremony.

## Phase 5 — Deliver

- **Never commit** (house git policy). End with the files-to-stage list and a suggested
  `docs:`-prefixed commit message.
- The final message leads with the determination, then how you know it (what was read
  vs executed, both shas), then the honest caveats — the same order the doc itself uses.

## Re-review mode (existing doc)

The shorter path when a FEATURES doc exists and the ask is "refresh it":

1. Re-pin both shas; diff each side's movement since the doc's last pass (subject:
   `git log <old-sha>..HEAD --oneline`; ours: the entries' Gap refs).
2. Fan out a verification pass shaped by the doc itself: readers check the subject-side
   claims that moved; a seams pass re-verifies Gap fields and hunts for shipped
   equivalents on our side.
3. Apply the README's re-review conventions: dated **Status** lines per entry (strict
   ADOPTED bar — any deferral stays PARTIAL), subject-side refresh lines only where
   their code materially moved, and a dated re-review summary **at the top, newest
   first** (hermes is the exemplar).
4. Shipped items get the **whole entry** reconciled — gap, sketch, cross-refs — not just
   the status line; update companion rollups (`UNADOPTED-IDEAS.md`) and any queue docs
   the same session.

If the ask is only "are the file:line refs still right?" with no status/verdict work,
hand off to `doc-reconcile` instead.

## Cost and honesty guardrails

- Readers return **reports, not transcripts** — a reader may burn six figures of tokens
  reading; its final message should be a few KB of citable facts.
- Don't let the fan-out's sunk cost inflate the doc: research volume is not evidence of
  borrow-worthiness. If the honest determination is "almost nothing", write that
  (amber and optimal-engine are the precedents).
- The doc records what was **not** verified as loudly as what was — un-executed runtime
  claims, unread subsystems, doc/code drift found while reading (drift calibrates trust
  in both directions).
