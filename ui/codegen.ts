import type { CodegenConfig } from "@graphql-codegen/cli";

// Types are generated from the committed SDL golden (ui/schema.graphql, written
// by `mix jidoclaw.graphql.schema`), never from a live endpoint — the golden is
// the client/server contract, and precommit's drift check keeps it honest.
const config: CodegenConfig = {
  overwrite: true,
  schema: "./schema.graphql",
  documents: ["src/**/*.graphql"],
  generates: {
    "./src/gql/graphql.ts": {
      // typescript-operations v6 is self-contained: it emits the scalars,
      // helpers, and every operation-used enum itself, and has no way to
      // reference an external enum declaration — pairing it with the base
      // `typescript` plugin double-declares any enum a document selects.
      plugins: ["typescript-operations", "typed-document-node"],
      config: {
        // Emit `import type` for TypedDocumentNode — its package is types-only
        // (no runtime entry), so a value import breaks Vite's resolver.
        useTypeImports: true,
        // TS `enum` is not erasable syntax (tsconfig erasableSyntaxOnly);
        // `as const` objects keep runtime value iteration and erase cleanly.
        enumType: "const",
        avoidOptionals: { field: true, inputValue: false },
        defaultScalarType: "unknown",
        nonOptionalTypename: true,
        skipTypeNameForRoot: true,
        scalars: {
          // ISO8601 with UTC "Z" per the DateTime scalar's SDL docblock.
          DateTime: "string",
        },
      },
    },
  },
};

export default config;
