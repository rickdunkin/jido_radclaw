import { useQuery } from "@apollo/client/react";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useEffectEvent, useReducer, useState, useSyncExternalStore } from "react";
import { RecentWorkflowRunsDocument, WorkflowRunStatus } from "../../gql/graphql.ts";
import {
  getSocket,
  getTransportStatus,
  retryConnect,
  subscribeTransportStatus,
} from "../../lib/socket.ts";

export const Route = createFileRoute("/_shell/runs")({
  component: RunsPage,
});

const NON_TERMINAL = new Set<WorkflowRunStatus>([
  WorkflowRunStatus.Pending,
  WorkflowRunStatus.Running,
  WorkflowRunStatus.AwaitingApproval,
]);

// The join reply carries the run status in lowercase snake ("pending",
// "awaiting_approval", ... — the channel's wire contract); the GraphQL enum
// is SCREAMING_SNAKE. Normalize before comparing, or every join would look
// like a mismatch and refetch.
function normalizeWireStatus(wire: string): string {
  return wire.toUpperCase();
}

// done_with_findings is the completed-family disposition every surface marks
// amber, never plain green (the platform terminal-statuses contract).
function isDoneWithFindings(run: {
  status: WorkflowRunStatus;
  disposition: string | null;
}): boolean {
  return run.status === WorkflowRunStatus.Completed && run.disposition === "done_with_findings";
}

// findingsDeferredCount is nullable in the SDL — a null count keeps the
// amber treatment with the countless label.
function deferredFindingsLabel(count: number | null): string {
  if (count === null) return "completed · findings deferred";
  return `completed · ${count} ${count === 1 ? "finding" : "findings"} deferred`;
}

function RunsPage() {
  // cache-and-network: cached rows paint immediately, but every route entry
  // also fires the network leg — the client is an app-lifetime singleton
  // (main.tsx), so Apollo's default cache-first would otherwise serve a
  // stale (even empty) list forever after navigation, and runs created
  // between visits would never appear. refetch() stays a network fetch
  // under this policy, so the run_event path is unchanged.
  const { data, loading, error, refetch } = useQuery(RecentWorkflowRunsDocument, {
    variables: { limit: 50 },
    fetchPolicy: "cache-and-network",
  });
  // Per-run channel health — its OWN state, separate from the transport
  // status: run A staying degraded must survive run B joining fine.
  const [degradedIds, setDegradedIds] = useState<ReadonlySet<string>>(new Set());
  // Bumping the epoch rebuilds fresh channels for the SAME id set — the only
  // way back after a leave() (Socket.connect() no-ops while connected).
  const [subEpoch, bumpSubEpoch] = useReducer((epoch: number) => epoch + 1, 0);
  const transportStatus = useSyncExternalStore(subscribeTransportStatus, getTransportStatus);

  const runs = data?.recentWorkflowRuns ?? [];
  const activeKey = runs
    .filter((run) => NON_TERMINAL.has(run.status))
    .map((run) => run.id)
    .sort()
    .join(",");

  // Effect-event reader: join receive callbacks re-fire on Phoenix rejoin
  // while the effect persists across refetches, so they must compare against
  // the CURRENT rendered status, never an effect-time snapshot.
  const currentStatusOf = useEffectEvent((id: string): string | undefined => {
    return data?.recentWorkflowRuns.find((run) => run.id === id)?.status;
  });

  function markDegraded(id: string) {
    setDegradedIds((prev) => {
      if (prev.has(id)) return prev;
      const next = new Set(prev);
      next.add(id);
      return next;
    });
  }

  function clearDegraded(id: string) {
    setDegradedIds((prev) => {
      if (!prev.has(id)) return prev;
      const next = new Set(prev);
      next.delete(id);
      return next;
    });
  }

  // Prune degradation for ids that left the active set — a terminal or
  // vanished run must not pin the banner forever.
  useEffect(() => {
    const active = new Set(activeKey === "" ? [] : activeKey.split(","));
    setDegradedIds((prev) => {
      const next = new Set([...prev].filter((id) => active.has(id)));
      return next.size === prev.size ? prev : next;
    });
  }, [activeKey]);

  useEffect(() => {
    const ids = activeKey === "" ? [] : activeKey.split(",");
    if (ids.length === 0) return;

    // Late callbacks from replaced channels (epoch bump, StrictMode
    // double-invoke) must never mutate current state.
    let disposed = false;
    const refetchSafely = () => {
      refetch().catch(() => {
        // Rejection surfaces via the hook's error state.
      });
    };

    const socket = getSocket();
    // Fresh channel per effect pass — join() throws on reuse.
    const channels = ids.map((id) => {
      const channel = socket.channel(`workflows:run:${id}`);
      channel.on("run_event", () => {
        if (disposed) return;
        refetchSafely();
      });
      channel
        .join()
        .receive("ok", (reply: { id: string; status: string }) => {
          if (disposed) return;
          clearDegraded(id);
          // Refetch on ANY current-status↔reply mismatch: catches both a
          // terminal race and a plain stale list (PENDING vs "running").
          if (normalizeWireStatus(reply.status) !== currentStatusOf(id)) {
            refetchSafely();
          }
        })
        .receive("error", (resp?: { reason?: string }) => {
          if (disposed) return;
          // Never rejoin a refused run forever, and never leave it rendered
          // stale — not_found resolves itself on refetch.
          channel.leave();
          refetchSafely();
          if (resp?.reason === "unavailable") markDegraded(id);
        })
        .receive("timeout", () => {
          if (disposed) return;
          markDegraded(id);
        });
      return channel;
    });

    return () => {
      disposed = true;
      for (const channel of channels) channel.leave();
    };
  }, [activeKey, subEpoch, refetch]);

  const liveDegraded = transportStatus === "unavailable" || degradedIds.size > 0;

  function handleRetry() {
    retryConnect();
    bumpSubEpoch();
  }

  return (
    <div className="mx-auto max-w-2xl px-6 py-12">
      <h1 className="text-2xl font-semibold tracking-tight">Runs</h1>
      {liveDegraded && (
        <div className="mt-4 flex items-center justify-between rounded-lg border border-status-waiting/20 bg-status-waiting/7 px-3 py-2 text-sm text-status-waiting">
          <span>Live updates unavailable.</span>
          <button
            type="button"
            onClick={handleRetry}
            className="rounded-md border border-status-waiting/20 px-2 py-0.5 hover:bg-status-waiting/10"
          >
            Retry
          </button>
        </div>
      )}
      {loading && <p className="mt-4 text-sm text-muted-foreground">Loading runs…</p>}
      {error && (
        <p className="mt-4 text-sm text-destructive">Failed to load runs: {error.message}</p>
      )}
      {data && runs.length === 0 && (
        <p className="mt-4 text-sm text-muted-foreground">No runs yet.</p>
      )}
      {data && runs.length > 0 && (
        <ul className="mt-6 divide-y divide-border">
          {runs.map((run) => (
            <li key={run.id} className="py-3">
              <div className="font-medium">{run.name}</div>
              {isDoneWithFindings(run) ? (
                <div className="text-sm text-status-waiting">
                  {run.workflowType ?? "—"} · {deferredFindingsLabel(run.findingsDeferredCount)}
                </div>
              ) : (
                <div className="text-sm text-muted-foreground">
                  {run.workflowType ?? "—"} · {run.status.toLowerCase()}
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
