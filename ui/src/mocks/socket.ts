import type {
  ChannelLike,
  JoinErrorReply,
  JoinOkReply,
  PushLike,
  SocketLike,
} from "../lib/socket-contract.ts";
import { getSharedStore, type MockStore, type RunTransition } from "./store.ts";

// A structural fake of the phoenix socket surface, mirroring the
// WorkflowsChannel wire contract (workflows_channel.ex / run_pubsub.ex). No
// runtime `phoenix` import — lib/socket.test.ts's vi.mock("phoenix") stays
// untangled from this module.

const TOPIC_PREFIX = "workflows:run:";
const UUID_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

type PushStatus = "ok" | "error" | "timeout";
type PushCallback =
  | ((response: JoinOkReply) => void)
  | ((response?: JoinErrorReply) => void)
  | (() => void);

interface PushHook {
  status: PushStatus;
  cb: (response?: unknown) => void;
}

class MockPush implements PushLike {
  private outcome: { status: PushStatus; response?: unknown } | null = null;
  private hooks: PushHook[] = [];

  receive(status: "ok", cb: (response: JoinOkReply) => void): PushLike;
  receive(status: "error", cb: (response?: JoinErrorReply) => void): PushLike;
  receive(status: "timeout", cb: () => void): PushLike;
  receive(status: PushStatus, cb: PushCallback): PushLike {
    // The single documented widening boundary: hooks are stored uniformly
    // and only ever invoked with the payload resolved for their status.
    const hook: PushHook = { status, cb: cb as (response?: unknown) => void };
    // phoenix parity: replay immediately when the reply already landed,
    // and register regardless.
    if (this.outcome && this.outcome.status === status) hook.cb(this.outcome.response);
    this.hooks.push(hook);
    return this;
  }

  resolve(status: PushStatus, response?: unknown): void {
    if (this.outcome) return;
    this.outcome = { status, response };
    for (const hook of [...this.hooks]) {
      if (hook.status === status) hook.cb(response);
    }
  }
}

export class MockChannel implements ChannelLike {
  readonly topic: string;
  // Canonical (lowercased) run id — mirrors the server's Ecto.UUID.cast/1-
  // FIRST join: an uppercase-UUID topic joins fine and still hears events,
  // instead of silently subscribing a dead topic.
  readonly canonicalRunId: string | null;

  private store: MockStore;
  private unregister: () => void;
  private joined = false;
  private joinUsed = false;
  private handlers = new Map<string, Array<(payload?: unknown) => void>>();

  constructor(topic: string, store: MockStore, unregister: () => void) {
    this.topic = topic;
    this.store = store;
    this.unregister = unregister;
    this.canonicalRunId = topic.startsWith(TOPIC_PREFIX)
      ? topic.slice(TOPIC_PREFIX.length).toLowerCase()
      : null;
  }

  on(event: string, cb: (payload?: unknown) => void): number {
    const list = this.handlers.get(event) ?? [];
    list.push(cb);
    this.handlers.set(event, list);
    return list.length;
  }

  join(): PushLike {
    // phoenix parity: a channel instance joins once, ever — runs.tsx's
    // fresh-channel-per-effect depends on this throw.
    if (this.joinUsed) {
      throw new Error(
        `tried to join multiple times. 'join' can only be called a single time per channel instance`,
      );
    }
    this.joinUsed = true;
    this.joined = true;
    const push = new MockPush();
    // State is read at REPLY time, in the server's precedence order: the
    // topic pattern match rejects first, Ecto.UUID.cast/1 runs before any
    // fallible subscribe/read (so "unavailable" models infra AFTER
    // validation), and only then the run lookup. The reply deliberately
    // races past leave(), like the real server — runs.tsx's disposed guard
    // covers it.
    queueMicrotask(() => {
      if (this.canonicalRunId === null) {
        push.resolve("error", { reason: "unauthorized topic" });
        return;
      }
      if (!UUID_SHAPE.test(this.canonicalRunId)) {
        push.resolve("error", { reason: "not_found" });
        return;
      }
      if (this.store.behavior.joins === "unavailable") {
        push.resolve("error", { reason: "unavailable" });
        return;
      }
      const run = this.store.getRun(this.canonicalRunId);
      if (!run) {
        push.resolve("error", { reason: "not_found" });
        return;
      }
      // Uppercase-snake enum → the channel's lowercase-snake wire casing;
      // the reply id is the canonical one.
      push.resolve("ok", { id: run.id, status: run.status.toLowerCase() });
    });
    return push;
  }

  leave(): unknown {
    this.joined = false;
    this.unregister();
    return null;
  }

  trigger(event: string, payload?: unknown): void {
    if (!this.joined) return;
    for (const cb of this.handlers.get(event) ?? []) cb(payload);
  }
}

export class MockPhoenixSocket implements SocketLike {
  private store: MockStore;
  private channels: MockChannel[] = [];
  private openCallbacks: Array<() => void> = [];
  private errorCallbacks: Array<() => void> = [];
  private connected = false;

  constructor(store: MockStore) {
    this.store = store;
    // Subscribed ONCE: the RunPubSub→WorkflowsChannel push mirror. Events
    // route by canonical run id (store ids are canonical lowercase), never
    // by the raw topic string.
    store.onTransition((transition: RunTransition) => {
      for (const channel of [...this.channels]) {
        if (channel.canonicalRunId === transition.id) {
          channel.trigger("run_event", { id: transition.id, kind: transition.kind });
        }
      }
    });
  }

  connect(): void {
    if (this.connected) return;
    this.connected = true;
    // Async like a real transport: the "live" status lands through the real
    // getSocket() onOpen wiring, after the current task.
    queueMicrotask(() => {
      if (!this.connected) return;
      for (const cb of [...this.openCallbacks]) cb();
    });
  }

  disconnect(): void {
    this.connected = false;
  }

  onOpen(cb: () => void): unknown {
    this.openCallbacks.push(cb);
    return "mock-ref";
  }

  // Registered but never fired: the fake models channel-level
  // unavailability (the degraded scenario), not transport errors.
  onError(cb: () => void): unknown {
    this.errorCallbacks.push(cb);
    return "mock-ref";
  }

  channel(topic: string): ChannelLike {
    const created: MockChannel = new MockChannel(topic, this.store, () => {
      this.channels = this.channels.filter((existing) => existing !== created);
    });
    this.channels.push(created);
    return created;
  }
}

// Interval-driven demo motion: advance the oldest advanceable run until only
// parked/terminal rows remain, then clear the interval — a parked
// AWAITING_APPROVAL row never holds it open. Tests drive the store mutators
// directly instead of relying on this.
export function startSimulation(store: MockStore, opts: { intervalMs?: number } = {}): () => void {
  const intervalMs = opts.intervalMs ?? 2500;
  const timer = setInterval(() => {
    const id = store.oldestAdvanceableRunId();
    if (id !== null) store.advanceRun(id);
    if (!store.hasAdvanceableRuns()) clearInterval(timer);
  }, intervalMs);
  return () => clearInterval(timer);
}

export function createMockPhoenixSocket(store: MockStore = getSharedStore()): SocketLike {
  const socket = new MockPhoenixSocket(store);
  if (store.behavior.simulate && import.meta.env.MODE !== "test") {
    startSimulation(store);
  }
  return socket;
}
