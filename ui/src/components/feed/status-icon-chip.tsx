import { cn } from "@/lib/utils";

export type StatusIconChipStatus = "waiting" | "failed" | "done" | "idle" | "working" | "offline";

// Literal class strings so Tailwind's scanner sees every status utility
// (styleguide precedent). working/offline are pre-staged for the Approvals
// and Threads screens — the Attention feed uses the first four.
const STATUS_CLASS: Record<StatusIconChipStatus, string> = {
  waiting: "bg-status-waiting/15 text-status-waiting",
  failed: "bg-status-failed/13 text-status-failed",
  done: "bg-status-done/12 text-status-done",
  idle: "bg-muted text-muted-foreground/80",
  working: "bg-status-working/15 text-status-working",
  offline: "bg-status-offline/15 text-status-offline",
};

// The square glyph tile leading every feed row. Always decorative — the
// row's kind is conveyed by its text — so it is unconditionally aria-hidden.
// `outline` is the resolved treatment: bordered, quieter than its status.
export function StatusIconChip({
  status,
  glyph,
  size = "sm",
  outline = false,
  className,
}: {
  status: StatusIconChipStatus;
  glyph: string;
  size?: "sm" | "lg";
  outline?: boolean;
  className?: string;
}) {
  return (
    <span
      aria-hidden="true"
      data-slot="status-icon-chip"
      data-status={status}
      className={cn(
        "inline-flex shrink-0 items-center justify-center font-mono font-semibold",
        size === "lg"
          ? "size-[30px] rounded-md text-[0.8125rem]"
          : "size-[26px] rounded-[9px] text-xs",
        STATUS_CLASS[status],
        outline && "border border-border text-muted-foreground",
        className,
      )}
    >
      {glyph}
    </span>
  );
}
