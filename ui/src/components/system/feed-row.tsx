import { type AttentionItem, needsYou } from "@/lib/attention-data";
import { cn } from "@/lib/utils";
import { Chevron } from "./chevron";
import { FeedAction } from "./feed-action";
import { FeedChip } from "./feed-chip";
import { MetaLine } from "./meta-line";
import { StatusIconChip, type StatusIconChipStatus } from "./status-icon-chip";

// One attention item as an <li>. REQUIRES an ancestor declaring the named
// container `@container/feed` (the Attention page root does; a future
// narrow placement — say a side panel — declares its own): every wide/phone
// anatomy twin flips at @3xl/feed (48rem of CONTAINER), never at a viewport
// breakpoint, so the row keeps phone anatomy wherever its host is narrow.
//
// variant "card" = rounded card inside a group panel (needs-you, by-project);
// variant "row"  = full-bleed row with an inset top hairline (EARLIER). The
// hairline lives on the li itself (`before:` pseudo, hidden on the first
// child) — a <div>-rendering Separator between <li>s would be invalid list
// markup.

type KindStyle = {
  glyph: string;
  status: StatusIconChipStatus;
  chipSize: "sm" | "lg";
  outline?: boolean;
  title: string;
};

const KIND_STYLE: Record<AttentionItem["kind"], KindStyle> = {
  gate: {
    glyph: "◆",
    status: "waiting",
    chipSize: "lg",
    title: "text-[0.84375rem] font-semibold text-foreground",
  },
  question: {
    glyph: "?",
    status: "waiting",
    chipSize: "lg",
    title: "text-[0.84375rem] font-semibold text-foreground",
  },
  alert: {
    glyph: "⚠",
    status: "waiting",
    chipSize: "lg",
    title: "text-[0.84375rem] font-semibold text-foreground",
  },
  failed: {
    glyph: "✕",
    status: "failed",
    chipSize: "sm",
    title: "text-[0.8125rem] font-medium text-foreground",
  },
  done: {
    glyph: "✓",
    status: "done",
    chipSize: "sm",
    title: "text-[0.8125rem] text-foreground/85",
  },
  idle: {
    glyph: "◌",
    status: "idle",
    chipSize: "sm",
    title: "text-[0.8125rem] text-muted-foreground",
  },
  resolved: {
    glyph: "✓",
    status: "idle",
    chipSize: "sm",
    outline: true,
    title: "text-[0.8125rem] text-muted-foreground",
  },
};

export function FeedRow({
  item,
  variant,
  showProject,
  className,
}: {
  item: AttentionItem;
  variant: "card" | "row";
  showProject: boolean;
  className?: string;
}) {
  const style = KIND_STYLE[item.kind];
  const projectSegment = showProject ? [item.project] : [];
  const phoneSegments = [...projectSegment, ...item.phoneMeta, item.age];
  const deskSegments = [...projectSegment, ...item.deskMeta];

  return (
    <li
      data-slot="feed-row"
      data-kind={item.kind}
      className={cn(
        "flex items-start gap-[11px] @3xl/feed:items-center @3xl/feed:gap-3",
        // Card surface is bg-popover in BOTH panel tones — popover is the
        // tokens' "card-in-a-panel" rung (muted is claimed by chips/pills),
        // deliberately unifying 5e's neutral-panel cards with the amber-panel
        // ones rather than minting a fourth surface. Don't re-litigate.
        variant === "card"
          ? "rounded-lg bg-popover p-3 shadow-xs @3xl/feed:px-3.5 dark:shadow-none"
          : "relative px-3.5 py-[11px] before:absolute before:inset-x-3.5 before:top-0 before:h-px before:bg-border first:before:hidden",
        item.kind === "resolved" && "opacity-[.62]",
        className,
      )}
    >
      <StatusIconChip
        status={style.status}
        glyph={style.glyph}
        size={style.chipSize}
        outline={style.outline}
      />
      <div className="min-w-0 flex-1">
        <p className={cn("leading-[1.35]", style.title)}>
          {item.title}
          {item.kind === "resolved" && item.titleCode !== undefined && (
            <>
              {" "}
              <span className="font-mono text-[0.6875rem] font-medium text-foreground/85">
                {item.titleCode}
              </span>
            </>
          )}
        </p>
        <MetaLine
          data-slot="feed-meta-phone"
          segments={phoneSegments}
          className="mt-[3px] @3xl/feed:hidden"
        />
        <MetaLine
          data-slot="feed-meta-desk"
          segments={deskSegments}
          className="mt-[3px] hidden @3xl/feed:block"
        />
      </div>
      <Trailing item={item} />
    </li>
  );
}

// Trailing anatomy per kind. Needs-you rows swap a phone chevron for the
// wide age chip + inline action; failed/done extract the age beside a
// persistent chevron; idle clusters keep their ×N chip at every width;
// resolved rows carry the word itself, age appended only when wide.
function Trailing({ item }: { item: AttentionItem }) {
  if (needsYou(item)) {
    return (
      <>
        <FeedChip tone="waiting" className="hidden self-center @3xl/feed:inline-flex">
          {item.age}
        </FeedChip>
        <FeedAction action={item.action} className="hidden self-center @3xl/feed:inline-flex" />
        <Chevron className="text-status-waiting @3xl/feed:hidden" />
      </>
    );
  }
  switch (item.kind) {
    case "failed":
    case "done":
      return (
        <>
          <Age age={item.age} className="hidden @3xl/feed:inline" />
          <Chevron className="text-muted-foreground/60" />
        </>
      );
    case "idle":
      return (
        <>
          <FeedChip tone="muted" className="self-center">
            ×{item.count}
          </FeedChip>
          <Age age={item.age} className="hidden @3xl/feed:inline" />
        </>
      );
    case "resolved":
      return (
        <span
          data-slot="feed-resolved-mark"
          className="shrink-0 self-center font-mono text-[0.65625rem] font-medium text-muted-foreground"
        >
          resolved
          <span className="hidden @3xl/feed:inline"> · {item.age}</span>
        </span>
      );
  }
}

function Age({ age, className }: { age: string; className?: string }) {
  return (
    <span
      data-slot="feed-age"
      className={cn(
        "shrink-0 self-center font-mono text-[0.65625rem] text-muted-foreground/60",
        className,
      )}
    >
      {age}
    </span>
  );
}
