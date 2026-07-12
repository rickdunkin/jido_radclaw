import { createRootRoute, Outlet } from "@tanstack/react-router";

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  // A div, not main: the shell layout owns the main landmark. isolate roots
  // a stacking context for the fixed tab bar and future portalled overlays.
  return (
    <div className="isolate min-h-svh bg-background text-foreground antialiased">
      <Outlet />
    </div>
  );
}
