# AR-8b — The Sketch Path (throwaway sandbox prototyping)

*Architecture direction — extends AR-2 §8 / AR-8. Not a commitment.*

**Status — SHIPPED (2026-06-23..25; reconciled 2026-07-02).** The sketch path is live:
`Triage.Verdict.composer?/1` includes `:sketch`, and the run roots in a **per-prototype,
hard-isolated `.prototypes/<id>/`** sandbox (symlink-safe — a refinement over this doc's single
`.prototypes` root). How the phases and forks resolved:

- **A** — tiered exactly as recommended: the first cut is a file-tools-only, VFS-jailed
  `sketch-build`; sandboxed *execution* landed later as the AR-8b-2 **F2 `:docker` exec tier**
  (`RunCommand`↔Forge bridge, no-egress + global-config isolation —
  [`AR-8b-2-F2-EXEC-TIER.md`](AR-8b-2-F2-EXEC-TIER.md)).
- **B** — shipped with one deviation from the sketch here: the trigger is **not** a bare
  `request-received` subscription on `sketch-build`. The front door seeds **exactly one
  discriminator topic** — `sketch-plain`, or `must-execute` for the exec tier — and the two
  build stages subscribe to those (`sketch-review` does subscribe `request-received`,
  route-filtered to `sketch`). No plan gate on the path, as designed.
- **C** — graduation shipped as AR-8b-2 C1–C3
  ([`AR-8b-2-GRADUATION.md`](AR-8b-2-GRADUATION.md)); the provenance fork resolved to
  **summary-only** (the recommended reference/summary option, in its summary form — the real
  run starts fresh, the prototype informs, never auto-merges).
- **D** — resolved as the *light lens*: `sketch-review` carries `lens: "correctness"` and stays
  **report-only** (no fixer on the sketch path — the surviving `:not_converged`-on-findings
  case).

Every open question at the end has since resolved: backend (tiered, A above), provenance
(summary, C), retention/GC (never-GC default **plus** the opt-in TTL
`VFS.PrototypeRetentionSweeper` — AR-8b-2 C3), and exec-tier gating (isolation-not-approval; a
per-tool approval overlay stays an explicit non-goal). AR-8b-2 also added **F3**'s read-only
real-tree tools (`read_real_file` / `search_real_code` / `list_real_directory`), relaxing the
full-isolation first cut without touching the writes-stay-in-`.prototypes/` boundary.

*(Write-time status, kept for the record:)* Unblocked and independent of AR-8c and of Phase 4
gates. The isolation substrate (VFS workspaces + the project-dir jail) and the composer/worker
machinery all shipped; the new parts are the sketch workspace rooting, a `sketch-build` worker,
and a cross-run graduation flow.

## Context

AR-8 triage classifies a turn as `sketch` — "throwaway exploration: a code tracer-bullet, a
diagram, a UI mockup, an idea sketch … graduates to `code`/`system` when a result is worth
keeping" (Alp River `agents/triage.md`, `WORKFLOW.md`).

Today `sketch` is **not** a composer path at all. `Triage.Verdict.composer?/1` is true only for
`:code` and `:system`, so `FrontDoor.decide/2` returns `{:inline, verdict}` for `sketch` (it is
grouped with `talk`) and the composer is never started. The turn is handled by the **inline chat
agent**, which carries full `WriteFile` / `EditFile` / `RunCommand` / `GitCommit` tools **against
the real working tree**. So in practice "sketch" today is `talk` with a label — it provides no
throwaway semantics and, worse, no isolation: a sketch can mutate the real project. This doc
designs the real path.

## Why separate

It needs a sandbox executor + workspace isolation + a cross-run graduation flow — none of which
the triage front door needs, and none shared with AR-8c. Independent of Phase 4 (gates).

## What it reuses (substrate that already exists)

- **VFS workspace + project-dir jail.** `JidoClaw.VFS.Workspace` (`vfs/workspace.ex`) is a
  GenServer per `workspace_id` owning a mount table; the `Resolver` realpath-jails every file op to
  its `project_dir` and rejects `../` escapes (`vfs/resolver.ex`). A **distinct `workspace_id`
  rooted at `<project_dir>/.prototypes`** is a fully separate, jailed namespace. The Ash
  `Workspaces.Workspace` row is keyed by `path`, so a `.prototypes`-rooted durable row coexists
  with the real one. (Note the two ids the front door already threads: `workspace_id` is the VFS
  mount-table key = the session id; `workspace_uuid` is the Ash row id.)
- **Forge sandbox** (`forge/sandbox/docker.ex`) is the heavier alternative for *real* OS isolation
  (filesystem, process, network) when a sketch must **execute** code; the default `HostShell`
  backend (`forge/runner/host_shell.ex`) is **not** isolated.
- **The front-door composer-launch seam.** `start_composer` + `composer_context/1`
  (`front_door.ex`) already thread `project_dir` / `workspace_id` / `workspace_uuid` into the run;
  that is the seam where a sketch run gets its `.prototypes` rooting.
- **Triage stickiness.** The front door re-classifies every turn and treats the prior path as
  observability-only (a `talk` flips to `code` on "do it"). Graduation (Phase C) rides exactly
  this.

## Phases

### A — Sandbox workspace

A `.prototypes/`-rooted, isolated workspace (reuse `JidoClaw.VFS.Workspace`) so sketch artifacts
never touch the real working tree. **The central decision is the isolation backend, and it turns
on whether the sketch worker can shell out:**

- The **VFS jail** isolates *file-tool* paths (`ReadFile`/`WriteFile`/`EditFile` through the
  Resolver), which is enough for file-only sketches (a diagram, a mockup, a doc, source files not
  run).
- But `run_command` **shells out** through `SessionManager` → the Forge backend, and the default
  `HostShell` is not isolated — a shelled `rm` / `>` escapes the VFS jail. So a sketch-build worker
  that must *run* code (a "tracer-bullet") needs either the **Forge Docker sandbox** or a worker
  **without `RunCommand`** (file-tools only, fully VFS-jailed).

Recommendation: **tier it** — file-only sketches use the VFS jail (cheap, fits the tailnet-only
threat model: the goal is keeping a misbehaving LLM off the real tree, not defending a hostile
attacker); code-execution sketches use the Forge Docker sandbox. A reasonable first cut is a
VFS-jailed, file-tools-only `sketch-build`, adding sandboxed execution later.

### B — `sketch-build` worker + catalog stages

- **`sketch-build`** — a producer worker (`JidoClaw.Agent.Defaults`), `routes: ["sketch"]`, reusing
  `OutputSchema.artifacts()`; its toolset follows the Phase-A isolation decision. It emits a
  `prototype` artifact.
- **Catalog stages** — `sketch-build` → optional `sketch-review`, all `routes: ["sketch"]`,
  validator-clean. No validator change (`"sketch"` ∈ `@paths`). The triggering subscription is the
  load-bearing detail: triage publishes `code` / `system` but **not** `sketch` (`catalog.ex:42-63`)
  — the `sketch` topic enters `live` only via the front-door seed — and a stage may only subscribe
  to a seed signal or a *published* topic (validator invariant). So `sketch-build` should subscribe
  to the seed signal **`request-received`** and be route-filtered to `sketch` (clean, no new
  signal), rather than to a `sketch` topic no stage produces.
- **Flip the front door** — add `:sketch` to `Verdict.composer?/1`, and have `start_composer` root
  the sketch run at `.prototypes` (Phase A) and seed `live: ["request-received", "sketch", …]`.
  Throwaway means **no plan-gate** — the sketch path skips the approval ceremony entirely.

### C — Graduation (`sketch → code` / `system`)

Triage-driven, riding the existing stickiness: on a later turn the user says "make it real" / "ship
it", triage re-classifies to `code` / `system` (the fresh verdict sees the prototype + the
instruction), and the front door **re-seeds a fresh composer run with the prototype as `request` /
`intent` context** — the "throwaway becomes real" transition.

- **Provenance (open):** how the prototype is carried — by reference to the `.prototypes`
  workspace, by re-reading the prototype files into the seed `request` artifact, or by an `intent`
  summary. Recommend a reference/summary in the seed; the real run starts fresh against the real
  tree (the prototype *informs*, it does not auto-merge).
- **Oscillation-guarded:** graduation is **cross-run** (a brand-new composer run), so AR-2 §4's
  *within-loop* oscillation guard does not cover it — the guard belongs at the front-door / triage
  level (don't let a `sketch ⇄ code` flip-flop thrash new runs). A distinct concern worth naming.

### D — Sketch convergence

A prototype "converges" differently from a reviewed change. On the `sketch` path the route-filter
(AR-2 §3.2 step 2) drops the code-only review band automatically — the four reviewers and `fixer`
are `routes: ["code"]`, so they never compose for `sketch` (the code-only ceremony is filtered off
by `routes`). The choice is how much review remains:

- *Minimal* — no lens; the run converges when `sketch-build` finishes (dispatch empties, no lens
  ran ⇒ `lenses_clean?` trivially true).
- *Light lens* — a `sketch-review` carrying a `lens` (correctness + security still apply, per the
  skeleton), so `clean:<lens>` gates convergence and a genuinely-broken prototype is caught without
  the full code-only ceremony.

## Open questions / decisions

- **Sandbox FS backend** — VFS jail (file-only) vs Forge Docker (code-exec). The
  `run_command`-escapes-the-VFS-jail nuance (Phase A) is the crux.
- **Retention / cleanup of `.prototypes/`** — when is a prototype GC'd? On graduation, on session
  end, or never (kept for reference)? A retention concern off the routing path (mirrors the
  `ComposerArtifact` retention note, AR-2 §6).
- **Graduation provenance** — by-ref vs re-read vs summary (Phase C).
- **Does a sandboxed (code-executing) sketch need any gate?** Throwaway argues no ceremony, but a
  sketch that can reach the network in a sandbox might still warrant a safety check. Likely no gate
  for the file-only first cut; revisit if sandboxed execution lands.
