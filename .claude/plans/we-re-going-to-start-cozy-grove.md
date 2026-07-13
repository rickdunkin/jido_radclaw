# Attention Feed (2a/5a/5e) — first real argus screen, design-only

## Context

The argus SPA has its substrate (shell, tokens, routing, mock layer) and two real data screens (`/projects`, `/runs`); the rest are stubs. This phase starts the UI design work proper: implement the **Attention feed** — the anchor screen at `/` — as a fully *designed but not yet wired* page. It exercises most of the design vocabulary (status chips, amber group-panel, list rows, mono meta lines, count/age chips, priority/by-project toggle) and extracts that vocabulary as reusable components for Approvals (2b) and Threads (2c). No backend wiring: static fixture data behind a seam (the `useShellData()` precedent — which already ships static counts/projects/nodes to every surface). Because the built SPA is node-served, the page must be **honest about being a preview**: an explicit sample-data marker instead of a fabricated "live" signal.

**Design truth**: `ui/_mocks/project/Argus Explorations.dc.html` (anchor by element id; line numbers drift when the bundle is regenerated):
- `#2a` (~638) — phone Priority view, 390px (chevron rows, age folded into meta, `3 wk · 3 you · 1 fail`)
- `#5a` (~157) — desk Priority view, 1280px (full-width rows + amber **age chip** + inline resolving action: solid `Open gate →`, outline `Reply →`/`Details →`; age extracted to trailing mono on EARLIER rows; richer meta; footer caption)
- `#5e` (~43) — phone By-project view (one panel per project ordered by urgency; amber panels for needs-you projects with `1 needs you` + `● 2 working` header; neutral panels with card-rows; quiet projects roll up to a single line). Desk by-project is NOT mocked — derived by applying the same 2a→5a transformation (operator-confirmed).
- `#4c` (~1842) — light-theme proof of 2a; components stay token-pure so light works by class flip.

**Settled with operator** (interview 2026-07-12):
1. Desk layout = 5a (full-width column; ultra-wide cap `max-w-6xl` is a taste default — 5xl would already bite at 1280).
2. Toggle is **functional**, local state only (no URL search param this phase); both views designed.
3. Rows and action "buttons" are **inert** — no link/button semantics, no focus stops, chevrons `aria-hidden`, actions are styled `<span>`s. The toggle is the page's only feed control.
4. Extract shared vocabulary into `src/components/feed/` now.

**Settled by plan review** (2026-07-12, three rounds):
5. **Explicit preview marker, no "live"**: the header renders a muted mono `preview · sample data` marker where the mock shows the live indicator (no green dot — green signals health). This keeps fixture incidents honest in ANY build (the mock-exclusion guard only covers `src/mocks/**`; `src/lib` fixtures ship), and it confines the inert CTAs/chevrons to an explicitly marked preview. Slice 1 swaps marker → real live indicator when real data lands.
6. **Phone path to `/runs` survives**: the temp links row is *kept* (restyled as a muted mono utility row under the feed), because `/runs` is a real screen with no phone tab by design and this stub is its only phone click-path. Removed in slice 1 when a real feed row navigates. Same accessible names ("View runs", "View projects", "View board", "Styleguide") to minimize test churn.
7. **Row anatomy responds to a NAMED container, `@3xl/feed`** (48rem = 768px container). The page root declares `@container/feed`; all anatomy twins use `@3xl/feed:` variants. Monotonic by construction: below the 768 viewport rail flip the container can never reach 768px (no premature wide flash at 672–767 the way `@2xl` had), and with the rail up the flip lands at viewport ≈ 1005 (pane content ≥ 48rem). Portable by construction: FeedRow is built for Approvals/Threads reuse, and a narrow desktop placement (side panel) that declares its own `@container/feed` keeps phone anatomy — a viewport `lg:` could not. **Defined layouts**: < 768 phone (2a/5e); 768–~1000 phone anatomy inside the rail shell (deliberate — pane ~532–780px); ≳ 1005 desk anatomy (5a / derived by-project). Page gutters stay chrome-aligned at viewport `md:`.
8. **Toggle pills = additive `pill` variant on the shared Tabs wrapper** (`components/ui/tabs.tsx` has a CVA variant seam; the Badge `waiting` variant is the additive precedent). Approvals 2b reuses it. No route-level class fights against the base variant.
9. **Chips compose Badge fully at the CVA seam**: badge.tsx gains additive *color* variants `waiting-subtle` (tinted amber) + `muted`, AND an additive **`size` axis** (`default` preserving today's classes, `feed` carrying the chip geometry: `h-auto rounded-full px-2 py-0.5 font-mono text-[0.65625rem] font-semibold`). `FeedChip` wraps `<Badge variant=… size="feed">` with `className` for *placement only* (`shrink-0 whitespace-nowrap`). Arbitrary **font sizes use rem** throughout the feature (design guideline; px stays for geometry lengths).
10. **Valid list markup for divider rows**: `Separator` renders a `<div>` — never between `<li>`s. EARLIER dividers are inset top hairlines on the `li` itself (`before:` pseudo-element, hidden on first child).
11. **No headerless `<section>`s**: `GroupPanel` renders `<section aria-labelledby>` only when given a `header`; headerless panels render `<div>` (the EARLIER panel sits inside a view-owned labelled section — a nested anonymous section would be wrong).

## Files

| # | Path | Change |
|---|------|--------|
| 1 | `ui/src/lib/attention-data.ts` | NEW — types, fixtures, seam, `deriveAttentionSummary` |
| 2–8 | `ui/src/components/feed/{group-panel,section-label,status-icon-chip,feed-chip,feed-action,meta-line,feed-row}.tsx` | NEW — vocabulary |
| 9 | `ui/src/components/ui/tabs.tsx` | EDIT — additive `pill` variant at the existing CVA seam (both themes; 4c light = white card + border + shadow-xs, dark = flat `bg-muted`) |
| 10 | `ui/src/components/ui/badge.tsx` | EDIT — additive `waiting-subtle` + `muted` color variants + `size` axis (`default` \| `feed`) |
| 11 | `ui/src/routes/_shell/index.tsx` | REWRITE — stub → real screen (keeps a restyled temp-links utility row; `StubPage` import dropped, component stays for other routes) |
| 12 | `ui/src/attention.test.tsx` | NEW — screen + derivation tests |
| 13 | `ui/src/attention-seam.test.tsx` | NEW — sentinel-data seam mock (own file: `vi.mock` hoists module-wide, shell-seam.test.tsx precedent) |
| 14 | `ui/src/shell.test.tsx` | EDIT — HREF_TABLE rows for the four temp links stay (labels unchanged); remove `/` from the stub-routes case (no longer a StubPage) and move its temp-links assertion into attention.test.tsx |
| 15 | `ui/src/router.test.tsx` | EDIT — index test keeps the heading assert, adds a real-page pin (`tab` "Priority"); provider-less render doubles as the no-Apollo guard |

Untouched: `src/mocks/**`, `schema.graphql`, `codegen.ts`, `components/ui/**` except tabs.tsx + badge.tsx (sidebar stays locally-edited-and-guarded), `shell-data.ts` (its `attentionCount: 3` already agrees with the fixtures — pinned by test, not edited).

## 1. Data seam — `src/lib/attention-data.ts`

Readonly **discriminated union** — invalid states unrepresentable (action required on needs-you kinds, forbidden elsewhere; count only on clusters; titleCode only on resolved). Fixture deep-frozen at module init; both getters return the singleton as a readonly type.

```ts
export type AttentionAction = Readonly<{ label: string; emphasis: "solid" | "outline" }>; // arrow in label
type ItemBase = Readonly<{
  id: string; title: string;
  project: string;                    // grouping key; "infra" is a pseudo-project
  phoneMeta: readonly string[];       // phone line = [project?, ...phoneMeta, age].join(" · ")
  deskMeta: readonly string[];        // wide line  = [project?, ...deskMeta].join(" · "); age moves to trailing slot
  age: string;                        // preformatted "4m" / "1h"
}>;
export type NeedsYouItem   = ItemBase & Readonly<{ kind: "gate" | "question" | "alert"; action: AttentionAction }>;
export type FailedItem     = ItemBase & Readonly<{ kind: "failed" }>;
export type DoneItem       = ItemBase & Readonly<{ kind: "done" }>;
export type IdleClusterItem= ItemBase & Readonly<{ kind: "idle"; count: number }>;   // ×N chip, no chevron
export type ResolvedItem   = ItemBase & Readonly<{ kind: "resolved"; titleCode?: string }>;
export type AttentionItem  = NeedsYouItem | FailedItem | DoneItem | IdleClusterItem | ResolvedItem;

export type AttentionData = Readonly<{
  workingCount: number;                                        // 3 — working threads are NOT feed rows
  workingByProject: Readonly<Partial<Record<string, number>>>; // { quill: 2 } — SPARSE (lookups type number|undefined,
                                                               // normalized `?? 0`); deliberately ≠ Σ workingCount (mock-honest)
  items: readonly AttentionItem[];                             // priority order; components never re-sort
}>;
export function getAttentionData(): AttentionData;    // non-hook getter (tests/pure code — rules-of-hooks is name-based)
export function useAttentionData(): AttentionData;    // hook-named seam for components (live-data swap point)
export function needsYou(item: AttentionItem): item is NeedsYouItem;   // kind ∈ {gate, question, alert}
export function terminal(item: AttentionItem): boolean;                // kind ∈ {done, resolved} — shared predicate

export type AttentionSummary = Readonly<{ working: number; waitingOnYou: number; failed: number; offlineNodes: readonly string[] }>;
export function deriveAttentionSummary(data: AttentionData, nodes: readonly ShellNode[]): AttentionSummary;
export function groupByProject(data: AttentionData): ProjectGroup[];
```

**Count sourcing (unambiguous, all through `deriveAttentionSummary`)**: `working` = `data.workingCount` (scalar — working threads aren't rows); `waitingOnYou` = `items.filter(needsYou).length`; `failed` = count of `kind === "failed"`; `offlineNodes` from the passed `ShellNode[]` (route passes `useShellData().nodes`). Per-project `● n working` = `workingByProject[project] ?? 0` (render the span only when > 0); per-project `n needs you` / `● n failed` derived from that group's items. No literals in components.

Fixtures (7 rows; meta stored as **fixture-exact segment arrays**, not composed by rules — the mock's composition is editorial; unify titles where 2a/5a/5e phrasings differ, desk copy wins — log in Deviations):

| id | kind | title | project | phoneMeta | deskMeta | age | extras |
|---|---|---|---|---|---|---|---|
| gate-export | gate | Plan review — migrate export pipeline to streaming | quill | export-pipeline, atlas | thread export-pipeline, atlas, run #7 step 3/5 | 4m | action solid "Open gate →" |
| q-webhook | question | "Webhook auth: HMAC per endpoint, or one shared signing key?" (curly quotes) | helios-api | webhook-endpoints, wren | thread webhook-endpoints, wren | 12m | action outline "Reply →" |
| alert-cred | alert | API credential expired on basalt — 2 threads paused | infra | basalt | basalt | 31m | action outline "Details →" |
| fail-e2e | failed | Run failed — e2e suite timed out at step 4/6 | terrarium | nightly-e2e #212 | nightly-e2e #212, wren — created T-222 | 1h | |
| done-pr142 | done | Finished — attention-feed virtualization · PR #142 opened | argus | attn-feed | attn-feed, atlas | 26m | |
| idle-cron | idle | Cron ticks skipped — basalt offline | terrarium | sensor-sync | sensor-sync | 2h | count 12 |
| res-merge | resolved | Approved — | quill | export-pipeline | export-pipeline | 3h | titleCode `gh pr merge --squash` |

`groupByProject` (pure, unit-tested): group by project, first-appearance order; hoist needs-you items within a group; `tone: "amber"` iff any needs-you; **`quiet` iff every item is `terminal()`** (done OR resolved — a resolved-only project rolls up too); order amber → non-quiet neutral → quiet ⇒ exactly 5e's quill, helios-api, infra, terrarium, argus. Quiet-line verb: from the **first terminal item in preserved source order** (items are priority-ordered; no timestamps exist this phase — explicitly defined, not "newest"): done → "finished", resolved → "resolved".

## 2. Vocabulary components — `src/components/feed/`

All token-pure (no hex/oklch), kebab-case, component-only exports (`only-export-components` is ON here — keep `KIND_STYLE`/tone maps module-private; `export type` is fine). Each stamps `data-slot`. Light-mode elevation is **dark-reset**: `shadow-xs dark:shadow-none` (light is `:root`). Arbitrary **font sizes in rem** (10px `text-[0.625rem]`, 10.5 `text-[0.65625rem]`, 11 `text-[0.6875rem]`, 11.5 `text-[0.71875rem]`, 13 `text-[0.8125rem]`, 13.5 `text-[0.84375rem]`, 15 `text-[0.9375rem]`); geometry lengths may stay px.

**Semantics are part of the contract** (not just inertness): the page `h1` is "Attention"; every section label ("NEEDS YOU · 3", "EARLIER", project names) renders as an `h2`; labelled `<section>`s come from GroupPanel-with-header or the view (EARLIER), never nested anonymously (decision 11); every row collection is `<ul role="list">` (explicit role — Safari/VO precedent from the shell) and **FeedRow renders an `<li>`**. `<ul>` children are `<li>` ONLY (decision 10). Quiet-project rollups are single-`li` lists inside their project section.

- **GroupPanel** `{ tone: "amber"|"neutral", header?, className?, children }` — `header` given ⇒ `<section aria-labelledby>` (id wired to the header's h2); headerless ⇒ `<div>`. Amber: `rounded-xl border border-status-waiting/35 bg-status-waiting/7 p-1 dark:border-status-waiting/20` (styleguide recipe + 4c light border); neutral: `rounded-xl bg-card p-1 shadow-xs dark:shadow-none`. Priority-EARLIER: view owns `<section aria-labelledby="earlier-h2">` around the page-level label + a headerless neutral GroupPanel (`px-0`; row `li`s carry their own inset hairline: `relative before:absolute before:inset-x-3.5 before:top-0 before:h-px before:bg-border first:before:hidden` — or nearest equivalent); by-project neutral keeps `p-1` card children.
- **SectionLabel** `{ tone?: "waiting"|"muted", id?, as?: "h2" }` — default heading `h2`; `text-[0.65625rem] font-bold tracking-[0.08em]`, amber or `text-muted-foreground/75`.
- **StatusIconChip** `{ status, glyph, size?: "sm"|"lg", outline? }` — always `aria-hidden`; sm `size-[26px] rounded-[9px] text-xs`, lg `size-[30px] rounded-md text-[0.8125rem]`; literal tone map (Tailwind scanner): waiting `bg-status-waiting/15 text-status-waiting`, failed `/13`, done `/12`, idle `bg-muted text-muted-foreground/80`, + working/offline pre-staged; `outline` = resolved treatment (`border border-border text-muted-foreground`).
- **FeedChip** `{ tone: "muted"|"waiting" }` — wraps `<Badge size="feed" variant={tone === "waiting" ? "waiting-subtle" : "muted"}>`; own `className` is placement-only (`shrink-0 whitespace-nowrap`). Geometry/typography live in badge.tsx's `size="feed"` (decision 9); colors: `muted` = `bg-muted text-muted-foreground` (the `×12` count), `waiting-subtle` = `bg-status-waiting/12 text-status-waiting` (the age chip). The solid `waiting` variant stays reserved for NavBadge/CTAs.
- **FeedAction** `{ action }` — inert `<span>` (no role/tabindex, text visible): solid `rounded-md bg-status-waiting-solid px-3.5 py-2 text-xs font-semibold text-status-waiting-solid-foreground`; outline `border border-status-waiting/50 text-status-waiting`.
- **MetaLine** `{ segments, className?, "data-slot"? }` — `truncate font-mono text-[0.6875rem] text-muted-foreground`, joins with `" · "`; **forwards per-instance `data-slot`** (FeedRow renders two).
- **FeedRow** `{ item, variant: "card"|"row", showProject: boolean }` — renders `<li>`; **requires an ancestor `@container/feed`** (documented in the component comment; the page root provides it, a future narrow placement provides its own). Private `KIND_STYLE` map keyed on the union's `kind` (glyph ◆ ? ⚠ ✕ ✓ ◌ ✓, status tone, chip size, title emphasis; resolved adds `opacity-[.62]` on the root). Root `flex items-start gap-[11px] @3xl/feed:items-center @3xl/feed:gap-3` + `data-kind`; card = `rounded-lg bg-popover p-3 shadow-xs @3xl/feed:px-3.5 dark:shadow-none`, row = `px-3.5 py-[11px]` (+ the EARLIER hairline classes from its parent recipe). **Overflow contract**: body `min-w-0 flex-1`, every trailing piece `shrink-0` (mock's `flex:1;min-width:0` / `flex:none`). Two sibling MetaLines: `feed-meta-phone` (`mt-[3px] @3xl/feed:hidden`, segments incl. age) / `feed-meta-desk` (`hidden @3xl/feed:block`, age extracted). Trailing anatomy per kind — needs-you: chevron (`@3xl/feed:hidden`) vs age FeedChip + FeedAction (`hidden @3xl/feed:inline-flex`); failed/done: age mono text (`hidden @3xl/feed:inline`) + chevron (both); idle: ×N chip (both) + age (wide); resolved: `resolved` + `<span className="hidden @3xl/feed:inline"> · {age}</span>`. All chevrons `aria-hidden`, `self-center`.

**Surface call**: by-project neutral-panel inner cards (mock `#17171b`) → `bg-popover` (popover is the "card-in-a-panel" rung; `muted` is claimed by chips/pills; unifies with amber-panel cards — comment so it isn't re-litigated).

## 3. Screen — `src/routes/_shell/index.tsx`

Route-local components (rule-exempt here): `PageHeader` (h1 `text-xl font-bold tracking-[-0.02em]` + **preview marker**: mono muted `preview · sample data`, `data-slot="preview-marker"` — NO green dot, NO "live"), `CountSummary` (renders from `deriveAttentionSummary`; phone wording `3 wk · 3 you · 1 fail` `@3xl/feed:hidden` with its visible abbreviation `aria-hidden` and an **`sr-only` full phrase** ("3 working · 3 waiting on you · 1 failed") derived from the same summary; wide wording `3 working · 3 waiting on you · 1 failed · basalt offline` `hidden @3xl/feed:inline`; tinted numbers in own spans, decorative dots `aria-hidden`), `PriorityView`, `ByProjectView`, `ProjectPanelHeader` (h2 mono name + amber `{n} needs you` + right `● n working`/`● n failed`), `QuietProjectRow` (single-line `bg-card rounded-xl` row: name + `quiet — ✓ {verb} {age} ago, nothing needs you` + chevron), `TempLinks` (the kept utility row: muted mono `text-[0.6875rem]` links, same four labels, comment marking it slice-1-removable).

```tsx
<div className="@container/feed mx-auto w-full max-w-6xl pt-[18px] pb-6 md:px-5">
  <PageHeader />
  <Tabs defaultValue="priority" className="gap-0">
    <div className="flex items-center gap-1.5 px-[18px] pt-2.5 pb-3.5 md:px-0">
      <TabsList variant="pill" aria-label="Attention view">Priority / By project</TabsList>
      <CountSummary className="ml-auto" />
    </div>
    <TabsContent value="priority"><PriorityView /></TabsContent>
    <TabsContent value="by-project"><ByProjectView /></TabsContent>
  </Tabs>
  <p className="mt-3 hidden … @3xl/feed:block">Items never vanish silently — resolved checks off in place, storms collapse to one row.</p>
  <TempLinks />
</div>
```

**Toggle = Tabs with the new shared `pill` variant** (real tablist semantics, one roving tab stop; Base UI `Tab` renders `<button role="tab">`; hidden panel unmounts — `keepMounted` false). The tablist carries `aria-label="Attention view"` (WAI tabs pattern requires an accessible name — no visible label exists). The variant lives in `components/ui/tabs.tsx` at the existing CVA seam: inactive pill = bare `text-muted-foreground`; active = light: white card + `border-border` + `shadow-xs` (4c), dark: flat `bg-muted` (2a `#1b1b20`); keep the base focus-visible ring. Note: a future `shadcn add tabs/badge --overwrite` would drop the additive variants — `check` fails loudly on the usages, same recovery story as the badge `waiting` variant.

Views share everything: Priority = amber GroupPanel(h2 "NEEDS YOU · {n}") + view-owned EARLIER section wrapping a headerless neutral GroupPanel with hairline rows (`variant="row"`, `showProject`); ByProject = `groupByProject()` panels, all `variant="card"`, `showProject={false}`, quiet rollups. Wide by-project costs zero extra code — the `@3xl/feed:` classes ARE the transformation.

## 4. Responsive (named-container twins — happy-dom tests assert classes, matching shell precedent; no JS breakpoints)

- Page root declares **`@container/feed`**; **all anatomy flips at `@3xl/feed`** (container ≥ 48rem): meta composition (age in/out), needs-you trailing (chevron ↔ age chip + action), failed/done age text, resolved `· {age}` suffix, count-summary wording (+`basalt offline`), footer caption, row alignment (`items-start` → `items-center`).
- Viewport-based (chrome-aligned) only: outer gutters `px-[18px]` → `md:px-5` + inner `md:px-0`; ultra-wide `max-w-6xl` cap.
- **Defined layouts** (monotonic — a <768 viewport cannot host a ≥768px container): < 768 phone (2a/5e); 768–~1000 phone anatomy inside the rail shell (deliberate — pane ~532–780px); ≳ 1005 desk anatomy (pane content ≥ 48rem). Visual pass includes a **700px case** (no rail, still phone anatomy — proves no premature wide flash).

## 5. Tests

`attention.test.tsx` (renderAt pattern from shell.test.tsx: memory history + `MockedProvider mocks={[]}` — empty mocks doubles as the no-query proof; scope to `getByRole("main")`; never call `use*` outside components — `getAttentionData()` + `renderHook`):
1. Seam cross-check: `getAttentionData().items.filter(needsYou).length === useShellData().attentionCount` (via renderHook).
2. Pure derivations with **sentinel synthetic data** (never the public fixture): `deriveAttentionSummary` on e.g. 2 needs-you / 4 failed / `workingCount: 5` / two offline nodes returns `{5, 2, 4, [names]}` — proves derivation, not fixture echo; `groupByProject` order/tones/hoisting/workingCount `?? 0` (absent key ⇒ 0, no `undefined` leak); **resolved-only project ⇒ quiet**; **quiet project mixing done + resolved uses the FIRST terminal item's verb** (source order, defined not "newest").
3. Priority view: NEEDS YOU · 3 (derived), 3 needs-you titles, EARLIER, 4 rows; `feed-meta-phone` vs `feed-meta-desk` textContent (proves slot forwarding + composition).
4. **Structure roles**: h1 "Attention"; `getAllByRole("heading", { level: 2 })` covers NEEDS YOU/EARLIER (priority) and project names (by-project); `getAllByRole("list")` per section; row counts via `getAllByRole("listitem")`; **every `<ul>`'s element children are all `<li>`** (valid-markup pin for the hairline-divider approach); **no `<section>` lacking an accessible name** — assert over LITERAL elements: every `container.querySelectorAll("section")` node has an `aria-labelledby` that resolves to an existing element (an unnamed `<section>` maps to role `generic`, so a `getAllByRole("region")` sweep would silently skip exactly the bad nodes — pins decision 11).
5. Toggle: `getByRole("tablist", { name: "Attention view" })`; 2 tabs; click "By project" → project headings + quiet line appear, NEEDS YOU/EARLIER gone (panel unmounts); toggle back.
6. By-project meta drops the project prefix; header right-slots `2 working` / `1 failed`.
7. **Inert feed**: within the open `tabpanel`, zero `link`/`button` roles and no descendant `[tabindex]`; `Open gate →` is a SPAN with `closest("a,button") === null`; all `›` `aria-hidden`. (Temp links live OUTSIDE the tabpanel; assert they're still present in main with correct hrefs.)
8. **Preview honesty**: `preview · sample data` marker present; `queryByText("live")` null. **Summary accessibility**: the phone abbreviation is `aria-hidden` and the sr-only full phrase ("3 working · 3 waiting on you · 1 failed") is present (derived, matches the wide wording sans offline suffix).
9. Cluster row has `×12`, no chevron. Resolved row: `opacity-[.62]`, `· 3h` suffix classes, mono titleCode.
10. Glyph/status class mapping per kind; container-variant class pins (`@3xl/feed:hidden`/`hidden @3xl/feed:*` on metas, chips, action, caption, count summaries; `@container/feed` on the page root; `min-w-0 flex-1` body).
11. Basepath: temp links re-asserted under `basepath: "/argus/"` (they're the page's only hrefs).

`attention-seam.test.tsx` (own file — `vi.mock` hoists module-wide; shell-seam.test.tsx precedent): **PARTIAL mock via `importOriginal`** — unlike `shell-data.ts`, this module also exports `deriveAttentionSummary`/`groupByProject`/predicates that the rendered route still calls, so a full replacement would leave them `undefined`. Factory uses the **typed module-promise overload** (the string-path form types `importOriginal()` as `unknown`, so the spread would fail `tsc`): `vi.mock(import("./lib/attention-data.ts"), async (importOriginal) => ({ ...(await importOriginal()), getAttentionData: () => SENTINEL, useAttentionData: () => SENTINEL }))` with `SENTINEL` defined via `vi.hoisted` (e.g. 2 needs-you, 4 failed, workingCount 5) → rendered count summary (both wordings + sr-only phrase) and `NEEDS YOU · 2` reflect the seam, proving the components consume it (a hardcoded `3/3/1` would fail here).

`shell.test.tsx`: HREF_TABLE rows unchanged (labels kept); remove `/` from the stub-routes list (no longer StubPage) and its TEMP_LINKS block (attention.test.tsx owns those now). `router.test.tsx`: index test keeps heading assert + adds `tab` "Priority" pin; basepath test unchanged.

Reachability: unchanged — temp links keep `/runs`, `/board`, `/styleguide` phone-clickable until slice 1 provides real paths.

## 6. Order & verification

1. `attention-data.ts` (+ pure derivation tests red-first) →
2. **Invoke `design` skill** (shell-build precedent), then the tabs `pill` variant + badge color/size variants, then leaf-first components (`section-label` → `status-icon-chip` → `feed-chip` → `feed-action` → `meta-line` → `group-panel` → `feed-row`); `shadcn` skill for component workflow →
3. Screen rewrite phone-first against 2a/5e →
4. **Invoke `make-responsive`**; apply the `@3xl/feed` flips against 5a; sanity the derived wide by-project + the defined 768 layout →
5. Finish tests; edit shell/router tests →
6. Gate: `pnpm --dir ui codegen && pnpm --dir ui check && pnpm --dir ui test && pnpm --dir ui build` (all four, never piped; `routeTree.gen.ts` should NOT diff — route path unchanged) →
7. Visual pass: `pnpm --dir ui dev:mock` → `http://localhost:5173/argus/` at **390 / 700 / 768 / 1024 / 1280**, both views each (700 = no rail + phone anatomy; 768 = rail + phone anatomy; 1024 = just past the ~1005 container flip, desk anatomy engaged; 1280 = mock-true desk); light proof by removing `class="dark"` from `<html>` in devtools vs `#4c` (light-only set: active-pill white/border/shadow, card/panel `shadow-xs`, amber border `/35`). **Shared-primitive regression**: `/argus/styleguide` in BOTH themes, activating BOTH of its tabs — this change edits shared badge.tsx/tabs.tsx internals, and the smoke page must show the existing default Badge and Tabs treatments unchanged (additive variants only).

`mix precommit` unaffected (node-free); the UI gate is the gate of record.

## 7. Gotchas (carry into implementation)

- tailwind-merge variant-chain rule: unprefixed overrides silently lose to `group-data-*`/`dark:`/`@3xl/feed:` base classes — matching-prefix twins everywhere (the `pill`/badge variants largely sidestep this by living at the CVA seams).
- `@container/feed` is a REQUIREMENT of the feed components (FeedRow/CountSummary twins) — reuse sites must declare their own named container; document in component comments. If tooling unexpectedly fights named container variants (tailwind-merge/oxlint/happy-dom), fall back to viewport `lg:` and log in Deviations.
- Signature sizes stay mock-exact via arbitrary values — **font sizes in rem** (`text-[0.84375rem]` = 13.5px etc.), geometry px ok (`size-[26px]`, `py-[11px]`, `tracking-[0.08em]`, `opacity-[.62]`); `text-xs` where 12px is imperceptible; no new tokens this phase (values are placeholder-grade).
- Exact characters in fixtures/tests: `—`, ` · `, `›`, `◆`, `◌`, `×` (U+00D7), curly quotes.
- Split-text queries: tinted numbers/dots break `getByText` — assert via `data-slot` + `textContent`; decorative dots in own `aria-hidden` spans.
- `react/rules-of-hooks` is name-based and `error` — hence `getAttentionData()`; sentinel seam mocks live in their own test file (`vi.mock` hoisting).
- `only-export-components` ON for `components/feed/**` (maps stay private), OFF for routes and `components/ui/**`.
- Deviations from mock copy (title unification, resolved opacity .62 vs 5e's .8, MetaLine `truncate`, preview marker replacing "live", temp-links row) → log below.

## Non-goals

Empty/loading/error states (mock set defers them), URL view state, real navigation/actions, theme toggle, GraphQL/case schema, mock-scenario changes, 2b+ screens, virtualization.

## Deviations

(fill in as they happen — what the plan assumed, what the code revealed, what was chosen and why)

Implemented 2026-07-12. Plan-anticipated mock-copy deviations, confirmed as built:

- **Title unification per the fixture table** (desk copy wins): gate/question/alert/failed/done titles take the 5a phrasing; the idle cluster keeps the shorter 2a/5e phrasing ("Cron ticks skipped — basalt offline") — table-explicit, 5a's "overlap guard … collapsed incident" copy deliberately not adopted. Resolved title is 5a's "Approved —" (5e's "Approved earlier —" dropped).
- **Resolved row opacity `.62`** everywhere (5e's by-project card showed 0.8; 2a/5a's .62 unified).
- **`MetaLine` truncates** (`truncate`) where the mock has no overflow handling; at 390px the question card's meta and the quiet-argus line genuinely overflow the mock's own metrics and now clip with an ellipsis instead.
- **`preview · sample data` marker** replaces the mock's green-dot "live" indicator (settled decision 5 — fixture data ships in every build, so no live/health signal).
- **Temp-links row kept**, restyled as a muted mono utility row under the feed (settled decision 6); same four accessible names.

Forced/taste corrections discovered during implementation (one sensible path, taken and logged):

- **Pill toggle keeps `font-medium` in both states** — the mock flips 500→600 on the active pill, but the design guideline "never change font-weight between nav item states" also prevents real width wiggle on toggle; at 11.5px the delta is imperceptible. The active state is carried by the bg/border/shadow flip alone.
- **GroupPanel's labelled-section wiring is an explicit prop pair**: the plan said "`<section aria-labelledby>` (id wired to the header's h2)" without naming a mechanism; built as a discriminated `{ header, labelId }` pair (both or neither, type-enforced), with `SectionLabel`/`ProjectPanelHeader` taking the matching `id`. No magic cloneElement.
- **`quietLine` (`{verb, age}`) is computed by `groupByProject`** in the data module and carried on `ProjectGroup`, rather than re-derived in the component — keeps the "FIRST terminal item in source order" rule unit-testable next to its definition (the component just renders it; a `done`+`resolved` mix with a *newer* resolved item pins the rule in tests).
- **The EARLIER hairline recipe lives on FeedRow's `row` variant itself** (plan: "from its parent recipe — or nearest equivalent"): every `row`-variant use this phase is a hairline row, and baking it in keeps the reuse contract (Approvals/Threads) single-sourced.

Process notes: the `shadcn` skill's dynamic project probe failed on this repo's pnpm `devEngines` pin (`npx` under the hood); the edits proceeded on the `design` skill guidance + the plan-pinned CVA seams, verified by the styleguide regression screenshots (default Badge/Tabs treatments unchanged in both themes). Visual pass ran headless (playwright-core + system Chrome against `dev:mock`) at 390/700/768/1024/1280, both views, dark + light + styleguide — no console/page errors; 700px confirmed no premature wide flash, 768px confirmed phone anatomy inside the rail, 1024px confirmed the ~1005 container flip.
