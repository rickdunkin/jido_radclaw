# OR first wave — the adoptable-now queue

*A sequenced grab-list, not new design. Extracted 2026-07-04 from the
[orca inventory](FEATURES-WORTH-BORROWING.md)'s "suggested first wave" — the
entries whose trigger is satisfied by the act of deciding to work (no argus slice
required). Everything else in the inventory is argus-slice-bound or rides an
already-queued item and stays there. Refs inherited from the inventory (verified
there 2026-07-04 @ jido_radclaw `609350aa`, orca `2520b31`); re-verify at build
time. orca is MIT — verbatim lifts are legal, but everything below is our-side
wiring anyway (Rust → Elixir).*

**Queue discipline** (the next-five/next-ten habit): each item ends by reconciling
its source entry — add the dated Status line (the inventory carries none yet; this
queue is orca's first adoption pass), correct any claims the implementation
falsified, and update cross-refs the same session.

**Effort legend**: XS ≤ 2h · S ≤ 1 day · M 2–4 days.

| # | Item | Source | Effort | Shape |
| --- | --- | --- | --- | --- |
| 1 | Step-projection reprojection command (make the moduledoc true) | [OR2-4a](FEATURES-WORTH-BORROWING.md#or2-4-event-store-deltas--the-rebuild-command-we-claim-the-summary-feed-the-stranded-run-sweep) | S | One maintenance entry point + fold reuse + tests |
| 2 | Non-interactive env floor for spawned children | [OR3-1](FEATURES-WORTH-BORROWING.md#or3-1-non-interactive-subprocess-env-baseline) | XS | One constant map + merge point + test |
| 3 | Riders on queued items: gates wiring → #5, severity-axis question → #6, ledger/readiness + quality gate → #8/#9, silence-vs-wall kinds → MC1-4 | [OR2-2](FEATURES-WORTH-BORROWING.md#or2-2-deterministic-gates-between-phases--the-shipped-shape-of-next-ten-5), [OQ-1](FEATURES-WORTH-BORROWING.md#open-questions), [OR2-5](FEATURES-WORTH-BORROWING.md#or2-5-briefing-judgment-layer--ambiguity-ledger-readiness-gate-and-the-promote-on-accept-evidence), [OR3-2](FEATURES-WORTH-BORROWING.md#or3-2-subprocess-failure-kind--dual-timeout-split--rider-on-mc1-4) | — (inside their hosts) | Recorded riders, not standalone work |

Items 1 and 2 are independent — slot either anywhere. Item 3 is not standalone:
each rider lands **inside** its host item when that item runs
([next-ten #5/#6/#8/#9](../../../plans/unadopted-next-ten/README.md) are
confirmed unstarted as of this dig; MC1-4 sits in the
[multica first wave](../multica/MC-FIRST-WAVE.md)), and each host carries a
dated back-reference to its rider (added 2026-07-04, the MC-FIRST-WAVE rider
habit) — recorded on both ends so nothing slips.

---

## 1. OR2-4a — Step-projection reprojection command (S)

**What**: close an our-side documented-but-unbuilt claim the dig surfaced.
`WorkflowStep` rows are projected best-effort inside the append transaction, wrapped
in a savepoint so a projection failure never rolls back the append — and the
moduledoc promises the escape hatch: failures "are repairable by replaying the run's
`step_*` events" (`workflow_event/changes/allocate.ex:50-51`). **No such replay
exists** (grep-verified; `Orchestration.Replay` is inputs-re-run, and
`Projection.project_status/1` is a test-only prover). orca ships the honest version:
a manual `rebuild_projections` that drops and re-folds from the log
(`commands.rs:4640-4784`) — dev-only, no auto-trigger, exactly the right scope.

**Shape**: a maintenance entry point (`mix jidoclaw.reproject_steps <run_id>`, or an
operator-scoped action beside `replay_workflow`'s surfaces) that reads the run's
`step_*` events in seq order and re-applies the existing upsert logic
(`record_started/record_completed/record_failed` — identity upserts, idempotent by
construction). The composer's fold (`route_composer/projection.ex:68-90`) is the
in-house precedent that projection == fold; this makes the step read-model's repair
path real. Tenant-scoped, read-the-log-only, no status writes (status projection is
the append path's job and stays there).

**Done when**: a run with hand-deleted/corrupted `WorkflowStep` rows reprojects to
byte-equal rows; a healthy run reprojects to a no-op; the allocate.ex moduledoc's
claim cites the command.

## 2. OR3-1 — Non-interactive env floor (XS)

**What**: orca injects a force-non-interactive baseline under every spawned child
(`CI=true`, `DEBIAN_FRONTEND=noninteractive`, `GIT_TERMINAL_PROMPT=0`,
`GIT_ASKPASS=""`, `SSH_ASKPASS=""`, `NPM_CONFIG_YES=true`, `PIP_NO_INPUT=1`,
`PYTHONUNBUFFERED=1`; caller wins — `subprocess.rs:207-213`). Our spawn hygiene is
the allowlist scrub (`security/redaction/env.ex` — secrets can't leak **in**) but
nothing forces never-prompt: a git or pip inside a Forge sandbox or gate command
that decides to prompt hangs against its timeout instead of failing fast.

**Shape**: one constant map merged at the same seams `scrubbed_cmd_env/1` /
`scrubbed_port_env/1` already own (inject after scrub, explicit caller env wins),
applied to Forge runner/bootstrap/init-class children — not to interactive shell
sessions. Composes with, never replaces, the allowlist (scrub = leakage hygiene;
floor = liveness hygiene).

**Done when**: a Forge-spawned `git fetch` against a credential-requiring remote
fails immediately rather than hanging to timeout; the env test pins the floor +
override-precedence.

## 3. Riders (recorded, land inside their hosts)

- **→ [next-ten #5](../../../plans/unadopted-next-ten/README.md) (deterministic
  verify)**: orca's gate wiring details — named gate registry + per-phase attach +
  per-unit override resolution, `GateStarted/GateRan` with
  `triggering_phase_run_id` provenance, first-fail-stops — and the one
  anti-pattern to invert: unknown gate names must fail loud, not silently skip
  (`pipeline.rs:72-100`). *(Back-reference recorded in item 5's scope notes.)*
- **→ [next-ten #6](../../../plans/unadopted-next-ten/README.md) (`review_stall` /
  argus `:review` co-design)**: OQ-1 — does finding severity grow a
  release-semantics axis (orca's `blocking|advisory`) or does the release decision
  live on the gate? Decide once, for both kinds. *(Back-reference recorded as item
  6's rider 7.)*
- **→ [next-ten #8/#9](../../../plans/unadopted-next-ten/README.md) (ambiguity
  loop / structured premises)**: the ambiguity-ledger item schema (`{question,
  why_it_matters, risk_if_unanswered, recommended_default_assumption,
  user_input_required, status, user_answer}`),
  `readiness_status ∈ ready_for_tasks|ready_with_assumptions|blocked_needs_user_input`,
  the explicit accept-assumptions gate, and the deterministic per-task quality gate
  with one repair re-prompt (`validate_task_quality`). Plus OQ-2: reserve the
  acceptance-criteria id linkage in #9's schema so OR1-1's criterion-mapping has a
  producer. *(Back-references recorded after each item's plan.)*
- **→ MC1-4 ([multica first wave, item 1](../multica/MC-FIRST-WAVE.md))**: the
  silence-vs-wall-clock timeout split (`stalled_no_output` vs
  `stalled_wall_clock`), `user_cancelled` as a first-class non-failure kind, and
  the group-kill discipline (`setsid` + kill the process group + a shutdown
  ChildTracker). *(Back-reference recorded under MC-FIRST-WAVE item 1's
  done-when.)*
