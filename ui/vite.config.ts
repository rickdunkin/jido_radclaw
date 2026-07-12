import path from "node:path";
import { defineConfig, lazyPlugins } from "vite-plus";
import tailwindcss from "@tailwindcss/vite";
import { tanstackRouter } from "@tanstack/router-plugin/vite";
import react from "@vitejs/plugin-react";

// https://vite.dev/config/
export default defineConfig({
  // Every gateway node serves the built SPA at /argus (same-origin with
  // /gql). The base is unconditional — dev serves at /argus/ too, so dev
  // and the deployed artifact exercise identical routing; the router's
  // basepath follows via import.meta.env.BASE_URL (see src/router.tsx).
  base: "/argus/",
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
  ]),
  test: {
    environment: "happy-dom",
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
});
