import { linkOptions, type LinkOptions } from "@tanstack/react-router";

// Nav config for both shell bars. linkOptions() validates every `to`
// against the generated route tree at the config site. Active matching
// includes search params by default, so every entry opts out
// (includeSearch: false — `/?mock=empty` must still mark Attention
// active); the index entry is additionally exact so `/` doesn't stay
// active on child routes.

export type ShellNavEntry = {
  id: string;
  label: string;
  link: LinkOptions;
  badge?: "attention" | "approvals";
};

export const RAIL_NAV: readonly ShellNavEntry[] = [
  {
    id: "attention",
    label: "Attention",
    badge: "attention",
    link: linkOptions({ to: "/", activeOptions: { exact: true, includeSearch: false } }),
  },
  {
    id: "approvals",
    label: "Approvals",
    badge: "approvals",
    link: linkOptions({ to: "/approvals", activeOptions: { includeSearch: false } }),
  },
  {
    id: "threads",
    label: "Threads",
    link: linkOptions({ to: "/threads", activeOptions: { includeSearch: false } }),
  },
  {
    id: "runs",
    label: "Runs",
    link: linkOptions({ to: "/runs", activeOptions: { includeSearch: false } }),
  },
  {
    id: "board",
    label: "Board",
    link: linkOptions({ to: "/board", activeOptions: { includeSearch: false } }),
  },
];

export const PHONE_TABS: readonly ShellNavEntry[] = [
  {
    id: "attention",
    label: "Attention",
    badge: "attention",
    link: linkOptions({ to: "/", activeOptions: { exact: true, includeSearch: false } }),
  },
  {
    id: "approvals",
    label: "Approvals",
    badge: "approvals",
    link: linkOptions({ to: "/approvals", activeOptions: { includeSearch: false } }),
  },
  {
    id: "threads",
    label: "Threads",
    link: linkOptions({ to: "/threads", activeOptions: { includeSearch: false } }),
  },
  {
    id: "projects",
    label: "Projects",
    link: linkOptions({ to: "/projects", activeOptions: { includeSearch: false } }),
  },
];
