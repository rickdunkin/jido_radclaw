import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";

// The wrapper's whole job is the bounded-reconnect policy around
// phoenix.js, so phoenix itself is mocked and each test re-imports a
// fresh module instance (the singleton + failure counter are module
// state).

const phoenix = vi.hoisted(() => {
  class MockSocket {
    static instances: MockSocket[] = [];
    endPoint: string;
    opts: Record<string, unknown>;
    connect = vi.fn();
    disconnect = vi.fn();
    private openCallbacks: Array<() => void> = [];
    private errorCallbacks: Array<() => void> = [];

    constructor(endPoint: string, opts?: Record<string, unknown>) {
      this.endPoint = endPoint;
      this.opts = opts ?? {};
      MockSocket.instances.push(this);
    }

    onOpen(callback: () => void): string {
      this.openCallbacks.push(callback);
      return "ref";
    }

    onError(callback: () => void): string {
      this.errorCallbacks.push(callback);
      return "ref";
    }

    fireOpen(): void {
      for (const callback of this.openCallbacks) callback();
    }

    fireError(): void {
      for (const callback of this.errorCallbacks) callback();
    }
  }
  return { MockSocket };
});

vi.mock("phoenix", () => ({ Socket: phoenix.MockSocket }));

beforeEach(() => {
  vi.resetModules();
  phoenix.MockSocket.instances.length = 0;
});

afterEach(() => {
  vi.unstubAllEnvs();
});

async function importSocketModule() {
  return await import("./socket.ts");
}

test("createSocket passes the API key as authToken, never in the URL", async () => {
  vi.stubEnv("VITE_API_KEY", "test-key-123");
  const mod = await importSocketModule();

  mod.createSocket();

  const [instance] = phoenix.MockSocket.instances;
  expect(instance.endPoint).toBe("/argus/ws");
  expect(instance.opts.authToken).toBe("test-key-123");
});

test("createSocket supplies the slower bounded reconnect schedule", async () => {
  const mod = await importSocketModule();

  mod.createSocket();

  const [instance] = phoenix.MockSocket.instances;
  const reconnectAfterMs = instance.opts.reconnectAfterMs as (tries: number) => number;
  expect([1, 2, 3, 4, 5, 99].map(reconnectAfterMs)).toEqual([
    1_000, 2_000, 5_000, 10_000, 30_000, 30_000,
  ]);
});

test("consecutive pre-open failures reach the cap: disconnect + unavailable", async () => {
  const mod = await importSocketModule();
  mod.getSocket();
  const [instance] = phoenix.MockSocket.instances;

  for (let i = 0; i < 7; i++) instance.fireError();
  expect(instance.disconnect).not.toHaveBeenCalled();
  expect(mod.getTransportStatus()).toBe("connecting");

  instance.fireError();
  expect(instance.disconnect).toHaveBeenCalledTimes(1);
  expect(mod.getTransportStatus()).toBe("unavailable");
});

test("the counter resets on open, then caps the post-open failure run", async () => {
  // The suspension scenario: an open socket is server-disconnected (1001)
  // and every reconnect is refused. Without the reset-on-open, the five
  // pre-open failures here would make the cap land three errors early.
  const mod = await importSocketModule();
  mod.getSocket();
  const [instance] = phoenix.MockSocket.instances;

  for (let i = 0; i < 5; i++) instance.fireError();
  instance.fireOpen();
  expect(mod.getTransportStatus()).toBe("live");

  for (let i = 0; i < 7; i++) instance.fireError();
  expect(instance.disconnect).not.toHaveBeenCalled();

  instance.fireError();
  expect(instance.disconnect).toHaveBeenCalledTimes(1);
  expect(mod.getTransportStatus()).toBe("unavailable");
});

test("retryConnect resets the counter and reconnects the parked socket", async () => {
  const mod = await importSocketModule();
  mod.getSocket();
  const [instance] = phoenix.MockSocket.instances;

  for (let i = 0; i < 8; i++) instance.fireError();
  expect(mod.getTransportStatus()).toBe("unavailable");
  const connectsBefore = instance.connect.mock.calls.length;

  const seen: string[] = [];
  mod.subscribeTransportStatus((status) => seen.push(status));
  mod.retryConnect();

  expect(instance.connect.mock.calls.length).toBe(connectsBefore + 1);
  expect(mod.getTransportStatus()).toBe("connecting");

  // A fresh failure run gets the full budget again before re-parking.
  for (let i = 0; i < 7; i++) instance.fireError();
  expect(instance.disconnect).toHaveBeenCalledTimes(1);

  instance.fireOpen();
  expect(mod.getTransportStatus()).toBe("live");
  expect(seen).toEqual(["connecting", "live"]);
});
