# Post-review remediation — Approvals (2b)

## Context

The Approvals (2b) implementation (plan `please-read-docs-plans-argus-ui-roadmap-jaunty-squid.md`) went through external code review. The review reported six findings — four P2, two P3 — and passed everything else (214-test gate, check, build, interaction walkthrough, light theme, phone layouts). All six findings were independently verified against the working tree and **all six are confirmed**. This plan fixes all of them. No invalid-findings section is needed.

| # | Finding | Verdict | Evidence |
|---|---|---|---|
| 1 | P2 — provider + store share one module; lint override masks an invalid Fast Refresh boundary | Confirmed | `ui/vite.config.ts:92-100` silences `react/only-export-components` for `approvals-local-state.tsx`, which exports the provider component (line 440) beside `createApprovalsStore`, the context, selectors, and hooks. Editing the file re-runs `createContext` under HMR → consumers throw "requires ApprovalsLocalStateProvider" |
| 2 | P2 — stale zero badge masquerades as healthy zero | Confirmed | `approvals-nav-badge.tsx:32` returns `null` on `pendingLeft === 0` **before** the `status === "error"` branch at line 33; error + retained zero baseline renders nothing, identical to healthy zero |
| 3 | P2 — recovery-less (tombstone) errors bypass the live status region | Confirmed | `approvals.tsx:572` (`decisionStatusContent`) returns `null` for tombstone; the failure copy renders in `DecisionTombstone`'s plain `<p>` (line 506) outside the always-mounted `role="status"` node — no AT announcement when the controls unmount |
| 4 | P2 — literal NUL byte in TypeScript source | Confirmed | `approvals-data.ts` `createFetchMoreGuard`'s `cursorKey` embeds a raw `0x00` as the null-cursor sentinel; `file` classifies the source as `data`, `rg` treats all 769 lines as binary. Only NUL in `src/` |
| 5 | P3 — `resolved` tone gets the expired-card styling | Confirmed | `decision-card.tsx:59-61` branches only on `amber`; `resolved` falls into `border-dashed bg-card/60 text-muted-foreground`, contradicting the component's own documented contract (lines 26-29: solid `border-border` + full `bg-card`, no dash, no opacity) |
| 6 | P3 — backend-needs doc cites wrong run_command.ex lines | Confirmed | `argus-backend-needs.md:75` cites `:30` (that's `output_schema:`); the params schema begins at `run_command.ex:34`. `argus-backend-needs.md:162` cites `:91,119`; the sandbox read from `tool_context` is at `:97`, the context-before-params workspace resolution at `:123` |

Findings 1–5 are UI-internal (matching the review's architecture verdict); finding 6 is a docs-only correction.

## Fix 1 — split the provider from the store module

**Files:** `ui/src/lib/approvals-local-state.tsx` (rename → `.ts`), new `ui/src/lib/approvals-local-state-provider.tsx`, `ui/vite.config.ts`, `ui/src/routes/__root.tsx`, `ui/src/approvals.test.tsx`, `ui/src/approvals-seam.test.tsx`

1. Rename `approvals-local-state.tsx` → **`approvals-local-state.ts`** and remove the provider component from it. Everything else stays: types, pure selectors, `createApprovalsStore`, `ApprovalsStoreContext` (now **exported**, with a comment marking it provider-wiring-only), `useApprovalsStore`, and all consumer hooks. After the provider leaves, the module contains no JSX, so `.ts` is honest and the file is no longer a (broken) Fast Refresh boundary at all. Drop every import the move orphans — `ReactNode`, `useEffect`, `useRef`, and `useApprovalsSummaryData` (used only by the provider; `noUnusedLocals` fails the strict build otherwise). `ApprovalsSummarySeamResult` stays: `createApprovalsStore`'s parameter still needs it.
2. New **`approvals-local-state-provider.tsx`** exporting ONLY `ApprovalsLocalStateProvider` — the exact current body (seam result via `useApprovalsSummaryData()` imported from `./approvals-data`, `useRef`-created store, `acceptSummaryResult` effect, `<ApprovalsStoreContext.Provider>`). A component-only module is a valid Fast Refresh boundary; the file needs no lint override.
3. **Delete the second `overrides` entry in `vite.config.ts` (lines 92-100)** — the override was masking the real boundary violation. The first entry (`src/routes/**`, `src/components/ui/**`) stays.
4. Update the importers. The test files use **explicit-extension specifiers**, so the rename touches them even where the imported names don't move:
   - `__root.tsx:2` (extension-less alias): import `ApprovalsLocalStateProvider` from `@/lib/approvals-local-state-provider`.
   - `approvals.test.tsx:33-45`: split the single import — `ApprovalsLocalStateProvider` from `./lib/approvals-local-state-provider.tsx`, everything else (`createApprovalsStore`, selectors, hooks, types) from `./lib/approvals-local-state.ts`.
   - `approvals-seam.test.tsx:18`: `./lib/approvals-local-state.tsx` → `./lib/approvals-local-state.ts` (type-only import, path change only).
5. Retarget the two doc comments in `approvals-data.ts` that name the old filename (`approvals-local-state.tsx` at lines 354 and 407) to the extensionless module name `approvals-local-state`, so the producer/acknowledgement guidance survives the rename. (The reference at `approvals.tsx:67` is already extensionless — no change.)

Proof — lint alone is NOT it: `react/only-export-components` is configured **warn-level** (vite.config.ts:65), so lint's exit code passes even with a regression. Two checks instead:

- **Lint, warnings denied**: run a one-off `pnpm --dir ui lint -- --deny-warnings` (oxlint's flag; if `vp` doesn't pass it through, inspect the lint output and require zero `react/only-export-components` diagnostics). The committed lint script is not changed — the override removal plus this check is the static half.
- **Fast Refresh smoke test** (the failure mode the review actually observed) — see the browser spot checks in Verification.

The full existing suite exercises provider + hooks through the new module layout.

## Fix 2 — stale zero must not render as healthy zero

**Files:** `ui/src/components/approvals-nav-badge.tsx`, `ui/src/approvals-seam.test.tsx`

Reorder `ApprovalsNavBadge` so the error state is handled before the zero early-return. Target logic when `summary !== undefined`:

- `status === "error" && summary.pendingLeft === 0` → render the existing `approvals-nav-unavailable` "—" marker (same face as error-with-no-baseline). Rationale, derivable from the component's own doctrine: "a 0 pill is noise" and "a summary outage must never masquerade as a healthy zero" — a zero baseline that failed to refresh carries no trustworthy signal, so the honest face is *unavailable*, not a muted "0 — may be stale" pill.
- `status === "error" && pendingLeft > 0` → the current `data-stale` muted badge (unchanged).
- healthy `pendingLeft === 0` → `null` (unchanged — absence stays the honest healthy zero).

Update the component's header comment: the four-state list becomes five (split the "—" marker state into no-baseline and stale-zero-baseline arms).

**New seam test** beside the existing stale-badge test (`approvals-seam.test.tsx:732`): `seam.set({ summary: summaryResult(summaryOf([]), "error") })`, render `/`, assert both bars show the `approvals-nav-unavailable` marker (accessible name "Approvals unavailable", `toHaveLength(2)`) and no `data-stale` badge — i.e. the stale zero is visibly distinguishable from the healthy-zero absence.

## Fix 3 — tombstone copy announces through the status region

**Files:** `ui/src/routes/_shell/approvals.tsx`, `ui/src/approvals.test.tsx`

1. `decisionStatusContent` (approvals.tsx:567): delete the tombstone early-return (`if (flags.tombstone) return null;`) and let the tombstone state fall through to the existing `flags.error !== undefined` arm, which appends the tombstone suffix:

   ```ts
   if (flags.error !== undefined) {
     if (flags.reconcile) { /* unchanged */ }
     const base = `couldn't ${flags.error.action} — ${flags.error.code}`;
     return flags.tombstone ? `${base}; this case no longer exists server-side` : base;
   }
   ```

   The copy dereferences `flags.error` only inside its own `!== undefined` narrowing (`flags.tombstone` alone would not narrow it — `decisionFlags` returns the fields independently), and the non-tombstone error copy stays byte-identical. It renders inside the always-mounted `DecisionResolution` `role="status"` node, whose filled styling (`font-mono text-[0.71875rem] text-muted-foreground`) matches the tombstone `<p>`'s current classes — announced by AT when the state lands, and looks the same.
2. `DecisionTombstone` (approvals.tsx:498) shrinks to just the Dismiss row: props become `{ onDismiss }` only, the copy `<p>` is deleted, the `data-slot="decision-tombstone"` attribute stays, and the row class becomes `flex justify-end` — the deleted `flex-1` copy was what pushed Dismiss to the trailing edge, so the row must keep that alignment explicitly in both card variants. **Delete the now-orphaned `DecisionError` alias at approvals.tsx:416** — the tombstone prop was its last use, and `noUnusedLocals` fails on it. Update the component comment: copy lives in the status region; this component is only the separate recovery control.
3. At both render sites (`ToolCallCard` ~line 825 and the question card ~line 1112), move the tombstone block **after** `<DecisionResolution>` so reading order is copy-then-Dismiss.
4. Extend the existing test `"recovery-less error renders the dismissible tombstone — Dismiss is the only focusable"` (approvals.test.tsx:1310) — and, since this test is the sole replacement for browser verification of the tombstone, exercise **both card variants** (render `QuestionCard` in a tombstone decision state alongside `ToolCallCard` — both render sites move in step 3, so both need the pin) with **realistic, distinct actions**: `action: "approve"` for the tool card, `action: "reply"` for the question card (a question fails reply/reject, never approve — and the split doubles as proof the copy stays action-derived). For each card assert: the only-focusable invariant (kept), `[data-slot="decision-resolution"]` (the `role="status"` node) contains `couldn't approve — not_found; this case no longer exists server-side` (tool card) / `couldn't reply — not_found; this case no longer exists server-side` (question card), the Dismiss button is NOT inside that node, the `[data-slot="decision-tombstone"]` row carries the `justify-end` trailing-edge alignment, and the **reading order**: the status node precedes the tombstone row in the DOM — `status.compareDocumentPosition(tombstoneRow) & Node.DOCUMENT_POSITION_FOLLOWING` is truthy (containment + alignment alone would still pass with an unmoved tombstone-before-status site). No other test pins the tombstone slot or asserts an empty status region in the tombstone state (verified: the empty-region assertion at approvals.test.tsx:910 is the pending state).

## Fix 4 — remove the literal NUL byte

**File:** `ui/src/lib/approvals-data.ts` (`createFetchMoreGuard`'s `cursorKey`)

Replace the raw-`0x00` sentinel with a structurally distinct key — no sentinel character at all:

```ts
const cursorKey = (gen: number, after: string | null) =>
  after === null ? String(gen) : `${String(gen)}:${after}`;
```

A null-cursor key never contains `:` after the generation, so it can never collide with any real cursor (including `""` → `"3:"` ≠ `"3"`). Behavior is otherwise identical; the existing generation-fence and cursor-suppression tests (approvals-seam.test.tsx:923 et al.) cover it unchanged. Verify `file src/lib/approvals-data.ts` reports text and `rg` matches lines again. (Confirmed this is the only NUL anywhere in `ui/src`.)

## Fix 5 — give `resolved` its documented face

**Files:** `ui/src/components/system/decision-card.tsx`, `ui/src/approvals.test.tsx`

Replace the two-way ternary at decision-card.tsx:59 with a three-way tone map:

- `amber` — unchanged (`border-status-waiting/45 bg-card shadow-xs dark:border-status-waiting/30 dark:shadow-none`)
- `muted` — unchanged (`border-dashed bg-card/60 text-muted-foreground`)
- `resolved` — `border-border bg-card`: solid neutral border and full surface in both modes, no dash, no opacity, no card-level foreground muting (the header comment's exact contract). Dropping the card-level `text-muted-foreground` is safe and intended: both ToolCallCard (approvals.tsx:700-705) and the question card (line ~1036) already apply their own muted title classes when resolved, and MetaLine/DecisionResolution carry their own muted styling.

Tests: `data-tone="resolved"` is already pinned (approvals.test.tsx:986, 1006). In the ToolCallCard resolved test (~986), add class assertions on the card element's own `className`: it contains `border-border` and `bg-card`, and contains NONE of the three expired-state classes — `border-dashed`, `bg-card/60`, or `text-muted-foreground` (the card element only; resolved children legitimately mute themselves). Styleguide tests are unaffected (they filter `amber`/`muted` only; no resolved demo exists).

## Fix 6 — correct the backend-needs evidence citations

**File:** `docs/plans/argus-ui-roadmap/argus-backend-needs.md` (docs-only)

- Line 75: `lib/jido_claw/tools/run_command.ex:30` → `:52,57,63` — the actual declaration lines of `workspace_id`/`backend`/`server` inside the params schema (line 30 is `output_schema:`; the review's suggested `:34` is only the `schema: [` opener, so the citation points at the declarations themselves).
- Line 162: `lib/jido_claw/tools/run_command.ex:91,119` → `:97,123` (the docker-sandbox read from `tool_context` is at 97; the workspace-from-context-before-params resolution at 123).

These are the doc's only two `run_command.ex` citations (verified by grep). The completed jaunty-squid plan doc carries the same stale numbers but is a historical planning artifact, out of the review's scope — left as written.

## Verification

UI changes (fixes 1–5) run the full UI gate **from the repository root** (`--dir ui` resolves the package from there), in the plan-established order (write-format first, codegen before any checking, verified build last):

```
pnpm --dir ui fmt
pnpm --dir ui codegen
pnpm --dir ui validate     # check && lint && fmt && test
pnpm --dir ui build        # tsc -b && vite build — the stricter type arbiter
```

All four must pass with exit 0; report exact test counts verbatim. Since `react/only-export-components` is warn-level, additionally run the one-off hard lint pass from Fix 1 (`pnpm --dir ui lint -- --deny-warnings`, or zero-warning output inspection). Spot-verify fix 4 (also from the repo root): `file ui/src/lib/approvals-data.ts` reports a text type.

**Browser spot checks** (`pnpm --dir ui dev:mock`, open `/argus/approvals`) — the automated gate cannot exercise HMR ordering or the changed visuals:

1. **Fix 1 Fast Refresh smoke — reproduce the reported failure mode.** With a draft typed on one card and another card resolved: save `approvals-local-state-provider.tsx` (append/remove a trailing comment) — no full reload, no "requires ApprovalsLocalStateProvider" exception, draft and resolution survive. Then save `approvals-local-state.ts` — no provider exception (a clean in-place refresh or an honest full-page reload are both acceptable; the intermittent provider crash is the regression being fenced).
2. **Fix 5 visuals, light AND dark themes.** Approve one tool card and reply to the question card (both reachable in preview): the resolved cards show the solid neutral `border-border` + full `bg-card` surface (no dash, no wash, no card-level muting). The **tombstone** (fix 3) is deliberately NOT in the browser matrix: the error decision state is slice-1-only and unreachable in `dev:mock` by design — the preview store's `resolve` only writes `resolved` decisions (approvals-local-state:388, approvals.tsx:363) — so its layout and reading order are pinned entirely by the extended regression test (copy inside the `role="status"` node, Dismiss outside it, `justify-end` on the row); no temporary harness is added for it.

`mix precommit` is not required: no Elixir source changes, and `argus-backend-needs.md` lives under `docs/plans/` (not guarded by `mix jidoclaw.system_docs.check`).

Nothing is committed and no `git add`/`git rm` is ever run: remediation changes remain **unstaged**, and the pre-existing staged index (the step-6 files already staged: plan docs, skill edits, roadmap README, `ui/package.json`) is preserved untouched. None of the files this plan edits are in the staged set (they are unstaged-modified or untracked, and the rename target is untracked), so the cached diff cannot move — verify `git diff --cached` is byte-identical before and after implementation (compare `git diff --cached | shasum`).
