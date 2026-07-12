import { ApolloClient, HttpLink, InMemoryCache } from "@apollo/client";

// Same-origin /gql in every deployment (P3 serves the SPA from the gateway
// node); in dev the Vite proxy forwards it to the Phoenix endpoint. The API
// key comes from VITE_API_KEY (ui/.env.local, gitignored) at build time.
export function createApolloClient() {
  const apiKey: string | undefined = import.meta.env.VITE_API_KEY;
  return new ApolloClient({
    link: new HttpLink({
      uri: "/gql",
      headers: apiKey ? { "x-api-key": apiKey } : undefined,
    }),
    cache: new InMemoryCache(),
  });
}
