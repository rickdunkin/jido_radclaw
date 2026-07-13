import { cn } from "@/lib/utils";

// Inert affordance hint — never focusable, never announced. The data-slot
// keeps its feed-era name: it is test-pinned, and the chevron's job (an
// "opens somewhere" hint on a feed-shaped row) is unchanged by the move.
export function Chevron({ className }: { className?: string }) {
  return (
    <span
      aria-hidden="true"
      data-slot="feed-chevron"
      className={cn("shrink-0 self-center text-[0.9375rem]", className)}
    >
      ›
    </span>
  );
}
