# Fix P1: mock mode must be build-proof (command-derived gate + self-verifying builds)

## Context

The mock-data-layer plan (`.claude/plans/flickering-soaring-bunny.md`) shipped with mock mode gated by `import.meta.env.DEV && import.meta.env.VITE_MOCKS === "1"` at `ui/src/lib/apollo.ts:13` and `ui/src/lib/socket.ts:56`. Code review flagged **[P1] Mock mode is not build-proof**: `DEV` derives from NODE_ENV, not from Vite's serve/build command.

**Finding VALIDATED** — mechanism confirmed first-hand in the installed toolchain (`ui/node_modules/vite` = `@voidzero-dev/vite-plus-core@0.2.4`, `dist/vite/node/chunks/node.js`):

- `resolveConfig` keeps an externally-set NODE_ENV: `const isNodeEnvSet = !!process.env.NODE_ENV; if (!isNodeEnvSet) process.env.NODE_ENV = defaultNodeEnv;` (lines 40760–40762) — the build entry's `"production"` default (line 38091-38092) is only a fallback.
- `const isProduction = process.env.NODE_ENV === "production"` (line 40890); resolved env is `DEV: !isProduction` (line 41004).
- The bundled `vite:define` plugin statically replaces `import.meta.env.DEV → JSON.stringify(config.env.DEV)` into rolldown's native `transform.define` for every bundled build (lines 29858–29861, 29904–29917), and `loadEnv` folds process-env `VITE_*` into the per-key replacements (line 7975 → 41001).

So `NODE_ENV=development VITE_MOCKS=1 pnpm --dir ui build` compiles the gate to `if (true && "1" === "1")`: the mock Apollo client, fixtures, fake socket, and simulator land in `priv/static/argus/` — the artifact `mix ui.build` ships into releases/docker images. An operator shell that exported both vars (plausible after a `dev:mock` session) silently produces a deployable backendless bundle. The original plan's "verified fact" held only for clean-env builds.

**Fix**: gate on a compile-time constant derived from `command === "serve"` (the reviewer's prescription) and make every build self-verify exclusion via a `generateBundle` guard — the strongest reading of "add this hostile combination to the exclusion check", per repo doctrine (permanent test over spot-check; load-bearing guard ships in v1).

## Verified toolchain facts the design rests on

All first-hand from installed packages (vite 8.1.3 / rolldown 1.1.4 / vitest 4.1.10 / oxlint 1.72.0, embedded in vite-plus 0.2.4); independently cross-checked by a toolchain deep-dive agent:

- vp's `defineConfig` supports function-form configs: typed overload (`define-config-BuMs_LKa.d.ts:325-329`) + runtime pass-through of `(env) => …` (`define-config-Dn5coJS5.js:401-406`); vite calls a function config with `{command, mode}` (`node.js:41157`). `vp build` is a faithful `vite build` (spawns vite's own cli.js).
- Under vitest (`vp test`), dot-less `define` keys are deleted from the vite config, `JSON.parse`d, and injected as **worker runtime globals**: `deleteDefineConfig` (`cli-api.BK8pd4xc.js:10070-10101`) → `setupDefines`: `globalThis[key] = config.defines[key]` (`setup-common.DYx3LtFI.js:31-32`). Vitest resolves the config via vite `createServer` → `resolveConfig(inlineConfig, "serve")` (`node.js:30927`), mode `"test"` — the constant is boolean `true` in tests (evidence-backed).
- `import.meta.env.*` stays a RUNTIME lookup under vitest (`MetaEnvReplacerPlugin`, enforce-pre, rewrites every occurrence before vite:define; the object proxies `process.env`) — the existing `vi.stubEnv("VITE_MOCKS", …)` tests keep working unchanged.
- `vp check`/`vp lint`/`vp fmt` metadata resolution invokes a function-form config with `command: "build"` and skips `lazyPlugins` factories — harmless both ways (nothing transforms or bundles under check), but it means the constant must be a **top-level `define`**, never injected from a plugin `config` hook.
- Bundle-guard viability: rolldown chunks expose `moduleIds: string[]` (`define-config-BBz954-q.d.mts:195,234`); `generateBundle(this: PluginContext, options, bundle, isWrite)` is a supported output hook (same file:2958); `OutputAsset.source: string | Uint8Array`. It only runs during builds.
- oxlint 1.72.0's default enabled set has **no `no-undef`** (verified via `--print-config`) — no `globals` config needed; the undeclared-identifier risk is the TS type-check path (tsgolint + `tsc -b`), which the `declare const` d.ts satisfies. `ui/src` has no `.d.ts` today; a new `src/*.d.ts` is auto-included by `tsconfig.app.json` `include: ["src"]`; the node project never references the bare identifier (the config only defines the string key).
- Leak-surface sweep: the ONLY non-test importers of `src/mocks/` are `lib/apollo.ts:2` and `lib/socket.ts:2` (static, in the gated dead branches); no dynamic `import()` in src outside a test file; `schema.graphql?raw` is imported only by `mocks/link.ts` (rides the mocks graph); routeTree/index.html/public/css are clean; `ui/.env.local` holds only `VITE_API_KEY`; `vp preview` performs no transforms (not a vector).

## Changes (file by file)

1. **`ui/vite.config.ts`** — convert to function form `defineConfig(({ command }) => ({ …existing keys unchanged… }))` and add two things:
   - Top-level `define: { __ARGUS_MOCKS_ALLOWED__: JSON.stringify(command === "serve") }` with a comment: command-derived, NOT NODE_ENV-derived — `vite build` resolves command `"build"` no matter what the shell exports (the P1 hole); `"serve"` covers vp dev AND vitest. The expression is an invariant: exactly `command === "serve"`, never widened by `mode` (mode is CLI-controllable on builds — `vp build --mode test` is still a build, so a `|| mode === "test"` arm would reopen the gate and leave only the bundle guard standing).
   - A module-level `const MOCK_MARKER = "argus-mock-fixture-7f3c"` (documented duplicate — the config CANNOT import `fixtures.ts`: it imports generated, git-ignored `src/gql/graphql.ts`, and the config must load pre-codegen; cross-ref comments both sides) plus an inline **`argus-mock-exclusion-guard`** plugin appended inside the existing `lazyPlugins` array: `apply: "build"`, `generateBundle(_options, bundle)` iterates `Object.entries(bundle)`; for chunks, fail if any normalized (`\\`→`/`) entry of `moduleIds` contains the resolved absolute `src/mocks/` dir (structural, primary — `includes` not `startsWith`, robust to `\0`-virtual ids and `?raw` suffixes) or `code` contains MOCK_MARKER (secondary); for assets, marker-scan `source` (TextDecoder for Uint8Array). Accumulate all problems, fail once via `this.error(...)` (fallback `throw` if contextual `this` typing balks) with an actionable message naming the leaked ids and pointing at the define + the gates. Run `pnpm --dir ui fmt` after (oxfmt owns the file).
2. **`ui/src/mocks-gate.d.ts`** (new) — import/export-free global declaration file: `declare const __ARGUS_MOCKS_ALLOWED__: boolean;` with the full gate contract in a comment (build: statically false, NODE_ENV-independent, DCE + guard; dev: true, still requires VITE_MOCKS=1; vitest: worker global true, pinned by test; gates MUST read the bare identifier inline — `globalThis.__X__` or any indirection dodges define replacement and breaks DCE).
3. **`ui/src/lib/apollo.ts`** — gate becomes `if (__ARGUS_MOCKS_ALLOWED__ && import.meta.env.VITE_MOCKS === "1")`; rewrite the falsified comment block (8–12) per the new contract (statically false in EVERY `vite build` — NODE_ENV and exported VITE_* cannot reopen it; guard proves it; vitest = worker global; see mocks-gate.d.ts).
4. **`ui/src/lib/socket.ts`** — same gate substitution at 56; comment (52–55) first sentence rewritten to match apollo.ts, keeping the createSocket-vs-getSocket rationale sentence.
5. **`ui/src/lib/socket.test.ts`** — comment-only touch-up (50–51): "__ARGUS_MOCKS_ALLOWED__ is true under vitest (define → worker global), so an inherited shell VITE_MOCKS=1 would flip createSocket() into its mock branch…". The `vi.stubEnv("VITE_MOCKS", "0")` stays.
6. **`ui/src/mocks/fixtures.ts`** — MOCK_MARKER comment (8–10) extended: names the two checks keying on it (the build guard in vite.config.ts and the manual verification grep) and the documented literal duplicate in the config.
7. **`ui/src/mocks/mock-mode.test.tsx`** — add a dedicated pin test: `expect(__ARGUS_MOCKS_ALLOWED__).toBe(true)` with a comment explaining it pins vitest's define→worker-global injection so toolchain drift fails with a readable message instead of a fixture-rendering cascade.

**Not touched**: `ui/package.json` (`dev:mock` unchanged), `AGENTS.md` ("dev-server-only by construction" now truly holds; keeps the node-free precommit doc checks out of scope), all mocks behavior, router/routes, `ui/schema.graphql`.

## Verification (run from repo root; builds and greps as separate commands, never piped; done = all green)

Env-poisoned and deliberately-red builds NEVER target the serving dir: they run via `pnpm --dir ui exec vp build --outDir <scratch>` (a session-scratchpad dir outside the repo; skipping `tsc -b` is fine there — env vars don't change type state). `priv/static/argus/` only ever receives the final clean build.

0. **RED repro before any edit** (corroboration — the finding is already mechanism-validated; not load-bearing): `NODE_ENV=development VITE_MOCKS=1 pnpm --dir ui exec vp build --outDir <scratch>/p1-red`, then `grep -rl "argus-mock-fixture" <scratch>/p1-red` → expect hits (exit 0). An interrupted run can never leave a deployable mock artifact behind.
1. Apply edits 1–7; `pnpm --dir ui fmt`.
2. `pnpm --dir ui codegen`
3. `pnpm --dir ui check` — contingency if lint flags the bare identifier: add `globals: { __ARGUS_MOCKS_ALLOWED__: "readonly" }` to the existing `lint` block.
4. `pnpm --dir ui test` — exact counts reported (prior passing count + 1). The pin test empirically re-confirms vitest sees command `"serve"`. If it ever fails, that is toolchain drift — stop and investigate; never widen the define expression (see the invariant in edit 1).
5. Exclusion across all three build flavors, grep after each expecting zero hits (exit 1):
   - `VITE_MOCKS=1 pnpm --dir ui exec vp build --outDir <scratch>/flavor2` + grep over that dir;
   - `NODE_ENV=development VITE_MOCKS=1 pnpm --dir ui exec vp build --outDir <scratch>/flavor3` (the P1 combo — build must SUCCEED with the guard silent; the fix is the fold, the guard is the proof) + grep over that dir;
   - LAST, the real gate build: `pnpm --dir ui build` (clean env, real outDir) + `grep -rl "argus-mock-fixture" priv/static/argus/` → zero hits — the artifact left on disk is the clean production build.
6. **Guard red-proof** (uncommitted scratch edit): set the define value to `JSON.stringify(true)` and run `VITE_MOCKS=1 pnpm --dir ui exec vp build --outDir <scratch>/red-proof` — `VITE_MOCKS=1` is REQUIRED (with it unset the second conjunct still folds the branch and the guard would stay silent, proving nothing); the scratch `--outDir` keeps step 5's green artifact untouched (`generateBundle` fires regardless of outDir). Expect the build to FAIL naming leaked `src/mocks/` module ids. Revert the scratch edit.
7. Dev smoke: `pnpm --dir ui dev:mock` → `/argus/runs` renders fixtures backendless; stop. (Plain `pnpm --dir ui dev` proxy path is untouched by construction — no assertion needed.)
8. `mix precommit` — bare, unpiped; report its own verdict lines verbatim. **This is the done criterion.**

## Risks / residuals

- Marker literal duplicated between `fixtures.ts` and `vite.config.ts` (cross-ref comments both sides; drift only weakens the secondary scan — the structural `moduleIds` scan is marker-independent).
- Under vitest the constant is a runtime worker global, not a static replacement — the pin test is the tripwire for vitest major bumps.
- Source maps: `build.sourcemap` is unset (off) → no `.map` outputs to scan; even if enabled later, a map can only reference bundled modules, so the moduleIds check is the structural superset. Documented, not scanned.
- A guard-failed build leaves `priv/static/argus/` emptied (`emptyOutDir` runs before `generateBundle` aborts) → ArgusController serves its honest 404-with-build-hint until a clean rebuild. Deliberate fail-safe: no artifact beats a poisoned one.
- A `NODE_ENV=development` build remains a weird artifact in other ways (dev-flavored transforms); this fix guarantees mock exclusion, not full production-parity of hostile-env builds.
- Stale git-ignored `ui/dist/` is marker-free scaffold cruft; out of scope.
- The working tree carries the uncommitted bunny-plan mock feature on `main`; this fix stacks onto it — commit only when asked.

## Critical files

- `ui/vite.config.ts`
- `ui/src/mocks-gate.d.ts` (new)
- `ui/src/lib/apollo.ts`, `ui/src/lib/socket.ts`
- `ui/src/mocks/mock-mode.test.tsx` (+ comment-only: `ui/src/lib/socket.test.ts`, `ui/src/mocks/fixtures.ts`)

## Deviations

- **Guard predicate refined: rendered-content check added to the structural moduleIds scan** (forced correction — one sensible path; logged, not surfaced, because the plan's own step-5 outcome contract decided it).
  - *Plan assumed*: flavor-3 (`NODE_ENV=development VITE_MOCKS=1 vp build`) succeeds with the guard silent under the literal predicate "fail if any moduleIds entry contains `src/mocks/`".
  - *Code revealed*: the fold works exactly as designed (no marker anywhere, none of link.ts's deps bundled), but under `NODE_ENV=development` builds rolldown (vite-plus 0.2.4) retains fully tree-shaken modules as **empty records in `moduleIds`** — probe evidence via `OutputChunk.modules`: `src/mocks/link.ts [renderedLength=0 code=null]`. The literal predicate therefore fails every dev-NODE_ENV build falsely (including a mock-free `NODE_ENV=development mix ui.build` with no VITE_MOCKS at all), directly contradicting step 5's required outcome ("build must SUCCEED with the guard silent").
  - *Chosen*: flag a `src/mocks/` module id only when its `RenderedModule` shows content (`renderedLength > 0` or non-empty `code`); a **missing** rendered record fails CLOSED as a leak; the marker scan and the `command === "serve"` define invariant are untouched. Re-ran the step-6 red-proof after the refinement: build fails naming all five mocks modules with real content (renderedLength 1169–4501) across two chunks plus the marker hit — detection strength empirically preserved.
  - *To revisit*: if a vite-plus bump changes `OutputChunk.modules` semantics, the red-proof procedure in step 6 is the re-verification.
- **Dev-serve define mechanism observed** (no code change): in serve mode `vite:define`'s transform skips client modules; the constant reaches the browser as a global injected by `/@vite/env` (`globalThis.__ARGUS_MOCKS_ALLOWED__ = true`), loaded via `/@vite/client` ahead of `src/main.tsx`. Consistent with the shipped contract in `src/mocks-gate.d.ts` (which claims static replacement only for builds); recorded so nobody "fixes" the unreplaced identifier visible in served dev sources.
- **Out-of-plan repair: precommit flake fixed per the standing repeat-flake rule** (`SessionStartIdempotencyTest` "concurrent first-callers" failed two consecutive full precommit runs with a DBConnection sandbox queue-drop — "connection … dropped from queue after 216ms" — while passing isolated; zero relation to the UI change). Final fix, scoped after a review round: the module goes `use JidoClaw.TenantCase, async: false` (the case template's shared-sandbox default posture — serial scheduling stops partition-internal CPU contention from inflating the shared-connection queue past DBConnection's default ~200ms drop horizon), the test trims `max_concurrency` 10→5, and it asserts all 50 results `{:ok, _}` (sibling `tenant_test.exs` shape; the insert-vs-`:touch`-fallback interleaving needs only ≥2 overlapping callers since DB calls serialize on the one shared connection anyway). A first-cut global fix (`config/test.exs` `queue_target: 500, queue_interval: 5_000`) was REVERTED on review: no suite-wide queue-drop evidence, the keys would merge onto the cluster suite's real `DBConnection.ConnectionPool`, and its comment misstated the ownership backstop (120s default, not 5s). Scoped-shape precommit: green, partition 1 `1591 passed` twice consecutively. The stale agent-draft plan (`…-agent-a57d1ed8335c11c7d.md`, carried the rejected `|| mode === "test"` define variant) was deleted in the same review round.
