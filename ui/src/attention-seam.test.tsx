import { MockedProvider } from "@apollo/client/testing/react";
import { render, screen, within } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { expect, test, vi } from "vite-plus/test";
import { createAppRouter } from "./router.tsx";

// Sentinel seam data lives in its OWN file: vi.mock hoists module-wide
// (shell-seam.test.tsx precedent). PARTIAL mock via importOriginal — unlike
// shell-data, this module also exports deriveAttentionSummary /
// groupByProject / the predicates that the rendered route still calls, so a
// full replacement would leave those undefined. The typed module-promise
// overload keeps the spread type-safe (the string-path form types
// importOriginal() as unknown).
const SENTINEL = vi.hoisted(() => {
  const base = (id: string, project: string, age: string) => ({
    id,
    title: `sentinel ${id}`,
    project,
    phoneMeta: [],
    deskMeta: [],
    age,
  });
  return {
    workingCount: 5,
    workingByProject: { "sentinel-project": 2 },
    items: [
      {
        ...base("s-g1", "sentinel-project", "1m"),
        kind: "gate" as const,
        action: { label: "Open gate →", emphasis: "solid" as const },
      },
      {
        ...base("s-q1", "sentinel-project", "2m"),
        kind: "question" as const,
        action: { label: "Reply →", emphasis: "outline" as const },
      },
      { ...base("s-f1", "sentinel-other", "3m"), kind: "failed" as const },
      { ...base("s-f2", "sentinel-other", "4m"), kind: "failed" as const },
      { ...base("s-f3", "sentinel-other", "5m"), kind: "failed" as const },
      { ...base("s-f4", "sentinel-other", "6m"), kind: "failed" as const },
    ],
  };
});

vi.mock(import("./lib/attention-data.ts"), async (importOriginal) => ({
  ...(await importOriginal()),
  getAttentionData: () => SENTINEL,
  useAttentionData: () => SENTINEL,
}));

test("the screen renders counts and sections from the seam, never fixture literals", async () => {
  const router = createAppRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(
    <MockedProvider mocks={[]}>
      <RouterProvider router={router} />
    </MockedProvider>,
  );
  const main = await screen.findByRole("main");

  // 2 needs-you / 4 failed / workingCount 5 — a component hardcoding the
  // public fixture's 3/3/1 fails every assertion below.
  expect(within(main).getByRole("heading", { level: 2, name: "NEEDS YOU · 2" })).toBeDefined();

  const phone = main.querySelector('[data-slot="count-summary-phone"]');
  expect(phone?.textContent).toBe("5 wk · 2 you · 4 fail");
  const srPhrase = main.querySelector('[data-slot="count-summary-sr"]');
  expect(srPhrase?.textContent).toBe("5 working · 2 waiting on you · 4 failed");
  // Nodes still come from the real shell seam, so basalt stays offline.
  const desk = main.querySelector('[data-slot="count-summary-desk"]');
  expect(desk?.textContent).toBe("5 working · 2 waiting on you · 4 failed · basalt offline");

  expect(within(main).getAllByRole("listitem")).toHaveLength(
    SENTINEL.items.length + 4, // six sentinel rows + the four temp links
  );
});
