import { ApolloClient, gql, InMemoryCache } from "@apollo/client";
import { CombinedGraphQLErrors } from "@apollo/client/errors";
import type { TypedDocumentNode } from "@graphql-typed-document-node/core";
import { expect, test } from "vite-plus/test";
import { ProjectsDocument, RecentWorkflowRunsDocument } from "../gql/graphql.ts";
import { DEFAULT_PROJECT_IDS, DEFAULT_RUN_IDS, makeProject, makeRun } from "./fixtures.ts";
import { createMockLink } from "./link.ts";
import { buildScenario } from "./scenarios.ts";
import { MockStore } from "./store.ts";

// Real ApolloClient over the mock SchemaLink — no MockedProvider. The
// documents execute against the committed SDL golden, so schema drift is a
// loud failure here, not a silent fixture divergence.

function clientFor(store: MockStore, cache: InMemoryCache = new InMemoryCache()): ApolloClient {
  return new ApolloClient({ link: createMockLink(store), cache });
}

async function rejectionOf(promise: Promise<unknown>): Promise<unknown> {
  return await promise.then(
    () => {
      throw new Error("expected the query to reject");
    },
    (error: unknown) => error,
  );
}

// errorPolicy "none" (the default) rejects on any error, so a fulfilled
// query always carries data — Apollo's types just can't see that.
function dataOf<TData>(result: { data?: TData }): TData {
  if (result.data === undefined) throw new Error("expected query data");
  return result.data;
}

interface WorkflowRunByIdData {
  workflowRun: {
    id: string;
    name: string;
    status: string;
    disposition: string | null;
    findingsDeferredCount: number | null;
    project: { id: string; name: string } | null;
  } | null;
}

const WorkflowRunByIdDocument: TypedDocumentNode<WorkflowRunByIdData, { id: string }> = gql`
  query WorkflowRunById($id: ID!) {
    workflowRun(id: $id) {
      id
      name
      status
      disposition
      findingsDeferredCount
      project {
        id
        name
      }
    }
  }
`;

interface ProjectByIdData {
  project: { id: string; name: string; githubFullName: string } | null;
}

const ProjectByIdDocument: TypedDocumentNode<ProjectByIdData, { id: string }> = gql`
  query ProjectById($id: ID!) {
    project(id: $id) {
      id
      name
      githubFullName
    }
  }
`;

test("recent runs order: insertedAt desc with id-desc tie-breaker", async () => {
  const client = clientFor(new MockStore(buildScenario("default")));

  const data = dataOf(
    await client.query({ query: RecentWorkflowRunsDocument, variables: { limit: 50 } }),
  );

  // failed and plainCompleted share insertedAt — the higher id wins.
  expect(data.recentWorkflowRuns.map((run) => run.id)).toEqual([
    DEFAULT_RUN_IDS.pending,
    DEFAULT_RUN_IDS.running,
    DEFAULT_RUN_IDS.awaitingApproval,
    DEFAULT_RUN_IDS.amberCompleted,
    DEFAULT_RUN_IDS.failed,
    DEFAULT_RUN_IDS.plainCompleted,
    DEFAULT_RUN_IDS.cancelled,
    DEFAULT_RUN_IDS.abandoned,
  ]);
  const statuses = data.recentWorkflowRuns.map((run) => run.status);
  expect(new Set(statuses).size).toBe(7);

  // disposition/findingsDeferredCount flow typed through the generated
  // document — amber where the fixture says so, honest nulls elsewhere.
  const amber = data.recentWorkflowRuns.find((run) => run.id === DEFAULT_RUN_IDS.amberCompleted);
  expect(amber?.disposition).toBe("done_with_findings");
  expect(amber?.findingsDeferredCount).toBe(3);
  const plain = data.recentWorkflowRuns.find((run) => run.id === DEFAULT_RUN_IDS.plainCompleted);
  expect(plain?.disposition).toBeNull();
  expect(plain?.findingsDeferredCount).toBeNull();
});

test("projects order: name asc with id-asc tie-breaker", async () => {
  const client = clientFor(new MockStore(buildScenario("default")));

  const data = dataOf(await client.query({ query: ProjectsDocument, variables: { limit: 50 } }));

  expect(data.projects.map((project) => project.id)).toEqual([
    DEFAULT_PROJECT_IDS.argus,
    DEFAULT_PROJECT_IDS.hermesA,
    DEFAULT_PROJECT_IDS.hermesB,
  ]);
});

test("limit: 2 is respected on both reads", async () => {
  const client = clientFor(new MockStore(buildScenario("default")));

  const runs = dataOf(
    await client.query({ query: RecentWorkflowRunsDocument, variables: { limit: 2 } }),
  );
  const projects = dataOf(await client.query({ query: ProjectsDocument, variables: { limit: 2 } }));

  expect(runs.recentWorkflowRuns.map((run) => run.id)).toEqual([
    DEFAULT_RUN_IDS.pending,
    DEFAULT_RUN_IDS.running,
  ]);
  expect(projects.projects.map((project) => project.id)).toEqual([
    DEFAULT_PROJECT_IDS.argus,
    DEFAULT_PROJECT_IDS.hermesA,
  ]);
});

test("omitted limit returns exactly 50 rows from a 60-row store", async () => {
  const store = new MockStore({
    ...buildScenario("empty"),
    runs: Array.from({ length: 60 }, (_, i) => makeRun(i + 1)),
    projects: Array.from({ length: 60 }, (_, i) => makeProject(i + 1)),
  });
  const client = clientFor(store);

  const runs = dataOf(await client.query({ query: RecentWorkflowRunsDocument }));
  const projects = dataOf(await client.query({ query: ProjectsDocument }));

  // An accidentally unbounded implementation must fail this.
  expect(runs.recentWorkflowRuns).toHaveLength(50);
  expect(runs.recentWorkflowRuns[0].id).toBe(makeRun(60).id);
  expect(projects.projects).toHaveLength(50);
});

for (const limit of [0, 500, null]) {
  test(`limit: ${limit} is an honest validation error, never a silent clamp`, async () => {
    const client = clientFor(new MockStore(buildScenario("default")));

    const error = await rejectionOf(
      client.query({ query: RecentWorkflowRunsDocument, variables: { limit } }),
    );

    expect(CombinedGraphQLErrors.is(error)).toBe(true);
    expect((error as Error).message).toContain("limit");
  });
}

test("workflowRun(id): known id resolves with nested project, unknown is null", async () => {
  const client = clientFor(new MockStore(buildScenario("default")));

  const known = dataOf(
    await client.query({
      query: WorkflowRunByIdDocument,
      variables: { id: DEFAULT_RUN_IDS.amberCompleted },
    }),
  );
  const run = known.workflowRun;
  expect(run?.name).toContain("sweep stale sessions");
  expect(run?.status).toBe("COMPLETED");
  expect(run?.disposition).toBe("done_with_findings");
  expect(run?.findingsDeferredCount).toBe(3);
  expect(run?.project?.name).toBe("argus");

  const unknown = dataOf(
    await client.query({
      query: WorkflowRunByIdDocument,
      variables: { id: "a1000000-0000-4000-8000-00000000dead" },
    }),
  );
  expect(unknown.workflowRun).toBeNull();
});

test("project(id): known id resolves, unknown is null", async () => {
  const client = clientFor(new MockStore(buildScenario("default")));

  const known = dataOf(
    await client.query({
      query: ProjectByIdDocument,
      variables: { id: DEFAULT_PROJECT_IDS.hermesB },
    }),
  );
  expect(known.project?.name).toBe("hermes");
  expect(known.project?.githubFullName).toBe("jidoclaw/hermes-fork");

  const unknown = dataOf(
    await client.query({
      query: ProjectByIdDocument,
      variables: { id: "b1000000-0000-4000-8000-00000000dead" },
    }),
  );
  expect(unknown.project).toBeNull();
});

test("results normalize into the cache under WorkflowRun:<id> keys", async () => {
  const cache = new InMemoryCache();
  const client = clientFor(new MockStore(buildScenario("default")), cache);

  await client.query({ query: RecentWorkflowRunsDocument, variables: { limit: 50 } });

  const keys = Object.keys(cache.extract());
  expect(keys).toContain(`WorkflowRun:${DEFAULT_RUN_IDS.pending}`);
  expect(keys).toContain(`WorkflowRun:${DEFAULT_RUN_IDS.abandoned}`);
});

test("scenario error-gql rejects through the GraphQL errors channel", async () => {
  const client = clientFor(new MockStore(buildScenario("error-gql")));

  const error = await rejectionOf(
    client.query({ query: RecentWorkflowRunsDocument, variables: { limit: 50 } }),
  );

  expect(CombinedGraphQLErrors.is(error)).toBe(true);
  expect((error as Error).message).toContain("scenario-forced");
});

test("scenario error-network rejects through the link channel with the original Error", async () => {
  const client = clientFor(new MockStore(buildScenario("error-network")));

  const error = await rejectionOf(
    client.query({ query: RecentWorkflowRunsDocument, variables: { limit: 50 } }),
  );

  expect(CombinedGraphQLErrors.is(error)).toBe(false);
  expect(error).toBeInstanceOf(Error);
  expect((error as Error).message).toContain("gateway unreachable");
});

test("a document selecting a nonexistent field fails validation (validate: true)", async () => {
  const client = clientFor(new MockStore(buildScenario("default")));
  const badDocument = gql`
    query Bad {
      recentWorkflowRuns {
        id
        nope
      }
    }
  `;

  const error = await rejectionOf(client.query({ query: badDocument }));

  expect(CombinedGraphQLErrors.is(error)).toBe(true);
  expect((error as Error).message).toContain("nope");
});
