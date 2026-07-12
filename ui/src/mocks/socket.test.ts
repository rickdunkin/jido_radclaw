import { afterEach, expect, test, vi } from "vite-plus/test";
import { WorkflowRunStatus } from "../gql/graphql.ts";
import type { JoinErrorReply, JoinOkReply } from "../lib/socket-contract.ts";
import { makeRun, type RunFixture } from "./fixtures.ts";
import { buildScenario, type MockScenario } from "./scenarios.ts";
import { createMockPhoenixSocket, MockPhoenixSocket, startSimulation } from "./socket.ts";
import { MockStore } from "./store.ts";

const S = WorkflowRunStatus;

function storeWith(runs: RunFixture[], extra: Partial<MockScenario> = {}): MockStore {
  return new MockStore({ ...buildScenario("empty"), runs, ...extra });
}

function pendingRun(index = 1): RunFixture {
  return makeRun(index, { status: S.Pending, startedAt: null, completedAt: null });
}

async function flush(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

afterEach(() => {
  vi.useRealTimers();
});

test("connect fires onOpen async and is idempotent while connected", async () => {
  const socket = new MockPhoenixSocket(storeWith([]));
  const opened: number[] = [];
  socket.onOpen(() => opened.push(opened.length + 1));

  socket.connect();
  socket.connect();
  expect(opened).toEqual([]); // async, like a real transport

  await flush();
  expect(opened).toEqual([1]); // the second connect() was a no-op
});

test('join ok replies carry lowercase-snake statuses ("pending", "awaiting_approval")', async () => {
  const pending = pendingRun(1);
  const parked = makeRun(2, { status: S.AwaitingApproval, completedAt: null });
  const socket = new MockPhoenixSocket(storeWith([pending, parked]));

  const pendingReplies: JoinOkReply[] = [];
  const parkedReplies: JoinOkReply[] = [];
  socket
    .channel(`workflows:run:${pending.id}`)
    .join()
    .receive("ok", (reply) => pendingReplies.push(reply));
  socket
    .channel(`workflows:run:${parked.id}`)
    .join()
    .receive("ok", (reply) => parkedReplies.push(reply));
  await flush();

  expect(pendingReplies).toEqual([{ id: pending.id, status: "pending" }]);
  expect(parkedReplies).toEqual([{ id: parked.id, status: "awaiting_approval" }]);
});

test("an uppercase-UUID topic joins ok with the canonical id and still hears events", async () => {
  const run = pendingRun();
  const store = storeWith([run]);
  const socket = new MockPhoenixSocket(store);

  const channel = socket.channel(`workflows:run:${run.id.toUpperCase()}`);
  const events: unknown[] = [];
  channel.on("run_event", (payload) => events.push(payload));
  const oks: JoinOkReply[] = [];
  channel.join().receive("ok", (reply) => oks.push(reply));
  await flush();

  // The reply id is the canonical lowercase one, not the raw topic's.
  expect(oks).toEqual([{ id: run.id, status: "pending" }]);

  store.advanceRun(run.id);
  expect(events).toEqual([{ id: run.id, kind: "run_started" }]);
});

test("join errors mirror the server: not_found, unavailable, unauthorized topic", async () => {
  const run = pendingRun();
  const okStore = storeWith([run]);
  const degradedStore = storeWith([run], { joins: "unavailable" });

  const notFound: Array<JoinErrorReply | undefined> = [];
  new MockPhoenixSocket(okStore)
    .channel("workflows:run:a1000000-0000-4000-8000-00000000dead")
    .join()
    .receive("error", (reply) => notFound.push(reply));

  const unavailable: Array<JoinErrorReply | undefined> = [];
  new MockPhoenixSocket(degradedStore)
    .channel(`workflows:run:${run.id}`)
    .join()
    .receive("error", (reply) => unavailable.push(reply));

  const unauthorized: Array<JoinErrorReply | undefined> = [];
  new MockPhoenixSocket(okStore)
    .channel(`rpc:${run.id}`)
    .join()
    .receive("error", (reply) => unauthorized.push(reply));

  await flush();
  expect(notFound).toEqual([{ reason: "not_found" }]);
  expect(unavailable).toEqual([{ reason: "unavailable" }]);
  expect(unauthorized).toEqual([{ reason: "unauthorized topic" }]);
});

test("validation precedes infra: degraded joins still reject bad topics honestly", async () => {
  const degradedStore = storeWith([pendingRun()], { joins: "unavailable" });
  const socket = new MockPhoenixSocket(degradedStore);

  const unauthorized: Array<JoinErrorReply | undefined> = [];
  socket
    .channel("rpc:anything")
    .join()
    .receive("error", (reply) => unauthorized.push(reply));

  const malformed: Array<JoinErrorReply | undefined> = [];
  socket
    .channel("workflows:run:not-a-uuid")
    .join()
    .receive("error", (reply) => malformed.push(reply));

  await flush();
  // The topic pattern match rejects before anything else...
  expect(unauthorized).toEqual([{ reason: "unauthorized topic" }]);
  // ...and Ecto.UUID.cast/1 runs before the fallible subscribe/read that
  // "unavailable" models.
  expect(malformed).toEqual([{ reason: "not_found" }]);
});

test("store transitions push run_event with honest lifecycle kinds", async () => {
  const run = makeRun(1, {
    status: S.Pending,
    startedAt: null,
    completedAt: null,
    simTerminal: "FAILED",
  });
  const store = storeWith([run]);
  const socket = new MockPhoenixSocket(store);

  const channel = socket.channel(`workflows:run:${run.id}`);
  const events: unknown[] = [];
  channel.on("run_event", (payload) => events.push(payload));
  channel.join();
  await flush();

  store.advanceRun(run.id); // PENDING → RUNNING
  store.advanceRun(run.id); // RUNNING → FAILED (simTerminal)

  expect(events).toEqual([
    { id: run.id, kind: "run_started" },
    { id: run.id, kind: "run_failed" },
  ]);
});

test("StrictMode shape: leave then fresh-channel rejoin; only the live channel hears", async () => {
  const run = pendingRun();
  const store = storeWith([run]);
  const socket = new MockPhoenixSocket(store);

  const first = socket.channel(`workflows:run:${run.id}`);
  const firstEvents: unknown[] = [];
  first.on("run_event", (payload) => firstEvents.push(payload));
  first.join();
  first.leave();

  const second = socket.channel(`workflows:run:${run.id}`);
  const secondEvents: unknown[] = [];
  second.on("run_event", (payload) => secondEvents.push(payload));
  const oks: JoinOkReply[] = [];
  second.join().receive("ok", (reply) => oks.push(reply));
  await flush();
  expect(oks).toEqual([{ id: run.id, status: "pending" }]);

  store.advanceRun(run.id);
  expect(firstEvents).toEqual([]);
  expect(secondEvents).toEqual([{ id: run.id, kind: "run_started" }]);

  // phoenix parity: a used channel instance can never join again.
  expect(() => first.join()).toThrowError(/join/);
});

test("a receive registered after the reply landed replays immediately", async () => {
  const run = pendingRun();
  const socket = new MockPhoenixSocket(storeWith([run]));

  const push = socket.channel(`workflows:run:${run.id}`).join();
  await flush(); // the reply has landed

  const oks: JoinOkReply[] = [];
  push.receive("ok", (reply) => oks.push(reply));
  expect(oks).toEqual([{ id: run.id, status: "pending" }]); // synchronous replay
});

test("simulation advances runs in age order and self-clears when the pool drains", () => {
  vi.useFakeTimers();
  const older = pendingRun(1);
  const newer = pendingRun(2);
  const parked = makeRun(3, { status: S.AwaitingApproval, completedAt: null });
  const store = storeWith([newer, parked, older]);
  const ids: string[] = [];
  const kinds: string[] = [];
  store.onTransition((transition) => {
    ids.push(transition.id);
    kinds.push(transition.kind);
  });

  startSimulation(store, { intervalMs: 100 });
  expect(vi.getTimerCount()).toBe(1);

  vi.advanceTimersByTime(400);

  expect(ids).toEqual([older.id, older.id, newer.id, newer.id]);
  expect(kinds).toEqual(["run_started", "run_completed", "run_started", "run_completed"]);
  // The parked row does not hold the interval open, and the clearing tick
  // left ZERO timers — absence of further transitions alone would also pass
  // on a leaked interval of no-op ticks.
  expect(vi.getTimerCount()).toBe(0);
  expect(store.getRun(parked.id)!.status).toBe(S.AwaitingApproval);
});

test("the returned stop() clears the interval mid-run", () => {
  vi.useFakeTimers();
  const store = storeWith([pendingRun()]);
  const stop = startSimulation(store, { intervalMs: 100 });

  vi.advanceTimersByTime(100); // one tick in, pool not drained
  expect(vi.getTimerCount()).toBe(1);

  stop();
  expect(vi.getTimerCount()).toBe(0);
});

test("createMockPhoenixSocket never auto-starts the simulator under vitest", () => {
  vi.useFakeTimers();
  const store = storeWith([pendingRun()], { simulate: true });

  createMockPhoenixSocket(store);

  // MODE === "test" gates the auto-start; the simulate flag alone must not
  // leak intervals into test runs.
  expect(vi.getTimerCount()).toBe(0);
});
