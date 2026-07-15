import { createFileRoute, Link } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { Chevron } from "@/components/system/chevron";
import { DecisionCard } from "@/components/system/decision-card";
import { FeedChip } from "@/components/system/feed-chip";
import { FeedRow } from "@/components/system/feed-row";
import { GroupPanel } from "@/components/system/group-panel";
import { InlineRef } from "@/components/system/inline-ref";
import { MicroCaption } from "@/components/system/micro-caption";
import { NavBadge } from "@/components/system/nav-badge";
import { SectionLabel } from "@/components/system/section-label";
import { StatusDot, type StatusDotStatus } from "@/components/system/status-dot";
import { StatusIconChip, type StatusIconChipStatus } from "@/components/system/status-icon-chip";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { needsYou, useAttentionData } from "@/lib/attention-data";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/_shell/styleguide")({
  component: StyleguidePage,
});

// The composite SPEC SHEET for components/system/: the vocabulary pieces
// rendered, including ones with no consuming screen yet (DecisionCard, the
// full StatusDot vocabulary) so Approvals/Threads start by composing. Page
// chrome (PageShell/PageHeader/PreviewMarker) is pinned by its consuming
// screens instead — PageHeader can't demo here without a second h1.
// Inline demo literals are deliberately OK here — the sheet's literals ARE
// the spec; the "no literals in components" rule governs screens fed by
// lib/ seams. Everything stays inert (FeedAction precedent): demo actions
// are styled spans, never focusable controls — the Controls section's real
// Buttons are the one pre-existing exception, kept as-is.

// StatusDot label colors: tokened statuses use their own text-status-*;
// recipe-borrowers are labeled by their BORROWED token (online→done,
// blocked→idle, unknown→offline — text-status-online/-blocked/-unknown do
// not exist). Literal strings keep the Tailwind scanner anchors.
const DOT_LABEL: Record<StatusDotStatus, string> = {
  working: "text-status-working",
  waiting: "text-status-waiting",
  failed: "text-status-failed",
  done: "text-status-done",
  online: "text-status-done",
  idle: "text-status-idle",
  blocked: "text-status-idle",
  unknown: "text-status-offline",
  offline: "text-status-offline",
};
const DOT_STATUSES = Object.keys(DOT_LABEL) as readonly StatusDotStatus[];

const CHIP_STATUSES: readonly { status: StatusIconChipStatus; glyph: string }[] = [
  { status: "waiting", glyph: "◆" },
  { status: "failed", glyph: "✕" },
  { status: "done", glyph: "✓" },
  { status: "idle", glyph: "◌" },
  { status: "working", glyph: "ex" },
  { status: "offline", glyph: "○" },
];

function Section({
  label,
  labelId,
  children,
}: {
  label: string;
  labelId: string;
  children: ReactNode;
}) {
  return (
    <section aria-labelledby={labelId} className="flex flex-col gap-3">
      <SectionLabel id={labelId}>{label}</SectionLabel>
      {children}
    </section>
  );
}

function StyleguidePage() {
  return (
    <div
      data-slot="styleguide-root"
      className="@container/feed mx-auto flex w-full max-w-4xl flex-col gap-9 p-6"
    >
      <header>
        <h1 className="text-4xl font-semibold tracking-tight">argus</h1>
        <div className="mt-4 flex gap-4">
          <Link
            to="/projects"
            className="inline-block text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
          >
            View projects
          </Link>
          <Link
            to="/runs"
            className="inline-block text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
          >
            View runs
          </Link>
        </div>
      </header>

      <Section label="STATUS DOTS" labelId="sg-status-dots">
        <div className="grid w-fit grid-cols-[5rem_auto_auto] items-center gap-x-6 gap-y-2.5">
          {DOT_STATUSES.map((status) => (
            <div key={status} className="contents">
              <span className={cn("font-mono text-xs", DOT_LABEL[status])}>{status}</span>
              <StatusDot status={status} size="md" />
              <StatusDot status={status} size="sm" />
            </div>
          ))}
        </div>
        {/* Connection vs activity picks the dot, never the word "live":
            glow-less green `online` = live connection/view; glowing violet
            `working` = live activity. */}
        <div
          data-slot="sg-composed-indicators"
          className="flex flex-wrap items-center gap-x-6 gap-y-2"
        >
          <span className="inline-flex items-center gap-1.5 font-mono text-[0.6875rem] text-muted-foreground">
            <StatusDot status="online" size="sm" />
            live
          </span>
          <span className="inline-flex items-center gap-1.5 font-mono text-[0.6875rem] text-status-working">
            <StatusDot status="working" size="sm" />
            thread live
          </span>
          <span className="inline-flex items-center gap-2 rounded-full bg-card px-3 py-2 font-mono text-[0.6875rem] text-muted-foreground">
            <StatusDot status="working" size="sm" />
            editing src/export/stream.ts · 2m
          </span>
        </div>
      </Section>

      <Section label="STATUS ICON CHIPS" labelId="sg-status-icon-chips">
        <div className="grid w-fit grid-cols-[5rem_auto_auto_auto] items-center gap-x-6 gap-y-2.5">
          {CHIP_STATUSES.map(({ status, glyph }) => (
            <div key={status} className="contents">
              <span className="font-mono text-xs text-muted-foreground">{status}</span>
              <StatusIconChip status={status} glyph={glyph} size="sm" />
              <StatusIconChip status={status} glyph={glyph} size="lg" />
              <StatusIconChip status={status} glyph={glyph} size="sm" outline />
            </div>
          ))}
        </div>
      </Section>

      <Section label="CHIPS" labelId="sg-chips">
        <div className="flex flex-wrap items-center gap-2">
          <FeedChip tone="waiting">4m</FeedChip>
          <FeedChip tone="muted">×12</FeedChip>
          <NavBadge count={3} />
          <Badge variant="waiting">3</Badge>
          <Badge variant="waiting-subtle">gate · 4m</Badge>
          <Badge variant="muted">cron</Badge>
        </div>
      </Section>

      <GroupPanelsSection />
      <FeedRowsSection />
      <DecisionCardsSection />

      <Section label="CONTROLS" labelId="sg-controls">
        <div className="flex flex-col gap-4 rounded-xl bg-card p-4">
          <div className="flex flex-wrap gap-2">
            <Button>Approve — just once</Button>
            <Button variant="secondary">This thread</Button>
            <Button variant="outline">Reject</Button>
            <Button variant="destructive">Revoke</Button>
          </div>
          <div className="flex flex-wrap gap-2">
            <Badge>3</Badge>
            <Badge variant="secondary">cron</Badge>
            <Badge variant="outline">CLI</Badge>
          </div>
        </div>
      </Section>
    </div>
  );
}

// Real panels wrapping real FeedRows — the spec sheet is a second declarer
// of @container/feed (host-portability proof), so the rows' wide/phone
// anatomy flips live with the sheet's width.
function GroupPanelsSection() {
  const data = useAttentionData();
  const needsYouItems = data.items.filter(needsYou);
  const earlierItems = data.items.filter((item) => !needsYou(item));
  return (
    <Section label="GROUP PANELS" labelId="sg-group-panels">
      <GroupPanel
        tone="amber"
        labelId="sg-panel-amber-h2"
        header={
          <SectionLabel tone="waiting" id="sg-panel-amber-h2" className="px-3 pt-2 pb-1">
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
      <GroupPanel tone="neutral" className="px-0">
        <ul role="list">
          {earlierItems.map((item) => (
            <FeedRow key={item.id} item={item} variant="row" showProject />
          ))}
        </ul>
      </GroupPanel>
    </Section>
  );
}

// All seven kinds in both variants; the fixture ships exactly one of each.
function FeedRowsSection() {
  const data = useAttentionData();
  return (
    <Section label="FEED ROWS" labelId="sg-feed-rows">
      <ul role="list" className="flex flex-col gap-1">
        {data.items.map((item) => (
          <FeedRow key={item.id} item={item} variant="card" showProject />
        ))}
      </ul>
      <GroupPanel tone="neutral" className="px-0">
        <ul role="list">
          {data.items.map((item) => (
            <FeedRow key={item.id} item={item} variant="row" showProject />
          ))}
        </ul>
      </GroupPanel>
    </Section>
  );
}

// Inert demo furniture for the DecisionCard slots (FeedAction precedent:
// styled spans, no role, no tabindex). Route-local on purpose — routes are
// exempt from only-export-components, and 2b passes real controls here.
function DemoAction({
  emphasis,
  children,
}: {
  emphasis: "solid" | "outline";
  children: ReactNode;
}) {
  return (
    <span
      className={cn(
        "flex-1 rounded-[10px] py-2.5 text-center text-[0.8125rem]",
        emphasis === "solid"
          ? "bg-primary font-semibold text-primary-foreground"
          : "border font-medium text-foreground/80",
      )}
    >
      {children}
    </span>
  );
}

function DemoScopeChip({ active, children }: { active?: boolean; children: ReactNode }) {
  return (
    <span
      className={cn(
        "rounded-lg border px-2.5 py-1.5 text-[0.71875rem]",
        active
          ? "border-primary/55 bg-primary/15 font-semibold text-primary"
          : "font-medium text-muted-foreground",
      )}
    >
      {children}
    </span>
  );
}

function DecisionCardsSection() {
  return (
    <Section label="DECISION CARDS" labelId="sg-decision-cards">
      <div className="flex flex-col gap-2">
        <DecisionCard
          labelId="sg-dc-approve"
          icon={<StatusIconChip status="working" glyph="ex" size="lg" />}
          title={
            <h3 id="sg-dc-approve">
              <InlineRef>export-pipeline</InlineRef> wants to run a command
            </h3>
          }
          meta={["quill", "wt export-stream", "atlas", "T-214", "4m"]}
          trailing={<FeedChip tone="waiting">4m</FeedChip>}
        >
          <div className="rounded-[10px] border bg-background px-3 py-2.5 font-mono text-xs leading-[1.55]">
            <span className="text-muted-foreground/60">$</span> pnpm dlx prisma migrate deploy
            <br />
            <span className="text-[0.65625rem] text-muted-foreground/60">
              writes to dev db on atlas
            </span>
          </div>
          <div>
            <p className="text-[0.625rem] font-bold tracking-[0.08em] text-muted-foreground">
              ALLOW…
            </p>
            <div className="mt-1.5 flex flex-wrap gap-1.5">
              <DemoScopeChip active>Just once</DemoScopeChip>
              <DemoScopeChip>This thread</DemoScopeChip>
              <DemoScopeChip>quill · 7 days</DemoScopeChip>
            </div>
          </div>
          <div className="rounded-[10px] border px-3 py-2 text-[0.78125rem] text-muted-foreground/60">
            Add a note (optional)…
          </div>
          <div className="flex gap-2">
            <DemoAction emphasis="solid">Approve — just once</DemoAction>
            <DemoAction emphasis="outline">Reject</DemoAction>
          </div>
        </DecisionCard>

        <DecisionCard
          labelId="sg-dc-question"
          icon={<StatusIconChip status="waiting" glyph="?" size="lg" />}
          title={
            <h3 id="sg-dc-question">
              <InlineRef>webhook-endpoints</InlineRef> asked
            </h3>
          }
          meta={["helios-api", "wren", "12m"]}
        >
          <p className="text-[0.8125rem] leading-normal">
            “HMAC secret per endpoint, or one shared signing key? Per-endpoint is safer but adds a
            rotation table.”
          </p>
          <div className="flex items-center gap-2">
            <span className="flex-1 rounded-[10px] border px-3 py-2.5 text-[0.8125rem] text-muted-foreground/60">
              Reply to the agent…
            </span>
            <span className="flex size-9 shrink-0 items-center justify-center rounded-[10px] bg-primary font-mono text-primary-foreground">
              →
            </span>
          </div>
        </DecisionCard>

        <DecisionCard
          labelId="sg-dc-gate"
          icon={<StatusIconChip status="waiting" glyph="◆" size="lg" />}
          title={<h3 id="sg-dc-gate">Plan review — export pipeline</h3>}
          meta={["quill", "gate", "markdown", "4m"]}
          trailing={<Chevron className="text-status-waiting" />}
        />

        <DecisionCard
          labelId="sg-dc-irreversible"
          icon={<StatusIconChip status="failed" glyph="!" size="lg" />}
          title={
            <h3 id="sg-dc-irreversible">
              <InlineRef>release-notes</InlineRef> wants to force-push{" "}
              <span className="font-mono text-xs">main</span>
            </h3>
          }
          meta={["quill", "atlas", "2m"]}
        >
          <p className="rounded-[10px] bg-background px-3 py-2 text-[0.6875rem] leading-[1.45] text-muted-foreground">
            Irreversible action — standing approval isn’t offered. Each request asks.
          </p>
          <div className="flex gap-2">
            <DemoAction emphasis="solid">Approve this once</DemoAction>
            <DemoAction emphasis="outline">Reject</DemoAction>
          </div>
        </DecisionCard>

        <DecisionCard
          tone="muted"
          labelId="sg-dc-expired"
          icon={<StatusIconChip status="idle" glyph="exp" size="lg" />}
          title={
            <h3 id="sg-dc-expired">
              Allow <span className="font-mono text-xs">rm -rf node_modules</span> — expired
            </h3>
          }
          meta={["helios-api", "asked 3h ago", "agent moved on without it"]}
          trailing={
            <span className="rounded-lg bg-muted px-3 py-1.5 text-[0.6875rem] font-semibold">
              Dismiss
            </span>
          }
        />
        <MicroCaption>
          Cards stay until you decide, then resolve in place — answering a comment, not clearing a
          dialog.
        </MicroCaption>
      </div>
    </Section>
  );
}
