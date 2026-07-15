// The Approvals screen's LOCAL state: a narrow optimistic overlay keyed by
// case id — deliberately NOT a second normalized cache (slice-1 Apollo still
// owns the rows). The provider (approvals-local-state-provider.tsx — a
// component-only module, so it stays a valid Fast Refresh boundary) mounts
// in __root.tsx: the root never unmounts in-session, so decisions/drafts
// survive every in-app navigation and reset exactly on reload; each
// createAppRouter render creates a fresh store via useRef, so tests isolate
// with no reset hook at all.
//
// The context value is ONE STABLE store reference (a tiny external store:
// subscribe + CACHED snapshot getters + actions); consumers read through
// useSyncExternalStore over KEYED getters — React's built-in has no selector
// parameter and rerenders on Object.is inequality of getSnapshot(), so the
// store memoizes per-key snapshots itself: a draft keystroke on card A
// rerenders only card A, never card B and never the shell chrome.
//
// Acknowledgement is DERIVED, never stored: a resolution is acknowledged ⇔
// committedVersion !== null && committedVersion ≤ acceptedBaseline.version,
// computed inside overlayDeltas — no boolean field to keep consistent, no
// impossible state, and a baseline advance never rewrites resolved decision
// objects just to flip a UI-invisible flag. Baselines install ONLY through
// the monotonic acceptBaseline coordinator (a late V response arriving after
// V+1 installs nothing, yet its resolution still derives correctly against
// the newer baseline).

import { createContext, useContext, useMemo, useSyncExternalStore } from "react";
import {
  type ApprovalsInboxData,
  type ApprovalsSummary,
  type ApprovalsSummaryData,
  type ApprovalsSummarySeamResult,
  deriveApprovalsSummary,
  type OptimisticDelta,
  type PendingCase,
  pendingOrder,
  PREVIEW_NOW,
  type SeamStatus,
  useApprovalsInboxData,
} from "./approvals-data";

// ---------------------------------------------------------------------------
// Decision-state union — TOTAL over the decideCase lifecycle NOW
// (argus-backend-needs.md #3), so slice 1 widens producers, not types.
// ---------------------------------------------------------------------------

// The DECISION-side scope projection — structured like the offer,
// label-free: resolution copy derives from THIS structure via the
// scopeLabels helper, never from wire text or button text. Preview maps the
// selected option's structure; slice 1 builds it from the authoritative
// decision projection (a reconciled winner's ACTUAL scope + grant identity).
export type ResolvedScope =
  | Readonly<{ kind: "once" }>
  | Readonly<{ kind: "thread"; threadRef: string | null; grantId?: string; expiresAt?: string }>
  | Readonly<{
      kind: "project";
      project: string;
      ttlDays: number;
      grantId?: string;
      expiresAt?: string;
    }>;

export type Resolution =
  // The COMPLETE slice-1 effect union now — preview only ever emits
  // created/none; "renewed" is a zero grants-count delta (needs-doc #3);
  // "once" is never persisted.
  | Readonly<{
      kind: "approved";
      scope: ResolvedScope;
      note: string;
      grantEffect: "created" | "renewed" | "none";
    }>
  | Readonly<{ kind: "rejected"; note: string }>
  | Readonly<{ kind: "replied"; reply: string }>;

export type DecisionAction = "approve" | "reject" | "reply";

export type DecisionState =
  // slice-1 only — preview mutators never produce it
  | Readonly<{ status: "submitting" }>
  // committedVersion starts null (preview mutators ALWAYS write null —
  // nothing commits in 2b); slice 1's mutation success stamps the payload's
  // post-decision baseline version. followUpFailure models the documented
  // decide-committed-but-resume-failed wire outcome (needs-doc #3's
  // `committed` arm arriving WITH an error): the decision is authoritative
  // and controls stay unmounted, but the card must visibly say the workflow
  // failed to resume. Preview producers always write null.
  | Readonly<{
      status: "resolved";
      outcome: Resolution;
      committedVersion: number | null;
      followUpFailure: string | null;
    }>
  // slice-1 only — decideCase failure; the server's authoritative allowed
  // set drives what stays enabled (parent_terminal blocks approve only,
  // reject stays live — needs-doc #3).
  | Readonly<{
      status: "error";
      code: string;
      action: DecisionAction;
      disposition: "retryable" | "terminal" | "reconcile";
      allowedActions: ReadonlySet<DecisionAction>;
    }>;

export type Draft = Readonly<{ scopeId?: string; note?: string; reply?: string }>;

export type LocalState = Readonly<{
  decisions: ReadonlyMap<string, DecisionState>;
  drafts: ReadonlyMap<string, Draft>;
  /**
   * Full PendingCase rows, written on the FIRST decision-state write for a
   * case id — a concurrent winner's refetch can drop the pending row while
   * THIS client is submitting or reconcile-locked, and the card must stay
   * on screen (locked, honest, in its comparator-determined place) until
   * authoritative reconciliation completes. Retained until reload.
   */
  snapshots: ReadonlyMap<string, PendingCase>;
  /** The single accepted-baseline snapshot — coordinator state, not a cache. */
  acceptedBaseline: ApprovalsSummaryData | null;
  /** Transport half of the summary seam result, last-write-wins. */
  summaryTransport: Readonly<{ status: SeamStatus; refetch: () => void }>;
}>;

// ---------------------------------------------------------------------------
// Pure selectors (exported for unit tests — no store backdoor needed).
// ---------------------------------------------------------------------------

function acknowledged(decision: DecisionState, baseline: ApprovalsSummaryData | null): boolean {
  return (
    decision.status === "resolved" &&
    decision.committedVersion !== null &&
    baseline !== null &&
    decision.committedVersion <= baseline.version
  );
}

/** Resolved only (acknowledged or not) — resolved STYLING/outcome rendering, never retention. */
export function resolvedIds(state: Pick<LocalState, "decisions">): ReadonlySet<string> {
  const ids = new Set<string>();
  for (const [id, decision] of state.decisions) {
    if (decision.status === "resolved") ids.add(id);
  }
  return ids;
}

/**
 * The list-RETENTION feed (pendingListRows unions these snapshots):
 * submitting, resolved, and error states WITH a live recovery path — a
 * retryable disposition, a reconcile (its Retry is the recovery), or a
 * nonempty allowedActions set. An error with NO recovery (slice-1
 * `not_found` with empty allowedActions — the case is gone server-side) is
 * NOT retained once its row leaves the pending data; the card instead
 * renders one last time as a dismissible tombstone.
 */
export function retainedDecisionIds(state: Pick<LocalState, "decisions">): ReadonlySet<string> {
  const ids = new Set<string>();
  for (const [id, decision] of state.decisions) {
    if (decision.status === "error") {
      const recoverable =
        decision.disposition === "retryable" ||
        decision.disposition === "reconcile" ||
        decision.allowedActions.size > 0;
      if (!recoverable) continue;
    }
    ids.add(id);
  }
  return ids;
}

export type OverlayState = Pick<LocalState, "decisions" | "snapshots" | "acceptedBaseline">;

/**
 * One OptimisticDelta — {id, kind, grantEffect}, all read from the snapshot,
 * never from page rows — per resolved decision NOT YET acknowledged against
 * the accepted baseline (derived: committedVersion === null || >
 * acceptedBaseline.version). The ONLY feed for deriveApprovalsSummary and
 * the nav badges. An acknowledged decision emits no delta: it never
 * decrements and its grant delta never adds. Transient states (submitting,
 * error) never count as resolved, so they keep counting pending.
 */
export function overlayDeltas(state: OverlayState): readonly OptimisticDelta[] {
  const deltas: OptimisticDelta[] = [];
  for (const [id, decision] of state.decisions) {
    if (decision.status !== "resolved") continue;
    if (acknowledged(decision, state.acceptedBaseline)) continue;
    const snapshot = state.snapshots.get(id);
    if (snapshot === undefined) continue;
    deltas.push({
      id,
      kind: snapshot.kind,
      grantEffect: decision.outcome.kind === "approved" ? decision.outcome.grantEffect : "none",
    });
  }
  return deltas;
}

/**
 * The pending list: page rows ∪ snapshots of retained decisions not in the
 * page (page rows win on id collision), sorted whole by the SAME
 * pendingOrder total comparator — snapshots carry full PendingCase rows, so
 * one comparator orders live and retained rows together with no recorded
 * positions to go stale.
 */
export function pendingListRows(
  data: ApprovalsInboxData,
  state: Pick<LocalState, "decisions" | "snapshots">,
): readonly PendingCase[] {
  const rows = new Map<string, PendingCase>();
  for (const row of data.pending) rows.set(row.id, row);
  for (const id of retainedDecisionIds(state)) {
    if (rows.has(id)) continue;
    const snapshot = state.snapshots.get(id);
    if (snapshot !== undefined) rows.set(id, snapshot);
  }
  return [...rows.values()].sort(pendingOrder);
}

// ---------------------------------------------------------------------------
// The store.
// ---------------------------------------------------------------------------

/** The explicit consumer type — every access goes through result.summary?.pendingLeft etc. */
export type DerivedApprovalsSummary = ApprovalsSummary & Readonly<{ grants: number }>;

export type UseApprovalsSummaryResult = Readonly<{
  summary: DerivedApprovalsSummary | undefined;
  status: SeamStatus;
  refetch: () => void;
}>;

export type AcceptedBaselineMeta = Readonly<{ version: number; oldestInsertedAt: string | null }>;

type RetentionState = Pick<LocalState, "decisions" | "snapshots">;

export type ApprovalsStore = Readonly<{
  subscribe: (listener: () => void) => () => void;
  getState: () => LocalState;
  getSummaryResult: () => UseApprovalsSummaryResult;
  getBaselineMeta: () => AcceptedBaselineMeta | undefined;
  getRetention: () => RetentionState;
  getResolvedIds: () => ReadonlySet<string>;
  getDraft: (id: string) => Draft | undefined;
  getDecision: (id: string) => DecisionState | undefined;
  /** The preview mutator: the decision write and its item snapshot land atomically. */
  resolve: (item: PendingCase, outcome: Resolution) => void;
  setDraft: (id: string, draft: Draft) => void;
  /** Tombstone escape hatch: clears the decision, draft, and snapshot for a case. */
  dismiss: (id: string) => void;
  /** The ONE monotonic acceptance coordinator — regressing versions install nothing. */
  acceptBaseline: (data: ApprovalsSummaryData) => void;
  /** Feeds a whole seam result: data → acceptBaseline half; status/refetch last-write-wins. */
  acceptSummaryResult: (result: ApprovalsSummarySeamResult) => void;
}>;

export function createApprovalsStore(initial?: ApprovalsSummarySeamResult): ApprovalsStore {
  let state: LocalState = {
    decisions: new Map(),
    drafts: new Map(),
    snapshots: new Map(),
    acceptedBaseline: initial?.data ?? null,
    summaryTransport: {
      status: initial?.status ?? "idle",
      refetch: initial?.refetch ?? (() => undefined),
    },
  };
  const listeners = new Set<() => void>();
  const setState = (next: LocalState) => {
    if (next === state) return;
    state = next;
    for (const listener of listeners) listener();
  };

  // Baseline install: monotonic (a late V response after V+1 never
  // overwrites), and the DRAFTS of newly-covered decisions clear in the
  // SAME dispatch — no render can observe a new baseline with a stale
  // draft or vice versa.
  const installBaseline = (base: LocalState, data: ApprovalsSummaryData): LocalState => {
    const current = base.acceptedBaseline;
    if (current !== null && (data === current || data.version < current.version)) return base;
    let drafts: Map<string, Draft> | null = null;
    for (const [id, decision] of base.decisions) {
      if (
        decision.status === "resolved" &&
        decision.committedVersion !== null &&
        decision.committedVersion <= data.version &&
        base.drafts.has(id)
      ) {
        drafts ??= new Map(base.drafts);
        drafts.delete(id);
      }
    }
    return { ...base, acceptedBaseline: data, drafts: drafts ?? base.drafts };
  };

  // Cached snapshot getters — useSyncExternalStore rerenders on Object.is
  // inequality, so each getter recomputes ONLY when its inputs change. The
  // summary snapshot invalidates on baseline, overlay (decisions/snapshots),
  // transport status, or refetch identity changes — a healthy→error
  // transition must refresh the badge, and a replacement refetch callback
  // with unchanged data must still reach consumers.
  let summaryCache: { deps: readonly unknown[]; value: UseApprovalsSummaryResult } | null = null;
  const getSummaryResult = (): UseApprovalsSummaryResult => {
    const deps = [
      state.decisions,
      state.snapshots,
      state.acceptedBaseline,
      state.summaryTransport,
    ] as const;
    if (summaryCache === null || summaryCache.deps.some((dep, i) => dep !== deps[i])) {
      const { acceptedBaseline, summaryTransport } = state;
      let summary: DerivedApprovalsSummary | undefined;
      if (acceptedBaseline !== null) {
        const deltas = overlayDeltas(state);
        const base = deriveApprovalsSummary(acceptedBaseline, deltas, PREVIEW_NOW);
        const grants =
          acceptedBaseline.grantsCount +
          deltas.filter((delta) => delta.grantEffect === "created").length;
        summary = { ...base, grants };
      }
      summaryCache = {
        deps,
        value: { summary, status: summaryTransport.status, refetch: summaryTransport.refetch },
      };
    }
    return summaryCache.value;
  };

  let metaCache: { baseline: ApprovalsSummaryData; value: AcceptedBaselineMeta } | null = null;
  const getBaselineMeta = (): AcceptedBaselineMeta | undefined => {
    const baseline = state.acceptedBaseline;
    if (baseline === null) return undefined;
    if (metaCache === null || metaCache.baseline !== baseline) {
      metaCache = {
        baseline,
        value: { version: baseline.version, oldestInsertedAt: baseline.oldestInsertedAt },
      };
    }
    return metaCache.value;
  };

  let retentionCache: {
    decisions: LocalState["decisions"];
    snapshots: LocalState["snapshots"];
    value: RetentionState;
  } | null = null;
  const getRetention = (): RetentionState => {
    if (
      retentionCache === null ||
      retentionCache.decisions !== state.decisions ||
      retentionCache.snapshots !== state.snapshots
    ) {
      retentionCache = {
        decisions: state.decisions,
        snapshots: state.snapshots,
        value: { decisions: state.decisions, snapshots: state.snapshots },
      };
    }
    return retentionCache.value;
  };

  let resolvedCache: { decisions: LocalState["decisions"]; value: ReadonlySet<string> } | null =
    null;
  const getResolvedIds = (): ReadonlySet<string> => {
    if (resolvedCache === null || resolvedCache.decisions !== state.decisions) {
      resolvedCache = { decisions: state.decisions, value: resolvedIds(state) };
    }
    return resolvedCache.value;
  };

  return {
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getState: () => state,
    getSummaryResult,
    getBaselineMeta,
    getRetention,
    getResolvedIds,
    getDraft: (id) => state.drafts.get(id),
    getDecision: (id) => state.decisions.get(id),
    resolve: (item, outcome) => {
      const decisions = new Map(state.decisions);
      decisions.set(item.id, {
        status: "resolved",
        outcome,
        committedVersion: null,
        followUpFailure: null,
      });
      const snapshots = state.snapshots.has(item.id)
        ? state.snapshots
        : new Map(state.snapshots).set(item.id, item);
      setState({ ...state, decisions, snapshots });
    },
    setDraft: (id, draft) => {
      const drafts = new Map(state.drafts);
      drafts.set(id, draft);
      setState({ ...state, drafts });
    },
    dismiss: (id) => {
      if (!state.decisions.has(id) && !state.drafts.has(id) && !state.snapshots.has(id)) return;
      const decisions = new Map(state.decisions);
      decisions.delete(id);
      const drafts = new Map(state.drafts);
      drafts.delete(id);
      const snapshots = new Map(state.snapshots);
      snapshots.delete(id);
      setState({ ...state, decisions, drafts, snapshots });
    },
    acceptBaseline: (data) => {
      setState(installBaseline(state, data));
    },
    acceptSummaryResult: (result) => {
      let next = state;
      const transport = state.summaryTransport;
      if (result.status !== transport.status || result.refetch !== transport.refetch) {
        next = {
          ...next,
          summaryTransport: { status: result.status, refetch: result.refetch },
        };
      }
      if (result.data !== undefined) next = installBaseline(next, result.data);
      setState(next);
    },
  };
}

// ---------------------------------------------------------------------------
// Store context + consumer hooks (split by concern). The provider component
// lives in approvals-local-state-provider.tsx — keeping this module JSX-free
// means it is not a Fast Refresh boundary at all.
// ---------------------------------------------------------------------------

/** Provider-wiring only — components consume through the hooks below, never this. */
export const ApprovalsStoreContext = createContext<ApprovalsStore | null>(null);

function useApprovalsStore(): ApprovalsStore {
  const store = useContext(ApprovalsStoreContext);
  if (store === null) {
    throw new Error("useApprovalsStore requires ApprovalsLocalStateProvider (mounted in __root)");
  }
  return store;
}

/**
 * Shell badges + page header — the derived counts ONLY. Derives from the
 * store's ACCEPTED baseline (never straight from the seam — baseline
 * exposure and delta retirement must share the coordinator) and preserves
 * the seam result shape, retaining the last accepted baseline on error so a
 * stale count beats a vanished one. Referentially stable across draft
 * dispatches.
 */
export function useApprovalsSummary(): UseApprovalsSummaryResult {
  const store = useApprovalsStore();
  return useSyncExternalStore(store.subscribe, store.getSummaryResult);
}

/**
 * Route only — the immutable {version, oldestInsertedAt} projection of the
 * ACCEPTED baseline that deriveOldestShown needs; it reads the store's
 * coordinator state, never the seam, so a regressing source response can
 * never drive the displayed oldest.
 */
export function useAcceptedBaselineMeta(): AcceptedBaselineMeta | undefined {
  const store = useApprovalsStore();
  return useSyncExternalStore(store.subscribe, store.getBaselineMeta);
}

export function useResolvedCaseIds(): ReadonlySet<string> {
  const store = useApprovalsStore();
  return useSyncExternalStore(store.subscribe, store.getResolvedIds);
}

export type UseApprovalsInboxResult = Readonly<{
  data: ApprovalsInboxData | undefined;
  /** pendingListRows over the seam page + retained snapshots — the render feed. */
  rows: readonly PendingCase[];
  initialStatus: SeamStatus;
  refetch: () => void;
  fetchMore: (after: string | null) => void;
  fetchMoreStatus: SeamStatus;
}>;

/** The approvals route only — shell chrome never calls this (needs-doc #4). */
export function useApprovalsInbox(): UseApprovalsInboxResult {
  const store = useApprovalsStore();
  const seam = useApprovalsInboxData();
  const retention = useSyncExternalStore(store.subscribe, store.getRetention);
  const rows = useMemo(
    () => (seam.data === undefined ? [] : pendingListRows(seam.data, retention)),
    [seam.data, retention],
  );
  return {
    data: seam.data,
    rows,
    initialStatus: seam.initialStatus,
    refetch: seam.refetch,
    fetchMore: seam.fetchMore,
    fetchMoreStatus: seam.fetchMoreStatus,
  };
}

export function useDraft(id: string): Draft | undefined {
  const store = useApprovalsStore();
  return useSyncExternalStore(store.subscribe, () => store.getDraft(id));
}

export function useDecision(id: string): DecisionState | undefined {
  const store = useApprovalsStore();
  return useSyncExternalStore(store.subscribe, () => store.getDecision(id));
}

export function useApprovalsActions(): Pick<ApprovalsStore, "resolve" | "setDraft" | "dismiss"> {
  const store = useApprovalsStore();
  return useMemo(
    () => ({ resolve: store.resolve, setDraft: store.setDraft, dismiss: store.dismiss }),
    [store],
  );
}
