import { createRouter, type RouterHistory } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen.ts";

export function createAppRouter(opts?: { history?: RouterHistory; basepath?: string }) {
  // basepath tracks Vite's base: "/argus/" in dev and build, "/" under
  // vitest — so tests exercise unprefixed routes unchanged, and the
  // deployed-prefix test injects the real value explicitly.
  return createRouter({
    routeTree,
    basepath: import.meta.env.BASE_URL,
    ...opts,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof createAppRouter>;
  }
}
