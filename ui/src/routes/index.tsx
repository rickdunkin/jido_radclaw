import { createFileRoute, Link } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  component: Index,
});

function Index() {
  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="text-center">
        <h1 className="text-4xl font-semibold tracking-tight">argus</h1>
        <div className="mt-4 flex justify-center gap-4">
          <Link
            to="/projects"
            className="inline-block text-sm text-zinc-400 underline-offset-4 hover:text-zinc-100 hover:underline"
          >
            View projects
          </Link>
          <Link
            to="/runs"
            className="inline-block text-sm text-zinc-400 underline-offset-4 hover:text-zinc-100 hover:underline"
          >
            View runs
          </Link>
        </div>
      </div>
    </div>
  );
}
