# AR-8b — The Sketch Path (throwaway sandbox prototyping)

*Architecture direction — extends AR-2 §8 / AR-8. Not a commitment.*

**Context.** AR-8 triage (Phase 3) classifies a turn as `sketch` — "throwaway
exploration: a code tracer-bullet, a diagram, a UI mockup, an idea sketch …
graduates to `code`/`system` when a result is worth keeping" (Alp River
`agents/triage.md`, `WORKFLOW.md`). Phase 3 routes `sketch` **inline** (like
`talk`) as a stopgap, because the sandbox machinery does not exist. This doc
designs it.

**Why separate.** It needs a sandbox executor + workspace isolation + a cross-run
graduation flow — none of which the triage front door needs. Independent of
Phase 4 (gates).

**Phases.**

- **A — Sandbox workspace.** A `.prototypes/`-rooted, isolated workspace (reuse
  `JidoClaw.VFS.Workspace`) so sketch artifacts never touch the real working tree.
- **B — `sketch-build` worker + catalog stages.** A new worker template + built-in-catalog
  `sketch`-route stages (`sketch-build` → optional `sketch-review`), validator-clean,
  `routes` including `"sketch"`. Flip the front door to start a composer for `sketch`.
- **C — Graduation.** A `sketch → code`/`system` promotion that re-seeds a fresh composer
  run with the prototype as `request` context (the "throwaway becomes real" transition),
  oscillation-guarded.
- **D — Sketch convergence.** A prototype "converges" differently from a reviewed change
  (correctness + security still apply; the code-only ceremony band is filtered off by
  `routes`).

**Open questions.** Sandbox FS backend; retention/cleanup of `.prototypes/`; how
graduation carries provenance.
