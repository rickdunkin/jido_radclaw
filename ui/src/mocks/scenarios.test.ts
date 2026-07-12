import { afterEach, expect, test, vi } from "vite-plus/test";
import { resolveScenario } from "./scenarios.ts";

const originalUrl = window.location.href;

afterEach(() => {
  history.replaceState(null, "", originalUrl);
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

test("no URL param and no env resolves the default scenario", () => {
  // Hermetic against an inherited shell VITE_MOCK_SCENARIO.
  vi.stubEnv("VITE_MOCK_SCENARIO", "");

  const scenario = resolveScenario();

  expect(scenario.simulate).toBe(true);
  expect(scenario.graphql).toBe("ok");
  expect(scenario.runs.length).toBeGreaterThan(0);
});

test("VITE_MOCK_SCENARIO applies when no ?mock= param is present", () => {
  vi.stubEnv("VITE_MOCK_SCENARIO", "degraded");

  const scenario = resolveScenario();

  expect(scenario.joins).toBe("unavailable");
  expect(scenario.simulate).toBe(false);
});

test("?mock= beats VITE_MOCK_SCENARIO", () => {
  vi.stubEnv("VITE_MOCK_SCENARIO", "degraded");
  history.replaceState(null, "", "/?mock=empty");

  const scenario = resolveScenario();

  expect(scenario.runs).toEqual([]);
  expect(scenario.projects).toEqual([]);
  expect(scenario.joins).toBe("ok");
});

test("an unknown name warns and falls back to default (never the env value)", () => {
  const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.stubEnv("VITE_MOCK_SCENARIO", "empty");
  history.replaceState(null, "", "/?mock=bogus");

  const scenario = resolveScenario();

  expect(warn).toHaveBeenCalledTimes(1);
  expect(String(warn.mock.calls[0][0])).toContain("bogus");
  // Default, not the env-named "empty" scenario.
  expect(scenario.simulate).toBe(true);
  expect(scenario.runs.length).toBeGreaterThan(0);
});
