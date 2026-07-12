import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";
import { ApolloProvider } from "@apollo/client/react";
import { RouterProvider } from "@tanstack/react-router";
import { createApolloClient } from "./lib/apollo.ts";
import { createAppRouter } from "./router.tsx";

const apolloClient = createApolloClient();
const router = createAppRouter();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ApolloProvider client={apolloClient}>
      <RouterProvider router={router} />
    </ApolloProvider>
  </StrictMode>,
);
