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

  A call is gated when its tool name is in `require` **or** a param-pattern
  trigger fires. The patterns close the bypass where a general-purpose tool
  reaches a gated capability — e.g. `run_command "git commit ..."` is the shell
  equivalent of the gated `git_commit` tool. The default `run_command`/`command`
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

  alias JidoClaw.Orchestration.ToolApprovals

  # The conservative default require list, single-sourced here so the config
  # sanity sweep validates the SAME list every environment ships (test config
  # only toggles `enabled?`). Operators override via `:tool_approval, :require`.
  @default_require ~w(network_share kill_agent schedule_task unschedule_task git_commit forget replay_workflow)

  @config_defaults [enabled?: true, require: @default_require]

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

      case requirement(tool, params, opts) do
        nil -> :ok
        reason -> decide(tool, params, context, reason, opts)
      end
    else
      :ok
    end
  end

  # -- Requirement check (global config only — no per-template knob in v1) --

  # `:listed` | `{:pattern, param_key}` | nil
  defp requirement(tool, params, opts) do
    if tool in require_list(opts) do
      :listed
    else
      pattern_match(tool, params, opts)
    end
  end

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

  defp reason_suffix({:pattern, param_key}),
    do: " (its `#{param_key}` argument matches a guarded-operation pattern)"

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
