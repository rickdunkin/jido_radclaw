# System Docs — Conventions & Index

One page per subsystem: the deep truth that outgrew its AGENTS.md bullet. AGENTS.md
keeps each subsystem's few-sentence load-bearing contract plus a pointer here; the page
holds the rest — mechanics, port provenance, config, telemetry, residuals.
[ARCHITECTURE](../ARCHITECTURE.md) stays broad-shallow, [TRUST-BOUNDARIES](../TRUST-BOUNDARIES.md)
stays the orchestration/gate review rubric, moduledocs stay per-module; this layer is
the per-subsystem middle.

`mix jidoclaw.system_docs.check` (in the `precommit` alias) guards the corpus: the
frontmatter + source-map contract below on every page, intra-corpus link resolution,
the index below set-matched against the directory, and AGENTS.md pointers in both
directions — a page cannot ship without its AGENTS.md citation, and a citation cannot
outlive its page.

## Rules

- **Same-PR rule**: a change touching subsystem X updates its page in the same change,
  bumping `verified:` (and `verified_sha` when present) to the reviewed state.
- **Atomicity**: an AGENTS.md bullet shrinks only in the commit that creates its page —
  machine-enforced in both directions by the pointer check.
- **Surgical updates**: edit the affected section, don't rewrite the page; history is
  git's job (no changelog sections).
- **Reconcile**: periodic freshness passes ride the doc-reconcile workflow, with each
  page's `sources:` list as its reconcile scope; `verified:` freshness is deliberately
  not machine-checked.
- **Owned artifacts**: generation may bootstrap a draft; the committed page is the
  authority, not a build product.

## Frontmatter

Every page opens with a YAML frontmatter block. Required keys are enforced by the
check; extra keys are tolerated (the guard enforces the contract, not a sealed schema):

```yaml
---
type: subsystem            # closed vocab: subsystem | surface | contract
description: One line for indexes and recall.
sources:                   # non-empty; repo-relative existing paths; no /, ~, or ..
  - lib/jido_claw/agent/loop_guard.ex
verified: 2026-07-07       # YYYY-MM-DD (format-checked only; freshness is reconcile's job)
verified_sha: "1c90e385"   # optional; quote it — unquoted digits parse as a YAML integer
---
```

`type: contract` is reserved (valid, currently unused) for a future cross-cutting
contract page; every page, regardless of `type`, must be cited from AGENTS.md — if a
page class ever genuinely doesn't belong there, that is the named trigger for a
frontmatter opt-out, not before.

## Page skeleton

`# Title` → `## What & why` → `## Invariants & contracts` (the sentences AGENTS.md
keeps inline, verbatim or near) → `## Mechanics` (the moved bulk: port provenance +
shas, windows/TTLs, deviation rationales) → `## Config & telemetry` → `## Residuals &
accepted risks` → `## Source map`.

Source-map refs are backticked `path[:line]` text, never markdown links. `:line` is
optional — a path-only entry covers a whole module, directory, or test file — and every
ref is a drift-tolerant "start here" pointer, not a pinned coordinate. The check
requires the section to carry at least one such ref.

## Index

Line-anchored rows, one per page: `- [Title](page-slug.md) — one-line hook`. The check
set-compares these against the directory (names, not counts).

- [Loop Guard](loop-guard.md) — doom-loop detection in the shared tool pipeline
- [Output Shaping](output-shaping.md) — compress the green, never the red; reversible via ref-stored captures
- [Context Compaction](context-compaction.md) — live per-agent compaction + the per-stage tiering seam (AR-9)
- [Tool Approval Gate](tool-approval.md) — per-tool-call human approval, single-use consumes, the shell floor
- [Verdict Normalizer](verdict-normalizer.md) — infra ≠ verdict ≠ inconclusive; schema drift fails closed
- [Verify Authority](verify-authority.md) — engine-run exit-code verdicts, integrity certificates, VERIFY_OATH
- [Terminal Statuses](terminal-statuses.md) — finding identity, stall detection, review_stall park, done_with_findings
- [MCP Consumption](mcp-consumption.md) — external MCP tools through the full safety pipeline, fail-closed approval
- [Lua Code-Mode](lua-code-mode.md) — read-only server-side Lua queries, VM budgets, seven host bindings
- [Eval Harness](eval-harness.md) — deterministic cases against production functions only
- [Executor Seam](executor-seam.md) — template executor binding, vendor CLI hardwiring, cross-vendor review
- [MCP Server Surface](mcp-server-surface.md) — the served tools/resources and the surface-version stability contract
- [Clustering](clustering.md) — multi-node topologies, the DB-lease ownership model, and the cluster_enabled flip checklist
- [Ambiguity Clarify Loop](ambiguity-clarify.md) — score → ask → fold → re-score before composing an ambiguous build; honest degraded labeling
