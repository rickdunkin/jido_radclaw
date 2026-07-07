# JidoClaw Documentation

The map over `docs/` — where each kind of truth lives and which file is the entry
point. (AGENTS.md at the repo root stays the always-in-context operating file: build
commands, key-pattern contracts, and pointers into the layers below.)

## Layers

- **[system/](system/README.md)** — guarded per-subsystem deep truth: one page per
  subsystem (mechanics, config, telemetry, residuals) behind the load-bearing contract
  AGENTS.md keeps inline. Conventions + index in `system/README.md`; drift-guarded by
  `mix jidoclaw.system_docs.check` in precommit.
- **[exploration/](exploration/README.md)** — the exploration corpus: external systems
  (and occasionally our own future shape) studied for what's worth borrowing. Tiered,
  evidence-backed inventories with lifecycles; conventions + subject index in
  `exploration/README.md`.
- **plans/** — program and queue plans: the `unadopted-next-*` queues (the roadmap of
  approved-but-unbuilt borrows), plus per-program plan directories (clustering,
  MCP workflow resources, v0.6).
- **reports/** — dated one-off reports: audits, code reviews, baselines, follow-ups.
  Historical records; they are not reconciled after the fact.
- **_archive/** — retired plans/backlogs kept for the record.

## Standing documents

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — the broad-shallow architecture map
  (supervision tree, subsystem directory, data flow).
- **[SETUP.md](SETUP.md)** — environment setup beyond the AGENTS.md quickstart.
- **[TRUST-BOUNDARIES.md](TRUST-BOUNDARIES.md)** — the five trust-boundary laws + the
  event-sourced durability checklist; the review rubric for orchestration/gate changes.

## Which layer does a new document belong to?

Subsystem truth that outgrew its AGENTS.md bullet → `system/` (same-PR rule applies).
Study of an external system → `exploration/` (use the explore-repo skill). A dated
finding or audit → `reports/`. Forward-looking program work → `plans/`. Anything
superseded → `_archive/`, not deletion.
