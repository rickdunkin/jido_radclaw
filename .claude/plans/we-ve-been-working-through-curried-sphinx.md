# Post-review fix: empty `--resume` values must be usage errors

## Context

The headless one-shot + CLI resume feature (plan `please-review-docs-plans-unadopted-next-warm-moonbeam.md`) is finished and code-reviewed. The review's second pass left exactly one finding:

> **[P2]** Empty resume values still bypass the usage path. `lib/jido_claw/cli/repl_args.ex:39` treats any binary `resume` as valid unless `--continue` is also set. `OptionParser` parses `--resume=` as `resume: ""` with no invalid entries, so `mix jidoclaw --resume=` / `jido --resume ""` still boot into the resume fallback path instead of exiting 2.

**Validated — CONFIRMED** (this session, empirically):

```
OptionParser.parse(["--resume="],     strict: [resume: :string])  → {[resume: ""],   [], []}
OptionParser.parse(["--resume", ""],  strict: [resume: :string])  → {[resume: ""],   [], []}
OptionParser.parse(["--resume", "  "],strict: [resume: :string])  → {[resume: "  "], [], []}
OptionParser.parse(["--resume"],      strict: [resume: :string])  → {[], [], [{"--resume", nil}]}  # only THIS form is invalid
```

So `ReplArgs.parse/1`'s cond (`lib/jido_claw/cli/repl_args.ex:39-57`) passes `resume: ""` through as `{:ok, ...}` — the `invalid != []` branch only catches the bare `--resume`, and the `is_binary(resume) and continue` branch only catches the conflict. Downstream, `Repl.resolve_boot_session/3` (`lib/jido_claw/cli/repl.ex:333-370`) hits `is_binary("")`, calls `Session.by_id("")`, fails, and falls back to a warn + fresh mint — exactly the silent-fresh-boot class `ReplArgs` was created to eliminate (its own moduledoc says so at `repl_args.ex:8-11`, and both entry-point moduledocs promise exit 2 for it).

The module docs are also now slightly wrong: `repl_args.ex:25-26` claims a valueless `--resume` "land[s] in `OptionParser`'s invalid list" — true only for the bare spelling, not `--resume=` / `--resume ""`.

**Scope guard — no UUID-shape validation.** The fix rejects only syntactically empty/blank values. Nonempty non-UUID strings keep today's contract: they reach `resolve_boot_session`'s interactive "not found — starting a FRESH session" fallback by design. Do not add format validation.

**Scope check (no other changes needed):**
- `RunCommand` (`--session=`) already fails loud: `resolve_session` → `Session.by_id("")` → `{:error, _}` → `{:usage, "session … not found"}` → exit 2 (`lib/jido_claw/cli/run_command.ex:278-288`). No change.
- Both entry files (`lib/mix/tasks/jidoclaw.ex:75-89`, `lib/jido_claw/cli/main.ex:58+`) already map `{:usage, _}` → stderr + exit 2, so the fix lands in both automatically.
- `resolve_boot_session` keeps its interactive fallback-warn posture by design; the usage error belongs at the parse boundary.

**Done means:** `mise exec -- mix precommit` passes.

## Fix

### 1. `lib/jido_claw/cli/repl_args.ex` — blank-resume branch

Add one cond branch between the `invalid != []` check and the mutual-exclusion check:

```elixir
is_binary(resume) and String.trim(resume) == "" ->
  {:usage, "--resume requires a session uuid"}
```

- `String.trim` (not `== ""`) so whitespace-only values (`--resume "  "`) are caught too — mirrors the house convention in `run_command.ex:159` (`String.trim(prompt) == ""`).
- Placed **before** the mutual-exclusion branch, so `--resume= --continue` reports the malformed value (the flag is broken regardless of the other flag). Either way it exits 2.
- Update the `@moduledoc` (lines 8-11) and `@doc` (lines 25-27): the bare `--resume` lands in OptionParser's invalid list, while the explicit-empty spellings (`--resume=`, `--resume ""`) parse as `resume: ""` and are rejected by the blank-value branch.

### 2. `test/jido_claw/cli/repl_args_test.exs` — pin the three empty spellings

Add alongside the existing "valueless `--resume`" test (line 54), following the same style:

- `--resume=` → `{:usage, message}`, `message =~ "--resume"`
- `--resume ""` (i.e. `ReplArgs.parse(["--resume", ""])`) → same
- `--resume "  "` (whitespace-only) → same
- `--resume= --continue` → `{:usage, message}` asserting the **blank-value message** (`message =~ "requires a session uuid"`), not just the shape — this pins the branch precedence (blank check before mutual exclusion), so a future cond reorder can't silently demote it to only "mutually exclusive"

Touch the test moduledoc's contract sentence to include the empty-value spellings.

### 3. Entry-point moduledoc prose (consistency, 2 one-line touches)

Both files promise exit 2 for "a valueless `--resume`" — extend the parenthetical to cover the empty forms:

- `lib/mix/tasks/jidoclaw.ex:15` — e.g. `` (e.g. `--bogus`, a valueless or empty `--resume`, `--resume <uuid> --continue`) ``
- `lib/jido_claw/cli/main.ex:16` — same phrasing.

## Verification

```bash
mise exec -- mix test test/jido_claw/cli/repl_args_test.exs   # targeted suite
mise exec -- mix format                                        # enforced
# Definition of done — run bare (NO pipes; a pipe masks the exit code),
# in background, then read the output tail:
mise exec -- mix precommit
```

Optional manual smoke (needs a configured project): `mise exec -- mix jidoclaw --resume=` should print `error: --resume requires a session uuid` + usage to stderr and exit 2.

Flaky-suite reminder: the async:false singleton tests (MCPServer/Prompt/PipelineStore/MultiSandbox) move under load — verify any unrelated failure in isolation before blaming this change.

## Precommit gotchas (checked)

No new modules or public functions (no new `@spec` surface); only a cond branch, tests, and prose. Don't start any comment line with the word "step" (ExSlop EXS3004).

## Commit-ready ending (user commits; nothing staged)

Files touched: `lib/jido_claw/cli/repl_args.ex`, `test/jido_claw/cli/repl_args_test.exs`, `lib/mix/tasks/jidoclaw.ex`, `lib/jido_claw/cli/main.ex`.

Suggested message (or fold into the feature's Unit-5 commit, since it's all uncommitted together):
`fix: reject empty/blank --resume values as usage errors (review P2)`
