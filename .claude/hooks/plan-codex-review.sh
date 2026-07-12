#!/usr/bin/env bash
# Stop/SubagentStop gate for the plan-custom agent: reviews the draft plan
# with a headless `codex exec` run. A {"ok": false} verdict blocks the stop
# and feeds the reason back as revision instructions; the agent revises and
# the gate re-fires (bounded by MAX_ROUNDS). Every unexpected failure exits
# 0/1 — never 2 — so a broken reviewer fails open and the plan proceeds.
#
# Block shape (SubagentStop/Stop): exit 0 + {"decision":"block","reason":...}
# Allow shape: silent exit 0.
#
# Knobs (env): PLAN_REVIEW_MODEL   -> passed as `codex -m` (default: codex's default)
#              PLAN_REVIEW_MAX_ROUNDS (default 3)
# Debug: state + per-run codex logs live in ${TMPDIR:-/tmp}/plan-codex-review/
set -euo pipefail

# Breadcrumb preamble: every firing leaves a trace (fired.log + raw stdin)
# BEFORE any guard can silently exit, so a no-op gate is diagnosable.
state="${TMPDIR:-/tmp}/plan-codex-review"
mkdir -p "$state" 2>/dev/null || state="/tmp"
input=$(cat || true)
echo "$(date '+%F %T') fired pid=$$ PATH=$PATH" >>"$state/fired.log" 2>/dev/null || true
printf '%s' "$input" >"$state/last-stdin.json" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || exit 0
command -v codex >/dev/null 2>&1 || exit 0

plan=$(jq -r '.last_assistant_message // empty' <<<"$input")
[[ -z "$plan" ]] && exit 0

session=$(jq -r '.session_id // "nosession"' <<<"$input")
agent=$(jq -r '.agent_id // "main"' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -z "$cwd" || ! -d "$cwd" ]] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

MAX_ROUNDS="${PLAN_REVIEW_MAX_ROUNDS:-3}"

find "$state" -type f -mtime +1 -delete 2>/dev/null || true
key="${session}-${agent}"
counter="$state/$key.count"
prior_file="$state/$key.feedback"
verdict_file="$state/$key.verdict.json"
log_file="$state/$key.log"

# Revision budget: our own counter. Deliberately not stop_hook_active
# (Stop-documented, unverified on SubagentStop, and it would cap at one
# round) nor the 8-consecutive-blocks override (likewise Stop-documented).
rounds=$(cat "$counter" 2>/dev/null || echo 0)
if ((rounds >= MAX_ROUNDS)); then
  rm -f "$counter" "$prior_file"
  exit 0 # budget spent — let the plan through rather than loop forever
fi

schema="$state/verdict.schema.json"
cat >"$schema" <<'EOF'
{
  "type": "object",
  "properties": {
    "ok": { "type": "boolean" },
    "reason": { "type": "string" }
  },
  "required": ["ok", "reason"],
  "additionalProperties": false
}
EOF

prior=""
[[ -f "$prior_file" ]] && prior=$(<"$prior_file")

# read -d '' (not prompt=$(cat <<EOF)): macOS /bin/bash 3.2 scans $( ) for
# its closing paren without understanding heredocs, so apostrophes in the
# prompt text would break parsing. read hits EOF without a NUL → || true.
IFS= read -r -d '' prompt <<EOF || true
You are gating a draft implementation plan for the repository at your working directory. You have read-only access. Please review this plan for anything that sticks out as incorrect, a gap, a potential regression, or just something that could be done better or maybe more idiomatically elixir/ash/jido

Below are some default guidelines for determining whether the original author would appreciate the issue being flagged.

These are not the final word in determining whether an issue is a bug. In many cases, you will encounter other, more specific guidelines. These may be present elsewhere in a developer message, a user message, a file, or even elsewhere in this system message.
Those guidelines should be considered to override these general instructions.

Here are the general guidelines for determining whether something is a bug and should be flagged.

1. It meaningfully impacts the accuracy, performance, security, or maintainability of the code.
2. The bug is discrete and actionable (i.e. not a general issue with the codebase or a combination of multiple issues).
3. Fixing the bug does not demand a level of rigor that is not present in the rest of the codebase (e.g. one doesn't need very detailed comments and input validation in a repository of one-off scripts in personal projects)
4. The bug was introduced in the commit (pre-existing bugs should not be flagged).
5. The author of the original PR would likely fix the issue if they were made aware of it.
6. The bug does not rely on unstated assumptions about the codebase or author's intent.
7. It is not enough to speculate that a change may disrupt another part of the codebase, to be considered a bug, one must identify the other parts of the code that are provably affected.
8. The bug is clearly not just an intentional change by the original author.

When flagging a bug, you will also provide an accompanying comment. Once again, these guidelines are not the final word on how to construct a comment -- defer to any subsequent guidelines that you encounter.

1. The comment should be clear about why the issue is a bug.
2. The comment should appropriately communicate the severity of the issue. It should not claim that an issue is more severe than it actually is.
3. The comment should be brief. The body should be at most 1 paragraph. It should not introduce line breaks within the natural language flow unless it is necessary for the code fragment.
4. The comment should not include any chunks of code longer than 3 lines. Any code chunks should be wrapped in markdown inline code tags or a code block.
5. The comment should clearly and explicitly communicate the scenarios, environments, or inputs that are necessary for the bug to arise. The comment should immediately indicate that the issue's severity depends on these factors.
6. The comment's tone should be matter-of-fact and not accusatory or overly positive. It should read as a helpful AI assistant suggestion without sounding too much like a human reviewer.
7. The comment should be written such that the original author can immediately grasp the idea without close reading.
8. The comment should avoid excessive flattery and comments that are not helpful to the original author. The comment should avoid phrasing like "Great job ...", "Thanks for ...".

Below are some more detailed guidelines that you should apply to this specific review.

HOW MANY FINDINGS TO RETURN:

Output all findings that the original author would fix if they knew about it. If there is no finding that a person would definitely love to see and fix, prefer outputting no findings. Do not stop at the first qualifying finding. Continue until you've listed every qualifying finding.

GUIDELINES:

- Ignore trivial style unless it obscures meaning or violates documented standards.
- Use one comment per distinct issue (or a multi-line range if necessary).
- Use ```suggestion blocks ONLY for concrete replacement code (minimal lines; no commentary inside the block).
- In every ```suggestion block, preserve the exact leading whitespace of the replaced lines (spaces vs tabs, number of spaces).
- Do NOT introduce or remove outer indentation levels unless that is the actual fix.

You should avoid providing unnecessary location details in the comment body. Always keep the line range as short as possible for interpreting the issue. Avoid ranges longer than 5–10 lines; instead, choose the most suitable subrange that pinpoints the problem.

At the beginning of the finding title, tag the bug with priority level. For example "[P1] Un-padding slices along wrong tensor dimensions". [P0] – Drop everything to fix.  Blocking release, operations, or major usage. Only use for universal issues that do not depend on any assumptions about the inputs. · [P1] – Urgent. Should be addressed in the next cycle · [P2] – Normal. To be fixed eventually · [P3] – Low. Nice to have.

Accept if the message is an explicit report that planning is blocked pending
user input, rather than a plan.
${prior:+
This is a revision. Prior review feedback was:
$prior
Accept if that feedback was materially addressed; do not raise new stylistic objections.}

Your final message must be **exactly one JSON object** matching the provided schema:
{"ok": true, "reason": "<one line>"} **to accept**, or
{"ok": false, "reason": "<specific, actionable revision instructions>"} **to reject**.

Draft plan follows:
---
$plan
EOF

model_args=()
[[ -n "${PLAN_REVIEW_MODEL:-}" ]] && model_args=(-m "$PLAN_REVIEW_MODEL")

# Surgical -c overrides (an inline table/array replaces the whole entry):
# no user MCP servers (node_repl has a 120s startup budget), no desktop
# notify app, bounded reasoning effort. Auth, model, and service tier still
# come from the user's config.
rm -f "$verdict_file"
codex exec \
  --sandbox read-only \
  --ephemeral \
  --skip-git-repo-check \
  --ignore-rules \
  --color never \
  --cd "$cwd" \
  -c 'mcp_servers={}' \
  -c 'notify=[]' \
  -c 'model_reasoning_effort="xhigh"' \
  -c 'model_reasoning_summary="concise"' \
  -c 'project_doc_max_bytes=150000' \
  --output-schema "$schema" \
  --output-last-message "$verdict_file" \
  ${model_args[@]+"${model_args[@]}"} \
  - <<<"$prompt" >"$log_file" 2>&1 || exit 0 # reviewer infra failure → open

verdict=$(jq -c '.' "$verdict_file" 2>/dev/null) || exit 0 # unparseable → open
ok=$(jq -r '.ok' <<<"$verdict")

if [[ "$ok" == "false" ]]; then
  reason=$(jq -r '.reason // "Revise the plan per review."' <<<"$verdict")
  echo $((rounds + 1)) >"$counter"
  printf '%s' "$reason" >"$prior_file"
  msg="Codex plan review (round $((rounds + 1))/$MAX_ROUNDS) rejected this draft:

$reason

Address the feedback and emit the complete revised plan as your final message — the entire plan again, not a description of the changes."
  jq -cn --arg r "$msg" '{decision: "block", reason: $r}'
  exit 0
fi

rm -f "$counter" "$prior_file"
exit 0
