import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

// The feed's section label ("NEEDS YOU · 3" / "EARLIER"): always a heading —
// h2 for now — so every feed section is heading-navigable. `id` exists to be
// wired into a labelled <section> via aria-labelledby (see GroupPanel).
export function SectionLabel({
  tone = "muted",
  id,
  as: Tag = "h2",
  className,
  children,
}: {
  tone?: "waiting" | "muted";
  id?: string;
  as?: "h2";
  className?: string;
  children: ReactNode;
}) {
  return (
    <Tag
      id={id}
      data-slot="section-label"
      className={cn(
        "text-[0.65625rem] font-bold tracking-[0.08em]",
        tone === "waiting" ? "text-status-waiting" : "text-muted-foreground/75",
        className,
      )}
    >
      {children}
    </Tag>
  );
}
