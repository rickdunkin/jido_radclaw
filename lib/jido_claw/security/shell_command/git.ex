defmodule JidoClaw.Security.ShellCommand.Git do
  @moduledoc """
  Git interpreter for the `run_command` approval analyzer: turns one resolved
  `git` command into **semantic risk facts** rather than a yes/no gate boolean.

  `JidoClaw.Security.ShellCommand` resolves a command word and its args the way
  a shell would, then hands every `git` invocation here as a plain map
  (`%{args: [...], arg_dyns: [...]}`). `facts/2` walks git's real option grammar
  and returns an `Invocation` of honest facts:

    * `commits?` — the sub-command resolves (literally, or through a fully
      expanded alias chain) to `commit`. This is the only thing that becomes a
      `:git_commit` effect; git-resolution *uncertainty* never masquerades as a
      commit.
    * `pushes?` — the sub-command resolves (literally, or through a fully
      expanded alias chain) to `push` — publishing to a remote. Same honesty
      contract: only a resolved push becomes a `:git_push` effect.
    * `inline_injections` — config injected into *this* run via global `-c` /
      `--config-env`: a config-include directive, a `--config-env` value read
      from an unreadable env var, or a dynamic inline `-c` value.
    * `config_writes` — a `git config` sub-command that **plants** config a later
      `git` honors (an `alias.*`/`include.*` write, a dynamic key, a section
      rename into a risky section, or an editor-driven mutation). These persist
      to `.git/config` across `run_command` calls.
    * `opaque_reason` — git could not be resolved confidently (an unknown global
      flag, a dynamic sub-command, an alias cycle, a `!`-shell alias, an
      unparsable alias body, or an alias body with no sub-command). This becomes
      a fail-closed `{:opaque, scope: :git}` effect, **not** a false `:git_commit`.

  ## The `git config` state machine

  `git config` is modeled over git's documented grammar (`git config -h`):

      git config [config-opts] [<action>] [config-opts] <key|sections> [value]
        actions: list | get | set | unset | rename-section | remove-section | edit
        legacy:  git config [config-opts] <key> [value]   (write); <key> alone is a read

  Config options may appear before *and* after an optional action word. Reads and
  removals (`get`/`list`/`unset`/`--get*`/`--unset*`/`remove-section`) cannot plant
  config a later git honors, so they are intentionally allowed. Writes plant: a
  literal `alias.*`/`include.*`/`includeIf.*` key, a *dynamic* key (we cannot tell
  what it sets), a `rename-section` whose destination is a risky section, and
  `edit`/`-e`/`--edit` (a scriptable persistent-config mutation surface). A
  dynamic token anywhere in a decision-critical position (key, section operand,
  config option) fails closed.

  ## Decoupling

  This module is **self-contained**: it matches the command map structurally and
  receives a re-tokenizer as a closure (`retokenize`), so the parent grammar
  stays single-sourced, there is no `ShellCommand ↔ Git` compile cycle, and the
  interpreter is independently testable.
  """

  defmodule Invocation do
    @moduledoc """
    Semantic facts from one resolved `git` command (see the parent moduledoc).
    All-default (`%Invocation{}`) means a benign git run that gates nothing.
    """
    defstruct subcommand: nil,
              commits?: false,
              pushes?: false,
              inline_injections: [],
              config_writes: [],
              opaque_reason: nil

    @type subcommand :: nil | {:literal, String.t()} | {:dynamic, String.t()}
    @type injection :: JidoClaw.Security.ShellCommand.Git.injection()
    @type config_write :: JidoClaw.Security.ShellCommand.Git.config_write()
    @type opaque_reason :: JidoClaw.Security.ShellCommand.Git.opaque_reason()

    @type t :: %__MODULE__{
            subcommand: subcommand(),
            commits?: boolean(),
            pushes?: boolean(),
            inline_injections: [injection()],
            config_writes: [config_write()],
            opaque_reason: opaque_reason()
          }
  end

  @typedoc "A word and its dynamic markers (`[]` ⇒ fully literal)."
  @type pair :: {String.t(), [atom()]}
  @typedoc "Re-tokenizer for an alias body: parent grammar, injected as a closure."
  @type retokenize :: (String.t() -> [pair()] | :error)
  @typedoc "Inline (`-c`/`--config-env`) config injected into this git run."
  @type injection :: {:config_include, String.t()} | :config_env_var | :dynamic_inline_c
  @typedoc "A `git config` write that plants config a later git honors."
  @type config_write ::
          {:alias_write, String.t()}
          | {:include_write, String.t()}
          | {:rename_to, String.t()}
          | :dynamic_key
          | :dynamic_section
          | :config_edit
  @typedoc "Git-resolution uncertainty — fails closed to an `{:opaque, scope: :git}` effect."
  @type opaque_reason ::
          nil
          | :unknown_flag
          | :dynamic_subcommand
          | :alias_cycle
          | :shell_alias
          | :alias_unparsable
          | :alias_no_subcommand

  @type command_input :: %{
          :args => [String.t()],
          :arg_dyns => [[atom()]],
          optional(atom()) => term()
        }

  @typep git_aliases :: %{optional(String.t()) => {:expansion, String.t()}}
  @typep walk_result ::
           {:candidate, pair(), [pair()], git_aliases(), Invocation.t()}
           | {:none, git_aliases(), Invocation.t()}
           | {:unknown_flag, Invocation.t()}
  @typep strip_result ::
           :dynamic
           | :read
           | :edit
           | :unknown
           | {:section, :rename | :remove, [pair()]}
           | {:stop, [pair()]}

  # ---- Git pre-sub-command global options (baked as DATA) ----
  # `path_value`: separate value, skip flag+value (a dynamic value is benign —
  # `git -C "$dir" status`). `config`: alias-capable (`-c key=value`). `bool`: no
  # value. An UNKNOWN `-`-leading pre-sub-command flag fails closed.
  @git_path_value_flags ~w(-C --git-dir --work-tree --namespace --super-prefix --attr-source)
  @git_config_flags ~w(-c --config-env)
  @git_bool_flags ~w(-p --paginate -P --no-pager --bare --no-replace-objects
                     --no-lazy-fetch --no-optional-locks --no-advice
                     --literal-pathspecs --glob-pathspecs --noglob-pathspecs
                     --icase-pathspecs --exec-path --html-path --man-path
                     --info-path --version --help -h)

  # Alias-chain depth cap; a breach — including a cycle (`ci=co, co=ci`) — fails closed.
  @git_alias_depth 8

  # ---- `git config` grammar (baked as DATA; supersets only over-gate reads) ----
  # INVARIANT: no entry may consume the *write-key* token, so every value-taking
  # write option lives in skip-value, not bool.
  #
  # flag + 1 NON-key value (separate form; bundled `--opt=val` is one token).
  @config_skip_value_opts ~w(-f --file --blob -t --type --default --value --url --comment)
  # read/removal modes that take a KEY arg — INTENTIONALLY ALLOWED (cannot plant).
  @config_read_key_opts ~w(--get --get-all --get-regexp --get-color --get-colorbool --unset --unset-all)
  @config_urlmatch "--get-urlmatch"
  # no-arg flags (scope/format + write-mode --add/--replace-all whose key is NEXT).
  @config_bool_opts ~w(--global --local --system --worktree -z --null --name-only --show-origin
                       --show-scope --show-names -l --list --add --replace-all --all --regexp
                       --fixed-value --includes --no-includes --bool --int --bool-or-int
                       --bool-or-str --path --expiry-date --no-type)
  @config_read_actions ~w(list get unset)
  @config_write_actions ~w(set)
  @config_edit_actions ~w(edit)
  # `edit`/-e/--edit open the config file in $GIT_EDITOR/$VISUAL — a scriptable
  # persistent-config mutation surface that can plant an alias, so they gate.
  @config_edit_flags ~w(-e --edit)
  @risky_sections ~w(alias include includeif)

  # ---- Public entry ----

  @doc """
  Resolve one `git` command (`%{args: _, arg_dyns: _}`) into an `Invocation`.

  `retokenize` re-tokenizes an alias body into `[pair()]` (or `:error`) using the
  parent grammar — injected so this module carries no dependency on it.
  """
  @spec facts(command_input(), retokenize()) :: Invocation.t()
  def facts(%{args: args, arg_dyns: arg_dyns}, retokenize) when is_function(retokenize, 1) do
    pairs = Enum.zip(args, arg_dyns)
    resolve_top(git_walk(pairs, %{}, %Invocation{}), retokenize)
  end

  # ---- Sub-command resolution ----

  @spec resolve_top(walk_result(), retokenize()) :: Invocation.t()
  defp resolve_top({:unknown_flag, inv}, _retok), do: set_opaque(inv, :unknown_flag)
  defp resolve_top({:none, _aliases, inv}, _retok), do: inv

  defp resolve_top({:candidate, {text, dyns} = pair, rest, aliases, inv}, retok) do
    classify_candidate(
      pair,
      rest,
      aliases,
      %{inv | subcommand: subcommand_tag(text, dyns)},
      0,
      retok
    )
  end

  defp subcommand_tag(text, []), do: {:literal, text}
  defp subcommand_tag(text, _dyns), do: {:dynamic, text}

  @spec classify_candidate(
          pair(),
          [pair()],
          git_aliases(),
          Invocation.t(),
          non_neg_integer(),
          retokenize()
        ) ::
          Invocation.t()
  defp classify_candidate({_text, dyns}, _rest, _aliases, inv, _depth, _retok) when dyns != [],
    do: set_opaque(inv, :dynamic_subcommand)

  defp classify_candidate({"config", _dyns}, rest, _aliases, inv, _depth, _retok),
    do: config_invocation(rest, inv)

  defp classify_candidate({"commit", _dyns}, _rest, _aliases, inv, _depth, _retok),
    do: %{inv | commits?: true}

  defp classify_candidate({"push", _dyns}, _rest, _aliases, inv, _depth, _retok),
    do: %{inv | pushes?: true}

  defp classify_candidate({text, _dyns}, _rest, aliases, inv, depth, retok),
    do: resolve_alias(text, aliases, inv, depth, retok)

  # An unknown sub-command that is not a recorded alias is benign (commits? stays
  # false). A recorded alias is expanded through the same walk.
  @spec resolve_alias(String.t(), git_aliases(), Invocation.t(), non_neg_integer(), retokenize()) ::
          Invocation.t()
  defp resolve_alias(text, aliases, inv, depth, retok) do
    case Map.fetch(aliases, String.downcase(text)) do
      {:ok, {:expansion, body}} -> expand_alias(body, aliases, inv, depth, retok)
      :error -> inv
    end
  end

  defp expand_alias(body, aliases, inv, depth, retok) do
    cond do
      depth >= @git_alias_depth -> set_opaque(inv, :alias_cycle)
      shell_alias?(body) -> set_opaque(inv, :shell_alias)
      true -> reexpand(body, aliases, inv, depth, retok)
    end
  end

  defp reexpand(body, aliases, inv, depth, retok) do
    case retok.(body) do
      :error -> set_opaque(inv, :alias_unparsable)
      pairs -> resolve_nested(git_walk(pairs, aliases, inv), depth + 1, retok)
    end
  end

  # Inside an alias body, no resolved sub-command is opaque: the real one would
  # come from trailing args after the alias word, which we do not carry over.
  defp resolve_nested({:unknown_flag, inv}, _depth, _retok), do: set_opaque(inv, :unknown_flag)

  defp resolve_nested({:none, _aliases, inv}, _depth, _retok),
    do: set_opaque(inv, :alias_no_subcommand)

  defp resolve_nested({:candidate, pair, rest, aliases, inv}, depth, retok),
    do: classify_candidate(pair, rest, aliases, inv, depth, retok)

  # Record the git-resolution opacity reason. Set once per path: every caller is
  # a terminal branch that returns immediately, so a reason is never overwritten.
  defp set_opaque(inv, reason), do: %{inv | opaque_reason: reason}

  # ---- Global-option walk (accumulates inline injections + alias defs) ----

  @spec git_walk([pair()], git_aliases(), Invocation.t()) :: walk_result()
  defp git_walk([], aliases, inv), do: {:none, aliases, inv}

  defp git_walk([{text, dyns} = pair | rest], aliases, inv) do
    cond do
      not flag_arg?(text) -> {:candidate, pair, rest, aliases, inv}
      String.contains?(text, "=") -> git_bundled_flag(text, dyns, rest, aliases, inv)
      text in @git_path_value_flags -> git_skip_value(rest, aliases, inv)
      text in @git_config_flags -> git_config_separate(text, rest, aliases, inv)
      text in @git_bool_flags -> git_walk(rest, aliases, inv)
      true -> {:unknown_flag, inv}
    end
  end

  # Separate value flag (`-C dir`): skip flag + value. A dynamic value is benign.
  defp git_skip_value([_value | rest], aliases, inv), do: git_walk(rest, aliases, inv)
  defp git_skip_value([], aliases, inv), do: {:none, aliases, inv}

  # Separate config flag (`-c key=value` / `--config-env name=ENVVAR`): absorb the
  # value token (injection and/or recorded alias), then continue the walk.
  defp git_config_separate(_flag, [], aliases, inv), do: {:none, aliases, inv}

  defp git_config_separate(flag, [{value, dyns} | rest], aliases, inv) do
    {next_aliases, next_inv} = absorb_config(flag, value, dyns, aliases, inv)
    git_walk(rest, next_aliases, next_inv)
  end

  # Bundled `--flag=value`: classify by the prefix before `=`; an unknown prefix
  # fails closed.
  defp git_bundled_flag(text, dyns, rest, aliases, inv) do
    [prefix | _] = String.split(text, "=", parts: 2)

    cond do
      prefix in @git_config_flags -> git_bundled_config(prefix, text, dyns, rest, aliases, inv)
      prefix in @git_path_value_flags -> git_walk(rest, aliases, inv)
      prefix in @git_bool_flags -> git_walk(rest, aliases, inv)
      true -> {:unknown_flag, inv}
    end
  end

  defp git_bundled_config(prefix, text, dyns, rest, aliases, inv) do
    {next_aliases, next_inv} = absorb_config(prefix, bundled_value(text), dyns, aliases, inv)
    git_walk(rest, next_aliases, next_inv)
  end

  # `--config-env` reads the value from an env var we cannot see ⇒ always an
  # injection. A dynamic inline `-c` value ⇒ injection. A literal `-c key=value`
  # ⇒ a config-include injection, an alias recorded for chain resolution, or a
  # benign no-op.
  @spec absorb_config(String.t(), String.t(), [atom()], git_aliases(), Invocation.t()) ::
          {git_aliases(), Invocation.t()}
  defp absorb_config("--config-env", _value, _dyns, aliases, inv),
    do: {aliases, add_injection(inv, :config_env_var)}

  defp absorb_config(_flag, _value, dyns, aliases, inv) when dyns != [],
    do: {aliases, add_injection(inv, :dynamic_inline_c)}

  defp absorb_config(_flag, value, _dyns, aliases, inv) do
    if config_include?(value) do
      {aliases, add_injection(inv, {:config_include, before_eq(value)})}
    else
      {record_alias_def(value, aliases), inv}
    end
  end

  # ---- `git config` state machine (the bug fix + refinements) ----

  # Everything after a resolved `config` sub-command. Strip leading config
  # options, then dispatch on the action/key (or a section flag the stripper hit).
  @spec config_invocation([pair()], Invocation.t()) :: Invocation.t()
  defp config_invocation(rest, inv),
    do: dispatch_strip(strip_config_opts(rest), inv, :action_or_key)

  # `set` consumes the action word, then options can recur before the write-key.
  defp classify_after_set(rest, inv), do: dispatch_strip(strip_config_opts(rest), inv, :key)

  defp dispatch_strip(:dynamic, inv, _mode), do: add_write(inv, :dynamic_key)
  defp dispatch_strip(:read, inv, _mode), do: inv
  defp dispatch_strip(:edit, inv, _mode), do: add_write(inv, :config_edit)
  defp dispatch_strip(:unknown, inv, _mode), do: set_opaque(inv, :unknown_flag)

  defp dispatch_strip({:section, kind, rest}, inv, _mode),
    do: add_writes(inv, judge_section(kind, rest))

  defp dispatch_strip({:stop, pairs}, inv, :action_or_key), do: classify_config(pairs, inv)
  defp dispatch_strip({:stop, pairs}, inv, :key), do: classify_key(pairs, inv)

  # At the first non-flag token: an action word, or the legacy default write-key.
  defp classify_config([], inv), do: inv

  defp classify_config([{text, dyns} | rest], inv) do
    cond do
      dyns != [] -> add_write(inv, :dynamic_key)
      text in @config_read_actions -> inv
      text in @config_edit_actions -> add_write(inv, :config_edit)
      text == "rename-section" -> add_writes(inv, judge_section(:rename, rest))
      text == "remove-section" -> inv
      text in @config_write_actions -> classify_after_set(rest, inv)
      true -> classify_key([{text, dyns} | rest], inv)
    end
  end

  # Classify the write-key: dynamic ⇒ fail closed; risky section ⇒ a planting
  # write; else benign (`git config user.name "$val"` stops here, never inspecting
  # the value).
  defp classify_key([], inv), do: inv

  defp classify_key([{_text, dyns} | _rest], inv) when dyns != [],
    do: add_write(inv, :dynamic_key)

  defp classify_key([{text, _dyns} | _rest], inv) do
    case config_section(text) do
      "alias" -> add_write(inv, {:alias_write, text})
      section when section in ~w(include includeif) -> add_write(inv, {:include_write, text})
      _other -> inv
    end
  end

  # Walk leading config options, short-circuiting on a special position.
  @spec strip_config_opts([pair()]) :: strip_result()
  defp strip_config_opts([]), do: {:stop, []}

  defp strip_config_opts([{text, dyns} | rest] = pairs) do
    cond do
      dyns != [] -> :dynamic
      flag_arg?(text) -> classify_config_opt(text, rest)
      true -> {:stop, pairs}
    end
  end

  defp classify_config_opt(text, rest) do
    cond do
      text in @config_read_key_opts or text == @config_urlmatch -> :read
      text in @config_edit_flags -> :edit
      text == "--rename-section" -> {:section, :rename, rest}
      text == "--remove-section" -> {:section, :remove, rest}
      text in @config_skip_value_opts -> strip_config_opts(drop_one(rest))
      bundled_config_opt?(text) -> strip_config_opts(rest)
      text in @config_bool_opts -> strip_config_opts(rest)
      true -> :unknown
    end
  end

  # `remove-section <name>` cannot plant — benign. `rename-section <old> <new>`
  # plants when the destination is a risky section (or either operand is dynamic).
  # Post-trigger config options are stripped first (`rename-section --file f a b`).
  @spec judge_section(:rename | :remove, [pair()]) :: [config_write()]
  defp judge_section(:remove, _rest), do: []
  defp judge_section(:rename, rest), do: rename_facts(strip_config_opts(rest))

  defp rename_facts({:stop, [{_old, old_dyns}, {new, new_dyns} | _]}) do
    cond do
      old_dyns != [] or new_dyns != [] -> [:dynamic_section]
      config_section(new) in @risky_sections -> [{:rename_to, config_section(new)}]
      true -> []
    end
  end

  defp rename_facts({:stop, _incomplete}), do: []
  # A dynamic token or any odd flag where an operand belongs ⇒ fail closed.
  defp rename_facts(_other), do: [:dynamic_section]

  # ---- Invocation accumulators ----

  defp add_injection(inv, injection),
    do: %{inv | inline_injections: [injection | inv.inline_injections]}

  defp add_write(inv, write), do: %{inv | config_writes: [write | inv.config_writes]}
  defp add_writes(inv, writes), do: Enum.reduce(writes, inv, &add_write(&2, &1))

  defp record_alias_def(value, aliases) do
    case parse_alias_config(value) do
      {:ok, name, body} -> Map.put(aliases, name, {:expansion, body})
      :error -> aliases
    end
  end

  # `[ALIAS.]<name>=<body>` → `{:ok, downcased_name, body}`. git config section
  # and variable names are case-insensitive, so the name is normalized.
  @spec parse_alias_config(String.t()) :: {:ok, String.t(), String.t()} | :error
  defp parse_alias_config(value) do
    with [section, rest] <- String.split(value, ".", parts: 2),
         "alias" <- String.downcase(section),
         [name, body] when name != "" <- String.split(rest, "=", parts: 2) do
      {:ok, String.downcase(name), body}
    else
      _ -> :error
    end
  end

  # ---- Small predicates / parsers ----

  # `include.path` / `includeIf.*.path` load config (incl. aliases) from another
  # file before git resolves the sub-command — config injection.
  defp config_include?(value), do: config_section(before_eq(value)) in ~w(include includeif)

  # The downcased git config section — the part before a key's first `.`. Section
  # names are case-insensitive.
  defp config_section(key), do: String.downcase(hd(String.split(key, ".", parts: 2)))

  defp before_eq(string), do: hd(String.split(string, "=", parts: 2))

  # A `!`-prefixed alias body is a shell command we cannot inspect — fail closed.
  defp shell_alias?(body), do: String.starts_with?(String.trim_leading(body), "!")

  defp flag_arg?(text), do: String.starts_with?(text, "-")

  # A `--opt=value` token whose prefix is a known value-taking config option.
  defp bundled_config_opt?(text) do
    case String.split(text, "=", parts: 2) do
      [prefix, _value] -> prefix in @config_skip_value_opts
      _single -> false
    end
  end

  defp bundled_value(text) do
    case String.split(text, "=", parts: 2) do
      [_prefix, value] -> value
      [_prefix] -> ""
    end
  end

  defp drop_one([_token | rest]), do: rest
  defp drop_one([]), do: []
end
