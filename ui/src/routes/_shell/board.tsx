import { createFileRoute } from "@tanstack/react-router";
import { StubPage } from "@/components/stub-page";

export const Route = createFileRoute("/_shell/board")({
  component: BoardPage,
});

function BoardPage() {
  return <StubPage title="Board" />;
}
