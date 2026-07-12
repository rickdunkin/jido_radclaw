import { SchemaLink } from "@apollo/client/link/schema";
import { buildSchema, GraphQLError, type GraphQLSchema } from "graphql";
import sdl from "../../schema.graphql?raw";
import { getSharedStore, type MockStore } from "./store.ts";

// Apollo SchemaLink executing real query documents against the committed SDL
// golden (ui/schema.graphql) — schema drift fails loudly instead of fixtures
// silently diverging from the contract. validate: true gives real validation
// errors for malformed documents.

// Lazy + memoized: buildSchema at module top level would defeat DCE.
let schema: GraphQLSchema | null = null;

function getSchema(): GraphQLSchema {
  return (schema ??= buildSchema(sdl));
}

// Ash limit contract (the read actions' argument): the default applies only
// when the arg is ABSENT; explicit null and out-of-range are honest
// validation errors, never a silent clamp.
function checkLimit(limit: number | null | undefined): number {
  if (limit === undefined) return 50;
  if (limit === null || limit < 1 || limit > 200) {
    throw new GraphQLError("limit: must be between 1 and 200");
  }
  return limit;
}

export function createMockLink(store: MockStore = getSharedStore()): SchemaLink {
  const failIfGqlError = (): void => {
    if (store.behavior.graphql === "graphql-error") {
      throw new GraphQLError("mock: scenario-forced GraphQL error");
    }
  };
  return new SchemaLink({
    schema: getSchema(),
    validate: true,
    // graphql-js defaultFieldResolver calls rootValue.<field>(args, context,
    // info) — NOT the 4-arg makeExecutableSchema shape. SchemaLink types
    // rootValue as `any`, so the params get no contextual type and must be
    // annotated explicitly.
    rootValue: {
      projects: (args: { limit?: number | null }) => {
        failIfGqlError();
        return store.listProjectsAlphabetical(checkLimit(args.limit));
      },
      recentWorkflowRuns: (args: { limit?: number | null }) => {
        failIfGqlError();
        return store.listRecentRuns(checkLimit(args.limit));
      },
      project: (args: { id: string }) => {
        failIfGqlError();
        return store.getProject(args.id);
      },
      workflowRun: (args: { id: string }) => {
        failIfGqlError();
        return store.getRun(args.id);
      },
    },
    // A throw here rejects through Apollo's link (network) error channel —
    // distinct from a resolver throw, which lands in the GraphQL errors.
    context: () => {
      if (store.behavior.graphql === "network-error") {
        throw new Error("mock: gateway unreachable");
      }
      return {};
    },
  });
}
