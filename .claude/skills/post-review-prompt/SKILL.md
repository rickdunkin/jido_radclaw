---
name: post-review-prompt
description: Prompt template for post-review
disable-model-invocation: true
---

we've just finished working through the plan @$0 and had a code review performed. please verify the issues found and create a plan to resolve all issues found if validated.

a few notes:

- the plan can not be considered "complete" until `mix precommit` passes
- keep in mind this project is greenfield so we don't need to worry at all about migrating data/paths for compatibility
- similarly, the plan itself is greenfield. if we have edits and revisions made to it, don't add changelog-like comments to the plan, just edit the plan in place however you need to
- don't commit anything, everything can remain unstaged
- you have access to an Elixir LSP, that may be helpful as you explore the codebase

here's the feedback from the reviewer:

```
$1
```
