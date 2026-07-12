import { defaultProjects, defaultRuns, type ProjectFixture, type RunFixture } from "./fixtures.ts";

export interface MockScenario {
  projects: ProjectFixture[];
  runs: RunFixture[];
  graphql: "ok" | "graphql-error" | "network-error";
  joins: "ok" | "unavailable";
  simulate: boolean;
}

export const SCENARIO_NAMES = [
  "default",
  "empty",
  "error-gql",
  "error-network",
  "degraded",
] as const;

export type ScenarioName = (typeof SCENARIO_NAMES)[number];

export function buildScenario(name: ScenarioName): MockScenario {
  switch (name) {
    case "default":
      return {
        projects: defaultProjects(),
        runs: defaultRuns(),
        graphql: "ok",
        joins: "ok",
        simulate: true,
      };
    case "empty":
      return { projects: [], runs: [], graphql: "ok", joins: "ok", simulate: false };
    case "error-gql":
      return { projects: [], runs: [], graphql: "graphql-error", joins: "ok", simulate: false };
    case "error-network":
      return { projects: [], runs: [], graphql: "network-error", joins: "ok", simulate: false };
    case "degraded":
      return {
        projects: defaultProjects(),
        runs: defaultRuns(),
        graphql: "ok",
        joins: "unavailable",
        simulate: false,
      };
  }
}

function requestedName(): string | undefined {
  if (typeof window !== "undefined") {
    const fromUrl = new URLSearchParams(window.location.search).get("mock");
    if (fromUrl) return fromUrl;
  }
  const fromEnv: string | undefined = import.meta.env.VITE_MOCK_SCENARIO;
  return fromEnv || undefined;
}

// A function, never top-level state: the URL and env are read only when a
// mock store is actually being built (dev server / vitest), so nothing here
// runs in a production bundle even if the module were retained.
export function resolveScenario(): MockScenario {
  const requested = requestedName();
  if (requested === undefined) return buildScenario("default");
  if ((SCENARIO_NAMES as readonly string[]).includes(requested)) {
    return buildScenario(requested as ScenarioName);
  }
  console.warn(`[argus mocks] unknown scenario "${requested}", falling back to "default"`);
  return buildScenario("default");
}
