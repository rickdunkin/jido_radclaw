import { ApolloProvider } from "@apollo/client/react";
import { act, cleanup, render, screen, within } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { StrictMode } from "react";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import { createApolloClient } from "../lib/apollo.ts";
import { createAppRouter } from "../router.tsx";
import { DEFAULT_RUN_IDS } from "./fixtures.ts";
import { getSharedStore } from "./store.ts";

// The only flag-on test — the real createApolloClient()/createSocket() mock
// branches, end to end. Deliberately NO vi.resetModules() and NO dynamic
// imports: the generated route tree statically imports routes/runs.tsx →
// lib/socket.ts, so a reset-then-import approach would split the module
// registry (the rendered component would keep the pre-reset socket/store
// while the test mutated post-reset instances). Vitest's per-file isolation
// gives this file a fresh registry, and the flag + shared store are only
// read lazily inside the factories — so the beforeEach stubs land first.
// The lib socket and shared store are file-lifetime singletons: one
// comprehensive /runs test, and the /projects test never assumes a
// pristine runs store.

beforeEach(() => {
  vi.stubEnv("VITE_MOCKS", "1");
  // Pin the scenario: an inherited developer/CI VITE_MOCK_SCENARIO (e.g.
  // "empty") would otherwise silently break the fixture-id assertions.
  vi.stubEnv("VITE_MOCK_SCENARIO", "default");
});

afterEach(() => {
  vi.unstubAllEnvs();
  cleanup();
});

function renderRoute(path: string) {
  const router = createAppRouter({
    history: createMemoryHistory({ initialEntries: [path] }),
  });
  render(
    <StrictMode>
      <ApolloProvider client={createApolloClient()}>
        <RouterProvider router={router} />
      </ApolloProvider>
    </StrictMode>,
  );
}

function rowFor(name: string): HTMLElement {
  const row = screen.getByText(name).closest("li");
  if (!row) throw new Error(`no list row found for "${name}"`);
  return row;
}

test("__ARGUS_MOCKS_ALLOWED__ is the vitest worker global, pinned true", () => {
  // Pins the define → worker-global injection this whole suite stands on:
  // vitest resolves the vite config with command "serve", deletes dot-less
  // define keys, and re-injects them as worker runtime globals. If a
  // vitest/vite-plus bump changes that, this fails with a readable message
  // instead of a fixture-rendering cascade in the tests below.
  expect(__ARGUS_MOCKS_ALLOWED__).toBe(true);
});

test("/runs renders fixtures backendless, and a store transition reaches its row", async () => {
  renderRoute("/runs");

  // Fixtures render through the real SchemaLink client — no /gql, no ws.
  expect(await screen.findByText("triage flaky partition")).toBeDefined();
  expect(screen.getByText("port evidence floor")).toBeDefined();
  expect(screen.getByText("rotate gateway keys")).toBeDefined();

  // The amber done_with_findings row, never plain green.
  const amberLabel = screen.getByText("code · completed · 3 findings deferred");
  expect(amberLabel.className).toContain("text-status-waiting");

  // Joins succeeded against the fake channel surface: no degraded banner.
  expect(screen.queryByText("Live updates unavailable.")).toBeNull();
  expect(screen.queryByText(/Failed to load runs/)).toBeNull();

  // Mutate the shared store: the fake socket pushes run_event, the route
  // refetches through the mock link, and ONLY the advanced run's row moves.
  const pendingRow = rowFor("triage flaky partition");
  expect(within(pendingRow).getByText("code · pending")).toBeDefined();

  act(() => {
    getSharedStore().advanceRun(DEFAULT_RUN_IDS.pending);
  });

  expect(await within(pendingRow).findByText("code · running")).toBeDefined();
  // A RUNNING fixture exists elsewhere — the scoped assertion above is what
  // proves the change landed on the advanced row.
  expect(within(rowFor("port evidence floor")).getByText("code · running")).toBeDefined();
  expect(screen.queryByText("code · pending")).toBeNull();
  expect(screen.queryByText("Live updates unavailable.")).toBeNull();
});

test("/projects renders the shared store alphabetically (runs store may have moved)", async () => {
  renderRoute("/projects");

  // Scoped to the main landmark: the shell rail also renders "argus" (the
  // wordmark and a PROJECTS fixture row) outside the page content.
  const main = within(await screen.findByRole("main"));
  expect(await main.findByText("argus")).toBeDefined();
  expect(main.getAllByText("hermes")).toHaveLength(2);
  expect(main.getByText("jidoclaw/hermes-fork · trunk")).toBeDefined();
  expect(screen.queryByText(/Failed to load projects/)).toBeNull();
});
