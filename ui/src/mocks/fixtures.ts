import { WorkflowRunStatus } from "../gql/graphql.ts";

// Deterministic fixture builders + the default dataset. Everything here is
// side-effect-free at module top level (the prod bundle must tree-shake the
// whole mocks graph away), and nothing reads Date.now()/Math.random() — ids
// and timestamps are hand-written or index-derived.

// Embedded in one fixture name; two checks key on this literal and expect
// zero hits in real build output: the argus-mock-exclusion-guard plugin in
// ui/vite.config.ts (its secondary marker scan — the config duplicates this
// literal because it must load pre-codegen and cannot import this module;
// keep the copies in sync) and the manual verification grep over
// priv/static/argus/.
export const MOCK_MARKER = "argus-mock-fixture-7f3c";

export interface ProjectFixture {
  id: string;
  name: string;
  githubFullName: string;
  defaultBranch: string;
  insertedAt: string;
  updatedAt: string;
}

export interface RunFixture {
  id: string;
  name: string;
  workflowType: string | null;
  status: WorkflowRunStatus;
  startedAt: string | null;
  completedAt: string | null;
  insertedAt: string;
  updatedAt: string;
  project: ProjectFixture | null;
  disposition: string | null;
  findingsDeferredCount: number | null;
  // Non-schema simulation hint: which terminal an advanceRun on RUNNING
  // reaches. Harmless under graphql-js default resolvers — no document can
  // select it (validation would reject the field).
  simTerminal?: "COMPLETED" | "FAILED" | "CANCELLED";
}

const BUILDER_BASE = "2026-07-01T00:00:00Z";

function builderIso(index: number): string {
  return new Date(Date.parse(BUILDER_BASE) + index * 60_000).toISOString();
}

function builderUuid(block: string, index: number): string {
  return `${block}-0000-4000-8000-${String(index).padStart(12, "0")}`;
}

// Index-derived rows for deterministic bulk seeding (the link tests build
// 60-row stores from these). Higher index ⇒ later insertedAt.
export function makeRun(index: number, overrides: Partial<RunFixture> = {}): RunFixture {
  const stamp = builderIso(index);
  return {
    id: builderUuid("aaaa0000", index),
    name: `bulk run ${index}`,
    workflowType: "code",
    status: WorkflowRunStatus.Completed,
    startedAt: stamp,
    completedAt: stamp,
    insertedAt: stamp,
    updatedAt: stamp,
    project: null,
    disposition: null,
    findingsDeferredCount: null,
    ...overrides,
  };
}

export function makeProject(
  index: number,
  overrides: Partial<ProjectFixture> = {},
): ProjectFixture {
  const stamp = builderIso(index);
  return {
    id: builderUuid("bbbb0000", index),
    name: `bulk-project-${String(index).padStart(3, "0")}`,
    githubFullName: `argus/bulk-${index}`,
    defaultBranch: "main",
    insertedAt: stamp,
    updatedAt: stamp,
    ...overrides,
  };
}

// Stable ids for the hand-written default dataset, exported so tests and the
// dev console can address specific rows without spelunking the arrays.
export const DEFAULT_RUN_IDS = {
  pending: "a1000000-0000-4000-8000-000000000001",
  running: "a1000000-0000-4000-8000-000000000002",
  awaitingApproval: "a1000000-0000-4000-8000-000000000003",
  amberCompleted: "a1000000-0000-4000-8000-000000000004",
  plainCompleted: "a1000000-0000-4000-8000-000000000005",
  failed: "a1000000-0000-4000-8000-000000000006",
  cancelled: "a1000000-0000-4000-8000-000000000007",
  abandoned: "a1000000-0000-4000-8000-000000000008",
} as const;

export const DEFAULT_PROJECT_IDS = {
  argus: "b1000000-0000-4000-8000-000000000001",
  hermesA: "b1000000-0000-4000-8000-000000000002",
  hermesB: "b1000000-0000-4000-8000-000000000003",
} as const;

// Two projects share a name deliberately: the alphabetical read's id-asc
// tie-breaker needs real rows to bite on.
export function defaultProjects(): ProjectFixture[] {
  return [
    {
      id: DEFAULT_PROJECT_IDS.argus,
      name: "argus",
      githubFullName: "jidoclaw/argus",
      defaultBranch: "main",
      insertedAt: "2026-07-08T09:00:00Z",
      updatedAt: "2026-07-08T09:00:00Z",
    },
    {
      id: DEFAULT_PROJECT_IDS.hermesA,
      name: "hermes",
      githubFullName: "jidoclaw/hermes",
      defaultBranch: "main",
      insertedAt: "2026-07-08T10:00:00Z",
      updatedAt: "2026-07-08T10:00:00Z",
    },
    {
      id: DEFAULT_PROJECT_IDS.hermesB,
      name: "hermes",
      githubFullName: "jidoclaw/hermes-fork",
      defaultBranch: "trunk",
      insertedAt: "2026-07-08T11:00:00Z",
      updatedAt: "2026-07-08T11:00:00Z",
    },
  ];
}

// Coverage: all seven statuses; amber COMPLETED (done_with_findings) beside a
// plain one; null workflowType; PENDING with null startedAt/completedAt;
// project embedded on some rows and null on others; one AWAITING_APPROVAL row
// the simulator parks on; two runs sharing insertedAt (recent read's id-desc
// tie-breaker).
export function defaultRuns(): RunFixture[] {
  const projects = defaultProjects();
  const argus = projects[0];
  const hermesA = projects[1];
  const hermesB = projects[2];
  return [
    {
      id: DEFAULT_RUN_IDS.pending,
      name: "triage flaky partition",
      workflowType: "code",
      status: WorkflowRunStatus.Pending,
      startedAt: null,
      completedAt: null,
      insertedAt: "2026-07-10T09:00:00Z",
      updatedAt: "2026-07-10T09:00:00Z",
      project: argus,
      disposition: null,
      findingsDeferredCount: null,
      simTerminal: "FAILED",
    },
    {
      id: DEFAULT_RUN_IDS.running,
      name: "port evidence floor",
      workflowType: "code",
      status: WorkflowRunStatus.Running,
      startedAt: "2026-07-10T08:31:00Z",
      completedAt: null,
      insertedAt: "2026-07-10T08:30:00Z",
      updatedAt: "2026-07-10T08:31:00Z",
      project: null,
      disposition: null,
      findingsDeferredCount: null,
    },
    {
      id: DEFAULT_RUN_IDS.awaitingApproval,
      name: "rotate gateway keys",
      workflowType: "system",
      status: WorkflowRunStatus.AwaitingApproval,
      startedAt: "2026-07-10T08:01:00Z",
      completedAt: null,
      insertedAt: "2026-07-10T08:00:00Z",
      updatedAt: "2026-07-10T08:05:00Z",
      project: hermesA,
      disposition: null,
      findingsDeferredCount: null,
    },
    {
      id: DEFAULT_RUN_IDS.amberCompleted,
      name: `sweep stale sessions ${MOCK_MARKER}`,
      workflowType: "code",
      status: WorkflowRunStatus.Completed,
      startedAt: "2026-07-10T07:01:00Z",
      completedAt: "2026-07-10T07:20:00Z",
      insertedAt: "2026-07-10T07:00:00Z",
      updatedAt: "2026-07-10T07:20:00Z",
      project: argus,
      disposition: "done_with_findings",
      findingsDeferredCount: 3,
    },
    {
      id: DEFAULT_RUN_IDS.plainCompleted,
      name: "regenerate sdl golden",
      workflowType: null,
      status: WorkflowRunStatus.Completed,
      startedAt: "2026-07-10T06:01:00Z",
      completedAt: "2026-07-10T06:12:00Z",
      insertedAt: "2026-07-10T06:00:00Z",
      updatedAt: "2026-07-10T06:12:00Z",
      project: null,
      disposition: null,
      findingsDeferredCount: null,
    },
    {
      id: DEFAULT_RUN_IDS.failed,
      name: "harden verify authority",
      workflowType: "code",
      status: WorkflowRunStatus.Failed,
      // insertedAt ties with plainCompleted above: id desc must order this
      // row first in the recent read.
      startedAt: "2026-07-10T06:02:00Z",
      completedAt: "2026-07-10T06:30:00Z",
      insertedAt: "2026-07-10T06:00:00Z",
      updatedAt: "2026-07-10T06:30:00Z",
      project: hermesB,
      disposition: null,
      findingsDeferredCount: null,
    },
    {
      id: DEFAULT_RUN_IDS.cancelled,
      name: "compact session transcripts",
      workflowType: "system",
      status: WorkflowRunStatus.Cancelled,
      startedAt: "2026-07-09T18:05:00Z",
      completedAt: "2026-07-09T18:40:00Z",
      insertedAt: "2026-07-09T18:00:00Z",
      updatedAt: "2026-07-09T18:40:00Z",
      project: null,
      disposition: null,
      findingsDeferredCount: null,
    },
    {
      id: DEFAULT_RUN_IDS.abandoned,
      name: "review consolidator ledger",
      workflowType: "code",
      status: WorkflowRunStatus.Abandoned,
      startedAt: "2026-07-09T17:10:00Z",
      completedAt: "2026-07-09T17:55:00Z",
      insertedAt: "2026-07-09T17:00:00Z",
      updatedAt: "2026-07-09T17:55:00Z",
      project: hermesA,
      disposition: null,
      findingsDeferredCount: null,
    },
  ];
}
