import { Link } from "@tanstack/react-router";
import { NavBadge } from "@/components/nav-badge";
import { useShellData } from "@/lib/shell-data";
import { PHONE_TABS } from "@/lib/shell-nav";

// Mock-exact 19×19 inline glyphs (stroke 1.6, currentColor) — the tab bar
// is the one surface the mock draws its own icons for, so lucide stays
// out. Decorative throughout: the label span names the tab.
function TabGlyph({ id }: { id: string }) {
  switch (id) {
    case "attention":
      return (
        <svg width="19" height="19" viewBox="0 0 19 19" aria-hidden="true">
          <circle cx="9.5" cy="9.5" r="7" fill="none" stroke="currentColor" strokeWidth="1.6" />
          <circle cx="9.5" cy="9.5" r="2.6" fill="currentColor" />
        </svg>
      );
    case "approvals":
      return (
        <svg width="19" height="19" viewBox="0 0 19 19" aria-hidden="true">
          <rect
            x="2.5"
            y="2.5"
            width="14"
            height="14"
            rx="4"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.6"
          />
          <path
            d="M6 9.5l2.4 2.4 4.6-4.8"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinecap="round"
          />
        </svg>
      );
    case "threads":
      return (
        <svg width="19" height="19" viewBox="0 0 19 19" aria-hidden="true">
          <path
            d="M3 5h13M3 9.5h13M3 14h8"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinecap="round"
          />
        </svg>
      );
    case "projects":
      return (
        <svg width="19" height="19" viewBox="0 0 19 19" aria-hidden="true">
          <rect x="3" y="3" width="5.5" height="5.5" rx="1.5" fill="currentColor" />
          <rect
            x="10.5"
            y="3"
            width="5.5"
            height="5.5"
            rx="1.5"
            fill="currentColor"
            opacity="0.5"
          />
          <rect
            x="3"
            y="10.5"
            width="5.5"
            height="5.5"
            rx="1.5"
            fill="currentColor"
            opacity="0.5"
          />
          <rect
            x="10.5"
            y="10.5"
            width="5.5"
            height="5.5"
            rx="1.5"
            fill="currentColor"
            opacity="0.5"
          />
        </svg>
      );
    default:
      return null;
  }
}

// The below-md primary navigation: a fixed bottom bar with the amber count
// pills nearest the thumb. A sibling of the shell's <main>, never inside
// it — it is persistent chrome, not page content.
export function TabBar() {
  const data = useShellData();

  return (
    <nav
      aria-label="Primary"
      className="fixed inset-x-0 bottom-0 z-20 flex border-t border-sidebar-border bg-sidebar pt-2 pr-[max(0.5rem,env(safe-area-inset-right))] pb-[max(0.875rem,env(safe-area-inset-bottom))] pl-[max(0.5rem,env(safe-area-inset-left))] md:hidden"
    >
      {PHONE_TABS.map((tab) => (
        <Link
          key={tab.id}
          {...tab.link}
          className="group relative flex flex-1 flex-col items-center gap-1 py-1.5 font-medium text-muted-foreground"
        >
          <span aria-hidden className="shrink-0 group-data-[status=active]:text-primary">
            <TabGlyph id={tab.id} />
          </span>
          <span className="text-[10px] group-data-[status=active]:font-semibold group-data-[status=active]:text-foreground">
            {tab.label}
          </span>
          {tab.badge && (
            <NavBadge
              count={tab.badge === "attention" ? data.attentionCount : data.approvalsCount}
              className="absolute top-px right-[calc(50%-22px)] ml-0 py-[1.5px]"
            />
          )}
        </Link>
      ))}
    </nav>
  );
}
