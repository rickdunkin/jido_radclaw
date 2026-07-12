// Global compile-time gate for mock mode. Declared here; DEFINED by the
// `define` block in ui/vite.config.ts, where the value is derived from the
// resolved vite command — never from NODE_ENV or any shell export.
//
// - `vite build` (any flavor, ANY shell env): statically false. Hostile
//   exports (NODE_ENV=development, VITE_MOCKS=1) cannot reopen it, the
//   gated branches fold away, dead-code elimination drops the whole
//   src/mocks/ module graph, and the argus-mock-exclusion-guard plugin
//   fails any build where mock modules or MOCK_MARKER survive anyway.
// - dev server (`vp dev` / `dev:mock`): true — mock mode still requires
//   the second conjunct, import.meta.env.VITE_MOCKS === "1".
// - vitest (`vp test`): vitest resolves the config with command "serve",
//   deletes dot-less define keys, and injects them as worker runtime
//   globals — so this is a runtime global with value true, not a static
//   replacement. Pinned by src/mocks/mock-mode.test.tsx so toolchain
//   drift fails with a readable message.
//
// Consumer rule: gates MUST read the bare identifier inline —
// `if (__ARGUS_MOCKS_ALLOWED__ && …)`. Reading it as
// `globalThis.__ARGUS_MOCKS_ALLOWED__`, aliasing it, or otherwise
// indirecting dodges vite's static define replacement and breaks the
// dead-code elimination the build-proofing rests on.
declare const __ARGUS_MOCKS_ALLOWED__: boolean;
