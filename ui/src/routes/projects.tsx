import { useQuery } from "@apollo/client/react";
import { createFileRoute } from "@tanstack/react-router";
import { ProjectsDocument } from "../gql/graphql.ts";

export const Route = createFileRoute("/projects")({
  component: ProjectsPage,
});

function ProjectsPage() {
  const { data, loading, error } = useQuery(ProjectsDocument, {
    variables: { limit: 50 },
  });

  return (
    <div className="mx-auto max-w-2xl px-6 py-12">
      <h1 className="text-2xl font-semibold tracking-tight">Projects</h1>
      {loading && <p className="mt-4 text-sm text-zinc-400">Loading projects…</p>}
      {error && (
        <p className="mt-4 text-sm text-red-400">Failed to load projects: {error.message}</p>
      )}
      {data && data.projects.length === 0 && (
        <p className="mt-4 text-sm text-zinc-400">No projects yet.</p>
      )}
      {data && data.projects.length > 0 && (
        <ul className="mt-6 divide-y divide-zinc-800">
          {data.projects.map((project) => (
            <li key={project.id} className="py-3">
              <div className="font-medium">{project.name}</div>
              <div className="text-sm text-zinc-400">
                {project.githubFullName} · {project.defaultBranch}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
