import path from "node:path";
import { defineConfig, lazyPlugins } from "vite-plus";
import tailwindcss from "@tailwindcss/vite";
import { tanstackRouter } from "@tanstack/router-plugin/vite";
import react from "@vitejs/plugin-react";

// Deliberate duplicate of MOCK_MARKER in src/mocks/fixtures.ts: this config
// cannot import fixtures.ts — that module imports generated, git-ignored
// src/gql/graphql.ts, and the config must load pre-codegen. fixtures.ts
// cross-references this copy; drift between the two only weakens the
// secondary marker scan in the exclusion guard below — the structural
// moduleIds check is marker-independent.
const MOCK_MARKER = "argus-mock-fixture-7f3c";

// Absolute src/mocks/ prefix for the guard's structural check. Trailing
// slash so sibling files (src/mocks-gate.d.ts) never match; separators
// normalized to keep the `includes` below robust across platforms.
const MOCKS_DIR = path.resolve(import.meta.dirname, "src/mocks").replaceAll("\\", "/") + "/";

// https://vite.dev/config/
export default defineConfig(({ command }) => ({
  // Every gateway node serves the built SPA at /argus (same-origin with
  // /gql). The base is unconditional — dev serves at /argus/ too, so dev
  // and the deployed artifact exercise identical routing; the router's
  // basepath follows via import.meta.env.BASE_URL (see src/router.tsx).
  base: "/argus/",
  define: {
    // Command-derived, NOT NODE_ENV-derived: `vite build` resolves command
    // "build" no matter what the shell exports, whereas import.meta.env.DEV
    // follows NODE_ENV — so `NODE_ENV=development VITE_MOCKS=1 vp build`
    // used to fold the whole mocks graph INTO the deployable artifact.
    // "serve" covers the dev server AND vitest (which resolves the config
    // via createServer and injects dot-less defines as worker globals).
    // INVARIANT: exactly `command === "serve"` — never widen by mode; mode
    // is CLI-controllable on builds (`vp build --mode test` is still a
    // build), so a `|| mode === "test"` arm would reopen the hole and
    // leave only the exclusion guard standing. Contract + consumer rules:
    // src/mocks-gate.d.ts.
    __ARGUS_MOCKS_ALLOWED__: JSON.stringify(command === "serve"),
  },
  resolve: {
    // Mirrors the tsconfig "@/*" paths (shadcn convention).
    alias: {
      "@": path.resolve(import.meta.dirname, "./src"),
    },
  },
  build: {
    // The Elixir app's static root, sibling to priv/static/assets/
    // (gitignored). outDir sits outside the Vite root, so emptying it
    // needs the explicit opt-in.
    outDir: "../priv/static/argus",
    emptyOutDir: true,
  },
  fmt: {
    // Generated files keep their generators' bytes: schema.graphql is the golden
    // owned by `mix jidoclaw.graphql.schema` (oxfmt touching it breaks the Elixir
    // drift check); routeTree.gen.ts is owned by the TanStack Router generator.
    // _mocks/ is the Claude Design handoff bundle — reference material, not code.
    ignorePatterns: ["schema.graphql", "src/routeTree.gen.ts", "src/gql/**", "_mocks/**"],
  },
  lint: {
    plugins: ["react", "typescript", "oxc"],
    rules: {
      "react/rules-of-hooks": "error",
      "react/only-export-components": [
        "warn",
        {
          allowConstantExport: true,
        },
      ],
      "vite-plus/prefer-vite-plus-imports": "error",
    },
    options: {
      typeAware: true,
      typeCheck: true,
    },
    jsPlugins: [
      {
        name: "vite-plus",
        specifier: "vite-plus/oxlint-plugin",
      },
    ],
    // TanStack file routes canonically export the Route const beside the
    // component; the router plugin owns their HMR, so fast-refresh purism
    // doesn't apply in src/routes/. shadcn ui files likewise export their
    // cva variants beside the component (buttonVariants et al.).
    overrides: [
      {
        files: ["src/routes/**", "src/components/ui/**"],
        rules: { "react/only-export-components": "off" },
      },
    ],
    ignorePatterns: ["_mocks/**"],
  },
  plugins: lazyPlugins(() => [
    tanstackRouter({ target: "react", autoCodeSplitting: true }),
    react(),
    tailwindcss(),
    // Every build self-verifies mock exclusion: if the __ARGUS_MOCKS_ALLOWED__
    // gates ever stop folding the mocks graph out (a widened define, an
    // ungated import, an indirect identifier read), the build FAILS instead
    // of shipping a backendless bundle toward priv/static/argus/.
    {
      name: "argus-mock-exclusion-guard",
      apply: "build",
      generateBundle(_options, bundle) {
        const problems: string[] = [];
        for (const [fileName, output] of Object.entries(bundle)) {
          if (output.type === "chunk") {
            // Structural, primary: any module under src/mocks/ that RENDERS
            // content into the chunk. `includes`, not `startsWith` — robust
            // to \0-virtual ids and query suffixes (schema.graphql?raw rides
            // the mocks graph). The rendered-content refinement is verified,
            // not cosmetic: NODE_ENV=development builds retain fully
            // tree-shaken modules as empty records (renderedLength 0, code
            // null) in moduleIds — metadata ghosts, not shipped code — so a
            // bare moduleIds check would fail every such mock-free build. A
            // missing rendered record fails CLOSED as a leak; a real leak
            // renders >0 here and drags fixtures' MOCK_MARKER into the scan
            // below (the red-proof in the P1 plan exercises exactly that).
            for (const id of output.moduleIds) {
              if (id.replaceAll("\\", "/").includes(MOCKS_DIR)) {
                const rendered = output.modules[id];
                const emptyGhost =
                  rendered !== undefined &&
                  rendered.renderedLength === 0 &&
                  (rendered.code === null || rendered.code === "");
                if (!emptyGhost) {
                  problems.push(
                    `${fileName} bundles mock module ${id} ` +
                      `(renderedLength=${String(rendered?.renderedLength)})`,
                  );
                }
              }
            }
            // Marker scan, secondary: catches mock content that arrives
            // without a src/mocks/ module id (inlining, transforms).
            if (output.code.includes(MOCK_MARKER)) {
              problems.push(`${fileName} contains the mock marker "${MOCK_MARKER}"`);
            }
          } else {
            const text =
              typeof output.source === "string"
                ? output.source
                : new TextDecoder().decode(output.source);
            if (text.includes(MOCK_MARKER)) {
              problems.push(`${fileName} contains the mock marker "${MOCK_MARKER}"`);
            }
          }
        }
        if (problems.length > 0) {
          this.error(
            "mock code leaked into a build output:\n" +
              problems.map((problem) => `  - ${problem}`).join("\n") +
              "\nMock mode is dev-server-only. The __ARGUS_MOCKS_ALLOWED__ define in " +
              'vite.config.ts must stay exactly `command === "serve"`, and the gates in ' +
              "src/lib/apollo.ts and src/lib/socket.ts must read it as a bare inline " +
              "identifier (see src/mocks-gate.d.ts).",
          );
        }
      },
    },
  ]),
  test: {
    environment: "happy-dom",
    server: {
      deps: {
        // graphql@17 ships dual dev/prod builds behind a `development`
        // exports condition: vite resolves source imports to __dev__/*.mjs
        // while Node's native loader (externalized deps) picks the default
        // build — two graphql instances, and SchemaLink's realm check
        // rejects schemas built by the other one. Inlining Apollo routes its
        // graphql import through vite too: one instance per test graph.
        inline: ["@apollo/client"],
      },
    },
  },
  server: {
    // Same-origin /gql in dev too: forward to the local Phoenix gateway.
    // The websocket proxy deliberately omits rewriteWsOrigin (Vite docs
    // flag it as a CSRF hazard); dev's browser origin (localhost:5173) is
    // instead allowed by the Phoenix endpoint's dev check_origin list.
    proxy: {
      "/gql": "http://localhost:4000",
      "/argus/ws": { target: "http://localhost:4000", ws: true },
    },
  },
}));
