# Argus componentize pass — roadmap step 5

## Context

Roadmap step 5, after Attention Feed 2a: "Run `componentize` after 2a — extract the argus composites once real usage has shaped their APIs. Subsequent screens consume them instead of re-deriving." The 2a commit already extracted most of the vocabulary into `ui/src/components/feed/` (GroupPanel, FeedRow, MetaLine, FeedChip, StatusIconChip, SectionLabel, FeedAction); this pass consolidates the home, extracts what's still inline or missing, and gives zero-consumer pieces a rendered spec sheet — so Approvals (2b) starts by composing, not deriving.

**Operator decisions (locked):**
1. Scope: componentize only — no new screens.
2. All cross-screen vocabulary consolidates into **one folder: `ui/src/components/system/`** (`components/feed/` dissolves into it).
3. `/styleguide` becomes a composite **spec sheet** rendering every system/ piece (DecisionCard and the StatusDot vocabulary have no consuming screen until 2b/2c).
4. DecisionCard **shell** is in scope (chrome + slots from mock evidence). The version chip (`v2 · you`) is **deferred** to the gate screens.

Roadmap-name → reality mapping: StatusDot → **new**; AttentionPanel → GroupPanel (move); ListRow → FeedRow (move); MetaLine → MetaLine (move); CountChip → FeedChip (move); DecisionCard shell → **new**. Plus one extraction the duplication scan justifies today: **Chevron** (private in feed-row.tsx + hand-copied in QuietProjectRow — two real sites). PageHeader/PreviewMarker stay route-local (one real consumer each — a spec-sheet demo is not a second real site; see ledger).

**`components/system/` folder rule**: presentational only — props in; may import types and pure derivations from `lib/`, never the `use*` data-seam hooks, never `@apollo/client`, never `@/mocks`. **Machine-guarded** by a checked-in architecture test (`ui/src/system-boundary.test.ts`, below), not just prose. Design-only phase: everything stays inert — no focusable control that does nothing (FeedAction precedent).

Skills that drive the work: `componentize` (invoke at start — its workflow frames steps 1–2 and the re-scan), `canonicalize-tailwind` (hygiene step, scoped). The latter shells out to `npx @tailwindcss/cli canonicalize`, so **`@tailwindcss/cli` 4.3.2 gets pinned as a `ui/` devDependency in commit 2** (operator-approved; matches the installed tailwindcss 4.3.x; dev-only tool — build output unaffected).

## Commit 1 — mechanical dissolve (zero behavior change)

1. `git mv` all seven files `ui/src/components/feed/*.tsx` → `ui/src/components/system/*.tsx` (names unchanged — the 2a names won; roadmap names were provisional). **Plus `ui/src/components/nav-badge.tsx` → `ui/src/components/system/nav-badge.tsx`** — NavBadge is cross-screen count vocabulary (the roadmap's CountChip family, consumed by both nav chromes), so the locked one-folder rule covers it; NodeHealth/StubPage stay at root (app chrome / dying placeholder, not vocabulary).
2. Update the only importers — five lines total: three in `ui/src/routes/_shell/index.tsx:2-4` (`@/components/feed/*` → `@/components/system/*`), one each in `app-sidebar.tsx` and `tab-bar.tsx` (`@/components/nav-badge` → `@/components/system/nav-badge`). feed-row's internal imports are relative and survive; tests import only `lib/` + router — zero test churn (verified by grep).
3. **Keep the container name `@container/feed` / `@3xl/feed`.** It names the component family's container contract, not the Attention page; renaming would churn ~10 pinned class-string assertions (attention.test.tsx:456-496) for zero behavior. The styleguide becomes a second declarer, proving host-portability.
4. Gate green with `attention.test.tsx` / `shell.test.tsx` passing **unchanged** — that is the preservation proof.

Commit: `refactor: dissolve components/feed into components/system (argus vocabulary home)`.

## Commit 2 — new vocabulary + spec sheet

### New components (all: kebab-case file, named function export, `data-slot`, className merged via `cn()`, no baked margins, token-pure — no hex/oklch literals)

**`system/status-dot.tsx`** — the round presence dot (distinct from StatusIconChip, the square glyph tile; both stay).
```ts
type StatusDotStatus =
  | "working" | "waiting" | "failed" | "done" | "online"
  | "idle" | "blocked" | "unknown" | "offline";
function StatusDot({ status, size = "md", className }: { status: StatusDotStatus; size?: "sm" | "md"; className?: string })
```
- `<span aria-hidden="true" data-slot="status-dot" data-status={status}>`, base `inline-block shrink-0 rounded-full`, `md` = `size-2` (8px, rows/tables), `sm` = `size-1.5` (6px, rail/inline).
- Module-private literal class map (Tailwind-scanner precedent from status-icon-chip.tsx), **mock-verified state model** (threads table 469-517 / 2c 956-1001):
  - `working` — violet fill + glow (mock 469: `background:oklch(72% 0.19 293);box-shadow:0 0 8px …/.8`)
  - `waiting` — amber fill; `failed` — red fill; `done` — green fill (lifecycle completion, quiet)
  - `online` — **semantic alias sharing done's green fill recipe** (`bg-status-done`; no new token — the mock budgets one all-quiet green). Exists so connectivity dots read honestly in `data-status` selectors instead of conflating connectivity with lifecycle completion.
  - `idle` — **dim fill**, not hollow (mock 509/992: `background:#3a3a42`): `bg-status-idle/55`, alpha tuned at implementation against the mock hex (token is oklch 0.62 dark; the /55 composite over the dark bg lands ≈ 0.35).
  - `blocked` — **hollow solid** (mock 485, the `blocked · deps` row: `border:1.5px solid #6a6a74`): `border-status-idle/<alpha>` — same hue family, but the unmodified token is materially brighter than the mock (dark `--status-idle` is oklch 0.62 vs `#6a6a74` ≈ 0.53), so the border alpha is **tuned at implementation** against the mock alongside the idle-fill tuning.
  - `unknown` — **hollow dashed** (mock 517/1001: `1.5px dashed #55555e`): `border-dashed border-status-offline` (verified index.css:169; row-level opacity is the host's job).
  - `offline` — hollow solid dim (rail 183: `1px solid #55555e`): `border-status-offline`.
  - Hollow border width is size-proportional (mock: 1.5px @ 8px, 1px @ 6px).
- `blocked` ships NOW: Threads (2c) is the imminent consumer and its table renders all of idle/blocked/unknown — deferring it guarantees immediate API/test churn.
- **Glow (token-pure, no new token):** try `shadow-[0_0_8px] shadow-status-working/80` (Tailwind v4 shadow-color composition); verify visually in the dev styleguide BEFORE pinning in tests; fallback `shadow-[0_0_8px_var(--status-working)]`.
- No `live`/`editing` union members. Doc-comment pins the connection-vs-activity mapping (mock-verified): **glow-less green `online`** marks a live connection/view and healthy nodes — the header/rail "live" labels (mock 49/189/644/1434, all the green hue, no shadow) and node dots; **`done`** marks quiet lifecycle completion; the **glowing violet `working`** dot marks live *activity* — "working" labels, threads-table active rows, the transcript's "editing src/… · 2m" indicators, and the Kanban card's "thread live" badge (mock 469/538/573/1080/1735 — 1735 is violet + glow despite the word "live"). The word "live" alone doesn't pick the status; connection vs activity does.
- Consolidations: **NodeHealth** dots (node-health.tsx:15-22 — swap to `status="online"`/`status="offline"` `size="sm"`; rendered classes stay byte-equal to today since online borrows done's recipe); **styleguide swatch dots** (replaced by the vocabulary row). Deliberately NOT consolidated: index.tsx `"● "` text glyphs (mock 5e itself uses literal glyphs there; pinned by tests), app-sidebar brand dot (brand mark, not status).

**FeedRow `className`** — add the optional merged `className` prop (onto the `<li>`, after the variant classes) that the componentize skill requires on every component; FeedRow is the sole migrated piece lacking it. Additive — existing `toContain` pins unaffected.

**NavBadge un-bake `ml-auto`** — nav-badge.tsx:15 bakes call-site placement (the tab-bar caller compensates with `ml-0`), contradicting the no-baked-margins rule. Remove it from the base; the rail passes `className="ml-auto"` (app-sidebar.tsx:77), the tab-bar drops its compensating `ml-0` (tab-bar.tsx:114). Rendered result identical at both sites (twMerge already collapses the pair today).

**`system/chevron.tsx`** — extract feed-row.tsx's private `Chevron` (lines 200-210) verbatim; keep `data-slot="feed-chevron"` (test-pinned). Migrate both call sites: feed-row.tsx (delete private copy) and QuietProjectRow's hand-copied span (index.tsx:242-248, passes `text-muted-foreground/60`; gains a visually-inert `self-center`).

**`system/decision-card.tsx`** — the shell only, synthesized from all five mock variants (2b:754-796 approve/question/compact-gate, 4a:870-896 irreversible/expired, 5b desk):
```ts
function DecisionCard({ tone = "amber", icon, title, labelId, meta, trailing, className, children }: {
  tone?: "amber" | "muted"; icon?: ReactNode; title: ReactNode; labelId?: string;
  meta?: readonly string[]; trailing?: ReactNode; className?: string; children?: ReactNode })
```
- **A11y contract mirrors GroupPanel's labelled-section precedent** (group-panel.tsx:4): with `labelId` the card renders `<article aria-labelledby={labelId}>`; without it, a plain `<div>`. The **call site owns heading semantics** — it passes a heading element (`<h2>`/`<h3>`) carrying `id={labelId}` as `title` (2b picks levels when it wraps cards in `<li>`s); the card owns typography via its title wrapper (preflight makes headings inherit). Spec-sheet demos pass `h3` + ids; tests assert `getByRole("article", { name })`.
- Chrome (invariant across variants): `rounded-[14px] border p-[13px] flex flex-col gap-[11px]`; amber tone `border-status-waiting/30` (dark, mock-exact) / `/45` light (derived from GroupPanel's light:dark ratio — no 4c evidence, retune in the light check) + `bg-card shadow-xs dark:shadow-none`; muted tone (4a expired) = `border-dashed bg-card/60 text-muted-foreground`, no shadow. 14px radius is deliberate mock anatomy between `lg` and `xl` — don't bend onto the scale.
- Header row (`data-slot="decision-card-header"`): icon slot (call sites compose `StatusIconChip` — its pre-staged colorways cover all five mock tiles: ex→working, ?/◆→waiting, !→failed, exp→idle) + title/MetaLine stack + trailing slot (FeedChip age pill / Chevron / dismiss chip).
- Everything below the header is **slotted `children`** (command preview, scope chips, note field, reply row, action rows) — owned by 2b, which passes real Button/Input later. Shell renders no focusable control, no href/onClick. Irreversible = amber tone + red icon + slotted notice (mock keeps the amber border).

### NOT extracted this pass (violates the ≥2-real-site rule)

**PageHeader and PreviewMarker stay route-local in index.tsx** — one real consumer each; a spec-sheet demo is not a second real usage site. The preview wording is page state, not system vocabulary. Extract both when Approvals (2b) creates the second real header. index.tsx is otherwise untouched beyond the three import lines and the QuietProjectRow chevron swap.

### Spec sheet — restructure `routes/_shell/styleguide.tsx`

Top-to-bottom sections (drop the two-tab wrapper; headings via `SectionLabel` `h2`s under the single pinned h1 "argus" — shell.test.tsx:240; keep the two existing top links; stays out of nav). Page root `max-w-4xl` and **declares `@container/feed`** so FeedRow demos flip live.
1. **StatusDot vocabulary** — all 9 statuses × both sizes; labels colored `text-status-*` for tokened statuses, with recipe-borrowers labeled by their borrowed token (`online` → `text-status-done`, `blocked` → `text-status-idle`, `unknown` → `text-status-offline` — `text-status-unknown`/`-online`/`-blocked` do not exist). Keeps scanner anchors; replaces the old filled swatches which mis-rendered idle/offline. Plus a **composed-indicators row** demoing connection-vs-activity: `live` = `online` sm dot + mono label (header/rail form), `thread live` and `editing …` = `working` sm dot with glow + mono label (mock 1735/573).
2. **StatusIconChip** — status × size × outline table incl. pre-staged working/offline colorways.
3. **Chips** — FeedChip tones, NavBadge, Badge argus variants.
4. **GroupPanel tones** — real GroupPanel amber + neutral wrapping real FeedRows (deletes the hand-rolled amber recipe, styleguide.tsx:63-74 — real dedup).
5. **FeedRow variants** — card + row sets across the seven kinds.
6. **DecisionCard shell** — all five variants with inert demo content (styled spans, FeedAction-precedent; route-local `DemoAction` helper is fine — routes exempt from only-export-components).
7. **Controls** — existing Button/Badge demos kept as-is (pre-existing focusable-demo precedent; not extended).

Inline demo literals are deliberately OK here (header comment: the sheet's literals ARE the spec; the "no literals in components" rule governs screens fed by `lib/` seams).

### Re-scan + hygiene

- Componentize skill step 5: sweep `system/*` + touched routes for residual duplication; extract only ≥2-real-site repeats. Expected ledger (noted, NOT extracted — one real site each): **PageHeader + PreviewMarker** (extract when 2b makes headers n=2), page-root wrapper (PageShell when n=2), muted micro-caption, colored-count text runs, inline mono ref-in-title (`InlineRef` when 2b consumes it), FeedAction tone axis, StubPage h1.
- **Pin the canonicalizer**: `pnpm --dir ui add -D @tailwindcss/cli@4.3.2` (updates `ui/package.json` + `pnpm-lock.yaml`; the one network-touching step, done once). Then invoke the `canonicalize-tailwind` skill, which runs `npx @tailwindcss/cli canonicalize --css src/index.css` **with `ui/` as the working directory** (both assumptions hold only there: the relative CSS path resolves, and npx finds the locally pinned CLI instead of downloading again from the repo root), **feeding the newly authored class strings as the candidates** — one per line on stdin with `--format jsonl` (or quoted positional args), since `--css` supplies only the design-system context and a candidate-less run is a no-op. Apply back only entries returned `changed: true`; skip any string the tool can't resolve rather than accepting a mangled rewrite; results verified by the existing gate (`vp check` + tests). Never on moved files (their strings are test-pinned); revert rewrites that break house parity (arbitrary-px style like `size-[30px]`, `rounded-[14px]`).

### Tests (written after canonicalize so pins capture final strings)

- **Invariant:** every existing assertion in attention.test.tsx (byte-unchanged) and shell.test.tsx passes through both commits.
- **Additive in shell.test.tsx:** NodeHealth→StatusDot integration — each online node row has exactly one `[data-slot="status-dot"][data-status="online"]` (sm, green fill recipe), basalt one `data-status="offline"` (`border-status-offline`), all `aria-hidden`.
- **New `ui/src/system-boundary.test.ts`** — the checked-in guard for the folder rule, enforcing **"props in" via an allowlist, not a hook-name denylist** (a denylist admits the `getAttentionData()` fixture getter, `@/hooks` data hooks, and Apollo subpaths like `@apollo/client/react`). Contract, applied to **every `.ts`/`.tsx` file under `src/components/system/` recursively** (top-level-only globbing would let a permitted relative import reach an unscanned `system/data.ts`): **rule order matters — forbidden sources reject first**: any import from the `@apollo/client` or `@/mocks` prefixes (subpaths included) fails outright, `import type` included — a type-only exemption applied first would wave the forbidden coupling through. Only then the type-only exemption applies, and only for permitted sources (`react`, relative system siblings `./*`, `@/components/ui/*`, `@/lib/*`); value imports are allowed only from `react`, relative siblings, `@/components/ui/*`, and an explicit named allowlist from `@/lib/*` — currently exactly `cn` (`@/lib/utils`) and `needsYou` (`@/lib/attention-data`), checked by **imported (source-side) name** so aliasing can't slip through; any other project value import (`@/lib/*`, `@/hooks/*`) fails. Implemented as a **bespoke statement-level import scanner, chosen explicitly** — the installed TypeScript 7 devDep exposes only version metadata at its package root (compiler/AST APIs sit behind unstable subpath exports), so no conditional AST path: one deterministic parser, unit-tested in-file before the sweep. Its test matrix covers every import form: multiline named imports, mixed type/value specifiers (`import { type A, b }`), default imports, namespace imports (`import * as x`), side-effect imports (`import "./styles.css"`), dynamic `import("...")` expressions, and `export … from` re-exports (which re-expose just like imports) — plus the semantic positives (`import { useId } from "react"`, `import type { AttentionItem } from "@/lib/attention-data"`) and negatives (`import { useShellData as data } from "@/lib/shell-data"`, `import { getAttentionData } from "@/lib/attention-data"`, `import { useQuery } from "@apollo/client/react"`, `import type { ApolloClient } from "@apollo/client"` — type-only does NOT exempt forbidden sources). Self-maintaining as files are added; growing the lib allowlist is a deliberate, reviewed act.
- **New `ui/src/styleguide.test.tsx`** — **provider-less render** (router.test.tsx:6 precedent — no Apollo provider at all, so any Apollo usage throws; `MockedProvider mocks={[]}` still supplies a client and lets async query errors slip). This is a **no-Apollo guard only** — static fixture seams like `useShellData` would render fine provider-less; the data-seam boundary is enforced by `system-boundary.test.ts` above. Assertions: StatusDot vocabulary table (all 9 statuses: recipe classes incl. idle-fill vs blocked-hollow vs unknown-dashed, sizes, hollow-width split, glow pin post-visual-verify); composed-indicators pins (`live` demo dot is `data-status="online"` with no glow class; `thread live`/`editing` demo dots are `data-status="working"` with glow classes); DecisionCard chrome per tone + `getByRole("article", { name })` via labelId + meta→MetaLine + trailing slot; DecisionCard inertness scoped to cards — within each card, zero matches for the full focusable set: `a[href]`, `button`, `input`, `select`, `textarea`, `summary`, `[tabindex]`, `[contenteditable]` (the Controls section legitimately has Buttons, hence the per-card scoping); spec-sheet structure (one h1, sections present, root declares `@container/feed`); `/argus/styleguide` basepath smoke.

Commit: `feat: argus componentize pass — StatusDot, DecisionCard shell, Chevron + composite styleguide`.

## Files touched

- Moves: `ui/src/components/feed/{feed-action,feed-chip,feed-row,group-panel,meta-line,section-label,status-icon-chip}.tsx` + `ui/src/components/nav-badge.tsx` → `ui/src/components/system/`
- New: `ui/src/components/system/{status-dot,chevron,decision-card}.tsx`, `ui/src/styleguide.test.tsx`, `ui/src/system-boundary.test.ts`
- Edits: `ui/src/routes/_shell/index.tsx` (3 import lines; QuietProjectRow chevron swap), `ui/src/components/{app-sidebar,tab-bar}.tsx` (1 import line each + NavBadge placement classes), `ui/src/routes/_shell/styleguide.tsx` (spec-sheet restructure), `ui/src/components/node-health.tsx` (StatusDot swap), `ui/src/components/feed→system/feed-row.tsx` (private Chevron deleted, imports shared one, gains `className`), `ui/package.json` + `ui/pnpm-lock.yaml` (`@tailwindcss/cli@4.3.2` devDependency)
- Untouched: `src/mocks/**`, `schema.graphql`, `codegen.ts`, `src/gql/**`, graphql documents, `components/ui/**`, all `lib/` seams, `attention.test.tsx`, index.tsx's local PageHeader/CountSummary/PreviewMarker

## Verification

1. Full UI gate after each commit, run directly, never piped: `pnpm --dir ui codegen` && `pnpm --dir ui check` && `pnpm --dir ui test` && `pnpm --dir ui build` — all four; report exit codes + test counts verbatim.
2. Working-glow visual check on the dev styleguide (`pnpm --dir ui dev` → `/argus/styleguide`) before its class string is test-pinned; idle-fill alpha tuned vs mock `#3a3a42` in the same pass.
3. Manual visual pass: dark spec sheet vs mocks 2b/4a/5b (DecisionCard variants, muted `bg-card/60` vs 4a's `#101012`, glow) and the threads-table dots vs 5c (idle/blocked/unknown); then remove `class="dark"` from `<html>` in devtools and compare vs 4c (amber borders, white cards + shadow-xs, status hues, the judgment-call `/45` light border).
4. `mix precommit` once at the end as the repo belt (node-free — should be untouched-green).

## Known tensions (flagged, resolved as stated)

- **DecisionCard light theme has no mock evidence** (no decision card in 4c) — `/45` amber and `bg-card/60` muted are derivations; retune in the light check, never relitigate the mock-exact dark values.
- **Glow class form** depends on Tailwind v4 colorless-arbitrary-shadow + shadow-color composition — verified visually before pinned; token-pure fallback specified.
- **`online` borrows done's recipe by design** (one all-quiet green; no `--status-online` token) — the `data-status` attribute carries the semantic distinction; if a future screen needs the greens to diverge, that's a deliberate token addition then.

## Deviations

(Record as they happen, per AGENTS.md conventions.)

- **Idle fill alpha is `/35`, not the provisional `/55`; blocked border is `/75`** (forced correction, plan-authorized tuning). Computed sRGB→OKLab compositing of the dark `--status-idle` token over the mock's card background: `/35` lands `#3b3b40` vs mock `#3a3a42` (the plan's `/55` would land ≈`#525257`, visibly brighter); `/75` border lands `#69696f` vs mock `#6a6a74`. Both pinned in styleguide.test.tsx.
- **Glow verified via emitted CSS, not a browser pass** (forced: no browser in the implementing environment). Built output proves the composition: `shadow-[0_0_8px]` emits `--tw-shadow: 0 0 8px var(--tw-shadow-color, currentcolor)` and `shadow-status-working/80` sets `--tw-shadow-color: color-mix(in oklab, var(--status-working) 80%, transparent)` — exactly the mock's `0 0 8px oklch(72% 0.19 293 / .8)`. Primary form ships; fallback unused. The operator's dev-styleguide visual pass (verification #2/#3) remains open.
- **`ui/pnpm-workspace.yaml` gains `allowBuilds: "@parcel/watcher": false`** (forced: unanticipated). Pinning `@tailwindcss/cli` pulls `@parcel/watcher` as a transitive optional dep whose native build script pnpm refuses to run without an explicit decision — and then hard-fails every subsequent `pnpm` invocation until one is recorded. `false` is deliberate: the native watcher only serves `--watch`, which we never run.
- **Boundary sweep reads files via `import.meta.glob(..., ?raw)`, not `node:fs`** (forced: `tsconfig.app.json` pins `types: ["vite/client"]` — deliberately node-free; adding ambient node types for one test would leak `process` etc. into every app module). The recursive glob satisfies the same "every `.ts`/`.tsx` under `system/` recursively" contract and stays self-maintaining.
- **Canonicalizer applied two rewrites** out of 46 newly-authored candidate strings: NavBadge's base string reordered (`leading-none` before `font-bold`) and the styleguide question demo's `leading-[1.5]` → `leading-normal`. Everything else returned `changed: false`; no house-parity reverts needed.
- **Units land uncommitted** (operator correction): the plan's "Commit 1/2" headings are unit boundaries, not commit authorization — unit 1 was committed, undone by the operator, and both units now sit together in the working tree for the operator to review and commit.
- **Re-scan ledger confirmed as predicted** — no new ≥2-real-site duplication after extraction; PageHeader/PreviewMarker, page-root wrapper (PageShell), muted micro-caption, colored-count text runs, inline mono ref-in-title (InlineRef), FeedAction tone axis, and StubPage h1 all remain single-real-site, deferred to 2b+.
