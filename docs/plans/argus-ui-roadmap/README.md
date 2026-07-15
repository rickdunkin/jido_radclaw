# Argus UI design-phase roadmap

*Laid out in the 2026-07-12 working session; until now it lived only in that
session's transcript (the [componentize plan](../../../.claude/plans/we-re-going-to-start-iridescent-codd.md)
quotes step 5). This file is the durable copy — status annotations added
2026-07-13. Design phase = screens built design-only against fixture seams;
real data wiring is the separate [argus-ui-bootstrap](../argus-ui-bootstrap/README.md)
program (GraphQL/channels slice 1), which begins at these screens' doorstep.*

**Numbering key**: `2a`, `3f`, `4c`, … are element ids in the design mock
`ui/_mocks/project/Argus Explorations.dc.html` — the design source of truth.
Anchor by id; line numbers drift when the bundle is regenerated.

## The sequence

1. **Commit the init as its own checkpoint** — staging only the `ui/` init
   files, deciding whether `ui/_mocks/` gets committed as reference material.
   **Done** — `2efb7e52` (scaffolding) + `793eb754` (shadcn init); the mock
   bundle was committed.

2. **Mock-data layer before any screen** — typed placeholder data shaped like
   the eventual GraphQL/channel payloads (projects, nodes, threads, runs,
   approvals, attention items); screens render against it so later wiring to
   `src/gql/` is mechanical. **Done** — `91e355ee`. Landed shape: `src/lib/`
   fixture seams (`useShellData()` et al.) + the `src/mocks/` dev-server-only
   fakes, not the provisionally named `src/fixtures/`.

3. **Responsive app shell** — the navigation frame both surfaces share: custom
   phone tab bar (Attention · Approvals · Threads · Projects, badges nearest
   the thumb) below `md`, shadcn `Sidebar` rail (nav + projects + node-health
   footer) above it. Cheap to build both now; retrofitting a shell under
   finished screens is the expensive version. **Done** — `57f61037`.

4. **Attention feed (2a) as the first real screen** — the anchor screen; it
   exercises most of the vocabulary: status dots, the amber group-panel, list
   rows, mono meta lines, count chips, priority/by-project toggle.
   **Done** — `86442901` (2a/5a/5e, design-only, explicit preview marker).

5. **Run `componentize` after 2a, not before** — extract the argus composites
   once real usage has shaped their APIs; subsequent screens consume them
   instead of re-deriving. **Done** — `fdf361b4`. The vocabulary home is
   `ui/src/components/system/` and the 2a names won over the roadmap's
   provisional ones: AttentionPanel → `GroupPanel`, ListRow → `FeedRow`,
   CountChip → `FeedChip`; `StatusDot`, `MetaLine`, `DecisionCard` (shell) as
   named; `/styleguide` is the rendered spec sheet.

6. **Remaining phone set, composing those pieces** — **Approvals (2b) done**;
   next: Grants + edge states (4a), then Threads (2c), Transcript (2d).
   This is where `Tabs`, `Input`/`Textarea`, and the decision-card patterns
   get their real workout. Step-5 obligation dispositions from the 2b pass:
   DecisionCard's version chip (`v2 · you`) **moved to the gate screens
   (3b/4b)** — the 2b mock shows none, per the step-5 locked decision;
   PageShell, PageHeader, PreviewMarker, InlineRef, and MicroCaption
   **extracted** into `ui/src/components/system/` (2b was their second real
   site); DecisionCard got its first real Button/Textarea children and the
   `tone="resolved"` variant. Still single-site (ledger notes only):
   colored-count runs (2a's CountSummary vs 2b's static amber run — different
   shapes) and the FeedAction tone axis (2b's actions are real Buttons).
   What 2b's UI fronts that the backend must grow is recorded in
   [argus-backend-needs.md](argus-backend-needs.md) — the design-phase
   ledger slice 1 implements against.

7. **Desk set, gate-loop first** — Runs (3f) → workflow run detail (3d) →
   review gate (3b) + gate editors/conflict (4b), since gates are the
   product's heart; then Worktrees + create panel (3a/3g), Board (3c), Diff
   viewer (3e).

8. **Per-screen hygiene throughout** — standing practice, not a discrete step:
   `canonicalize-tailwind` as classes accumulate, a light-theme spot check
   against the 4c proof (flip the `dark` class), and the full UI gate
   (`codegen && check && test && build`) green before each checkpoint.

9. **Endgame housekeeping** — promote Attention to the default route, move the
   token smoke board off `/` to a dev-only styleguide route, and run
   `make-responsive` where phone and desk mocks describe the same surface
   (Threads, Runs, gates) to merge them properly.
