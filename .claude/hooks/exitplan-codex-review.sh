#!/usr/bin/env bash
# PreToolUse gate for ExitPlanMode: reviews the plan file the main
# conversation is about to present for approval, via a headless `codex exec`
# run. A {"ok": false} verdict denies the tool call and feeds the findings back
# to the model as revision instructions; the model revises the plan file and
# re-calls ExitPlanMode, re-firing the gate (bounded by MAX_ROUNDS). Budget
# exhaustion downgrades to permissionDecision "ask" — the normal plan dialog,
# with the last objection attached — instead of a silent pass.
#
# ExitPlanMode carries NO plan text in tool_input on this build (2.1.207):
# the model writes the plan to plansDirectory (.claude/plans/) BEFORE calling,
# so the gate reads the newest recently-written *.md there.
#
# Fail-open discipline: every unexpected failure exits 0/1 — NEVER 2. On
# PreToolUse, exit 2 BLOCKS the call (opposite of Stop hooks), so a broken
# reviewer must exit 0/1 to let the plan through. The only block path is the
# deliberate exit-0 deny JSON.
#
# Block shape (PreToolUse): exit 0 + {"hookSpecificOutput":{"hookEventName":
# "PreToolUse","permissionDecision":"deny","permissionDecisionReason":...}}
# Allow shape: silent exit 0.
#
# Twin: plan-codex-review.sh (SubagentStop gate on the Plan agent override).
# The guideline, output-contract, schema, and findings-render blocks are
# shared verbatim — keep them byte-identical.
# Deliberate divergence: no "blocked pending user input" acceptance clause
# (a plan file at ExitPlanMode time must BE a plan; open questions belong in
# AskUserQuestion before exiting plan mode).
#
# Knobs (env, shared with the twin):
#   PLAN_REVIEW_MODEL           -> passed as `codex -m` (default: codex's default)
#   PLAN_REVIEW_MAX_ROUNDS      revision budget (default 3)
#   PLAN_REVIEW_EFFORT          codex model_reasoning_effort (default xhigh)
#   PLAN_REVIEW_CONVERGE_ROUNDS trailing rounds where the re-review narrows to
#                               prior-feedback-only (default 1 = final round only;
#                               earlier revision rounds re-review the whole plan)
# Debug: state + per-run codex logs live in ${TMPDIR:-/tmp}/exitplan-codex-review/
set -euo pipefail

# Breadcrumb preamble: every firing leaves a trace (fired.log + raw stdin)
# BEFORE any guard can silently exit, so a no-op gate is diagnosable. Guard
# exits log their reason for the same purpose.
state="${TMPDIR:-/tmp}/exitplan-codex-review"
mkdir -p "$state" 2>/dev/null || state="/tmp"
log() { echo "$(date '+%F %T') pid=$$ $*" >>"$state/fired.log" 2>/dev/null || true; }
input=$(cat || true)
log "fired"
printf '%s' "$input" >"$state/last-stdin.json" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || exit 0

[[ "$(jq -r '.tool_name // empty' <<<"$input")" == "ExitPlanMode" ]] || {
  log "skip: tool_name != ExitPlanMode"
  exit 0
}

# Main conversation only: agent_id is present iff the hook fired inside a
# subagent (subagents rarely have ExitPlanMode, but fail toward not gating).
agent_id=$(jq -r '.agent_id // empty' <<<"$input")
[[ -n "$agent_id" ]] && {
  log "skip: subagent agent_id=$agent_id"
  exit 0
}

# Out-of-plan-mode ExitPlanMode calls are model mistakes the tool itself
# rejects — don't burn a codex run reviewing a stale plan file for them.
mode=$(jq -r '.permission_mode // empty' <<<"$input")
[[ "$mode" == "plan" ]] || {
  log "skip: permission_mode=${mode:-absent}"
  exit 0
}

command -v codex >/dev/null 2>&1 || {
  log "skip: no codex on PATH"
  exit 0
}

session=$(jq -r '.session_id // "nosession"' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -z "$cwd" || ! -d "$cwd" ]] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

# Plan source: newest *.md in plansDirectory, but only if freshly written —
# the model writes the plan file moments before calling ExitPlanMode, so a
# stale newest file means we'd review the WRONG plan. Skip (fail open)
# rather than deny real work with feedback about yesterday's plan.
plans_dir="${CLAUDE_PROJECT_DIR:-$cwd}/.claude/plans"
plan_file=""
if [[ -d "$plans_dir" ]]; then
  candidates=$(ls -t "$plans_dir"/*.md 2>/dev/null || true)
  newest=$(head -n1 <<<"$candidates")
  if [[ -n "$newest" && -n "$(find "$newest" -mmin -60 2>/dev/null)" ]]; then
    plan_file="$newest"
  fi
fi
[[ -z "$plan_file" ]] && {
  log "skip: no fresh plan file in $plans_dir"
  exit 0
}
plan=$(cat "$plan_file" 2>/dev/null || true)
[[ -z "$plan" ]] && {
  log "skip: empty plan file $plan_file"
  exit 0
}

MAX_ROUNDS="${PLAN_REVIEW_MAX_ROUNDS:-3}"

# New-knob typos must degrade to defaults, not fail-open the whole gate.
CONVERGE_ROUNDS="${PLAN_REVIEW_CONVERGE_ROUNDS:-1}"
[[ "$CONVERGE_ROUNDS" =~ ^[0-9]+$ ]] || {
  log "invalid PLAN_REVIEW_CONVERGE_ROUNDS=$CONVERGE_ROUNDS -> 1"
  CONVERGE_ROUNDS=1
}

effort="${PLAN_REVIEW_EFFORT:-xhigh}"
case "$effort" in
  minimal | low | medium | high | xhigh) ;;
  *)
    log "invalid PLAN_REVIEW_EFFORT=$effort -> xhigh"
    effort="xhigh"
    ;;
esac

find "$state" -type f -mtime +1 -delete 2>/dev/null || true
key="$session"
counter="$state/$key.count"
prior_file="$state/$key.feedback"
verdict_file="$state/$key.verdict.json"
log_file="$state/$key.log"

# Revision budget: our own counter — PreToolUse has no built-in deny cap
# (the 8-consecutive-blocks override is Stop-only). At exhaustion, downgrade
# to "ask" so the user sees the surviving objection in the approval dialog
# instead of the gate silently vanishing.
rounds=$(cat "$counter" 2>/dev/null || echo 0)
if ((rounds >= MAX_ROUNDS)); then
  last=$(cat "$prior_file" 2>/dev/null || true)
  rm -f "$counter" "$prior_file"
  log "budget exhausted after $rounds rounds -> ask"
  msg="Codex plan review budget exhausted ($rounds rounds). Unresolved objections: ${last:-none recorded}"
  jq -cn --arg r "$msg" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
fi

schema="$state/verdict.schema.json"
cat >"$schema" <<'EOF'
{
  "type": "object",
  "properties": {
    "ok": { "type": "boolean" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "title": { "type": "string" },
          "body": { "type": "string" },
          "suggestion": { "type": "string" },
          "confidence_score": { "type": "number" },
          "priority": { "type": "integer" },
          "code_location": {
            "anyOf": [
              {
                "type": "object",
                "properties": {
                  "absolute_file_path": { "type": "string" },
                  "line_range": {
                    "type": "object",
                    "properties": {
                      "start": { "type": "integer" },
                      "end": { "type": "integer" }
                    },
                    "required": ["start", "end"],
                    "additionalProperties": false
                  }
                },
                "required": ["absolute_file_path", "line_range"],
                "additionalProperties": false
              },
              { "type": "null" }
            ]
          }
        },
        "required": ["title", "body", "suggestion", "confidence_score", "priority", "code_location"],
        "additionalProperties": false
      }
    },
    "overall_explanation": { "type": "string" }
  },
  "required": ["ok", "findings", "overall_explanation"],
  "additionalProperties": false
}
EOF

prior=""
[[ -f "$prior_file" ]] && prior=$(<"$prior_file")

# Revision-note variant by round: early revision rounds re-review the whole
# plan (new findings welcome); only the last CONVERGE_ROUNDS rounds narrow to
# prior-feedback-only, so the loop converges instead of chasing objections it
# has no budget left to re-review. Keep the two variants identical in the twin.
revision_note=""
if [[ -n "$prior" ]]; then
  if ((rounds + 1 > MAX_ROUNDS - CONVERGE_ROUNDS)); then
    IFS= read -r -d '' revision_note <<EOF || true

This is a revision (round $((rounds + 1)) of $MAX_ROUNDS — the review budget is nearly exhausted). Prior review feedback was:
$prior
Accept if that feedback was materially addressed; do not raise new objections unless the revision introduced a new critical defect.
EOF
  else
    IFS= read -r -d '' revision_note <<EOF || true

This is a revision (round $((rounds + 1)) of $MAX_ROUNDS). Prior review feedback was:
$prior
Verify that feedback was materially addressed (reject if not), and re-review the revised plan as a whole — new qualifying findings may still be raised.
EOF
  fi
fi

# Static guideline block in a QUOTED heredoc: apostrophes and the backtick
# fences are literal here (in an unquoted heredoc the backticks command-
# substitute and swallow the text between the fences).
IFS= read -r -d '' guidelines <<'EOF' || true
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
- If there is an architectural design flaw, call it out in the comment and suggest a better way to do it.
- Use ```suggestion blocks ONLY for concrete replacement code (minimal lines; no commentary inside the block).
- In every ```suggestion block, preserve the exact leading whitespace of the replaced lines (spaces vs tabs, number of spaces).
- Do NOT introduce or remove outer indentation levels unless that is the actual fix.

You should avoid providing unnecessary location details in the comment body. Always keep the line range as short as possible for interpreting the issue. Avoid ranges longer than 5–10 lines; instead, choose the most suitable subrange that pinpoints the problem.

At the beginning of all finding titles, tag the bug with priority level. For example "[P1] Un-padding slices along wrong tensor dimensions". [P0] – Drop everything to fix.  Blocking release, operations, or major usage. Only use for universal issues that do not depend on any assumptions about the inputs. · [P1] – Urgent. Should be addressed in the next cycle · [P2] – Normal. To be fixed eventually · [P3] – Low. Nice to have.
EOF

# Output contract in a QUOTED heredoc for the same reason (the json fence
# backticks must stay literal). Shared verbatim with the twin — keep the two
# blocks byte-identical.
IFS= read -r -d '' output_contract <<'EOF' || true
OUTPUT FORMAT:

## Output schema — MUST MATCH *exactly*

```json
{
  "ok": <boolean>,
  "findings": [
    {
      "title": "<≤ 80 chars, imperative>",
      "body": "<valid Markdown explaining *why* this is a problem; cite files/lines/functions>",
      "suggestion": "<valid Markdown suggestion for a potential fix>",
      "confidence_score": <float 0.0-1.0>,
      "priority": <int 0-3>,
      "code_location": {
        "absolute_file_path": "<file path>",
        "line_range": {"start": <int>, "end": <int>}
      }
    }
  ],
  "overall_explanation": "<1-3 sentence explanation justifying the ok verdict>"
}
```

* **Do not** wrap the JSON in markdown fences or extra prose.
* "ok" MUST be false if and only if "findings" is non-empty; include ONLY findings that should block approval of this plan.
* "findings" must list EVERY qualifying finding, not just the first or most severe.
* "code_location" must cite a real repository file (absolute path) when the finding is about existing code; use null for findings about the plan itself (omissions, sequencing, scope).
* Line ranges must be as short as possible for interpreting the issue (avoid ranges over 5–10 lines; pick the most suitable subrange).
EOF

# read -d '' (not prompt=$(cat <<EOF)): macOS /bin/bash 3.2 scans $( ) for
# its closing paren without understanding heredocs, so apostrophes in the
# text would break parsing. read hits EOF without a NUL -> || true. Only
# variable expansions appear in this unquoted heredoc's literal text — no
# backticks, no apostrophes ($guidelines/$output_contract/$plan/$prior expand
# as data and are never re-parsed).
IFS= read -r -d '' prompt <<EOF || true
You are gating a finalized implementation plan for the repository at your working directory — the plan is about to be presented to the user for approval. You have read-only access. The plan may be targeting backed, frontend, or potentially both. Focus your review efforts only on the relevant pieces of the plan. Look for anything that sticks out as incorrect, a gap, a potential regression, or just something that could be done better or maybe more idiomatically elixir/ash/jido if backend code, or react/tailwind/shadcn/apollo if frontend code.

$guidelines
$revision_note

$output_contract
Plan file ($plan_file) follows:
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
  -c "model_reasoning_effort=\"$effort\"" \
  -c 'model_reasoning_summary="concise"' \
  -c 'fast_mode=true' \
  -c 'project_doc_max_bytes=150000' \
  --output-schema "$schema" \
  --output-last-message "$verdict_file" \
  ${model_args[@]+"${model_args[@]}"} \
  - <<<"$prompt" >"$log_file" 2>&1 || {
  log "codex infra failure -> open"
  exit 0
}

verdict=$(jq -c '.' "$verdict_file" 2>/dev/null) || {
  log "unparseable verdict -> open"
  exit 0
}
ok=$(jq -r '.ok' <<<"$verdict")

# Render the findings array into numbered markdown feedback: the rendered
# text is both the deny reason and the stored prior feedback for the next
# round. The [P#] tag comes from the priority field (stripped from the title
# if the model tagged it there too); ok=false with zero findings falls back
# to overall_explanation, and a render failure falls back rather than
# failing the gate.
render_findings='
if (.findings // []) | length == 0 then
  (.overall_explanation // "Revise the plan per review.")
else
  [ .findings[]
    | "[P\(.priority // "?")] "
      + ((.title // "(untitled)") | sub("^\\[P[0-9]\\]\\s*"; ""))
      + (if .code_location then " — \(.code_location.absolute_file_path):\(.code_location.line_range.start // "?")-\(.code_location.line_range.end // "?")" else "" end)
      + " (confidence \(.confidence_score // "?"))\n"
      + (.body // "")
      + (if (.suggestion // "") != "" then "\nSuggestion: \(.suggestion)" else "" end)
  ] | to_entries | map("\(.key + 1). \(.value)") | join("\n\n")
end'

if [[ "$ok" == "false" ]]; then
  reason=$(jq -r "$render_findings" <<<"$verdict" 2>/dev/null) || reason=""
  [[ -z "$reason" ]] && reason="Revise the plan per review."
  echo $((rounds + 1)) >"$counter"
  printf '%s' "$reason" >"$prior_file"
  log "deny round $((rounds + 1))/$MAX_ROUNDS"
  msg="Plan review (round $((rounds + 1))/$MAX_ROUNDS) rejected this plan:

$reason

Address the feedback by revising the plan file in place ($plan_file), then call ExitPlanMode again."
  jq -cn --arg r "$msg" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
fi

log "allow"
rm -f "$counter" "$prior_file"
exit 0
