import type { ReactNode } from "react";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

// Thin binding of Badge's `size="feed"` to the two feed-chip tones: the
// amber age chip (waiting) and the ×N cluster-count chip (muted). Geometry
// and typography live in badge.tsx's size axis — className here is for
// PLACEMENT only (visibility twins, alignment), never chip geometry. The
// solid `waiting` Badge variant stays reserved for NavBadge/CTAs.
export function FeedChip({
  tone,
  className,
  children,
}: {
  tone: "muted" | "waiting";
  className?: string;
  children: ReactNode;
}) {
  return (
    <Badge
      variant={tone === "waiting" ? "waiting-subtle" : "muted"}
      size="feed"
      data-slot="feed-chip"
      className={cn("shrink-0 whitespace-nowrap", className)}
    >
      {children}
    </Badge>
  );
}
