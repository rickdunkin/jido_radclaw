import { expect, test } from "vite-plus/test";

// The machine guard for the components/system/ folder rule: presentational
// only — props in; may import types and pure derivations from lib/, never
// the use* data-seam hooks, never @apollo/client, never @/mocks. Enforced
// as an ALLOWLIST, not a hook-name denylist (a denylist admits the
// getAttentionData() fixture getter, @/hooks data hooks, and Apollo
// subpaths like @apollo/client/react).
//
// Rule order matters: forbidden sources reject FIRST — a type-only
// exemption applied first would wave `import type { ApolloClient } from
// "@apollo/client"` through. Only then the type-only exemption applies,
// and only for permitted sources; value imports are checked by IMPORTED
// (source-side) name so aliasing can't slip through. Growing the lib
// allowlist below is a deliberate, reviewed act.
//
// Bespoke statement-level import scanner, chosen explicitly: the installed
// TypeScript 7 devDep exposes only version metadata at its package root
// (compiler/AST APIs sit behind unstable subpath exports), so no
// conditional AST path — one deterministic parser, unit-tested in-file
// before the sweep.

const FORBIDDEN_PREFIXES = ["@apollo/client", "@/mocks"];
// Sources from which ANY import (type or value) is permitted.
const OPEN_SOURCES = { exact: ["react"], prefixes: ["@/components/ui/"] };
// @/lib/*: type-only imports are always permitted; VALUE imports only for
// these exact (source, imported-name) pairs.
const LIB_VALUE_ALLOWLIST: Record<string, readonly string[]> = {
  "@/lib/utils": ["cn"],
  "@/lib/attention-data": ["needsYou"],
};

type Specifier = { imported: string; typeOnly: boolean };
type ImportRecord = {
  source: string;
  form: "static" | "side-effect" | "dynamic" | "reexport";
  specifiers: Specifier[];
};

// --- scanner -------------------------------------------------------------

// Blank comments (preserving offsets) and record string/template spans so
// the statement matcher never fires on `import` inside a comment or string.
function stripComments(code: string): { stripped: string; inString: (i: number) => boolean } {
  const out = code.split("");
  const stringSpans: [number, number][] = [];
  let i = 0;
  while (i < code.length) {
    const two = code.slice(i, i + 2);
    if (two === "//") {
      const start = i;
      while (i < code.length && code[i] !== "\n") i += 1;
      for (let k = start; k < i; k += 1) out[k] = " ";
    } else if (two === "/*") {
      const start = i;
      i += 2;
      while (i < code.length && code.slice(i, i + 2) !== "*/") i += 1;
      i = Math.min(i + 2, code.length);
      for (let k = start; k < i; k += 1) if (out[k] !== "\n") out[k] = " ";
    } else if (code[i] === '"' || code[i] === "'" || code[i] === "`") {
      const quote = code[i];
      const start = i;
      i += 1;
      while (i < code.length) {
        if (code[i] === "\\") {
          i += 2;
        } else if (code[i] === quote) {
          i += 1;
          break;
        } else {
          i += 1;
        }
      }
      stringSpans.push([start, i]);
    } else {
      i += 1;
    }
  }
  return {
    stripped: out.join(""),
    inString: (pos) => stringSpans.some(([from, to]) => pos >= from && pos < to),
  };
}

function readStringLiteral(code: string, at: number): { value: string; end: number } | null {
  const quote = code[at];
  if (quote !== '"' && quote !== "'") return null;
  const close = code.indexOf(quote, at + 1);
  if (close === -1) return null;
  return { value: code.slice(at + 1, close), end: close + 1 };
}

function skipWs(code: string, at: number): number {
  let i = at;
  while (i < code.length && /\s/.test(code[i])) i += 1;
  return i;
}

// One import/export clause ("type A, { b, type C as D }", "* as ns") into
// source-side specifiers. `default` and `*` are synthetic imported names.
function parseClause(clause: string, statementTypeOnly: boolean): Specifier[] {
  const specifiers: Specifier[] = [];
  const braced = /\{([^}]*)\}/.exec(clause);
  const outside = clause.replace(/\{[^}]*\}/, "");
  const star = /\*\s*(?:as\s+[\w$]+)?/.exec(outside);
  if (star) specifiers.push({ imported: "*", typeOnly: statementTypeOnly });
  const defaultName = /(?:^|,)\s*([\w$]+)\s*(?:,|$)/.exec(outside.replace(/\*\s*as\s+[\w$]+/, ""));
  if (defaultName?.[1] !== undefined && defaultName[1] !== "type") {
    specifiers.push({ imported: "default", typeOnly: statementTypeOnly });
  }
  if (braced) {
    for (const raw of braced[1].split(",")) {
      const entry = raw.trim();
      if (entry === "") continue;
      const typed = /^type\s+/.test(entry);
      const name = entry
        .replace(/^type\s+/, "")
        .split(/\s+as\s+/)[0]
        .trim();
      if (name !== "") specifiers.push({ imported: name, typeOnly: statementTypeOnly || typed });
    }
  }
  return specifiers;
}

// All imports a module performs: static imports, side-effect imports,
// dynamic import(...) expressions, and export-from re-exports (which
// re-expose just like imports). Throws on a non-literal dynamic import —
// unanalyzable reach fails loudly rather than passing unscanned.
export function scanImports(code: string): ImportRecord[] {
  const { stripped, inString } = stripComments(code);
  const records: ImportRecord[] = [];
  const keyword = /\b(import|export)\b/g;
  for (let match = keyword.exec(stripped); match !== null; match = keyword.exec(stripped)) {
    if (inString(match.index)) continue;
    let i = skipWs(stripped, match.index + match[0].length);
    if (match[1] === "import") {
      if (stripped[i] === "(") {
        // dynamic import(...)
        i = skipWs(stripped, i + 1);
        const literal = readStringLiteral(stripped, i);
        if (!literal) throw new Error("non-literal dynamic import() — unanalyzable, refusing");
        records.push({ source: literal.value, form: "dynamic", specifiers: [] });
        continue;
      }
      const direct = readStringLiteral(stripped, i);
      if (direct) {
        records.push({ source: direct.value, form: "side-effect", specifiers: [] });
        continue;
      }
    }
    // Clause form: scan ahead (brace-aware) for `from "..."` at depth 0.
    // A local (from-less) export ends the search at the next `;` / `=`.
    let typeOnly = false;
    if (stripped.slice(i, i + 5) === "type " || stripped.slice(i, i + 5) === "type\n") {
      const after = skipWs(stripped, i + 4);
      if (stripped[after] === "{" || stripped[after] === "*" || /[\w$]/.test(stripped[after])) {
        typeOnly = true;
        i = after;
      }
    }
    const clauseStart = i;
    let depth = 0;
    let sourceValue: string | null = null;
    let clauseEnd = i;
    while (i < stripped.length) {
      const ch = stripped[i];
      if (ch === "{") depth += 1;
      if (ch === "}") depth -= 1;
      if (depth === 0 && (ch === ";" || (match[1] === "export" && ch === "="))) break;
      if (depth === 0 && stripped.startsWith("from", i) && !/[\w$]/.test(stripped[i - 1] ?? "")) {
        const at = skipWs(stripped, i + 4);
        const literal = readStringLiteral(stripped, at);
        if (literal) {
          clauseEnd = i;
          sourceValue = literal.value;
          break;
        }
      }
      i += 1;
    }
    if (sourceValue === null) continue; // local export / not an import form
    const clause = stripped.slice(clauseStart, clauseEnd).trim();
    records.push({
      source: sourceValue,
      form: match[1] === "export" ? "reexport" : "static",
      specifiers: parseClause(clause, typeOnly),
    });
  }
  return records;
}

// --- rules ---------------------------------------------------------------

function matchesPrefix(source: string, prefix: string): boolean {
  return source === prefix || source.startsWith(`${prefix}/`);
}

// null = permitted; string = violation description. Rule order matters —
// see the header comment.
export function checkImport(record: ImportRecord): string | null {
  const { source, form, specifiers } = record;
  for (const prefix of FORBIDDEN_PREFIXES) {
    if (matchesPrefix(source, prefix)) {
      return `forbidden source "${source}" (type-only included)`;
    }
  }
  const open =
    OPEN_SOURCES.exact.includes(source) ||
    OPEN_SOURCES.prefixes.some((prefix) => source.startsWith(prefix)) ||
    source.startsWith("./"); // relative SIBLINGS only — "../" escapes the scanned folder and falls through to the deny below
  if (open) return null;
  if (matchesPrefix(source, "@/lib")) {
    const allowlist = LIB_VALUE_ALLOWLIST[source] ?? [];
    if (form === "dynamic" || form === "side-effect") {
      return `value import of "${source}" (${form}) — lib modules allow only type imports and the named value allowlist`;
    }
    const badValue = specifiers.filter(
      (spec) => !spec.typeOnly && !allowlist.includes(spec.imported),
    );
    if (specifiers.length === 0) {
      return `value import of "${source}" with no named specifiers — nothing to allowlist-check`;
    }
    if (badValue.length > 0) {
      const names = badValue.map((spec) => spec.imported).join(", ");
      return `value import { ${names} } from "${source}" — not in the lib value allowlist`;
    }
    return null;
  }
  return `import from "${source}" — not a permitted source for components/system/`;
}

export function checkModule(code: string): string[] {
  return scanImports(code)
    .map(checkImport)
    .filter((violation): violation is string => violation !== null);
}

// --- parser unit tests (the scanner is proven before it guards) ----------

test("scanner: multiline named imports and mixed type/value specifiers", () => {
  const records = scanImports(
    `import {\n  type AttentionItem,\n  needsYou,\n} from "@/lib/attention-data";\nimport { type A, b } from "./sibling";`,
  );
  expect(records).toEqual([
    {
      source: "@/lib/attention-data",
      form: "static",
      specifiers: [
        { imported: "AttentionItem", typeOnly: true },
        { imported: "needsYou", typeOnly: false },
      ],
    },
    {
      source: "./sibling",
      form: "static",
      specifiers: [
        { imported: "A", typeOnly: true },
        { imported: "b", typeOnly: false },
      ],
    },
  ]);
});

test("scanner: default, namespace, side-effect, dynamic, and export-from forms", () => {
  const records = scanImports(
    `import React from "react";\nimport * as x from "@/lib/utils";\nimport "./styles.css";\nconst m = await import("@/mocks/scenarios");\nexport { FeedRow } from "./feed-row";\nexport type { Tone } from "./group-panel";\nexport * from "./meta-line";`,
  );
  expect(records).toEqual([
    { source: "react", form: "static", specifiers: [{ imported: "default", typeOnly: false }] },
    { source: "@/lib/utils", form: "static", specifiers: [{ imported: "*", typeOnly: false }] },
    { source: "./styles.css", form: "side-effect", specifiers: [] },
    { source: "@/mocks/scenarios", form: "dynamic", specifiers: [] },
    {
      source: "./feed-row",
      form: "reexport",
      specifiers: [{ imported: "FeedRow", typeOnly: false }],
    },
    {
      source: "./group-panel",
      form: "reexport",
      specifiers: [{ imported: "Tone", typeOnly: true }],
    },
    { source: "./meta-line", form: "reexport", specifiers: [{ imported: "*", typeOnly: false }] },
  ]);
});

test("scanner: import/export inside comments and strings never match; local exports skipped", () => {
  const records = scanImports(
    `// import { useQuery } from "@apollo/client";\n/* export { x } from "@/mocks" */\nconst s = 'import fake from "@/mocks"';\nexport function StatusDot() {\n  return s;\n}\nexport const t = \`import also fake from "@apollo/client"\`;`,
  );
  expect(records).toEqual([]);
});

test("scanner: whole-statement import type marks every specifier type-only", () => {
  const records = scanImports(`import type { ApolloClient } from "@apollo/client";`);
  expect(records).toEqual([
    {
      source: "@apollo/client",
      form: "static",
      specifiers: [{ imported: "ApolloClient", typeOnly: true }],
    },
  ]);
});

test("scanner: non-literal dynamic import refuses loudly", () => {
  expect(() => scanImports(`const path = "@/mocks"; await import(path);`)).toThrow(/non-literal/);
});

// --- rule unit tests ------------------------------------------------------

function verdicts(code: string): string[] {
  return checkModule(code);
}

test("rules: semantic positives pass", () => {
  expect(verdicts(`import { useId } from "react";`)).toEqual([]);
  expect(verdicts(`import type { AttentionItem } from "@/lib/attention-data";`)).toEqual([]);
  expect(verdicts(`import { type AttentionItem, needsYou } from "@/lib/attention-data";`)).toEqual(
    [],
  );
  expect(verdicts(`import { cn } from "@/lib/utils";`)).toEqual([]);
  expect(verdicts(`import { Badge } from "@/components/ui/badge";`)).toEqual([]);
  expect(verdicts(`import { MetaLine } from "./meta-line";`)).toEqual([]);
});

test("rules: forbidden sources reject first — type-only does NOT exempt them", () => {
  expect(verdicts(`import { useQuery } from "@apollo/client/react";`)).toHaveLength(1);
  expect(verdicts(`import type { ApolloClient } from "@apollo/client";`)).toHaveLength(1);
  expect(verdicts(`import { scenario } from "@/mocks/scenarios";`)).toHaveLength(1);
});

test("rules: lib value imports check the IMPORTED name — aliasing can't slip through", () => {
  expect(verdicts(`import { useShellData as data } from "@/lib/shell-data";`)).toHaveLength(1);
  expect(verdicts(`import { getAttentionData } from "@/lib/attention-data";`)).toHaveLength(1);
  expect(verdicts(`import { needsYou as cn } from "@/lib/attention-data";`)).toEqual([]);
  expect(verdicts(`import { cn } from "@/lib/attention-data";`)).toHaveLength(1);
});

test("rules: default/namespace/dynamic/side-effect lib reach and non-permitted sources fail", () => {
  expect(verdicts(`import utils from "@/lib/utils";`)).toHaveLength(1);
  expect(verdicts(`import * as x from "@/lib/utils";`)).toHaveLength(1);
  expect(verdicts(`const m = await import("@/lib/utils");`)).toHaveLength(1);
  expect(verdicts(`import "@/lib/utils";`)).toHaveLength(1);
  expect(verdicts(`import { useShellData } from "@/hooks/shell";`)).toHaveLength(1);
  expect(verdicts(`import { NodeHealth } from "../node-health";`)).toHaveLength(1);
  expect(verdicts(`export { getAttentionData } from "@/lib/attention-data";`)).toHaveLength(1);
});

// --- the sweep ------------------------------------------------------------

test("every file under components/system/ passes the boundary", () => {
  // Raw-source glob, RECURSIVE by pattern — top-level-only globbing would
  // let a permitted relative import reach an unscanned system/data.ts.
  // Self-maintaining: new files join the sweep with no test edit.
  const modules = import.meta.glob("/src/components/system/**/*.{ts,tsx}", {
    query: "?raw",
    import: "default",
    eager: true,
  }) as Record<string, string>;
  const files = Object.keys(modules).sort();
  expect(files.length).toBeGreaterThan(0);
  const violations = files.flatMap((name) =>
    checkModule(modules[name]).map((violation) => `${name}: ${violation}`),
  );
  expect(violations).toEqual([]);
});
