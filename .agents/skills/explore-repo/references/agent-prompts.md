# Agent prompt templates for the research fan-out

These are scaffolds, not scripts — fill the brackets and cut sections the subject
doesn't have. They exist because the *shape* of a reader prompt determines whether five
reports compose into one citable doc or into five piles of prose. Every reader prompt
must demand the same five properties; every seams prompt must demand file:line on our
side. Spawn all readers in one message, as read-only Explore agents.

## Why these properties are non-negotiable

- **"Your final message is consumed by another agent as raw research data"** — stops the
  reader from writing a human-facing summary. You want dense facts, not narration.
- **file:line for every claim** — the doc's Gap/Where fields are file:line on both sides;
  a reader that returns claims without refs forces you to re-find everything.
- **verbatim key blocks** (schema, config, a representative example) — you'll quote these
  in the doc; paraphrased schemas drift.
- **honest not-founds + immaturity/platform flags** — "no code for X, grep clean" and
  "TODO/alpha/platform-gated" are findings that shape verdicts (SKIP, TRACK-with-trigger,
  the read-vs-executed caveat).
- **assigned scope** — non-overlapping subsystems/areas so readers don't collide.

## Subject reader (one per subsystem/docs-area)

```
You are researching "<subject>" at <abs-path> (<lang>, <one-line what-it-is>). Report
FACTS about <this reader's slice: e.g. "its profile system and process lifecycle">, with
file references. Your final message is consumed by another agent as raw research data —
be dense, factual, complete; no marketing language, no recommendations.

Read fully: <explicit doc/file list for this slice>.
Confirm key claims against source in <code dir> — cite the .<ext> files.

Report:
1. <specific question — the exact mechanism, not a summary>
2. <specific question — schema/contract: include a representative block VERBATIM>
3. <specific question — the sharp edge you actually care about for integration>
...
Note anything immature, TODO, alpha, or platform-gated. Distinguish what the docs CLAIM
from what the code DOES if they diverge (report the divergence — it's a finding).
Include file:line for every claim.
```

Targeting tips: give each reader a **sharpest-question** framing for the decision that
matters (nono's macOS reader was told "this is the highest-priority section: the
consuming project's dev machine is macOS"). Ask for the *escape hatches / documented
residuals / non-goals* explicitly — a security-serious subject documents its own gaps,
and those become your SKIP/TRACK rationale.

## Seams-mapper (exactly one, over jido_radclaw)

The most important prompt: its output is the doc's hardest evidence (the Gap fields).

```
You are researching the JidoClaw codebase at /Users/rickdunkin/workspace/claws/jido_radclaw
(Elixir). Goal: map exactly how <the surface the subject would plug into> works today, so
we can evaluate <the integration the subject enables>. Your final message is consumed by
another agent as raw research data — be dense, factual, with file:line references.

Investigate:
1. <the primary seam: the exact call path, the load-bearing function, argv vs shell,
   spawn mechanism, cwd/env>
2. <adjacent state: persistence, lifecycle, timeouts, kill story>
3. <the security/gate layer that would interact: what it does today, its residuals>
4. <where a new backend/impl/config would register — the touch-points>
5. <env/secret hygiene already applied on this path — correct any premise you were given>
6. <config surface + defaults, incl. test.exs overrides>
7. Grep for any existing mention of "<subject>"/<its key tech terms> — presumably none;
   confirm.
Note anything platform-conditional (primary dev machine is macOS/darwin).
Include file:line for every claim.
```

Feed the seams-mapper a premise and invite correction — this session's mapper corrected a
false premise ("env scrubbing is MCP-only") into a load-bearing fact ("it's already
applied at the host spawn"), which reshaped a Tier-1 entry.

## Re-review verification pass

```
Re-verify the exploration entry "<ID: title>" (in <doc path>) against current source.
Subject moved <old-sha>..HEAD; our tree is at <sha>.
- Subject side: is the mechanism at <cited files> still as the entry describes? What
  changed? New location + behavior delta if any.
- Our side (the Gap): re-check <cited jido_radclaw files>. Has an equivalent shipped
  since the entry was written? Cite file:line.
Return: per-side status (unchanged / moved / shipped / superseded) with evidence. Dense,
factual, cited. This feeds a dated Status line, so be precise about what is and isn't done
(any deferral or placeholder means NOT fully done).
```

## Anti-patterns

- One reader for the whole subject — collides with the seams-mapper's job and returns
  shallow coverage; split by area instead.
- Asking a reader to *recommend* — verdicts are the synthesis step's job, made across all
  reports against our threat model; a reader recommending in isolation biases the tier.
- Skipping the seams-mapper because "the subject is simple" — the Gap fields still need
  file:line, and a self-read tends to hand-wave them.
- Reading the reader's raw transcript file — it overflows context; the final message is
  the deliverable. Wait for the completion notification.
