export const meta = {
  name: 'doc-reconcile',
  description: 'Verify docs against current source in parallel, apply corrections, merge one report',
  whenToUse:
    'Reconciling exploration/architecture docs against the codebases they describe (replaces one-doc-at-a-time fact-check sessions)',
  phases: [
    { title: 'Preflight', detail: 'refresh + SHA-stamp reference repos' },
    { title: 'Verify', detail: 'one agent per doc, line-level corrections' },
    { title: 'Synthesize', detail: 'merge corrections + unadopted ideas' },
  ],
}

// args: [{ doc: '/abs/path/to/doc.md', source: '/abs/path/to/repo' }, ...]
// Headless `claude -p` invocations tend to pass args as a JSON string — tolerate both.
let pairs = args
if (typeof pairs === 'string') {
  try {
    pairs = JSON.parse(pairs)
  } catch {
    // fall through to the array guard below
  }
}
if (!Array.isArray(pairs) || pairs.length === 0) {
  return { error: 'Pass args as [{doc: "<abs doc path>", source: "<abs repo path>"}, ...]' }
}

phase('Preflight')
const repos = [...new Set(pairs.map((a) => a.source))]
const STAMP = {
  type: 'object',
  properties: {
    repo: { type: 'string' },
    sha: { type: 'string' },
    age: { type: 'string' },
    pulled: { type: 'boolean' },
    note: { type: 'string' },
  },
  required: ['repo', 'sha', 'age', 'pulled'],
}
// Barrier is intentional: verification must read refreshed trees.
const stamps = await parallel(
  repos.map((r) => () =>
    agent(
      `Refresh and stamp the reference repo ${r}. Steps: (1) run \`git -C ${r} pull --ff-only\` exactly once — it is auto-allowed only for whitelisted reference repos; if it is blocked or fails, do NOT retry or work around it, record pulled=false with the reason in note. (2) Report sha = \`git -C ${r} rev-parse --short HEAD\`, age = \`git -C ${r} log -1 --format=%cr\`. Return only the structured result.`,
      { phase: 'Preflight', label: `stamp:${r.split('/').pop()}`, schema: STAMP },
    )
  ),
)

phase('Verify')
const RESULT = {
  type: 'object',
  properties: {
    claimsChecked: { type: 'number' },
    corrections: {
      type: 'array',
      items: {
        type: 'object',
        properties: { where: { type: 'string' }, was: { type: 'string' }, now: { type: 'string' } },
        required: ['where', 'was', 'now'],
      },
    },
    staleFraming: { type: 'array', items: { type: 'string' } },
    unadoptedIdeas: { type: 'array', items: { type: 'string' } },
    unverifiable: { type: 'array', items: { type: 'string' } },
  },
  required: ['claimsChecked', 'corrections', 'staleFraming', 'unadoptedIdeas', 'unverifiable'],
}
const results = await parallel(
  pairs.map(({ doc, source }) => () =>
    agent(
      `Fact-check the doc ${doc} against the CURRENT source in ${source}. Read the doc fully. For EVERY factual claim — file paths, module/function/class names, behaviors, flows, counts, architecture statements — verify against the actual code (Read/Grep/Glob inside ${source}; cite paths). Apply minimal line-level Edits to ${doc} fixing anything stale; preserve the doc's voice and structure. If the doc's entire framing is obsolete (the code was rewritten), do NOT rewrite it wholesale — record it in staleFraming instead. Also list ideas the doc proposes that were never implemented (unadoptedIdeas) and claims you could not verify either way (unverifiable). Return only the structured result.`,
      { phase: 'Verify', label: `verify:${doc.split('/').pop()}`, schema: RESULT },
    )
  ),
)

phase('Synthesize')
const docs = pairs.map((a, i) => ({ ...a, result: results[i] }))
const failed = docs.filter((d) => !d.result).map((d) => d.doc)
if (failed.length) log(`No result for: ${failed.join(', ')}`)
return {
  stamps: stamps.filter(Boolean),
  totals: {
    claimsChecked: docs.reduce((n, d) => n + (d.result?.claimsChecked || 0), 0),
    corrections: docs.reduce((n, d) => n + (d.result?.corrections?.length || 0), 0),
  },
  docs,
  failed,
}
