import { createFileRoute, type SearchSchemaInput } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";
import {
  type FocusEvent,
  type FormEvent,
  type ReactNode,
  type Ref,
  useEffect,
  useId,
  useRef,
} from "react";
import { DecisionCard } from "@/components/system/decision-card";
import { InlineRef } from "@/components/system/inline-ref";
import { MicroCaption } from "@/components/system/micro-caption";
import { PageHeader } from "@/components/system/page-header";
import { PageShell } from "@/components/system/page-shell";
import { PreviewMarker } from "@/components/system/preview-marker";
import { StatusIconChip } from "@/components/system/status-icon-chip";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Empty, EmptyDescription } from "@/components/ui/empty";
import { Field, FieldLabel, FieldLegend, FieldSet } from "@/components/ui/field";
import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupTextarea,
} from "@/components/ui/input-group";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import {
  type ApprovalScopeOption,
  caseMeta,
  deriveOldestShown,
  type GenericPendingCase,
  type NeedsInputCase,
  normalizeScopeOptions,
  type PendingCase,
  type PlanGateCase,
  PREVIEW_NOW,
  scopeLabels,
  type SeamStatus,
  type ToolCallCase,
} from "@/lib/approvals-data";
import {
  type DecisionAction,
  type DecisionState,
  type DerivedApprovalsSummary,
  type Draft,
  type Resolution,
  type ResolvedScope,
  useAcceptedBaselineMeta,
  useApprovalsActions,
  useApprovalsInbox,
  type UseApprovalsInboxResult,
  useApprovalsSummary,
  useDecision,
  useDraft,
  useResolvedCaseIds,
} from "@/lib/approvals-local-state";
import { cn } from "@/lib/utils";

// The Approvals screen (mock 2b phone; grants/edge sibling 4a) — designed
// but NOT wired: fixture data behind the useApprovalsSummaryData /
// useApprovalsInboxData seams, locally interactive decisions in the
// root-mounted optimistic overlay (approvals-local-state), and an explicit
// preview marker instead of a live indicator. Approve/Reject/Reply resolve
// the card IN PLACE; decisions survive in-app navigation and reset on
// reload. No mutations — slice 1 swaps in decideCase (needs-doc #3).

type ApprovalsView = "pending" | "grants";

export const Route = createFileRoute("/_shell/approvals")({
  // ?view= IS the tab state (deep-linkable; invalid values coerce to
  // pending). The INPUT type is optional via SearchSchemaInput, so existing
  // linkOptions({ to: "/approvals" }) and bare router.navigate calls keep
  // compiling with no `search` key.
  validateSearch: (search: { view?: unknown } & SearchSchemaInput): { view: ApprovalsView } => ({
    view: search.view === "grants" ? "grants" : "pending",
  }),
  component: ApprovalsPage,
});

const PAGE_META_CLASSES = "font-mono text-[0.6875rem] font-medium text-muted-foreground";

function ApprovalsPage() {
  const { view } = Route.useSearch();
  const navigate = Route.useNavigate();
  const summaryResult = useApprovalsSummary();
  const inbox = useApprovalsInbox();
  const baselineMeta = useAcceptedBaselineMeta();
  const resolvedCaseIds = useResolvedCaseIds();
  const summary = summaryResult.summary;

  // Route-local header polish: rows drive the "oldest" display only on a
  // version-certified complete page (deriveOldestShown); the ACCEPTED
  // baseline's server value stands otherwise — including while the inbox is
  // loading or failed.
  const oldestShown =
    baselineMeta === undefined
      ? undefined
      : inbox.data === undefined
        ? summary?.oldestAge
        : deriveOldestShown(baselineMeta, PREVIEW_NOW, inbox.data, resolvedCaseIds);

  return (
    <PageShell>
      <PageHeader
        title="Approvals"
        trailing={
          <div className="flex flex-col items-end gap-0.5">
            {view === "pending"
              ? oldestShown !== undefined && (
                  <p data-slot="page-meta" className={PAGE_META_CLASSES}>
                    oldest {oldestShown}
                  </p>
                )
              : summary !== undefined && (
                  <p data-slot="page-meta" className={PAGE_META_CLASSES}>
                    {summary.grants} standing
                  </p>
                )}
            <PreviewMarker />
          </div>
        }
      />
      <Tabs
        value={view}
        onValueChange={(value: unknown) => {
          // Base UI may hand null on deactivation — runtime-guard to the two
          // literal values, never a cast. The FUNCTIONAL search update
          // preserves foreign params (the dev-only ?mock= scenario key must
          // survive tab switches).
          if (value === "pending" || value === "grants") {
            void navigate({ replace: true, search: (prev) => ({ ...prev, view: value }) });
          }
        }}
        className="gap-0"
      >
        <div className="flex items-center gap-1.5 px-[18px] pt-2.5 pb-3.5 md:px-0">
          <TabsList variant="pill" aria-label="Approvals view">
            {/* Tones are fixed per tab regardless of selection (4a shows
                inactive-Pending still amber — tone encodes attention). No
                summary baseline → no count rendered: absence over fake zeros. */}
            <TabsTrigger value="pending">
              Pending
              {summary !== undefined && <TabCount tone="waiting">{summary.pendingLeft}</TabCount>}
            </TabsTrigger>
            <TabsTrigger value="grants">
              Grants
              {summary !== undefined && <TabCount tone="muted">{summary.grants}</TabCount>}
            </TabsTrigger>
          </TabsList>
          {view === "pending" && summary !== undefined && (
            <PendingSummary className="ml-auto" summary={summary} />
          )}
        </div>
        <TabsContent value="pending">
          <div className="px-3.5 md:max-w-2xl md:px-0">
            {summaryResult.status === "error" && (
              <QuietRetryLine onRetry={summaryResult.refetch}>
                couldn't refresh the approvals summary
              </QuietRetryLine>
            )}
            <PendingList inbox={inbox} />
          </div>
        </TabsContent>
        <TabsContent value="grants">
          <div className="px-3.5 md:max-w-2xl md:px-0">
            <GrantsPlaceholder count={summary?.grants} />
          </div>
        </TabsContent>
      </Tabs>
    </PageShell>
  );
}

// ---------------------------------------------------------------------------
// Pending list + page-level data states (rendered only under seam mocks in
// this phase — the preview constants never produce them, but the guards are
// slice-1 semantics modeled now).
// ---------------------------------------------------------------------------

function PendingList({ inbox }: { inbox: UseApprovalsInboxResult }) {
  const data = inbox.data;
  if (data === undefined) {
    return inbox.initialStatus === "error" ? (
      <ApprovalsErrorPanel onRetry={inbox.refetch} />
    ) : (
      <ApprovalsSkeleton />
    );
  }
  // The empty arm keys on the MERGED rows, never raw pending: an
  // acknowledged resolved snapshot still renders in place, and the empty
  // state must never hide it.
  const rows = inbox.rows;
  return (
    <>
      {inbox.initialStatus === "error" && (
        <QuietRetryLine onRetry={inbox.refetch}>
          couldn't refresh — showing last data
        </QuietRetryLine>
      )}
      {rows.length === 0 ? (
        <Empty
          data-slot="pending-empty"
          className="rounded-xl border bg-card text-sm text-muted-foreground"
        >
          <EmptyDescription>Nothing pending — all caught up.</EmptyDescription>
        </Empty>
      ) : (
        <>
          <ul role="list" className="flex flex-col gap-2">
            {rows.map((item) => (
              <li key={item.id}>
                <PendingCaseCard item={item} />
              </li>
            ))}
          </ul>
          {data.pageInfo.hasNextPage && (
            <LoadMoreRow
              status={inbox.fetchMoreStatus}
              onClick={() => {
                inbox.fetchMore(data.pageInfo.endCursor);
              }}
            />
          )}
          <MicroCaption className="mt-3.5 px-1 md:px-0.5">
            Cards stay until you decide, then resolve in place — answering a comment, not clearing a
            dialog.
          </MicroCaption>
        </>
      )}
    </>
  );
}

function QuietRetryLine({ children, onRetry }: { children: ReactNode; onRetry: () => void }) {
  return (
    <p
      role="status"
      className="mb-2 flex items-center gap-2 font-mono text-[0.6875rem] text-muted-foreground"
    >
      {children}
      <Button
        type="button"
        variant="ghost"
        size="xs"
        onClick={onRetry}
        className="font-mono text-[0.6875rem]"
      >
        Retry
      </Button>
    </p>
  );
}

function ApprovalsSkeleton() {
  return (
    <div className="flex flex-col gap-2">
      {[0, 1, 2].map((index) => (
        <Skeleton key={index} aria-hidden="true" className="h-32 rounded-[14px]" />
      ))}
      <p role="status" className="sr-only">
        loading approvals…
      </p>
    </div>
  );
}

function ApprovalsErrorPanel({ onRetry }: { onRetry: () => void }) {
  return (
    <Empty
      data-slot="approvals-error"
      className="rounded-xl border bg-card text-sm text-muted-foreground"
    >
      <EmptyDescription>couldn't load approvals</EmptyDescription>
      <Button type="button" variant="outline" onClick={onRetry}>
        Retry
      </Button>
    </Empty>
  );
}

function LoadMoreRow({ status, onClick }: { status: SeamStatus; onClick: () => void }) {
  // Quiet full-width load-more; the disabled face is presentation — the
  // real concurrency fence is createFetchMoreGuard behind the seam's
  // fetchMore. On error the SAME single button re-labels to an honest
  // retry (one control, no dead end). Never renders on a complete page.
  const loading = status === "loading";
  return (
    <Button
      type="button"
      variant="ghost"
      onClick={onClick}
      disabled={loading}
      aria-busy={loading || undefined}
      className="mt-2 w-full font-mono text-[0.71875rem] text-muted-foreground"
    >
      {status === "error" ? "Couldn't load more — Retry" : "Load more"}
    </Button>
  );
}

// ---------------------------------------------------------------------------
// Route-local chrome pieces (all honestly n=1 — the 5b desk sibling and
// styleguide demos don't count as real sites).
// ---------------------------------------------------------------------------

function TabCount({ tone, children }: { tone: "waiting" | "muted"; children: ReactNode }) {
  return (
    <Badge
      variant={tone === "waiting" ? "waiting" : "muted"}
      className="h-4 min-w-4 rounded-full px-1 font-mono text-[0.59375rem] leading-none font-bold tabular-nums"
    >
      {children}
    </Badge>
  );
}

function PendingSummary({
  summary,
  className,
}: {
  summary: DerivedApprovalsSummary;
  className?: string;
}) {
  return (
    <p
      data-slot="pending-summary"
      className={cn("font-mono text-[0.6875rem] font-medium text-muted-foreground", className)}
    >
      <span className="text-status-waiting">{summary.decide}</span>
      {" decide · "}
      <span className="text-status-waiting">{summary.reply}</span>
      {" reply"}
    </p>
  );
}

function GrantsPlaceholder({ count }: { count?: number }) {
  // The count is the ADJUSTED grants value from useApprovalsSummary() —
  // never the raw baseline and provably no literal: the placeholder must
  // agree with the Grants TabCount and page-meta after a standing-scope
  // approval. Count-free copy when the summary is unavailable — never
  // "undefined standing grants".
  return (
    <Empty
      data-slot="grants-placeholder"
      className="rounded-xl border bg-card text-sm text-muted-foreground"
    >
      <EmptyDescription>
        {count !== undefined
          ? `${String(count)} standing grants — this tab is designed in a later slice (4a).`
          : "Standing grants — this tab is designed in a later slice (4a)."}
      </EmptyDescription>
    </Empty>
  );
}

// ---------------------------------------------------------------------------
// The cards. Decision state arrives as a PROP so the transient branches
// (submitting / error / reconcile / tombstone — slice-1 producers) are
// unit-renderable with hand-built states, no store backdoor.
// ---------------------------------------------------------------------------

function assertNeverCase(value: never): never {
  throw new Error(`unhandled case: ${JSON.stringify(value)}`);
}

function PendingCaseCard({ item }: { item: PendingCase }) {
  const draft = useDraft(item.id);
  const decision = useDecision(item.id);
  const actions = useApprovalsActions();
  const handlers = {
    decision,
    draft: draft ?? {},
    onDraftChange: (next: Draft) => {
      actions.setDraft(item.id, next);
    },
    onResolve: (outcome: Resolution) => {
      actions.resolve(item, outcome);
    },
    // The reconcile Retry reissues the by-id read in slice 1 — prop-driven;
    // preview never produces the reconcile state.
    onRetryReconcile: () => undefined,
    onDismiss: () => {
      actions.dismiss(item.id);
    },
  };
  switch (item.kind) {
    case "tool_call":
      return <ToolCallCard item={item} {...handlers} />;
    case "needs_input":
      return <QuestionCard item={item} {...handlers} />;
    case "plan":
      return <GateLinkCard item={item} />;
    case "irreversible_write":
    case "review_stall":
      return <GenericCaseCard item={item} />;
    default:
      return assertNeverCase(item);
  }
}

export type DecisionCardHandlers = Readonly<{
  decision: DecisionState | undefined;
  draft: Draft;
  onDraftChange: (draft: Draft) => void;
  onResolve: (outcome: Resolution) => void;
  onRetryReconcile: () => void;
  onDismiss: () => void;
}>;

// Enablement derives from the decision state: for error states the server's
// authoritative allowedActions set is the ONLY authority (a parent_terminal
// approve failure keeps Reject enabled — a dead approve never strands a
// pending case); reconcile and tombstone lock everything.
function decisionFlags(decision: DecisionState | undefined) {
  const submitting = decision?.status === "submitting";
  const error = decision?.status === "error" ? decision : undefined;
  const resolved = decision?.status === "resolved" ? decision : undefined;
  const reconcile = error !== undefined && error.disposition === "reconcile";
  const tombstone =
    error !== undefined && error.disposition === "terminal" && error.allowedActions.size === 0;
  const allows = (action: DecisionAction): boolean => {
    if (submitting || reconcile || tombstone || resolved !== undefined) return false;
    if (error === undefined) return true;
    return error.allowedActions.has(action);
  };
  return { submitting, error, resolved, reconcile, tombstone, allows };
}

// One-shot, remount-safe, ownership-tracked focus move: resolving unmounts
// the focused control, so the card moves keyboard focus to its resolution
// node — but only on a LIVE transition (the ref initializes from the
// CURRENT snapshot on mount, so a resolved card remounting after a
// tab/route round-trip sees no empty→filled transition and steals nothing),
// and only while ownership holds (recorded at action start, cleared when
// focus leaves the card's form — a user who tabbed to a sibling during a
// slice-1 submitting wait must not have focus yanked back).
function useResolutionFocus(isResolved: boolean) {
  const statusRef = useRef<HTMLParagraphElement | null>(null);
  const wasResolved = useRef(isResolved);
  const ownership = useRef(false);
  useEffect(() => {
    if (isResolved && !wasResolved.current && ownership.current) {
      statusRef.current?.focus();
      ownership.current = false;
    }
    wasResolved.current = isResolved;
  }, [isResolved]);
  const markOwnership = () => {
    ownership.current = true;
  };
  const releaseOwnership = (event: FocusEvent<HTMLElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
      ownership.current = false;
    }
  };
  return { statusRef, markOwnership, releaseOwnership };
}

// The always-mounted per-card status node (WCAG 4.1.3 — transient states
// announce through the SAME region the resolution fills): sr-only while
// empty (sr-only is absolutely positioned, so no phantom flex gap), full-
// contrast mono when filled. tabIndex={-1} keeps it out of the tab order
// while letting the focus move land on it. pre-wrap + anywhere-wrap because
// replies are multiline textarea text with possibly long unbroken tokens.
function DecisionResolution({
  statusRef,
  children,
}: {
  statusRef: Ref<HTMLParagraphElement>;
  children: ReactNode;
}) {
  const filled = children !== null && children !== undefined && children !== false;
  return (
    <p
      ref={statusRef}
      role="status"
      tabIndex={-1}
      data-slot="decision-resolution"
      className={
        filled
          ? "font-mono text-[0.71875rem] whitespace-pre-wrap text-muted-foreground wrap-anywhere"
          : "sr-only"
      }
    >
      {children}
    </p>
  );
}

function DecisionTombstone({ onDismiss }: { onDismiss: () => void }) {
  // A recovery-less error (empty allowedActions, non-retryable,
  // non-reconcile — the case is gone server-side): ONLY the one Dismiss
  // control that clears the decision, draft, and snapshot — the failure
  // copy renders in the always-mounted DecisionResolution status region
  // above, so AT announces it when the state lands. A permanently locked
  // corpse the operator can never clear would violate both the
  // server-authoritative rule and no-dead-ends.
  return (
    <div data-slot="decision-tombstone" className="flex justify-end">
      <Button type="button" variant="outline" size="xs" onClick={onDismiss}>
        Dismiss
      </Button>
    </div>
  );
}

function resolvedScopeCopy(scope: ResolvedScope): string {
  // Resolution copy PROVABLY derives from the structured scope via the same
  // scopeLabels helper — no label field exists on the wire to forge or parse.
  switch (scope.kind) {
    case "once":
      return scopeLabels({ id: "resolved", kind: "once" }).resolved;
    case "thread":
      return scopeLabels({ id: "resolved", kind: "thread", threadRef: scope.threadRef }).resolved;
    case "project":
      return scopeLabels({
        id: "resolved",
        kind: "project",
        project: scope.project,
        ttlDays: scope.ttlDays,
      }).resolved;
    default:
      return assertNeverCase(scope);
  }
}

function toolCallResolutionText(outcome: Resolution): string {
  switch (outcome.kind) {
    case "approved": {
      const note = outcome.note.trim();
      return `Approved — ${resolvedScopeCopy(outcome.scope)}${note !== "" ? ` · “${note}”` : ""}`;
    }
    case "rejected": {
      const note = outcome.note.trim();
      return `Rejected${note !== "" ? ` · “${note}”` : ""}`;
    }
    case "replied":
      return `Replied — “${outcome.reply}”`;
    default:
      return assertNeverCase(outcome);
  }
}

function questionResolutionText(outcome: Resolution): string {
  switch (outcome.kind) {
    case "replied":
      return `Replied — “${outcome.reply}”`;
    case "rejected":
      // The quiet composer Reject: the backend's "no answer will be given".
      return "Rejected — no answer given";
    case "approved":
      return `Approved — ${resolvedScopeCopy(outcome.scope)}`;
    default:
      return assertNeverCase(outcome);
  }
}

function decisionStatusContent(
  flags: ReturnType<typeof decisionFlags>,
  resolutionText: (outcome: Resolution) => string,
  onRetryReconcile: () => void,
): ReactNode {
  if (flags.submitting) return "submitting…";
  if (flags.resolved !== undefined) {
    return (
      <>
        {resolutionText(flags.resolved.outcome)}
        {flags.resolved.followUpFailure !== null && (
          // The decided-but-degraded arm (needs-doc #3's committed-with-error):
          // the decision is authoritative, controls stay unmounted, but the
          // failure is visible at full contrast.
          <span className="block text-status-waiting">
            decided, but the workflow failed to resume — {flags.resolved.followUpFailure}
          </span>
        )}
      </>
    );
  }
  if (flags.error !== undefined) {
    if (flags.reconcile) {
      return (
        <>
          {"decided elsewhere — reconciling to the authoritative outcome "}
          <Button type="button" variant="outline" size="xs" onClick={onRetryReconcile}>
            Retry
          </Button>
        </>
      );
    }
    const base = `couldn't ${flags.error.action} — ${flags.error.code}`;
    return flags.tombstone ? `${base}; this case no longer exists server-side` : base;
  }
  return null;
}

function toResolvedScope(option: ApprovalScopeOption): ResolvedScope {
  switch (option.kind) {
    case "once":
      return { kind: "once" };
    case "thread":
      return { kind: "thread", threadRef: option.threadRef };
    case "project":
      return { kind: "project", project: option.project, ttlDays: option.ttlDays };
    default:
      return assertNeverCase(option);
  }
}

// ---------------------------------------------------------------------------
// ToolCallCard — the command/tool approval card.
// ---------------------------------------------------------------------------

export function ToolCallCard({
  item,
  decision,
  draft,
  onDraftChange,
  onResolve,
  onRetryReconcile,
  onDismiss,
}: DecisionCardHandlers & { item: ToolCallCase }) {
  const labelId = useId();
  const noteId = useId();
  const flags = decisionFlags(decision);
  const { statusRef, markOwnership, releaseOwnership } = useResolutionFocus(
    flags.resolved !== undefined,
  );

  const refLabel = item.threadRef ?? "agent";
  // Defensive scope resolution over a NORMALIZED option set: any validation
  // failure (duplicate ids, missing/duplicated once, unsafe names, bad TTL)
  // renders the card reject-only — no chips, no Approve, nothing to throw on.
  const normalized = normalizeScopeOptions(item.scopeOptions);
  const onceOption = normalized?.find((option) => option.kind === "once");
  // A stale draft id (policy refreshed the option set) silently falls back
  // to the REQUIRED one-shot option — never a server default id.
  const selectedScope =
    normalized === null
      ? undefined
      : (normalized.find((option) => option.id === draft.scopeId) ?? onceOption);
  const complete = item.presentation.complete;
  const canApprove = flags.allows("approve") && complete && selectedScope !== undefined;
  const canReject = flags.allows("reject");
  // A single-option (hard-block) set has no choice to present; a disallowed
  // approve hides the radios exactly like the other fences — a draft no
  // permitted action can consume must not keep focusable controls.
  const showScopeGroup =
    normalized !== null &&
    normalized.length > 1 &&
    complete &&
    flags.allows("approve") &&
    onceOption !== undefined;

  const approve = () => {
    if (!canApprove || selectedScope === undefined) return;
    markOwnership();
    onResolve({
      kind: "approved",
      scope: toResolvedScope(selectedScope),
      note: draft.note ?? "",
      grantEffect: selectedScope.kind === "once" ? "none" : "created",
    });
  };
  const reject = () => {
    if (!canReject) return;
    markOwnership();
    onResolve({ kind: "rejected", note: draft.note ?? "" });
  };

  const resolved = flags.resolved;
  const authorization = item.presentation.authorization;
  return (
    <DecisionCard
      tone={resolved !== undefined ? "resolved" : "amber"}
      labelId={labelId}
      icon={
        resolved !== undefined ? (
          <StatusIconChip
            status="idle"
            glyph={resolved.outcome.kind === "approved" ? "✓" : "✕"}
            size="lg"
            outline
          />
        ) : (
          <StatusIconChip status="working" glyph="ex" size="lg" />
        )
      }
      title={
        <h2
          id={labelId}
          className={cn(resolved !== undefined && "font-medium text-muted-foreground")}
        >
          {/* Title copy derives from kind + presentation.type — editorial
              fragments never ride the backend-shaped seam. */}
          {item.threadRef !== null ? (
            <InlineRef className={cn(resolved !== undefined && "text-muted-foreground")}>
              {item.threadRef}
            </InlineRef>
          ) : (
            "An agent"
          )}{" "}
          {item.presentation.type === "command" ? "wants to run a command" : "wants to run a tool"}
        </h2>
      }
      meta={caseMeta(item)}
    >
      {resolved === undefined &&
        !flags.tombstone && (
          // The form exists for grouping/naming — it never submits-to-approve:
          // both buttons are type="button", a textarea's Enter inserts a
          // newline, and onSubmit only preventDefaults (anti-rubber-stamping,
          // FLOW §12).
          <form
            data-slot="decide-form"
            aria-label={`Decide ${refLabel}`}
            aria-busy={flags.submitting || undefined}
            onSubmit={(event: FormEvent) => {
              event.preventDefault();
            }}
            onBlur={releaseOwnership}
            className="flex flex-col gap-[11px]"
          >
            <div>
              {item.presentation.type === "command" ? (
                <CommandBlock
                  text={item.presentation.commandPreview}
                  annotation={item.presentation.riskNote}
                  prompt
                />
              ) : (
                <CommandBlock
                  text={item.presentation.invocationSummary}
                  annotation={item.presentation.riskNote}
                  prompt={false}
                />
              )}
              {/* The authorization dimensions must be visible where the
                decision happens: template always, target unless the server
                proved it irrelevant (needs-doc #1/#2). */}
              <p
                data-slot="authorization-context"
                className="mt-1.5 font-mono text-[0.65625rem] text-muted-foreground any-pointer-coarse:text-xs"
              >
                requested by {authorization.template}
                {authorization.target !== null && ` · ${authorization.target}`}
              </p>
            </div>
            {!complete && (
              <p
                data-slot="incomplete-note"
                className="font-mono text-[0.65625rem] text-muted-foreground any-pointer-coarse:text-xs"
              >
                preview incomplete — the full invocation must be inspectable before approval
              </p>
            )}
            {showScopeGroup && normalized !== null && (
              <AllowScopeGroup
                options={normalized}
                value={selectedScope?.id ?? ""}
                onChange={(id) => {
                  onDraftChange({ ...draft, scopeId: id });
                }}
                name={`allow-scope-${item.id}`}
              />
            )}
            <Field>
              <FieldLabel htmlFor={noteId} className="sr-only">
                Add a note (optional)
              </FieldLabel>
              <Textarea
                id={noteId}
                name="note"
                rows={1}
                placeholder="Add a note (optional)…"
                value={draft.note ?? ""}
                onChange={(event) => {
                  onDraftChange({ ...draft, note: event.target.value });
                }}
                disabled={flags.submitting || (!flags.allows("approve") && !flags.allows("reject"))}
                className="min-h-0 rounded-[10px] px-3 py-2 not-any-pointer-coarse:pointer-fine:text-[0.78125rem]"
              />
            </Field>
            <div className="flex gap-2">
              {selectedScope !== undefined ? (
                <Button
                  type="button"
                  onClick={approve}
                  disabled={!canApprove}
                  className="h-auto flex-[1.6] rounded-[10px] py-2.5 text-[0.8125rem] font-semibold any-pointer-coarse:min-h-12"
                >
                  {scopeLabels(selectedScope).approve}
                </Button>
              ) : (
                // Reject-only: no truthful label exists for an Approve button
                // (its label IS the selected scope's), and a dead focusable is
                // banned — the explanation renders in its place.
                <p
                  data-slot="scope-unavailable"
                  className="flex-[1.6] self-center font-mono text-[0.65625rem] text-muted-foreground"
                >
                  standing approval unavailable — the offered scopes were missing or malformed
                </p>
              )}
              <Button
                type="button"
                variant="outline"
                onClick={reject}
                disabled={!canReject}
                className="h-auto flex-1 rounded-[10px] py-2.5 text-[0.8125rem] any-pointer-coarse:min-h-12"
              >
                Reject
              </Button>
            </div>
          </form>
        )}
      <DecisionResolution statusRef={statusRef}>
        {decisionStatusContent(flags, toolCallResolutionText, onRetryReconcile)}
      </DecisionResolution>
      {flags.tombstone && <DecisionTombstone onDismiss={onDismiss} />}
    </DecisionCard>
  );
}

// The ONE presentation well for both ToolCallPresentation variants:
// code.textContent equals the presentation text byte-exact (the dim $ lives
// OUTSIDE <code> as an aria-hidden select-none sibling; marker glyphs render
// via ::before pseudo-content, joining neither textContent nor the
// clipboard). whitespace-pre preserves runs, but preservation alone is not
// distinguishability — each tab and each INDIVIDUAL trailing-whitespace
// character gets its own data-ws marker span (per-character, never per-run:
// trailing-run LENGTH is fingerprint-significant), so tab-vs-spaces,
// trailing-vs-none, and trailing-length pairs can never render identically
// (needs-doc #1 records the server-escaped-display alternative).
function CommandBlock({
  text,
  annotation,
  prompt,
}: {
  text: string;
  annotation?: string;
  prompt: boolean;
}) {
  return (
    <div data-slot="command-block">
      <pre className="overflow-x-auto rounded-[10px] border bg-background px-3 py-2.5 font-mono text-xs leading-[1.55] whitespace-pre">
        {prompt && (
          <span aria-hidden="true" className="text-muted-foreground/60 select-none">
            {"$ "}
          </span>
        )}
        <code>{markedWhitespace(text)}</code>
      </pre>
      {annotation !== undefined && (
        // Decision-critical text: full-strength muted (the /60 alpha fails
        // 4.5:1 on the card surface) and 12px on touch devices.
        <p className="mt-1 text-[0.65625rem] text-muted-foreground any-pointer-coarse:text-xs">
          {annotation}
        </p>
      )}
    </div>
  );
}

const TAB_MARKER_CLASSES = "before:text-muted-foreground/60 before:content-['⇥']";
const TRAILING_MARKER_CLASSES = "before:text-muted-foreground/60 before:content-['·']";

function markedWhitespace(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let plain = "";
  let key = 0;
  const flush = () => {
    if (plain !== "") {
      nodes.push(plain);
      plain = "";
    }
  };
  const lines = text.split("\n");
  lines.forEach((line, lineIndex) => {
    const trailingMatch = /[ \t]+$/.exec(line);
    const bodyEnd = trailingMatch === null ? line.length : trailingMatch.index;
    for (let index = 0; index < line.length; index += 1) {
      const char = line[index];
      if (char === "\t") {
        flush();
        key += 1;
        nodes.push(
          <span key={key} data-ws="tab" className={TAB_MARKER_CLASSES}>
            {"\t"}
          </span>,
        );
      } else if (index >= bodyEnd) {
        flush();
        key += 1;
        nodes.push(
          <span key={key} data-ws="trailing" className={TRAILING_MARKER_CLASSES}>
            {char}
          </span>,
        );
      } else {
        plain += char;
      }
    }
    if (lineIndex < lines.length - 1) plain += "\n";
  });
  flush();
  return nodes;
}

// Native radio group composed through the field primitives: single-select,
// arrow-key roving, and group naming come free (a Base UI RadioGroup
// install was considered and declined — it adds an install for semantics
// the native elements already provide, and the chips need fully custom
// styling either way). The spacing resets are load-bearing: the field
// primitives ship gap-4/mb-1.5 defaults (verified at install) that would
// blow out the mock's ~7px legend-to-chip rhythm; the legend size override
// rides the SAME data-[variant=legend]: variant as the component's
// text-base so it wins in tailwind-merge.
function AllowScopeGroup({
  options,
  value,
  onChange,
  name,
}: {
  options: readonly ApprovalScopeOption[];
  value: string;
  onChange: (id: string) => void;
  name: string;
}) {
  return (
    <FieldSet data-slot="allow-scope" className="gap-0">
      <FieldLegend className="mb-0 font-bold tracking-[0.08em] text-muted-foreground data-[variant=legend]:text-[0.625rem]">
        ALLOW…
      </FieldLegend>
      <div className="mt-1.5 flex flex-wrap gap-1.5">
        {options.map((option) => {
          const checked = option.id === value;
          return (
            // Each chip is its own 48px target under coarse pointers —
            // scope selection is an authorization decision, not decoration.
            <label
              key={option.id}
              className={cn(
                "cursor-pointer rounded-lg border px-2.5 py-1.5 text-[0.71875rem] transition-colors has-[:focus-visible]:border-ring has-[:focus-visible]:ring-[3px] has-[:focus-visible]:ring-ring/50 any-pointer-coarse:inline-flex any-pointer-coarse:min-h-12 any-pointer-coarse:items-center",
                checked
                  ? "border-primary/55 bg-primary/15 font-semibold text-primary"
                  : "font-medium text-muted-foreground",
              )}
            >
              <input
                type="radio"
                className="sr-only"
                name={name}
                value={option.id}
                checked={checked}
                onChange={() => {
                  onChange(option.id);
                }}
              />
              {scopeLabels(option).chip}
            </label>
          );
        })}
      </div>
    </FieldSet>
  );
}

// ---------------------------------------------------------------------------
// QuestionCard — the needs_input reply composer.
// ---------------------------------------------------------------------------

export function QuestionCard({
  item,
  decision,
  draft,
  onDraftChange,
  onResolve,
  onRetryReconcile,
  onDismiss,
}: DecisionCardHandlers & { item: NeedsInputCase }) {
  const labelId = useId();
  const replyId = useId();
  const flags = decisionFlags(decision);
  const { statusRef, markOwnership, releaseOwnership } = useResolutionFocus(
    flags.resolved !== undefined,
  );
  const refLabel = item.threadRef ?? "agent";
  const reply = draft.reply ?? "";
  const canReply = flags.allows("reply");
  const canReject = flags.allows("reject");

  const send = () => {
    if (!canReply || reply.trim() === "") return;
    markOwnership();
    onResolve({ kind: "replied", reply });
  };
  const reject = () => {
    if (!canReject) return;
    markOwnership();
    // The backend's needs_input deny ("no answer will be given") — the
    // current LiveView offers it and 2b must not regress it (needs-doc #7).
    onResolve({ kind: "rejected", note: "" });
  };

  const resolved = flags.resolved;
  return (
    <DecisionCard
      tone={resolved !== undefined ? "resolved" : "amber"}
      labelId={labelId}
      icon={
        resolved !== undefined ? (
          <StatusIconChip
            status="idle"
            glyph={resolved.outcome.kind === "rejected" ? "✕" : "✓"}
            size="lg"
            outline
          />
        ) : (
          <StatusIconChip status="waiting" glyph="?" size="lg" />
        )
      }
      title={
        <h2
          id={labelId}
          className={cn(resolved !== undefined && "font-medium text-muted-foreground")}
        >
          {item.threadRef !== null ? (
            <InlineRef className={cn(resolved !== undefined && "text-muted-foreground")}>
              {item.threadRef}
            </InlineRef>
          ) : (
            "An agent"
          )}{" "}
          asked
        </h2>
      }
      meta={caseMeta(item)}
    >
      {resolved === undefined && !flags.tombstone && (
        <>
          <p className="text-[0.8125rem] leading-normal">{item.question}</p>
          {/* A block-end chat-composer shape (the shadcn API reserves inline
              addons for inputs; textareas take block addons) — a deliberate
              deviation from the mock's inline row, flagged at taste review.
              Send is an explicit click: textarea Enter = newline, matching
              the backend's textarea answer field. */}
          <form
            data-slot="reply-form"
            aria-label={`Reply to ${refLabel}`}
            aria-busy={flags.submitting || undefined}
            onSubmit={(event: FormEvent) => {
              event.preventDefault();
            }}
            onBlur={releaseOwnership}
          >
            <Field>
              <FieldLabel htmlFor={replyId} className="sr-only">
                Reply to the agent
              </FieldLabel>
              <InputGroup className="rounded-[10px]">
                <InputGroupTextarea
                  id={replyId}
                  name="reply"
                  rows={1}
                  placeholder="Reply to the agent…"
                  value={reply}
                  onChange={(event) => {
                    onDraftChange({ ...draft, reply: event.target.value });
                  }}
                  disabled={!canReply}
                  className="max-h-32 min-h-0 not-any-pointer-coarse:pointer-fine:text-[0.8125rem]"
                />
                <InputGroupAddon align="block-end" className="justify-end">
                  {/* Disjoint 48px touch slots — an overlap would let a
                      Reject tap fire Send. */}
                  <InputGroupButton
                    type="button"
                    onClick={reject}
                    disabled={!canReject}
                    className="any-pointer-coarse:min-h-12 any-pointer-coarse:min-w-12"
                  >
                    Reject
                  </InputGroupButton>
                  <InputGroupButton
                    type="button"
                    variant="default"
                    onClick={send}
                    aria-label="Send reply"
                    disabled={!canReply || reply.trim() === ""}
                    className="any-pointer-coarse:min-h-12 any-pointer-coarse:min-w-12"
                  >
                    <ArrowRight data-icon="inline-end" />
                  </InputGroupButton>
                </InputGroupAddon>
              </InputGroup>
            </Field>
          </form>
        </>
      )}
      <DecisionResolution statusRef={statusRef}>
        {decisionStatusContent(flags, questionResolutionText, onRetryReconcile)}
      </DecisionResolution>
      {flags.tombstone && <DecisionTombstone onDismiss={onDismiss} />}
    </DecisionCard>
  );
}

// ---------------------------------------------------------------------------
// GateLinkCard — the compact plan-gate deep-link card (inert until 3b).
// ---------------------------------------------------------------------------

function GateLinkCard({ item }: { item: PlanGateCase }) {
  const labelId = useId();
  // Deliberate mock deviation: the 2b mock shows an amber ›, but a chevron
  // implying navigation-to-nowhere is the visual cousin of the forbidden
  // focusable no-op — 3b replaces the note with the real link + chevron
  // (the styleguide demo keeps the chevron as the eventual shape). The card
  // counts in the `decide` bucket (case-type taxonomy) while its decide
  // affordance lives on the gate screen — needs-doc #4 records it.
  return (
    <DecisionCard
      labelId={labelId}
      icon={<StatusIconChip status="waiting" glyph="◆" size="lg" />}
      title={<h2 id={labelId}>{item.title}</h2>}
      meta={caseMeta(item)}
    >
      <p className="font-mono text-[0.6875rem] text-muted-foreground">
        decides on the gate screen — not built yet
      </p>
    </DecisionCard>
  );
}

// The minimal total-renderer arm for irreversible_write/review_stall rows
// (needs-doc #4's lightweight representation): not in the fixture, but the
// union renderer stays exhaustive — rich cards arrive with 4a and the gate
// screens.
function GenericCaseCard({ item }: { item: GenericPendingCase }) {
  const labelId = useId();
  return (
    <DecisionCard
      labelId={labelId}
      icon={<StatusIconChip status="waiting" glyph="◆" size="lg" />}
      title={<h2 id={labelId}>{item.title}</h2>}
      meta={caseMeta(item)}
    >
      <p className="font-mono text-[0.6875rem] text-muted-foreground">
        this case type gets its full card in a later slice
      </p>
    </DecisionCard>
  );
}
