# Phase 3 — Memory subsystem (split into three sub-phases)

The original Phase 3 plan was a single 1,902-line spec covering
the full Memory rewrite (resources, consolidator, frozen-snapshot
prompt, Codex runner). During implementation planning the work
was sliced into **three independently-shippable sub-releases** so
each is reviewable and `main` stays release-able between them.
The sub-phase docs below are the canonical source going forward;
this file is kept as an index so cross-phase references in the
sibling docs (Phase 0 / 1 / 2 / 4) keep resolving.

## Sub-phase docs

- [**Phase 3a — Memory: Data Layer & Retrieval**](phase-3a-memory-data.md)
  ships the seven Memory resources (`Block`, `BlockRevision`,
  `Fact`, `Episode`, `FactEpisode`, `Link`, `ConsolidationRun`),
  the multi-scope + bitemporal schema, write paths, hybrid
  retrieval (FTS + pgvector + trigram via RRF), the model and
  user tool surface (`Remember`, `Recall`, `Forget`), the CLI
  surface for blocks/list/search/save/forget, the embedding
  pipeline for `Memory.Fact`, the migration and rollback-export
  mix tasks, and the decommissioning of the legacy
  `JidoClaw.Memory` GenServer. Source-plan §3.1-§3.13, §3.16-§3.18,
  data-layer subset of §3.19.
- [**Phase 3b — Memory: Consolidator Runtime & Frozen-Snapshot
  Prompt**](phase-3b-memory-consolidator.md) ships the scheduled
  consolidator (per-scope advisory lock, watermark resolution,
  in-memory clustering, Forge harness session via Claude Code,
  the in-process HTTP scoped MCP server hosting the eleven
  proposal tools, staging buffer + transactional publish), the
  frozen-snapshot system prompt rewrite, the new
  `JidoClaw.Cron.Scheduler.start_system_jobs/0` entry, the
  per-session `sandbox_mode` knob, and the `/memory consolidate`
  / `/memory status` CLI commands. Source-plan §3.14, §3.15,
  consolidator + snapshot subset of §3.19.
- [**Phase 3c — Memory: Codex Sibling
  Runner**](phase-3c-memory-codex.md) ships
  `JidoClaw.Forge.Runners.Codex` so the consolidator can be
  configured with `harness: :codex`. Smallest of the three; reuses
  every piece of 3b's orchestration. Source-plan references in
  §3.9, §3.15.

## Ship order

3a → 3b → 3c. Each sub-phase ships as its own point release
(`v0.6.3a`, `v0.6.3b`, `v0.6.3c`) and `main` stays release-able
between them. 3a is fully usable on its own — agents can
remember/recall in Postgres, users can edit Blocks manually,
migration tasks let people move off `.jido/memory.json`. 3b makes
the Block tier self-improving via the consolidator and lets the
Anthropic prompt cache fire across turns. 3c lets operators swap
which frontier-model harness drives the consolidator.

## Cross-phase references

Source-plan section numbering (§3.1, §3.6, etc.) is preserved
verbatim across the sub-phase docs so existing references inside
Phase 0 / 1 / 2 / 4 keep working. If a sibling doc refers to
"§3.13 Retrieval API," look in 3a; "§3.15 Consolidator design,"
look in 3b.

## Why split

The decision is a process choice, not a design change. The
single-file spec in v0.5 of this doc was correct as a *design*
artifact (it preserves the cross-cutting invariants — bitemporal
predicate matrix, scope/source precedence in SQL, contiguous-prefix
watermark advance — without artificial chapter breaks) but a poor
*ship* artifact: a single 1,902-line doc maps to a single ~5,000-
line PR that's hard to review, hard to revert in pieces, and
forces every resource change to land at the same time as the
consolidator's MCP wiring. Slicing along the consolidator boundary
(3a is the data layer; 3b is the orchestration; 3c is the runner
sibling) keeps each sub-phase under ~1,500 lines of code change
and lets reviewers focus on one concern at a time.
