import { createFileRoute, Link } from "@tanstack/react-router";
import { Chevron } from "@/components/system/chevron";
import { FeedRow } from "@/components/system/feed-row";
import { GroupPanel } from "@/components/system/group-panel";
import { MicroCaption } from "@/components/system/micro-caption";
import { PageHeader } from "@/components/system/page-header";
import { PageShell } from "@/components/system/page-shell";
import { PreviewMarker } from "@/components/system/preview-marker";
import { SectionLabel } from "@/components/system/section-label";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  deriveAttentionSummary,
  groupByProject,
  needsYou,
  type ProjectGroup,
  useAttentionData,
} from "@/lib/attention-data";
import { useShellData } from "@/lib/shell-data";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/_shell/")({
  component: AttentionPage,
});

// The Attention feed (mock 2a phone / 5a desk / 5e by-project; 4c light) —
// designed but NOT wired: fixture data behind the useAttentionData() seam,
// inert rows/actions, and an explicit preview marker instead of a live
// indicator. The page root declares the named container `@container/feed`;
// every anatomy flip below rides @3xl/feed (48rem of pane, ≈1005px viewport
// with the rail up), while page gutters stay chrome-aligned at viewport md.
// The only feed control is the Priority/By-project toggle (local state).
function AttentionPage() {
  return (
    <PageShell>
      <PageHeader title="Attention" trailing={<PreviewMarker />} />
      <Tabs defaultValue="priority" className="gap-0">
        <div className="flex items-center gap-1.5 px-[18px] pt-2.5 pb-3.5 md:px-0">
          <TabsList variant="pill" aria-label="Attention view">
            <TabsTrigger value="priority">Priority</TabsTrigger>
            <TabsTrigger value="by-project">By project</TabsTrigger>
          </TabsList>
          <CountSummary className="ml-auto" />
        </div>
        <TabsContent value="priority">
          <PriorityView />
        </TabsContent>
        <TabsContent value="by-project">
          <ByProjectView />
        </TabsContent>
      </Tabs>
      <MicroCaption className="mt-3 hidden @3xl/feed:block">
        Items never vanish silently — resolved checks off in place, storms collapse to one row.
      </MicroCaption>
      <TempLinks />
    </PageShell>
  );
}

// Both wordings render from deriveAttentionSummary — no literals here. The
// phone abbreviation is decorative (aria-hidden) with an sr-only full
// phrase beside it; the whole phone pair drops out of the DOM's a11y tree
// at @3xl/feed so wide readers hear only the visible long wording.
function CountSummary({ className }: { className?: string }) {
  const data = useAttentionData();
  const { nodes } = useShellData();
  const summary = deriveAttentionSummary(data, nodes);
  return (
    <p
      data-slot="count-summary"
      className={cn("font-mono text-[0.6875rem] font-medium text-muted-foreground", className)}
    >
      <span className="@3xl/feed:hidden">
        <span aria-hidden="true" data-slot="count-summary-phone">
          <span className="text-status-working">{summary.working}</span>
          {" wk · "}
          <span className="text-status-waiting">{summary.waitingOnYou}</span>
          {" you · "}
          <span className="text-status-failed">{summary.failed}</span>
          {" fail"}
        </span>
        <span className="sr-only" data-slot="count-summary-sr">
          {`${String(summary.working)} working · ${String(summary.waitingOnYou)} waiting on you · ${String(summary.failed)} failed`}
        </span>
      </span>
      <span className="hidden @3xl/feed:inline" data-slot="count-summary-desk">
        <span className="text-status-working">{summary.working}</span>
        {" working"}
        <span aria-hidden="true">{" · "}</span>
        <span className="text-status-waiting">{summary.waitingOnYou}</span>
        {" waiting on you"}
        <span aria-hidden="true">{" · "}</span>
        <span className="text-status-failed">{summary.failed}</span>
        {" failed"}
        {summary.offlineNodes.length > 0 && (
          <>
            <span aria-hidden="true">{" · "}</span>
            {`${summary.offlineNodes.join(", ")} offline`}
          </>
        )}
      </span>
    </p>
  );
}

function PriorityView() {
  const data = useAttentionData();
  const needsYouItems = data.items.filter(needsYou);
  const earlierItems = data.items.filter((item) => !needsYou(item));
  return (
    <div className="px-3.5 md:px-0">
      <GroupPanel
        tone="amber"
        labelId="needs-you-h2"
        header={
          <SectionLabel tone="waiting" id="needs-you-h2" className="px-3 pt-2 pb-1">
            NEEDS YOU · {needsYouItems.length}
          </SectionLabel>
        }
      >
        <ul role="list" className="flex flex-col gap-1">
          {needsYouItems.map((item) => (
            <FeedRow key={item.id} item={item} variant="card" showProject />
          ))}
        </ul>
      </GroupPanel>
      {/* The view owns this labelled section: its panel is headerless (the
          label sits OUTSIDE the neutral panel in the mock), and a nested
          anonymous <section> would be wrong — see GroupPanel. */}
      <section aria-labelledby="earlier-h2">
        <SectionLabel id="earlier-h2" className="px-1 pt-5 pb-2 @3xl/feed:px-0.5">
          EARLIER
        </SectionLabel>
        <GroupPanel tone="neutral" className="px-0">
          <ul role="list">
            {earlierItems.map((item) => (
              <FeedRow key={item.id} item={item} variant="row" showProject />
            ))}
          </ul>
        </GroupPanel>
      </section>
    </div>
  );
}

function ByProjectView() {
  const data = useAttentionData();
  const groups = groupByProject(data);
  return (
    <div className="flex flex-col gap-2.5 px-3.5 md:px-0">
      {groups.map((group) =>
        group.quiet ? (
          <QuietProjectRow key={group.project} group={group} />
        ) : (
          <GroupPanel
            key={group.project}
            tone={group.tone}
            labelId={`project-${group.project}-h2`}
            header={<ProjectPanelHeader group={group} labelId={`project-${group.project}-h2`} />}
          >
            <ul role="list" className="flex flex-col gap-1">
              {group.items.map((item) => (
                <FeedRow key={item.id} item={item} variant="card" showProject={false} />
              ))}
            </ul>
          </GroupPanel>
        ),
      )}
    </div>
  );
}

function ProjectPanelHeader({ group, labelId }: { group: ProjectGroup; labelId: string }) {
  return (
    <div className="flex items-baseline gap-2 px-3 pt-2 pb-1">
      <h2 id={labelId} className="font-mono text-xs font-bold">
        {group.project}
      </h2>
      {group.needsYouCount > 0 && (
        <p className="font-mono text-[0.625rem] font-medium text-status-waiting">
          {group.needsYouCount} needs you
        </p>
      )}
      {(group.workingCount > 0 || group.failedCount > 0) && (
        <p className="ml-auto flex items-center gap-2 font-mono text-[0.65625rem] text-muted-foreground">
          {group.workingCount > 0 && (
            <span data-slot="project-working">
              <span aria-hidden="true" className="text-status-working">
                {"● "}
              </span>
              {`${String(group.workingCount)} working`}
            </span>
          )}
          {group.failedCount > 0 && (
            <span data-slot="project-failed">
              <span aria-hidden="true" className="text-status-failed">
                {"● "}
              </span>
              {`${String(group.failedCount)} failed`}
            </span>
          )}
        </p>
      )}
    </div>
  );
}

// A fully-quiet project rolls up to one line; still a labelled section with
// a single-item list so the by-project view stays uniformly navigable.
function QuietProjectRow({ group }: { group: ProjectGroup }) {
  if (!group.quietLine) return null;
  const labelId = `project-${group.project}-h2`;
  return (
    <section aria-labelledby={labelId}>
      <ul role="list">
        <li
          data-slot="quiet-project-row"
          className="flex items-center gap-[9px] rounded-xl bg-card px-3.5 py-[11px] shadow-xs dark:shadow-none"
        >
          <h2 id={labelId} className="shrink-0 font-mono text-xs font-bold text-muted-foreground">
            {group.project}
          </h2>
          <p className="min-w-0 flex-1 truncate font-mono text-[0.6875rem] text-muted-foreground/70">
            {"quiet — "}
            <span aria-hidden="true" className="text-status-done">
              ✓
            </span>
            {` ${group.quietLine.verb} ${group.quietLine.age} ago, nothing needs you`}
          </p>
          <Chevron className="text-muted-foreground/60" />
        </li>
      </ul>
    </section>
  );
}

// Temporary reachability row — REMOVE IN SLICE 1 once a real feed row
// navigates: /runs and /board have no phone tab by design and this is their
// only phone click-path meanwhile; /styleguide stays out of nav. Accessible
// names are pinned by shell.test.tsx's HREF_TABLE — keep them stable.
const TEMP_LINKS = [
  { label: "View runs", to: "/runs" },
  { label: "View projects", to: "/projects" },
  { label: "View board", to: "/board" },
  { label: "Styleguide", to: "/styleguide" },
] as const;

function TempLinks() {
  return (
    <ul
      role="list"
      className="mt-6 flex flex-wrap gap-x-4 gap-y-2 px-[18px] font-mono text-[0.6875rem] md:px-0"
    >
      {TEMP_LINKS.map((entry) => (
        <li key={entry.to}>
          <Link
            to={entry.to}
            className="text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
          >
            {entry.label}
          </Link>
        </li>
      ))}
    </ul>
  );
}
