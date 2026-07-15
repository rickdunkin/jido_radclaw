import { MockedProvider } from "@apollo/client/testing/react";
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { afterEach, expect, test, vi } from "vite-plus/test";
import {
  acceptInboxConnection,
  type ApprovalsInboxData,
  type ApprovalsInboxSeamResult,
  type ApprovalsSummaryData,
  type ApprovalsSummarySeamResult,
  createFetchMoreGuard,
  type NeedsInputCase,
  type PendingCase,
  type PendingCaseKind,
  PREVIEW_NOW,
  type ToolCallCase,
} from "./lib/approvals-data.ts";
import { type DecisionState, type Resolution } from "./lib/approvals-local-state.ts";
import { QuestionCard, ToolCallCard } from "./routes/_shell/approvals.tsx";
import { createAppRouter } from "./router.tsx";

// Sentinel seam data lives in its OWN file (shell-seam precedent: vi.mock
// hoists module-wide). The summary and inbox seams are mocked INDEPENDENTLY
// — the whole point of the source-level split — through a hoisted holder
// the mocked hooks subscribe to via useSyncExternalStore, so a test can
// swap either seam mid-render (stateful two-page pagination, late summary
// responses) and the tree re-renders. Per-test objects are built once, so
// the provider coordinator sees stable identities.
const seam = vi.hoisted(() => {
  const listeners = new Set<() => void>();
  const state: { summary?: unknown; inbox?: unknown } = {};
  return {
    state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    set: (partial: { summary?: unknown; inbox?: unknown }) => {
      Object.assign(state, partial);
      for (const listener of listeners) listener();
    },
    reset: () => {
      state.summary = undefined;
      state.inbox = undefined;
    },
  };
});

vi.mock(import("./lib/approvals-data.ts"), async (importOriginal) => {
  const original = await importOriginal();
  const { useSyncExternalStore } = await import("react");
  return {
    ...original,
    useApprovalsSummaryData: () => {
      const override = useSyncExternalStore(seam.subscribe, () => seam.state.summary);
      return (override ?? original.useApprovalsSummaryData()) as ReturnType<
        typeof original.useApprovalsSummaryData
      >;
    },
    useApprovalsInboxData: () => {
      const override = useSyncExternalStore(seam.subscribe, () => seam.state.inbox);
      return (override ?? original.useApprovalsInboxData()) as ReturnType<
        typeof original.useApprovalsInboxData
      >;
    },
  };
});

// ---------------------------------------------------------------------------
// Sentinel builders — everything derives from insertedAt + display age (the
// declared contract fields), never fixture literals.
// ---------------------------------------------------------------------------

function sentinelToolCall(id: string, overrides?: Partial<ToolCallCase>): ToolCallCase {
  return {
    id,
    kind: "tool_call",
    threadRef: "sentinel-pipeline",
    project: "sentinel-project",
    node: "sentinel-node",
    worktree: null,
    taskRef: null,
    age: "7m",
    insertedAt: "2026-07-14T11:53:00.000Z",
    presentation: {
      type: "command",
      commandPreview: "sentinel deploy",
      complete: true,
      riskNote: "sentinel risk",
      authorization: { template: "main", target: null },
    },
    scopeOptions: [
      { id: `${id}-once`, kind: "once" },
      { id: `${id}-project`, kind: "project", project: "helios-api", ttlDays: 3 },
    ],
    ...overrides,
  };
}

function sentinelQuestion(id: string, overrides?: Partial<NeedsInputCase>): NeedsInputCase {
  return {
    id,
    kind: "needs_input",
    threadRef: "sentinel-thread",
    project: "sentinel-project",
    node: "sentinel-node",
    age: "9m",
    insertedAt: "2026-07-14T11:51:00.000Z",
    question: "sentinel question?",
    ...overrides,
  };
}

function summaryOf(
  cases: readonly PendingCase[],
  overrides?: Partial<ApprovalsSummaryData>,
): ApprovalsSummaryData {
  const pendingByKind: Record<PendingCaseKind, number> = {
    tool_call: 0,
    needs_input: 0,
    plan: 0,
    irreversible_write: 0,
    review_stall: 0,
  };
  for (const item of cases) pendingByKind[item.kind] += 1;
  return {
    version: 1,
    asOf: PREVIEW_NOW,
    pendingByKind,
    total: cases.length,
    oldestInsertedAt: cases.length > 0 ? "2026-07-14T11:18:00.000Z" : null, // 42m before PREVIEW_NOW
    grantsCount: 9,
    ...overrides,
  };
}

function summaryResult(
  data: ApprovalsSummaryData | undefined,
  status: "idle" | "loading" | "error" = "idle",
  refetch: () => void = () => undefined,
): ApprovalsSummarySeamResult {
  return { data, status, refetch };
}

function inboxOf(pending: readonly PendingCase[], hasNextPage = false): ApprovalsInboxData {
  return { snapshotVersion: null, pending, pageInfo: { hasNextPage, endCursor: null } };
}

function inboxResult(
  data: ApprovalsInboxData | undefined,
  overrides?: Partial<ApprovalsInboxSeamResult>,
): ApprovalsInboxSeamResult {
  return {
    data,
    initialStatus: "idle",
    refetch: () => undefined,
    fetchMore: () => undefined,
    fetchMoreStatus: "idle",
    ...overrides,
  };
}

function renderAt(path: string) {
  const router = createAppRouter({
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
  await screen.findByRole("heading", { level: 1, name: "Approvals" });
}

function mainEl(): HTMLElement {
  return screen.getByRole("main");
}

const FOCUSABLE =
  "a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]";

function actionable(scope: HTMLElement): Element[] {
  return Array.from(scope.querySelectorAll(FOCUSABLE)).filter(
    (element) => element.getAttribute("tabindex") !== "-1",
  );
}

function noopHandlers() {
  return {
    draft: {},
    onDraftChange: vi.fn(),
    onResolve: vi.fn(),
    onRetryReconcile: vi.fn(),
    onDismiss: vi.fn(),
  };
}

afterEach(() => {
  cleanup();
  seam.reset();
});

// ---------------------------------------------------------------------------
// The rendered screen against sentinel seams.
// ---------------------------------------------------------------------------

test("the screen renders counts, header meta, cards, and form names from the seams — never fixture literals", async () => {
  const cases = [sentinelToolCall("s-cmd"), sentinelQuestion("s-q")];
  seam.set({
    summary: summaryResult(summaryOf(cases)),
    inbox: inboxResult(inboxOf(cases)),
  });
  renderAt("/approvals");
  await settle();

  expect(screen.getByRole("tab", { name: "Pending 2" })).toBeDefined();
  expect(screen.getByRole("tab", { name: "Grants 9" })).toBeDefined();
  expect(mainEl().querySelector('[data-slot="page-meta"]')?.textContent).toBe("oldest 42m");
  expect(document.querySelector('[data-slot="pending-summary"]')?.textContent).toBe(
    "1 decide · 1 reply",
  );

  // Sentinel-derived titles and form names — proof the labels derive from
  // the case, not fixture literals.
  expect(
    screen.getByRole("article", { name: /sentinel-pipeline wants to run a command/ }),
  ).toBeDefined();
  expect(screen.getByRole("article", { name: /sentinel-thread asked/ })).toBeDefined();
  expect(screen.getByRole("form", { name: "Decide sentinel-pipeline" })).toBeDefined();
  expect(screen.getByRole("form", { name: "Reply to sentinel-thread" })).toBeDefined();

  // Approving with the structured project option renders copy PROVABLY
  // derived from the structure — no label field exists on the wire type to
  // parse or forge.
  const card = screen.getByRole("article", { name: /sentinel-pipeline wants to run a command/ });
  fireEvent.click(within(card).getByRole("radio", { name: "helios-api · 3 days" }));
  fireEvent.click(within(card).getByRole("button", { name: "Approve — helios-api · 3 days" }));
  expect(card.querySelector('[data-slot="decision-resolution"]')?.textContent).toBe(
    "Approved — helios-api · 3 days",
  );
});

test("a single once-only option renders no ALLOW group; approve still carries its label and resolves", async () => {
  const hardBlock = sentinelToolCall("s-hard", {
    scopeOptions: [{ id: "s-hard-once", kind: "once" }],
  });
  seam.set({
    summary: summaryResult(summaryOf([hardBlock])),
    inbox: inboxResult(inboxOf([hardBlock])),
  });
  renderAt("/approvals");
  await settle();

  const card = screen.getByRole("article", { name: /sentinel-pipeline/ });
  // The hard-block shape (needs-doc #2): one-shot approval survives, only
  // standing grants disappear — no choice to present, no radios.
  expect(within(card).queryByRole("group", { name: "ALLOW…" })).toBeNull();
  expect(within(card).queryAllByRole("radio")).toHaveLength(0);
  fireEvent.click(within(card).getByRole("button", { name: "Approve — just once" }));
  expect(card.querySelector('[data-slot="decision-resolution"]')?.textContent).toBe(
    "Approved — just once",
  );
});

test("a sentinel irreversible_write row renders the GenericCaseCard — the total-renderer pin", async () => {
  const generic: PendingCase = {
    id: "s-irr",
    kind: "irreversible_write",
    title: "sentinel irreversible write",
    threadRef: null,
    project: "sentinel-project",
    node: "sentinel-node",
    age: "2m",
    insertedAt: "2026-07-14T11:58:00.000Z",
  };
  seam.set({
    summary: summaryResult(summaryOf([generic])),
    inbox: inboxResult(inboxOf([generic])),
  });
  renderAt("/approvals");
  await settle();

  const card = screen.getByRole("article", { name: "sentinel irreversible write" });
  expect(card.querySelector('[data-slot="meta-line"]')?.textContent).toBe(
    "sentinel-project · sentinel-node · 2m",
  );
  expect(
    within(card).getByText("this case type gets its full card in a later slice"),
  ).toBeDefined();
  expect(actionable(card)).toHaveLength(0);
});

// ---------------------------------------------------------------------------
// Presentation-well distinguishability (unit renders — the well is the same
// component the route mounts).
// ---------------------------------------------------------------------------

test("generic presentations render through the shared well: no $ prompt, byte-exact text, marked tabs", () => {
  const invocation = 'forget(memory_id: "mem_9f3a",\n  note: "a  b\tc")';
  const item = sentinelToolCall("s-gen", {
    presentation: {
      type: "generic",
      invocationSummary: invocation,
      complete: true,
      authorization: { template: "main", target: null },
    },
  });
  render(<ToolCallCard item={item} decision={undefined} {...noopHandlers()} />);

  const pre = document.querySelector("pre");
  expect(pre?.className).toContain("whitespace-pre");
  // No $ prompt — a generic invocation isn't a shell line.
  expect(pre?.querySelector("span[aria-hidden='true']")).toBeNull();
  // Byte-exact copy channel: no character dropped, no ambiguous elision.
  expect(pre?.querySelector("code")?.textContent).toBe(invocation);
  const tabMarkers = pre?.querySelectorAll('[data-ws="tab"]') ?? [];
  expect(tabMarkers).toHaveLength(1);
  expect(tabMarkers[0].className).toContain("before:content-");
  expect(tabMarkers[0].textContent).toBe("\t");
  // Title copy derives from presentation.type.
  expect(screen.getByRole("article", { name: /wants to run a tool/ })).toBeDefined();
});

test("trailing-run length is visibly distinguishable per character; a spaces-only twin has no tab marker", () => {
  const oneTrailing = sentinelToolCall("s-t1", {
    presentation: {
      type: "command",
      commandPreview: "deploy now ",
      complete: true,
      riskNote: "r",
      authorization: { template: "main", target: null },
    },
  });
  const { unmount } = render(
    <ToolCallCard item={oneTrailing} decision={undefined} {...noopHandlers()} />,
  );
  let code = document.querySelector("pre code");
  expect(code?.textContent).toBe("deploy now ");
  let trailing = document.querySelectorAll('[data-ws="trailing"]');
  expect(trailing).toHaveLength(1);
  expect(trailing[0].className).toContain("before:content-");
  unmount();

  const twoTrailing = sentinelToolCall("s-t2", {
    presentation: {
      type: "command",
      commandPreview: "deploy now  ",
      complete: true,
      riskNote: "r",
      authorization: { template: "main", target: null },
    },
  });
  const second = render(
    <ToolCallCard item={twoTrailing} decision={undefined} {...noopHandlers()} />,
  );
  code = document.querySelector("pre code");
  expect(code?.textContent).toBe("deploy now  ");
  trailing = document.querySelectorAll('[data-ws="trailing"]');
  expect(trailing).toHaveLength(2);
  second.unmount();

  // Visually-identical-when-collapsed spaces-only twin: interior runs are
  // preserved by whitespace-pre and carry NO tab marker.
  const spacesOnly = sentinelToolCall("s-t3", {
    presentation: {
      type: "command",
      commandPreview: "deploy  now",
      complete: true,
      riskNote: "r",
      authorization: { template: "main", target: null },
    },
  });
  render(<ToolCallCard item={spacesOnly} decision={undefined} {...noopHandlers()} />);
  code = document.querySelector("pre code");
  expect(code?.textContent).toBe("deploy  now");
  expect(document.querySelectorAll('[data-ws="tab"]')).toHaveLength(0);
  expect(document.querySelectorAll('[data-ws="trailing"]')).toHaveLength(0);
});

test("incomplete presentations refuse approval in BOTH variants: disabled Approve, zero radios, honest line", () => {
  const incompleteCommand = sentinelToolCall("s-inc1", {
    presentation: {
      type: "command",
      commandPreview: "truncated…",
      complete: false,
      riskNote: "r",
      authorization: { template: "main", target: null },
    },
  });
  const first = render(
    <ToolCallCard item={incompleteCommand} decision={undefined} {...noopHandlers()} />,
  );
  expect(screen.getByRole("button", { name: /Approve/ }).hasAttribute("disabled")).toBe(true);
  expect(
    screen.getByText(
      "preview incomplete — the full invocation must be inspectable before approval",
    ),
  ).toBeDefined();
  expect(screen.queryAllByRole("radio")).toHaveLength(0);
  // The note and Reject stay — a rejection may carry a note.
  expect(screen.getByRole("textbox", { name: "Add a note (optional)" })).toBeDefined();
  expect(screen.getByRole("button", { name: "Reject" }).hasAttribute("disabled")).toBe(false);
  first.unmount();

  const incompleteGeneric = sentinelToolCall("s-inc2", {
    presentation: {
      type: "generic",
      invocationSummary: "bounded(…)",
      complete: false,
      authorization: { template: "main", target: null },
    },
  });
  render(<ToolCallCard item={incompleteGeneric} decision={undefined} {...noopHandlers()} />);
  expect(screen.getByRole("button", { name: /Approve/ }).hasAttribute("disabled")).toBe(true);
  expect(screen.queryAllByRole("radio")).toHaveLength(0);
});

// ---------------------------------------------------------------------------
// Malformed-payload fences — reject-only means NO focusable standing options
// survive, not just a disabled Approve.
// ---------------------------------------------------------------------------

function expectRejectOnly(card: HTMLElement) {
  expect(within(card).queryByRole("button", { name: /Approve/ })).toBeNull();
  expect(within(card).queryAllByRole("radio")).toHaveLength(0);
  expect(within(card).getByText(/standing approval unavailable/)).toBeDefined();
  expect(within(card).getByRole("button", { name: "Reject" }).hasAttribute("disabled")).toBe(false);
}

test("scope sets missing once, empty, duplicated-id, and unsafe-name sets all render reject-only", () => {
  const missingOnce = sentinelToolCall("s-m1", {
    scopeOptions: [{ id: "only-thread", kind: "thread", threadRef: "t" }],
  });
  const empty = sentinelToolCall("s-m2", { scopeOptions: [] });
  // A duplicated id shared between the once and project options could
  // display one-shot consent while the id binds a standing grant.
  const duplicated = sentinelToolCall("s-m3", {
    scopeOptions: [
      { id: "dup", kind: "once" },
      { id: "dup", kind: "project", project: "quill", ttlDays: 7 },
    ],
  });
  // A control/bidi character in a scope-bound display name could make two
  // distinct scopes render identically or reordered.
  const unsafeName = sentinelToolCall("s-m4", {
    scopeOptions: [
      { id: "u-once", kind: "once" },
      { id: "u-proj", kind: "project", project: "quill‮lliuq", ttlDays: 7 },
    ],
  });
  for (const item of [missingOnce, empty, duplicated, unsafeName]) {
    const { unmount } = render(
      <ToolCallCard item={item} decision={undefined} {...noopHandlers()} />,
    );
    expectRejectOnly(screen.getByRole("article"));
    unmount();
  }
});

test("a stale draft scopeId falls back to the one-shot selection", () => {
  const item = sentinelToolCall("s-stale");
  render(
    <ToolCallCard
      item={item}
      decision={undefined}
      {...noopHandlers()}
      draft={{ scopeId: "id-from-a-previous-option-set" }}
    />,
  );
  expect(screen.getByRole("button", { name: "Approve — just once" })).toBeDefined();
  expect((screen.getByRole("radio", { name: "Just once" }) as HTMLInputElement).checked).toBe(true);
});

// ---------------------------------------------------------------------------
// Authorization-line sentinels — the consent dimensions must be visible and
// distinct where the decision happens.
// ---------------------------------------------------------------------------

test("authorization lines render template + target; identical args with different templates render distinct lines", () => {
  const withTarget = sentinelToolCall("s-a1", {
    presentation: {
      type: "command",
      commandPreview: "deploy",
      complete: true,
      riskNote: "r",
      authorization: { template: "coder", target: "ssh: build-3 · workspace w-12" },
    },
  });
  const first = render(<ToolCallCard item={withTarget} decision={undefined} {...noopHandlers()} />);
  expect(document.querySelector('[data-slot="authorization-context"]')?.textContent).toBe(
    "requested by coder · ssh: build-3 · workspace w-12",
  );
  first.unmount();

  // The identical-args/different-template pin, one per presentation variant.
  const lineFor = (template: string, type: "command" | "generic") => {
    const item = sentinelToolCall(`s-a-${type}-${template}`, {
      presentation:
        type === "command"
          ? {
              type: "command",
              commandPreview: "identical",
              complete: true,
              riskNote: "r",
              authorization: { template, target: null },
            }
          : {
              type: "generic",
              invocationSummary: "identical(…)",
              complete: true,
              authorization: { template, target: null },
            },
    });
    const rendered = render(<ToolCallCard item={item} decision={undefined} {...noopHandlers()} />);
    const text = document.querySelector('[data-slot="authorization-context"]')?.textContent;
    rendered.unmount();
    return text;
  };
  for (const type of ["command", "generic"] as const) {
    const main = lineFor("main", type);
    const coder = lineFor("coder", type);
    expect(main).not.toBe(coder);
    // A null target (a genuinely target-irrelevant tool) renders exactly the
    // template — no dangling separator, no fabricated segment.
    expect(main).toBe("requested by main");
  }
});

// ---------------------------------------------------------------------------
// Decided-but-degraded (needs-doc #3's committed-with-error arm).
// ---------------------------------------------------------------------------

test("a resolved card with followUpFailure shows the outcome plus the resume warning, zero controls", () => {
  const outcome: Resolution = {
    kind: "approved",
    scope: { kind: "once" },
    note: "",
    grantEffect: "none",
  };
  const decision: DecisionState = {
    status: "resolved",
    outcome,
    committedVersion: null,
    followUpFailure: "resume timed out",
  };
  render(<ToolCallCard item={sentinelToolCall("s-f")} decision={decision} {...noopHandlers()} />);
  const card = screen.getByRole("article");
  const status = card.querySelector('[data-slot="decision-resolution"]');
  expect(status?.textContent).toContain("Approved — just once");
  expect(status?.textContent).toContain(
    "decided, but the workflow failed to resume — resume timed out",
  );
  expect(actionable(card)).toHaveLength(0);
});

// ---------------------------------------------------------------------------
// Null-thread fallbacks for both form variants.
// ---------------------------------------------------------------------------

test("null-thread cases render the An-agent fallback — never 'null' in titles or form names", () => {
  const nullThreadTool = sentinelToolCall("s-n1", { threadRef: null });
  const first = render(
    <ToolCallCard item={nullThreadTool} decision={undefined} {...noopHandlers()} />,
  );
  expect(screen.getByRole("article", { name: "An agent wants to run a command" })).toBeDefined();
  expect(screen.getByRole("form", { name: "Decide agent" })).toBeDefined();
  first.unmount();

  const nullThreadQuestion = sentinelQuestion("s-n2", { threadRef: null });
  render(<QuestionCard item={nullThreadQuestion} decision={undefined} {...noopHandlers()} />);
  expect(screen.getByRole("article", { name: "An agent asked" })).toBeDefined();
  expect(screen.getByRole("form", { name: "Reply to agent" })).toBeDefined();
});

// ---------------------------------------------------------------------------
// Empty dataset + retained snapshots.
// ---------------------------------------------------------------------------

test("an empty dataset renders the semantic empty state; zero-count badges unmount; grants stays honest", async () => {
  seam.set({
    summary: summaryResult(summaryOf([])),
    inbox: inboxResult(inboxOf([])),
  });
  renderAt("/approvals");
  await settle();

  const empty = mainEl().querySelector<HTMLElement>('[data-slot="pending-empty"]');
  expect(empty?.textContent).toBe("Nothing pending — all caught up.");
  expect(empty ? actionable(empty) : null).toHaveLength(0);
  expect(screen.getByRole("tab", { name: "Pending 0" })).toBeDefined();

  // Both shell nav badges unmount at zero — absence is the honest zero.
  const railNav = screen.getByRole("navigation", { name: "Main" });
  const tabBar = screen.getByRole("navigation", { name: "Primary" });
  expect(within(railNav).getByRole("link", { name: "Approvals" })).toBeDefined();
  expect(within(tabBar).getByRole("link", { name: "Approvals" })).toBeDefined();

  fireEvent.click(screen.getByRole("tab", { name: "Grants 9" }));
  expect(await screen.findByText(/standing grants/)).toBeDefined();
});

test("a resolved snapshot keeps rendering after the pending connection drops the row — never the empty panel", async () => {
  const item = sentinelQuestion("s-drop");
  seam.set({
    summary: summaryResult(summaryOf([item])),
    inbox: inboxResult(inboxOf([item])),
  });
  renderAt("/approvals");
  await settle();

  fireEvent.click(
    within(screen.getByRole("article", { name: /sentinel-thread asked/ })).getByRole("button", {
      name: "Reject",
    }),
  );

  // A refetch drops the decided row: the empty arm keys on the MERGED rows,
  // never raw pending — the resolved card must keep rendering in place.
  act(() => {
    seam.set({ inbox: inboxResult(inboxOf([])) });
  });
  const card = screen.getByRole("article", { name: /sentinel-thread asked/ });
  expect(card.querySelector('[data-slot="decision-resolution"]')?.textContent).toBe(
    "Rejected — no answer given",
  );
  expect(mainEl().querySelector('[data-slot="pending-empty"]')).toBeNull();
});

// ---------------------------------------------------------------------------
// Page-level data states — the summary and inbox seams vary INDEPENDENTLY.
// ---------------------------------------------------------------------------

test("summary-success + inbox-loading: skeleton in the list area only; badges keep the summary", async () => {
  const cases = [sentinelToolCall("s-cmd")];
  seam.set({
    summary: summaryResult(summaryOf(cases)),
    inbox: inboxResult(undefined, { initialStatus: "loading" }),
  });
  renderAt("/approvals");
  await settle();

  expect(screen.getByText("loading approvals…")).toBeDefined();
  expect(screen.queryAllByRole("article")).toHaveLength(0);
  // The aggregate is known and honest: badges, TabCounts, page-meta render.
  expect(screen.getByRole("tab", { name: "Pending 1" })).toBeDefined();
  const railNav = screen.getByRole("navigation", { name: "Main" });
  expect(within(railNav).getByRole("link", { name: "Approvals 1" })).toBeDefined();
  expect(mainEl().querySelector('[data-slot="page-meta"]')?.textContent).toBe("oldest 42m");
});

test("summary-success + inbox-error: the error panel's Retry is its only focusable and fires refetch once", async () => {
  const refetch = vi.fn();
  seam.set({
    summary: summaryResult(summaryOf([sentinelToolCall("s-cmd")])),
    inbox: inboxResult(undefined, { initialStatus: "error", refetch }),
  });
  renderAt("/approvals");
  await settle();

  const panel = mainEl().querySelector<HTMLElement>('[data-slot="approvals-error"]');
  expect(panel?.textContent).toContain("couldn't load approvals");
  const controls = panel ? actionable(panel) : [];
  expect(controls).toHaveLength(1);
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  expect(refetch).toHaveBeenCalledTimes(1);
  // Counts stay.
  expect(screen.getByRole("tab", { name: "Pending 1" })).toBeDefined();
});

test("summary-undefined + inbox-success: cards render, badges and counts stay absent", async () => {
  const cases = [sentinelToolCall("s-cmd")];
  seam.set({
    summary: summaryResult(undefined, "loading"),
    inbox: inboxResult(inboxOf(cases)),
  });
  renderAt("/approvals");
  await settle();

  expect(screen.getByRole("article", { name: /sentinel-pipeline/ })).toBeDefined();
  // The badge follows the summary seam only — no fake zeros anywhere.
  expect(screen.getByRole("tab", { name: "Pending" })).toBeDefined();
  expect(screen.getByRole("tab", { name: "Grants" })).toBeDefined();
  expect(mainEl().querySelector('[data-slot="page-meta"]')).toBeNull();
  expect(document.querySelector('[data-slot="pending-summary"]')).toBeNull();
  const railNav = screen.getByRole("navigation", { name: "Main" });
  expect(within(railNav).getByRole("link", { name: "Approvals" })).toBeDefined();
});

test("summary-error with no baseline: the — marker in both bars from the Attention route; count-free grants copy", async () => {
  seam.set({ summary: summaryResult(undefined, "error") });
  renderAt("/");
  await screen.findByRole("heading", { level: 1, name: "Attention" });

  // An outage never masquerades as a healthy zero in persistent chrome.
  const railNav = screen.getByRole("navigation", { name: "Main" });
  const tabBar = screen.getByRole("navigation", { name: "Primary" });
  expect(within(railNav).getByRole("link", { name: "Approvals unavailable" })).toBeDefined();
  expect(within(tabBar).getByRole("link", { name: "Approvals unavailable" })).toBeDefined();
  expect(document.querySelectorAll('[data-slot="approvals-nav-unavailable"]')).toHaveLength(2);
  cleanup();

  renderAt("/approvals?view=grants");
  await settle();
  // Never "undefined standing grants".
  expect(mainEl().querySelector('[data-slot="grants-placeholder"]')?.textContent).toBe(
    "Standing grants — this tab is designed in a later slice (4a).",
  );
});

test("summary-error on the approvals page: quiet status line + Retry wired to the summary refetch", async () => {
  const refetch = vi.fn();
  const cases = [sentinelToolCall("s-cmd")];
  seam.set({
    summary: summaryResult(summaryOf(cases), "error", refetch),
    inbox: inboxResult(inboxOf(cases)),
  });
  renderAt("/approvals");
  await settle();

  expect(screen.getByText("couldn't refresh the approvals summary")).toBeDefined();
  const line = screen.getByText("couldn't refresh the approvals summary");
  fireEvent.click(within(line as HTMLElement).getByRole("button", { name: "Retry" }));
  expect(refetch).toHaveBeenCalledTimes(1);
});

test("summary-error WITH a retained baseline: the stale-badge face from the Attention route", async () => {
  const cases = [sentinelToolCall("a"), sentinelToolCall("b"), sentinelToolCall("c")];
  seam.set({ summary: summaryResult(summaryOf(cases), "error") });
  renderAt("/");
  await screen.findByRole("heading", { level: 1, name: "Attention" });

  const railNav = screen.getByRole("navigation", { name: "Main" });
  const tabBar = screen.getByRole("navigation", { name: "Primary" });
  // Distinct from the cold-error — marker: the number stays, visibly stale.
  expect(within(railNav).getByRole("link", { name: "Approvals 3 — may be stale" })).toBeDefined();
  expect(within(tabBar).getByRole("link", { name: "Approvals 3 — may be stale" })).toBeDefined();
  expect(document.querySelectorAll('[data-stale="true"]')).toHaveLength(2);
});

test("summary-error WITH a retained ZERO baseline renders the unavailable marker, never the healthy-zero absence", async () => {
  seam.set({ summary: summaryResult(summaryOf([]), "error") });
  renderAt("/");
  await screen.findByRole("heading", { level: 1, name: "Attention" });

  // A zero that failed to refresh carries no trustworthy signal: both bars
  // show the — marker (the error-with-no-baseline face), visibly distinct
  // from the healthy zero's absence — and no stale-count badge either.
  const railNav = screen.getByRole("navigation", { name: "Main" });
  const tabBar = screen.getByRole("navigation", { name: "Primary" });
  expect(within(railNav).getByRole("link", { name: "Approvals unavailable" })).toBeDefined();
  expect(within(tabBar).getByRole("link", { name: "Approvals unavailable" })).toBeDefined();
  expect(document.querySelectorAll('[data-slot="approvals-nav-unavailable"]')).toHaveLength(2);
  expect(document.querySelectorAll('[data-stale="true"]')).toHaveLength(0);
});

test("a late regressing summary response never overwrites the accepted baseline", async () => {
  const five = [
    sentinelToolCall("a"),
    sentinelToolCall("b"),
    sentinelToolCall("c"),
    sentinelToolCall("d"),
    sentinelToolCall("e"),
  ];
  seam.set({ summary: summaryResult(summaryOf(five, { version: 2 })) });
  renderAt("/");
  await screen.findByRole("heading", { level: 1, name: "Attention" });
  const railNav = screen.getByRole("navigation", { name: "Main" });
  expect(within(railNav).getByRole("link", { name: "Approvals 5" })).toBeDefined();

  // The late V1 response installs nothing — counts provably unchanged.
  act(() => {
    seam.set({
      summary: summaryResult(summaryOf([sentinelToolCall("x")], { version: 1 })),
    });
  });
  expect(within(railNav).getByRole("link", { name: "Approvals 5" })).toBeDefined();
  expect(within(railNav).queryByRole("link", { name: "Approvals 1" })).toBeNull();
});

test("stale-refresh-error keeps rendering last data with an honest notice and inline Retry", async () => {
  const refetch = vi.fn();
  const cases = [sentinelToolCall("s-cmd")];
  seam.set({
    summary: summaryResult(summaryOf(cases)),
    inbox: inboxResult(inboxOf(cases), { initialStatus: "error", refetch }),
  });
  renderAt("/approvals");
  await settle();

  // Live data is never blanked mid-view.
  expect(screen.getByRole("article", { name: /sentinel-pipeline/ })).toBeDefined();
  const line = screen.getByText("couldn't refresh — showing last data");
  fireEvent.click(within(line as HTMLElement).getByRole("button", { name: "Retry" }));
  expect(refetch).toHaveBeenCalledTimes(1);
});

// ---------------------------------------------------------------------------
// Pagination: the stateful two-page mock merges THROUGH the production
// helpers (the Apollo cache-path proof is needs-doc #4's slice-1 test — no
// inbox GraphQL operation exists yet).
// ---------------------------------------------------------------------------

function twoPageScenario() {
  const pageOneCase = sentinelToolCall("page-1-case");
  const pageTwoCase = sentinelQuestion("page-2-case");
  const pageOne: ApprovalsInboxData = {
    snapshotVersion: null,
    pending: [pageOneCase],
    pageInfo: { hasNextPage: true, endCursor: "cursor-1" },
  };
  const pageTwo: ApprovalsInboxData = {
    snapshotVersion: null,
    pending: [pageTwoCase],
    pageInfo: { hasNextPage: false, endCursor: null },
  };
  let connection = pageOne;
  let fetcherCalls = 0;
  const releases: ((page: ApprovalsInboxData) => void)[] = [];
  const guard = createFetchMoreGuard<ApprovalsInboxData>(
    () => {
      fetcherCalls += 1;
      return new Promise((resolve) => releases.push(resolve));
    },
    (result, context) => {
      connection = acceptInboxConnection(connection, result, {
        mode: "append",
        generation: context.generation,
        after: context.after,
      });
      publish();
    },
  );
  const publish = () => {
    seam.set({
      inbox: inboxResult(connection, {
        fetchMore: (after) => {
          guard.run(after).catch(() => undefined);
        },
      }),
    });
  };
  publish();
  return {
    pageTwo,
    fetcherCalls: () => fetcherCalls,
    release: (page: ApprovalsInboxData) => releases.shift()?.(page),
  };
}

test("two-page load-more: guarded double-activation, page 2 appended, row disappears when complete", async () => {
  const scenario = twoPageScenario();
  seam.set({ summary: summaryResult(summaryOf([sentinelToolCall("page-1-case")])) });
  renderAt("/approvals");
  await settle();

  const loadMore = screen.getByRole("button", { name: "Load more" });
  // Rapid double-activation through the UI issues ONE fetcher call — the
  // guard is the concurrency fence, the disabled face is presentation.
  fireEvent.click(loadMore);
  fireEvent.click(loadMore);
  expect(scenario.fetcherCalls()).toBe(1);

  await act(async () => {
    scenario.release(scenario.pageTwo);
    await Promise.resolve();
  });
  expect(screen.getByRole("article", { name: /sentinel-thread asked/ })).toBeDefined();
  expect(screen.queryByRole("button", { name: "Load more" })).toBeNull();
});

test("fetchMore error: the same row re-labels to an honest retry and fires fetchMore again", async () => {
  const fetchMore = vi.fn();
  const cases = [sentinelToolCall("s-cmd")];
  seam.set({
    summary: summaryResult(summaryOf(cases)),
    inbox: inboxResult(inboxOf(cases, true), { fetchMore, fetchMoreStatus: "error" }),
  });
  renderAt("/approvals");
  await settle();

  const retry = screen.getByRole("button", { name: "Couldn't load more — Retry" });
  fireEvent.click(retry);
  expect(fetchMore).toHaveBeenCalledTimes(1);
});

// ---------------------------------------------------------------------------
// acceptInboxConnection + the generation fence, directly on the helpers.
// ---------------------------------------------------------------------------

test("acceptInboxConnection: replace replaces; append dedupes by id; mismatched certificates null out", () => {
  const a = sentinelToolCall("a");
  const b = sentinelQuestion("b");
  const base = inboxOf([a], true);
  const replacement = acceptInboxConnection(base, inboxOf([b]), {
    mode: "replace",
    generation: 1,
    after: null,
  });
  expect(replacement.pending.map((row) => row.id)).toEqual(["b"]);

  // Append with id dedupe: a row present in both pages appears once, and a
  // repeated already-merged page is idempotent.
  const pageTwo: ApprovalsInboxData = {
    snapshotVersion: null,
    pending: [a, b],
    pageInfo: { hasNextPage: false, endCursor: null },
  };
  const appended = acceptInboxConnection(base, pageTwo, {
    mode: "append",
    generation: 0,
    after: "cursor-1",
  });
  expect(appended.pending.map((row) => row.id)).toEqual(["a", "b"]);
  const repeated = acceptInboxConnection(appended, pageTwo, {
    mode: "append",
    generation: 0,
    after: "cursor-1",
  });
  expect(repeated.pending.map((row) => row.id)).toEqual(["a", "b"]);

  // Pages certified at different summary versions cannot jointly certify.
  const certified = { ...inboxOf([a], true), snapshotVersion: 2 };
  const uncertified = { ...pageTwo, snapshotVersion: 1 };
  expect(
    acceptInboxConnection(certified, uncertified, {
      mode: "append",
      generation: 0,
      after: "cursor-1",
    }).snapshotVersion,
  ).toBeNull();
});

test("generation fence: the full four-step race — a stale completion is discarded before any merge", async () => {
  const merges: Array<{ generation: number; after: string | null; ids: string[] }> = [];
  const resolvers: ((page: ApprovalsInboxData) => void)[] = [];
  let fetcherCalls = 0;
  const guard = createFetchMoreGuard<ApprovalsInboxData>(
    () => {
      fetcherCalls += 1;
      return new Promise((resolve) => resolvers.push(resolve));
    },
    (result, context) => {
      merges.push({
        generation: context.generation,
        after: context.after,
        ids: result.pending.map((row) => row.id),
      });
    },
  );

  // 1. A generation-0 fetch-more starts and stays UNRESOLVED.
  const stale = guard.run("cursor-1");
  expect(fetcherCalls).toBe(1);

  // 2. An initial/refetch replacement mints a new generation, abandoning the
  //    old generation's in-flight entry.
  expect(guard.advance()).toBe(1);

  // 3. A generation-1 load-more on the SAME cursor is NOT blocked (in-flight
  //    state is per-generation; cursor suppression died with generation 0).
  const fresh = guard.run("cursor-1");
  expect(fetcherCalls).toBe(2);
  resolvers[1](inboxOf([sentinelQuestion("fresh-row")]));
  await fresh;
  expect(merges).toEqual([{ generation: 1, after: "cursor-1", ids: ["fresh-row"] }]);

  // A repeated already-merged cursor is a no-op WITHIN the generation.
  await guard.run("cursor-1");
  expect(fetcherCalls).toBe(2);

  // 4. The late generation-0 completion resolves and is DISCARDED before any
  //    merge — it appends nothing.
  resolvers[0](inboxOf([sentinelToolCall("stale-row")]));
  await stale;
  expect(merges).toHaveLength(1);
});
