import { type ReactNode, useEffect, useRef } from "react";
import { useApprovalsSummaryData } from "./approvals-data";
import {
  type ApprovalsStore,
  ApprovalsStoreContext,
  createApprovalsStore,
} from "./approvals-local-state";

// The root-mounted provider for the approvals local-state store — the ONLY
// export on purpose: a component-only module is a valid Fast Refresh
// boundary, so an HMR edit here never re-runs createContext under
// consumers' feet. The store, context, selectors, and consumer hooks live
// in approvals-local-state.ts (JSX-free — not a refresh boundary at all).
export function ApprovalsLocalStateProvider({ children }: { children: ReactNode }) {
  // Bootstrap is the seam, not a constant: the coordinator carries the WHOLE
  // source result — data flows into the monotonic acceptBaseline half,
  // transport status/refetch land beside it. The store seeds from the first
  // render's result (the preview fixture yields the version-1 baseline on
  // first render; a mocked undefined seam leaves NO accepted baseline, which
  // is what makes the no-baseline states real). Slice 1's summary operation
  // and mutation payloads flow through the same coordinator.
  const seamResult = useApprovalsSummaryData();
  const storeRef = useRef<ApprovalsStore | null>(null);
  storeRef.current ??= createApprovalsStore(seamResult);
  const store = storeRef.current;
  useEffect(() => {
    store.acceptSummaryResult(seamResult);
  }, [store, seamResult]);
  return <ApprovalsStoreContext.Provider value={store}>{children}</ApprovalsStoreContext.Provider>;
}
