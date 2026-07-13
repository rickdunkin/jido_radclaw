import { cleanup, render, screen, within } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { afterEach, expect, test } from "vite-plus/test";
import type { StatusDotStatus } from "@/components/system/status-dot";
import { createAppRouter } from "./router.tsx";

// PROVIDER-LESS render on purpose (router.test.tsx precedent): no Apollo
// provider at all, so any Apollo usage in the spec sheet throws — a
// MockedProvider with empty mocks would still supply a client and let
// async query errors slip. This is a no-Apollo guard only; static fixture
// seams like useShellData render fine provider-less — the data-seam
// boundary is enforced by system-boundary.test.ts.
async function renderStyleguide(path = "/styleguide", basepath?: string) {
  const router = createAppRouter({
    basepath,
    history: createMemoryHistory({ initialEntries: [path] }),
  });
  render(<RouterProvider router={router} />);
  await screen.findByRole("heading", { name: "argus" });
}

function dots(status: StatusDotStatus): HTMLElement[] {
  return Array.from(
    document.querySelectorAll<HTMLElement>(`[data-slot="status-dot"][data-status="${status}"]`),
  );
}

afterEach(() => {
  cleanup();
});

const GLOW_CLASSES = ["shadow-[0_0_8px]", "shadow-status-working/80"];

// status → the class list every instance must carry (recipe axis only;
// size axis asserted separately). online borrows done's green; blocked
// borrows idle's hue; unknown/offline share the offline token.
const DOT_RECIPE: Record<StatusDotStatus, readonly string[]> = {
  working: ["bg-status-working", ...GLOW_CLASSES],
  waiting: ["bg-status-waiting"],
  failed: ["bg-status-failed"],
  done: ["bg-status-done"],
  online: ["bg-status-done"],
  idle: ["bg-status-idle/35"],
  blocked: ["border-status-idle/75"],
  unknown: ["border-dashed", "border-status-offline"],
  offline: ["border-status-offline"],
};
const HOLLOW: readonly StatusDotStatus[] = ["blocked", "unknown", "offline"];

test("StatusDot vocabulary: all 9 statuses in both sizes, recipes and hollow widths pinned", async () => {
  await renderStyleguide();
  for (const [status, recipe] of Object.entries(DOT_RECIPE)) {
    const instances = dots(status as StatusDotStatus);
    // The vocabulary table renders md + sm for every status (composed
    // indicators and other sections may add more instances).
    const bySize = {
      md: instances.filter((dot) => dot.classList.contains("size-2")),
      sm: instances.filter((dot) => dot.classList.contains("size-1.5")),
    };
    expect(bySize.md.length, `${status} md`).toBeGreaterThan(0);
    expect(bySize.sm.length, `${status} sm`).toBeGreaterThan(0);
    expect(bySize.md.length + bySize.sm.length, `${status} sized`).toBe(instances.length);
    for (const dot of instances) {
      expect(dot.getAttribute("aria-hidden"), status).toBe("true");
      for (const cls of ["inline-block", "shrink-0", "rounded-full", ...recipe]) {
        expect(dot.classList.contains(cls), `${status} → ${cls}`).toBe(true);
      }
      // Hollow border width is size-proportional: 1.5px @ md, 1px @ sm.
      const hollow = HOLLOW.includes(status as StatusDotStatus);
      expect(dot.classList.contains("border-[1.5px]"), `${status} md border`).toBe(
        hollow && dot.classList.contains("size-2"),
      );
      expect(dot.classList.contains("border"), `${status} sm border`).toBe(
        hollow && dot.classList.contains("size-1.5"),
      );
      // Fills never carry the glow unless they are `working`.
      if (status !== "working") {
        for (const cls of GLOW_CLASSES) {
          expect(dot.classList.contains(cls), `${status} must not glow`).toBe(false);
        }
      }
    }
  }
});

test("composed indicators: `live` is glow-less online; `thread live`/`editing` are glowing working", async () => {
  await renderStyleguide();
  const row = document.querySelector<HTMLElement>('[data-slot="sg-composed-indicators"]');
  if (!row) throw new Error("composed indicators row not rendered");

  const live = within(row).getByText("live", { exact: true }).closest("span");
  const liveDot = live?.querySelector('[data-slot="status-dot"]');
  expect(liveDot?.getAttribute("data-status")).toBe("online");
  for (const cls of GLOW_CLASSES) {
    expect(liveDot?.classList.contains(cls), "live never glows").toBe(false);
  }

  for (const label of ["thread live", /^editing /] as const) {
    const host = within(row).getByText(label).closest("span");
    const dot = host?.querySelector('[data-slot="status-dot"]');
    expect(dot?.getAttribute("data-status"), String(label)).toBe("working");
    for (const cls of GLOW_CLASSES) {
      expect(dot?.classList.contains(cls), `${String(label)} glows`).toBe(true);
    }
  }
});

const CARD_NAMES = [
  "export-pipeline wants to run a command",
  "webhook-endpoints asked",
  "Plan review — export pipeline",
  "release-notes wants to force-push main",
  "Allow rm -rf node_modules — expired",
];

test("DecisionCard shell: labelled articles, tone chrome, meta line, trailing slot", async () => {
  await renderStyleguide();

  const cards = CARD_NAMES.map((name) => screen.getByRole("article", { name }));
  expect(document.querySelectorAll('[data-slot="decision-card"]')).toHaveLength(cards.length);

  for (const card of cards) {
    for (const cls of ["rounded-[14px]", "border", "p-[13px]", "gap-[11px]"]) {
      expect(card.classList.contains(cls), cls).toBe(true);
    }
    const header = card.querySelector('[data-slot="decision-card-header"]');
    expect(header).not.toBeNull();
    // Every demo passes meta — the header carries a MetaLine.
    expect(header?.querySelector('[data-slot="meta-line"]')).not.toBeNull();

    if (card.getAttribute("data-tone") === "amber") {
      for (const cls of [
        "border-status-waiting/45",
        "dark:border-status-waiting/30",
        "bg-card",
        "shadow-xs",
        "dark:shadow-none",
      ]) {
        expect(card.classList.contains(cls), `amber → ${cls}`).toBe(true);
      }
    } else {
      for (const cls of ["border-dashed", "bg-card/60", "text-muted-foreground"]) {
        expect(card.classList.contains(cls), `muted → ${cls}`).toBe(true);
      }
      expect(card.classList.contains("shadow-xs"), "muted has no shadow").toBe(false);
    }
  }

  // Tone split: exactly the expired card is muted.
  const expired = screen.getByRole("article", { name: "Allow rm -rf node_modules — expired" });
  expect(expired.getAttribute("data-tone")).toBe("muted");
  expect(
    cards.filter((card) => card.getAttribute("data-tone") === "amber"),
    "irreversible keeps the amber tone; red enters via the icon slot",
  ).toHaveLength(4);

  // Trailing slots render inside the header: the compact gate's chevron and
  // the expired card's dismiss chip.
  const gate = screen.getByRole("article", { name: "Plan review — export pipeline" });
  expect(
    gate
      .querySelector('[data-slot="decision-card-header"]')
      ?.querySelector('[data-slot="feed-chevron"]'),
  ).not.toBeNull();
  expect(within(expired).getByText("Dismiss")).toBeDefined();
});

const FOCUSABLE =
  "a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]";

test("DecisionCard demos are inert: no focusable control inside any card", async () => {
  await renderStyleguide();
  for (const card of Array.from(document.querySelectorAll('[data-slot="decision-card"]'))) {
    // Scoped per card — the Controls section legitimately renders Buttons.
    expect(card.querySelectorAll(FOCUSABLE)).toHaveLength(0);
  }
});

test("spec-sheet structure: one h1, every section present, root declares @container/feed", async () => {
  await renderStyleguide();
  expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
  for (const label of [
    "STATUS DOTS",
    "STATUS ICON CHIPS",
    "CHIPS",
    "GROUP PANELS",
    "FEED ROWS",
    "DECISION CARDS",
    "CONTROLS",
  ]) {
    const heading = screen.getByRole("heading", { level: 2, name: label });
    expect(heading.closest("section")?.getAttribute("aria-labelledby")).toBe(heading.id);
  }
  const root = document.querySelector<HTMLElement>('[data-slot="styleguide-root"]');
  expect(root?.classList.contains("@container/feed")).toBe(true);
  expect(root?.classList.contains("max-w-4xl")).toBe(true);
});

test("resolves under the deployed /argus/ prefix", async () => {
  await renderStyleguide("/argus/styleguide", "/argus/");
  expect(screen.getByRole("heading", { name: "argus" })).toBeDefined();
});
