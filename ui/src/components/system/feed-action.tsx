import type { AttentionAction } from "@/lib/attention-data";
import { cn } from "@/lib/utils";

// The inline resolving action on wide needs-you rows ("Open gate →").
// Deliberately INERT this phase: a styled span — no role, no tabindex, no
// hover — because the whole feed is an explicitly marked sample-data
// preview. Slice 1 swaps these for real controls.
export function FeedAction({ action, className }: { action: AttentionAction; className?: string }) {
  return (
    <span
      data-slot="feed-action"
      data-emphasis={action.emphasis}
      className={cn(
        "inline-flex shrink-0 items-center justify-center rounded-md px-3.5 py-2 text-xs font-semibold whitespace-nowrap",
        action.emphasis === "solid"
          ? "bg-status-waiting-solid text-status-waiting-solid-foreground"
          : "border border-status-waiting/50 text-status-waiting",
        className,
      )}
    >
      {action.label}
    </span>
  );
}
