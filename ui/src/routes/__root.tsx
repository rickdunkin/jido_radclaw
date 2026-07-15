import { createRootRoute, Outlet } from "@tanstack/react-router";
import { ApprovalsLocalStateProvider } from "@/lib/approvals-local-state-provider";

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  // A div, not main: the shell layout owns the main landmark. isolate roots
  // a stacking context for the fixed tab bar and future portalled overlays.
  // The approvals local-state provider mounts HERE on purpose: the root
  // never unmounts in-session (decisions survive every navigation, reset on
  // reload), and each router render creates a fresh store, so tests isolate
  // with no reset hook. Both nav bars and the approvals route consume it.
  return (
    <div className="isolate min-h-svh bg-background text-foreground antialiased">
      <ApprovalsLocalStateProvider>
        <Outlet />
      </ApprovalsLocalStateProvider>
    </div>
  );
}
