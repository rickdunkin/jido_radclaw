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
  param-pattern → template, so the most specific reason wins. The patterns
  close the bypass where a general-purpose tool reaches a gated capability —
  e.g. `run_command "git commit ..."` is the shell equivalent of the gated
  `git_commit` tool. The default `run_command`/`command`
  patterns match plain `git commit` and option-bearing forms (`git -C repo
  commit`, `git -c user.name=x commit`, `git --git-dir=.git commit`) plus
  `crontab` (the `schedule_task` equivalent). Quoted args with spaces
  (`git -C "my dir" commit`) are out of regex reach — operators wanting full
  shell containment add `run_command` to `require`. False positives merely ask
  for approval, which is acceptable.

  ## Configuration

      config :jido_claw, :tool_approval,
        enabled?: true,
        require: ~w(network_share kill_agent ...)

  `enabled?`/`require`/`require_patterns` resolve via per-call opts first, then
  app config, then the in-module defaults (the DestinationPolicy `opt_or_config`
  pattern), so tests stay env-free. The shell param-patterns live in-module
  (`@require_patterns`); config can **add** patterns for other tools but a typo'd
  config entry can never disable the shipped ones (defaults win on merge, and
  malformed entries are warn-and-skipped).
  """

  require Logger

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Orchestration.ToolApprovals

  # The conservative default require list, single-sourced here so the config
  # sanity sweep validates the SAME list every environment ships (test config
  # only toggles `enabled?`). Operators override via `:tool_approval, :require`.
  @default_require ~w(network_share kill_agent schedule_task unschedule_task git_commit forget replay_workflow)

  @config_defaults [enabled?: true, require: @default_require, mcp_require_approval: true]

  @doc "The shipped default require list (single source of truth)."
  @spec default_require() :: [String.t()]
  def default_require, do: @default_require

  # In-module param-pattern triggers — `{param_key, [regex, ...]}` per tool.
  # Shell equivalents of gated tools reachable through general-purpose tools.
  @require_patterns %{
    "run_command" =>
      {:command,
       [
         # git-commit equivalence: plain `git commit` AND option-bearing forms
         # (`git -C repo commit`, `git -c user.name=x commit`,
         # `git --git-dir=.git commit`). Bare-token interpositions break the
         # chain (`git log && echo commit` stays unmatched).
         ~r/\bgit(?:\s+-{1,2}\S+(?:\s+\S+)?)*\s+commit\b/,
         # crontab equivalence (schedule_task).
         ~r/\bcrontab\b/
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
  # posture), then truly native names route to `native_requirement/3`.
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
    if tool in require_list(opts) do
      :listed
    else
      pattern_match(tool, params, opts) || template_requirement(tool, context)
    end
  end

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

  defp pattern_match(tool, params, opts) do
    case Map.get(require_patterns(opts), tool) do
      {param_key, regexes} when is_list(regexes) ->
        value = param_value(params, param_key)

        if is_binary(value) and Enum.any?(regexes, &Regex.match?(&1, value)) do
          {:pattern, param_key}
        end

      _ ->
        nil
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
      {tool, {param, regexes}}
      when is_binary(tool) and is_atom(param) and is_list(regexes) ->
        if Enum.all?(regexes, &match?(%Regex{}, &1)) do
          [{tool, {param, regexes}}]
        else
          warn_skip(tool)
        end

      {tool, _bad} ->
        warn_skip(tool)
    end)
    |> Map.new()
  end

  defp validated_config_patterns(_other), do: %{}

  defp warn_skip(tool) do
    Logger.warning("tool approval: ignoring invalid :require_patterns entry for #{inspect(tool)}")
    []
  end

  defp enabled?(opts), do: opt_or_config(opts, :enabled?)
  defp require_list(opts), do: opt_or_config(opts, :require)
  defp config_patterns(opts), do: opt_or_config(opts, :require_patterns) || %{}

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
