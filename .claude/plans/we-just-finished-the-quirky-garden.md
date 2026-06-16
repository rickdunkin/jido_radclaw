# Plan: Effects-based refactor of the `run_command` shell approval analyzer

## Context

We just shipped the shell-aware `run_command` approval gate (`JidoClaw.Security.ShellCommand` +
`JidoClaw.Security.ToolApproval`, uncommitted on `main`) per
`.claude/plans/please-review-docs-exploration-jidoka-fe-goofy-book.md`. A code review argued the
design keeps "asking whether this command matches `git commit`" and bolts each new injection case
onto `command_present?/3`, and recommended refactoring around **semantic risk facts (effects)**:
split `git` into its own interpreter, parse `git config` key positions deliberately, gate on
effects, and make tests assert *reasons*.

**Verification result.** Of the review's five examples, four already behave correctly. **One
validated correctness bug:** `git_config_injection?/1` (`shell_command.ex:446`) resolves the
sub-command is `config`, then `Enum.any?(pairs, &config_inject_arg?/1)` scans **all args
position-independently** for a *literal* `alias.*`/`include.*` key. A **dynamic** key collapses to
empty text, so `git config "$key" commit` — and the real bypass `K=alias.ci; git config "$K"
commit; git ci` — slips the gate yet injects an alias and commits at runtime.

**Scope: the full effects refactor**, adopting the review's design *and* the follow-up refinements:
- **`:git_commit` stays honest** — emitted only for a *definitively resolved* commit. Git-resolution
  uncertainty (unknown flag, dynamic sub-command, alias cycle, `!`-shell alias, opaque config-env)
  becomes `{:opaque, %{scope: :git, reason: …}}`, never a false `:git_commit`.
- **The `git config` state machine models git's real grammar** — config options can appear *before
  and after* an optional action word (`set`/`get`/`rename-section`/…); read/unset modes are
  distinguished from writes; **`edit` (`-e`/`--edit`) gates** (a scriptable persistent-config
  mutation surface); **section-level mutation** (`rename-section foo alias`) is gated (it plants
  `alias.*` without an `alias.*` key token).

The parsing substrate is untouched, **intended gating behavior is preserved** (with a few reads/
removals over risky keys no longer over-gated — see §6), and the dynamic-key bug is closed. The bar
for "done" is **`mix precommit` green**.

## Approach

Keep the `nimble_parsec` grammar, `coalesce`, `split`, command-word resolution (`strip`/wrappers/
redirects), structure detection, `sh -c`/`eval` recursion, and all bounds **exactly as they are**.
Change only the *result shape* and the *git interpreter*:

1. `analyze/1` returns `%Analysis{commands, structure, effects, opaque?}` — `effects` is a list of
   honest semantic risk facts `{kind, evidence}`; `opaque?` renames `unknown?`;
   `git_config_env_seen?` is removed (folded into an effect).
2. All git logic moves to a new `JidoClaw.Security.ShellCommand.Git` interpreter that turns a
   resolved git `Command` into an `%Invocation{}` of facts — including a **deliberate `git config`
   state machine over git's real grammar** (the bug fix + the refinements).
3. `ShellCommand` derives `effects` from commands + structure + git invocations + env in one small
   reducer.
4. `ToolApproval` gates **on effects, declaratively**: the built-in `run_command` matcher list
   becomes `{:effect, kind}` entries (floor) + `:structure` (tunable).
5. Tests assert effects/reasons (`assert_effect`, `assert_opaque`) and two invariants.

Model the modules on `lib/jido_claw/security/destination_policy.ex` (data-table attributes,
`@type`/`@spec`, small section-grouped private helpers).

## Design

### 1. Effect taxonomy & new `%Analysis{}`

An effect is `{kind, evidence}`; `kind` drives gating, `evidence` (`%{reason: atom(), ...}`) is
informational (tests/logging). **Facts stay honest**: a kind asserts what is *known*, not a
fail-closed guess.

```elixir
@type effect_kind ::
        :git_commit                    # DEFINITIVE: resolved git sub-command (literal or fully-resolved alias) IS commit
        | :git_config_injection        # KNOWN config injection into a git run: inline -c (dynamic/include/--config-env) OR a GIT_CONFIG_* env mutation + a git cmd
        | :git_config_persistent_write # `git config` that PLANTS config (alias/include write, dynamic key, rename-to-risky-section, or editor mutation)
        | :crontab
        | :command_substitution | :backtick | :pipe_to_shell   # tunable structure
        | :opaque                       # fail-closed: analysis could not resolve (scope ∈ {:parse, :interpreter, :git})
@type evidence :: %{optional(atom()) => term()}
@type effect :: {effect_kind(), evidence()}
```

```elixir
defmodule Analysis do
  @moduledoc "..."
  defstruct commands: [], structure: [], effects: [], opaque?: false
  @type t :: %__MODULE__{commands: [Command.t()], structure: [atom()], effects: [...], opaque?: boolean()}
end
```

- **Honest `:git_commit`.** Emitted *only* when a sub-command resolves to `commit` (literal, or an
  alias chain that fully expands to commit). Git uncertainty does **not** masquerade as `:git_commit`.
- **`:opaque` is the single fail-closed fact, carrying `scope`.** `%{scope: :parse, reason: …}`
  (incomplete parse, over-length, count/depth cap, here-doc, dynamic command word, unrecognized
  wrapper flag), `%{scope: :interpreter, reason: :dynamic_interpreter}` (`sh -c "$cmd"`/`eval "$x"`),
  `%{scope: :git, reason: …}` (`:unknown_flag` | `:dynamic_subcommand` | `:alias_cycle` |
  `:shell_alias` | `:opaque_config_env`). **Invariant (tested): `opaque?: true` ⟺ at least one
  `{:opaque, _}` effect is present** — `opaque?` is set whenever any opacity (parse, interpreter, or
  git-resolution) is detected.
- `structure` keeps its `[atom()]` shape (so `structure_present?/2` and the toggle path are
  unchanged); the same atoms are *also* emitted as structure effects from the one `detect_structure/2`
  output (no drift).
- **New public predicate** `has_effect?/2` (`@spec has_effect?(t(), effect_kind()) :: boolean()`):
  `Enum.any?(effects, &match?({^kind, _}, &1))`.
- **Keep `command_present?/3` and `structure_present?/2` as thin, spec'd, effect-based shims** — they
  back the unit-test helpers (`git?`/`cron?`/`struct?`) and any operator-config `{:cmd,…}` matcher.
  `command_present?(_, "git", subcommand: "commit")` returns the **git floor** (`:git_commit` |
  `:git_config_injection` | `:git_config_persistent_write` | `opaque?`) — so `git?` stays true for
  every gated git case, *including* the now-honest git-opacity ones (via `opaque?`). The generic
  clause keeps the existing `first_non_flag` logic for other names. `structure_present?/2` is today's
  lines 381-386 with `unknown?`→`opaque?`.

### 2. New module `JidoClaw.Security.ShellCommand.Git` (`lib/jido_claw/security/shell_command/git.ex`)

Owns everything git: the global-option walk (`git_walk/2` + helpers), `resolve_git/4`, alias
machinery (`judge_git_candidate`, `resolve_git_alias`, `reresolve_git_alias`, `parse_alias_config`,
`record_alias`, `alias_entry`), the global-flag tables (`@git_path_value_flags`, `@git_config_flags`,
`@git_bool_flags`, `@git_alias_depth`), and the **new `git config` state machine**. `config_section/1`
and `before_eq/1` move here.

```elixir
defmodule Invocation do
  @moduledoc "Semantic facts from one resolved `git` Command."
  defstruct subcommand: nil,        # {:literal, "config"} | {:dynamic, token} | nil
            commits?: false,        # resolved sub-command (incl. via fully-resolved alias) IS commit
            inline_injections: [],  # [{:inline_c, key} | {:config_include, key} | :config_env_var | :dynamic_inline_c]
            config_writes: [],      # [{:alias_write, key} | {:include_write, key} | :dynamic_key | {:rename_to, section} | :dynamic_section | :config_edit]
            opaque_reason: nil       # nil | :unknown_flag | :dynamic_subcommand | :alias_cycle | :shell_alias | :opaque_config_env
  @type t :: %__MODULE__{...}
end
```

**Public entry — re-tokenizer injected as a closure** (keeps the parent grammar single-sourced,
avoids a module cycle, keeps `Git` independently testable):

```elixir
@spec facts(JidoClaw.Security.ShellCommand.Command.t(), (String.t() -> [pair()] | :error)) :: Invocation.t()
def facts(%Command{} = command, retokenize) when is_function(retokenize, 1)
```

The parent calls `Git.facts(cmd, &retokenize_args/1)`. (`pair :: {String.t(), [atom()]}` is promoted
from `@typep` to `@type` on the parent so `Git` can name `ShellCommand.pair()`.)

The existing `git_walk/2`/`resolve_git/4`/`judge_git_candidate/5` move over, retargeted from
returning the `:gate` boolean to **accumulating honest facts**: `commits?: true` only when the
candidate (or a fully-resolved alias chain) equals `"commit"`; `opaque_reason` set for any
git-resolution uncertainty; inline `-c`/include/`--config-env` push onto `inline_injections`. The
alias depth cap (cycle → `opaque_reason: :alias_cycle`) and `no_subcommand_gate?/1` (benign at top
level, opaque inside an alias body) carry over. An alias resolving to a benign sub-command sets none
of the facts (preserves the `alias.ci=status` pass-through).

#### 2a. The `git config` state machine (the fix + refinements)

Replaces `git_config_injection?/1` + `config_inject_arg?/1`. After the global walk yields
`subcommand: {:literal, "config"}`, resolve git's **real** config grammar (confirmed via
`git help config` / `git config -h`):

```
git config [config-opts] [<action>] [config-opts] <key|sections> [value]
  actions (v2.46+): list | get | set | unset | rename-section | remove-section | edit
  legacy positional: git config [config-opts] <key> [value]      (write); <key> alone is a read
```

Tables as DATA (supersets only over-gate reads, which is acceptable; the ONE invariant: no entry may
consume the *write-key* token, so every value-taking write option lives in skip-value, not bool):

```elixir
# flag + 1 NON-key value (separate form; bundled --opt=val is one token, handled by the = branch)
@config_skip_value_opts ~w(-f --file --blob -t --type --default --value --url)
# read/removal modes that take a KEY arg — INTENTIONALLY ALLOWED (cannot plant config a later git
# honors): consume flag + key → benign. (--get-urlmatch takes key + url = 2 args.)
@config_read_key_opts   ~w(--get --get-all --get-regexp --get-color --get-colorbool --unset --unset-all)
@config_urlmatch        "--get-urlmatch"
# no-arg flags (scope/format + write-mode --add/--replace-all whose key is the NEXT token)
@config_bool_opts       ~w(--global --local --system --worktree -z --null --name-only --show-origin
                           --show-scope --show-names -l --list --add --replace-all --all --regexp
                           --fixed-value --includes --no-includes --bool --int --bool-or-int --path
                           --expiry-date --no-type)
@config_section_flags   ~w(--rename-section --remove-section)
@config_read_actions    ~w(list get unset)                 # benign (read/removal)
@config_write_actions   ~w(set)                            # next token (after opts) is the write-key
@config_section_actions ~w(rename-section remove-section)
# `edit`/-e/--edit open the config file in $GIT_EDITOR/$VISUAL — a scriptable persistent-config
# mutation surface that can plant an alias, so they gate as a WRITE (not a read).
@config_edit_actions    ~w(edit)
@config_edit_flags      ~w(-e --edit)
@risky_sections         ~w(alias include includeif)
```

**Decision rules** (a small pipeline with a short-circuit sentinel — `:dynamic` / `:read` / `:edit` /
`{:section, …}` — so each helper stays one `cond`/`case` at depth ≤ 2):

1. **Strip leading config options.** Dynamic token in an option-or-key position ⇒ `:dynamic` (we
   cannot tell option from key) ⇒ gate `:dynamic_key`. `@config_read_key_opts` / `@config_urlmatch`
   ⇒ `:read` (benign, short-circuit). `@config_edit_flags` ⇒ `:edit` (gate). `@config_section_flags`
   ⇒ judge section-mutation on the rest. `@config_skip_value_opts` ⇒ drop flag + 1. bundled
   `--opt=…` known prefix ⇒ drop flag. `@config_bool_opts` ⇒ drop flag. First non-flag token ⇒ stop
   (it is the action-or-key).
2. **At the action/key token.** `@config_read_actions` ⇒ `:read` (benign). `@config_edit_actions`
   ⇒ `:edit` (gate). `@config_section_actions` ⇒ judge section-mutation on the rest.
   `@config_write_actions` (`set`) ⇒ consume it, **strip options again** (step 1), then classify the
   key. Otherwise ⇒ it is the legacy default write-key: classify it.
3. **Classify the write-key.** dynamic ⇒ gate `:dynamic_key`; literal with `config_section/1` ∈
   `@risky_sections` ⇒ `:alias_write`/`:include_write`; else ⇒ benign.
4. **Section-mutation** — **first strips post-trigger config options** (reuses step 1's stripper, so
   `git config rename-section --file .git/config foo alias` resolves `foo`/`alias` as the operands,
   not `--file`; a dynamic option there ⇒ `:dynamic_section`, gate). Then for `rename-section <old>
   <new>` / `--rename-section …`: either operand dynamic ⇒ `:dynamic_section` (gate); destination
   section ∈ `@risky_sections` ⇒ `:rename_to` (gate). `remove-section <name>` / `--remove-section …`
   ⇒ **benign** (removal cannot plant).
5. **Edit mode** (`:edit`) ⇒ `:git_config_persistent_write` (`%{reason: :config_edit}`) — an
   editor-driven persistent-config mutation we cannot inspect.

This makes **`git config user.name "$val"` benign** (machine stops at the literal key `user.name`
and never inspects the value), while **all dynamic-key, edit, and risky forms gate** (§6). Read stance
is explicit and documented: `--get*`/`--unset*`/`get`/`unset`/`list`/`remove-section` are
intentionally allowed (they cannot plant config); a *bare-key* read of a risky section
(`git config alias.x`, no value) over-gates as an acceptable false positive.

**Dynamic-subcommand invariant** (`git $x`): the global walk lands on a candidate with `dyns != []`
⇒ `opaque_reason: :dynamic_subcommand`, `subcommand: {:dynamic, token}` (honest — we don't claim
commit). General rule: any dynamic token in a *decision-critical* position (sub-command, inline `-c`
value, config option/key, rename section) fails closed; a dynamic *value* in a known value position
stays benign.

### 3. `ShellCommand` derives effects (the reducer)

Assemble in `build/2` and `merge_recursions/2`:

- **Structure effects** — map each `detect_structure/2` atom to `{atom, %{}}` from the same output.
- **git-env injection** (replaces `git_config_env_seen?` + the deleted `git_env_injected?/2`):
  `git_config_env_present?/1` + `git_config_assignment?/1` stay; emit
  `{:git_config_injection, %{reason: :git_config_env}}` iff a visible `GIT_CONFIG_*` mutation
  co-occurs with any `git` command.
- **per-command git facts** — for each `%Command{cmd: "git"}`, `Git.facts/2` → fold the `Invocation`:
  `commits?` → `{:git_commit, %{reason: :resolved}}` (honest); each `inline_injections` →
  `:git_config_injection`; each `config_writes` → `:git_config_persistent_write`; **`opaque_reason`
  (if set) → `{:opaque, %{scope: :git, reason: opaque_reason}}` and contributes `opaque?: true`** —
  *not* `:git_commit`.
- **parent-owned opacity** — depth/over-length/incomplete-parse/sub-command-cap, `strip → :unknown`
  (dynamic command word, unknown wrapper flag), here-doc → `{:opaque, %{scope: :parse, reason: …}}`;
  dynamic interpreter (`merge_recursion(:dynamic, …)`) → `{:opaque, %{scope: :interpreter, reason:
  :dynamic_interpreter}}`. Each sets `opaque?: true`.
- **crontab / generic** — `{:crontab, %{}}` when a command word is `crontab`.
- `opaque?` is the OR of all opacity sources; `merge/2` gains `effects: Enum.uniq(a.effects ++
  b.effects)`, ORs `opaque?`, drops `git_config_env_seen?`.

Funnel the effect sub-mappers through one constructor `defp effect(kind, ev), do: {kind, ev}` to
avoid three identical contiguous `defp`s (ExDNA clone guard).

### 4. `ToolApproval` gates on effects (`tool_approval.ex`)

The built-in `run_command` matcher list becomes **declarative effect matchers** (floor) + tunable
`:structure`:

```elixir
@require_patterns %{
  "run_command" =>
    {:command,
     [
       {:effect, :git_commit},
       {:effect, :git_config_injection},
       {:effect, :git_config_persistent_write},
       {:effect, :crontab},
       {:effect, :opaque},   # fail-closed floor (covers all scopes incl. :git)
       :structure            # tunable via :suspicious_shell_structure_kinds
     ]}
}
```

`matcher_matches?/4` gains an `{:effect, kind}` clause; the `%Regex{}`, `{:cmd, name}`,
`{:cmd, name, opts}`, and `:structure` clauses **stay** (operator-config back-compat + the
`read_file => {:path, [~r{/etc/shadow}]}` test):

```elixir
defp matcher_matches?({:effect, kind}, _raw, a, _opts), do: ShellCommand.has_effect?(a, kind)
defp matcher_matches?(:structure, _raw, a, opts) do
  case suspicious_structure_kinds(opts) do
    [] -> false
    kinds -> ShellCommand.structure_present?(a, kinds)
  end
end
# %Regex{} / {:cmd, name} / {:cmd, name, opts} clauses unchanged (the latter via command_present? shim)
```

- `valid_matcher?/1` adds `valid_matcher?({:effect, kind}) when is_atom(kind), do: true`.
- **Floor vs tunable**: the five `{:effect,…}` entries are non-disable-able (protected by "defaults
  win on merge" in `require_patterns/1`); `:structure` is narrowed/disabled by
  `:suspicious_shell_structure_kinds` (`suspicious_structure_kinds/1` unchanged). `[]` disables only
  structure — `{:effect, :opaque}` still fires the fail-closed floor (incl. git-opacity).
- **Unchanged**: `{:pattern, :command}` reason tuple, the exact "guarded-operation pattern" message,
  all error envelopes, atom/string `param_value` normalization, and the `{param, [matchers]}` outer
  shape (so the config-sanity sweep and merge still work). Effects are internal to the boolean
  decision — the LLM-facing wire contract does not change.
- **Moduledoc**: reconcile the git-config clause to describe the deliberate config grammar (options
  before/after an action, read-vs-write modes, `edit`/section-mutation gating, dynamic-key closure);
  keep the config/error-contract sections and `# reach:disable-for-this-file fixed_shape_map`.

### 5. Tests assert effects (`shell_command_test.exs`, `tool_approval_test.exs`)

- **New unit helpers**: `effects/1`, `has_effect?/2`, `assert_effect/2`, `refute_effect/2`,
  `assert_opaque/2` (asserts `{:opaque, %{scope: ^scope, reason: ^reason}}`). Keep `git?`/`cron?`/
  `struct?`/`gated?` (fold the floor via the shims); rename `unknown?/1`→`opaque?/1`. Drop `git_opts/0`
  (no `{:cmd,"git",opts}` matcher to source); `git?` calls the
  `command_present?(_, "git", subcommand: "commit")` shim.
- **Honest-reason assertions** (split the lumped cases per the "assert reasons" goal):
  - resolved-commit → `assert_effect :git_commit`: `git -c alias.ci=commit ci`, `alias.x='commit -a'`,
    nested `ci=co,co=commit`, `alias.ci='-c user.name=x commit'`, literal global-flag forms.
  - git-opacity → `assert_opaque scope: :git`: `git --frobnicate commit` (`:unknown_flag`), `git $x`
    (`:dynamic_subcommand`), `git -c alias.ci=co -c alias.co=ci ci` (`:alias_cycle`),
    `git -c alias.x='!git commit' x` (`:shell_alias`).
  - config injection → `assert_effect :git_config_injection`: GIT_CONFIG_* env forms (`:git_config_env`),
    `git -c "$cfg" ci` (`:dynamic_inline_c`), `git -c include.path=f ci` (`:config_include`),
    `git --config-env=include.path=VAR ci` (`:config_env_var`).
  - persistent write → `assert_effect :git_config_persistent_write`: existing `git config alias.*`/
    `include.*` write forms.
- **New describe-block "git config grammar (deliberate key resolution)"** — must-gate:
  `git config "$key" commit`, `git config set "$key" commit`, `git config set --global "$key" commit`,
  `git config set --file .git/config alias.ci commit`, `git config rename-section foo alias`,
  `git config rename-section --file .git/config foo alias`, `git config --rename-section foo include`,
  `git config edit`, `git config -e`, `git config --edit` (`:config_edit`),
  `K=alias.ci; git config "$K" commit; git ci`. Must-pass: `git config user.name "$val"`,
  `git config --get alias.x`, `git config get user.name`, `git config unset alias.x`,
  `git config remove-section alias`, `git config --list`.
- **Invariant tests** (new):
  - `opaque? ⟺ {:opaque,_}`: iterate parse/interpreter/git opacity fixtures; assert each has
    `opaque?: true` AND an `{:opaque, _}` effect, and that a representative non-opaque set has neither.
  - dynamic values stay benign: iterate `git config user.name "$val"`, `git -C "$dir" status`,
    `git push origin "$branch"`, `git commit -m "$MSG"` (the last gates on the literal `commit`, not
    the var) and assert the var does not by itself produce a gating effect.
- Flip literal `unknown?:` struct-pattern keys to `opaque?:`. Tokenizer/redirect/separator/wrapper/
  compound/structure/toggle blocks are otherwise unchanged.
- **`tool_approval_test.exs`**: add the new must-gate config cases to the `bypasses` list; add the new
  must-pass config reads to the benign list. Template overlay, MCP policy, wrapper loop,
  config-sanity, `%Regex{}` coexist, SSH-backed, narrow/`[]`/malformed toggle are untouched.

### 6. Correctness delta (honest effects)

| Command | Effect | Result |
| --- | --- | --- |
| `git config "$key" commit` | `:git_config_persistent_write` (`:dynamic_key`) | **now gates** |
| `git config set "$key" commit` | `:git_config_persistent_write` (`:dynamic_key`) | **now gates** |
| `git config set --global "$key" commit` | `:git_config_persistent_write` (`:dynamic_key`) | **now gates** (opt after action) |
| `git config set --file .git/config alias.ci commit` | `:git_config_persistent_write` (`:alias_write`) | **now gates** (opt+value after action) |
| `git config rename-section foo alias` | `:git_config_persistent_write` (`:rename_to`) | **now gates** (section mutation) |
| `git config rename-section --file f foo alias` | `:git_config_persistent_write` (`:rename_to`) | **now gates** (opts stripped before operands) |
| `git config edit` / `-e` / `--edit` | `:git_config_persistent_write` (`:config_edit`) | **now gates** (editor mutation surface) |
| `K=alias.ci; git config "$K" commit; git ci` | `:git_config_persistent_write` (`:dynamic_key`) | **now gates** |
| `git --frobnicate commit` / `git $x` | `:opaque` (`scope: :git`) | gates (honest — was a false `:git_commit`) |
| `git config user.name "$val"` | — (stops at literal key) | passes (no new FP) |
| `git config --get alias.x` / `unset alias.x` / `remove-section alias` | — (read/removal) | passes (intentional) |

**Intended gating is preserved, with two deliberate deltas vs. the old broad scanner:** (1) git
uncertainty (`git --frobnicate commit` / `git $x`) is now `{:opaque, scope: :git}` rather than a
false `:git_commit` — still gated (the `:opaque` floor + the `command_present?` git shim that folds
`opaque?`), just honest; (2) explicit read/removal forms over risky keys (`git config --get alias.x`,
`unset alias.x`, `remove-section alias`) now **pass** instead of being over-gated by the
position-independent scan — a reduced false-positive rate, which is the intended behavior. Every
must-gate write/injection case is preserved.

## Precommit-risk mitigations

- **Credo strict** (Cyclomatic/Perceived ≤ 11, Nesting ≤ 3, MaxLineLength 120, Readability.Specs):
  the config machine is the main hazard — decompose into `strip_config_opts/1` (the option walk,
  short-circuiting on `:dynamic`/`:read`/`:edit`/section, reused by the section-mutation operand
  step), `classify_config/1` (action/key dispatch), `classify_key/1`, and `judge_section_mut/1`, each
  a single `cond`/`case` at depth ≤ 2 with the sentinel doing the branching; `@spec` every public
  function and the moved privates; `@moduledoc` on `Git` and `Invocation`.
- **reach `--smells --strict`**: `Git`'s walkers operate on `[pair()]` (distinct from the parent's
  element-tuple `strip`/`strip_wrapper`) so `clone_consistency` sees different shapes; carry
  `# reach:disable-next-line bare_rescue` on `analyze/1`'s `rescue _`; scope any residual with
  `# reach:disable-for-this-file <smell>` (precedent `tool_approval.ex:5`). `Git` is outside the
  `web`/`data` layers so `--arch` is unaffected.
- **ExDNA clone (`min_mass: 30`)**: funnel effect sub-mappers through one `effect/2` constructor; do
  **not** add a third near-identical `opt_or_config/2`; the config stepper (action + section + key
  phases) is structurally distinct from `git_walk/2`.
- **Dialyzer** (`:error_handling, :unknown, :no_opaque`): declare `evidence` as
  `%{optional(atom()) => term()}`; promote `pair` to `@type`; `Analysis` stays a non-opaque struct.
- **`jidoclaw.compile_check`** (clean recompile, warnings blocking): delete `git_config_env_seen?`
  (field + literals + `merge/2`) and `git_env_injected?/2` together with their references; no unused
  vars/aliases; new module/struct carry a `@moduledoc`.

## Critical files

| File | Change |
| --- | --- |
| `lib/jido_claw/security/shell_command/git.ex` | **New.** `Git` interpreter + `Invocation` struct; `facts/2`; the deliberate `git config` state machine (options before/after an action, read-vs-write modes, `edit`/section-mutation gating, dynamic-key closure); moved git global-walk/alias/config machinery + tables. |
| `lib/jido_claw/security/shell_command.ex` | `%Analysis{effects, opaque?}` (drop `git_config_env_seen?`/`unknown?`); `has_effect?/2`; honest effect reducer (`:opaque` scope evidence, `:git_commit` only for resolved commit); `command_present?`/`structure_present?` effect shims; delegate git to `Git.facts/2`; moduledoc to the effects model. |
| `lib/jido_claw/security/tool_approval.ex` | `@require_patterns` run_command → `{:effect, kind}` + `:structure`; `matcher_matches?` `{:effect,_}` clause; `valid_matcher?` `{:effect,_}`; moduledoc git-config clause. |
| `test/jido_claw/security/shell_command_test.exs` | effect helpers (`assert_effect`/`assert_opaque`); honest-reason assertions; **new** config-grammar block + invariant tests; `unknown?`→`opaque?`; drop `git_opts/0`. |
| `test/jido_claw/security/tool_approval_test.exs` | add the new config must-gate cases to `bypasses` and the new config reads to the benign list. |

## Verification

Iterate with targeted runs, then the full gate:

```
mix compile                                                   # no new warnings (compile_check proxy)
mix test test/jido_claw/security/shell_command_test.exs       # pure, async; effect + invariant assertions
mix test test/jido_claw/security/tool_approval_test.exs        # DB-backed pend/approve loop
mix credo --strict lib/jido_claw/security/shell_command.ex lib/jido_claw/security/shell_command/git.ex lib/jido_claw/security/tool_approval.ex
mix reach.check --arch --smells --strict
mix dialyzer
```

**Bug-closed proof** (must fail before, pass after): the dynamic-key, section-mutation, and `edit`
cases in §6 gate (`assert_effect … :git_config_persistent_write`; `approval_pending` in the gate
suite), while `git config user.name "$val"` and the explicit read/removal forms pass.

**Honesty proof**: `git --frobnicate commit` / `git $x` assert `{:opaque, scope: :git}` and
`refute_effect :git_commit`; the `opaque? ⟺ {:opaque,_}` invariant test passes.

**Done bar:** `mix precommit` passes end-to-end (`jidoclaw.compile_check` → `system_prompt.check` →
`deps.unlock --unused` → `format --check-formatted` → `reach.check --arch --smells --strict` →
`credo --strict` → `dialyzer` → `test`). No new tool is registered (`system_prompt.check`
unaffected); `nimble_parsec` is already a direct dep (`deps.unlock --unused` unaffected).
