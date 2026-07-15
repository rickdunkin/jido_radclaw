import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

// The mock's page-title row (20px/700, tight tracking) with a trailing
// slot for page-level meta — the preview marker, "oldest 12m", "4
// standing". The h1 lives here: exactly one per page, nothing sits between
// it and the page's h2 sections.
export function PageHeader({
  title,
  trailing,
  className,
}: {
  title: string;
  trailing?: ReactNode;
  className?: string;
}) {
  return (
    <header className={cn("flex items-center justify-between px-[18px] pb-1 md:px-0", className)}>
      <h1 className="text-xl font-bold tracking-[-0.02em]">{title}</h1>
      {trailing}
    </header>
  );
}
