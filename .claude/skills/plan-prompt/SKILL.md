---
name: plan-prompt
description: Prompt template for planning
disable-model-invocation: true
---

$ARGUMENTS

a few notes:

- let me know if there's any additional information you need from me in order to write and then implement the plan -- ask as many questions as you need to (one at a time), don't make assumptions
- the plan can not be considered "complete" until `mix precommit` passes
- keep in mind this project is greenfield so we don't need to worry at all about migrating data/paths for compatibility
- similarly, the plan itself is greenfield. if we have edits and revisions made to it, don't add changelog-like comments to the plan, just edit the plan in place however you need to
- don't commit anything, everything can remain unstaged
- you have access to an Elixir LSP, that may be helpful as you explore the codebase
- **no deferrals** -- if a unit seems too large to handle in a single plan, let's pause the planning and discuss how to handle it
