import { cn } from "@/lib/utils";

// One mono meta line, segments joined by " · ". FeedRow renders two sibling
// instances (the phone and wide compositions differ — age folds in or out),
// so the data-slot is per-instance: forwarded, not fixed.
export function MetaLine({
  segments,
  className,
  "data-slot": dataSlot = "meta-line",
}: {
  segments: readonly string[];
  className?: string;
  "data-slot"?: string;
}) {
  return (
    <p
      data-slot={dataSlot}
      className={cn("truncate font-mono text-[0.6875rem] text-muted-foreground", className)}
    >
      {segments.join(" · ")}
    </p>
  );
}
