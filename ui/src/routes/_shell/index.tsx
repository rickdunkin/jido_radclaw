import { createFileRoute, Link } from "@tanstack/react-router";
import { StubPage } from "@/components/stub-page";

export const Route = createFileRoute("/_shell/")({
  component: AttentionPage,
});

// Temporary links list, removed when the real pages land: /runs and /board
// have no phone tab by design, and /styleguide is deliberately out of nav —
// this stub is their reachable home meanwhile.
const TEMP_LINKS = [
  { label: "View runs", to: "/runs" },
  { label: "View projects", to: "/projects" },
  { label: "View board", to: "/board" },
  { label: "Styleguide", to: "/styleguide" },
] as const;

function AttentionPage() {
  return (
    <StubPage title="Attention">
      <ul role="list" className="mt-4 flex flex-wrap gap-4">
        {TEMP_LINKS.map((entry) => (
          <li key={entry.to}>
            <Link
              to={entry.to}
              className="text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
            >
              {entry.label}
            </Link>
          </li>
        ))}
      </ul>
    </StubPage>
  );
}
