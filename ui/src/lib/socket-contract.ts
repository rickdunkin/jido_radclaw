// The app-owned structural subset of the phoenix socket API. phoenix's real
// Socket satisfies SocketLike with no cast (its `any` callback params absorb
// the typed ones below), and the mock socket `implements` these interfaces —
// so any new phoenix API a route reaches for fails tsc until the contract and
// the fake are widened together. That compile-time tripwire is the point.

export interface JoinOkReply {
  id: string;
  status: string;
}

export interface JoinErrorReply {
  reason?: string;
}

// Status-specific overloads, not one `(response?: unknown) => void` param:
// standalone arrow arguments are checked strictly, so runs.tsx's annotated
// reply callbacks would not type-check against an `unknown` payload.
export interface PushLike {
  receive(status: "ok", cb: (response: JoinOkReply) => void): PushLike;
  receive(status: "error", cb: (response?: JoinErrorReply) => void): PushLike;
  receive(status: "timeout", cb: () => void): PushLike;
}

export interface ChannelLike {
  on(event: string, cb: (payload?: unknown) => void): void | number;
  join(): PushLike;
  leave(): unknown;
}

export interface SocketLike {
  connect(): void;
  disconnect(): void;
  onOpen(cb: () => void): unknown;
  onError(cb: () => void): unknown;
  channel(topic: string): ChannelLike;
}
