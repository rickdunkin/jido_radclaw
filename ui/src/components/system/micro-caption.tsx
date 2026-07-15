import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

// The page-footnote caption ("Cards stay until you decide, then resolve in
// place…"). Full-strength text-muted-foreground, NOT a /60 alpha: these
// captions convey behavior, so they don't qualify for WCAG's incidental-
// text exception and must clear 4.5:1. Visibility and margins are
// placement, owned by callers.
export function MicroCaption({ className, children }: { className?: string; children: ReactNode }) {
  return (
    <p
      data-slot="micro-caption"
      className={cn("text-[0.6875rem] leading-normal text-muted-foreground", className)}
    >
      {children}
    </p>
  );
}
