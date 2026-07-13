import { MockedProvider } from "@apollo/client/testing/react";
import { cleanup, fireEvent, render, renderHook, screen, within } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { afterEach, expect, test } from "vite-plus/test";
import {
  type AttentionData,
  type AttentionItem,
  deriveAttentionSummary,
  getAttentionData,
  groupByProject,
  needsYou,
  useAttentionData,
} from "./lib/attention-data.ts";
import { type ShellNode, useShellData } from "./lib/shell-data.ts";
import { createAppRouter } from "./router.tsx";

// ---------------------------------------------------------------------------
// Seam cross-checks: the fixture must agree with the shell seam's badge
// count, and the hook-named seam must serve the same singleton as the
// non-hook getter (the live-data swap point replaces both together).
// ---------------------------------------------------------------------------

test("fixture needs-you count agrees with the shell seam's attentionCount", () => {
  const shell = renderHook(() => useShellData()).result.current;
  expect(getAttentionData().items.filter(needsYou)).toHaveLength(shell.attentionCount);
  const attention = renderHook(() => useAttentionData()).result.current;
  expect(attention).toBe(getAttentionData());
});

// ---------------------------------------------------------------------------
// Pure derivations, proven on SENTINEL synthetic data — never the public
// fixture, so a derivation that merely echoes fixture literals fails here.
// ---------------------------------------------------------------------------

function baseItem(id: string, project: string, age: string) {
  return { id, title: `title ${id}`, project, phoneMeta: [], deskMeta: [], age };
}

function gate(id: string, project: string, age = "1h"): AttentionItem {
  return {
    ...baseItem(id, project, age),
    kind: "gate",
    action: { label: "Open →", emphasis: "solid" },
  };
}

function question(id: string, project: string, age = "1h"): AttentionItem {
  return {
    ...baseItem(id, project, age),
    kind: "question",
    action: { label: "Reply →", emphasis: "outline" },
  };
}

function failed(id: string, project: string, age = "1h"): AttentionItem {
  return { ...baseItem(id, project, age), kind: "failed" };
}

function done(id: string, project: string, age = "1h"): AttentionItem {
  return { ...baseItem(id, project, age), kind: "done" };
}

function idle(id: string, project: string, count: number, age = "1h"): AttentionItem {
  return { ...baseItem(id, project, age), kind: "idle", count };
}

function resolved(id: string, project: string, age = "1h"): AttentionItem {
  return { ...baseItem(id, project, age), kind: "resolved" };
}

test("deriveAttentionSummary counts by kind and collects offline node names", () => {
  const data: AttentionData = {
    workingCount: 5,
    workingByProject: {},
    items: [
      gate("g1", "alpha"),
      question("q1", "beta"),
      failed("f1", "alpha"),
      failed("f2", "beta"),
      failed("f3", "gamma"),
      failed("f4", "gamma"),
      done("d1", "alpha"),
    ],
  };
  const nodes: ShellNode[] = [
    { name: "up", meta: "desk", online: true },
    { name: "down-a", meta: "laptop", online: false },
    { name: "down-b", meta: "pi", online: false },
  ];
  expect(deriveAttentionSummary(data, nodes)).toEqual({
    working: 5,
    waitingOnYou: 2,
    failed: 4,
    offlineNodes: ["down-a", "down-b"],
  });
});

test("groupByProject orders amber → active neutral → quiet, hoists needs-you, normalizes absent working counts", () => {
  const data: AttentionData = {
    workingCount: 9,
    workingByProject: { alpha: 4 },
    items: [
      done("a1", "alpha"),
      failed("b1", "beta"),
      gate("a2", "alpha"),
      resolved("c1", "gamma", "3h"),
    ],
  };
  const groups = groupByProject(data);
  expect(groups.map((group) => group.project)).toEqual(["alpha", "beta", "gamma"]);
  const [alpha, beta, gamma] = groups;

  // Hoisting: the gate leads even though the done row appeared first.
  expect(alpha.items.map((item) => item.id)).toEqual(["a2", "a1"]);
  expect(alpha.tone).toBe("amber");
  expect(alpha.quiet).toBe(false);
  expect(alpha.needsYouCount).toBe(1);
  expect(alpha.workingCount).toBe(4);

  // Absent workingByProject key normalizes to 0 — no undefined leak.
  expect(beta.workingCount).toBe(0);
  expect(beta.tone).toBe("neutral");
  expect(beta.quiet).toBe(false);
  expect(beta.failedCount).toBe(1);

  // A resolved-only project still rolls up quiet.
  expect(gamma.quiet).toBe(true);
  expect(gamma.tone).toBe("neutral");
  expect(gamma.quietLine).toEqual({ verb: "resolved", age: "3h" });
});

test("a quiet project mixing done + resolved takes the FIRST terminal item's verb (source order, not age)", () => {
  const data: AttentionData = {
    workingCount: 0,
    workingByProject: {},
    items: [
      // First in source order but OLDER — a "newest wins" implementation
      // would pick the resolved row instead. "First" is the defined rule:
      // items are priority-ordered and carry no timestamps this phase.
      done("d1", "delta", "9h"),
      resolved("d2", "delta", "1m"),
    ],
  };
  const [delta] = groupByProject(data);
  expect(delta.quiet).toBe(true);
  expect(delta.quietLine).toEqual({ verb: "finished", age: "9h" });
});

test("an idle cluster keeps a project out of the quiet rollup", () => {
  const data: AttentionData = {
    workingCount: 0,
    workingByProject: {},
    items: [done("e1", "epsilon"), idle("e2", "epsilon", 7)],
  };
  const [epsilon] = groupByProject(data);
  expect(epsilon.quiet).toBe(false);
  expect(epsilon.quietLine).toBeUndefined();
});

// ---------------------------------------------------------------------------
// Screen tests (renderAt pattern from shell.test.tsx: memory history +
// MockedProvider with EMPTY mocks — the page firing any query would throw,
// so mocks={[]} doubles as the no-query proof).
// ---------------------------------------------------------------------------

function renderAt(path: string, basepath?: string) {
  const router = createAppRouter({
    basepath,
    history: createMemoryHistory({ initialEntries: [path] }),
  });
  render(
    <MockedProvider mocks={[]}>
      <RouterProvider router={router} />
    </MockedProvider>,
  );
  return router;
}

async function settle() {
  await screen.findByRole("heading", { level: 1, name: "Attention" });
}

function mainEl(): HTMLElement {
  return screen.getByRole("main");
}

function rowByKind(kind: string): HTMLElement {
  const row = mainEl().querySelector<HTMLElement>(`[data-slot="feed-row"][data-kind="${kind}"]`);
  if (!row) throw new Error(`no feed row of kind ${kind}`);
  return row;
}

function showByProject() {
  fireEvent.click(screen.getByRole("tab", { name: "By project" }));
}

afterEach(() => {
  cleanup();
});

test("priority view: derived NEEDS YOU count, three needs-you cards, four EARLIER rows", async () => {
  renderAt("/");
  await settle();
  const main = within(mainEl());

  expect(main.getByRole("heading", { level: 2, name: "NEEDS YOU · 3" })).toBeDefined();
  for (const title of [
    "Plan review — migrate export pipeline to streaming",
    "“Webhook auth: HMAC per endpoint, or one shared signing key?”",
    "API credential expired on basalt — 2 threads paused",
  ]) {
    expect(main.getByText(title)).toBeDefined();
  }

  const needsYouSection = main
    .getByRole("heading", { name: "NEEDS YOU · 3" })
    .closest<HTMLElement>("section");
  const earlierSection = main
    .getByRole("heading", { name: "EARLIER" })
    .closest<HTMLElement>("section");
  if (!needsYouSection || !earlierSection) throw new Error("feed sections not rendered");
  expect(within(needsYouSection).getAllByRole("listitem")).toHaveLength(3);
  expect(within(earlierSection).getAllByRole("listitem")).toHaveLength(4);
});

test("feed rows render both meta compositions: phone folds the age in, desk extracts it", async () => {
  renderAt("/");
  await settle();
  const gateRow = rowByKind("gate");

  const phoneMeta = gateRow.querySelector('[data-slot="feed-meta-phone"]');
  const deskMeta = gateRow.querySelector('[data-slot="feed-meta-desk"]');
  expect(phoneMeta?.textContent).toBe("quill · export-pipeline · atlas · 4m");
  expect(deskMeta?.textContent).toBe("quill · thread export-pipeline · atlas · run #7 step 3/5");
  expect(phoneMeta?.className).toContain("@3xl/feed:hidden");
  expect(deskMeta?.className).toContain("hidden");
  expect(deskMeta?.className).toContain("@3xl/feed:block");

  // The failed row's richer desk meta proves per-slot fixture segments.
  const failedRow = rowByKind("failed");
  expect(failedRow.querySelector('[data-slot="feed-meta-phone"]')?.textContent).toBe(
    "terrarium · nightly-e2e #212 · 1h",
  );
  expect(failedRow.querySelector('[data-slot="feed-meta-desk"]')?.textContent).toBe(
    "terrarium · nightly-e2e #212 · wren — created T-222",
  );
});

test("structure: h1/h2 hierarchy, li-only lists, and every <section> carries a resolving label", async () => {
  renderAt("/");
  await settle();

  function sweepStructure() {
    const main = mainEl();
    // Every <ul> is role=list with <li>-only element children (the EARLIER
    // hairlines live on the li itself — a <div> divider between <li>s would
    // be invalid list markup).
    const lists = Array.from(main.querySelectorAll("ul"));
    expect(lists.length).toBeGreaterThan(0);
    for (const list of lists) {
      expect(list.getAttribute("role")).toBe("list");
      for (const child of Array.from(list.children)) {
        expect(child.tagName).toBe("LI");
      }
    }
    // Literal-element sweep, NOT getAllByRole("region"): an unnamed
    // <section> maps to role "generic", so a role query would silently
    // skip exactly the bad nodes.
    for (const section of Array.from(main.querySelectorAll("section"))) {
      const labelId = section.getAttribute("aria-labelledby");
      expect(labelId, "section without aria-labelledby").toBeTruthy();
      expect(document.getElementById(labelId ?? "")).not.toBeNull();
    }
  }

  expect(screen.getByRole("heading", { level: 1, name: "Attention" })).toBeDefined();
  const priorityHeadings = within(mainEl())
    .getAllByRole("heading", { level: 2 })
    .map((heading) => heading.textContent);
  expect(priorityHeadings).toEqual(["NEEDS YOU · 3", "EARLIER"]);
  sweepStructure();

  showByProject();
  const projectHeadings = within(mainEl())
    .getAllByRole("heading", { level: 2 })
    .map((heading) => heading.textContent);
  expect(projectHeadings).toEqual(["quill", "helios-api", "infra", "terrarium", "argus"]);
  sweepStructure();
});

test("toggle: real tablist semantics; the hidden panel unmounts and comes back", async () => {
  renderAt("/");
  await settle();

  const tablist = screen.getByRole("tablist", { name: "Attention view" });
  expect(within(tablist).getAllByRole("tab")).toHaveLength(2);

  showByProject();
  expect(screen.queryByRole("heading", { name: "NEEDS YOU · 3" })).toBeNull();
  expect(screen.queryByRole("heading", { name: "EARLIER" })).toBeNull();
  expect(within(mainEl()).getByRole("heading", { level: 2, name: "quill" })).toBeDefined();

  // The quiet project rolls up to a single line with the FIRST terminal
  // item's verb.
  const argusHeading = within(mainEl()).getByRole("heading", { level: 2, name: "argus" });
  const quietRow = argusHeading.closest("li");
  expect(quietRow?.textContent).toContain("quiet — ");
  expect(quietRow?.textContent).toContain("✓ finished 26m ago, nothing needs you");

  fireEvent.click(screen.getByRole("tab", { name: "Priority" }));
  expect(within(mainEl()).getByRole("heading", { name: "NEEDS YOU · 3" })).toBeDefined();
  expect(screen.queryByRole("heading", { level: 2, name: "quill" })).toBeNull();
});

test("by-project drops the meta project prefix and fills the header right-slots", async () => {
  renderAt("/");
  await settle();
  showByProject();
  const main = mainEl();

  const gateRow = rowByKind("gate");
  expect(gateRow.querySelector('[data-slot="feed-meta-phone"]')?.textContent).toBe(
    "export-pipeline · atlas · 4m",
  );
  expect(gateRow.querySelector('[data-slot="feed-meta-desk"]')?.textContent).toBe(
    "thread export-pipeline · atlas · run #7 step 3/5",
  );

  expect(within(main).getAllByText("1 needs you")).toHaveLength(3);
  const working = main.querySelector('[data-slot="project-working"]');
  const failed = main.querySelector('[data-slot="project-failed"]');
  expect(working?.textContent).toBe("● 2 working");
  expect(failed?.textContent).toBe("● 1 failed");
  // The working span belongs to quill's header, the failed one to terrarium's.
  expect(
    working?.closest("section")?.contains(within(main).getByRole("heading", { name: "quill" })),
  ).toBe(true);
  expect(
    failed?.closest("section")?.contains(within(main).getByRole("heading", { name: "terrarium" })),
  ).toBe(true);
});

test("the feed is inert: no links/buttons/focus stops inside the tabpanel; temp links live outside it", async () => {
  renderAt("/");
  await settle();

  function assertInertPanel() {
    const panel = screen.getByRole("tabpanel");
    expect(within(panel).queryAllByRole("link")).toHaveLength(0);
    expect(within(panel).queryAllByRole("button")).toHaveLength(0);
    expect(panel.querySelectorAll("[tabindex]")).toHaveLength(0);
    const chevrons = Array.from(panel.querySelectorAll('[data-slot="feed-chevron"]'));
    expect(chevrons.length).toBeGreaterThan(0);
    for (const chevron of chevrons) {
      expect(chevron.getAttribute("aria-hidden")).toBe("true");
    }
  }

  assertInertPanel();
  const action = within(screen.getByRole("tabpanel")).getByText("Open gate →");
  expect(action.tagName).toBe("SPAN");
  expect(action.closest("a,button")).toBeNull();

  showByProject();
  assertInertPanel();

  // The temporary reachability row stays OUTSIDE the tabpanel — the page's
  // only real links until slice 1 provides in-feed navigation.
  const main = within(mainEl());
  for (const [name, href] of [
    ["View runs", "/runs"],
    ["View projects", "/projects"],
    ["View board", "/board"],
    ["Styleguide", "/styleguide"],
  ] as const) {
    const link = main.getByRole("link", { name });
    expect(link.getAttribute("href")).toBe(href);
    expect(screen.getByRole("tabpanel").contains(link)).toBe(false);
  }
});

test("preview honesty: explicit sample-data marker, no live signal, sr-only summary phrase", async () => {
  renderAt("/");
  await settle();
  const main = mainEl();

  expect(within(main).getByText("preview · sample data")).toBeDefined();
  expect(within(main).queryByText("live")).toBeNull();

  const phone = main.querySelector('[data-slot="count-summary-phone"]');
  expect(phone?.getAttribute("aria-hidden")).toBe("true");
  expect(phone?.textContent).toBe("3 wk · 3 you · 1 fail");
  // The phone pair (abbreviation + sr-only phrase) hides together at
  // @3xl/feed so wide readers hear only the visible long wording.
  expect(phone?.parentElement?.className).toContain("@3xl/feed:hidden");

  const srPhrase = main.querySelector('[data-slot="count-summary-sr"]');
  expect(srPhrase?.classList.contains("sr-only")).toBe(true);
  expect(srPhrase?.textContent).toBe("3 working · 3 waiting on you · 1 failed");

  const desk = main.querySelector('[data-slot="count-summary-desk"]');
  expect(desk?.textContent).toBe("3 working · 3 waiting on you · 1 failed · basalt offline");
  expect(desk?.className).toContain("hidden");
  expect(desk?.className).toContain("@3xl/feed:inline");
});

test("cluster row carries ×12 with no chevron; resolved row dims with mono title code", async () => {
  renderAt("/");
  await settle();

  const idleRow = rowByKind("idle");
  const clusterChip = idleRow.querySelector('[data-slot="feed-chip"]');
  expect(clusterChip?.textContent).toBe("×12");
  expect(idleRow.querySelector('[data-slot="feed-chevron"]')).toBeNull();

  const resolvedRow = rowByKind("resolved");
  expect(resolvedRow.className).toContain("opacity-[.62]");
  expect(resolvedRow.querySelector('[data-slot="feed-chevron"]')).toBeNull();
  const mark = resolvedRow.querySelector('[data-slot="feed-resolved-mark"]');
  expect(mark?.textContent).toBe("resolved · 3h");
  const ageSuffix = mark?.querySelector("span");
  expect(ageSuffix?.textContent).toBe(" · 3h");
  expect(ageSuffix?.className).toContain("hidden");
  expect(ageSuffix?.className).toContain("@3xl/feed:inline");
  const code = within(resolvedRow).getByText("gh pr merge --squash");
  expect(code.className).toContain("font-mono");
});

const KIND_CHIP_TABLE = [
  { kind: "gate", glyph: "◆", tone: "text-status-waiting", size: "size-[30px]" },
  { kind: "question", glyph: "?", tone: "text-status-waiting", size: "size-[30px]" },
  { kind: "alert", glyph: "⚠", tone: "text-status-waiting", size: "size-[30px]" },
  { kind: "failed", glyph: "✕", tone: "text-status-failed", size: "size-[26px]" },
  { kind: "done", glyph: "✓", tone: "text-status-done", size: "size-[26px]" },
  { kind: "idle", glyph: "◌", tone: "text-muted-foreground/80", size: "size-[26px]" },
  { kind: "resolved", glyph: "✓", tone: "text-muted-foreground", size: "size-[26px]" },
] as const;

test("status icon chips map glyph, tone, and size per kind — always decorative", async () => {
  renderAt("/");
  await settle();
  for (const entry of KIND_CHIP_TABLE) {
    const chip = rowByKind(entry.kind).querySelector('[data-slot="status-icon-chip"]');
    expect(chip?.textContent, entry.kind).toBe(entry.glyph);
    expect(chip?.getAttribute("aria-hidden"), entry.kind).toBe("true");
    expect(chip?.className, entry.kind).toContain(entry.tone);
    expect(chip?.className, entry.kind).toContain(entry.size);
  }
  // The resolved chip takes the outline treatment (and tw-merge drops the
  // idle tone's /80 in favor of the outline's full muted-foreground).
  const resolvedChip = rowByKind("resolved").querySelector('[data-slot="status-icon-chip"]');
  expect(resolvedChip?.className).toContain("border-border");
  expect(resolvedChip?.className).not.toContain("text-muted-foreground/80");
});

test("container-anatomy pins: the page declares @container/feed and the twins flip at @3xl/feed", async () => {
  renderAt("/");
  await settle();
  const main = mainEl();

  const pageRoot = main.firstElementChild;
  expect(pageRoot?.className).toContain("@container/feed");
  expect(pageRoot?.className).toContain("max-w-6xl");

  const gateRow = rowByKind("gate");
  expect(gateRow.className).toContain("items-start");
  expect(gateRow.className).toContain("@3xl/feed:items-center");
  const body = gateRow.querySelector(".min-w-0");
  expect(body?.className).toContain("flex-1");

  const ageChip = gateRow.querySelector('[data-slot="feed-chip"]');
  expect(ageChip?.textContent).toBe("4m");
  expect(ageChip?.className).toContain("hidden");
  expect(ageChip?.className).toContain("@3xl/feed:inline-flex");

  const feedAction = gateRow.querySelector('[data-slot="feed-action"]');
  expect(feedAction?.className).toContain("hidden");
  expect(feedAction?.className).toContain("@3xl/feed:inline-flex");

  const chevron = gateRow.querySelector('[data-slot="feed-chevron"]');
  expect(chevron?.className).toContain("@3xl/feed:hidden");

  const failedAge = rowByKind("failed").querySelector('[data-slot="feed-age"]');
  expect(failedAge?.textContent).toBe("1h");
  expect(failedAge?.className).toContain("hidden");
  expect(failedAge?.className).toContain("@3xl/feed:inline");
  // The failed/done chevron persists at every width — no hidden twin.
  expect(rowByKind("failed").querySelector('[data-slot="feed-chevron"]')?.className).not.toContain(
    "hidden",
  );

  const caption = within(main).getByText(
    "Items never vanish silently — resolved checks off in place, storms collapse to one row.",
  );
  expect(caption.className).toContain("hidden");
  expect(caption.className).toContain("@3xl/feed:block");
});

test("temp links carry the /argus/ prefix under the deployed basepath", async () => {
  renderAt("/argus/", "/argus/");
  await settle();
  const main = within(mainEl());
  for (const [name, href] of [
    ["View runs", "/argus/runs"],
    ["View projects", "/argus/projects"],
    ["View board", "/argus/board"],
    ["Styleguide", "/argus/styleguide"],
  ] as const) {
    expect(main.getByRole("link", { name }).getAttribute("href")).toBe(href);
  }
});
