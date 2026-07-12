import { Socket, type SocketConnectOption } from "phoenix";
import { createMockPhoenixSocket } from "../mocks/socket.ts";
import type { SocketLike } from "./socket-contract.ts";

// The npm phoenix package is pinned EXACT to the hex phoenix version in
// mix.lock (serializer wire compat) — a hex phoenix bump must bump
// ui/package.json in the same change.

export type TransportStatus = "connecting" | "live" | "unavailable";

// Phoenix's default first five backoffs land in <1s — too brittle a window
// to cap on. Each refused connect writes a durable audit row server-side,
// and phoenix.js deliberately reconnects even after the server's 1001
// "disconnect" close, so a suspended tenant's client would loop forever
// without a slower schedule + a hard cap.
const RECONNECT_SCHEDULE_MS = [1_000, 2_000, 5_000, 10_000];
const RECONNECT_CAP_MS = 30_000;
// ~8 consecutive failures ≈ >1min of refusals before parking the client.
const MAX_CONSECUTIVE_FAILURES = 8;

type StatusListener = (status: TransportStatus) => void;

let socket: SocketLike | null = null;
let status: TransportStatus = "connecting";
// Consecutive onError since the most recent onOpen — reset on every open,
// so it bounds the pre-first-open run AND every later reconnect run
// (suspension included).
let consecutiveFailures = 0;
const listeners = new Set<StatusListener>();

function setStatus(next: TransportStatus): void {
  if (status === next) return;
  status = next;
  for (const listener of listeners) listener(next);
}

export function getTransportStatus(): TransportStatus {
  return status;
}

export function subscribeTransportStatus(listener: StatusListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

// authToken rides the Sec-WebSocket-Protocol header (Phoenix auth_token
// transport) — the key never appears in the URL. Mirrors apollo.ts: the
// key comes from VITE_API_KEY (ui/.env.local, gitignored) at build time.
export function createSocket(): SocketLike {
  // Bare inline identifier, same gate as apollo.ts: __ARGUS_MOCKS_ALLOWED__
  // is statically false in every `vite build` (command-derived — hostile
  // NODE_ENV/VITE_* exports can't reopen it; see src/mocks-gate.d.ts), so
  // the branch and the mocks graph fold out of every build. Branching
  // here rather than in getSocket() keeps the real onOpen/onError/status
  // wiring and retryConnect() driving the fake unchanged.
  if (__ARGUS_MOCKS_ALLOWED__ && import.meta.env.VITE_MOCKS === "1") {
    return createMockPhoenixSocket();
  }
  const apiKey: string | undefined = import.meta.env.VITE_API_KEY;
  const opts: Partial<SocketConnectOption> = {
    reconnectAfterMs: (tries: number) => RECONNECT_SCHEDULE_MS[tries - 1] ?? RECONNECT_CAP_MS,
  };
  if (apiKey) opts.authToken = apiKey;
  return new Socket("/argus/ws", opts);
}

// Lazy singleton: routes that never render live data never open a socket,
// and reconnect state survives route changes.
export function getSocket(): SocketLike {
  if (socket) return socket;
  socket = createSocket();
  socket.onOpen(() => {
    consecutiveFailures = 0;
    setStatus("live");
  });
  socket.onError(() => {
    consecutiveFailures += 1;
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      socket?.disconnect();
      setStatus("unavailable");
    } else {
      setStatus("connecting");
    }
  });
  setStatus("connecting");
  socket.connect();
  return socket;
}

export function retryConnect(): void {
  consecutiveFailures = 0;
  setStatus("connecting");
  getSocket().connect();
}
