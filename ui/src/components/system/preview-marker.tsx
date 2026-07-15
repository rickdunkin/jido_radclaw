import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

// Honest preview marker where the mock shows a live indicator: design-phase
// screens render shipped fixture data (src/lib fixtures SHIP in every build
// — the mock-exclusion guard only covers src/mocks/**), so no green dot, no
// "live". Deliberately separate from PageHeader: the wording is page STATE,
// and slice 1 swaps this for the real indicator per screen.
export function PreviewMarker({
  className,
  children = "preview · sample data",
}: {
  className?: string;
  children?: ReactNode;
}) {
  return (
    <p
      data-slot="preview-marker"
      className={cn("font-mono text-[0.6875rem] font-medium text-muted-foreground", className)}
    >
      {children}
    </p>
  );
}
