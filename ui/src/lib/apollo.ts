import { ApolloClient, HttpLink, InMemoryCache } from "@apollo/client";
import { createMockLink } from "../mocks/link.ts";

// Same-origin /gql in every deployment (P3 serves the SPA from the gateway
// node); in dev the Vite proxy forwards it to the Phoenix endpoint. The API
// key comes from VITE_API_KEY (ui/.env.local, gitignored) at build time.
export function createApolloClient() {
  // MUST stay a bare inline identifier: __ARGUS_MOCKS_ALLOWED__ is a vite
  // define constant that is statically false in EVERY `vite build` — it
  // derives from the resolved command, never NODE_ENV, so exported
  // NODE_ENV/VITE_* cannot reopen it — and this branch plus the whole mocks
  // module graph behind createMockLink folds away (the
  // argus-mock-exclusion-guard plugin proves the fold on every build).
  // Under vitest it is a worker global, true; contract in
  // src/mocks-gate.d.ts.
  if (__ARGUS_MOCKS_ALLOWED__ && import.meta.env.VITE_MOCKS === "1") {
    return new ApolloClient({ link: createMockLink(), cache: new InMemoryCache() });
  }
  const apiKey: string | undefined = import.meta.env.VITE_API_KEY;
  return new ApolloClient({
    link: new HttpLink({
      uri: "/gql",
      headers: apiKey ? { "x-api-key": apiKey } : undefined,
    }),
    cache: new InMemoryCache(),
  });
}
