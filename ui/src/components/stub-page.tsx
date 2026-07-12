import type { ReactNode } from "react";

// Placeholder screen for routes whose real designs land in a later slice:
// the mock's page-title pattern (20px/700, tight tracking) over a muted
// panel, with an optional slot for temporary page content.
export function StubPage({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="mx-auto max-w-2xl px-6 py-12">
      <h1 className="text-xl font-bold tracking-tight">{title}</h1>
      <div className="mt-6 rounded-xl border border-border bg-card px-4 py-8 text-center text-sm text-muted-foreground">
        This screen is designed in a later slice.
      </div>
      {children}
    </div>
  );
}
