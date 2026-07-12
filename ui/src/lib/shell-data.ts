// The shell's data seam: static fixtures today, swapped for real queries in
// later phases (AWAITING_APPROVAL runs are already queryable for the future
// Runs count) without touching the consumers in app-sidebar / tab-bar.

export type ShellNode = {
  name: string;
  meta: string;
  online: boolean;
};

export type ShellData = {
  attentionCount: number;
  approvalsCount: number;
  runsAtGates: number;
  projects: string[];
  nodes: ShellNode[];
};

const SHELL_DATA: ShellData = {
  attentionCount: 3,
  approvalsCount: 3,
  runsAtGates: 2,
  projects: ["argus", "helios-api", "quill", "terrarium"],
  nodes: [
    { name: "atlas", meta: "desk", online: true },
    { name: "wren", meta: "laptop", online: true },
    { name: "basalt", meta: "offline 2h", online: false },
  ],
};

export function useShellData(): ShellData {
  return SHELL_DATA;
}
