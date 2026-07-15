---
name: post-review-prompt
description: Prompt template for post-review
disable-model-invocation: true
---

we've just finished working through the plan $0 and had a code review performed. please verify the issues found and create a plan to resolve all issues found if validated.

a few notes:

- the plan can not be considered "complete" until `mix precommit` and/or `pnpm --dir ui validate` pass (depending on what was changed)
- keep in mind this project is greenfield so we don't need to worry at all about migrating data/paths for compatibility
- similarly, the plan itself is greenfield. if we have edits and revisions made to it, don't add changelog-like comments to the plan, just edit the plan in place however you need to
- don't commit anything, everything can remain unstaged
- you have access to an Elixir LSP and a TypeScript LSP, they may be helpful as you explore the codebase
- When you are done writing the plan, it is automatically
  reviewed by an external reviewer. If the review rejects it, you are
  resumed with the rejection feedback. Validate the feedback, and if valid
  resolve the findings in the plan; for any feedback not found to be valid,
  include the finding in the plan in its own invalid findings section and
  provide your reasoning for disagreement. DO NOT write changelog-type
  comments (revised, round n, rev n, etc). The only acknowledgement of the
  review should come in the form of the refutation section (if needed). Treat
  the plan as a living document, it should always be greenfield.

here's the feedback from the reviewer:

```
$1
```
