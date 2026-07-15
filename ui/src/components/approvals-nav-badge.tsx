import { NavBadge } from "@/components/system/nav-badge";
import { useApprovalsSummary } from "@/lib/approvals-local-state";
import { cn } from "@/lib/utils";

// The approvals count both nav bars share, read through the ONE selector
// hook so every surface moves together after a decision. Five
// distinguishable states:
//  - a number (healthy data) — unmounting at 0: absence is the honest zero,
//    a 0 pill is noise;
//  - nothing (loading with no baseline — transient);
//  - a muted "—" marker (error with no baseline, accessible name
//    "Approvals unavailable") — a summary outage must never masquerade as a
//    healthy zero in persistent chrome;
//  - the same "—" marker (error with a retained ZERO baseline) — a zero
//    that failed to refresh carries no trustworthy signal, and a 0 pill is
//    noise, so the honest face is unavailable, never the healthy-zero
//    absence;
//  - the number with a visible data-stale treatment + "may be stale"
//    accessible name (error WITH a retained nonzero baseline) — a refresh
//    failure must not render an arbitrarily old count visually identical
//    to healthy data.
export function ApprovalsNavBadge({ className }: { className?: string }) {
  const { summary, status } = useApprovalsSummary();
  if (status === "error" && (summary === undefined || summary.pendingLeft === 0)) {
    return (
      <span
        data-slot="approvals-nav-unavailable"
        className={cn("font-mono text-[9px] font-medium text-muted-foreground", className)}
      >
        <span aria-hidden="true">—</span>
        <span className="sr-only">unavailable</span>
      </span>
    );
  }
  if (summary === undefined || summary.pendingLeft === 0) return null;
  if (status === "error") {
    return (
      <span data-stale="true" className="contents">
        <NavBadge
          count={summary.pendingLeft}
          className={cn("bg-muted text-muted-foreground", className)}
        />
        <span className="sr-only"> — may be stale</span>
      </span>
    );
  }
  return <NavBadge count={summary.pendingLeft} className={className} />;
}
