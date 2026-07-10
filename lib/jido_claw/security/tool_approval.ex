defmodule JidoClaw.Security.ToolApproval do
  # The {code, details, message} map is the LLM-facing wire-error contract
  # (shared with JidoClaw.Tools.Error) — an explicit API surface, not
  # incidental duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  Host-enforced approval gate for require-listed LLM tool calls.

  `gate/4` sits in the shared `JidoClaw.Tools.Action` wrapper between the LLM's
  decision to call a tool and the tool executing. For a require-listed (or
  param-pattern-triggered) call it routes through
  `JidoClaw.Orchestration.ToolApprovals` and returns:

    * `:ok` — not gated, gating disabled, or a prior approval was consumed; the
      tool runs.
    * `{:error, %{code: :approval_pending, ...}}` — a durable pending
      `AgentCase` was opened/reused; the LLM relays the case id and retries the
      identical call only after an operator approves.
    * `{:error, %{code: :approval_denied, ...}}` — an operator rejected an
      identical call (deny-once); the LLM must not auto-retry.
    * `{:error, %{code: :approval_unavailable, ...}}` — fail-closed: no tenant
      scope to record a request, or a DB fault. Not an approval request.

  All three error codes are **non-retryable** in jido_ai (its retry-hint
  whitelist is `[:timeout, :transient, :transient_error, :rate_limited]`), and
  `details` is held to `%{case_id: id}` (or `%{}`) — never `:reason`/`:retry*`
  keys, which jido_ai's retry-hint digger would inspect. The tool-result
  envelope jido_ai builds from the error is what the LLM reads and relays.

  ## What is gated

  A call is gated when its tool name is in `require`, a param-pattern trigger
  fires, **or** the calling agent's template lists it in `require_approval`
  (`JidoClaw.Agent.Templates`). The template overlay is **additive** — it can
  only gate *more* native tools for a given worker class, never weaken the
  global floor — and is keyed off `tool_context.agent_template`, so it applies
  to every templated surface (handoff / spawn / follow-up / skill step) and
  never to the unrouted `"main"` agent. The check order is require-list →
  param-pattern → template, so the most specific reason wins. (AR-8b-2 F2: a
  `run_command` under `sandbox: :docker` SKIPS the param-pattern shell floor —
  its host-shell reasons are inapplicable inside a proven-isolated microVM — but
  the require-list and template overlay still gate; see `native_requirement/4`.)
  The patterns
  close the bypass where a general-purpose tool reaches a gated capability —
  e.g. `run_command "git commit ..."` is the shell equivalent of the gated
  `git_commit` tool. The `run_command` `:command` matchers delegate to
  `JidoClaw.Security.ShellCommand`, a shell-aware analyzer (a `nimble_parsec`
  grammar) that tokenizes the command the way a shell would, splits on
  separators/group boundaries, strips transparent prefixes (env-assignments,
  redirects, control keywords, wrapper words) to resolve the real command word,
  and emits **honest semantic effects** the gate matches on (`{:effect, kind}`).
  So `git commit`, `git -C "my dir" commit`, `FOO=bar git commit`,
  `sudo git commit`, `/usr/bin/git commit`, `sh -c "git commit"`, and the
  multiline / separator variants all gate (`:git_commit`), as do `git push`
  and its dressings (`:git_push` — a push publishes to a remote, and there is
  no native `git_push` tool to require-list, so the pattern is the whole gate)
  and `crontab` (`:crontab`, the `schedule_task` equivalent). For `git` the
  analyzer resolves
  the *true* sub-command past global options, inline `-c alias.X=Y` definitions,
  and alias chains, emitting `:git_commit`/`:git_push` **only** for a
  definitively resolved
  commit/push; git-resolution uncertainty (a dynamic sub-command `git $x`, an
  unknown
  pre-sub-command flag `git --frobnicate commit`, an alias cycle, a `!`-shell
  alias) surfaces as `:opaque` (scope `:git`) — gated, but never a *false*
  `:git_commit`. Config injection (`:git_config_injection`) covers an inline
  `-c include.path=…` directive, a `--config-env` value, a dynamic inline `-c`,
  and any visible `GIT_CONFIG_*` env mutation co-occurring with a git command. A
  `git config` sub-command that **plants** config a later turn honors
  (`:git_config_persistent_write`) is resolved by a deliberate state machine over
  git's real grammar — config options may appear before *and* after an optional
  action word (`set`/`rename-section`/…); writes to an `alias.*`/`include.*` key,
  a *dynamic* key (`git config "$key" commit`, `git config set "$k" commit`), a
  `rename-section` into `alias`/`include`, and an `edit`/`-e`/`--edit` mutation
  all gate, while reads and removals (`git config --get alias.x`,
  `git config get user.name`, `unset`, `remove-section`, `--list`) and a benign
  write (`git config user.name "$val"`) pass. So `git -c alias.ci=commit ci`,
  `git -c include.path=f ci`, `git config alias.ci commit`,
  `git config "$key" commit`, `git config edit`, `GIT_CONFIG_COUNT=1 … git ci`,
  and `export GIT_CONFIG_…=…; git ci` all gate while `git -C "$dir" status` and
  `git config user.name x` stay un-gated; a dynamic interpreter/eval script
  (`sh -c "$cmd"`) fails closed (`:opaque`, scope `:interpreter`). The gate
  additionally fires on *suspicious structure* — command substitution (`$()`),
  backticks, and a pipe into a shell (`curl … | sh`) — tunable (or disabled) via
  `:suspicious_shell_structure_kinds`. Anything it cannot confidently resolve
  fails closed to "require approval" (the `{:effect, :opaque}` floor). The gate
  runs pre-dispatch, so it is backend-agnostic (host `sh -c`, remote SSH shell,
  VFS). Documented residuals —
  covered by the escape valve (add `run_command` to `require` for total
  containment): shell aliases/functions sourced from login/startup files (not
  visible in the command string) and script-file indirection (`bash deploy.sh`,
  `sh < deploy.sh`). False positives merely ask for approval, which is
  acceptable.

  ## Configuration

      config :jido_claw, :tool_approval,
        enabled?: true,
        require: ~w(network_share kill_agent ...),
        suspicious_shell_structure_kinds: [:command_substitution, :backtick, :pipe_to_shell]

  `enabled?`/`require`/`require_patterns`/`suspicious_shell_structure_kinds`
  resolve via per-call opts first, then app config, then the in-module defaults
  (the DestinationPolicy `opt_or_config` pattern), so tests stay env-free. The
  shell param-patterns live in-module (`@require_patterns`); config can **add**
  patterns for other tools but a typo'd config entry can never disable the
  shipped ones (defaults win on merge, and malformed entries are
  warn-and-skipped). `:suspicious_shell_structure_kinds` narrows the `:structure`
  matcher — a literal `[]` disables structural gating (the `:git_commit`/
  `:git_push`/`:git_config_injection`/`:git_config_persistent_write`/`:crontab`
  effect matchers and the `:opaque` fail-closed floor remain), an unknown/
  malformed value falls back to the default. The `{:effect, _}` matchers are
  intentionally not disable-able.
  """

  require Logger

  alias Jido.Shell.VFS.MountTable
  alias JidoClaw.Agent.Templates
  alias JidoClaw.Core.FileStat
  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Core.OsCmd
  alias JidoClaw.Orchestration.ToolApprovals
  alias JidoClaw.Security.ShellCommand
  alias JidoClaw.Security.ToolApproval.MountConfigCache
  alias JidoClaw.VFS.AdapterPolicy
  alias JidoClaw.VFS.Resolver

  @mount_config_max_bytes 256_000
  @mount_config_read_timeout_ms 1_000

  # The conservative default require list, single-sourced here so the config
  # sanity sweep validates the SAME list every environment ships (test config
  # only toggles `enabled?`). Operators override via `:tool_approval, :require`.
  @default_require ~w(network_share kill_agent schedule_task unschedule_task git_commit forget replay_workflow)

  # Suspicious shell-structure kinds the `run_command` `:structure` matcher gates
  # on by default. Operators narrow via `:suspicious_shell_structure_kinds`
  # (a dedicated key, not @require_patterns — see suspicious_structure_kinds/1);
  # a literal `[]` disables structural gating (the git/crontab + unknown? floor
  # stays). Must mirror JidoClaw.Security.ShellCommand's structure vocabulary.
  @default_structure_kinds [:command_substitution, :backtick, :pipe_to_shell]

  @config_defaults [
    enabled?: true,
    require: @default_require,
    mcp_require_approval: true,
    suspicious_shell_structure_kinds: @default_structure_kinds
  ]

  @doc "The shipped default require list (single source of truth)."
  @spec default_require() :: [String.t()]
  def default_require, do: @default_require

  # In-module param-pattern triggers — `{param_key, [matcher, ...]}` per tool.
  # A matcher is `{:effect, kind}` (a semantic risk fact from
  # JidoClaw.Security.ShellCommand.analyze/1), `:structure` (suspicious shell
  # structure, kinds from :suspicious_shell_structure_kinds), `{:cmd, name}` /
  # `{:cmd, name, opts}` (shell-aware command resolution, kept for operator
  # config), or a `%Regex{}` (raw-string fallback). These close the bypass where
  # the general-purpose run_command reaches a gated capability.
  #
  # The six `{:effect, _}` entries are the non-disable-able floor (defaults win
  # on merge in require_patterns/1); `:structure` is narrowed/disabled via
  # :suspicious_shell_structure_kinds. The analyzer's effects are honest semantic
  # facts: `:git_commit`/`:git_push` only for a definitively resolved commit/push
  # (git-resolution uncertainty surfaces as `:opaque`, scope :git),
  # `:git_config_injection` for
  # inline `-c`/`--config-env`/`GIT_CONFIG_*`-env config injection, and
  # `:git_config_persistent_write` for a `git config` write that PLANTS config a
  # later turn honors (an `alias.*`/`include.*` key, a dynamic key, a section
  # rename into `alias`/`include`, or an `edit`/`-e`/`--edit` mutation) — read/
  # removal config forms (`--get`/`get`/`unset`/`remove-section`) are allowed.
  @require_patterns %{
    "run_command" =>
      {:command,
       [
         # git-commit equivalence (the git_commit tool): `git … commit` in any
         # shell dressing — quoting, separators, env/wrapper/path prefixes,
         # aliases, `sh -c`, multiline. `git log && echo commit` stays unmatched.
         {:effect, :git_commit},
         # git-push equivalence: a push publishes to a remote (there is no
         # native git_push tool to require-list, so this pattern is the whole
         # gate). Same honest resolution as commit — only a definitively
         # resolved push matches.
         {:effect, :git_push},
         # git config injection (inline -c include/--config-env, GIT_CONFIG_* env).
         {:effect, :git_config_injection},
         # a persistent `git config` write that plants config for a later turn.
         {:effect, :git_config_persistent_write},
         # crontab equivalence (the schedule_task tool).
         {:effect, :crontab},
         # fail-closed floor: anything unresolved (parse/interpreter/git opacity).
         {:effect, :opaque},
         # Suspicious shell structure: `$()`, backticks, pipe-into-a-shell.
         :structure
       ]}
  }

  @type gate_result :: :ok | {:error, map()}

  @doc """
  Gate `tool_name`/`params` under the enriched tool `context`.

  Scope is read from `context[:tool_context]` (guaranteed nested by
  `JidoClaw.ToolContext.ensure_nested/1` on every path). `opts` override config
  for env-free testing.
  """
  @spec gate(atom() | String.t(), map(), map(), keyword()) :: gate_result()
  def gate(tool_name, params, context, opts \\ []) do
    if enabled?(opts) do
      tool = to_string(tool_name)

      case requirement(tool, params, context, opts) do
        nil -> :ok
        reason -> decide(tool, params, context, reason, opts)
      end
    else
      :ok
    end
  end

  # -- Requirement check --
  #
  # External MCP proxy tools (the `mcp_`-rooted names minted by
  # `JidoClaw.MCP.ProxyGenerator`) resolve against the published per-server
  # approval policy FIRST; everything else falls through to the native
  # require-list / param-pattern logic. The mapping is explicit so internal
  # tags (`:gated`/`:trusted`/`:not_external`) never reach `reason_suffix/1`.

  # `:listed` | `{:pattern, param_key}` | `{:template, name}` | :mcp_external | nil
  defp requirement(tool, params, context, opts) do
    case mcp_requirement(tool, opts) do
      :gated -> :mcp_external
      :trusted -> nil
      :not_external -> native_requirement(tool, params, context, opts)
    end
  end

  # Bypass analysis (feedback_gate_bypass_coverage_sweeps): MCP proxies are
  # in-process `Jido.Action` modules invoked by name through the same wrapper
  # as native tools — there is no shell-equivalent surface (`run_command`
  # cannot reach them), so the exact-name policy is the whole gate.
  #
  # `:gated` | `:trusted` | `:not_external`. Explicit clauses (NOT `&&`/`||`,
  # which would wrongly map a global `false` to `:not_external`): exact policy
  # wins, then an unknown `mcp_`-prefixed name falls back to the global default
  # (never native — a lost/reset policy term fails CLOSED to the global
  # posture), then truly native names route to `native_requirement/4`.
  defp mcp_requirement(tool, opts) do
    case Map.fetch(mcp_policy(opts), tool) do
      {:ok, true} -> :gated
      {:ok, false} -> :trusted
      {:ok, nil} -> global_req(opts)
      :error -> if String.starts_with?(tool, "mcp_"), do: global_req(opts), else: :not_external
    end
  end

  defp global_req(opts), do: global_to_req(opt_or_config(opts, :mcp_require_approval))

  defp global_to_req(false), do: :trusted
  # Default and fail-closed: `true` or any malformed config value ⇒ gated.
  defp global_to_req(_other), do: :gated

  defp mcp_policy(opts) do
    Keyword.get(opts, :mcp_policy) || JidoClaw.MCP.approval_policy()
  end

  # `:listed` | `{:pattern, param_key}` | `{:template, name}` | nil — native
  # require-list, then shell param-patterns, then the calling template's
  # additive `require_approval` overlay. The order keeps reason precision: a
  # `run_command "git commit"` under a template that broadly gates
  # `run_command` still surfaces the more useful `{:pattern, :command}` reason
  # (`||` short-circuits before the template is consulted).
  defp native_requirement(tool, params, context, opts) do
    cond do
      tool in require_list(opts) ->
        :listed

      docker_run_command?(tool, context) ->
        # AR-8b-2 F2 (D2-b): a `run_command` under `sandbox: :docker` skips the
        # whole shell `pattern_match/3` matcher set — the six non-disableable
        # `{:effect, _}` floors (git_commit/git_push/git_config_injection/
        # git_config_persistent_write/crontab/opaque) PLUS the `:structure`
        # matcher — because their *reasons* (host git/crontab/opaque, pipe-to-
        # host-shell) are inapplicable in-container: a `:docker` worker runs in a
        # proven-no-egress, globally-unmounted microVM. The bypass keeps the
        # ADDITIVE policy intact — the operator `require:` list (checked above)
        # and the template overlay (still consulted below) continue to gate. The
        # trust in the bare `sandbox: :docker` stamp is safe by STRUCTURE, not by
        # the stamp alone: `Skills.Steps.AgentRunner.validate_sandbox_scope(:docker)`
        # refuses to launch a `:docker` worker unless its Forge session is a real
        # `:docker_sandbox` backend, so a `:docker` stamp on a ready
        # HostShell/default session never produces a running worker and this
        # bypass therefore never fires against a non-isolated session. Inert in
        # Phase 1 (no `:docker` worker ships); active in Phase 2.
        template_requirement(tool, context)

      true ->
        pattern_match(tool, params, context, opts) || template_requirement(tool, context)
    end
  end

  defp docker_run_command?(tool, context),
    do: tool == "run_command" and sandbox_from(context) == :docker

  # Nil-safe mirror of `template_name/1` — reads the canonical `:sandbox` tier
  # from the nested tool_context; nil on the no-tenant / passthrough path.
  defp sandbox_from(%{tool_context: %{sandbox: s}}), do: s
  defp sandbox_from(_context), do: nil

  # The calling agent's template (set on every spawned/handoff/step
  # tool_context) may gate ADDITIONAL native tools. `template_name/1` is
  # nil-safe on the no-tenant / passthrough `ensure_nested` path (no
  # `:tool_context`) — a nil name means "global floor only", the correct
  # fail-state. `Templates.require_approval/1` returns `[]` for `"main"` and
  # any unknown template, so those never gate here.
  defp template_requirement(tool, context) do
    name = template_name(context)

    cond do
      is_nil(name) -> nil
      gated_by_template?(tool, Templates.require_approval(name)) -> {:template, name}
      true -> nil
    end
  end

  defp template_name(%{tool_context: %{agent_template: name}}) when is_binary(name), do: name
  defp template_name(_context), do: nil

  defp gated_by_template?(_tool, :all), do: true
  defp gated_by_template?(tool, list) when is_list(list), do: tool in list

  defp pattern_match(tool, params, context, opts) do
    configured_pattern_match(tool, params, opts) ||
      mounted_remote_write_match(tool, params, context)
  end

  defp configured_pattern_match(tool, params, opts) do
    case Map.get(require_patterns(opts), tool) do
      {param_key, matchers} when is_list(matchers) ->
        value = param_value(params, param_key)

        if is_binary(value) and matchers_match?(matchers, value, opts),
          do: {:pattern, param_key}

      _ ->
        nil
    end
  end

  # URI matchers alone are insufficient: a workspace may mount a GitHub, S3,
  # or Git filesystem at an arbitrary absolute path (for example `/publish`). Resolve
  # an already-live mount table when available; otherwise inspect config as
  # plain data. Never bootstrap a workspace from the approval gate: configuring
  # a Git mount can itself create/init/commit a repository, which would make the
  # supposedly pre-execution decision path side-effectful.
  defp mounted_remote_write_match(tool, params, context)
       when tool in ["write_file", "edit_file"] do
    path = param_value(params, :path)

    # Deliberate Enum.find shape (NOT `or`): the direct boolean form trips a
    # Dialyzer `pattern_match` failure ("the pattern can never match the type
    # true") — do not "simplify" this back.
    case Enum.find([:uri, :mount], fn
           :uri -> Resolver.remote?(path)
           :mount -> absolute_remote_workspace_mount?(path, context)
         end) do
      nil -> nil
      _remote_kind -> {:pattern, :path}
    end
  end

  defp mounted_remote_write_match(_tool, _params, _context), do: nil

  defp absolute_remote_workspace_mount?(path, context) when is_binary(path) do
    case Path.type(path) do
      :absolute -> remote_workspace_mount?(path, context)
      _relative -> false
    end
  end

  defp absolute_remote_workspace_mount?(_path, _context), do: false

  defp remote_workspace_mount?(path, context) do
    # Classify the path execution will resolve, not the raw param: ShellVFS
    # canonicalizes (Path.expand + duplicate-slash collapse) BEFORE consulting
    # the mount table, so a raw prefix match here would classify
    # `/project/../publish/file` under the local /project mount while the write
    # publishes through the remote /publish mount ungated. First expression so
    # any canonicalization raise stays inside this function's fail-closed
    # rescue/catch, and both the live and config classifications below see the
    # canonical form.
    path = canonicalize_absolute_path(path)
    scope = scope_from(context)
    workspace_id = scope[:workspace_id]
    project_dir = scope[:project_dir]

    if is_binary(workspace_id) and workspace_id != "" do
      live_remote? =
        case MountTable.resolve(workspace_id, path) do
          {:ok, %{adapter: adapter}, _relative_path} -> AdapterPolicy.module_remote?(adapter)
          {:error, :no_mount} -> false
        end

      # OR, not fallback: a mount-table row can outlive its Workspace process.
      # Resolver clears/rebuilds stale rows immediately before the write, so a
      # stale local row must not mask a remote declaration in current config.
      # Deliberate lazy Enum.any? shape (NOT `or`): the direct boolean form
      # trips a Dialyzer `pattern_match` failure — do not "simplify" it back.
      Enum.any?(
        [
          fn -> live_remote? end,
          fn -> configured_remote_mount?(path, project_dir) end
        ],
        fn check -> check.() end
      )
    else
      false
    end

    # Fail closed across the open set of VFS/config faults at this pre-execution
    # security boundary.
  rescue
    # reach:disable-next-line bare_rescue
    _error -> true
  catch
    :exit, _reason -> true
  end

  # Byte-for-byte mirror of `Jido.Shell.VFS.normalize_path/1` (private in the
  # agentjido/jido_shell dep — replicated, not called; upstreaming a public
  # helper is a possible follow-up). The base is the literal "/": ShellVFS uses
  # no cwd, so the gate reproduces its resolution deterministically with no
  # workspace state.
  defp canonicalize_absolute_path(path) do
    path
    |> Path.expand("/")
    |> String.replace(~r{/+}, "/")
  end

  defp configured_remote_mount?(path, project_dir)
       when is_binary(project_dir) and project_dir != "" do
    with {:ok, bytes} <- read_mount_config(project_dir),
         digest <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
         {:ok, mounts} <- MountConfigCache.fetch(project_dir, digest, bytes) do
      mounts
      |> Enum.filter(&configured_remote_entry?/1)
      |> Enum.flat_map(&configured_mount_path/1)
      |> Enum.any?(&path_under_mount?(path, &1))
    else
      :missing -> false
      # Parse/read/cache uncertainty at this security boundary asks for
      # approval; it never treats a possibly-remote mount as local.
      {:error, _reason} -> true
    end
  end

  # A workspace id without a project directory cannot be bootstrapped or
  # statically audited here. Fail closed for its absolute path; a false positive
  # asks an operator, while a false negative could publish externally.
  defp configured_remote_mount?(_path, _project_dir), do: true

  # Read fresh bytes on EVERY decision; only the parse is cached. `head` runs
  # through the bounded process-tree runner so a FIFO swap cannot wedge the
  # approval gate, and reading max+1 bytes distinguishes an oversized file
  # without buffering it. Pre/post lstat rejects non-regular and changed files.
  defp read_mount_config(project_dir) do
    config_path = Path.join([project_dir, ".jido", "config.yaml"])

    case File.lstat(config_path, time: :posix) do
      {:error, :enoent} ->
        :missing

      {:ok, %File.Stat{type: :regular} = before} ->
        with executable when is_binary(executable) <- System.find_executable("head"),
             {bytes, 0} <-
               OsCmd.run(
                 executable,
                 ["-c", Integer.to_string(@mount_config_max_bytes + 1), config_path],
                 cd: project_dir,
                 timeout: @mount_config_read_timeout_ms,
                 max_output_bytes: @mount_config_max_bytes + 1
               ),
             true <- byte_size(bytes) <= @mount_config_max_bytes,
             {:ok, %File.Stat{type: :regular} = after_stat} <-
               File.lstat(config_path, time: :posix),
             true <- stable_config_stat?(before, after_stat) do
          {:ok, bytes}
        else
          _failure -> {:error, :mount_config_unreadable}
        end

      {:ok, _non_regular} ->
        {:error, :mount_config_not_regular}

      {:error, _reason} ->
        {:error, :mount_config_unreadable}
    end
  end

  defp stable_config_stat?(left, right), do: FileStat.stable?(left, right)

  defp configured_remote_entry?(entry) when is_map(entry) do
    entry
    |> MapKeys.coalesce_field("adapter")
    |> AdapterPolicy.config_remote?()
  end

  defp configured_remote_entry?(_entry), do: false

  defp configured_mount_path(entry) when is_map(entry) do
    path = MapKeys.coalesce_field(entry, "path")

    if is_binary(path) and String.starts_with?(path, "/") do
      [normalize_mount_path(path)]
    else
      []
    end
  end

  defp configured_mount_path(_entry), do: []

  defp normalize_mount_path("/"), do: "/"
  defp normalize_mount_path(path), do: String.trim_trailing(path, "/")

  defp path_under_mount?(_path, "/"), do: true

  defp path_under_mount?(path, mount_path),
    do: path == mount_path or String.starts_with?(path, mount_path <> "/")

  # Analyze shell commands once, then test each matcher against the shared
  # analysis. Non-command patterns (for example remote VFS URI regexes) do not
  # need or deserve shell parsing.
  defp matchers_match?(matchers, value, opts) do
    analysis =
      if Enum.any?(matchers, &shell_matcher?/1), do: ShellCommand.analyze(value), else: nil

    Enum.any?(matchers, &matcher_matches?(&1, value, analysis, opts))
  end

  defp shell_matcher?({:effect, _kind}), do: true
  defp shell_matcher?({:cmd, _name}), do: true
  defp shell_matcher?({:cmd, _name, _opts}), do: true
  defp shell_matcher?(:structure), do: true
  defp shell_matcher?(_matcher), do: false

  defp matcher_matches?(%Regex{} = regex, raw, _analysis, _opts), do: Regex.match?(regex, raw)

  defp matcher_matches?({:effect, kind}, _raw, analysis, _opts),
    do: ShellCommand.has_effect?(analysis, kind)

  defp matcher_matches?({:cmd, name}, _raw, analysis, _opts),
    do: ShellCommand.command_present?(analysis, name, [])

  defp matcher_matches?({:cmd, name, cmd_opts}, _raw, analysis, _opts),
    do: ShellCommand.command_present?(analysis, name, cmd_opts)

  defp matcher_matches?(:structure, _raw, analysis, opts) do
    case suspicious_structure_kinds(opts) do
      [] -> false
      kinds -> ShellCommand.structure_present?(analysis, kinds)
    end
  end

  # Normalize atom/string keys so a raw/MCP-path `%{"command" => ...}` can't
  # slip past a configured `:command` trigger.
  defp param_value(params, key) when is_map(params) do
    case Map.get(params, key) do
      nil -> Map.get(params, to_string(key))
      value -> value
    end
  end

  defp param_value(_params, _key), do: nil

  # -- Decision --

  defp decide(tool, params, context, reason, _opts) do
    scope = scope_from(context)

    if is_binary(scope[:tenant_id]) do
      route(ToolApprovals.request(scope, tool, params), tool, reason)
    else
      unavailable_error(
        tool,
        "no tenant scope to record an approval request — a configuration issue, not an approval request"
      )
    end
  end

  defp route({:allowed, _agent_case}, _tool, _reason), do: :ok
  defp route({:pending, agent_case}, tool, reason), do: pending_error(agent_case, tool, reason)
  defp route({:denied, agent_case}, tool, reason), do: denied_error(agent_case, tool, reason)

  defp route({:error, _reason}, tool, _reason_tag) do
    unavailable_error(
      tool,
      "the approval system could not record the request (transient or storage fault)"
    )
  end

  defp scope_from(context) when is_map(context) do
    case Map.get(context, :tool_context) do
      scope when is_map(scope) -> scope
      _ -> %{}
    end
  end

  defp scope_from(_context), do: %{}

  # -- Error envelopes (details limited to %{case_id: id} | %{}) --

  defp pending_error(agent_case, tool, reason) do
    {:error,
     %{
       code: :approval_pending,
       message:
         "The tool `#{tool}` requires operator approval before it can run" <>
           reason_suffix(reason) <>
           ". A pending approval (case #{agent_case.id}) was recorded. Relay this to the user " <>
           "and ask them to approve it with `/gates approve #{agent_case.id}` (REPL) or the " <>
           "Approvals dashboard, then retry the identical call. Do not retry until it is approved.",
       details: %{case_id: agent_case.id}
     }}
  end

  defp denied_error(agent_case, tool, reason) do
    {:error,
     %{
       code: :approval_denied,
       message:
         "The tool `#{tool}` was rejected by the operator" <>
           reason_suffix(reason) <>
           " (case #{agent_case.id}). Do not retry automatically; ask the user how to proceed.",
       details: %{case_id: agent_case.id}
     }}
  end

  defp unavailable_error(tool, why) do
    {:error,
     %{
       code: :approval_unavailable,
       message: "The tool `#{tool}` requires approval but was denied fail-closed: #{why}.",
       details: %{}
     }}
  end

  defp reason_suffix(:listed), do: ""

  defp reason_suffix(:mcp_external),
    do: " (it is an external MCP server tool, gated by default until its server is trusted)"

  defp reason_suffix({:pattern, param_key}),
    do: " (its `#{param_key}` argument matches a guarded-operation pattern)"

  defp reason_suffix({:template, name}),
    do: " (the `#{name}` agent template requires approval for this tool)"

  # -- Config resolution (DestinationPolicy opt_or_config pattern) --

  @doc false
  @spec require_patterns(keyword()) :: map()
  def require_patterns(opts \\ []) do
    # Defaults win on merge: a config entry for a default tool can't weaken it.
    Map.merge(validated_config_patterns(config_patterns(opts)), @require_patterns)
  end

  defp validated_config_patterns(config) when is_map(config) do
    config
    |> Enum.flat_map(fn
      {tool, {param, matchers}}
      when is_binary(tool) and is_atom(param) and is_list(matchers) ->
        if Enum.all?(matchers, &valid_matcher?/1) do
          [{tool, {param, matchers}}]
        else
          warn_skip(tool)
        end

      {tool, _bad} ->
        warn_skip(tool)
    end)
    |> Map.new()
  end

  defp validated_config_patterns(_other), do: %{}

  defp valid_matcher?(%Regex{}), do: true
  # Validate the kind against the analyzer's known effect kinds — an operator
  # `{:effect, :typo}` must be warn-skipped, never accepted-then-silently-inert.
  defp valid_matcher?({:effect, kind}) when is_atom(kind), do: kind in ShellCommand.effect_kinds()
  defp valid_matcher?({:cmd, name}) when is_binary(name), do: true
  defp valid_matcher?({:cmd, name, opts}) when is_binary(name) and is_list(opts), do: true
  defp valid_matcher?(:structure), do: true
  defp valid_matcher?(_other), do: false

  defp warn_skip(tool) do
    Logger.warning("tool approval: ignoring invalid :require_patterns entry for #{inspect(tool)}")
    []
  end

  defp enabled?(opts), do: opt_or_config(opts, :enabled?)
  defp require_list(opts), do: opt_or_config(opts, :require)
  defp config_patterns(opts), do: opt_or_config(opts, :require_patterns) || %{}

  # The kinds the `:structure` matcher gates on. A dedicated config key (not
  # @require_patterns, whose defaults win on merge and so could never be
  # narrowed): a literal `[]` disables structural gating; non-list/all-unknown
  # falls back to the default (a typo must not silently disable a gate); a
  # mixed list keeps its known kinds and warns-and-drops the unknown ones.
  defp suspicious_structure_kinds(opts) do
    opts
    |> opt_or_config(:suspicious_shell_structure_kinds)
    |> normalize_structure_kinds()
  end

  defp normalize_structure_kinds([]), do: []

  defp normalize_structure_kinds(kinds) when is_list(kinds) do
    {known, unknown} = Enum.split_with(kinds, &(&1 in @default_structure_kinds))
    maybe_warn_unknown_kinds(unknown)
    if known == [], do: @default_structure_kinds, else: known
  end

  defp normalize_structure_kinds(other) do
    Logger.warning(
      "tool approval: :suspicious_shell_structure_kinds must be a list of " <>
        "#{inspect(@default_structure_kinds)}, got #{inspect(other)}; using default"
    )

    @default_structure_kinds
  end

  defp maybe_warn_unknown_kinds([]), do: :ok

  defp maybe_warn_unknown_kinds(unknown) do
    Logger.warning(
      "tool approval: ignoring unknown :suspicious_shell_structure_kinds " <>
        "#{inspect(unknown)} (known: #{inspect(@default_structure_kinds)})"
    )
  end

  defp opt_or_config(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        :jido_claw
        |> Application.get_env(:tool_approval, [])
        |> Keyword.get(key, @config_defaults[key])
    end
  end
end
