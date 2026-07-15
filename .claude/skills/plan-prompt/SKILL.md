---
name: plan-prompt
description: Prompt template for planning
disable-model-invocation: true
---

$ARGUMENTS

a few notes:

- let me know if there's any additional information you need from me in order to write and then implement the plan -- ask as many questions as you need to (one at a time), don't make assumptions
- the plan can not be considered "complete" until `mix precommit` and/or `pnpm --dir ui validate` pass (depending on what was changed)
- keep in mind this project is greenfield so we don't need to worry at all about migrating data/paths for compatibility
- similarly, the plan itself is greenfield. if we have edits and revisions made to it, don't add changelog-like comments to the plan, just edit the plan in place however you need to
- don't commit anything, everything can remain unstaged
- you have access to an Elixir LSP and a TypeScript LSP, they may be helpful as you explore the codebase
- **no deferrals** -- if a unit seems too large to handle in a single plan, let's pause the planning and discuss how to handle it
- When you are done writing the plan, it is automatically
  reviewed by an external reviewer. If the review rejects it, you are
  resumed with the rejection feedback. Validate the feedback, and if valid
  resolve the findings in the plan; for any feedback not found to be valid,
  include the finding in the plan in its own invalid findings section and
  provide your reasoning for disagreement. DO NOT write changelog-type
  comments (revised, round n, rev n, etc). The only acknowledgement of the
  review should come in the form of the refutation section (if needed). Treat
  the plan as a living document, it should always be greenfield.
