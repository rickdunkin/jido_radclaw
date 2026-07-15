import { MockedProvider } from "@apollo/client/testing/react";
import {
  act,
  cleanup,
  fireEvent,
  render,
  renderHook,
  screen,
  within,
} from "@testing-library/react";
import { createMemoryHistory, linkOptions, RouterProvider } from "@tanstack/react-router";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { Textarea } from "@/components/ui/textarea";
import {
  type ApprovalsSummaryData,
  caseMeta,
  decisionBucket,
  deriveApprovalsSummary,
  deriveOldestShown,
  formatAge,
  getApprovalsInboxData,
  getApprovalsSummaryData,
  PENDING_CASE_KINDS,
  type PendingCase,
  type PendingCaseKind,
  pendingOrder,
  PREVIEW_NOW,
  scopeLabels,
  type ToolCallCase,
  useApprovalsInboxData,
  useApprovalsSummaryData,
} from "./lib/approvals-data.ts";
import { ApprovalsLocalStateProvider } from "./lib/approvals-local-state-provider.tsx";
import {
  createApprovalsStore,
  type DecisionState,
  overlayDeltas,
  pendingListRows,
  type Resolution,
  resolvedIds,
  retainedDecisionIds,
  useApprovalsActions,
  useApprovalsSummary,
  useDraft,
} from "./lib/approvals-local-state.ts";
import { useShellData } from "./lib/shell-data.ts";
import { QuestionCard, ToolCallCard } from "./routes/_shell/approvals.tsx";
import { createAppRouter } from "./router.tsx";

// ---------------------------------------------------------------------------
// Seam cross-checks: the AUTHORITATIVE summary total is the anchor against
// the shell seam's badge count (never page length — page-equals-total is not
// an invariant), and each hook-named seam serves its getter's singleton.
// ---------------------------------------------------------------------------

test("fixture summary total agrees with the shell seam's approvalsCount; hooks serve the getters' singletons", () => {
  const shell = renderHook(() => useShellData()).result.current;
  expect(getApprovalsSummaryData().total).toBe(shell.approvalsCount);
  const summaryResult = renderHook(() => useApprovalsSummaryData()).result.current;
  expect(summaryResult.data).toBe(getApprovalsSummaryData());
  expect(summaryResult.status).toBe("idle");
  const inboxResult = renderHook(() => useApprovalsInboxData()).result.current;
  expect(inboxResult.data).toBe(getApprovalsInboxData());
  expect(inboxResult.initialStatus).toBe("idle");
  expect(inboxResult.fetchMoreStatus).toBe("idle");
});

// ---------------------------------------------------------------------------
// Pure derivations on SENTINEL data — never only the public fixture, so a
// derivation echoing fixture literals fails here (attention.test.tsx
// precedent). deriveApprovalsSummary is fed EXPLICIT OptimisticDelta
// literals: overlayDeltas and acknowledgement are the store's concern.
// ---------------------------------------------------------------------------

function summaryOf(partial?: {
  version?: number;
  total?: number;
  pendingByKind?: Partial<Record<PendingCaseKind, number>>;
  oldestInsertedAt?: string | null;
  grantsCount?: number;
}): ApprovalsSummaryData {
  const pendingByKind: Record<PendingCaseKind, number> = {
    tool_call: 0,
    needs_input: 0,
    plan: 0,
    irreversible_write: 0,
    review_stall: 0,
    ...partial?.pendingByKind,
  };
  const derivedTotal = Object.values(pendingByKind).reduce((sum, count) => sum + count, 0);
  return {
    version: partial?.version ?? 1,
    asOf: PREVIEW_NOW,
    pendingByKind,
    total: partial?.total ?? derivedTotal,
    oldestInsertedAt: partial?.oldestInsertedAt ?? null,
    grantsCount: partial?.grantsCount ?? 0,
  };
}

test("deriveApprovalsSummary: no deltas returns the summary verbatim, buckets derived via decisionBucket", () => {
  const summary = summaryOf({
    pendingByKind: { tool_call: 2, needs_input: 3, plan: 1 },
    oldestInsertedAt: "2026-07-14T11:18:00.000Z", // 42m before PREVIEW_NOW
  });
  // decide/reply are computed from the wire's per-kind counts — never
  // trusted as pre-bucketed fields.
  expect(deriveApprovalsSummary(summary, [], PREVIEW_NOW)).toEqual({
    pendingLeft: 6,
    decide: 3,
    reply: 3,
    oldestAge: "42m",
  });
});

test("deriveApprovalsSummary: one delta shifts counts; all-deltas reaches the zero branch", () => {
  const summary = summaryOf({ pendingByKind: { tool_call: 1, needs_input: 1 } });
  expect(
    deriveApprovalsSummary(
      summary,
      [{ id: "a", kind: "needs_input", grantEffect: "none" }],
      PREVIEW_NOW,
    ),
  ).toEqual({ pendingLeft: 1, decide: 1, reply: 0 });
  // pendingLeft: 0 lives HERE — the UI floors at 1 (the inert gate card).
  expect(
    deriveApprovalsSummary(
      summary,
      [
        { id: "a", kind: "needs_input", grantEffect: "none" },
        { id: "b", kind: "tool_call", grantEffect: "created" },
      ],
      PREVIEW_NOW,
    ),
  ).toEqual({ pendingLeft: 0, decide: 0, reply: 0 });
});

test("deriveApprovalsSummary is PAGE-FREE: a partial page never undercounts the badge", () => {
  // total 12 with only a 2-row page fetched anywhere — counts derive from
  // the summary alone (the derivation takes no page argument by
  // construction), so one delta yields 11 regardless of rows.
  const summary = summaryOf({ pendingByKind: { tool_call: 10, needs_input: 2 }, total: 12 });
  const derived = deriveApprovalsSummary(
    summary,
    [{ id: "x", kind: "tool_call", grantEffect: "none" }],
    PREVIEW_NOW,
  );
  expect(derived.pendingLeft).toBe(11);
  expect(derived).toEqual({ pendingLeft: 11, decide: 9, reply: 2 });
});

test("deriveApprovalsSummary: age formats via the injected clock and advances between responses", () => {
  const fixture = getApprovalsSummaryData();
  expect(deriveApprovalsSummary(fixture, [], PREVIEW_NOW).oldestAge).toBe("12m");
  // A later injected now yields a larger age — the display advances between
  // responses; no wall-clock reads anywhere.
  expect(deriveApprovalsSummary(fixture, [], "2026-07-14T13:00:00.000Z").oldestAge).toBe("1h");
  expect(formatAge(PREVIEW_NOW, "2026-07-12T12:00:00.000Z")).toBe("2d");
  expect(formatAge(PREVIEW_NOW, PREVIEW_NOW)).toBe("now");
});

test("deriveApprovalsSummary: delta-present/absent pair against a fresher summary", () => {
  const fresher = summaryOf({ version: 2, pendingByKind: { tool_call: 2 } });
  expect(
    deriveApprovalsSummary(
      fresher,
      [{ id: "c", kind: "tool_call", grantEffect: "none" }],
      PREVIEW_NOW,
    ),
  ).toEqual({ pendingLeft: 1, decide: 1, reply: 0 });
  // The same summary WITHOUT that delta equals it exactly — the store-level
  // acknowledgement that produces the absent case is the store's concern.
  expect(deriveApprovalsSummary(fresher, [], PREVIEW_NOW)).toEqual({
    pendingLeft: 2,
    decide: 2,
    reply: 0,
  });
});

test("decisionBucket: a delta of EACH kind decrements pendingLeft AND its own bucket", () => {
  const oneOfEach = summaryOf({
    pendingByKind: {
      tool_call: 1,
      needs_input: 1,
      plan: 1,
      irreversible_write: 1,
      review_stall: 1,
    },
  });
  expect(deriveApprovalsSummary(oneOfEach, [], PREVIEW_NOW)).toEqual({
    pendingLeft: 5,
    decide: 4,
    reply: 1,
  });
  for (const kind of PENDING_CASE_KINDS) {
    const derived = deriveApprovalsSummary(
      oneOfEach,
      [{ id: "d", kind, grantEffect: "none" }],
      PREVIEW_NOW,
    );
    const expected =
      decisionBucket(kind) === "reply"
        ? { pendingLeft: 4, decide: 4, reply: 0 }
        : { pendingLeft: 4, decide: 3, reply: 1 };
    expect(derived, kind).toEqual(expected);
  }
  // needs_input is the only reply kind — decide vs reply never drift.
  expect(PENDING_CASE_KINDS.filter((kind) => decisionBucket(kind) === "reply")).toEqual([
    "needs_input",
  ]);
});

test("fixture + empty delta set derives the mock values", () => {
  expect(deriveApprovalsSummary(getApprovalsSummaryData(), [], PREVIEW_NOW)).toEqual({
    pendingLeft: 3,
    decide: 2,
    reply: 1,
    oldestAge: "12m",
  });
});

// ---------------------------------------------------------------------------
// deriveOldestShown — the route-local header polish. Rows outrank the
// server aggregate ONLY on a version-CERTIFIED complete page.
// ---------------------------------------------------------------------------

function fixtureBaseline() {
  const summary = getApprovalsSummaryData();
  return { oldestInsertedAt: summary.oldestInsertedAt, version: summary.version };
}

test("deriveOldestShown: resolving the oldest on a certified complete page shifts 12m → 4m", () => {
  const shown = deriveOldestShown(
    fixtureBaseline(),
    PREVIEW_NOW,
    getApprovalsInboxData(),
    new Set(["q-hmac"]),
  );
  expect(shown).toBe("4m");
});

test("deriveOldestShown: an incomplete page keeps the server value regardless of rows", () => {
  const inbox = getApprovalsInboxData();
  const partial = { ...inbox, pageInfo: { hasNextPage: true, endCursor: "cursor-1" } };
  expect(deriveOldestShown(fixtureBaseline(), PREVIEW_NOW, partial, new Set(["q-hmac"]))).toBe(
    "12m",
  );
});

test("deriveOldestShown: a null snapshotVersion (every live page pre-certificate) keeps the server value", () => {
  const inbox = getApprovalsInboxData();
  const uncertified = { ...inbox, snapshotVersion: null };
  expect(deriveOldestShown(fixtureBaseline(), PREVIEW_NOW, uncertified, new Set(["q-hmac"]))).toBe(
    "12m",
  );
});

test("deriveOldestShown: a V1-certified page never outlives a V2-accepted summary", () => {
  // Complete, oldest resolved — but the accepted summary has outrun the
  // page's certification, so the server value STILL stands.
  const advanced = { oldestInsertedAt: fixtureBaseline().oldestInsertedAt, version: 2 };
  expect(
    deriveOldestShown(advanced, PREVIEW_NOW, getApprovalsInboxData(), new Set(["q-hmac"])),
  ).toBe("12m");
});

test("deriveOldestShown: all rows resolved on a certified page → undefined; empty resolved set → server value", () => {
  const allResolved = new Set(["cmd-prisma", "q-hmac", "gate-export-plan"]);
  expect(
    deriveOldestShown(fixtureBaseline(), PREVIEW_NOW, getApprovalsInboxData(), allResolved),
  ).toBeUndefined();
  expect(
    deriveOldestShown(fixtureBaseline(), PREVIEW_NOW, getApprovalsInboxData(), new Set()),
  ).toBe("12m");
});

// ---------------------------------------------------------------------------
// caseMeta — exhaustive per kind, null context drops its segment.
// ---------------------------------------------------------------------------

function genericCase(kind: "irreversible_write" | "review_stall"): PendingCase {
  return {
    id: `g-${kind}`,
    kind,
    title: `sentinel ${kind}`,
    threadRef: null,
    project: "sentinel-project",
    node: "sentinel-node",
    age: "9m",
    insertedAt: "2026-07-14T11:51:00.000Z",
  };
}

test("caseMeta reproduces the mock lines exactly for the fixture cases", () => {
  const [cmd, question, gate] = getApprovalsInboxData().pending;
  expect(caseMeta(cmd).join(" · ")).toBe("quill · wt export-stream · atlas · T-214 · 4m");
  expect(caseMeta(question).join(" · ")).toBe("helios-api · wren · 12m");
  expect(caseMeta(gate).join(" · ")).toBe("quill · gate · markdown · 4m");
});

test("caseMeta covers the generic kinds' [project, node, age] arm", () => {
  expect(caseMeta(genericCase("irreversible_write"))).toEqual([
    "sentinel-project",
    "sentinel-node",
    "9m",
  ]);
  expect(caseMeta(genericCase("review_stall"))).toEqual([
    "sentinel-project",
    "sentinel-node",
    "9m",
  ]);
});

test("caseMeta drops null context segments — shorter list, never an empty segment", () => {
  const [cmd] = getApprovalsInboxData().pending;
  if (cmd.kind !== "tool_call") throw new Error("fixture order changed");
  const bare: PendingCase = { ...cmd, worktree: null, taskRef: null, node: null };
  expect(caseMeta(bare)).toEqual(["quill", "4m"]);
  const noProject: PendingCase = { ...cmd, project: null };
  expect(caseMeta(noProject)).toEqual(["wt export-stream", "atlas", "T-214", "4m"]);
  const [, question] = getApprovalsInboxData().pending;
  if (question.kind !== "needs_input") throw new Error("fixture order changed");
  const bareQuestion: PendingCase = { ...question, node: null };
  expect(caseMeta(bareQuestion)).toEqual(["helios-api", "12m"]);
});

// ---------------------------------------------------------------------------
// pendingOrder — the exact client mirror of the required server total order.
// ---------------------------------------------------------------------------

test("the fixture page is sorted by pendingOrder — a shuffled copy re-sorts to it", () => {
  const page = getApprovalsInboxData().pending;
  expect([...page].sort(pendingOrder).map((row) => row.id)).toEqual(page.map((row) => row.id));
  const shuffled = [page[2], page[0], page[1]];
  expect(shuffled.sort(pendingOrder).map((row) => row.id)).toEqual([
    "cmd-prisma",
    "q-hmac",
    "gate-export-plan",
  ]);
});

test("pendingOrder: kind rank beats recency; same-minute ties fall to the id", () => {
  const [cmd] = getApprovalsInboxData().pending;
  if (cmd.kind !== "tool_call") throw new Error("fixture order changed");
  // Two same-minute sentinels — the EXACT insertedAt key collides, so the
  // unique id decides (rounded display ages never participate).
  const first: PendingCase = { ...cmd, id: "aa-first", insertedAt: "2026-07-14T11:50:00.000Z" };
  const second: PendingCase = { ...cmd, id: "ab-second", insertedAt: "2026-07-14T11:50:00.000Z" };
  expect([second, first].sort(pendingOrder).map((row) => row.id)).toEqual([
    "aa-first",
    "ab-second",
  ]);
  // A NEWER rank-0 command still sorts above an OLDER rank-1 question and
  // rank-2 gate — this is what reproduces the mock's card order.
  const newest: PendingCase = { ...cmd, id: "zz-newest", insertedAt: "2026-07-14T11:59:00.000Z" };
  const rows = [...getApprovalsInboxData().pending, newest].sort(pendingOrder);
  expect(rows.map((row) => row.id)).toEqual([
    "cmd-prisma",
    "zz-newest",
    "q-hmac",
    "gate-export-plan",
  ]);
});

// ---------------------------------------------------------------------------
// scopeLabels — every operator-facing scope copy derives from structure.
// ---------------------------------------------------------------------------

test("scopeLabels derives chip/approve/resolved copy from the option structure", () => {
  expect(scopeLabels({ id: "o", kind: "once" })).toEqual({
    chip: "Just once",
    approve: "Approve — just once",
    resolved: "just once",
  });
  expect(scopeLabels({ id: "t", kind: "thread", threadRef: "export-pipeline" })).toEqual({
    chip: "This thread",
    approve: "Approve — this thread",
    resolved: "this thread",
  });
  expect(scopeLabels({ id: "p", kind: "project", project: "quill", ttlDays: 7 })).toEqual({
    chip: "quill · 7 days",
    approve: "Approve — quill · 7 days",
    resolved: "quill · 7 days",
  });
  expect(scopeLabels({ id: "p1", kind: "project", project: "helios-api", ttlDays: 1 }).chip).toBe(
    "helios-api · 1 day",
  );
});

// ---------------------------------------------------------------------------
// Sentinel builders shared by the store/selector and card unit tests.
// ---------------------------------------------------------------------------

function toolCallCase(id: string, overrides?: Partial<ToolCallCase>): ToolCallCase {
  return {
    id,
    kind: "tool_call",
    threadRef: `thread-${id}`,
    project: "sentinel-project",
    node: "sentinel-node",
    worktree: null,
    taskRef: null,
    age: "1m",
    insertedAt: "2026-07-14T11:59:00.000Z",
    presentation: {
      type: "command",
      commandPreview: `echo ${id}`,
      complete: true,
      riskNote: "sentinel risk",
      authorization: { template: "main", target: null },
    },
    scopeOptions: [{ id: `${id}-once`, kind: "once" }],
    ...overrides,
  };
}

function resolvedState(
  outcome: Resolution,
  overrides?: Partial<Extract<DecisionState, { status: "resolved" }>>,
): DecisionState {
  return {
    status: "resolved",
    outcome,
    committedVersion: null,
    followUpFailure: null,
    ...overrides,
  };
}

const REJECTED: Resolution = { kind: "rejected", note: "" };
const APPROVED_WITH_GRANT: Resolution = {
  kind: "approved",
  scope: { kind: "thread", threadRef: "t" },
  note: "",
  grantEffect: "created",
};

// ---------------------------------------------------------------------------
// Store + selector unit tests — no React, no store backdoor: the exported
// pure selectors and the store's public producers are the whole surface.
// ---------------------------------------------------------------------------

test("selectors: resolvedIds vs retainedDecisionIds vs overlayDeltas over a mixed decisions map", () => {
  const snapA = toolCallCase("a");
  const snapB = toolCallCase("b");
  const snapC = toolCallCase("c");
  const snapD = toolCallCase("d");
  const decisions = new Map<string, DecisionState>([
    ["a", { status: "submitting" }],
    // Unacknowledged (committed above the baseline version below).
    ["b", resolvedState(APPROVED_WITH_GRANT, { committedVersion: 3 })],
    // Baseline-covered (committed at ≤ the baseline version) — acknowledged.
    ["c", resolvedState(REJECTED, { committedVersion: 1 })],
    [
      "d",
      {
        status: "error",
        code: "infra",
        action: "approve",
        disposition: "retryable",
        allowedActions: new Set(["approve", "reject"]),
      },
    ],
  ]);
  const snapshots = new Map([
    ["a", snapA],
    ["b", snapB],
    ["c", snapC],
    ["d", snapD],
  ]);
  const baseline = summaryOf({ version: 2, pendingByKind: { tool_call: 5 } });

  // Rendering never loses a card: BOTH resolved entries, ack'd or not.
  expect(resolvedIds({ decisions })).toEqual(new Set(["b", "c"]));
  // The retention feed is wider than the styling feed: every entry with any
  // decision state (the error here has a live recovery path).
  expect(retainedDecisionIds({ decisions })).toEqual(new Set(["a", "b", "c", "d"]));

  // Deltas ONLY for resolutions stamped null or > baseline version, with
  // kind and grantEffect read from the snapshot/outcome. Transient states
  // (submitting, error) keep counting pending — no delta.
  const deltas = overlayDeltas({ decisions, snapshots, acceptedBaseline: baseline });
  expect(deltas).toEqual([{ id: "b", kind: "tool_call", grantEffect: "created" }]);

  // Null committedVersion is never acknowledged.
  const nullStamped = new Map<string, DecisionState>([["b", resolvedState(REJECTED)]]);
  expect(overlayDeltas({ decisions: nullStamped, snapshots, acceptedBaseline: baseline })).toEqual([
    { id: "b", kind: "tool_call", grantEffect: "none" },
  ]);
});

test("selectors: a resolved entry with followUpFailure derives identically to a clean one", () => {
  const snapshots = new Map([["a", toolCallCase("a")]]);
  const clean = new Map<string, DecisionState>([["a", resolvedState(REJECTED)]]);
  const degraded = new Map<string, DecisionState>([
    ["a", resolvedState(REJECTED, { followUpFailure: "resume timed out" })],
  ]);
  const state = { snapshots, acceptedBaseline: null };
  expect(overlayDeltas({ decisions: degraded, ...state })).toEqual(
    overlayDeltas({ decisions: clean, ...state }),
  );
  expect(resolvedIds({ decisions: degraded })).toEqual(resolvedIds({ decisions: clean }));
});

test("store: acceptBaseline is monotonic and the late-response case acknowledges from birth", () => {
  const store = createApprovalsStore();
  const v3 = summaryOf({ version: 3, pendingByKind: { tool_call: 2 }, grantsCount: 4 });
  store.acceptBaseline(v3);
  expect(store.getSummaryResult().summary?.pendingLeft).toBe(2);

  // A regressing baseline installs nothing — counts unchanged.
  store.acceptBaseline(summaryOf({ version: 2, pendingByKind: { tool_call: 9 } }));
  expect(store.getBaselineMeta()?.version).toBe(3);
  expect(store.getSummaryResult().summary?.pendingLeft).toBe(2);

  // Decision B committed at V2 but its response lands after V3 installed:
  // its resolution derives as acknowledged from birth — no delta ever
  // emitted, counts equal the V3 baseline exactly, and its created-grant
  // effect adds nothing to the grants field.
  const item = toolCallCase("b");
  store.resolve(item, APPROVED_WITH_GRANT);
  const decisions = new Map(store.getState().decisions);
  decisions.set("b", resolvedState(APPROVED_WITH_GRANT, { committedVersion: 2 }));
  const acknowledgedDeltas = overlayDeltas({
    decisions,
    snapshots: store.getState().snapshots,
    acceptedBaseline: v3,
  });
  expect(acknowledgedDeltas).toEqual([]);
  expect(deriveApprovalsSummary(v3, acknowledgedDeltas, PREVIEW_NOW).pendingLeft).toBe(2);
});

test("store: the summary snapshot is stable across draft dispatches, refreshes on resolve and on a new refetch identity", () => {
  const fixtureResult = renderHook(() => useApprovalsSummaryData()).result.current;
  const store = createApprovalsStore(fixtureResult);
  const before = store.getSummaryResult();

  // Draft keystrokes never invalidate the shell-facing snapshot.
  store.setDraft("cmd-prisma", { note: "x" });
  expect(store.getSummaryResult()).toBe(before);

  // A resolve does.
  store.resolve(toolCallCase("cmd-prisma"), REJECTED);
  const afterResolve = store.getSummaryResult();
  expect(afterResolve).not.toBe(before);
  expect(afterResolve.summary?.pendingLeft).toBe(2);

  // A replacement refetch callback with unchanged data/status must still
  // reach consumers — a stale captured refetch would retry a dead closure.
  const nextRefetch = () => undefined;
  store.acceptSummaryResult({ data: fixtureResult.data, status: "idle", refetch: nextRefetch });
  const afterRefetch = store.getSummaryResult();
  expect(afterRefetch).not.toBe(afterResolve);
  expect(afterRefetch.refetch).toBe(nextRefetch);
});

test("render-count probe: a draft edit on card A rerenders neither card B nor the badge consumers", () => {
  const log: string[] = [];
  let actions: ReturnType<typeof useApprovalsActions> | undefined;
  function Capture() {
    actions = useApprovalsActions();
    return null;
  }
  function DraftProbe({ id }: { id: string }) {
    useDraft(id);
    log.push(id);
    return null;
  }
  function BadgeProbe() {
    useApprovalsSummary();
    log.push("badge");
    return null;
  }
  render(
    <ApprovalsLocalStateProvider>
      <Capture />
      <DraftProbe id="card-a" />
      <DraftProbe id="card-b" />
      <BadgeProbe />
    </ApprovalsLocalStateProvider>,
  );
  log.length = 0;
  act(() => {
    actions?.setDraft("card-a", { note: "typing" });
  });
  expect(log).toEqual(["card-a"]);
});

// ---------------------------------------------------------------------------
// pendingListRows — the merged render feed.
// ---------------------------------------------------------------------------

function inboxOf(pending: readonly PendingCase[], hasNextPage = false) {
  return {
    snapshotVersion: null,
    pending,
    pageInfo: { hasNextPage, endCursor: null },
  };
}

test("pendingListRows: page rows win on id collision; dropped resolved and reconcile rows render from snapshots", () => {
  const live = toolCallCase("x", { node: "live-node" });
  const snapshotX = toolCallCase("x", { node: "snapshot-node" });
  const snapshotY = toolCallCase("y");
  const decisions = new Map<string, DecisionState>([
    ["x", resolvedState(REJECTED)],
    [
      "y",
      {
        status: "error",
        code: "not_pending",
        action: "approve",
        disposition: "reconcile",
        allowedActions: new Set(),
      },
    ],
  ]);
  const snapshots = new Map([
    ["x", snapshotX],
    ["y", snapshotY],
  ]);
  // The page still carries x — the live row wins; y was dropped by the
  // refetch (a concurrent winner) but its reconcile-locked card must
  // outlive the pending-query row until the by-id result arrives.
  const rows = pendingListRows(inboxOf([live]), { decisions, snapshots });
  expect(rows.map((row) => row.id)).toEqual(["x", "y"]);
  expect(rows[0].kind === "tool_call" && rows[0].node).toBe("live-node");
});

test("pendingListRows: reverse-order double-drop keeps comparator positions; a new rank-0 row slots above retained snapshots", () => {
  const first = toolCallCase("aa", { insertedAt: "2026-07-14T11:50:00.000Z" });
  const middle = toolCallCase("bb", { insertedAt: "2026-07-14T11:53:00.000Z" });
  const last = toolCallCase("cc", { insertedAt: "2026-07-14T11:56:00.000Z" });
  // bb and cc resolved in REVERSE order, then dropped from the dataset:
  // both render in their original comparator positions.
  const decisions = new Map<string, DecisionState>([
    ["cc", resolvedState(REJECTED)],
    ["bb", resolvedState(REJECTED)],
  ]);
  const snapshots = new Map([
    ["bb", middle],
    ["cc", last],
  ]);
  const rows = pendingListRows(inboxOf([first]), { decisions, snapshots });
  expect(rows.map((row) => row.id)).toEqual(["aa", "bb", "cc"]);

  // A NEW rank-0 live row arriving ahead of retained snapshots lands above
  // them exactly where the server would put it — one pendingOrder governs
  // live and retained rows alike.
  const newest = toolCallCase("ab", { insertedAt: "2026-07-14T11:51:00.000Z" });
  const withNew = pendingListRows(inboxOf([first, newest]), { decisions, snapshots });
  expect(withNew.map((row) => row.id)).toEqual(["aa", "ab", "bb", "cc"]);
});

test("pendingListRows: a recovery-less error is NOT retained against a dataset missing the row", () => {
  const decisions = new Map<string, DecisionState>([
    [
      "gone",
      {
        status: "error",
        code: "not_found",
        action: "approve",
        disposition: "terminal",
        allowedActions: new Set(),
      },
    ],
  ]);
  const snapshots = new Map([["gone", toolCallCase("gone")]]);
  // No permanent corpse survives an inbox replacement: the tombstone
  // renders only while its row is still in the data.
  expect(pendingListRows(inboxOf([]), { decisions, snapshots })).toEqual([]);
  // An ACKNOWLEDGED resolved decision, by contrast, is retained — retention
  // never consults acknowledgement (the card keeps rendering after the
  // pending connection drops the row).
  const acknowledged = new Map<string, DecisionState>([
    ["gone", resolvedState(REJECTED, { committedVersion: 1 })],
  ]);
  expect(
    pendingListRows(inboxOf([]), { decisions: acknowledged, snapshots }).map((row) => row.id),
  ).toEqual(["gone"]);
});

// ---------------------------------------------------------------------------
// Screen tests (renderAt pattern from attention.test.tsx: memory history +
// MockedProvider with EMPTY mocks — the page firing any query would throw,
// so mocks={[]} doubles as the no-query proof). Multi-render suite:
// afterEach(cleanup); NO state-reset hook — each render mounts a fresh
// provider (the root creates a fresh store per router instance).
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
  await screen.findByRole("heading", { level: 1, name: "Approvals" });
}

function mainEl(): HTMLElement {
  return screen.getByRole("main");
}

async function showGrants() {
  fireEvent.click(screen.getByRole("tab", { name: /Grants/ }));
  await screen.findByText(/standing grants/);
}

async function showPending() {
  fireEvent.click(screen.getByRole("tab", { name: /Pending/ }));
  // The resolve-in-place caption is pending-only chrome that renders with
  // the list — present whether or not any decide form is still mounted.
  await screen.findByText(/Cards stay until you decide/);
}

const FOCUSABLE =
  "a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]";

function actionable(scope: HTMLElement): Element[] {
  return Array.from(scope.querySelectorAll(FOCUSABLE)).filter(
    (element) => element.getAttribute("tabindex") !== "-1",
  );
}

function cardByName(name: RegExp | string): HTMLElement {
  return screen.getByRole("article", { name });
}

const COMMAND_CARD = /export-pipeline wants to run a command/;
const QUESTION_CARD = /webhook-endpoints asked/;

afterEach(() => {
  cleanup();
});

test("page chrome: h1, oldest meta, preview marker, no live signal, page-shell container", async () => {
  renderAt("/approvals");
  await settle();
  const main = mainEl();

  expect(within(main).getByText("preview · sample data")).toBeDefined();
  expect(within(main).queryByText("live")).toBeNull();
  const meta = main.querySelector('[data-slot="page-meta"]');
  expect(meta?.textContent).toBe("oldest 12m");

  const pageRoot = main.firstElementChild;
  expect(pageRoot?.getAttribute("data-slot")).toBe("page-shell");
  expect(pageRoot?.className).toContain("@container/feed");
  expect(pageRoot?.className).toContain("max-w-6xl");

  // Preview honesty: none of the modeled data states render in preview —
  // statuses are "idle" and data is always the fixture.
  expect(main.querySelector('[data-slot="pending-empty"]')).toBeNull();
  expect(main.querySelector('[data-slot="approvals-error"]')).toBeNull();
  expect(within(main).queryByText("loading approvals…")).toBeNull();
  expect(within(main).queryByText(/couldn't refresh/)).toBeNull();
  expect(within(main).queryByText("Load more")).toBeNull();
});

test("toggle: tabs named with counts, badge classes, panel swap, alignment pins", async () => {
  renderAt("/approvals");
  await settle();

  const tablist = screen.getByRole("tablist", { name: "Approvals view" });
  const pendingTab = within(tablist).getByRole("tab", { name: "Pending 3" });
  const grantsTab = within(tablist).getByRole("tab", { name: "Grants 4" });

  // TabCount tones are fixed per tab: waiting (solid amber) on Pending,
  // muted on Grants — regardless of selection.
  const pendingBadge = pendingTab.querySelector('[data-slot="badge"]');
  const grantsBadge = grantsTab.querySelector('[data-slot="badge"]');
  for (const cls of ["bg-status-waiting-solid", "h-4", "min-w-4", "tabular-nums"]) {
    expect(pendingBadge?.classList.contains(cls), cls).toBe(true);
  }
  expect(grantsBadge?.classList.contains("bg-muted")).toBe(true);

  // Alignment pins: the summary hangs off the right edge of the centered row.
  const summary = document.querySelector<HTMLElement>('[data-slot="pending-summary"]');
  expect(summary?.textContent).toBe("2 decide · 1 reply");
  expect(summary?.className).toContain("ml-auto");
  expect(summary?.parentElement?.className).toContain("items-center");

  await showGrants();
  expect(document.querySelector('[data-slot="pending-summary"]')).toBeNull();
  // Tab-specific chrome: grants meta + no resolve-in-place caption.
  expect(mainEl().querySelector('[data-slot="page-meta"]')?.textContent).toBe("4 standing");
  expect(within(mainEl()).queryByText(/Cards stay until you decide/)).toBeNull();

  await showPending();
  expect(document.querySelector('[data-slot="pending-summary"]')).not.toBeNull();
  expect(mainEl().querySelector('[data-slot="page-meta"]')?.textContent).toBe("oldest 12m");
  expect(within(mainEl()).getByText(/Cards stay until you decide/)).toBeDefined();
});

test("three labelled article cards render as h2 with fixture-exact meta joins", async () => {
  renderAt("/approvals");
  await settle();

  const expectations = [
    { name: COMMAND_CARD, meta: "quill · wt export-stream · atlas · T-214 · 4m" },
    { name: QUESTION_CARD, meta: "helios-api · wren · 12m" },
    { name: /Plan review — export pipeline/, meta: "quill · gate · markdown · 4m" },
  ];
  for (const { name, meta } of expectations) {
    const card = cardByName(name);
    const heading = within(card).getByRole("heading", { level: 2 });
    expect(heading).toBeDefined();
    expect(card.querySelector('[data-slot="meta-line"]')?.textContent).toBe(meta);
  }
  expect(document.querySelectorAll('[data-slot="decision-card"]')).toHaveLength(3);

  // Heading hierarchy + li-only lists.
  expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
  const lists = Array.from(mainEl().querySelectorAll("ul"));
  expect(lists.length).toBeGreaterThan(0);
  for (const list of lists) {
    expect(list.getAttribute("role")).toBe("list");
    for (const child of Array.from(list.children)) {
      expect(child.tagName).toBe("LI");
    }
  }
});

test("tool-call card: command well, authorization line, scope group, approve label follows selection", async () => {
  renderAt("/approvals");
  await settle();
  const card = cardByName(COMMAND_CARD);

  const form = within(card).getByRole("form", { name: "Decide export-pipeline" });
  expect(form.className).toContain("gap-[11px]");

  const pre = card.querySelector("pre");
  expect(pre?.className).toContain("overflow-x-auto");
  expect(pre?.className).toContain("whitespace-pre");
  const code = pre?.querySelector("code");
  expect(code?.textContent).toBe("pnpm dlx prisma migrate deploy");
  // The $ prompt lives OUTSIDE <code>: aria-hidden, select-none, never in
  // the copy channel.
  const prompt = pre?.querySelector("span[aria-hidden='true']");
  expect(prompt?.textContent).toBe("$ ");
  expect(prompt?.className).toContain("select-none");
  expect(code?.contains(prompt ?? null)).toBe(false);

  // Risk annotation at full-strength muted — never the /60 alpha.
  const risk = within(card).getByText("writes to dev db on atlas");
  expect(risk.className).toContain("text-muted-foreground");
  expect(risk.className).not.toContain("text-muted-foreground/60");

  // The always-rendered authorization line — the one deliberate visible
  // addition over the mock (decision-critical consent info).
  expect(card.querySelector('[data-slot="authorization-context"]')?.textContent).toBe(
    "requested by main · atlas · wt export-stream · db quill_dev",
  );

  const group = within(card).getByRole("group", { name: "ALLOW…" });
  const radios = within(group).getAllByRole("radio");
  expect(radios).toHaveLength(3);
  const chipsRow = group.querySelector(":scope > div");
  for (const cls of ["flex", "flex-wrap", "gap-1.5"]) {
    expect(chipsRow?.classList.contains(cls), cls).toBe(true);
  }
  // Spacing resets on the field primitives (the mock's ~7px rhythm).
  expect(group.getAttribute("data-slot")).toBe("allow-scope");
  expect(group.className).toContain("gap-0");
  const legend = group.querySelector("legend");
  expect(legend?.className).toContain("mb-0");

  // Scope selection drives the approve label through all three labels;
  // initial selection is the once option.
  expect(within(card).getByRole("button", { name: "Approve — just once" })).toBeDefined();
  fireEvent.click(within(group).getByRole("radio", { name: "This thread" }));
  expect(within(card).getByRole("button", { name: "Approve — this thread" })).toBeDefined();
  fireEvent.click(within(group).getByRole("radio", { name: "quill · 7 days" }));
  expect(within(card).getByRole("button", { name: "Approve — quill · 7 days" })).toBeDefined();
  fireEvent.click(within(group).getByRole("radio", { name: "Just once" }));
  expect(within(card).getByRole("button", { name: "Approve — just once" })).toBeDefined();

  // Neither textarea carries a breakpoint or bare-pointer-fine font size —
  // the compact size rides ONLY the hybrid-safe guarded stack.
  for (const textarea of Array.from(document.querySelectorAll("textarea"))) {
    const tokens = textarea.className.split(/\s+/);
    expect(tokens.some((token) => token.startsWith("md:text-"))).toBe(false);
    for (const token of tokens) {
      if (token.includes("pointer-fine:")) {
        expect(token.startsWith("not-any-pointer-coarse:pointer-fine:"), token).toBe(true);
      }
    }
  }

  // Form-composition pin: the note textarea sits inside a Field wrapper.
  const note = within(card).getByRole("textbox", { name: "Add a note (optional)" });
  expect(note.closest('[data-slot="field"]')).not.toBeNull();
});

test("no implicit approve: submitting the decide form resolves nothing", async () => {
  renderAt("/approvals");
  await settle();
  const card = cardByName(COMMAND_CARD);
  fireEvent.submit(within(card).getByRole("form", { name: "Decide export-pipeline" }));
  // Still pending: the approve button is live and the status region empty.
  expect(within(card).getByRole("button", { name: "Approve — just once" })).toBeDefined();
  expect(card.querySelector('[data-slot="decision-resolution"]')?.textContent).toBe("");
});

test("drafts survive a tab switch and leaving the route; resolutions survive too", async () => {
  const router = renderAt("/approvals");
  await settle();

  const card = cardByName(COMMAND_CARD);
  const group = within(card).getByRole("group", { name: "ALLOW…" });
  fireEvent.click(within(group).getByRole("radio", { name: "This thread" }));
  fireEvent.change(within(card).getByRole("textbox", { name: "Add a note (optional)" }), {
    target: { value: "sentinel note" },
  });
  const question = cardByName(QUESTION_CARD);
  fireEvent.change(within(question).getByRole("textbox", { name: "Reply to the agent" }), {
    target: { value: "sentinel reply" },
  });

  await showGrants();
  await showPending();
  const cardAfterTab = cardByName(COMMAND_CARD);
  expect(
    within(cardAfterTab).getByRole<HTMLTextAreaElement>("textbox", {
      name: "Add a note (optional)",
    }).value,
  ).toBe("sentinel note");
  expect(
    within(cardAfterTab).getByRole("radio", { name: "This thread" }).getAttribute("checked"),
  ).toBeDefined();
  expect(within(cardAfterTab).getByRole("button", { name: "Approve — this thread" })).toBeDefined();

  // Resolve the question, then leave the route entirely and come back: the
  // shared store lives above the router outlet, so both the draft and the
  // resolution survive (they reset only on reload). These bare navigate
  // calls double as the type-level pin that /approvals needs no search key.
  fireEvent.click(within(cardByName(QUESTION_CARD)).getByRole("button", { name: "Send reply" }));
  await act(async () => {
    await router.navigate({ to: "/" });
  });
  await screen.findByRole("heading", { level: 1, name: "Attention" });
  await act(async () => {
    await router.navigate({ to: "/approvals" });
  });
  await settle();

  expect(
    within(cardByName(COMMAND_CARD)).getByRole<HTMLTextAreaElement>("textbox", {
      name: "Add a note (optional)",
    }).value,
  ).toBe("sentinel note");
  const resolvedQuestion = cardByName(QUESTION_CARD);
  expect(within(resolvedQuestion).getByRole("status").textContent).toBe(
    "Replied — “sentinel reply”",
  );
});

test("approve resolves in place: neutral tone, muted title, no controls, focused status node", async () => {
  renderAt("/approvals");
  await settle();
  let card = cardByName(COMMAND_CARD);

  fireEvent.change(within(card).getByRole("textbox", { name: "Add a note (optional)" }), {
    target: { value: "ship it" },
  });
  fireEvent.click(within(card).getByRole("button", { name: "Approve — just once" }));

  card = cardByName(COMMAND_CARD);
  // No tabbable/actionable control remains (the resolution node's
  // tabindex=-1 is deliberate).
  expect(actionable(card)).toHaveLength(0);
  const status = card.querySelector('[data-slot="decision-resolution"]');
  expect(status?.textContent).toBe("Approved — just once · “ship it”");
  expect(document.activeElement).toBe(status);

  // tone owns the neutral look: no amber border classes in any mode, no
  // opacity dimming anywhere on the card.
  expect(card.getAttribute("data-tone")).toBe("resolved");
  expect(card.className).not.toContain("border-status-waiting");
  expect([...card.classList].some((cls) => cls.startsWith("opacity-"))).toBe(false);
  // The documented resolved contract: solid neutral border + full surface,
  // and NONE of the expired-card (muted) vocabulary on the card element
  // itself — resolved children legitimately mute themselves.
  expect(card.classList.contains("border-border")).toBe(true);
  expect(card.classList.contains("bg-card")).toBe(true);
  for (const cls of ["border-dashed", "bg-card/60", "text-muted-foreground"]) {
    expect(card.classList.contains(cls), cls).toBe(false);
  }

  const heading = within(card).getByRole("heading", { level: 2 });
  expect(heading.className).toContain("text-muted-foreground");
  const inlineRef = card.querySelector('[data-slot="inline-ref"]');
  expect(inlineRef?.className).not.toContain("text-status-working");
  expect(inlineRef?.className).toContain("text-muted-foreground");

  // The sibling card's status node stays empty and sr-only.
  const question = cardByName(QUESTION_CARD);
  const questionStatus = question.querySelector('[data-slot="decision-resolution"]');
  expect(questionStatus?.textContent).toBe("");
  expect(questionStatus?.classList.contains("sr-only")).toBe(true);

  // Survives a tab round-trip — and the remount must NOT steal focus back.
  await showGrants();
  await showPending();
  card = cardByName(COMMAND_CARD);
  expect(card.getAttribute("data-tone")).toBe("resolved");
  expect(actionable(card)).toHaveLength(0);
  expect(document.activeElement).not.toBe(card.querySelector('[data-slot="decision-resolution"]'));
});

test("reject resolves in place with the note suffix and moves focus", async () => {
  renderAt("/approvals");
  await settle();
  const card = cardByName(COMMAND_CARD);
  fireEvent.change(within(card).getByRole("textbox", { name: "Add a note (optional)" }), {
    target: { value: "not on prod" },
  });
  fireEvent.click(within(card).getByRole("button", { name: "Reject" }));
  const status = cardByName(COMMAND_CARD).querySelector('[data-slot="decision-resolution"]');
  expect(status?.textContent).toBe("Rejected · “not on prod”");
  expect(document.activeElement).toBe(status);
});

test("reply composer: block-end addon, gated send, quiet reject, wrap classes on multiline replies", async () => {
  renderAt("/approvals");
  await settle();
  let question = cardByName(QUESTION_CARD);

  const inputGroup = question.querySelector('[data-slot="input-group"]');
  expect(inputGroup).not.toBeNull();
  const addon = question.querySelector('[data-slot="input-group-addon"]');
  expect(addon?.getAttribute("data-align")).toBe("block-end");
  const send = within(question).getByRole("button", { name: "Send reply" });
  const rejectButton = within(question).getByRole("button", { name: "Reject" });
  expect(addon?.contains(send)).toBe(true);
  expect(addon?.contains(rejectButton)).toBe(true);

  // Disjoint 48px touch slots on BOTH composer buttons.
  for (const control of [send, rejectButton]) {
    expect(control.className).toContain("any-pointer-coarse:min-h-12");
    expect(control.className).toContain("any-pointer-coarse:min-w-12");
  }

  const reply = within(question).getByRole("textbox", { name: "Reply to the agent" });
  // The grow-then-scroll mechanism pin (happy-dom does no layout — actual
  // growth is verified at the visual check).
  expect(reply.className).toContain("field-sizing-content");
  expect(reply.className).toContain("max-h-32");

  // Send disabled until trimmed text — no focusable no-op submit.
  expect(send.hasAttribute("disabled")).toBe(true);
  fireEvent.change(reply, { target: { value: "   " } });
  expect(
    within(question).getByRole("button", { name: "Send reply" }).hasAttribute("disabled"),
  ).toBe(true);
  fireEvent.change(reply, {
    target: { value: "Per endpoint.\nSee supercalifragilisticexpialidocious-rotation-doc" },
  });
  fireEvent.click(within(question).getByRole("button", { name: "Send reply" }));

  question = cardByName(QUESTION_CARD);
  const status = question.querySelector('[data-slot="decision-resolution"]');
  expect(status?.textContent).toBe(
    "Replied — “Per endpoint.\nSee supercalifragilisticexpialidocious-rotation-doc”",
  );
  expect(status?.className).toContain("whitespace-pre-wrap");
  expect(status?.className).toContain("wrap-anywhere");
  expect(document.activeElement).toBe(status);
});

test("question reject resolves 'Rejected — no answer given'", async () => {
  renderAt("/approvals");
  await settle();
  const question = cardByName(QUESTION_CARD);
  fireEvent.click(within(question).getByRole("button", { name: "Reject" }));
  expect(
    cardByName(QUESTION_CARD).querySelector('[data-slot="decision-resolution"]')?.textContent,
  ).toBe("Rejected — no answer given");
});

test("live counts follow resolutions everywhere; grants surfaces move together", async () => {
  renderAt("/approvals");
  await settle();

  // Reply to the question: every pending surface drops together and the
  // oldest meta shifts to the next unresolved row (12m → 4m).
  fireEvent.change(
    within(cardByName(QUESTION_CARD)).getByRole("textbox", { name: "Reply to the agent" }),
    { target: { value: "per endpoint" } },
  );
  fireEvent.click(within(cardByName(QUESTION_CARD)).getByRole("button", { name: "Send reply" }));

  expect(screen.getByRole("tab", { name: "Pending 2" })).toBeDefined();
  const railNav = screen.getByRole("navigation", { name: "Main" });
  const tabBar = screen.getByRole("navigation", { name: "Primary" });
  expect(within(railNav).getByRole("link", { name: "Approvals 2" })).toBeDefined();
  expect(within(tabBar).getByRole("link", { name: "Approvals 2" })).toBeDefined();
  expect(document.querySelector('[data-slot="pending-summary"]')?.textContent).toBe(
    "2 decide · 0 reply",
  );
  expect(mainEl().querySelector('[data-slot="page-meta"]')?.textContent).toBe("oldest 4m");

  // Approve the command with a standing scope: pending drops again AND all
  // three grants surfaces move together (4 → 5).
  const card = cardByName(COMMAND_CARD);
  fireEvent.click(
    within(within(card).getByRole("group", { name: "ALLOW…" })).getByRole("radio", {
      name: "This thread",
    }),
  );
  fireEvent.click(within(card).getByRole("button", { name: "Approve — this thread" }));

  expect(screen.getByRole("tab", { name: "Pending 1" })).toBeDefined();
  expect(within(railNav).getByRole("link", { name: "Approvals 1" })).toBeDefined();
  expect(document.querySelector('[data-slot="pending-summary"]')?.textContent).toBe(
    "1 decide · 0 reply",
  );
  expect(screen.getByRole("tab", { name: "Grants 5" })).toBeDefined();
  expect(
    cardByName(COMMAND_CARD).querySelector('[data-slot="decision-resolution"]')?.textContent,
  ).toBe("Approved — this thread");

  await showGrants();
  expect(mainEl().querySelector('[data-slot="page-meta"]')?.textContent).toBe("5 standing");
  expect(mainEl().querySelector('[data-slot="grants-placeholder"]')?.textContent).toBe(
    "5 standing grants — this tab is designed in a later slice (4a).",
  );
  // The gate card is inert, so the page floors at Pending 1 — the zero
  // branch is derivation-test-only.
});

test("a once-scoped approve leaves every grants surface at 4", async () => {
  renderAt("/approvals");
  await settle();
  fireEvent.click(
    within(cardByName(COMMAND_CARD)).getByRole("button", { name: "Approve — just once" }),
  );
  expect(screen.getByRole("tab", { name: "Grants 4" })).toBeDefined();
  await showGrants();
  expect(mainEl().querySelector('[data-slot="page-meta"]')?.textContent).toBe("4 standing");
  expect(mainEl().querySelector('[data-slot="grants-placeholder"]')?.textContent).toBe(
    "4 standing grants — this tab is designed in a later slice (4a).",
  );
});

test("?view= is the tab state: deep links open grants, invalid coerces, foreign params survive", async () => {
  renderAt("/approvals?view=grants");
  await settle();
  expect(await screen.findByText(/standing grants/)).toBeDefined();
  cleanup();

  renderAt("/approvals?view=zzz");
  await settle();
  expect(screen.getByRole("form", { name: "Decide export-pipeline" })).toBeDefined();
  cleanup();

  // Type-level pin: linkOptions to /approvals compiles with NO search key
  // (the SearchSchemaInput optional-input contract).
  const options = linkOptions({ to: "/approvals" });
  expect(options.to).toBe("/approvals");

  // Foreign search params survive a tab switch — the dev-only ?mock=
  // scenario key must still be there for a reload to re-read.
  const router = renderAt("/approvals?mock=empty&view=pending");
  await settle();
  await showGrants();
  expect(router.state.location.href).toContain("mock=empty");
  expect(router.state.location.href).toContain("view=grants");
});

test("gate card is inert and chevron-less; generic-card note explains it", async () => {
  renderAt("/approvals");
  await settle();
  const gate = cardByName(/Plan review — export pipeline/);
  expect(actionable(gate)).toHaveLength(0);
  expect(gate.querySelector('[data-slot="feed-chevron"]')).toBeNull();
  expect(within(gate).getByText("decides on the gate screen — not built yet")).toBeDefined();
});

test("grants tab is honest: placeholder inside the shared content wrapper, zero focusables", async () => {
  renderAt("/approvals?view=grants");
  await settle();
  const placeholder = mainEl().querySelector<HTMLElement>('[data-slot="grants-placeholder"]');
  expect(placeholder?.textContent).toBe(
    "4 standing grants — this tab is designed in a later slice (4a).",
  );
  expect(placeholder ? actionable(placeholder) : null).toHaveLength(0);
  const wrapper = placeholder?.parentElement;
  for (const cls of ["px-3.5", "md:max-w-2xl", "md:px-0"]) {
    expect(wrapper?.classList.contains(cls), cls).toBe(true);
  }
  // No h1 inside the placeholder — the page header owns the single h1.
  expect(placeholder?.querySelector("h1")).toBeNull();
});

test("deployed /argus/approvals prefix renders the screen", async () => {
  renderAt("/argus/approvals", "/argus/");
  await settle();
  expect(screen.getByRole("form", { name: "Decide export-pipeline" })).toBeDefined();
});

// ---------------------------------------------------------------------------
// Card decision-state branches, unit-rendered via the `decision` prop
// (slice-1 producers; hand-built states — the cards need no provider).
// ---------------------------------------------------------------------------

function noopHandlers() {
  return {
    draft: {},
    onDraftChange: vi.fn(),
    onResolve: vi.fn(),
    onRetryReconcile: vi.fn(),
    onDismiss: vi.fn(),
  };
}

test("submitting: controls disabled, aria-busy on the form, status announces", () => {
  const item = toolCallCase("s1", {
    scopeOptions: [
      { id: "s1-once", kind: "once" },
      { id: "s1-thread", kind: "thread", threadRef: "t" },
    ],
  });
  render(<ToolCallCard item={item} decision={{ status: "submitting" }} {...noopHandlers()} />);
  const form = screen.getByRole("form", { name: "Decide thread-s1" });
  expect(form.getAttribute("aria-busy")).toBe("true");
  expect(screen.getByRole("button", { name: /Approve/ }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Reject" }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("status").textContent).toBe("submitting…");
});

test("error/retryable: status message, form stays actionable", () => {
  const item = toolCallCase("r1");
  render(
    <ToolCallCard
      item={item}
      decision={{
        status: "error",
        code: "infra_unavailable",
        action: "approve",
        disposition: "retryable",
        allowedActions: new Set(["approve", "reject"]),
      }}
      {...noopHandlers()}
    />,
  );
  expect(screen.getByRole("status").textContent).toBe("couldn't approve — infra_unavailable");
  expect(screen.getByRole("button", { name: /Approve/ }).hasAttribute("disabled")).toBe(false);
  expect(screen.getByRole("button", { name: "Reject" }).hasAttribute("disabled")).toBe(false);
});

test("error/terminal on approve: Approve disabled, Reject enabled, zero scope radios", () => {
  const item = toolCallCase("t1", {
    scopeOptions: [
      { id: "t1-once", kind: "once" },
      { id: "t1-thread", kind: "thread", threadRef: "t" },
    ],
  });
  render(
    <ToolCallCard
      item={item}
      decision={{
        status: "error",
        code: "parent_terminal",
        action: "approve",
        disposition: "terminal",
        allowedActions: new Set(["reject"]),
      }}
      {...noopHandlers()}
    />,
  );
  expect(screen.getByRole("status").textContent).toBe("couldn't approve — parent_terminal");
  expect(screen.getByRole("button", { name: /Approve/ }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Reject" }).hasAttribute("disabled")).toBe(false);
  // The disallowed approve's draft controls disappear with it.
  expect(screen.queryAllByRole("radio")).toHaveLength(0);
});

test("needs_input error excluding reply disables the textarea and Send together", () => {
  const item = {
    id: "q1",
    kind: "needs_input" as const,
    threadRef: "sentinel-thread",
    project: "p",
    node: null,
    age: "1m",
    insertedAt: "2026-07-14T11:59:00.000Z",
    question: "sentinel?",
  };
  render(
    <QuestionCard
      item={item}
      decision={{
        status: "error",
        code: "parent_terminal",
        action: "reply",
        disposition: "terminal",
        allowedActions: new Set(["reject"]),
      }}
      {...noopHandlers()}
    />,
  );
  expect(screen.getByRole("textbox", { name: "Reply to the agent" }).hasAttribute("disabled")).toBe(
    true,
  );
  expect(screen.getByRole("button", { name: "Send reply" }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Reject" }).hasAttribute("disabled")).toBe(false);
});

test("recovery-less error renders the dismissible tombstone — Dismiss is the only focusable", () => {
  // Both card variants, with realistic distinct actions (a question fails
  // reply/reject, never approve — the split doubles as proof the copy stays
  // action-derived). The copy rides the always-mounted role="status" node,
  // NOT the tombstone row, so AT announces it when the controls unmount.
  const tombstoneDecision = (action: "approve" | "reply"): DecisionState => ({
    status: "error",
    code: "not_found",
    action,
    disposition: "terminal",
    allowedActions: new Set(),
  });
  const questionItem = {
    id: "q-gone",
    kind: "needs_input" as const,
    threadRef: "sentinel-thread",
    project: "p",
    node: null,
    age: "1m",
    insertedAt: "2026-07-14T11:59:00.000Z",
    question: "sentinel?",
  };
  const variants = [
    {
      element: (handlers: ReturnType<typeof noopHandlers>) => (
        <ToolCallCard
          item={toolCallCase("gone")}
          decision={tombstoneDecision("approve")}
          {...handlers}
        />
      ),
      copy: "couldn't approve — not_found; this case no longer exists server-side",
    },
    {
      element: (handlers: ReturnType<typeof noopHandlers>) => (
        <QuestionCard item={questionItem} decision={tombstoneDecision("reply")} {...handlers} />
      ),
      copy: "couldn't reply — not_found; this case no longer exists server-side",
    },
  ];
  for (const variant of variants) {
    const handlers = noopHandlers();
    const { unmount } = render(variant.element(handlers));
    const card = screen.getByRole("article");
    const controls = actionable(card);
    expect(controls).toHaveLength(1);
    expect(controls[0].textContent).toBe("Dismiss");

    const status = card.querySelector('[data-slot="decision-resolution"]');
    const row = card.querySelector('[data-slot="decision-tombstone"]');
    const dismiss = screen.getByRole("button", { name: "Dismiss" });
    expect(status?.textContent).toBe(variant.copy);
    expect(status?.contains(dismiss)).toBe(false);
    expect(row?.contains(dismiss)).toBe(true);
    // The copy's flex-1 left the row with it; Dismiss keeps its trailing
    // edge explicitly.
    expect(row?.className).toContain("justify-end");
    // Reading order: the status copy precedes the Dismiss row in the DOM.
    expect(
      status !== null && row !== null
        ? status.compareDocumentPosition(row) & Node.DOCUMENT_POSITION_FOLLOWING
        : 0,
    ).toBeTruthy();

    fireEvent.click(dismiss);
    expect(handlers.onDismiss).toHaveBeenCalledTimes(1);
    unmount();
  }
});

test("error/reconcile locks all decision controls; the status Retry is the one live control", () => {
  const handlers = noopHandlers();
  const item = toolCallCase("c1", {
    scopeOptions: [
      { id: "c1-once", kind: "once" },
      { id: "c1-thread", kind: "thread", threadRef: "t" },
    ],
  });
  render(
    <ToolCallCard
      item={item}
      decision={{
        status: "error",
        code: "not_pending",
        action: "approve",
        disposition: "reconcile",
        allowedActions: new Set(),
      }}
      {...handlers}
    />,
  );
  const card = screen.getByRole("article");
  const enabled = actionable(card).filter((control) => !control.hasAttribute("disabled"));
  expect(enabled).toHaveLength(1);
  expect(enabled[0].textContent).toBe("Retry");
  expect(screen.queryAllByRole("radio")).toHaveLength(0);
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  expect(handlers.onRetryReconcile).toHaveBeenCalledTimes(1);
});

test("initial selection is the once option even when reordered last; ownership gate never steals focus", () => {
  const item = toolCallCase("o1", {
    scopeOptions: [
      { id: "o1-thread", kind: "thread", threadRef: "t" },
      { id: "o1-project", kind: "project", project: "p", ttlDays: 7 },
      { id: "o1-once", kind: "once" },
    ],
  });
  const { rerender } = render(
    <div>
      <ToolCallCard item={item} decision={{ status: "submitting" }} {...noopHandlers()} />
      <button type="button">sibling</button>
    </div>,
  );
  // Submitting hides the scope radios (a draft no permitted action can
  // consume must not keep focusable controls).
  expect(screen.queryAllByRole("radio")).toHaveLength(0);

  // Focus a sibling during the submitting wait, then land the hand-built
  // resolved state: focus must NOT be yanked to the resolution node.
  const sibling = screen.getByRole("button", { name: "sibling" });
  sibling.focus();
  rerender(
    <div>
      <ToolCallCard
        item={item}
        decision={resolvedState({ kind: "rejected", note: "" })}
        {...noopHandlers()}
      />
      <button type="button">sibling</button>
    </div>,
  );
  expect(document.activeElement).toBe(screen.getByRole("button", { name: "sibling" }));

  // Fresh pending render of the same reordered item: the once option is the
  // initial selection (never a server default id, never array order).
  cleanup();
  render(<ToolCallCard item={item} decision={undefined} {...noopHandlers()} />);
  expect((screen.getByRole("radio", { name: "Just once" }) as HTMLInputElement).checked).toBe(true);
  expect(screen.getByRole("button", { name: "Approve — just once" })).toBeDefined();
});

// ---------------------------------------------------------------------------
// The Textarea registry-edit pin: the compact size rides the hybrid-safe
// guarded stack, never md: — the class string itself proves hybrid devices
// keep 16px (a bare md:text-sm would re-trigger iOS auto-zoom on landscape
// phones and coarse-touch hybrids).
// ---------------------------------------------------------------------------

test("Textarea carries the guarded compact size instead of md:text-sm", () => {
  render(<Textarea aria-label="probe" />);
  const textarea = screen.getByRole("textbox", { name: "probe" });
  expect(textarea.className).toContain("not-any-pointer-coarse:pointer-fine:text-sm");
  expect(textarea.className).not.toContain("md:text-sm");
  expect(textarea.className).toContain("text-base");
});
