# Plan: Close two fail-closed bypasses in the shell-aware `run_command` gate

## Context

The just-finished V2-1 follow-up (`.claude/plans/please-review-docs-exploration-jidoka-fe-goofy-book.md`) replaced the brittle `git commit` regexes with `JidoClaw.Security.ShellCommand`, a `nimble_parsec` shell analyzer feeding `ToolApproval`'s per-tool-call gate. A code review then found **two P1 holes that break the analyzer's core fail-closed contract** ("a false negative is a silent `git commit`"). Both were **reproduced** against the live analyzer (all analyze `gated?=false unknown?=false`):

- **[P1] F1 — dynamic args hide gated operations.** `arg_texts/1` (`shell_command.ex:509`) discards each arg's dyn markers, so the analyzer can't tell a dynamic token from a literal one. Confirmed bypasses: `git $x` / `x=commit; git $x` (dynamic **subcommand**); `sh -c "$cmd"`, `bash -c "$x"`, `sh -c"$cmd"`, `cmd="git commit"; eval "$cmd"` (dynamic **script/eval target** → recursion runs on `""`).
- **[P1] F2 — git inline aliases bypass the matcher.** `git -c alias.ci=commit ci` runs git's `commit` via the aliased `ci`; the matcher only looks for a literal `commit` arg.

**Decisions (Q&A + review amendments):** F1 → **model git's pre-subcommand options completely, or fail closed** — preserve per-arg dyn metadata, resolve the *true* subcommand past git's global flags, and gate when the subcommand position is dynamic. F2 → **close it** — resolve inline `git -c alias.X=Y`. Additional review amendments fold in: gate visible `!`-shell aliases; fail closed on dynamic `-c`/`--config-env` config; gate unknown pre-subcommand flags (don't assume boolean); make arg extraction **redirect-aware** so a redirect target isn't mistaken for the subcommand (`git > out commit`); and make the unit test's `git?/1` use the **exact same matcher opts** as the real gate. Intended outcome: realistic evasions gate, common benign git usage (`git push origin "$branch"`, `git -C "$dir" status`) stays un-gated, and `mix precommit` is green.

## Approach

The git knowledge moves **into `ShellCommand`** (as `@git_*` flag tables + a git-tuned subcommand resolver), not into matcher opts. Rationale: amendments 1–3 (`!`-aliases, dynamic config, unknown-flag completeness) put git-specific *logic* in the resolution walk regardless, and baking the data in keeps the matcher minimal — so `ToolApproval`'s git matcher stays `{:cmd, "git", subcommand: "commit"}` (no opts change) and the unit-test helper calls `command_present?` with that *same* opt set (amendment 5 solved structurally, with the test sourcing the opts from `ToolApproval.require_patterns/0` to lock parity). This is consistent with the module already baking in `@shells`, `@wrappers`, `@control_keywords`. Blast radius stays the predicate layer: verified nothing outside `shell_command.ex`/its test reads `Command.args`; `tool_approval.ex` only calls `analyze`/`command_present?`/`structure_present?`.

### `lib/jido_claw/security/shell_command.ex`

**1. Preserve per-arg dyn metadata.** Add a parallel field to `Command`:
```elixir
defstruct cmd: nil, args: [], arg_dyns: []   # arg_dyns :: [[atom()]], 1:1 with args
```
A *new* field keeps every existing `args: [...]` test assertion passing (struct patterns ignore unlisted keys). Update `Command.@type`.

**2. Redirect-aware arg extraction (amendment 4).** Replace `arg_texts/1` (which filters to all `{:word, …}` and so keeps a redirect's *target* word — `git > out commit` extracts `["out","commit"]`, confirmed) with `extract_args/1` that walks the post-command elements and, for a `{:redirect, raw}` with `redirect_meta(raw).needs_target?`, drops the following target word (reusing the existing `redirect_meta/1` + `drop_leading_word/1` that `strip/1`'s leading-redirect clause already uses). `strip/1`'s `:command` branch builds the `Command` by `Enum.unzip`-ing `extract_args(rest)` into `args`/`arg_dyns`. This fixes redirects in any position for the git walk, the generic resolver, and interpreter recursion at once.

**3. Git-tuned, complete-or-fail-closed subcommand resolver (F1 + F2 + amendments 1–3).** Dispatch the subcommand check on the command name:
```elixir
defp command_match?(%Command{cmd: cmd} = c, name, opts),
  do: cmd == name and subcommand_ok?(c, name, Keyword.get(opts, :subcommand))
defp subcommand_ok?(_c, _name, nil), do: true
defp subcommand_ok?(c, "git", sub), do: git_subcommand_match?(c, sub)   # git is the only subcommand matcher
defp subcommand_ok?(c, _name, sub), do: generic_subcommand_match?(c, sub) # first non-flag ==sub or dynamic
```
`git_subcommand_match?/2` zips `args`+`arg_dyns` into `{text, dyns}` pairs and runs `git_walk/2`, which steps over git's pre-subcommand global options using three baked tables, collecting inline alias definitions, and **fails closed (`:gate`)** wherever it can't resolve:
- `@git_path_value_flags` (`-C --git-dir --work-tree --namespace --super-prefix --attr-source`) — separate value; skip flag + value (a **dynamic** value is fine — `git -C "$dir" status` stays benign).
- `@git_config_flags` (`-c --config-env`) — alias-capable value: **dynamic value ⇒ `:gate`** (amendment 2 — could be `alias.ci=commit`); a literal `alias.<name>=<value>` ⇒ record `name => expansion` (for `--config-env`, the body lives in an env var ⇒ record as `:opaque`); otherwise skip.
- `@git_bool_flags` (`-p --paginate -P --no-pager --bare --no-replace-objects --no-lazy-fetch --no-optional-locks --no-advice --literal-pathspecs --glob-pathspecs --noglob-pathspecs --icase-pathspecs --exec-path --html-path --man-path --info-path --version --help -h`) — skip one.
- A bundled `--flag=value` ⇒ classify by the prefix before `=` (known value/config/bool ⇒ handle; config ⇒ inspect for alias; **unknown prefix ⇒ `:gate`**).
- **Any other `-`-leading token ⇒ `:gate`** (amendment 3 — unknown pre-subcommand flag, never assumed boolean).

The first non-flag token is the subcommand candidate. Resolution gates (returns **true**) when `git_walk` yields `:gate`, or the candidate is **dynamic** (`dyns != []` — F1 dynamic subcommand, incl. `git -C "$d" $x`), or its text `== sub`.

**Recursive alias resolution (review amendment).** When the candidate is a recorded alias, resolve its expansion *through the same git walk* rather than a shallow "first token == sub" check — git aliases chain (`alias.ci=co`, `alias.co=commit`) and alias bodies can begin with git global options (`alias.ci='-c user.name=x commit'`). A `resolve(pairs, aliases, sub, depth)` loop runs `git_walk` (carrying/accumulating the alias map), and on a candidate that is an alias re-tokenizes its expansion into pairs and recurses at `depth + 1`. Fail-closed throughout: `depth > @git_alias_depth` (cap ~8) ⇒ gate (covers **cycles** like `ci=co, co=ci`); an expansion starting with `!` ⇒ gate (amendment — visible `!`-shell alias); `:opaque` (`--config-env`) ⇒ gate; a re-tokenize that doesn't fully consume ⇒ gate; an alias body that resolves to **no** subcommand at `depth > 0` ⇒ gate (the real subcommand would come from trailing args we don't model). A non-alias literal `!= sub` ⇒ benign (e.g. nested aliases ending in `status`); top-level no-subcommand (`git`, `git -c x`) ⇒ benign. Keep helpers small + spec'd (credo cyclomatic ≤11 / nesting ≤3; the lone `cond` in `git_walk` has ~6 arms).

**4. Dynamic script/eval ⇒ `unknown?` (fail closed).** Thread dyns into interpreter recursion:
- `shell_script/1` consumes `{text, dyns}` pairs, returns `nil | :dynamic | {:script, String.t()}` — `:dynamic` when the `-c`-bearing arg carries dyns (`sh -c"$x"`) or the resolved script token is dynamic (`sh -c "$cmd"`).
- `recursion_scripts/1`: shells → `shell_script(zip(args, arg_dyns))`; `eval` → `:dynamic` if any arg dynamic else `{:script, Enum.join(args, " ")}`.
- `merge_recursions/3`: `:dynamic → %{acc | unknown?: true}`; `{:script, s} → merge(acc, do_analyze(s, depth+1))`.
- `piped_bare_shell?/1` → `shell_script(pairs) == nil`.

This also fails closed on `sh -c "git status $x"` (the literal recursion can't see `$x` could be `&& git commit`).

**5. Moduledoc.** Document the git-aware resolver and shrink "Documented residuals" to just login/startup-file aliases and script-file indirection (`bash deploy.sh`, `sh < deploy.sh`).

### `lib/jido_claw/security/tool_approval.ex`

Matcher and `valid_matcher?/1` **unchanged** (`{:cmd, "git", subcommand: "commit"}`). Only the moduledoc "What is gated" / residuals paragraph updates to reflect the git-aware resolution and the shrunk residual set.

### Tests

`test/jido_claw/security/shell_command_test.exs` (pure, `async: true`) — **source the git opts from `ToolApproval.require_patterns/0`** so `git?/1` can never drift from the gate (amendment 5):
```elixir
defp git_opts do
  {_param, matchers} = ToolApproval.require_patterns()["run_command"]
  Enum.find_value(matchers, fn {:cmd, "git", o} -> o; _ -> nil end)
end
defp git?(cmd), do: SC.command_present?(SC.analyze(cmd), "git", git_opts())
```
Add cases:
- *Redirect-aware (amendment 4):* `git?` for `git > out commit`, `git commit > out`.
- *F1 dynamic subcommand gates:* `git?` for `git $x`, `x=commit; git $x`, `git -C "$d" $x`, `git -C "my dir" $x`. *Benign:* `refute git?` for `git push origin "$branch"`, `git checkout "$b"`, `git diff "$range"`, `git -C "$dir" status`.
- *F1 dynamic script/eval → unknown:* `unknown?` for `sh -c "$cmd"`, `bash -c "$x"`, `sh -c"$cmd"`, `eval "$cmd"`, `sh -c "git status $x"`, `cmd="git commit"; sh -c "$cmd"`. Keep `git?` for literal `sh -c "git commit"` / `eval "git commit"` (regression guard).
- *F2 + amendments:* `git?` for `git -c alias.ci=commit ci`, `git -c alias.x='commit -a' x`, `git -c alias.x='!git commit' x` (`!`-alias), `git -c "$cfg" ci` (dynamic config), `git --frobnicate commit` (unknown flag), **`git -c alias.ci=co -c alias.co=commit ci`** (nested alias→commit), **`git -c alias.ci='-c user.name=x commit' ci`** (alias body with global option), **`git -c alias.ci=co -c alias.co=ci ci`** (cycle → depth-cap gate). *Benign:* `refute git?` for `git -c alias.ci=status ci`, **`git -c alias.ci=st -c alias.st=status ci --short`** (nested→status), **`git -c alias.ci='-c user.name=x status' ci --short`** (global-option alias→status). Keep existing `git -c user.name=x commit`, `git --git-dir=.git commit`, `git -C repo commit` green.

`test/jido_claw/security/tool_approval_test.exs` — extend the must-pend loop with `git $x`, `sh -c "$cmd"`, `eval "$cmd"`, `git -c alias.ci=commit ci`, `git > out commit`, `git --frobnicate commit`; extend benign pass-through with `git push origin "$branch"` and `git -C "$dir" status`. Existing pend→approve→execute-once→re-pend and config-sanity sweeps stay untouched.

### `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` (only if it enumerates the now-closed forms)

Reconcile the V2-1 residual paragraph to the shrunk residual set, consistent with the prior plan's "reconcile the whole entry" rule.

## Critical files

| File | Change |
| --- | --- |
| `lib/jido_claw/security/shell_command.ex` | `Command.arg_dyns`; redirect-aware `extract_args/1`; git tables + `git_walk`/`git_subcommand_match?` (F1 dynamic subcommand, F2 alias, `!`-alias, dynamic-config, unknown-flag — complete-or-fail-closed); dynamic script/eval → `unknown?`; moduledoc. |
| `lib/jido_claw/security/tool_approval.ex` | Moduledoc residuals only (matcher unchanged). |
| `test/jido_claw/security/shell_command_test.exs` | `git?/1` sources opts from `ToolApproval`; F1/F2/amendment + benign/regression cases. |
| `test/jido_claw/security/tool_approval_test.exs` | Newly-closed bypasses in must-pend; benign dynamic forms in pass-through. |
| `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` | Residual reconciliation (if it lists the closed forms). |

## Verification

**End-to-end bar: `mix precommit` passes** (`jidoclaw.compile_check` → `format --check-formatted` → `reach.check --arch --smells --strict` → `credo --strict` → `dialyzer` → `test`). Run the full suite — not just compile+test — and do **not** pipe it through `tail`.

Precommit watch-items: keep new `defp`s small, `@spec`'d, and **distinct-bodied / non-contiguous** to avoid the ExSlop clone check (min_mass 30); give `shell_script`'s `:dynamic | {:script, _}` and `git_walk`'s `:gate | {candidate, aliases}` consistent specs through their call chains.

Targeted runs while iterating:
```
mix compile
mix test test/jido_claw/security/shell_command_test.exs
mix test test/jido_claw/security/tool_approval_test.exs
mix credo --strict lib/jido_claw/security/shell_command.ex
```

Empirical re-check via Tidewave `project_eval` (pure — the same path that reproduced the findings); `g` uses the gate's exact opts:
```elixir
alias JidoClaw.Security.ShellCommand, as: SC
g = fn c -> SC.command_present?(SC.analyze(c), "git", subcommand: "commit") end
# gate (was bypass): all true
Enum.map(["git $x", "x=commit; git $x", "git -C \"my dir\" $x",
          "git -c alias.ci=commit ci", "git -c alias.x='!git commit' x",
          "git -c \"$cfg\" ci", "git --frobnicate commit", "git > out commit",
          "git -c alias.ci=co -c alias.co=commit ci",        # nested
          "git -c alias.ci='-c user.name=x commit' ci",      # alias body w/ global opt
          "git -c alias.ci=co -c alias.co=ci ci"], g)        # cycle → depth-cap
# fail closed: unknown? true
Enum.map(["sh -c \"$cmd\"", "eval \"$cmd\"", "bash -c \"$x\""], &SC.analyze(&1).unknown?)
# stay benign: all false
Enum.map(["git push origin \"$branch\"", "git -C \"$dir\" status",
          "git -c alias.ci=status ci", "git status",
          "git -c alias.ci=st -c alias.st=status ci --short",       # nested → status
          "git -c alias.ci='-c user.name=x status' ci --short"], g) # global-opt → status
```
