import { Link } from "@tanstack/react-router";
import { ApprovalsNavBadge } from "@/components/approvals-nav-badge";
import { NavBadge } from "@/components/system/nav-badge";
import { NodeHealth } from "@/components/node-health";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import { useShellData } from "@/lib/shell-data";
import { RAIL_NAV } from "@/lib/shell-nav";
import { cn } from "@/lib/utils";

// TanStack Link stamps data-status="active" on the anchor; the generated
// button styles key off a separate data-active state we never set, so the
// active treatment must be explicit. The 500→600 weight shift on active is
// mock-exact (a deliberate deviation from the no-weight-shift guideline).
const NAV_ACTIVE_CLASSES =
  "data-[status=active]:bg-sidebar-accent data-[status=active]:font-semibold data-[status=active]:text-sidebar-foreground";

// The mock's compact 12px-mono project-row treatment, shared by the static
// fixture rows and the one real link row so they read as one list.
const PROJECT_ROW_CLASSES = "rounded-lg font-mono text-xs text-sidebar-foreground/70";

// The md+ rail: brand → nav → PROJECTS → node-health footer, fixed at
// 196px (--sidebar-width on the provider), never collapsing. Block-axis
// safe areas live here so the brand clears the status bar and the footer
// clears the home indicator at md widths (landscape phones).
export function AppSidebar() {
  const data = useShellData();

  return (
    <Sidebar
      collapsible="none"
      className="sticky top-0 hidden h-svh flex-none border-r border-sidebar-border px-2.5 pt-[max(0.875rem,env(safe-area-inset-top))] pb-[max(0.875rem,env(safe-area-inset-bottom))] md:flex"
    >
      <SidebarHeader className="p-0">
        {/* A real link home, so the brand row is never a focusable no-op;
            exact matching keeps aria-current honest off the index route. */}
        <Link
          to="/"
          aria-label="Homepage"
          activeOptions={{ exact: true, includeSearch: false }}
          className="flex items-center gap-2 px-2 pt-0.5 pb-3.5"
        >
          <span
            aria-hidden
            className="flex size-4 shrink-0 items-center justify-center rounded-full border-[1.5px] border-primary bg-primary/15"
          >
            <span className="size-[5px] rounded-full bg-primary" />
          </span>
          <span className="font-mono text-[13.5px] font-semibold tracking-[-0.02em]">argus</span>
        </Link>
      </SidebarHeader>
      <SidebarContent>
        <nav aria-label="Main">
          {/* p-0 on groups + h-auto labels: the registry's stacked p-2
              paddings would double the mock's 10px outer + 8px row inset.
              The rail's own px-2.5 is the single horizontal inset. */}
          <SidebarGroup className="p-0">
            <SidebarGroupContent>
              <SidebarMenu role="list">
                {RAIL_NAV.map((entry) => (
                  <SidebarMenuItem key={entry.id}>
                    <SidebarMenuButton
                      size="sm"
                      className={cn("font-medium text-sidebar-foreground/70", NAV_ACTIVE_CLASSES)}
                      render={<Link {...entry.link} />}
                    >
                      {entry.label}
                      {entry.badge === "attention" && (
                        <NavBadge count={data.attentionCount} className="ml-auto" />
                      )}
                      {entry.badge === "approvals" && <ApprovalsNavBadge className="ml-auto" />}
                      {entry.id === "runs" && (
                        <>
                          <span
                            aria-hidden
                            className="ml-auto font-mono text-[9px] font-semibold text-status-waiting"
                          >
                            {data.runsAtGates} ◆
                          </span>
                          <span className="sr-only">
                            {data.runsAtGates} {data.runsAtGates === 1 ? "run" : "runs"} at gates
                          </span>
                        </>
                      )}
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        </nav>
        <SidebarGroup className="p-0">
          {/* The mock's 16px/6px header rhythm lives on the label itself —
              group-level bottom padding would land after the rows. */}
          <SidebarGroupLabel className="h-auto px-2 pt-4 pb-1.5 text-[9.5px] font-bold tracking-[0.1em] text-muted-foreground">
            PROJECTS
            <span
              aria-hidden
              className="ml-auto flex size-4 items-center justify-center rounded-[5px] bg-sidebar-accent font-mono text-[11px] font-medium text-muted-foreground"
            >
              +
            </span>
          </SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu role="list">
              {/* Fixture rows are honest static text — four rows all
                  pointing at the same list would mislead; "All projects"
                  below is the real desktop path to /projects. */}
              {data.projects.map((name) => (
                <li
                  key={name}
                  className={cn("flex h-7 items-center px-2 py-[5px]", PROJECT_ROW_CLASSES)}
                >
                  {name}
                </li>
              ))}
              <SidebarMenuItem>
                <SidebarMenuButton
                  size="sm"
                  className={cn(PROJECT_ROW_CLASSES, NAV_ACTIVE_CLASSES)}
                  render={<Link to="/projects" activeOptions={{ includeSearch: false }} />}
                >
                  All projects
                </SidebarMenuButton>
              </SidebarMenuItem>
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>
      <SidebarFooter className="mt-auto border-t border-sidebar-border px-2 py-2.5">
        <NodeHealth nodes={data.nodes} />
      </SidebarFooter>
    </Sidebar>
  );
}
