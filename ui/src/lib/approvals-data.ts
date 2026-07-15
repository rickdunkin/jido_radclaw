// The Approvals screen's data seam (attention-data.ts precedent): static
// fixture data today, swapped for real GraphQL operations in slice 1
// without touching the screen. TWO independent sources on purpose —
// getApprovalsSummaryData()/useApprovalsSummaryData() feed shell chrome +
// the page header, getApprovalsInboxData()/useApprovalsInboxData() feed the
// approvals route ONLY — so each swaps for its own slice-1 operation
// drop-in and mocking one never drags the other (argus-backend-needs.md #4:
// a badge must never fetch the rich inbox). The fixture backs both from one
// underlying literal, but the exports are independent seams.
//
// Every field is backend-shaped: it either exists on AgentCase today
// (marked "supported"), is documented contract, or is recorded as a gap in
// docs/plans/argus-ui-roadmap/argus-backend-needs.md (marked by entry
// number). Editorial copy (card titles, scope-chip labels) is NOT data —
// it derives client-side from kind + structure, so a forged wire label can
// never misstate consent.

// ---------------------------------------------------------------------------
// Scope options + labels
// ---------------------------------------------------------------------------

// A DISCRIMINATED union carrying structured context — NO free-form label.
// Every piece of operator-facing copy (chip, approve button, resolution
// line) derives client-side from kind + context via scopeLabels(), so a
// forged or mislabeled wire label can never show one-shot consent while the
// option id binds a standing grant (needs-doc #2 — copy is not wire data;
// the id is still the ONLY thing decideCase ever receives, and the UI
// derives the initial selection from the REQUIRED "once" option, never from
// a server-supplied default id).
export type ApprovalScopeOption =
  | Readonly<{ id: string; kind: "once" }>
  | Readonly<{ id: string; kind: "thread"; threadRef: string | null }>
  | Readonly<{ id: string; kind: "project"; project: string; ttlDays: number }>;

function assertNever(value: never): never {
  throw new Error(`unreachable: ${JSON.stringify(value)}`);
}

/** All operator-facing scope copy, derived from structure — never wire text. */
export function scopeLabels(
  option: ApprovalScopeOption,
): Readonly<{ chip: string; approve: string; resolved: string }> {
  switch (option.kind) {
    case "once":
      return { chip: "Just once", approve: "Approve — just once", resolved: "just once" };
    case "thread":
      return { chip: "This thread", approve: "Approve — this thread", resolved: "this thread" };
    case "project": {
      const label = `${option.project} · ${String(option.ttlDays)} ${option.ttlDays === 1 ? "day" : "days"}`;
      return { chip: label, approve: `Approve — ${label}`, resolved: label };
    }
    default:
      return assertNever(option);
  }
}

// A cheap deterministic reject of control/bidi/zero-width characters —
// Projects.Project permits arbitrary name strings today, so the client
// fences what the server doesn't yet constrain (the server-side obligation
// is needs-doc #2; the same display-safety contract governs needs-doc #1's
// authorization fields).
// Control (C0/C1) + bidi controls + zero-width/joiner/invisible characters.
// Matching control characters is the point here — reject, not render.
const UNSAFE_DISPLAY = new RegExp(
  // oxlint-disable-next-line no-control-regex
  "[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028\u2029\u2060\u2066-\u2069\u202a-\u202e\ufeff]",
);

function displaySafe(value: string): boolean {
  return value.length > 0 && !UNSAFE_DISPLAY.test(value);
}

/**
 * The pure option-set validator every card runs before anything renders:
 * unique nonempty ids (a duplicated id could display one-shot consent while
 * its id binds a standing grant), EXACTLY one `once`, bounded valid context
 * (nonempty display-safe project, TTL within sane bounds), display-safe
 * scope names. ANY failure returns null and the card renders reject-only —
 * a spoofable or ambiguous consent surface never renders (needs-doc #2).
 */
export function normalizeScopeOptions(
  options: readonly ApprovalScopeOption[],
): readonly ApprovalScopeOption[] | null {
  const ids = new Set<string>();
  let onceCount = 0;
  for (const option of options) {
    if (option.id === "" || ids.has(option.id)) return null;
    ids.add(option.id);
    switch (option.kind) {
      case "once":
        onceCount += 1;
        break;
      case "thread":
        if (option.threadRef !== null && !displaySafe(option.threadRef)) return null;
        break;
      case "project":
        if (!displaySafe(option.project)) return null;
        if (!Number.isInteger(option.ttlDays) || option.ttlDays < 1 || option.ttlDays > 365) {
          return null;
        }
        break;
      default:
        return assertNever(option);
    }
  }
  if (onceCount !== 1) return null;
  return options;
}

// ---------------------------------------------------------------------------
// Pending cases — the union keys on the REAL AgentCase kind values
// (Gate.Kinds.all(): tool_call · needs_input · plan · irreversible_write ·
// review_stall) and is TOTAL over all five (needs-doc #4).
// ---------------------------------------------------------------------------

export const PENDING_CASE_KINDS = [
  "tool_call",
  "needs_input",
  "plan",
  "irreversible_write",
  "review_stall",
] as const;
export type PendingCaseKind = (typeof PENDING_CASE_KINDS)[number];

type CaseBase = Readonly<{
  /** AgentCase.id (supported). */
  id: string;
  /**
   * Resolved thread/session display name — NULLABLE: workflow cases may
   * lack session_id (needs-doc #5). Null renders the "An agent" fallback.
   */
  threadRef: string | null;
  /** Display context — all nullable; null drops the meta segment (needs-doc #5). */
  project: string | null;
  node: string | null;
  /** Preformatted display "4m" — slice 1 derives from insertedAt (supported). */
  age: string;
  /**
   * Immutable ISO order key (AgentCase.inserted_at — supported): the sort +
   * oldest key, so ordering never depends on rounded display ages
   * (same-minute cases would collide) or on mutable list positions.
   */
  insertedAt: string;
}>;

export type AuthorizationContext = Readonly<{
  /**
   * Requesting agent template — a fingerprint dimension
   * (tool_approvals.ex:103-111), already shown by the current LiveView;
   * ALWAYS present and ALWAYS rendered, else `main` and `coder` requests
   * with identical arguments render identically while authorizing distinct
   * subjects (needs-doc #1).
   */
  template: string;
  /**
   * Server-rendered effective execution target (backend/server/workspace/
   * sandbox/worktree identity, materialized at case creation — needs-doc
   * #2); null ONLY when the server proved every remaining dimension
   * default/irrelevant to effect — otherwise the payload must be
   * complete: false.
   */
  target: string | null;
}>;

// BOTH variants carry `complete` AND `authorization` — approval authorizes
// the FULL argument fingerprint plus its effective target, so any elided
// representation must say so and refuse approval (needs-doc #1; today's
// summarize_args drops args after the 3rd and truncates at 40 chars).
export type ToolCallPresentation =
  | Readonly<{
      /** Exact redacted command, fingerprint-bound (needs-doc #1). */
      type: "command";
      commandPreview: string;
      complete: boolean;
      riskNote: string;
      authorization: AuthorizationContext;
    }>
  | Readonly<{
      /** Redacted "tool(arg: v, …)" — tool_call also gates non-command tools. */
      type: "generic";
      invocationSummary: string;
      complete: boolean;
      riskNote?: string;
      authorization: AuthorizationContext;
    }>;

export type ToolCallCase = CaseBase &
  Readonly<{
    // Gate.Kinds value (supported). Title copy is NOT data: the card derives
    // it from kind + presentation.type ("wants to run a command" / "wants to
    // run a tool") — editorial fragments don't ride the backend-shaped seam.
    kind: "tool_call";
    /** "export-stream" — rendered as `wt export-stream` (needs-doc #5). */
    worktree: string | null;
    /** "T-214" (needs-doc #5). */
    taskRef: string | null;
    /** Both wire shapes recorded in needs-doc #1. */
    presentation: ToolCallPresentation;
    /**
     * ALWAYS contains a kind:"once" option (hard-block cases offer ONLY it;
     * FLOW §12 + 4a's "Approve this once"); a set missing "once" renders
     * REJECT-ONLY (no Approve control rendered) — needs-doc #2.
     */
    scopeOptions: readonly ApprovalScopeOption[];
  }>;

export type NeedsInputCase = CaseBase &
  Readonly<{
    // Supported — details["question"], answer = decision_comment. Title copy
    // ("asked") derived from kind in the card, same rule as tool_call.
    kind: "needs_input";
    question: string;
  }>;

export type PlanGateCase = CaseBase &
  Readonly<{
    /** Workflow plan-review gate (supported; deep-link target is 3b). */
    kind: "plan";
    /**
     * Human display title — NO wire source today (gate_title is the static
     * "Approve plan"; needs-doc #5).
     */
    title: string;
    /** "markdown" — artifact format, also needs-doc #5. */
    format: string;
  }>;

// The remaining live kinds — needs-doc #4's lightweight representation, so
// the union is TOTAL over Gate.Kinds and an exhaustive renderer never
// breaks; rich cards arrive with 4a (irreversible) and the gate screens
// (review_stall).
export type GenericPendingCase = CaseBase &
  Readonly<{
    kind: "irreversible_write" | "review_stall";
    title: string;
  }>;

export type PendingCase = ToolCallCase | NeedsInputCase | PlanGateCase | GenericPendingCase;

function compact(segments: readonly (string | null)[]): readonly string[] {
  return segments.filter((segment): segment is string => segment !== null);
}

/**
 * Pure meta-line derivation — null context drops its segment; the fixture
 * never hand-writes segment arrays. EXHAUSTIVE over the union via switch +
 * assertNever (GenericCaseCard feeds it the remaining kinds too).
 */
export function caseMeta(item: PendingCase): readonly string[] {
  switch (item.kind) {
    case "tool_call":
      return compact([
        item.project,
        item.worktree !== null ? `wt ${item.worktree}` : null,
        item.node,
        item.taskRef,
        item.age,
      ]);
    case "needs_input":
      return compact([item.project, item.node, item.age]);
    case "plan":
      return compact([item.project, "gate", item.format, item.age]);
    case "irreversible_write":
    case "review_stall":
      return compact([item.project, item.node, item.age]);
    default:
      return assertNever(item);
  }
}

// ---------------------------------------------------------------------------
// Ordering + ages
// ---------------------------------------------------------------------------

// The client mirror of the required server sort (needs-doc #4): a
// priority-aware TOTAL order — (kind_rank, inserted_at ASC, id). One-tap
// decisions first, replies second, gate deep-links last; this reproduces
// the approved 2b mock card order, where a bare inserted_at asc (today's
// pending_for_tenant sort) would put the 12m question above the 4m command.
const KIND_RANK: Readonly<Record<PendingCaseKind, number>> = {
  tool_call: 0,
  irreversible_write: 0,
  needs_input: 1,
  plan: 2,
  review_stall: 2,
};

/** Total comparator: kind rank, then the EXACT immutable insertedAt, then id. */
export function pendingOrder(a: PendingCase, b: PendingCase): number {
  const rank = KIND_RANK[a.kind] - KIND_RANK[b.kind];
  if (rank !== 0) return rank;
  if (a.insertedAt !== b.insertedAt) return a.insertedAt < b.insertedAt ? -1 : 1;
  if (a.id === b.id) return 0;
  return a.id < b.id ? -1 : 1;
}

/**
 * Display age against an INJECTED clock (PREVIEW_NOW in preview/tests — no
 * wall-clock reads), so the displayed oldest can advance between responses
 * instead of freezing a preformatted string.
 */
export function formatAge(now: string, insertedAt: string): string {
  const minutes = Math.max(0, Math.floor((Date.parse(now) - Date.parse(insertedAt)) / 60_000));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${String(minutes)}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${String(hours)}h`;
  return `${String(Math.floor(hours / 24))}d`;
}

// ---------------------------------------------------------------------------
// Summary (the aggregate operation — shell chrome's ONLY source)
// ---------------------------------------------------------------------------

export type ApprovalsSummaryData = Readonly<{
  /**
   * Monotonic authoritative baseline version (needs-doc #3/#4), used
   * EXCLUSIVELY for optimistic-delta acknowledgement — it is NOT a
   * pagination snapshot token (the inbox paginates on stable keyset
   * cursors, independent of this: sharing one version would let a
   * grant-only update or an unrelated decision reset every load-more and
   * starve pagination under regular activity). Fixture: 1.
   */
  version: number;
  /**
   * The aggregate's ISO timestamp — ages derive client-side against a
   * clock, so the displayed oldest can advance between responses.
   */
  asOf: string;
  /**
   * The WIRE shape (needs-doc #4): per-kind counts, exactly what the
   * summary operation returns — decide/reply buckets are CLIENT derivations
   * via decisionBucket, never a second kind taxonomy baked server-side.
   */
  pendingByKind: Readonly<Record<PendingCaseKind, number>>;
  /**
   * SERVER-authoritative — badges/counts never derive from page rows alone,
   * so a tenant whose pending set exceeds one page is never undercounted.
   */
  total: number;
  /**
   * The oldest pending case's inserted_at — display formatting is the
   * client's (formatAge(now, insertedAt) with an INJECTED clock).
   */
  oldestInsertedAt: string | null;
  /** 4 — count only; grant ROWS are 4a's (needs-doc #2/#6 territory). */
  grantsCount: number;
}>;

/**
 * One per UNACKNOWLEDGED resolved decision, built from the overlay snapshot
 * alone (id + kind + grant effect) — NEVER from page rows, so shell chrome
 * needs no inbox page to apply it. The producer selector overlayDeltas()
 * lives in approvals-local-state; THIS module only consumes explicit
 * delta arrays.
 */
export type OptimisticDelta = Readonly<{
  id: string;
  kind: PendingCaseKind;
  grantEffect: "created" | "renewed" | "none";
}>;

export type ApprovalsSummary = Readonly<{
  /** summary.total minus unacknowledged overlay deltas — the Pending TabCount AND the shell nav badge. */
  pendingLeft: number;
  /** Decide-bucket total minus decide-bucket deltas (via decisionBucket — case-type taxonomy). */
  decide: number;
  reply: number;
  /**
   * formatAge(now, oldestInsertedAt) over the SERVER value — display
   * adjustment from page rows is deriveOldestShown's route-local job, never
   * this summary's (shell chrome only ever reads pendingLeft).
   */
  oldestAge?: string;
}>;

/**
 * The ONE classifier both the server-summary adaptation and local
 * decrements use, so resolving any kind moves pendingLeft and its bucket
 * together. EXHAUSTIVE over all five Gate.Kinds values.
 */
export function decisionBucket(kind: PendingCaseKind): "decide" | "reply" {
  switch (kind) {
    case "needs_input":
      return "reply";
    case "tool_call":
    case "plan":
    case "irreversible_write":
    case "review_stall":
      return "decide";
    default:
      return assertNever(kind);
  }
}

/**
 * The single count source — PAGE-FREE by construction: counts and grants
 * never read inbox rows, so shell chrome never imports rich data. The
 * AUTHORITATIVE summary adjusted by overlay deltas, bucketed via
 * decisionBucket. DELTAS RETIRE ONLY ON EXPLICIT ACKNOWLEDGEMENT — NEVER on
 * inbox membership: the summary and the rich inbox are INDEPENDENT wire
 * operations (needs-doc #4), so a row vanishing from a refetched page
 * proves nothing about the aggregate — treating absence as absorption would
 * bounce the badge back up whenever the inbox refreshes before the summary,
 * and intersecting with page rows would force shell chrome to mount the
 * rich inbox it must never fetch. Acknowledgement is version-derived in the
 * local store (approvals-local-state); this derivation just consumes
 * whatever deltas remain unacknowledged.
 */
export function deriveApprovalsSummary(
  summary: ApprovalsSummaryData,
  deltas: readonly OptimisticDelta[],
  now: string,
): ApprovalsSummary {
  const totals = { decide: 0, reply: 0 };
  for (const kind of PENDING_CASE_KINDS) {
    totals[decisionBucket(kind)] += summary.pendingByKind[kind];
  }
  for (const delta of deltas) {
    totals[decisionBucket(delta.kind)] -= 1;
  }
  return {
    pendingLeft: Math.max(0, summary.total - deltas.length),
    decide: Math.max(0, totals.decide),
    reply: Math.max(0, totals.reply),
    ...(summary.oldestInsertedAt !== null
      ? { oldestAge: formatAge(now, summary.oldestInsertedAt) }
      : {}),
  };
}

// ---------------------------------------------------------------------------
// Inbox (the paginated rich operation — the approvals route's ONLY source)
// ---------------------------------------------------------------------------

export type ApprovalsInboxData = Readonly<{
  /**
   * The summary version this page was certified against — COMPARABLE, not a
   * bare boolean: a page certified at V1 must stop certifying the moment
   * the accepted summary advances to V2 (a stale `true` would let V1 rows
   * replace V2's authoritative oldest). The fixture sets 1 (one static
   * literal backs both sources, so they ARE one snapshot); slice 1 sets
   * null until needs-doc #4's snapshot certificate exists.
   */
  snapshotVersion: number | null;
  /**
   * ONE bounded page in the server's total order (pendingOrder mirror). The
   * fixture's page is the complete set: total === pending.length.
   */
  pending: readonly PendingCase[];
  /**
   * endCursor is a KEYSET cursor over the total order — no snapshot
   * isolation needed: merges dedupe by case id, endCursor advances
   * monotonically, and a repeated cursor is idempotent (needs-doc #4).
   */
  pageInfo: Readonly<{ hasNextPage: boolean; endCursor: string | null }>;
}>;

/**
 * ROUTE-LOCAL header polish, imported only by the approvals route: rows
 * drive the display ONLY when the page is CERTIFIED — snapshotVersion
 * matches the accepted baseline's version AND the page is complete — then
 * the min-insertedAt row not locally resolved supplies its age, so the
 * header derives from exactly the rows the LIST shows (the preview fixture
 * certifies at the fixture summary's version, giving the mock's 12m → 4m
 * shift on resolving the oldest). A null or MISMATCHED snapshotVersion —
 * every live page until needs-doc #4's certificate ships, and any page
 * whose certification the accepted summary has outrun — keeps the SERVER
 * value even when hasNextPage is false.
 */
export function deriveOldestShown(
  baseline: Readonly<{ oldestInsertedAt: string | null; version: number }>,
  now: string,
  inbox: ApprovalsInboxData,
  resolvedIds: ReadonlySet<string>,
): string | undefined {
  const certified =
    inbox.snapshotVersion !== null &&
    inbox.snapshotVersion === baseline.version &&
    !inbox.pageInfo.hasNextPage;
  if (!certified) {
    if (baseline.oldestInsertedAt === null) return undefined;
    return formatAge(now, baseline.oldestInsertedAt);
  }
  let oldest: string | null = null;
  for (const row of inbox.pending) {
    if (resolvedIds.has(row.id)) continue;
    if (oldest === null || row.insertedAt < oldest) oldest = row.insertedAt;
  }
  return oldest !== null ? formatAge(now, oldest) : undefined;
}

// ---------------------------------------------------------------------------
// Connection acceptance + the fetch-more guard — REAL, TESTED production
// code the preview hook already wraps (slice 1 swaps only the fetcher for
// Apollo fetchMore; the field policy stays keyArgs + replacement-only, so
// the generation-aware updateQuery closure is the ONE merge authority —
// needs-doc #4).
// ---------------------------------------------------------------------------

// The helper is HANDED its identity-bearing context, never left to infer
// replacement-vs-append or the request cursor from shapes.
export type InboxConnectionContext = Readonly<{
  mode: "replace" | "append";
  generation: number;
  after: string | null;
}>;

/**
 * Connection acceptance: an initial/refetch response REPLACES the
 * connection; fetch-more results APPEND with id dedupe (a row resolved
 * between pages never duplicates; a repeated cursor is idempotent). Pages
 * certified at different summary versions cannot jointly certify — the
 * merged snapshotVersion nulls on mismatch.
 */
export function acceptInboxConnection(
  existing: ApprovalsInboxData | undefined,
  incoming: ApprovalsInboxData,
  context: InboxConnectionContext,
): ApprovalsInboxData {
  if (context.mode === "replace" || existing === undefined) return incoming;
  const seen = new Set(existing.pending.map((row) => row.id));
  const appended = incoming.pending.filter((row) => !seen.has(row.id));
  return {
    snapshotVersion:
      existing.snapshotVersion === incoming.snapshotVersion ? existing.snapshotVersion : null,
    pending: [...existing.pending, ...appended],
    pageInfo: incoming.pageInfo,
  };
}

export type FetchMoreGuard = Readonly<{
  /** Current connection generation. */
  generation: () => number;
  /**
   * Mint a new generation (every initial/refetch REPLACEMENT): abandons the
   * old generation's in-flight entry — a still-pending generation-N request
   * can never block the N+1 connection's load-more — and its merged-cursor
   * suppression (a fresh connection may legitimately re-expose a
   * previously-merged cursor, so suppression dies with its generation).
   */
  advance: () => number;
  /**
   * The guarded fetch-more: ignores re-entrant calls while one is in flight
   * (this generation), no-ops a cursor already merged in this generation,
   * and — because every request captures its generation token AT START —
   * DISCARDS a stale completion before any merge.
   */
  run: (after: string | null) => Promise<void>;
}>;

/** The concurrency fence behind LoadMoreRow — the disabled button is presentation only. */
export function createFetchMoreGuard<T>(
  fetcher: (after: string | null) => Promise<T>,
  onResult: (result: T, context: Readonly<{ generation: number; after: string | null }>) => void,
): FetchMoreGuard {
  let generation = 0;
  const inFlight = new Set<number>();
  const merged = new Set<string>();
  const cursorKey = (gen: number, after: string | null) =>
    after === null ? String(gen) : `${String(gen)}:${after}`;
  return Object.freeze({
    generation: () => generation,
    advance: () => {
      generation += 1;
      return generation;
    },
    run: async (after: string | null) => {
      const gen = generation;
      if (inFlight.has(gen)) return;
      if (merged.has(cursorKey(gen, after))) return;
      inFlight.add(gen);
      try {
        const result = await fetcher(after);
        if (generation !== gen) return; // stale completion — discarded before any merge
        merged.add(cursorKey(gen, after));
        onResult(result, { generation: gen, after });
      } finally {
        inFlight.delete(gen);
      }
    },
  });
}

// ---------------------------------------------------------------------------
// The fixture (mock-exact copy; insertedAt literals chosen so display ages
// hold against PREVIEW_NOW and the pendingOrder sort reproduces the mock
// card order).
// ---------------------------------------------------------------------------

/** The frozen preview clock — tests and preview derivations never read the wall clock. */
export const PREVIEW_NOW = "2026-07-14T12:00:00.000Z";

function deepFreeze<T>(value: T): T {
  if (typeof value === "object" && value !== null) {
    for (const nested of Object.values(value)) deepFreeze(nested);
    Object.freeze(value);
  }
  return value;
}

const PENDING_CASES: readonly PendingCase[] = deepFreeze([
  {
    id: "cmd-prisma",
    kind: "tool_call" as const,
    threadRef: "export-pipeline",
    project: "quill",
    node: "atlas",
    worktree: "export-stream",
    taskRef: "T-214",
    age: "4m",
    insertedAt: "2026-07-14T11:56:00.000Z",
    presentation: {
      type: "command" as const,
      commandPreview: "pnpm dlx prisma migrate deploy",
      complete: true,
      riskNote: "writes to dev db on atlas",
      // A migration's effective destination includes the RESOLVED
      // datasource, not just host/worktree (`prisma migrate deploy` reads
      // it from config/env, and an unbound risk-note string enforces
      // nothing), so the fixture binds the stable non-secret database
      // identity too — and may honestly offer standing scopes because the
      // persisted grant subject binds that same identity (needs-doc #2).
      authorization: { template: "main", target: "atlas · wt export-stream · db quill_dev" },
    },
    scopeOptions: [
      { id: "scope-once", kind: "once" as const },
      { id: "scope-thread", kind: "thread" as const, threadRef: "export-pipeline" },
      { id: "scope-project", kind: "project" as const, project: "quill", ttlDays: 7 },
    ],
  },
  {
    id: "q-hmac",
    kind: "needs_input" as const,
    threadRef: "webhook-endpoints",
    project: "helios-api",
    node: "wren",
    age: "12m",
    insertedAt: "2026-07-14T11:48:00.000Z",
    question:
      "“HMAC secret per endpoint, or one shared signing key? Per-endpoint is safer but adds a rotation table.”",
  },
  {
    id: "gate-export-plan",
    kind: "plan" as const,
    threadRef: "export-pipeline",
    project: "quill",
    node: null,
    age: "4m",
    insertedAt: "2026-07-14T11:56:00.000Z",
    title: "Plan review — export pipeline",
    format: "markdown",
  },
]);

// The summary derives from the same literal the page renders (the fixture
// page IS the complete set), so the two sources can never disagree in
// preview; grantsCount is the 4a mock's independent count.
function countByKind(cases: readonly PendingCase[]): Record<PendingCaseKind, number> {
  const counts: Record<PendingCaseKind, number> = {
    tool_call: 0,
    needs_input: 0,
    plan: 0,
    irreversible_write: 0,
    review_stall: 0,
  };
  for (const item of cases) counts[item.kind] += 1;
  return counts;
}

const APPROVALS_SUMMARY: ApprovalsSummaryData = deepFreeze({
  version: 1,
  asOf: PREVIEW_NOW,
  pendingByKind: countByKind(PENDING_CASES),
  total: PENDING_CASES.length,
  oldestInsertedAt: PENDING_CASES.reduce<string | null>(
    (oldest, item) => (oldest === null || item.insertedAt < oldest ? item.insertedAt : oldest),
    null,
  ),
  grantsCount: 4,
});

const APPROVALS_INBOX: ApprovalsInboxData = deepFreeze({
  // One static literal backs both sources, so the fixture page IS a
  // snapshot certified at the fixture summary's version; slice 1 sets null
  // until the server certificate exists (needs-doc #4).
  snapshotVersion: APPROVALS_SUMMARY.version,
  pending: PENDING_CASES,
  pageInfo: { hasNextPage: false, endCursor: null },
});

// ---------------------------------------------------------------------------
// The two seams. Hook results model slice-1 semantics NOW (statuses,
// refetch/fetchMore) so the screen's guards exist before Apollo arrives;
// preview constants: data always the fixture, every status "idle".
// ---------------------------------------------------------------------------

export type SeamStatus = "idle" | "loading" | "error";

export type ApprovalsSummarySeamResult = Readonly<{
  data: ApprovalsSummaryData | undefined;
  status: SeamStatus;
  refetch: () => void;
}>;

export type ApprovalsInboxSeamResult = Readonly<{
  /**
   * Undefined ONLY while the initial load is in flight or failed with
   * nothing cached; data + initialStatus "error" together mean a background
   * refresh failed and the rendered data is STALE — kept on screen with an
   * honest notice, never blanked.
   */
  data: ApprovalsInboxData | undefined;
  initialStatus: SeamStatus;
  refetch: () => void;
  fetchMore: (after: string | null) => void;
  fetchMoreStatus: SeamStatus;
}>;

/** Non-hook getter for tests and pure code (rules-of-hooks is name-based). */
export function getApprovalsSummaryData(): ApprovalsSummaryData {
  return APPROVALS_SUMMARY;
}

const SUMMARY_RESULT: ApprovalsSummarySeamResult = Object.freeze({
  data: APPROVALS_SUMMARY,
  status: "idle" as const,
  refetch: () => undefined,
});

/**
 * Hook-named seam — slice 1 swaps THIS source for the summary-only GraphQL
 * operation, drop-in. Consumed by the root store coordinator only; shell
 * chrome reads useApprovalsSummary() (the store selector), never this.
 */
export function useApprovalsSummaryData(): ApprovalsSummarySeamResult {
  return SUMMARY_RESULT;
}

export function getApprovalsInboxData(): ApprovalsInboxData {
  return APPROVALS_INBOX;
}

// The PRODUCTION hook wraps its own fetcher with the tested guard even in
// preview (a no-op fetcher today, Apollo fetchMore in slice 1) — the
// concurrency fence is real code, not mock behavior. The fixture's page is
// complete (hasNextPage false), so LoadMoreRow never renders in preview.
const PREVIEW_FETCH_MORE_GUARD = createFetchMoreGuard(
  () => Promise.resolve(undefined),
  () => undefined,
);

const INBOX_RESULT: ApprovalsInboxSeamResult = Object.freeze({
  data: APPROVALS_INBOX,
  initialStatus: "idle" as const,
  refetch: () => undefined,
  fetchMore: (after: string | null) => {
    PREVIEW_FETCH_MORE_GUARD.run(after).catch(() => undefined);
  },
  fetchMoreStatus: "idle" as const,
});

/**
 * Hook-named seam — mounted ONLY by the approvals route; slice 1 swaps THIS
 * source for the paginated rich-inbox operation. Shell chrome never imports
 * it (needs-doc #4).
 */
export function useApprovalsInboxData(): ApprovalsInboxSeamResult {
  return INBOX_RESULT;
}
