defmodule JidoClaw.Security.ShellCommand do
  @moduledoc """
  Shell-aware analyzer for the `run_command` approval gate.

  This is a **gate heuristic, not a shell.** `run_command` hands the model's
  string to a real shell (`sh -c …` on the host backend, a remote login shell
  over SSH), and `JidoClaw.Security.ToolApproval` must decide *before* dispatch
  whether the string reaches a gated capability — `git commit` (the shell
  equivalent of the `git_commit` tool) or `crontab` (the `schedule_task`
  equivalent) — regardless of how it is dressed up. Brittle regexes over the raw
  string miss quoting (`git -C "my dir" commit`), separators (`a && git commit`),
  multiline, env prefixes (`FOO=bar git commit`), wrappers (`sudo git commit`),
  paths (`/usr/bin/git commit`), and interpreters (`sh -c "git commit"`).

  `analyze/1` tokenizes with a `nimble_parsec` grammar the way a shell would
  (quote/escape-aware), splits on shell separators and group boundaries, strips
  transparent leading prefixes (env-assignments, redirects, control keywords,
  wrapper words) to resolve the real command word per sub-command, and surfaces
  **semantic risk facts** — *effects*.

  ## Effects, not booleans

  `analyze/1` returns `%Analysis{commands, structure, effects, opaque?}`. Each
  effect is `{kind, evidence}`: `kind` drives gating, `evidence`
  (`%{reason: atom(), …}`) is informational (tests/logging). **Facts stay
  honest** — a kind asserts what is *known*, not a fail-closed guess:

    * `:git_commit` — a git sub-command *definitively* resolves (literally or
      through a fully-expanded alias chain) to `commit`. Git-resolution
      *uncertainty* never masquerades as a commit.
    * `:git_config_injection` — config injected into a git run: a visible
      `GIT_CONFIG_*` env mutation co-occurring with a `git` command, an inline
      `-c include.path=…` directive, a `--config-env` value from an unreadable
      env var, or a dynamic inline `-c` value.
    * `:git_config_persistent_write` — a `git config` sub-command that **plants**
      config a later `git` honors and that persists to `.git/config` across
      `run_command` calls (an `alias.*`/`include.*` write, a dynamic key, a
      section rename into a risky section, or an `edit`/`-e`/`--edit` mutation).
    * `:crontab` — a `crontab` command (the `schedule_task` equivalent).
    * `:command_substitution` / `:backtick` / `:pipe_to_shell` — suspicious shell
      structure (also surfaced in `structure`, tunable by the gate).
    * `:opaque` — the single fail-closed fact, carrying `%{scope, reason}` where
      `scope ∈ {:parse, :interpreter, :git}`. Anywhere analysis cannot confidently
      resolve — an incomplete parse, an over-length input, the recursion/
      sub-command caps, a here-doc feeding a shell, a parameter-expansion command
      word, an unrecognized wrapper flag (`scope: :parse`), a dynamic
      interpreter/eval script (`scope: :interpreter`), or a git-resolution
      uncertainty (`scope: :git`) — it emits an `{:opaque, _}` effect.

  **Invariant:** `opaque?: true` ⟺ at least one `{:opaque, _}` effect is present.
  The contract is deliberately over-recognizing: a false positive merely asks an
  operator for approval (acceptable), while a false negative is a silent
  `git commit` (the failure to avoid) — so the `:opaque` floor **fails closed:
  require approval, never pass through.**

  `has_effect?/2` answers "is this kind present?". `command_present?/3` and
  `structure_present?/2` are thin, effect-based shims kept for the gate's
  operator-config matchers (`{:cmd, …}`) and the unit-test helpers: the git
  `subcommand: "commit"` form returns the git gating floor (`:git_commit` |
  `:git_config_injection` | `:git_config_persistent_write` | `opaque?`).

  ## Git-aware sub-command resolution

  `git` is special because its real sub-command hides behind global options and
  config-defined aliases. `JidoClaw.Security.ShellCommand.Git` owns the git
  interpreter: it steps over git's pre-sub-command global options (`-C`, `-c`,
  `--git-dir`, …) using baked flag tables, collects inline `-c alias.X=Y`
  definitions, chases alias expansions (`git -c alias.ci=commit ci`) through the
  same walk, and runs a deliberate `git config` state machine over git's real
  grammar. A dynamic sub-command (`git $x`), dynamic config (`git -c "$cfg" ci`),
  a config-include directive (`git -c include.path=f ci`), an unknown
  pre-sub-command flag (`git --frobnicate commit`), a `!`-shell alias, an alias
  cycle, or an un-re-tokenizable expansion all surface honest facts —
  `:git_commit` only for a resolved commit, `{:opaque, scope: :git}` for
  uncertainty. The **`git config` write subcommand** plants config that persists
  across calls, so an `alias.*`/`include.*` write, a dynamic key, a section
  rename into `alias`/`include`, or an editor mutation gate independently of any
  later `git`; reads and removals (`--get`/`get`/`unset`/`remove-section`) are
  intentionally allowed (they cannot plant). Independently, a visible
  `GIT_CONFIG_*` env mutation anywhere on the line gates any git command.

  ## Documented residuals (escape valve = gate all `run_command` via `require`)

  Pinned by pass-through tests: out-of-band aliases not visible in the command
  string (shell aliases/functions from login/startup files; `git` aliases read
  from the `~/.gitconfig` *file* contents — distinct from the now-gated
  `GIT_CONFIG_*` env injection) and script-file indirection (`bash deploy.sh`,
  `sh < deploy.sh`). A *visible* function body (`f(){ git commit; }; f`) is gated
  (descended via splitting); here-docs feeding a shell, `$()`/backtick presence,
  a pipe into a shell, parameter-expansion command words, and a dynamic
  interpreter/eval script (`sh -c "$cmd"`) are all gated even though opaque.
  `$VAR`/`${…}` in a plain *argument* position stays benign — it does not obscure
  the command word.
  """
  import NimbleParsec

  defmodule Command do
    @moduledoc """
    One resolved sub-command: a command word (basename), its arguments, and the
    per-argument dynamic markers (`arg_dyns`, 1:1 with `args`) so a dynamic token
    (`$x`) is distinguishable from a literal one during sub-command resolution.
    """
    defstruct cmd: nil, args: [], arg_dyns: []
    @type t :: %__MODULE__{cmd: String.t() | nil, args: [String.t()], arg_dyns: [[atom()]]}
  end

  defmodule Analysis do
    @moduledoc """
    The result of analyzing a command string. `effects` is a list of honest
    semantic risk facts `{kind, evidence}`; `opaque?` is the fail-closed sentinel
    and holds ⟺ at least one `{:opaque, _}` effect is present.
    """
    defstruct commands: [], structure: [], effects: [], opaque?: false

    @type t :: %__MODULE__{
            commands: [JidoClaw.Security.ShellCommand.Command.t()],
            structure: [atom()],
            effects: [JidoClaw.Security.ShellCommand.effect()],
            opaque?: boolean()
          }
  end

  alias __MODULE__.{Analysis, Command, Git}

  @type t :: Analysis.t()

  @typedoc "Effect kind — drives gating."
  @type effect_kind ::
          :git_commit
          | :git_config_injection
          | :git_config_persistent_write
          | :crontab
          | :command_substitution
          | :backtick
          | :pipe_to_shell
          | :opaque
  @typedoc "Informational evidence carried by an effect (`%{reason: …}` + extras)."
  @type evidence :: %{optional(atom()) => term()}
  @type effect :: {effect_kind(), evidence()}

  # The known effect kinds — the single source of truth for gate-matcher
  # validation (`ToolApproval.valid_matcher?/1`), so an operator-config
  # `{:effect, :typo}` is warn-skipped rather than silently inert. MUST mirror
  # the effect_kind/0 union above.
  @effect_kinds [
    :git_commit,
    :git_config_injection,
    :git_config_persistent_write,
    :crontab,
    :command_substitution,
    :backtick,
    :pipe_to_shell,
    :opaque
  ]

  # A word and its dynamic markers (`[]` ⇒ fully literal). 1:1 with Command.args.
  @typep pair :: {String.t(), [atom()]}
  # An interpreter/eval recursion target: a literal script, or a runtime-dynamic
  # one we cannot read (fail closed to :opaque). `nil` ⇒ no script (bare shell).
  @typep script :: nil | :dynamic | {:script, String.t()}

  # ---- Bounds (every breach fails closed to an :opaque effect) ----
  @max_input_bytes 64 * 1024
  @max_subcommands 256
  @max_depth 3

  @shells ~w(sh bash zsh dash ash ksh)

  # Leading control / compound keywords stripped so a gated command inside a
  # control structure resolves (`then git commit`, `do git commit`). Group
  # delimiters `( ) { }` are split boundaries (handled in split/1), not words.
  @control_keywords ~w(! if then elif else fi for while until do done case esac in select function coproc)

  # Per-wrapper flag-arity table as DATA. `bool`: flags taking no value;
  # `val`: flags taking a separate value (or a bundled `-fVALUE`/`--flag=value`);
  # `assignments`: `VAR=val` tolerated as a prefix (env); `positional`: leading
  # positional values consumed before the command (timeout's duration). A
  # recognized wrapper followed by an UNrecognized flag fails closed (:opaque).
  @wrappers %{
    "sudo" => %{
      bool: ~w(-b -E -H -i -K -k -n -P -S -s -V -v),
      val: ~w(-C -g -h -p -r -t -T -U -u),
      assignments: false,
      positional: 0
    },
    "doas" => %{bool: ~w(-n -s), val: ~w(-a -C -u), assignments: false, positional: 0},
    "env" => %{bool: ~w(-i -0 -v), val: ~w(-u -C), assignments: true, positional: 0},
    "nice" => %{bool: [], val: ~w(-n), assignments: false, positional: 0},
    "ionice" => %{bool: ~w(-t), val: ~w(-c -n -p), assignments: false, positional: 0},
    "timeout" => %{
      bool: ~w(--preserve-status --foreground -f),
      val: ~w(-s -k --signal --kill-after),
      assignments: false,
      positional: 1
    },
    "nohup" => %{bool: [], val: [], assignments: false, positional: 0},
    "setsid" => %{bool: ~w(-c -f -w), val: [], assignments: false, positional: 0},
    "stdbuf" => %{bool: [], val: ~w(-i -o -e), assignments: false, positional: 0},
    "exec" => %{bool: ~w(-c -l), val: ~w(-a), assignments: false, positional: 0},
    "command" => %{bool: ~w(-p -v -V), val: [], assignments: false, positional: 0},
    "builtin" => %{bool: [], val: [], assignments: false, positional: 0},
    "time" => %{bool: ~w(-p -v), val: [], assignments: false, positional: 0}
  }

  @assignment_re ~r/^[A-Za-z_][A-Za-z0-9_]*=/
  @redirect_re ~r/^\d*(<<<|<<-|<<|&>>|&>|>>|>&|<&|>|<)(.*)$/
  @c_flag_re ~r/^-[A-Za-z]*c(.*)$/

  # ---- Grammar character classes ----
  @ws_chars [?\s, ?\t, ?\r]
  @op_chars [?\s, ?\t, ?\r, ?\n, ?|, ?&, ?;, ?(, ?), ?{, ?}, ?<, ?>]
  @special_chars [?', ?", ?`, ?$, ?\\]
  @word_break @op_chars ++ @special_chars

  # `#` excluded from a word START (so a leading `#` is a comment) but allowed
  # mid-word (so `git#x` is one word, not a comment).
  @bare_start_excl Enum.map([?# | @word_break], &{:not, &1})
  @bare_cont_excl Enum.map(@word_break, &{:not, &1})
  @redir_target_excl Enum.map([?# | @word_break], &{:not, &1})
  @dq_lit_excl Enum.map([?", ?\\, ?$, ?`], &{:not, &1})

  # ---- Grammar combinators (compile-time data) ----
  ws = replace(times(utf8_char(@ws_chars), min: 1), :ws)
  newline = replace(string("\n"), {:op, :newline})
  and_op = replace(string("&&"), {:op, :and})
  or_op = replace(string("||"), {:op, :or})
  pipe_op = replace(string("|"), {:op, :pipe})
  amp_op = replace(string("&"), {:op, :amp})
  semi_op = replace(string(";"), {:op, :semi})
  lparen = replace(string("("), {:op, :subshell_open})
  rparen = replace(string(")"), {:op, :subshell_close})
  lbrace = replace(string("{"), {:op, :brace_open})
  rbrace = replace(string("}"), {:op, :brace_close})

  # Redirect: optional fd digits + a redirect core + an optional fused target,
  # joined to a raw string and classified in Elixir (redirect_meta/1). Bare
  # `<`/`>` are excluded from word runs, so this is their only matcher.
  redirect_core =
    choice([
      string("<<<"),
      string("<<-"),
      string("<<"),
      string("&>>"),
      string("&>"),
      string(">>"),
      string(">&"),
      string("<&"),
      string(">"),
      string("<")
    ])

  redirect =
    optional(ascii_string([?0..?9], min: 1))
    |> concat(redirect_core)
    |> optional(utf8_string(@redir_target_excl, min: 1))
    |> reduce({Enum, :join, [""]})
    |> unwrap_and_tag(:redirect)

  # Active `$(`/backtick → structure markers; `$NAME`/`${…}` → a parameter
  # expansion marker. Inside single quotes (and after a backslash) these are
  # literal, handled by single_quoted / escaped consuming them as text.
  dollar_command = replace(string("$("), {:dyn, :command})

  dollar_brace =
    string("${")
    |> repeat(utf8_char([{:not, ?}}]))
    |> optional(string("}"))
    |> replace({:dyn, :param})

  dollar_name =
    string("$")
    |> concat(
      choice([
        ascii_string([?a..?z, ?A..?Z, ?_, ?0..?9], min: 1),
        ascii_string([??, ?$, ?!, ?@, ?*, ?#, ?-], 1)
      ])
    )
    |> replace({:dyn, :param})

  dollar_literal = replace(string("$"), {:lit, "$"})
  backtick = replace(string("`"), {:dyn, :backtick})

  # `\<char>` → the literal char (line-continuations are spliced before parsing).
  escaped =
    ignore(string("\\"))
    |> concat(utf8_string([], 1))
    |> unwrap_and_tag(:lit)

  # Single quotes: literal content, no escapes, no substitution.
  single_quoted =
    ignore(string("'"))
    |> repeat(utf8_char([{:not, ?'}]))
    |> ignore(optional(string("'")))
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:lit)

  dq_literal = unwrap_and_tag(utf8_string(@dq_lit_excl, min: 1), :lit)

  # Double quotes: `$(`/backtick/`$VAR` stay active; spaces/operators are literal.
  double_quoted =
    ignore(string("\""))
    |> repeat(
      choice([
        escaped,
        dollar_command,
        dollar_brace,
        dollar_name,
        dollar_literal,
        backtick,
        dq_literal
      ])
    )
    |> ignore(optional(string("\"")))

  # A comment runs to end-of-line. Reachable only at a word-start `#` because a
  # bare word never starts with `#`; mid-word `#` (`git#x`) stays in the word.
  comment = ignore(repeat(string("#"), utf8_char([{:not, ?\n}])))

  bare_run =
    utf8_char(@bare_start_excl)
    |> repeat(utf8_char(@bare_cont_excl))
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:lit)

  # Totality fallback: consume any single codepoint as a literal so the parser
  # never errors. A residual (invalid byte) leaves a non-empty rest → :opaque.
  any_char = unwrap_and_tag(utf8_string([], 1), :lit)

  defparsecp(
    :tokenize,
    repeat(
      choice([
        ws,
        newline,
        and_op,
        or_op,
        pipe_op,
        redirect,
        amp_op,
        semi_op,
        lparen,
        rparen,
        lbrace,
        rbrace,
        dollar_command,
        dollar_brace,
        dollar_name,
        dollar_literal,
        backtick,
        single_quoted,
        double_quoted,
        escaped,
        comment,
        bare_run,
        any_char
      ])
    )
  )

  # ---- Public API ----

  @doc """
  Analyzes `command` into resolved sub-commands, suspicious structure, and
  honest semantic effects.

  Total and fail-closed: any breach of the bounds, an incomplete parse, or an
  internal fault yields an `{:opaque, %{scope: :parse, …}}` effect (so
  `opaque?: true`).
  """
  @spec analyze(String.t()) :: t()
  def analyze(command) when is_binary(command) do
    do_analyze(command, 0)
  rescue
    # A gate must fail closed even on an unexpected internal parser fault — a
    # propagating raise could otherwise be read as "no match" upstream.
    # reach:disable-next-line bare_rescue
    _ -> opaque_analysis(:parse, :internal_fault)
  end

  def analyze(_command), do: opaque_analysis(:parse, :not_a_string)

  @doc "Whether an effect of `kind` is present."
  @spec has_effect?(t(), effect_kind()) :: boolean()
  def has_effect?(%Analysis{effects: effects}, kind),
    do: Enum.any?(effects, &match?({^kind, _}, &1))

  @doc "The known effect kinds — the valid `kind` set for an `{:effect, kind}` gate matcher."
  @spec effect_kinds() :: [effect_kind()]
  def effect_kinds, do: @effect_kinds

  @doc """
  Whether a sub-command runs `name` (optionally with `:subcommand` among its
  non-flag args). `opaque?: true` always matches (fail closed).

  For `("git", subcommand: "commit")` this is the git gating floor (`:git_commit`
  | `:git_config_injection` | `:git_config_persistent_write` | `opaque?`); every
  other form uses the generic "first non-flag token" heuristic over `commands`.
  """
  @spec command_present?(t(), String.t(), keyword()) :: boolean()
  def command_present?(analysis, name, opts \\ [])
  def command_present?(%Analysis{opaque?: true}, _name, _opts), do: true

  def command_present?(%Analysis{} = analysis, "git", opts) do
    if Keyword.get(opts, :subcommand) == "commit" do
      git_gating_effect?(analysis)
    else
      generic_present?(analysis, "git", opts)
    end
  end

  def command_present?(%Analysis{} = analysis, name, opts),
    do: generic_present?(analysis, name, opts)

  @doc """
  Whether any of `kinds` is present. An empty `kinds` is `false` (nothing to
  look for, even when `opaque?`); otherwise `opaque?` matches (fail closed).
  """
  @spec structure_present?(t(), [atom()]) :: boolean()
  def structure_present?(_analysis, []), do: false
  def structure_present?(%Analysis{opaque?: true}, _kinds), do: true

  def structure_present?(%Analysis{structure: structure}, kinds) do
    Enum.any?(kinds, &(&1 in structure))
  end

  # ---- Matching (generic clause + git floor) ----

  defp git_gating_effect?(analysis) do
    has_effect?(analysis, :git_commit) or has_effect?(analysis, :git_config_injection) or
      has_effect?(analysis, :git_config_persistent_write)
  end

  defp generic_present?(%Analysis{commands: commands}, name, opts) do
    Enum.any?(commands, &command_match?(&1, name, opts))
  end

  defp command_match?(%Command{cmd: cmd} = command, name, opts),
    do: cmd == name and subcommand_ok?(command, Keyword.get(opts, :subcommand))

  defp subcommand_ok?(_command, nil), do: true
  defp subcommand_ok?(command, sub), do: generic_subcommand_match?(command, sub)

  # Generic: the first non-flag arg IS the sub-command. Match when it equals `sub`
  # or is dynamic (a `$x` we cannot resolve — fail closed).
  defp generic_subcommand_match?(%Command{args: args, arg_dyns: arg_dyns}, sub) do
    case first_non_flag(Enum.zip(args, arg_dyns)) do
      nil -> false
      {text, dyns} -> dyns != [] or text == sub
    end
  end

  defp first_non_flag([{text, _dyns} = pair | rest]),
    do: if(flag_arg?(text), do: first_non_flag(rest), else: pair)

  defp first_non_flag([]), do: nil

  # A literal `-`-leading token is a flag; an empty text (a pure `$x`) is not.
  defp flag_arg?(text), do: String.starts_with?(text, "-")

  # ---- Analysis pipeline ----

  defp do_analyze(_command, depth) when depth > @max_depth,
    do: opaque_analysis(:parse, :max_depth)

  defp do_analyze(command, _depth) when byte_size(command) > @max_input_bytes,
    do: opaque_analysis(:parse, :over_length)

  defp do_analyze(command, depth) do
    # Splice backslash-newline continuations (over-recognizing: globally, even
    # inside single quotes — can only over-gate, never under-gate).
    spliced = String.replace(command, "\\\n", "")

    case tokenize(spliced) do
      {:ok, tokens, "", _context, _line, _column} -> analyze_tokens(tokens, depth)
      _ -> opaque_analysis(:parse, :incomplete_parse)
    end
  end

  defp analyze_tokens(tokens, depth) do
    subcommands =
      tokens
      |> coalesce()
      |> split()

    if length(subcommands) > @max_subcommands do
      opaque_analysis(:parse, :subcommand_cap)
    else
      build(subcommands, depth)
    end
  end

  defp build(subcommands, depth) do
    resolved = Enum.map(subcommands, fn {conn, els} -> {conn, strip(els)} end)
    commands = for {_conn, %Command{} = cmd} <- resolved, do: cmd
    elements = Enum.flat_map(subcommands, fn {_conn, els} -> els end)
    structure = detect_structure(elements, resolved)

    effects =
      parse_opacity(resolved, elements) ++
        structure_effects(structure) ++
        git_env_effects(elements, commands) ++
        crontab_effects(commands) ++
        Enum.flat_map(commands, &git_command_effects/1)

    base = analysis(commands, structure, effects)
    merge_recursions(base, commands, depth)
  end

  # Build an Analysis, deriving `opaque?` from the effects so the invariant
  # (`opaque?` ⟺ an `{:opaque, _}` effect) holds by construction.
  defp analysis(commands, structure, effects) do
    uniq = Enum.uniq(effects)

    %Analysis{
      commands: commands,
      structure: structure,
      effects: uniq,
      opaque?: opaque_present?(uniq)
    }
  end

  defp opaque_present?(effects), do: Enum.any?(effects, &match?({:opaque, _}, &1))

  defp opaque_analysis(scope, reason),
    do: analysis([], [], [effect(:opaque, %{scope: scope, reason: reason})])

  # ---- Effect sub-mappers (all funneled through effect/2) ----

  defp effect(kind, evidence), do: {kind, evidence}

  # Parent-owned opacity: a here-doc anywhere feeds executable stdin we will not
  # parse, and a `strip → :unknown` is a command word we cannot resolve (a
  # parameter-expansion word or an unrecognized wrapper flag). Both fail closed.
  defp parse_opacity(resolved, elements) do
    []
    |> maybe_opaque(unresolved_command?(resolved), :unresolved_command)
    |> maybe_opaque(heredoc_present?(elements), :heredoc)
  end

  defp maybe_opaque(effects, true, reason),
    do: [effect(:opaque, %{scope: :parse, reason: reason}) | effects]

  defp maybe_opaque(effects, false, _reason), do: effects

  defp unresolved_command?(resolved), do: Enum.any?(resolved, &match?({_, :unknown}, &1))

  defp structure_effects(structure), do: Enum.map(structure, &effect(&1, %{}))

  # A visible GIT_CONFIG_* env mutation injects config (incl. `alias.ci=commit`)
  # into a later git invocation, so an actual git command in its presence gates.
  defp git_env_effects(elements, commands) do
    if git_config_env_present?(elements) and any_git?(commands) do
      [effect(:git_config_injection, %{reason: :git_config_env})]
    else
      []
    end
  end

  defp crontab_effects(commands) do
    if Enum.any?(commands, &(&1.cmd == "crontab")), do: [effect(:crontab, %{})], else: []
  end

  defp any_git?(commands), do: Enum.any?(commands, &(&1.cmd == "git"))

  # Per-git-command facts via the Git interpreter (re-tokenizer injected as a
  # closure so the parent grammar stays single-sourced and there is no cycle).
  defp git_command_effects(%Command{cmd: "git"} = command) do
    command
    |> Git.facts(&retokenize_args/1)
    |> invocation_effects()
  end

  defp git_command_effects(_command), do: []

  defp invocation_effects(inv) do
    commit_effect(inv.commits?) ++
      Enum.map(inv.inline_injections, &injection_effect/1) ++
      Enum.map(inv.config_writes, &write_effect/1) ++
      opaque_effect(inv.opaque_reason)
  end

  defp commit_effect(true), do: [effect(:git_commit, %{reason: :resolved})]
  defp commit_effect(false), do: []

  defp injection_effect({:config_include, key}),
    do: effect(:git_config_injection, %{reason: :config_include, key: key})

  defp injection_effect(reason), do: effect(:git_config_injection, %{reason: reason})

  defp write_effect({reason, value}) when reason in [:alias_write, :include_write],
    do: effect(:git_config_persistent_write, %{reason: reason, key: value})

  defp write_effect({:rename_to, section}),
    do: effect(:git_config_persistent_write, %{reason: :rename_to, section: section})

  defp write_effect(reason), do: effect(:git_config_persistent_write, %{reason: reason})

  defp opaque_effect(nil), do: []
  defp opaque_effect(reason), do: [effect(:opaque, %{scope: :git, reason: reason})]

  # ---- git-env detection ----

  # A visible GIT_CONFIG_* env mutation anywhere on the line injects config into a
  # later git invocation. Shell env state set by one sub-command (a leading/
  # standalone assignment, an `export`/`set -a`) persists to a later `git`, so
  # detect the mutation across all elements; git_env_effects/2 gates any git.
  defp git_config_env_present?(elements), do: Enum.any?(elements, &git_config_assignment?/1)

  # An assignment-FORM word (NAME=…) whose NAME starts with GIT_CONFIG — matches a
  # leading/standalone assignment or an `env`/`export`/`set -a`/`declare -x` arg.
  # The regex guard means the GIT_CONFIG prefix is necessarily the variable name.
  defp git_config_assignment?({:word, text, _dyns}),
    do: Regex.match?(@assignment_re, text) and String.starts_with?(text, "GIT_CONFIG")

  defp git_config_assignment?(_element), do: false

  # ---- Interpreter / eval recursion ----

  # Interpreter/eval recursion folded into analysis: a shell with a `-c` script
  # (or `eval <args>`) re-enters analyze on the inner script (depth-bounded) and
  # merges the inner commands/structure/effects.
  defp merge_recursions(base, commands, depth) do
    commands
    |> Enum.flat_map(&recursion_scripts/1)
    |> Enum.reduce(base, fn directive, acc -> merge_recursion(directive, acc, depth) end)
  end

  # A dynamic interpreter/eval target (`sh -c "$cmd"`, `eval "$x"`) is opaque ⇒
  # fail closed; a literal one re-enters analysis (depth-bounded).
  defp merge_recursion(:dynamic, acc, _depth),
    do: add_effect(acc, effect(:opaque, %{scope: :interpreter, reason: :dynamic_interpreter}))

  defp merge_recursion({:script, script}, acc, depth),
    do: merge(acc, do_analyze(script, depth + 1))

  defp recursion_scripts(%Command{cmd: cmd, args: args, arg_dyns: arg_dyns})
       when cmd in @shells do
    case shell_script(Enum.zip(args, arg_dyns)) do
      nil -> []
      directive -> [directive]
    end
  end

  defp recursion_scripts(%Command{cmd: "eval", args: args, arg_dyns: arg_dyns}) do
    if Enum.any?(arg_dyns, &(&1 != [])),
      do: [:dynamic],
      else: [{:script, Enum.join(args, " ")}]
  end

  defp recursion_scripts(_command), do: []

  defp merge(a, b),
    do:
      analysis(
        a.commands ++ b.commands,
        Enum.uniq(a.structure ++ b.structure),
        a.effects ++ b.effects
      )

  defp add_effect(%Analysis{} = a, effect),
    do: analysis(a.commands, a.structure, [effect | a.effects])

  # ---- Structure detection ----

  defp detect_structure(elements, resolved) do
    dyn_kinds =
      elements
      |> Enum.flat_map(&word_dyns/1)
      |> Enum.flat_map(&dyn_to_structure/1)

    Enum.uniq(dyn_kinds ++ pipe_structure(resolved))
  end

  defp word_dyns({:word, _text, dyns}), do: dyns
  defp word_dyns(_element), do: []

  defp dyn_to_structure(:command), do: [:command_substitution]
  defp dyn_to_structure(:backtick), do: [:backtick]
  defp dyn_to_structure(_param), do: []

  defp pipe_structure(resolved) do
    if Enum.any?(resolved, &piped_bare_shell?/1), do: [:pipe_to_shell], else: []
  end

  # A pipe target resolving (through wrappers) to a bare shell with no `-c`. A
  # `-c` on the pipe RHS diverts to recursion (handled above), not a pipe-gate.
  defp piped_bare_shell?({:pipe, %Command{cmd: cmd, args: args, arg_dyns: arg_dyns}}),
    do: cmd in @shells and shell_script(Enum.zip(args, arg_dyns)) == nil

  defp piped_bare_shell?(_resolved), do: false

  # ---- Command-word resolution (leading-prefix normalizer) ----

  # A leading redirect is transparent; a core-only form (`2> /dev/null`) also
  # consumes its target word. (A here-doc is flagged globally in build/2.)
  defp strip([{:redirect, raw} | rest]) do
    if redirect_meta(raw).needs_target?,
      do: strip(drop_leading_word(rest)),
      else: strip(rest)
  end

  defp strip([{:word, text, dyns} | rest]) do
    case classify_leading(text, dyns) do
      :assignment -> strip(rest)
      :keyword -> strip(rest)
      :dynamic -> :unknown
      :command -> build_command(text, rest)
      {:wrapper, name} -> strip_wrapper_then(name, rest)
    end
  end

  defp strip([]), do: %Command{cmd: nil, args: []}

  defp build_command(text, rest) do
    {args, arg_dyns} = Enum.unzip(extract_args(rest))
    %Command{cmd: Path.basename(text), args: args, arg_dyns: arg_dyns}
  end

  defp classify_leading(text, dyns) do
    base = Path.basename(text)

    cond do
      # Assignment first, so `FOO=$BAR git commit` strips before the dyn check.
      Regex.match?(@assignment_re, text) -> :assignment
      # A parameter-expansion command word is runtime-dynamic — can't resolve it.
      dyns != [] -> :dynamic
      base in @control_keywords -> :keyword
      Map.has_key?(@wrappers, base) -> {:wrapper, base}
      true -> :command
    end
  end

  defp strip_wrapper_then(name, rest) do
    case strip_wrapper(@wrappers[name], rest, 0) do
      {:ok, remaining} -> strip(remaining)
      :unknown -> :unknown
    end
  end

  defp strip_wrapper(_spec, [], _pos), do: {:ok, []}
  defp strip_wrapper(_spec, [{:redirect, _} | _] = rest, _pos), do: {:ok, rest}
  defp strip_wrapper(_spec, [{:word, "--", []} | rest], _pos), do: {:ok, rest}

  defp strip_wrapper(spec, [{:word, text, _dyns} | rest] = all, pos) do
    cond do
      spec.assignments and Regex.match?(@assignment_re, text) -> strip_wrapper(spec, rest, pos)
      wrapper_flag?(text) -> handle_wrapper_flag(spec, text, rest, pos)
      positional_pending?(spec, pos) -> strip_wrapper(spec, rest, pos + 1)
      true -> {:ok, all}
    end
  end

  defp wrapper_flag?(text), do: String.starts_with?(text, "-") and text != "-"

  defp positional_pending?(spec, pos), do: pos < spec.positional

  defp handle_wrapper_flag(spec, flag, rest, pos) do
    cond do
      flag in spec.bool -> strip_wrapper(spec, rest, pos)
      flag in spec.val -> strip_wrapper(spec, drop_leading_word(rest), pos)
      bundled_value?(spec, flag) -> strip_wrapper(spec, rest, pos)
      # Don't guess past an unrecognized wrapper flag.
      true -> :unknown
    end
  end

  defp bundled_value?(spec, flag) do
    Enum.any?(spec.val, fn vf ->
      String.starts_with?(flag, vf) and flag != vf and
        (byte_size(vf) == 2 or String.starts_with?(flag, vf <> "="))
    end)
  end

  defp drop_leading_word([{:word, _text, _dyns} | rest]), do: rest
  defp drop_leading_word(elements), do: elements

  # Post-command args as `{text, dyns}` pairs, redirect-aware: a redirect needing
  # a target (`> out`) drops the target word so it is not mistaken for an arg /
  # sub-command (`git > out commit` ⇒ args `["commit"]`). Reused to re-tokenize
  # git alias expansions, hence the op/other catch-all (an op cannot be an arg).
  @spec extract_args([tuple()]) :: [pair()]
  defp extract_args([{:redirect, raw} | rest]) do
    if redirect_meta(raw).needs_target?,
      do: extract_args(drop_leading_word(rest)),
      else: extract_args(rest)
  end

  defp extract_args([{:word, text, dyns} | rest]), do: [{text, dyns} | extract_args(rest)]
  defp extract_args([_other | rest]), do: extract_args(rest)
  defp extract_args([]), do: []

  # Re-tokenize an alias expansion into arg pairs (same grammar). Passed to
  # `Git.facts/2` as a closure. A parse that does not fully consume fails closed.
  @spec retokenize_args(String.t()) :: [pair()] | :error
  defp retokenize_args(expansion) do
    case tokenize(expansion) do
      {:ok, tokens, "", _context, _line, _column} -> extract_args(coalesce(tokens))
      _ -> :error
    end
  end

  # ---- Redirect classification ----

  defp heredoc_present?(elements), do: Enum.any?(elements, &heredoc_element?/1)

  defp heredoc_element?({:redirect, raw}), do: redirect_meta(raw).heredoc?
  defp heredoc_element?(_element), do: false

  defp redirect_meta(raw) do
    case Regex.run(@redirect_re, raw) do
      [_full, core, target] -> classify_redirect(core, target)
      _ -> %{heredoc?: false, needs_target?: false}
    end
  end

  defp classify_redirect(core, _target) when core in ["<<", "<<-", "<<<"],
    do: %{heredoc?: true, needs_target?: false}

  defp classify_redirect(core, _target) when core in [">&", "<&", "&>", "&>>"],
    do: %{heredoc?: false, needs_target?: false}

  defp classify_redirect(_core, ""), do: %{heredoc?: false, needs_target?: true}
  defp classify_redirect(_core, _target), do: %{heredoc?: false, needs_target?: false}

  # ---- Interpreter `-c` script extraction ----

  # The interpreter script for a shell command, from `{text, dyns}` arg pairs:
  # nil (no `-c` — a bare shell or a script-file invocation), :dynamic (a runtime
  # `-c` target we cannot read), or {:script, s} (a literal script to re-analyze).
  @spec shell_script([pair()]) :: script()
  defp shell_script([{text, dyns} | rest]) do
    case c_trigger(text) do
      {:inline, inline} -> script_or_dynamic(inline, dyns)
      :next -> next_script(rest, dyns)
      :no -> shell_script(rest)
    end
  end

  defp shell_script([]), do: nil

  # A word carrying dyns is partly runtime-dynamic (`-c"$x"`, a `$cmd` next arg)
  # ⇒ fail closed; otherwise the literal text is the script.
  defp script_or_dynamic(_text, dyns) when dyns != [], do: :dynamic
  defp script_or_dynamic(text, _dyns), do: {:script, text}

  # Bare `-c`: the script is the next arg — unless the dyns sit on the `-c` word
  # itself (fused `-c"$cmd"`, whose dynamic content collapsed to empty text).
  defp next_script(_rest, flag_dyns) when flag_dyns != [], do: :dynamic
  defp next_script([{text, dyns} | _rest], _flag_dyns), do: script_or_dynamic(text, dyns)
  defp next_script([], _flag_dyns), do: {:script, ""}

  defp c_trigger(arg) do
    case Regex.run(@c_flag_re, arg) do
      [_full, ""] -> :next
      [_full, inline] -> {:inline, inline}
      nil -> :no
    end
  end

  # ---- Token coalescing (pieces → words) ----

  defp coalesce(tokens) do
    {elements, acc} = Enum.reduce(tokens, {[], []}, &coalesce_step/2)

    elements
    |> flush(acc)
    |> Enum.reverse()
  end

  defp coalesce_step(:ws, {elements, acc}), do: {flush(elements, acc), []}
  defp coalesce_step({:op, op}, {elements, acc}), do: {[{:op, op} | flush(elements, acc)], []}

  defp coalesce_step({:redirect, raw}, {elements, acc}),
    do: {[{:redirect, raw} | flush(elements, acc)], []}

  defp coalesce_step({:lit, _} = piece, {elements, acc}), do: {elements, [piece | acc]}
  defp coalesce_step({:dyn, _} = piece, {elements, acc}), do: {elements, [piece | acc]}

  defp flush(elements, []), do: elements

  defp flush(elements, acc) do
    pieces = Enum.reverse(acc)

    text =
      pieces
      |> Enum.flat_map(&lit_text/1)
      |> Enum.join()

    dyns = Enum.flat_map(pieces, &dyn_kind/1)
    [{:word, text, dyns} | elements]
  end

  defp lit_text({:lit, s}), do: [s]
  defp lit_text(_piece), do: []

  defp dyn_kind({:dyn, k}), do: [k]
  defp dyn_kind(_piece), do: []

  # ---- Sub-command splitting (retains each boundary's connector) ----

  defp split(elements) do
    {subs, conn, cur} = Enum.reduce(elements, {[], :start, []}, &split_step/2)

    subs
    |> close(conn, cur)
    |> Enum.reverse()
  end

  defp split_step({:op, op}, {subs, conn, cur}), do: {close(subs, conn, cur), op, []}
  defp split_step(element, {subs, conn, cur}), do: {subs, conn, [element | cur]}

  defp close(subs, _conn, []), do: subs
  defp close(subs, conn, cur), do: [{conn, Enum.reverse(cur)} | subs]
end
