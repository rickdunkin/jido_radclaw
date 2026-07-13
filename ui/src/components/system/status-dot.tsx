import { cn } from "@/lib/utils";

export type StatusDotStatus =
  | "working"
  | "waiting"
  | "failed"
  | "done"
  | "online"
  | "idle"
  | "blocked"
  | "unknown"
  | "offline";

// The round presence dot (vs StatusIconChip, the square glyph tile).
// Connection vs activity picks the status, never the word "live": the
// glow-less green `online` marks a live connection/view and healthy nodes
// (the header/rail "live" labels, node dots); `done` is quiet lifecycle
// completion — `online` borrows its green recipe by design (one all-quiet
// green; the data-status attribute carries the semantic split, and a future
// divergence is a deliberate token addition). The glowing violet `working`
// dot marks live ACTIVITY — "working" labels, active thread rows, "editing
// src/… · 2m" indicators, and the Kanban "thread live" badge.
//
// Literal class strings so Tailwind's scanner sees every recipe
// (status-icon-chip precedent). Fills and hollows are mock-verified against
// the threads table and node rail; idle's /35 fill and blocked's /75 border
// are alpha-tuned so the token composites onto the mock hexes (#3a3a42 /
// #6a6a74) over the dark card background.
const STATUS_CLASS: Record<StatusDotStatus, string> = {
  working: "bg-status-working shadow-[0_0_8px] shadow-status-working/80",
  waiting: "bg-status-waiting",
  failed: "bg-status-failed",
  done: "bg-status-done",
  online: "bg-status-done",
  idle: "bg-status-idle/35",
  blocked: "border-status-idle/75",
  unknown: "border-dashed border-status-offline",
  offline: "border-status-offline",
};

// Hollow border width is size-proportional (mock: 1.5px @ 8px, 1px @ 6px).
const HOLLOW_BORDER: Record<"sm" | "md", string> = {
  md: "border-[1.5px]",
  sm: "border",
};

// Always decorative — the host row's status is conveyed by its text.
export function StatusDot({
  status,
  size = "md",
  className,
}: {
  status: StatusDotStatus;
  size?: "sm" | "md";
  className?: string;
}) {
  const hollow = status === "blocked" || status === "unknown" || status === "offline";
  return (
    <span
      aria-hidden="true"
      data-slot="status-dot"
      data-status={status}
      className={cn(
        "inline-block shrink-0 rounded-full",
        size === "md" ? "size-2" : "size-1.5",
        hollow && HOLLOW_BORDER[size],
        STATUS_CLASS[status],
        className,
      )}
    />
  );
}
