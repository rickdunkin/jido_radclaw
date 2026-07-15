import { MockedProvider } from "@apollo/client/testing/react";
import { render, screen, within } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { expect, test, vi } from "vite-plus/test";
import { createAppRouter } from "./router.tsx";

// Sentinel seam data lives in its OWN file: vi.mock hoists module-wide, so
// a shell.test.tsx mock would feed sentinels to every default-fixture
// assertion there — and the static route tree makes reset/dynamic-import
// recovery unsafe (see mock-mode.test.tsx). The COMPLETE ShellData shape is
// required: AppSidebar renders the whole object.
vi.mock("./lib/shell-data.ts", () => ({
  useShellData: () => ({
    attentionCount: 9,
    approvalsCount: 8,
    runsAtGates: 1,
    projects: ["sentinel-project"],
    nodes: [{ name: "sentinel-node", meta: "probe", online: true }],
  }),
}));

// The approvals nav badge no longer reads shell-data — it derives from the
// approvals summary seam through the local-state store, so the sentinel
// count must ride useApprovalsSummaryData. PARTIAL mock via importOriginal
// (the store still calls deriveApprovalsSummary et al.); the result object
// is built ONCE — the provider coordinator keys on its identity.
vi.mock(import("./lib/approvals-data.ts"), async (importOriginal) => {
  const original = await importOriginal();
  const summary = {
    ...original.getApprovalsSummaryData(),
    pendingByKind: {
      tool_call: 8,
      needs_input: 0,
      plan: 0,
      irreversible_write: 0,
      review_stall: 0,
    },
    total: 8,
  };
  const result = { data: summary, status: "idle" as const, refetch: () => undefined };
  return {
    ...original,
    useApprovalsSummaryData: () => result,
  };
});

test("both bars render counts from the seams, never literals", async () => {
  const router = createAppRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(
    <MockedProvider mocks={[]}>
      <RouterProvider router={router} />
    </MockedProvider>,
  );

  // Dual scoping: both bars exist in happy-dom, so unscoped queries are
  // ambiguous — and the phone consumer must be proven un-hardcoded too.
  const railNav = await screen.findByRole("navigation", { name: "Main" });
  const tabBar = screen.getByRole("navigation", { name: "Primary" });

  expect(within(railNav).getByRole("link", { name: "Attention 9" })).toBeDefined();
  expect(within(railNav).getByRole("link", { name: "Approvals 8" })).toBeDefined();
  expect(within(tabBar).getByRole("link", { name: "Attention 9" })).toBeDefined();
  expect(within(tabBar).getByRole("link", { name: "Approvals 8" })).toBeDefined();

  // The count-of-one sentinel also proves the singular sr-only boundary —
  // a real count of one must never announce "1 runs at gates".
  expect(within(railNav).getByRole("link", { name: "Runs 1 run at gates" })).toBeDefined();
});
