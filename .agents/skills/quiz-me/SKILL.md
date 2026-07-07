---
name: quiz-me
description: Pre-commit comprehension gate — brief the operator on a change (mental model, non-obvious decisions, invariants touched, off-diff dependencies), then quiz them on it; a perfect score clears the change to stage and commit. Use when the user asks to be quizzed on a change ("quiz me", "do I actually understand this", "am I ready to commit this"), or before staging a large autonomous deliverable where reading the diff alone gives only light understanding. Accepts an optional commit-ish or range argument to quiz on landed work instead of the working tree. Do NOT use for: hunting defects (code-review), proving a change works end-to-end (verify), or trivial diffs (typo fixes, one-liners) where a quiz is ceremony.
---

# Quiz Me → Pre-Commit Comprehension Gate

`docs/TRUST-BOUNDARIES.md` is the review rubric for the *machine* side of the trust
boundary; this skill gates the *human* side: does the operator still hold the invariants
this change touched? The house git policy makes the operator the commit gate — reading a
diff gives only light understanding when behavior rides existing code paths, and this
codebase is dense with standing contracts (findings-win, fail-closed-to-infra, single-use
approvals, …). If the operator can't pass the quiz, they're not ready to commit — and
that's the point. This is not a defect hunt: assume the change is correct and test
whether it is *understood*.

## Phase 1 — Scope the change

- Default scope is the working tree: `git diff` + `git diff --staged`, plus untracked
  files from `git status --porcelain` (read new files directly — untracked files are
  part of the change).
- An argument overrides: a commit-ish (`git show <ref>`) or range (`git diff A..B`)
  quizzes landed work instead.
- Empty scope: say so and ask whether to quiz on the last commit instead. Never invent a
  quiz from nothing.
- If the change spans several subsystems, weight the briefing and quiz toward the parts
  where misunderstanding is most expensive (trust boundaries, gates, terminal statuses,
  concurrency fences) and say explicitly what was left out.

## Phase 2 — Context beyond the diff

The quiz targets what the diff *means* against existing code, not the diff text. Before
writing anything:

- Map touched files → subsystems via the `docs/system/README.md` index; read the
  matching `docs/system/<x>.md` pages and the corresponding AGENTS.md Key Patterns
  bullets.
- Read `docs/TRUST-BOUNDARIES.md` when the change touches orchestration, gates, verdict
  surfaces, or anything event-sourced.
- If the change implements a plan from `docs/plans/`, read the plan **and its
  `## Deviations` section** — deviations are prime quiz material (the operator approved
  or should know about each one).
- Trace the off-diff dependencies: existing code paths the change relies on that never
  appear in the diff. These produce the best questions.

## Phase 3 — The briefing (narrative first)

Prime understanding before testing it — the quiz must be passable from the briefing
alone. Deliver in one message:

- **Mental model** — old shape → new shape, one tight paragraph (a small ASCII diagram
  if the topology changed).
- **Non-obvious decisions** — 3–6, each with the *why* and a `file:line` ref. If a
  decision was a deviation from the plan or a judgment call, say so honestly.
- **Invariants touched** — which standing contracts the change relies on, extends, or
  modifies, and what now upholds each.
- **Off-diff dependencies** — behavior riding existing paths not visible in the diff
  ("this works because `X` already does `Y`").

## Phase 4 — The quiz

Immediately after the briefing, in the same message:

- **5–6 multiple-choice questions** (a–d), numbered, each keyed to a briefing section.
- Target decisions, invariants, and runtime consequences — at least one scenario
  question ("what happens at runtime if X?") and at least one failure-mode question
  ("what breaks / what holds when Y goes wrong?").
- Never trivia: no function names, line numbers, or mechanical facts a reader could
  pattern-match without understanding.
- Distractors are plausible-but-wrong statements of the invariant — the misreadings a
  skimmer would actually make, not obvious throwaways.
- Do not reveal answers. Ask the operator to reply in one line (`1b 2a 3d …`).

## Phase 5 — Grade and clear

- Grade every answer: verdict, the correct choice, a one-sentence why, and for each miss
  a pointer back to the briefing section and `file:line` to reread.
- A near-miss is a miss — never soften grading; the gate is only worth what it enforces.
- **Perfect score** → declare **Cleared to commit** and end with the files-to-stage list
  plus a suggested commit message (house git policy: the operator stages and commits).
- **Any miss** → not cleared. Name exactly what to reread, then offer a re-quiz with
  *fresh* questions concentrated on the missed areas — never repeat a question verbatim
  (recognition is not comprehension).
- Partial answers: grade what was given, ask for the rest. Clearing requires every
  question answered correctly, across re-quizzes.

## Guardrails

- The briefing must be self-sufficient: if a question needs knowledge the briefing never
  stated, the briefing is defective — fix it rather than blaming the answer.
- Keep everything terminal markdown; no artifacts unless the operator asks.
- The gate is advisory by design: report cleared/not-cleared and stop. Whether to commit
  anyway is the operator's call, not the skill's.
