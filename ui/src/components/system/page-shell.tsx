import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

// The page root every argus screen shares (extracted from the Attention
// page at its second real site, Approvals 2b): centered column, chrome-
// aligned gutters at viewport md, and the named container `@container/feed`
// that FeedRow/caption twins flip on — the shell declares it so any page
// content composes container-aware pieces without re-declaring.
export function PageShell({ className, children }: { className?: string; children: ReactNode }) {
  return (
    <div
      data-slot="page-shell"
      className={cn("@container/feed mx-auto w-full max-w-6xl pt-[18px] pb-6 md:px-5", className)}
    >
      {children}
    </div>
  );
}
