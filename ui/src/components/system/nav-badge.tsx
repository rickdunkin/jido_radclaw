import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

// The amber count pill both nav bars share: the waiting Badge variant plus
// the mock geometry. h-auto beats the Badge base's h-5 (the mock pill is
// ~13px: 9px line + 2px padding + the base's kept 1px transparent border);
// tabular-nums keeps changing counts from wiggling. Renders inline inside
// its link so the count joins the accessible name — callers own ALL
// placement via className (rail ml-auto, phone absolute), none is baked.
export function NavBadge({ count, className }: { count: number; className?: string }) {
  return (
    <Badge
      variant="waiting"
      className={cn(
        "h-auto rounded-full px-[5px] py-px font-mono text-[9px] leading-none font-bold tabular-nums",
        className,
      )}
    >
      {count}
    </Badge>
  );
}
