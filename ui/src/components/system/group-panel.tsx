import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

// A header makes the panel a labelled <section>; the header's heading must
// carry id={labelId}. Headerless panels stay a <div> — an anonymous
// <section> maps to role "generic" and defeats landmark/heading navigation.
// (The priority view's EARLIER panel is the headerless case: the view owns
// its own labelled section around the page-level label + this panel.)
type GroupPanelProps = {
  tone: "amber" | "neutral";
  className?: string;
  children: ReactNode;
} & ({ header: ReactNode; labelId: string } | { header?: undefined; labelId?: undefined });

// The feed's two panel surfaces (mock 2a/5a/5e; light borders/shadows from
// 4c): amber is the needs-you recipe — waiting hue at /7 bg with a /35
// border in light, /20 in dark; neutral is the soft card panel, elevated
// only in light (dark resets the shadow).
export function GroupPanel({ tone, header, labelId, className, children }: GroupPanelProps) {
  const Tag = header !== undefined ? "section" : "div";
  return (
    <Tag
      data-slot="group-panel"
      data-tone={tone}
      aria-labelledby={header !== undefined ? labelId : undefined}
      className={cn(
        "rounded-xl p-1",
        tone === "amber"
          ? "border border-status-waiting/35 bg-status-waiting/7 dark:border-status-waiting/20"
          : "bg-card shadow-xs dark:shadow-none",
        className,
      )}
    >
      {header}
      {children}
    </Tag>
  );
}
