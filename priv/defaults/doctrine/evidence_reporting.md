## Evidence reporting (claims the engine cross-checks)

Your output includes an optional `evidence` block. Fill it with the facts of what
you actually ran, so the engine can verify your claims against the tool transcript:

- `evidence.commands_run` — the EXACT command invocations you executed (as you ran
  them, not paraphrased).
- `evidence.tests_passed` — test commands that ran to completion and exited green.
  Never list a test here if it was skipped, filtered, or its exit code was swallowed
  by plumbing (an unprotected `| tail`/`| grep`, `|| true`) — run tests clean, read
  the real exit code, and report that.

Keep `files_changed` accurate: every path you created or edited, no paths you did
not touch.

Report honestly. An absent `evidence` block is fine; a fabricated entry is not — the
engine checks every claim against the recorded tool calls and the working tree, and
an unsupported claim becomes a blocking finding against your stage.
