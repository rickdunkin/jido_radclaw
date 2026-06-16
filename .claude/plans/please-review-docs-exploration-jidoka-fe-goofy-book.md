# Plan: Shell-aware `run_command` approval predicates (V2-1 follow-up)

## Context

The Jidoka-V2 borrowing program (`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md`) is, per its own "Program status", complete — V2-1/2/4/6 all shipped. What remains are deliberate deferrals and documented residual risks. Asked to pick the highest-value next step, you chose **V2-1's deferred "richer approval predicates"** — the most threat-model-aligned remaining item (the project weights *LLM-misbehavior containment* highest).

**The problem.** The per-tool-call approval gate (`JidoClaw.Security.ToolApproval`) catches shell-equivalents of gated tools — e.g. `run_command "git commit ..."` is the shell version of the gated `git_commit` tool — using **regexes over the raw command string**:

```elixir
~r/\bgit(?:\s+-{1,2}\S+(?:\s+\S+)?)*\s+commit\b/   # git commit
~r/\bcrontab\b/                                     # crontab
```

These have documented **false-negative holes**. `run_command` hands the string to a shell (`backend_host.ex:135` → `sh -c …`; SSH backend → remote `shell -lc …`; the gate runs *before* dispatch, so it's backend-agnostic), so any gap between "what the regex matches" and "what the shell executes" is a containment hole: `git -C "my dir" commit` (quoted space breaks the regex), **multiline** strings, `||`/`|`/`&` separators, `FOO=bar git commit`, `sudo git commit`, `/usr/bin/git commit`, `sh -c "git commit"`, `if true; then git commit; fi`.

**Intended outcome.** Replace the brittle regexes with a small, auditable, **shell-aware analyzer** that tokenizes the command the way a shell would, splits on shell separators, resolves the real command word, and matches on token structure — closing the realistic LLM evasion vectors while keeping the existing escape valve (add `run_command` to the global `require` list for total containment) and the documented posture that a false positive merely asks for approval.

## Decisions (from planning Q&A + plan review)

1. **Coverage = maximize**, with **fail-closed** semantics throughout: beyond quoting/separators/multiline/env/wrapper-words/paths/`sh -c`, also handle (a) **wrappers with value-taking flags** (`sudo -u user`, `nice -n 10`, `timeout 5`, `env -i`), (b) **shell control/compound/function syntax** (`if/for/while/case`, `( )`, `{ }`, `name(){…}`), and (c) **suspicious structure** — gate when the command *contains* command-substitution `$(...)` / backticks or **pipes into a shell** (`| sh`, `base64 -d | bash -e`). Anywhere the analyzer cannot confidently resolve the command (bound breach, unrecognized wrapper flags, undescendable compound form), it returns an **`unknown?` sentinel that fails closed → require approval**, never pass-through.
2. **Parser substrate = `nimble_parsec`** (pure-BEAM Dashbit combinator; already transitive in `mix.lock`, promote to a direct dep). Researched first: **no drop-in shell-parser exists on Hex**. A Rust NIF was considered and declined — `shell-words`/`shlex` crates only do quote/escape word-splitting (the easiest ~30%; no `;`/`&&`/`|` splitting, no `$()` structure), the project compiles no Rust locally (cargo absent; `extractous_ex` uses *precompiled* NIFs), and moving a security component into native code removes it from the project's own dialyzer/credo/reach analysis. `nimble_parsec` gives a battle-tested engine in pure BEAM that surfaces token types while keeping the security logic auditable in Elixir.

## Scope boundary (post-maximize residuals — documented, not bugs)

Pinned by pass-through tests (escape valve = gate all `run_command`): shell **aliases/functions not visible in the command string** (sourced from login/startup files — host runs spawn a fresh `sh -c` per call, so these come from a remote/login shell's `.bashrc`/`.profile`-style startup, not from a prior command in the same session) and **script-file indirection** (`bash deploy.sh`, and a shell reading a named file via stdin redirection `sh < deploy.sh` — local files we can't read; distinct from here-docs `<<` and `| sh`'s *dynamic* stdin, both of which **are** gated). Note: a *visible* function definition like `f(){ git commit; }; f` is **gated** (body descended); `$()`/`| sh` presence, **here-docs feeding a shell** (`sh <<EOF…`), and **parameter-expansion command words** (`$GIT commit`, `git${IFS}commit` — via `unknown?`) are all gated even though opaque. (`$VAR`/`${…}` in *argument* position stays benign — it doesn't obscure the command word, e.g. `git commit -m "$MSG"` gates on the literal `git commit`, not the var.)

## Approach

A new pure module `JidoClaw.Security.ShellCommand` does the shell analysis on top of `nimble_parsec`; `ToolApproval` swaps its regex matching for a small matcher-dispatch that consumes it. The gate's reason tuple (`{:pattern, :command}`), error envelopes, producer (`ToolApprovals`), and fingerprint stay **unchanged** — blast radius is the predicate layer only. Model the module on **`lib/jido_claw/security/destination_policy.ex`** (the house-style pure, fail-closed security parser).

> Do **not** reuse `Jido.Shell.Command.Parser` (jido_shell dep): it only splits `;`/`&&`, lacks `| || & \n`, and returns `{:error, :unclosed_quote}` rather than best-effort (`session_manager.ex:75-85` documents that gap).

### New module: `lib/jido_claw/security/shell_command.ex`

A gate *heuristic*, not a shell — it deliberately over-recognizes (false positive = ask for approval = fine; false negative = silent `git commit` = the failure to avoid). State this contract in the moduledoc. Types + public API (need `@spec` — `Readability.Specs` + dialyzer are in precommit):

```
# First-class result structs (Dialyzer/reach-friendly; unknown? is the sentinel).
defmodule JidoClaw.Security.ShellCommand.Command do
  defstruct cmd: nil, args: []                  # cmd: String.t() | nil, args: [String.t()]
end
defmodule JidoClaw.Security.ShellCommand.Analysis do
  defstruct commands: [], structure: [], unknown?: false
  #   unknown? == true ⇒ analysis incomplete/ambiguous ⇒ fail closed (gate)
  #   structure ⊆ [:command_substitution, :backtick, :pipe_to_shell]
end
@type t :: %Analysis{commands: [%Command{}], structure: [atom], unknown?: boolean}
analyze(String.t()) :: t
command_present?(t, name :: String.t(), opts :: keyword()) :: boolean   # %Analysis{unknown?: true} ⇒ true
structure_present?(t, kinds :: [atom()]) :: boolean                     # kinds == [] ⇒ false; else %Analysis{unknown?: true} ⇒ true
```

**`analyze/1` pipeline:**

0. **Pre-pass (before tokenizing):** (a) **input-length cap first** — if `byte_size(command)` exceeds the cap (e.g. 64 KB), return `%Analysis{unknown?: true}` *immediately, without parsing* (the DoS guard runs ahead of splicing and `nimble_parsec`); (b) **splice line-continuations** — remove backslash-newline (`\<newline>`) so `git \<newline> commit` is one command. This splice is a deliberately **over-recognizing heuristic**, not exact shell behavior: a shell keeps `\<newline>` literal inside single quotes, but splicing globally can only over-gate, never under-gate — acceptable for a gate.
1. **Tokenize** via a `nimble_parsec` grammar (`defparsecp`) → a typed token stream: `{:word, string}` (adjacent single/double-quoted + bare runs concatenated into one word — closes `-C "my dir"`), `{:op, :and|:or|:pipe|:semi|:amp|:newline}`, group/compound tokens `{:op, :subshell_open|:subshell_close|:brace_open|:brace_close}` for `( ) { }`, and `{:subst, :command|:backtick}` markers for `$(` / backtick. Quote/escape handling is in the grammar: `$(`/backtick are **literal** (no `:subst`) inside single quotes *or* when backslash-escaped (`echo '$(x)'`, `echo \$(date)`, escaped backtick). Redirect tokens carry metadata — `{:redirect, needs_target?: bool, fused?: bool, heredoc?: bool}` — so the normalizer knows whether a following word is the target: self-contained dups (`2>&1`, `>&2`, `&>`) ⇒ `needs_target?: false`; fused (`>out`, `2>/dev/null`) ⇒ target already in-token; separated (`2> /dev/null`) ⇒ consume the next word. **Here-docs / here-strings** (`<<`, `<<-`, `<<<`) ⇒ `heredoc?: true`. **Totality:** top-level is `repeat(choice([…all tokens…, any-single-char fallback]))`, so the parser consumes every byte and never returns `{:error,…}`; `analyze/1` treats any non-`{:ok, _, ""}` shape as **`unknown?: true`**.
2. **Split into sub-commands** on the `:op` separators `;`,`&&`,`||`,`|`,`&`,newline and the group/compound boundaries (drop empty), **retaining each boundary's connector** (needed for pipe-to-shell). Multiline `\n` splitting is the single highest-value fix.
3. **Resolve command word** per sub-command via one re-looping leading-prefix normalizer that strips, as transparent prefixes:
   - leading `VAR=value` env-assignments (all);
   - leading redirect ops, consuming a following target word **only when** `needs_target? and not fused?` (so `2>&1 git commit`, `2>/dev/null git commit`, `2> /dev/null git commit`, `>out git commit` all leave `git commit` intact). **A `heredoc?: true` redirect ⇒ `unknown?: true`** (shell reads executable stdin — `sh <<EOF … EOF` is the `curl | sh` class; we will not parse the body);
   - leading **shell control keywords / group openers** (`if then elif else fi for while until do done case in esac`, `(`, `{`, and a leading function signature `name ( )`), so a gated command inside a control structure / group / function body resolves and gates;
   - leading **wrapper words** (`sudo env nohup nice command exec setsid stdbuf doas time builtin timeout ionice`) with a **per-wrapper flag-arity table as data** (`sudo -u <v>`, `nice -n <v>`, `timeout <v>`, `env -i`/`-u <v>`/`VAR=val`, and `--` end-of-options on any wrapper). **If a recognized wrapper is followed by an unrecognized flag sequence** (can't confidently locate the command word — e.g. `sudo -X …`, `env -S "git commit"`) ⇒ set **`unknown?: true`** (gate), don't guess.
   Then `cmd = Path.basename/1` of the next token; rest are `args`. **A command-word token containing a parameter expansion** (`$VAR` or `${…}` — e.g. `$GIT commit`, `git${IFS}commit`) ⇒ **`unknown?: true`**: the real command word is runtime-dynamic and can't be statically resolved (this closes `${IFS}` token-boundary injection). `$VAR`/`${…}` in *argument* position is unaffected (it doesn't change the command word). Any compound/control token the normalizer can't confidently descend ⇒ **`unknown?: true`**.
4. **Detect structure** → `:command_substitution`/`:backtick` from `{:subst,…}` tokens; `:pipe_to_shell` when a `:pipe`-connected sub-command's command word — **resolved through wrappers** (so `sudo sh`/`env sh` count) — is in `{sh bash zsh dash ash ksh}` **and has no `-c`** (a bare shell reading the pipe, incl. `sh -s`, `bash -e`). A `-c` on the pipe RHS instead diverts to script recursion (below), not a pipe-gate.
5. **Remaining bounds — all fail closed via `unknown?: true`:** sub-command count cap (e.g. 256) → `unknown?`; interpreter/eval recursion depth > 3 → `unknown?`. (The input-length cap runs first, in step 0.) **In sum, `unknown?` is set by:** parse-incomplete, over-length, count/depth caps, here-doc, parameter-expansion command word, unrecognized wrapper flags, and undescendable compound syntax — every one gates.

**`command_present?/3`:** `analysis.unknown? or <direct-or-recursive match>`, where direct match = some sub-command has `cmd == name` AND (no `:subcommand`, OR the subcommand ∈ its **non-flag args** — the "any non-flag arg" rule, not "first arg", keeps `git -C "my dir" commit` matching). **Interpreter/eval recursion** (depth-bounded): if `cmd ∈ shells` and a `-c` trigger is present — exact `-c`, **bundled** `-lc`/`-ec`, no-space `-c<script>`, **or `-c` past other shell options** (`bash -o pipefail -c "git commit"`) — recursively `analyze` the script and re-check; `eval <rest>` joins args and recurses. Recursion re-enters full `analyze/1` so inner stripping runs; exceeding depth 3 ⇒ `unknown?` (gate).

**`structure_present?/2`:** `[] ⇒ false` (nothing to look for, even when `unknown?` — keeps the public API unsurprising); otherwise `analysis.unknown? or Enum.any?(kinds, & &1 in analysis.structure)`. The `unknown?` fail-closed *floor* is preserved independently by `command_present?` (git/crontab), so an empty `kinds` disables only *structural* gating, never the floor.

**Credo-clean structure** (thresholds: Cyclomatic/Perceived 11, Nesting 3, MaxLineLength 120). `nimble_parsec` *reduces* complexity risk vs. a hand-rolled char loop. Keep post-parse reducers small + spec'd; the prefix-stripper is one tail-recursive function with head clauses (env / redirect / control-keyword / wrapper), **not** a `cond`; the wrapper flag-arity table is **data** (a map), consumed by a tiny matcher. Funnel shared clause bodies through one helper to dodge the ExSlop clone check (min_mass ~30). `# reach:disable-for-this-file <smell>` is the sanctioned escape hatch (precedent `tool_approval.ex:5`).

### Integration: `lib/jido_claw/security/tool_approval.ex`

1. **`@require_patterns`** (lines 82-94) → structured matchers:
   ```elixir
   "run_command" => {:command, [
     {:cmd, "git", subcommand: "commit"},
     {:cmd, "crontab"},
     :structure          # kinds resolved from config, see (3) — NOT hardcoded here
   ]}
   ```
2. **`pattern_match/3`** (lines 201-213): `analyze` the value once, then `Enum.any?(matchers, &matcher_matches?(&1, value, analysis, opts))` — **`opts` is threaded into the dispatch** (the `:structure` clause needs it; the others ignore it):
   ```elixir
   defp matcher_matches?(%Regex{} = re, raw, _a, _opts), do: Regex.match?(re, raw)
   defp matcher_matches?({:cmd, name}, _raw, a, _opts), do: ShellCommand.command_present?(a, name, [])
   defp matcher_matches?({:cmd, name, cmd_opts}, _raw, a, _opts), do: ShellCommand.command_present?(a, name, cmd_opts)
   defp matcher_matches?(:structure, _raw, a, opts) do
     case suspicious_structure_kinds(opts) do
       [] -> false                                            # operator-disabled
       kinds -> ShellCommand.structure_present?(a, kinds)
     end
   end
   ```
   All hits return `{:pattern, :command}` → `reason_suffix/1`, error envelopes, and the "guarded-operation pattern" message test are unchanged. (Note: `command_present?` already fails closed on `unknown?` independent of the structure toggle, so disabling structure gating can never let an *un-analyzable* command slip past the git/crontab matchers.)
3. **Config key for the tunable kinds** — `suspicious_structure_kinds(opts)` reads `opt_or_config(opts, :suspicious_shell_structure_kinds)`, **default** `[:command_substitution, :backtick, :pipe_to_shell]`, `[]` disables. This is a **dedicated config key**, *not* the `@require_patterns` list — because `require_patterns/1` merges config *under* defaults (defaults win, `tool_approval.ex:313`), so a hardcoded kinds list there could not be narrowed by operators. Validation: **non-list / malformed ⇒ fall back to the default** (a typo must not silently disable gating); a literal **`[]` ⇒ disabled** (the only way to turn it off); a non-empty list ⇒ keep the known atoms and **warn-and-drop unknowns**, and if that leaves it empty (all-unknown — a typo) ⇒ fall back to the default rather than silently disabling. Add the key to `@config_defaults`.
4. **`validated_config_patterns/1`** (lines 318-335): `valid_matcher?/1` accepting `%Regex{}` | `{:cmd, name}` | `{:cmd, name, opts}` | `:structure`; rename bound var `regexes`→`matchers`; keep warn-and-skip.
5. **Reuse as-is:** `param_value/2` (atom/string-key normalization — MCP path), `opt_or_config/2`, the `Map.merge(…, @require_patterns)` defaults-win merge.

### Promote the dep & reconcile docs

- **`mix.exs`**: add `{:nimble_parsec, "~> 1.4"}` to deps (already resolved at 1.4.2 → no lock churn; makes direct use explicit so `deps.unlock --unused` stays happy).
- **`tool_approval.ex` moduledoc** (lines 42-48): the `git -C "my dir" commit` "out of regex reach" claim is now false — rewrite to describe shell-aware matching + the new (smaller) residual set; update the `@require_patterns` comments (lines 86-92). Mention the gate is backend-agnostic (host/SSH/VFS) since it runs pre-dispatch.
- **`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md`** V2-1 entry: reconcile the whole entry (not just one line) — the "Deferred … richer approval predicates" line, the "Residual risk" paragraph, and the program-status mention — to reflect what shipped and shrink the residual set to the post-maximize non-goals above.

### Critical files

| File | Change |
| --- | --- |
| `lib/jido_claw/security/shell_command.ex` | **New** `nimble_parsec` analyzer (grammar → split → resolve → `command_present?`/`structure_present?`), `unknown?` fail-closed sentinel. |
| `lib/jido_claw/security/tool_approval.ex` | `@require_patterns` + `:structure`; `pattern_match/3` dispatch; `suspicious_structure_kinds` config key + validation; `validated_config_patterns/1`; moduledoc/comment fixes. |
| `mix.exs` | Promote `nimble_parsec` to a direct dep. |
| `test/jido_claw/security/shell_command_test.exs` | **New** pure unit suite. `async: true`, no `TenantCase`. |
| `test/jido_claw/security/tool_approval_test.exs` | Extend must-pend / must-pass loops; fail-closed + structure + toggle + SSH cases; mixed regex/structured back-compat; rename `{param, _regexes}`→`_matchers` (line 351). |
| `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` | Reconcile the V2-1 entry. |

## Verification

End-to-end bar: **`mix precommit` passes** (`jidoclaw.compile_check` → `format --check-formatted` → `reach.check --arch --smells --strict` → `credo --strict` → `dialyzer` → `test`). No new tool is registered, so `jidoclaw.system_prompt.check` is unaffected.

**Test matrix** (pin every case):

- *Grammar/tokenizer* (`shell_command_test.exs`): quoting (`git -C "my dir" commit` → arg `my dir`), adjacent/nested quotes, escapes (`git\ commit`, `a\&\&b`), **unterminated quote → best-effort, no raise**, empty/whitespace/operators-only, **comments** (`# git commit` whole-line → no commands → pass-through; `echo x # git commit` → trailing comment stripped → cmd `echo`, not gated; `git#x` mid-word and `echo "#x"` in-quotes are **not** comments), **line-continuation** (`git \<newline> commit` → one command `git commit`, not two).
- *Redirect metadata (must still resolve to `git commit`)*: `2>&1 git commit` (self-contained dup, no target eaten), `2>/dev/null git commit` (fused), `2> /dev/null git commit` (separated target), `>out git commit` (fused).
- *Separators*: `a && git commit`, `a || git commit`, `a | git commit`, `git commit &`, **`echo x\ngit commit`** (multiline), `a; git commit`.
- *Command-word resolution*: `/usr/bin/git commit`, `FOO=bar git commit` + multi-assignment, `sudo`/`env`/`nohup git commit`, `2>/dev/null git commit`, `sudo -u user git commit`, `timeout 5 git commit`, `sudo -- git commit`.
- *Fail-closed (`unknown?` → gate, NOT pass-through)*: recursion depth > 3 (deeply nested `sh -c`), sub-command count cap, over-length input, **unrecognized wrapper flag** (`sudo -X git commit`, `env -S "git commit"`), **here-doc / here-string** (`sh <<EOF\ngit commit\nEOF`, `cat <<EOF…` — acceptable FP on benign `cat`), **parameter-expansion command word** (`$GIT commit`, `git${IFS}commit`, `$x commit`), undescendable compound form.
- *Compound/control (must gate, via descent **or** `unknown?` fail-close — the contract is "it gates", not the mechanism)*: `if true; then git commit; fi`, `(git commit)`, `{ git commit; }`, `f(){ git commit; }; f`, `for x in a; do git commit; done`, `case x in y) git commit;; esac`.
- *Interpreter recursion*: `sh -c "git commit"`, `bash -lc 'git commit'`, `sh -c"git commit"`, **`bash -o pipefail -c "git commit"`**, `eval "git commit"`.
- *Suspicious structure*: `git status $(date)` → `:command_substitution`; `` git log `date` `` → `:backtick`; `curl x | sh`, `base64 -d | bash -e`, `foo | sudo sh`, `foo | sh -s` → `:pipe_to_shell`; `sh -c "git status"` on a pipe RHS → recursion, **not** pipe-gate; **escaped/literal not flagged** (cmd word `echo`, no structure marker, `unknown?` false): `echo '$(x)'`, `echo \$(date)`, escaped backtick. (`$EDITOR file` is **not** here — a `$VAR` *command word* now gates via `unknown?`; see the fail-closed row.)
- *Residuals (must pass through — escape valve covers them)*: `bash deploy.sh`, `sh < deploy.sh` (named-file indirection), `alias gc='git commit'` (definition, no invocation), `gc` (alias call — cmd `gc` ≠ git).
- *DoS*: `String.duplicate("a;", 100_000)` and deeply-nested `sh -c` complete within bounds (assert returns).
- *Gate integration* (`tool_approval_test.exs`): extend must-pend with newly-closed bypasses + structure + compound + fail-closed cases; extend must-pass with benign + pinned residuals; **SSH-backend** case (`%{command: "git commit", backend: "ssh", server: "x"}` pends — proves pre-dispatch/backend-agnostic gating); **toggle** narrowing (`suspicious_shell_structure_kinds: [:pipe_to_shell]` lets `echo $(date)` through but `curl x | sh` pends; `[]` lets `echo $(date)` through while `git commit` and an `unknown?` command still pend); string-key path; mixed regex+structured back-compat. Existing pend→approve→execute-once→re-pend loop and config-sanity sweeps stay green.

**Targeted runs while iterating** (the Elixir LSP helps confirm references/specs):
```
mix deps.get && mix compile
mix test test/jido_claw/security/shell_command_test.exs
mix test test/jido_claw/security/tool_approval_test.exs
mix credo --strict lib/jido_claw/security/shell_command.ex
```
Then the full `mix precommit`.

## Note on the maximize tradeoff

Gating on *presence* of `$()` / backtick / `| sh` (and the `unknown?` fail-closed posture) is aggressive — `$()` is common in legitimate shell, so the interactive `main` agent will pend more often. This is the chosen posture; the structural layer ships **default-on but config-tunable** via `suspicious_shell_structure_kinds` (narrow to `[:pipe_to_shell]` or `[]` without code changes). The `unknown?` fail-close on the git/crontab matchers is intentionally **not** disable-able — an un-analyzable command must require approval.
