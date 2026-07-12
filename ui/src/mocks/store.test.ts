import { expect, test } from "vite-plus/test";
import { WorkflowRunStatus } from "../gql/graphql.ts";
import { makeProject, makeRun, type RunFixture } from "./fixtures.ts";
import { buildScenario, type MockScenario } from "./scenarios.ts";
import { MockStore, type RunTransition, type RunTransitionKind } from "./store.ts";

const S = WorkflowRunStatus;

function scenarioWith(runs: RunFixture[], extra: Partial<MockScenario> = {}): MockScenario {
  return { ...buildScenario("empty"), runs, ...extra };
}

function runWithStatus(status: WorkflowRunStatus): RunFixture {
  const terminal = !(status === S.Pending || status === S.Running || status === S.AwaitingApproval);
  return makeRun(1, {
    status,
    startedAt: status === S.Pending ? null : "2026-07-05T10:00:00.000Z",
    completedAt: terminal ? "2026-07-05T11:00:00.000Z" : null,
  });
}

const FIRST_TICK = "2026-07-10T12:01:00.000Z";
const SECOND_TICK = "2026-07-10T12:02:00.000Z";

// ---------------------------------------------------------------------------
// The status × operation matrix, pinning the single transition table against
// the projection's next_status/2: fail/cancel legal from ALL THREE
// non-terminals, advance only PENDING→RUNNING and RUNNING→terminal, abandon
// only from AWAITING_APPROVAL, everything else a total no-op.
// ---------------------------------------------------------------------------

const ALL_STATUSES = [
  S.Pending,
  S.Running,
  S.AwaitingApproval,
  S.Completed,
  S.Failed,
  S.Cancelled,
  S.Abandoned,
] as const;

type Op = "advanceRun" | "failRun" | "cancelRun" | "abandonRun";
const OPS: readonly Op[] = ["advanceRun", "failRun", "cancelRun", "abandonRun"];

type Outcome = { status: WorkflowRunStatus; kind: RunTransitionKind };

const LEGAL: Record<WorkflowRunStatus, Partial<Record<Op, Outcome>>> = {
  PENDING: {
    advanceRun: { status: S.Running, kind: "run_started" },
    failRun: { status: S.Failed, kind: "run_failed" },
    cancelRun: { status: S.Cancelled, kind: "run_cancelled" },
  },
  RUNNING: {
    advanceRun: { status: S.Completed, kind: "run_completed" },
    failRun: { status: S.Failed, kind: "run_failed" },
    cancelRun: { status: S.Cancelled, kind: "run_cancelled" },
  },
  AWAITING_APPROVAL: {
    failRun: { status: S.Failed, kind: "run_failed" },
    cancelRun: { status: S.Cancelled, kind: "run_cancelled" },
    abandonRun: { status: S.Abandoned, kind: "run_abandoned" },
  },
  COMPLETED: {},
  FAILED: {},
  CANCELLED: {},
  ABANDONED: {},
};

for (const status of ALL_STATUSES) {
  for (const op of OPS) {
    const expected = LEGAL[status][op] ?? null;
    const title = expected
      ? `${op} on ${status} → ${expected.status} [${expected.kind}]`
      : `${op} on ${status} is a total no-op`;
    test(title, () => {
      const run = runWithStatus(status);
      const store = new MockStore(scenarioWith([run]));
      const events: RunTransition[] = [];
      store.onTransition((transition) => events.push(transition));
      const before = store.getRun(run.id)!;

      const changed = store[op](run.id);
      const after = store.getRun(run.id)!;

      if (expected) {
        expect(changed).toBe(true);
        expect(after.status).toBe(expected.status);
        expect(events).toEqual([{ id: run.id, kind: expected.kind }]);
        expect(after.updatedAt).toBe(FIRST_TICK);
        if (expected.kind === "run_started") {
          expect(after.startedAt).toBe(FIRST_TICK);
          expect(after.completedAt).toBeNull();
        } else {
          // Every non-start legal transition in the table is terminal.
          expect(after.completedAt).toBe(FIRST_TICK);
        }
      } else {
        expect(changed).toBe(false);
        expect(after).toEqual(before);
        expect(events).toEqual([]);
      }
    });
  }
}

// All three simTerminal hints pinned, plus the absent-hint default (the
// matrix RUNNING/advanceRun cell above covers absent → run_completed).
const SIM_TERMINALS = [
  { hint: "FAILED", status: S.Failed, kind: "run_failed" },
  { hint: "CANCELLED", status: S.Cancelled, kind: "run_cancelled" },
  { hint: "COMPLETED", status: S.Completed, kind: "run_completed" },
] as const;

for (const { hint, status, kind } of SIM_TERMINALS) {
  test(`advanceRun on RUNNING with simTerminal ${hint} → ${status} [${kind}]`, () => {
    const run = makeRun(1, {
      status: S.Running,
      startedAt: "2026-07-05T10:00:00.000Z",
      completedAt: null,
      simTerminal: hint,
    });
    const store = new MockStore(scenarioWith([run]));
    const events: RunTransition[] = [];
    store.onTransition((transition) => events.push(transition));

    expect(store.advanceRun(run.id)).toBe(true);

    const after = store.getRun(run.id)!;
    expect(after.status).toBe(status);
    expect(after.completedAt).toBe(FIRST_TICK);
    expect(events).toEqual([{ id: run.id, kind }]);
  });
}

test("the logical clock ticks only on successful transitions", () => {
  const run = runWithStatus(S.Pending);
  const store = new MockStore(scenarioWith([run]));

  expect(store.abandonRun(run.id)).toBe(false); // illegal — no tick
  expect(store.advanceRun(run.id)).toBe(true); // tick 1
  expect(store.getRun(run.id)!.updatedAt).toBe(FIRST_TICK);

  expect(store.abandonRun(run.id)).toBe(false); // illegal on RUNNING — no tick
  expect(store.advanceRun(run.id)).toBe(true); // tick 2, not 3
  expect(store.getRun(run.id)!.completedAt).toBe(SECOND_TICK);
});

test("an unknown run id is a total no-op", () => {
  const store = new MockStore(scenarioWith([runWithStatus(S.Pending)]));
  const events: RunTransition[] = [];
  store.onTransition((transition) => events.push(transition));

  expect(store.advanceRun("a1000000-0000-4000-8000-00000000dead")).toBe(false);
  expect(events).toEqual([]);
});

test("onTransition unsubscribe stops delivery", () => {
  const run = runWithStatus(S.Pending);
  const store = new MockStore(scenarioWith([run]));
  const events: RunTransition[] = [];
  const unsubscribe = store.onTransition((transition) => events.push(transition));

  store.advanceRun(run.id);
  unsubscribe();
  store.advanceRun(run.id);

  expect(events).toEqual([{ id: run.id, kind: "run_started" }]);
});

// ---------------------------------------------------------------------------
// Isolation, three angles.
// ---------------------------------------------------------------------------

test("mutating the original scenario after construction does not leak in", () => {
  const project = makeProject(1);
  const run = makeRun(1, {
    status: S.Pending,
    startedAt: null,
    completedAt: null,
    project,
  });
  const scenario = scenarioWith([run]);
  const store = new MockStore(scenario);

  run.name = "mutated";
  run.status = S.Failed;
  project.name = "mutated-project";

  const inside = store.getRun(run.id)!;
  expect(inside.name).toBe("bulk run 1");
  expect(inside.status).toBe(S.Pending);
  expect(inside.project!.name).toBe("bulk-project-001");
});

test("two stores built from the same scenario are independent", () => {
  const run = runWithStatus(S.Pending);
  const scenario = scenarioWith([run]);
  const a = new MockStore(scenario);
  const b = new MockStore(scenario);

  a.advanceRun(run.id);

  expect(a.getRun(run.id)!.status).toBe(S.Running);
  expect(b.getRun(run.id)!.status).toBe(S.Pending);
});

test("mutating rows returned by public reads changes nothing inside", () => {
  const run = makeRun(1, {
    status: S.Pending,
    startedAt: null,
    completedAt: null,
    project: makeProject(1),
  });
  const store = new MockStore(scenarioWith([run]));

  const listed = store.listRecentRuns(50)[0];
  listed.status = S.Completed;
  listed.project!.name = "mutated";
  const fetched = store.getRun(run.id)!;
  fetched.status = S.Cancelled;

  const inside = store.getRun(run.id)!;
  expect(inside.status).toBe(S.Pending);
  expect(inside.project!.name).toBe("bulk-project-001");
  expect(store.hasAdvanceableRuns()).toBe(true);
});

test("hasAdvanceableRuns is false when only parked/terminal rows remain", () => {
  const store = new MockStore(
    scenarioWith([
      makeRun(1, { status: S.AwaitingApproval, completedAt: null }),
      makeRun(2), // COMPLETED
      makeRun(3, { status: S.Failed }),
    ]),
  );

  expect(store.hasAdvanceableRuns()).toBe(false);
  expect(store.oldestAdvanceableRunId()).toBeNull();
});

test("oldestAdvanceableRunId picks the oldest PENDING|RUNNING row", () => {
  const older = makeRun(1, { status: S.Running, completedAt: null });
  const newer = makeRun(2, { status: S.Pending, startedAt: null, completedAt: null });
  const parked = makeRun(3, { status: S.AwaitingApproval, completedAt: null });
  const store = new MockStore(scenarioWith([newer, parked, older]));

  expect(store.oldestAdvanceableRunId()).toBe(older.id);
});
