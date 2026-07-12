import { createFileRoute } from "@tanstack/react-router";
import { StubPage } from "@/components/stub-page";

export const Route = createFileRoute("/_shell/threads")({
  component: ThreadsPage,
});

function ThreadsPage() {
  return <StubPage title="Threads" />;
}
