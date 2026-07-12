import { render, screen } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { expect, test } from "vite-plus/test";
import { createAppRouter } from "./router.tsx";

test("renders the Attention stub at /", async () => {
  const router = createAppRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);
  expect(await screen.findByRole("heading", { name: "Attention" })).toBeDefined();
  // Board has no phone tab by design: "/" must link to it so the route is
  // phone-reachable from the moment it exists.
  expect(screen.getByRole("link", { name: "View board" }).getAttribute("href")).toBe("/board");
});

test("resolves routes under the deployed /argus/ prefix", async () => {
  // The node-served shape: Vite base "/argus/" (import.meta.env.BASE_URL in
  // dev and build) with browser URLs carrying the prefix. Deep-link refresh
  // works only if the router strips the basepath before matching.
  const router = createAppRouter({
    basepath: "/argus/",
    history: createMemoryHistory({ initialEntries: ["/argus/"] }),
  });
  render(<RouterProvider router={router} />);
  expect(await screen.findByRole("heading", { name: "Attention" })).toBeDefined();
});
