import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

// Inline mono references inside prose/titles. tone "ref" is the violet
// thread-name recipe ("export-pipeline wants to run a command"); tone
// "code" is the quieter literal-code treatment FeedRow's resolved rows use
// ("gh pr merge --squash"). className is for caller overrides (a resolved
// card mutes its ref) — the tones own the base recipes.
export function InlineRef({
  tone = "ref",
  className,
  children,
}: {
  tone?: "ref" | "code";
  className?: string;
  children: ReactNode;
}) {
  return (
    <span
      data-slot="inline-ref"
      data-tone={tone}
      className={cn(
        tone === "ref"
          ? "font-mono text-xs text-status-working"
          : "font-mono text-[0.6875rem] font-medium text-foreground/85",
        className,
      )}
    >
      {children}
    </span>
  );
}
