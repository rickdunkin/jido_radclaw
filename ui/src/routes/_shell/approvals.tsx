import { createFileRoute } from "@tanstack/react-router";
import { StubPage } from "@/components/stub-page";

export const Route = createFileRoute("/_shell/approvals")({
  component: ApprovalsPage,
});

function ApprovalsPage() {
  return <StubPage title="Approvals" />;
}
