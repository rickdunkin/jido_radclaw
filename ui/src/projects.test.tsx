import { MockedProvider } from "@apollo/client/testing/react";
import { render, screen } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { expect, test } from "vite-plus/test";
import { ProjectsDocument } from "./gql/graphql.ts";
import { createAppRouter } from "./router.tsx";

const mocks = [
  {
    request: { query: ProjectsDocument, variables: { limit: 50 } },
    result: {
      data: {
        projects: [
          {
            __typename: "Project" as const,
            id: "3ad47987-ce28-456f-b772-d08eb58f0d8a",
            name: "curl-smoke",
            githubFullName: "curl/smoke-708",
            defaultBranch: "main",
            insertedAt: "2026-07-01T00:00:00Z",
            updatedAt: "2026-07-01T00:00:00Z",
          },
        ],
      },
    },
  },
];

test("renders the projects list through router and mocked Apollo", async () => {
  const router = createAppRouter({
    history: createMemoryHistory({ initialEntries: ["/projects"] }),
  });
  render(
    <MockedProvider mocks={mocks}>
      <RouterProvider router={router} />
    </MockedProvider>,
  );
  expect(await screen.findByText("curl-smoke")).toBeDefined();
  expect(await screen.findByText("curl/smoke-708 · main")).toBeDefined();
  // Containment guard: /projects must render inside the app shell at both
  // breakpoints (the rail is CSS-hidden below md, but always in the DOM).
  expect(document.querySelector('[data-slot="sidebar"]')).not.toBeNull();
});
