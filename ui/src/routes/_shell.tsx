import { createFileRoute, Outlet } from "@tanstack/react-router";
import type { CSSProperties } from "react";
import { AppSidebar } from "@/components/app-sidebar";
import { TabBar } from "@/components/tab-bar";
import { SidebarProvider } from "@/components/ui/sidebar";

export const Route = createFileRoute("/_shell")({
  component: ShellLayout,
});

// The navigation frame every routed screen shares. Future detail screens
// (transcript/gate/diff) drop ALL chrome by living outside this pathless
// layout. Below md a fixed phone tab bar navigates; at md+ the fixed 196px
// rail. The tab bar is persistent primary navigation — a sibling of main,
// never page content. Inline safe-area edges are paid once here, for both
// bars; the bars own their block-axis insets.
function ShellLayout() {
  return (
    <SidebarProvider
      style={{ "--sidebar-width": "196px" } as CSSProperties}
      className="pr-[env(safe-area-inset-right)] pl-[env(safe-area-inset-left)]"
    >
      <AppSidebar />
      {/* md keeps the env() bottom inset rather than pb-0: a landscape
          phone wider than 768px hides the tab bar but keeps its home
          indicator. */}
      <main className="min-w-0 flex-1 pt-[env(safe-area-inset-top)] pb-[calc(4.5rem+env(safe-area-inset-bottom))] md:pb-[env(safe-area-inset-bottom)]">
        <Outlet />
      </main>
      <TabBar />
    </SidebarProvider>
  );
}
