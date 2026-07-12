import { createRootRoute, Outlet } from "@tanstack/react-router";

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-100">
      <Outlet />
    </main>
  );
}
