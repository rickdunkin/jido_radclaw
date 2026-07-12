import { MockedProvider } from "@apollo/client/testing/react";
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { afterEach, expect, test } from "vite-plus/test";
import { SidebarProvider, useSidebar } from "@/components/ui/sidebar";
import { ProjectsDocument } from "./gql/graphql.ts";
import { createAppRouter } from "./router.tsx";

// The /projects active-state case renders a route that fires useQuery on
// mount — a provider-less render would throw before the shell could be
// inspected. /runs is never rendered here, so no socket mock is needed.
const projectsMock = {
  request: { query: ProjectsDocument, variables: { limit: 50 } },
  result: { data: { projects: [] } },
};

function renderAt(path: string, basepath?: string) {
  const router = createAppRouter({
    basepath,
    history: createMemoryHistory({ initialEntries: [path] }),
  });
  render(
    <MockedProvider mocks={[projectsMock]}>
      <RouterProvider router={router} />
    </MockedProvider>,
  );
  return router;
}

// Sibling landmark scopes: railNav covers only the nav group — brand,
// PROJECTS, and the node footer are sibling regions under the sidebar slot.
function shellScopes() {
  const sidebar = document.querySelector<HTMLElement>('[data-slot="sidebar"]');
  if (!sidebar) throw new Error("shell sidebar not rendered");
  const projectsGroup = screen
    .getByText("PROJECTS")
    .closest<HTMLElement>('[data-slot="sidebar-group"]');
  if (!projectsGroup) throw new Error("PROJECTS group not rendered");
  return {
    sidebar,
    projectsGroup,
    railNav: screen.getByRole("navigation", { name: "Main" }),
    tabBar: screen.getByRole("navigation", { name: "Primary" }),
  };
}

async function settle() {
  await screen.findByRole("navigation", { name: "Main" });
}

afterEach(() => {
  cleanup();
});

test("responsive switch is CSS-only: rail hidden below md, tab bar hidden at md+", async () => {
  renderAt("/");
  await settle();
  const { sidebar, tabBar } = shellScopes();

  // happy-dom applies no media queries — assert the classes, never layout.
  expect(sidebar.classList.contains("hidden")).toBe(true);
  expect(sidebar.classList.contains("md:flex")).toBe(true);
  expect(tabBar.classList.contains("md:hidden")).toBe(true);
});

test("rail renders brand, seam-fed nav, honest PROJECTS rows, and list semantics", async () => {
  renderAt("/");
  await settle();
  const { sidebar, railNav, projectsGroup } = shellScopes();

  // Nav names include badge/sr-only text; the ◆ glyph is aria-hidden and
  // absent from the Runs name.
  for (const name of ["Attention 3", "Approvals 3", "Threads", "Runs 2 runs at gates", "Board"]) {
    expect(within(railNav).getByRole("link", { name })).toBeDefined();
  }

  // Fixture rows are static text: no link/button roles, exactly one link
  // in the whole group (the honest path to /projects), no focusable +.
  for (const name of ["argus", "helios-api", "quill", "terrarium"]) {
    expect(within(projectsGroup).getByText(name)).toBeDefined();
  }
  const projectLinks = within(projectsGroup).getAllByRole("link");
  expect(projectLinks).toHaveLength(1);
  expect(projectLinks[0].textContent).toBe("All projects");
  expect(within(projectsGroup).queryAllByRole("button")).toHaveLength(0);
  const plusTile = within(projectsGroup).getByText("+");
  expect(plusTile.tagName).toBe("SPAN");
  expect(plusTile.getAttribute("aria-hidden")).toBe("true");

  expect(within(sidebar).getByRole("link", { name: "Homepage" })).toBeDefined();

  // list-style: none strips list semantics in Safari/VoiceOver — every
  // shell menu carries the explicit role.
  const menus = sidebar.querySelectorAll('[data-slot="sidebar-menu"]');
  expect(menus.length).toBe(2);
  for (const menu of Array.from(menus)) {
    expect(menu.getAttribute("role")).toBe("list");
  }
});

// Every navigation control, by destination — a link pointing at the wrong
// valid route passes name-only tests. Scope keys resolve at assert time.
const HREF_TABLE = [
  { scope: "railNav", name: "Attention 3", href: "/" },
  { scope: "railNav", name: "Approvals 3", href: "/approvals" },
  { scope: "railNav", name: "Threads", href: "/threads" },
  { scope: "railNav", name: "Runs 2 runs at gates", href: "/runs" },
  { scope: "railNav", name: "Board", href: "/board" },
  { scope: "projectsGroup", name: "All projects", href: "/projects" },
  { scope: "sidebar", name: "Homepage", href: "/" },
  { scope: "tabBar", name: "Attention 3", href: "/" },
  { scope: "tabBar", name: "Approvals 3", href: "/approvals" },
  { scope: "tabBar", name: "Threads", href: "/threads" },
  { scope: "tabBar", name: "Projects", href: "/projects" },
  { scope: "main", name: "View runs", href: "/runs" },
  { scope: "main", name: "View projects", href: "/projects" },
  { scope: "main", name: "View board", href: "/board" },
  { scope: "main", name: "Styleguide", href: "/styleguide" },
] as const;

function assertHrefs(expected: (href: string) => string) {
  const scopes = { ...shellScopes(), main: screen.getByRole("main") };
  for (const row of HREF_TABLE) {
    const link = within(scopes[row.scope]).getByRole("link", { name: row.name });
    expect(link.getAttribute("href"), `${row.scope} → ${row.name}`).toBe(expected(row.href));
  }
}

test("every navigation control points at its declared destination", async () => {
  renderAt("/");
  await settle();
  assertHrefs((href) => href);
});

test("every navigation control carries the /argus/ prefix under the deployed basepath", async () => {
  renderAt("/argus/", "/argus/");
  await settle();
  // The router renders the bare basepath with its trailing slash ("/argus/"
  // for the index), and joins child paths slash-less.
  assertHrefs((href) => (href === "/" ? "/argus/" : `/argus${href}`));
});

test("node footer renders proven rows: two online, basalt offline with visible meta", async () => {
  renderAt("/");
  await settle();
  const { sidebar } = shellScopes();

  const atlasRow = within(sidebar).getByText("atlas").closest("li");
  const wrenRow = within(sidebar).getByText("wren").closest("li");
  const basaltRow = within(sidebar).getByText("basalt").closest("li");
  if (!atlasRow || !wrenRow || !basaltRow) throw new Error("node rows not rendered");

  expect(within(atlasRow).getByText("desk")).toBeDefined();
  expect(within(atlasRow).getByText("online")).toBeDefined();
  expect(within(wrenRow).getByText("laptop")).toBeDefined();
  expect(within(wrenRow).getByText("online")).toBeDefined();
  // Offline is conveyed by visible text, not sr-only copy.
  expect(within(basaltRow).getByText("offline 2h")).toBeDefined();
  expect(within(basaltRow).queryByText("online")).toBeNull();
  expect(within(sidebar).getAllByText("online")).toHaveLength(2);
});

test("tab bar carries exactly the four phone tabs — no Runs, no Board", async () => {
  renderAt("/");
  await settle();
  const { tabBar } = shellScopes();

  for (const name of ["Attention 3", "Approvals 3", "Threads", "Projects"]) {
    expect(within(tabBar).getByRole("link", { name })).toBeDefined();
  }
  expect(within(tabBar).getAllByRole("link")).toHaveLength(4);
  expect(within(tabBar).queryByRole("link", { name: /Runs/ })).toBeNull();
  expect(within(tabBar).queryByRole("link", { name: /Board/ })).toBeNull();
});

function currentOf(scope: HTMLElement, name: string): string | null {
  return within(scope).getByRole("link", { name }).getAttribute("aria-current");
}

test("active state: exact index matching in both bars, brand included", async () => {
  const router = renderAt("/");
  await settle();
  const { sidebar, railNav, tabBar } = shellScopes();

  expect(currentOf(railNav, "Attention 3")).toBe("page");
  expect(currentOf(tabBar, "Attention 3")).toBe("page");
  expect(currentOf(sidebar, "Homepage")).toBe("page");
  expect(currentOf(railNav, "Approvals 3")).toBeNull();
  expect(currentOf(tabBar, "Approvals 3")).toBeNull();

  await act(async () => {
    await router.navigate({ to: "/approvals" });
  });

  expect(currentOf(railNav, "Approvals 3")).toBe("page");
  expect(currentOf(tabBar, "Approvals 3")).toBe("page");
  // Attention's exact guard — and the brand link's own — release off "/".
  expect(currentOf(railNav, "Attention 3")).toBeNull();
  expect(currentOf(tabBar, "Attention 3")).toBeNull();
  expect(currentOf(sidebar, "Homepage")).toBeNull();
});

test("search params never deactivate a tab: /?mock=empty keeps Attention active", async () => {
  // The real dev:mock URL shape — the includeSearch: false guard on the
  // exact-matched index link is load-bearing here.
  renderAt("/?mock=empty");
  await settle();
  const { railNav, tabBar } = shellScopes();

  expect(currentOf(railNav, "Attention 3")).toBe("page");
  expect(currentOf(tabBar, "Attention 3")).toBe("page");
});

test("on /projects only the Projects tab and the All projects row are current", async () => {
  renderAt("/projects");
  await screen.findByRole("heading", { name: "Projects" });
  const { sidebar, railNav, tabBar, projectsGroup } = shellScopes();

  expect(currentOf(tabBar, "Projects")).toBe("page");
  const allProjects = within(projectsGroup).getByRole("link", { name: "All projects" });
  expect(allProjects.getAttribute("aria-current")).toBe("page");
  // The generated button styles key off data-active (never set) — the
  // desktop current-page indicator must ride the link's own data-status.
  expect(allProjects.getAttribute("data-status")).toBe("active");
  expect(allProjects.className).toContain("data-[status=active]:bg-sidebar-accent");

  for (const link of within(railNav).getAllByRole("link")) {
    expect(link.getAttribute("aria-current")).toBeNull();
  }
  expect(currentOf(sidebar, "Homepage")).toBeNull();
});

test("stub routes render inside the shell; /styleguide stays out of nav", async () => {
  const routes = [
    { path: "/", heading: "Attention" },
    { path: "/approvals", heading: "Approvals" },
    { path: "/threads", heading: "Threads" },
    { path: "/board", heading: "Board" },
    { path: "/styleguide", heading: "argus" },
  ];
  for (const route of routes) {
    renderAt(route.path);
    expect(await screen.findByRole("heading", { name: route.heading })).toBeDefined();
    expect(document.querySelector('[data-slot="sidebar"]')).not.toBeNull();
    if (route.path === "/") {
      // Temporary reachability list on the Attention stub (phone access to
      // /runs and /board, /styleguide discoverability).
      for (const name of ["View runs", "View projects", "View board", "Styleguide"]) {
        expect(screen.getByRole("link", { name })).toBeDefined();
      }
    }
    cleanup();
  }
});

test("deep links resolve under the deployed /argus/ prefix inside the shell", async () => {
  renderAt("/argus/approvals", "/argus/");
  expect(await screen.findByRole("heading", { name: "Approvals" })).toBeDefined();
  expect(document.querySelector('[data-slot="sidebar"]')).not.toBeNull();
});

// Guards the local registry edit in components/ui/sidebar.tsx: a registry
// re-add would silently restore the global Cmd/Ctrl+B toggle and the
// sidebar_state cookie write. Two INDEPENDENT probes — the keydown path
// alone never exercises setOpen, so a restored cookie write needs (b).
test("sidebar strip guard: no keyboard shortcut, no state cookie", async () => {
  renderAt("/");
  await settle();

  // (a) A restored shortcut handler would preventDefault on Cmd/Ctrl+B;
  // fireEvent returns false when a handler cancels the event.
  expect(fireEvent.keyDown(window, { key: "b", metaKey: true, cancelable: true })).toBe(true);
  expect(fireEvent.keyDown(window, { key: "b", ctrlKey: true, cancelable: true })).toBe(true);

  // (b) Drive setOpen directly under a bare provider: a restored cookie
  // write would land in document.cookie.
  function CookieProbe() {
    const { setOpen } = useSidebar();
    return (
      <button type="button" onClick={() => setOpen(false)}>
        strip-probe
      </button>
    );
  }
  render(
    <SidebarProvider>
      <CookieProbe />
    </SidebarProvider>,
  );
  fireEvent.click(screen.getByRole("button", { name: "strip-probe" }));
  expect(document.cookie).not.toContain("sidebar_state");
});
