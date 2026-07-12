import type { ComponentProps } from "react";
import { MockedProvider } from "@apollo/client/testing/react";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import { RecentWorkflowRunsDocument, WorkflowRunStatus } from "./gql/graphql.ts";
import { createAppRouter } from "./router.tsx";

// The route talks to the socket only through the lib/socket.ts seam; the
// fake records channels, their handlers, and their join-receive callbacks
// so tests can fire join replies, join errors, and run_event pushes.
const fake = vi.hoisted(() => {
  type Callback = (arg?: unknown) => void;

  class FakeChannel {
    topic: string;
    left = false;
    private handlers = new Map<string, Callback[]>();
    private receives = new Map<string, Callback[]>();

    constructor(topic: string) {
      this.topic = topic;
    }

    on(event: string, callback: Callback): number {
      const list = this.handlers.get(event) ?? [];
      list.push(callback);
      this.handlers.set(event, list);
      return list.length;
    }

    join() {
      const push = {
        receive: (status: string, callback: Callback) => {
          const list = this.receives.get(status) ?? [];
          list.push(callback);
          this.receives.set(status, list);
          return push;
        },
      };
      return push;
    }

    leave() {
      this.left = true;
      return { receive: () => ({}) };
    }

    fireReceive(kind: "ok" | "error" | "timeout", resp?: unknown): void {
      for (const callback of this.receives.get(kind) ?? []) callback(resp);
    }

    firePush(event: string, payload?: unknown): void {
      for (const callback of this.handlers.get(event) ?? []) callback(payload);
    }
  }

  class FakeSocket {
    channels: FakeChannel[] = [];

    channel(topic: string): FakeChannel {
      const created = new FakeChannel(topic);
      this.channels.push(created);
      return created;
    }
  }

  const state = {
    socket: new FakeSocket(),
    transportStatus: "live",
    listeners: new Set<() => void>(),
  };

  return {
    state,
    getSocket: vi.fn(() => state.socket),
    retryConnect: vi.fn(),
    reset() {
      state.socket = new FakeSocket();
      state.transportStatus = "live";
      state.listeners.clear();
      this.getSocket.mockClear();
      this.retryConnect.mockClear();
    },
  };
});

vi.mock("./lib/socket.ts", () => ({
  getSocket: fake.getSocket,
  getTransportStatus: () => fake.state.transportStatus,
  subscribeTransportStatus: (listener: () => void) => {
    fake.state.listeners.add(listener);
    return () => fake.state.listeners.delete(listener);
  },
  retryConnect: fake.retryConnect,
}));

const RUN_A = "11111111-1111-4111-8111-111111111111";
const RUN_B = "22222222-2222-4222-8222-222222222222";
const RUN_C = "33333333-3333-4333-8333-333333333333";

type Mocks = NonNullable<ComponentProps<typeof MockedProvider>["mocks"]>;

function runRow(id: string, name: string, status: WorkflowRunStatus) {
  return {
    __typename: "WorkflowRun" as const,
    id,
    name,
    workflowType: "code",
    status,
    insertedAt: "2026-07-01T00:00:00Z",
    completedAt: null,
  };
}

function runsMock(rows: Array<ReturnType<typeof runRow>>) {
  return {
    request: { query: RecentWorkflowRunsDocument, variables: { limit: 50 } },
    result: { data: { recentWorkflowRuns: rows } },
  };
}

function renderRuns(mocks: Mocks) {
  const router = createAppRouter({
    history: createMemoryHistory({ initialEntries: ["/runs"] }),
  });
  render(
    <MockedProvider mocks={mocks}>
      <RouterProvider router={router} />
    </MockedProvider>,
  );
  return router;
}

function channelFor(id: string) {
  const matches = fake.state.socket.channels.filter((c) => c.topic === `workflows:run:${id}`);
  const last = matches[matches.length - 1];
  if (!last) throw new Error(`no channel joined for ${id}`);
  return last;
}

async function flush() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 10));
  });
}

beforeEach(() => {
  fake.reset();
});

afterEach(() => {
  cleanup();
});

test("renders mixed statuses and joins exactly the non-terminal topics", async () => {
  renderRuns([
    runsMock([
      runRow(RUN_A, "run-a", WorkflowRunStatus.Pending),
      runRow(RUN_B, "run-b", WorkflowRunStatus.Completed),
      runRow(RUN_C, "run-c", WorkflowRunStatus.Running),
    ]),
  ]);

  expect(await screen.findByText("run-b")).toBeDefined();
  await flush();

  expect(fake.state.socket.channels.map((c) => c.topic)).toEqual([
    `workflows:run:${RUN_A}`,
    `workflows:run:${RUN_C}`,
  ]);
});

test("join reply disagreeing with the rendered status refetches (stale list)", async () => {
  renderRuns([
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Pending)]),
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Running)]),
  ]);
  expect(await screen.findByText("code · pending")).toBeDefined();

  act(() => channelFor(RUN_A).fireReceive("ok", { id: RUN_A, status: "running" }));

  expect(await screen.findByText("code · running")).toBeDefined();
});

test("join reply agreeing with the rendered status does not refetch", async () => {
  renderRuns([runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Running)])]);
  expect(await screen.findByText("code · running")).toBeDefined();

  act(() => channelFor(RUN_A).fireReceive("ok", { id: RUN_A, status: "running" }));
  await flush();

  // A spurious refetch would exhaust the single mock and surface as the
  // hook's error state.
  expect(screen.queryByText(/Failed to load runs/)).toBeNull();
  expect(screen.getByText("code · running")).toBeDefined();
});

test("join reply with a terminal status refetches (the join-reply race)", async () => {
  renderRuns([
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Pending)]),
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Completed)]),
  ]);
  expect(await screen.findByText("code · pending")).toBeDefined();

  act(() => channelFor(RUN_A).fireReceive("ok", { id: RUN_A, status: "completed" }));

  expect(await screen.findByText("code · completed")).toBeDefined();
});

test("a rejoin reply compares against the CURRENT status, not a snapshot", async () => {
  renderRuns([
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Pending)]),
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Running)]),
  ]);
  expect(await screen.findByText("code · pending")).toBeDefined();

  const channel = channelFor(RUN_A);
  act(() => channel.fireReceive("ok", { id: RUN_A, status: "running" }));
  expect(await screen.findByText("code · running")).toBeDefined();

  // Phoenix re-fires join receive callbacks on rejoin. An effect-time
  // snapshot would still say PENDING here and refetch a third time —
  // exhausting the mocks and surfacing an error.
  act(() => channel.fireReceive("ok", { id: RUN_A, status: "running" }));
  await flush();

  expect(screen.queryByText(/Failed to load runs/)).toBeNull();
  expect(screen.getByText("code · running")).toBeDefined();
});

test("a run_event push refetches; a now-terminal run's channel is left", async () => {
  renderRuns([
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Running)]),
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Completed)]),
  ]);
  expect(await screen.findByText("code · running")).toBeDefined();

  const channel = channelFor(RUN_A);
  act(() => channel.firePush("run_event", { id: RUN_A, kind: "run_completed" }));

  expect(await screen.findByText("code · completed")).toBeDefined();
  await flush();
  expect(channel.left).toBe(true);
  expect(fake.state.socket.channels).toHaveLength(1);
});

test("a not_found join error leaves the channel and refetches the row away", async () => {
  renderRuns([runsMock([runRow(RUN_A, "gone-run", WorkflowRunStatus.Pending)]), runsMock([])]);
  expect(await screen.findByText("gone-run")).toBeDefined();

  const channel = channelFor(RUN_A);
  act(() => channel.fireReceive("error", { reason: "not_found" }));

  expect(await screen.findByText("No runs yet.")).toBeDefined();
  expect(channel.left).toBe(true);
  // not_found is resolution, not degradation — no banner.
  expect(screen.queryByText("Live updates unavailable.")).toBeNull();
});

test("an all-terminal list never touches the socket", async () => {
  renderRuns([
    runsMock([
      runRow(RUN_A, "run-a", WorkflowRunStatus.Completed),
      runRow(RUN_B, "run-b", WorkflowRunStatus.Failed),
    ]),
  ]);
  expect(await screen.findByText("run-b")).toBeDefined();
  await flush();

  expect(fake.getSocket).not.toHaveBeenCalled();
});

test("degradation is per-run: B's success never clears A; Retry does", async () => {
  renderRuns([
    runsMock([
      runRow(RUN_A, "run-a", WorkflowRunStatus.Pending),
      runRow(RUN_B, "run-b", WorkflowRunStatus.Pending),
    ]),
    runsMock([
      runRow(RUN_A, "run-a", WorkflowRunStatus.Pending),
      runRow(RUN_B, "run-b", WorkflowRunStatus.Pending),
    ]),
  ]);
  expect(await screen.findByText("run-a")).toBeDefined();
  await flush();

  act(() => channelFor(RUN_A).fireReceive("error", { reason: "unavailable" }));
  expect(await screen.findByText("Live updates unavailable.")).toBeDefined();

  act(() => channelFor(RUN_B).fireReceive("ok", { id: RUN_B, status: "pending" }));
  await flush();
  expect(screen.getByText("Live updates unavailable.")).toBeDefined();

  // Retry bumps the subscription epoch: fresh channels for the same ids.
  const channelsBefore = fake.state.socket.channels.length;
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await flush();
  expect(fake.retryConnect).toHaveBeenCalledTimes(1);
  expect(fake.state.socket.channels.length).toBe(channelsBefore + 2);

  act(() => channelFor(RUN_A).fireReceive("ok", { id: RUN_A, status: "pending" }));
  await flush();
  expect(screen.queryByText("Live updates unavailable.")).toBeNull();
});

test("re-entering /runs refetches: runs created after the first visit appear", async () => {
  // One MockedProvider for the whole navigation — its constructor builds a
  // single persistent client, the main.tsx production-singleton shape, so
  // the Apollo cache survives leaving the route exactly like it does in
  // the real app.
  const router = renderRuns([
    runsMock([]),
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Pending)]),
  ]);
  expect(await screen.findByText("No runs yet.")).toBeDefined();

  // Awaited navigation, and the index must have SETTLED before returning —
  // otherwise the remount races the assertion below.
  await act(async () => {
    await router.navigate({ to: "/" });
  });
  expect(await screen.findByText("View runs")).toBeDefined();

  await act(async () => {
    await router.navigate({ to: "/runs" });
  });

  // cache-first would serve the cached empty list on remount and never
  // consume the second mock — the run created between visits must appear
  // without a hard reload (cache-and-network's network leg).
  expect(await screen.findByText("run-a")).toBeDefined();
});

test("callbacks from replaced (disposed) channels cannot mutate health", async () => {
  renderRuns([
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Pending)]),
    runsMock([runRow(RUN_A, "run-a", WorkflowRunStatus.Pending)]),
  ]);
  expect(await screen.findByText("run-a")).toBeDefined();
  await flush();

  // Degrade (banner + Retry appear), bump the epoch, recover via the NEW
  // channel's join-ok.
  const preEpochChannel = channelFor(RUN_A);
  act(() => preEpochChannel.fireReceive("error", { reason: "unavailable" }));
  expect(await screen.findByText("Live updates unavailable.")).toBeDefined();

  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await flush();
  act(() => channelFor(RUN_A).fireReceive("ok", { id: RUN_A, status: "pending" }));
  await flush();
  expect(screen.queryByText("Live updates unavailable.")).toBeNull();

  // A late callback from the replaced channel must mutate nothing: no
  // re-degraded banner, and no refetch (the mocks are exhausted — a
  // refetch would surface as the hook's error state).
  act(() => preEpochChannel.fireReceive("error", { reason: "unavailable" }));
  await flush();

  expect(screen.queryByText("Live updates unavailable.")).toBeNull();
  expect(screen.queryByText(/Failed to load runs/)).toBeNull();
});
