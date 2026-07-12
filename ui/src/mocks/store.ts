import { WorkflowRunStatus } from "../gql/graphql.ts";
import type { ProjectFixture, RunFixture } from "./fixtures.ts";
import { resolveScenario, type MockScenario } from "./scenarios.ts";

// The five lifecycle wire kinds (RunPubSub.lifecycle_kinds/0). There is
// deliberately NO kind for entering/leaving AWAITING_APPROVAL — approval
// resolution emits no run_event server-side, so the mock never invents one.
export type RunTransitionKind =
  | "run_started"
  | "run_completed"
  | "run_failed"
  | "run_cancelled"
  | "run_abandoned";

export interface RunTransition {
  id: string;
  kind: RunTransitionKind;
}

type TransitionListener = (transition: RunTransition) => void;
type MutatorOp = "advance" | "fail" | "cancel" | "abandon";

// Logical clock: base + 60s per successful transition. Deterministic — the
// store never reads the wall clock.
const CLOCK_BASE = "2026-07-10T12:00:00Z";
const CLOCK_STEP_MS = 60_000;

function nonTerminal(status: WorkflowRunStatus): boolean {
  return (
    status === WorkflowRunStatus.Pending ||
    status === WorkflowRunStatus.Running ||
    status === WorkflowRunStatus.AwaitingApproval
  );
}

function advanceable(status: WorkflowRunStatus): boolean {
  return status === WorkflowRunStatus.Pending || status === WorkflowRunStatus.Running;
}

function terminalKind(status: "COMPLETED" | "FAILED" | "CANCELLED"): RunTransitionKind {
  if (status === "FAILED") return "run_failed";
  if (status === "CANCELLED") return "run_cancelled";
  return "run_completed";
}

// The one legal-transition table — single source for the mutators AND the
// simulator, mirroring the projection's next_status/2 (projection.ex):
// run_started only from PENDING; run_completed only from RUNNING; fail and
// cancel from ANY non-terminal; run_abandoned only from AWAITING_APPROVAL.
// advance on AWAITING_APPROVAL no-ops — no lifecycle kind exists for
// approval resolution. Everything else is illegal ⇒ null ⇒ total no-op.
function planTransition(
  op: MutatorOp,
  run: RunFixture,
): { status: WorkflowRunStatus; kind: RunTransitionKind } | null {
  switch (op) {
    case "advance": {
      if (run.status === WorkflowRunStatus.Pending) {
        return { status: WorkflowRunStatus.Running, kind: "run_started" };
      }
      if (run.status === WorkflowRunStatus.Running) {
        const terminal = run.simTerminal ?? "COMPLETED";
        return { status: terminal, kind: terminalKind(terminal) };
      }
      return null;
    }
    case "fail":
      return nonTerminal(run.status)
        ? { status: WorkflowRunStatus.Failed, kind: "run_failed" }
        : null;
    case "cancel":
      return nonTerminal(run.status)
        ? { status: WorkflowRunStatus.Cancelled, kind: "run_cancelled" }
        : null;
    case "abandon":
      return run.status === WorkflowRunStatus.AwaitingApproval
        ? { status: WorkflowRunStatus.Abandoned, kind: "run_abandoned" }
        : null;
  }
}

function compareProjectsAlphabetical(a: ProjectFixture, b: ProjectFixture): number {
  if (a.name !== b.name) return a.name < b.name ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

// insertedAt desc, id desc — parsed, not string-compared, so mixed ISO
// formats (with/without milliseconds) still order by instant.
function compareRunsRecent(a: RunFixture, b: RunFixture): number {
  const at = Date.parse(a.insertedAt);
  const bt = Date.parse(b.insertedAt);
  if (at !== bt) return bt - at;
  return a.id < b.id ? 1 : a.id > b.id ? -1 : 0;
}

function compareRunsOldest(a: RunFixture, b: RunFixture): number {
  return -compareRunsRecent(a, b);
}

export class MockStore {
  // The single immutable behavior surface both fakes read (link:
  // behavior.graphql; channel joins: behavior.joins; sim auto-start:
  // behavior.simulate). Readonly<> aligns the compile-time contract with the
  // Object.freeze — property-level readonly alone would still let
  // `store.behavior.graphql = ...` type-check while the freeze threw.
  readonly behavior: Readonly<{
    graphql: "ok" | "graphql-error" | "network-error";
    joins: "ok" | "unavailable";
    simulate: boolean;
  }>;

  private projects: ProjectFixture[];
  private runs: RunFixture[];
  private listeners = new Set<TransitionListener>();
  private ticks = 0;

  constructor(scenario: MockScenario) {
    this.behavior = Object.freeze({
      graphql: scenario.graphql,
      joins: scenario.joins,
      simulate: scenario.simulate,
    });
    // Deep-clone the scenario rows (nested projects included): no caller or
    // sibling store can mutate another store's fixture template.
    this.projects = structuredClone(scenario.projects);
    this.runs = structuredClone(scenario.runs);
  }

  // All public reads return snapshots, never internal rows — a live
  // reference would let callers mutate status past the transition table
  // (no stamps, no events).
  listProjectsAlphabetical(limit: number): ProjectFixture[] {
    const sorted = [...this.projects].sort(compareProjectsAlphabetical);
    return structuredClone(sorted.slice(0, limit));
  }

  listRecentRuns(limit: number): RunFixture[] {
    const sorted = [...this.runs].sort(compareRunsRecent);
    return structuredClone(sorted.slice(0, limit));
  }

  getProject(id: string): ProjectFixture | null {
    const found = this.projects.find((project) => project.id === id);
    return found ? structuredClone(found) : null;
  }

  getRun(id: string): RunFixture | null {
    const found = this.runs.find((run) => run.id === id);
    return found ? structuredClone(found) : null;
  }

  advanceRun(id: string): boolean {
    return this.applyTransition("advance", id);
  }

  failRun(id: string): boolean {
    return this.applyTransition("fail", id);
  }

  cancelRun(id: string): boolean {
    return this.applyTransition("cancel", id);
  }

  abandonRun(id: string): boolean {
    return this.applyTransition("abandon", id);
  }

  onTransition(listener: TransitionListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  // A parked AWAITING_APPROVAL run does NOT keep the simulator alive.
  hasAdvanceableRuns(): boolean {
    return this.runs.some((run) => advanceable(run.status));
  }

  oldestAdvanceableRunId(): string | null {
    const candidates = this.runs.filter((run) => advanceable(run.status));
    if (candidates.length === 0) return null;
    candidates.sort(compareRunsOldest);
    return candidates[0].id;
  }

  private applyTransition(op: MutatorOp, id: string): boolean {
    const run = this.runs.find((row) => row.id === id);
    if (!run) return false;
    const planned = planTransition(op, run);
    // Illegal ⇒ total no-op: no event, no clock tick, no stamp.
    if (!planned) return false;
    const stamp = this.nextStamp();
    run.status = planned.status;
    run.updatedAt = stamp;
    if (planned.kind === "run_started") run.startedAt = stamp;
    if (!nonTerminal(planned.status)) run.completedAt = stamp;
    const transition: RunTransition = { id: run.id, kind: planned.kind };
    for (const listener of [...this.listeners]) listener(transition);
    return true;
  }

  private nextStamp(): string {
    this.ticks += 1;
    return new Date(Date.parse(CLOCK_BASE) + this.ticks * CLOCK_STEP_MS).toISOString();
  }
}

declare global {
  // Dev-console poking: __argusMockStore.advanceRun(...) etc.
  var __argusMockStore: MockStore | undefined;
}

let sharedStore: MockStore | null = null;

// Lazy singleton: the link and the socket share one store in app mode, so a
// mutation is visible as both a channel push and a refetched query result.
export function getSharedStore(): MockStore {
  if (!sharedStore) {
    sharedStore = new MockStore(resolveScenario());
    globalThis.__argusMockStore = sharedStore;
  }
  return sharedStore;
}
