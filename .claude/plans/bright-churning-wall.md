# Plan: Close two git-config-injection bypasses in the `run_command` approval gate

## Context

The just-finished V2-1 follow-up replaced the brittle `run_command` approval regexes
with the shell-aware analyzer `JidoClaw.Security.ShellCommand`, including a git-aware
sub-command resolver that resolves `git`'s *true* sub-command past global options and
inline `-c alias.X=Y` definitions (so `git -c alias.ci=commit ci` gates). A code review
found **two P1 holes** where git can still be made to run `commit` under an aliased
sub-command while the gate returns `:ok`. Both were **verified against the live system**
(Tidewave `project_eval` on the analyzer + a real `git` run confirming the injection is
honored).

1. **`GIT_CONFIG_*` env injection — in any visible form.** `GIT_CONFIG_COUNT` +
   `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` (also `GIT_CONFIG_PARAMETERS`,
   `GIT_CONFIG_GLOBAL`/`SYSTEM`) inject config — including `alias.ci=commit` — into git.
   These appear as a leading assignment (`GIT_CONFIG_COUNT=1 … git ci`), an `env` wrapper
   (`env GIT_CONFIG_…=… git ci`), **or a prior shell-state mutation that persists to a
   later `git`**: `export GIT_CONFIG_…=…; git ci` and `set -a; GIT_CONFIG_…=…; git ci`.
   The analyzer strips leading assignments as transparent and splits on `;`, so the
   resolved `git ci` carries no commit signal ⇒ **not gated** in every one of these forms.
2. **`-c include.path` / `includeIf.*.path`.** `record_config/3` only records `alias.*`
   keys and treats every other `-c key=value` as a no-op, so
   `git -c include.path=/path/to/config ci` (and the `includeIf.*.path` form) passes —
   even though git loads aliases from that included file *before* resolving `ci`.

**Intended outcome:** both vectors **fail closed** within the existing git resolver — the
same posture already used for `git -c "$cfg" ci` (dynamic config) and `git --frobnicate
commit` (unknown flag). No new error code, reason tuple, producer, or fingerprint change.
**Done bar: `mix precommit` passes.**

## Fix design

### 1. `lib/jido_claw/security/shell_command.ex`

**A. Gate any git invocation in the presence of a visible `GIT_CONFIG_*` env mutation
(Finding 1) — analysis-level flag.**
Shell env state set by one sub-command (`export`/`set -a`/standalone assignment) persists
to a later `git`, so per-command env capture is insufficient (confirmed: the resolved
`git ci` carries no env in the `export …; git ci` and `set -a; …; git ci` forms). Instead
detect the mutation **anywhere on the command line** and gate any git command — strictly
broader than, and replacing, a per-`Command` env field (no `strip`/`Command`-struct change
needed).

- Add `git_config_env_seen?: false` to the `Analysis` struct and its `@type t`.
- Compute it in `build/2` over the (already-collected) `elements` and propagate through
  recursion in `merge/2` (logical OR), so a `GIT_CONFIG_*` mutation inside an `sh -c "…"`
  script also counts:
  ```elixir
  # in build/2's %Analysis{}:  git_config_env_seen?: git_config_env_present?(elements),
  # in merge/2:                git_config_env_seen?: a.git_config_env_seen? or b.git_config_env_seen?,

  defp git_config_env_present?(elements), do: Enum.any?(elements, &git_config_assignment?/1)

  # An assignment-FORM word (NAME=…) whose NAME starts with GIT_CONFIG. Matches a
  # leading/standalone assignment, an `env`/`export`/`declare -x`/`set -a` arg — every
  # form that can put a GIT_CONFIG_* var into git's environment.
  defp git_config_assignment?({:word, text, _dyns}),
    do: Regex.match?(@assignment_re, text) and text |> before_eq() |> String.starts_with?("GIT_CONFIG")
  defp git_config_assignment?(_element), do: false

  defp before_eq(s), do: s |> String.split("=", parts: 2) |> hd()
  ```
- Gate at `command_present?/3` (it has the whole `%Analysis{}`), guarded by an **actual git
  command being present** so a benign `echo GIT_CONFIG_COUNT=1` (no git) does not gate:
  ```elixir
  def command_present?(%Analysis{commands: commands} = analysis, name, opts),
    do: Enum.any?(commands, &command_match?(&1, name, opts)) or git_env_injected?(analysis, name)

  defp git_env_injected?(%Analysis{git_config_env_seen?: true, commands: commands}, "git"),
    do: Enum.any?(commands, &(&1.cmd == "git"))
  defp git_env_injected?(_analysis, _name), do: false
  ```
  (The `unknown?: true` head of `command_present?/3` stays first/unchanged.) This is a
  **conservative gate**: a `GIT_CONFIG_*` assignment-form token + any git command pends,
  even where shell scoping would not actually export it (bare unexported assignment, a var
  only set for a *different* command's prefix, a subshell `export`). Over-gating just asks
  for approval — the chosen fail-closed posture.

**B. Gate config-include directives (Finding 2).**
Make `record_config/3` able to signal a gate and propagate it through the walk:
```elixir
defp git_config_separate(flag, [{text, _dyns} | rest], aliases),
  do: continue_config(record_config(flag, text, aliases), rest)
defp git_bundled_config(prefix, text, _dyns, rest, aliases),
  do: continue_config(record_config(prefix, bundled_value(text), aliases), rest)

defp continue_config(:gate, _rest), do: :gate
defp continue_config({:ok, aliases}, rest), do: git_walk(rest, aliases)

@spec record_config(String.t(), String.t(), git_aliases()) :: {:ok, git_aliases()} | :gate
defp record_config(flag, value, aliases) do
  if config_include?(value), do: :gate, else: {:ok, record_config_alias(flag, value, aliases)}
end

# (old two-head record_config logic, renamed)
defp record_config_alias("--config-env", value, aliases), do: record_alias(value, :opaque, aliases)
defp record_config_alias(_flag, value, aliases), do: record_alias(value, :expansion, aliases)

# include.path / includeIf.*.path import config (incl. aliases) from a file we cannot read.
# git config section names are case-insensitive.
defp config_include?(value) do
  section = value |> before_eq() |> String.split(".", parts: 2) |> hd() |> String.downcase()
  section in ~w(include includeif)
end
```
`continue_config/2` returns the existing `git_walk()` typep (`:gate | {pair|nil, aliases}`),
so `git_walk`/`resolve_git` map `:gate` → match (fail closed) exactly like an unknown flag.
The `git_config_separate`/`git_bundled_config` dynamic-value guards (`when dyns != [] ->
:gate`) are unchanged. `before_eq/1` is shared with Finding 1's predicate.

**C. Moduledoc reconciliation** ("Git-aware sub-command resolution" + "Documented
residuals"): add (i) the config-include directive and (ii) a visible `GIT_CONFIG_*` env
mutation (leading / `env`-wrapper / `export` / `set -a` / standalone, incl. inside an
`sh -c`) to the gated list, noting the conservative over-gating; keep — as residual —
reading the actual gitconfig *file* contents (incl. relocating it via `HOME=`/`GIT_DIR=`),
distinct from the now-gated `GIT_CONFIG_*` injection. Update the comment above `record_config`.

### 2. `lib/jido_claw/security/tool_approval.ex` (moduledoc only)

Extend the git-resolution sentence (~lines 50-54): the gated set now reads "inline
`-c alias.X=Y` definitions, config-include directives (`-c include.path=…`), and any
visible `GIT_CONFIG_*` config-injection env mutation (a leading/`env`-wrapper assignment or
a prior `export`/`set -a`) — so `git -c alias.ci=commit ci`, `git -c include.path=f ci`,
`GIT_CONFIG_COUNT=1 … git ci`, and `export GIT_CONFIG_…=…; git ci` all gate". No code change.

### 3. `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` (V2-1 entry)

Reconcile the whole entry (per the doc-status-sweep practice):
- **"Richer approval predicates" (line 25):** add config-include directives and the visible
  `GIT_CONFIG_*` env-injection forms (incl. cross-command `export`/`set -a`) to the git
  vectors that fail closed.
- **"Residual risk" (line 27):** narrow the `~/.gitconfig` residual to *file-content*
  aliases (incl. `HOME=`/`GIT_DIR=` relocation); state that inline `-c` config-include and
  visible `GIT_CONFIG_*` env injection are now **gated**, not residual.

### 4. Tests

**`test/jido_claw/security/shell_command_test.exs`** — new describe block
`"git-aware sub-command: config injection via env + includes (review F1/F2)"`. Gates assert
`git?` true **and** `refute unknown?` (these gate via the git matcher, not the unknown floor):
- **env injection, all forms:** `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci
  GIT_CONFIG_VALUE_0=commit git ci`; the `env` and `env -i` wrapper variants;
  **`export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit; git ci`**;
  **`set -a; GIT_CONFIG_COUNT=1; GIT_CONFIG_KEY_0=alias.ci; GIT_CONFIG_VALUE_0=commit; git ci`**;
  **`GIT_CONFIG_COUNT=1; git ci`**; **`sh -c "export GIT_CONFIG_COUNT=1; git ci"`** (recursion);
  `GIT_CONFIG_PARAMETERS='alias.ci=commit' git ci`; `GIT_CONFIG_GLOBAL=/tmp/evil git status`;
  `GIT_CONFIG_COUNT=$n git ci`.
- **include directives:** `git -c include.path=/path/to/config ci`,
  `git -c includeIf.gitdir:/x/.path=/p ci`, `git -c include.path=/p commit`,
  `git --config-env=include.path=VAR ci`.
- **benign regression (`refute git?`):** `echo GIT_CONFIG_COUNT=1` and `export
  GIT_CONFIG_COUNT=1` **alone (no git → not gated, proving the git-present guard)**;
  `GIT_AUTHOR_NAME=x git status`; `FOO=bar git status`; `git -c core.pager=less status`;
  `git -c user.name=x status`.

**`test/jido_claw/security/tool_approval_test.exs`** — end-to-end through the real gate:
- Add to "newly-closed shell bypasses of git_commit pend": the inline, `env`-wrapper,
  **`export …; git ci`**, **`set -a; …; git ci`** `GIT_CONFIG_*` forms and
  `git -c include.path=/path/to/config ci` (assert `:approval_pending`).
- Add to "benign commands and pinned residuals pass through": `echo GIT_CONFIG_COUNT=1`,
  `GIT_AUTHOR_NAME=x git status`, `git -c core.pager=less status` (assert `:ok`).

## Reuse / consistency notes

- Reuses the fail-closed machinery: `git_walk`'s `:gate` path and the `command_present?`
  match contract; mirrors `destination_policy.ex`'s pure fail-closed style.
- `before_eq/1` funnels the shared "key/name before `=`" extraction (one helper, two
  callers) so the new predicates don't read as a clone (ExSlop `min_mass ~30`).
- No `Command`-struct or `strip`/`strip_wrapper` change — the analysis-level flag keeps the
  diff small and the existing prefix normalizer untouched.

## Verification

Iterate with targeted runs, then the full gate:
```
mix compile --warnings-as-errors
# spot-check via Tidewave project_eval: the F1 (incl. export/set -a/recursion) and F2
# strings gate (git? true); echo/export-alone and core.pager/GIT_AUTHOR_NAME do not.
mix test test/jido_claw/security/shell_command_test.exs
mix test test/jido_claw/security/tool_approval_test.exs
mix credo --strict lib/jido_claw/security/shell_command.ex
mix precommit
```
**Done = `mix precommit` green.** Precommit-risk watchlist (project history): add the
`record_config` `@spec` so Dialyzer accepts the new `{:ok, …} | :gate` return; update
`Analysis.@type t` and **every** `%Analysis{}` constructor path (`build`, `merge`, and the
`unknown?: true` short-circuits default the new field) so the field is consistent; keep
lines ≤120 and the new predicates tiny (Credo); route the shared `=`-split through
`before_eq/1` (reach clone). No new tool/dep, so `jidoclaw.system_prompt.check` and
`deps.unlock --unused` are unaffected.

## Memory to capture (post-approval)

Reviewer feedback worth persisting: when gating shell commands on env vars, shell-state
mutations (`export`, `set -a`, standalone assignments) in an earlier `;`-separated
sub-command persist to later commands — gate on the var appearing **anywhere** on the line,
not only as a prefix of the target command. (Extends `[[feedback_gate_bypass_coverage_sweeps]]`.)
