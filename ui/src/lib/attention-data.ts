// The Attention feed's data seam: static fixture data today, swapped for
// real queries in slice 1 without touching the feed components — the
// useShellData() precedent from shell-data.ts. The screen is honest about
// this: it renders an explicit "preview · sample data" marker (see
// routes/_shell/index.tsx) because src/lib fixtures SHIP in any build (the
// mock-exclusion guard only covers src/mocks/**).
//
// Meta lines are stored as fixture-exact segment arrays, not composed by
// rules: the mock's meta composition is editorial (which segments appear,
// and in what order, differs per item), so the fixture IS the copy. Where
// the 2a/5a/5e mock phrasings differ, titles are unified per the plan's
// fixture table (desk copy wins, except the idle cluster's deliberately
// shorter phone phrasing).

import type { ShellNode } from "./shell-data";

export type AttentionAction = Readonly<{
  /** Arrow included, e.g. "Open gate →". */
  label: string;
  emphasis: "solid" | "outline";
}>;

type ItemBase = Readonly<{
  id: string;
  title: string;
  /** Grouping key for the by-project view; "infra" is a pseudo-project. */
  project: string;
  /** Phone meta line = [project?, ...phoneMeta, age].join(" · "). */
  phoneMeta: readonly string[];
  /** Wide meta line = [project?, ...deskMeta].join(" · ") — age moves to the trailing slot. */
  deskMeta: readonly string[];
  /** Preformatted "4m" / "1h" — no timestamps exist this phase. */
  age: string;
}>;

export type NeedsYouItem = ItemBase &
  Readonly<{ kind: "gate" | "question" | "alert"; action: AttentionAction }>;
export type FailedItem = ItemBase & Readonly<{ kind: "failed" }>;
export type DoneItem = ItemBase & Readonly<{ kind: "done" }>;
export type IdleClusterItem = ItemBase & Readonly<{ kind: "idle"; count: number }>;
export type ResolvedItem = ItemBase & Readonly<{ kind: "resolved"; titleCode?: string }>;
export type AttentionItem = NeedsYouItem | FailedItem | DoneItem | IdleClusterItem | ResolvedItem;

export type AttentionData = Readonly<{
  /** Working threads are NOT feed rows — the count is a scalar. */
  workingCount: number;
  /**
   * SPARSE per-project slice of the working threads (lookups type
   * number | undefined; consumers normalize with `?? 0`). Deliberately
   * ≠ Σ workingCount — the mock only attributes quill's two threads.
   */
  workingByProject: Readonly<Partial<Record<string, number>>>;
  /** Priority order — components never re-sort. */
  items: readonly AttentionItem[];
}>;

function deepFreeze<T>(value: T): T {
  if (typeof value === "object" && value !== null) {
    for (const nested of Object.values(value)) deepFreeze(nested);
    Object.freeze(value);
  }
  return value;
}

const ATTENTION_DATA: AttentionData = deepFreeze({
  workingCount: 3,
  workingByProject: { quill: 2 },
  items: [
    {
      id: "gate-export",
      kind: "gate",
      title: "Plan review — migrate export pipeline to streaming",
      project: "quill",
      phoneMeta: ["export-pipeline", "atlas"],
      deskMeta: ["thread export-pipeline", "atlas", "run #7 step 3/5"],
      age: "4m",
      action: { label: "Open gate →", emphasis: "solid" },
    },
    {
      id: "q-webhook",
      kind: "question",
      title: "“Webhook auth: HMAC per endpoint, or one shared signing key?”",
      project: "helios-api",
      phoneMeta: ["webhook-endpoints", "wren"],
      deskMeta: ["thread webhook-endpoints", "wren"],
      age: "12m",
      action: { label: "Reply →", emphasis: "outline" },
    },
    {
      id: "alert-cred",
      kind: "alert",
      title: "API credential expired on basalt — 2 threads paused",
      project: "infra",
      phoneMeta: ["basalt"],
      deskMeta: ["basalt"],
      age: "31m",
      action: { label: "Details →", emphasis: "outline" },
    },
    {
      id: "fail-e2e",
      kind: "failed",
      title: "Run failed — e2e suite timed out at step 4/6",
      project: "terrarium",
      phoneMeta: ["nightly-e2e #212"],
      deskMeta: ["nightly-e2e #212", "wren — created T-222"],
      age: "1h",
    },
    {
      id: "done-pr142",
      kind: "done",
      title: "Finished — attention-feed virtualization · PR #142 opened",
      project: "argus",
      phoneMeta: ["attn-feed"],
      deskMeta: ["attn-feed", "atlas"],
      age: "26m",
    },
    {
      id: "idle-cron",
      kind: "idle",
      title: "Cron ticks skipped — basalt offline",
      project: "terrarium",
      phoneMeta: ["sensor-sync"],
      deskMeta: ["sensor-sync"],
      age: "2h",
      count: 12,
    },
    {
      id: "res-merge",
      kind: "resolved",
      title: "Approved —",
      project: "quill",
      phoneMeta: ["export-pipeline"],
      deskMeta: ["export-pipeline"],
      age: "3h",
      titleCode: "gh pr merge --squash",
    },
  ],
});

/** Non-hook getter for tests and pure code (rules-of-hooks is name-based). */
export function getAttentionData(): AttentionData {
  return ATTENTION_DATA;
}

/** Hook-named seam for components — the live-data swap point. */
export function useAttentionData(): AttentionData {
  return ATTENTION_DATA;
}

export function needsYou(item: AttentionItem): item is NeedsYouItem {
  return item.kind === "gate" || item.kind === "question" || item.kind === "alert";
}

/** Shared terminal predicate: done OR resolved (both roll a project up quiet). */
export function terminal(item: AttentionItem): boolean {
  return item.kind === "done" || item.kind === "resolved";
}

export type AttentionSummary = Readonly<{
  working: number;
  waitingOnYou: number;
  failed: number;
  offlineNodes: readonly string[];
}>;

/**
 * The single count source for the screen: `working` is the scalar (working
 * threads aren't feed rows), `waitingOnYou`/`failed` derive from the items,
 * and `offlineNodes` from the passed shell nodes. No literals in components.
 */
export function deriveAttentionSummary(
  data: AttentionData,
  nodes: readonly ShellNode[],
): AttentionSummary {
  return {
    working: data.workingCount,
    waitingOnYou: data.items.filter(needsYou).length,
    failed: data.items.filter((item) => item.kind === "failed").length,
    offlineNodes: nodes.filter((node) => !node.online).map((node) => node.name),
  };
}

export type ProjectGroup = Readonly<{
  project: string;
  /** Needs-you items hoisted to the front; source order preserved otherwise. */
  items: readonly AttentionItem[];
  tone: "amber" | "neutral";
  /** Every item terminal — the group rolls up to a single quiet line. */
  quiet: boolean;
  needsYouCount: number;
  /** workingByProject[project] ?? 0 — render the span only when > 0. */
  workingCount: number;
  failedCount: number;
  /**
   * Present iff quiet. The verb comes from the FIRST terminal item in
   * source order — items are priority-ordered and carry no timestamps this
   * phase, so "first", not "newest", is the defined rule: done → "finished",
   * resolved → "resolved".
   */
  quietLine?: Readonly<{ verb: "finished" | "resolved"; age: string }>;
}>;

/**
 * Groups items by project in first-appearance order, then bands the groups
 * amber → non-quiet neutral → quiet (stable within each band) — exactly the
 * 5e panel order for the public fixture.
 */
export function groupByProject(data: AttentionData): ProjectGroup[] {
  const projects: string[] = [];
  const itemsByProject = new Map<string, AttentionItem[]>();
  for (const item of data.items) {
    const bucket = itemsByProject.get(item.project);
    if (bucket) {
      bucket.push(item);
    } else {
      projects.push(item.project);
      itemsByProject.set(item.project, [item]);
    }
  }

  const groups = projects.map((project): ProjectGroup => {
    const items = itemsByProject.get(project) ?? [];
    const needsYouItems = items.filter(needsYou);
    const quiet = items.every(terminal);
    const firstTerminal = items.find(terminal);
    return {
      project,
      items: [...needsYouItems, ...items.filter((item) => !needsYou(item))],
      tone: needsYouItems.length > 0 ? "amber" : "neutral",
      quiet,
      needsYouCount: needsYouItems.length,
      workingCount: data.workingByProject[project] ?? 0,
      failedCount: items.filter((item) => item.kind === "failed").length,
      ...(quiet && firstTerminal
        ? {
            quietLine: {
              verb: firstTerminal.kind === "done" ? ("finished" as const) : ("resolved" as const),
              age: firstTerminal.age,
            },
          }
        : {}),
    };
  });

  const band = (group: ProjectGroup) => (group.tone === "amber" ? 0 : group.quiet ? 2 : 1);
  return groups.sort((a, b) => band(a) - band(b));
}
