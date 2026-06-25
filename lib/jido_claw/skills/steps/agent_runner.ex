defmodule JidoClaw.Skills.Steps.AgentRunner do
  @moduledoc """
  Spawn a templated agent, run a task, and capture the result as a
  `%JidoClaw.Workflows.StepResult{}`.

  The shared "spawn → ask → await → record" core for compiled skill steps
  (`JidoClaw.Skills.Steps.AgentStep` and `JidoClaw.Skills.Steps.IterativeStep`),
  ported from the retired `JidoClaw.Workflows.StepAction`. It resolves the
  child agent's scope from the **Reactor context** the
  `JidoClaw.Orchestration.ReactorRunner` seeds (`context[:tenant]` →
  `tenant_id`, `context[:actor]` → `actor`, plus the merged
  `workspace_id`/`project_dir`/`session_*`/`user_id` scope keys), with the same
  precedence/fallback semantics the old driver used.

  Always writes the sub-agent's durable transcript turns
  (`SubagentTranscript.record_task`/`record_terminal`) + a child correlation,
  so any caller running it with real tenant/session UUIDs hits the DB from
  spawned processes — tests that run it need a shared sandbox.
  """

  # A spawned sub-agent's fault must record a terminal `:system` transcript row
  # and surface as `{:error, _}` to the step — never escape and kill the parent.
  # Mirrors the retired StepAction's deliberate never-crash boundary.
  # reach:disable-for-this-file bare_rescue

  alias Jido.AgentServer
  alias JidoClaw.Agent.Templates
  alias JidoClaw.Conversations.SubagentTranscript
  alias JidoClaw.Forge
  alias JidoClaw.Reasoning.Output
  alias JidoClaw.VFS.Sandbox
  alias JidoClaw.Workflows.StepResult

  @step_timeout_ms 180_000

  # The real Forge Docker backend module a `:docker` worker's session MUST be
  # backed by (AR-8b-2 F2 D5). Distinct from the template-policy atom `:docker`.
  @docker_backend JidoClaw.Forge.Sandbox.Docker

  defp agent_server_module do
    Application.get_env(:jido_claw, :step_agent_server, AgentServer)
  end

  defp mcp do
    Application.get_env(:jido_claw, :mcp_facade, JidoClaw.MCP)
  end

  @doc """
  Spawn `template_name`, run `task`, and capture the result.

  `step_name` becomes `StepResult.name` verbatim — the YAML step name, or
  `nil` for an unnamed step (so downstream label rendering falls back to the
  template). `context` is the Reactor context. Returns
  `{:ok, %StepResult{}}` or `{:error, binary()}`.
  """
  @spec run(String.t(), String.t(), String.t() | nil, map()) ::
          {:ok, StepResult.t()} | {:error, binary()}
  def run(template_name, task, step_name, context) do
    with {:ok, template} <- Templates.get(template_name),
         :ok <- validate_sandbox_scope(template, context),
         tag = "wf_#{template_name}_#{:erlang.unique_integer([:positive])}",
         scope = stamp_sandbox(resolve_scope(context, tag), template),
         visibility = Map.get(template, :forward_context, :public),
         scoped = JidoClaw.ToolContext.apply_visibility(scope, visibility),
         # resolve_scope/2 omits :agent_template (build/1 nils it); set it so the
         # per-template approval policy applies to step workers too.
         tool_context =
           Map.put(JidoClaw.ToolContext.build(scoped), :agent_template, template_name),
         {:ok, pid} <- JidoClaw.Jido.start_subagent(template.module, id: tag) do
      # Bounded: register this step template's allowlisted external MCP proxies
      # onto the freshly-spawned worker before its single-shot turn. Best-effort
      # — a `:skipped`/`:partial`/`:timeout` just means a tool-less step (still
      # strictly better than today's zero tools). Blocks only this step's setup.
      _ = mcp().ensure_attached(pid, template_name, 8_000)

      # AR-5: inject the doctrine system prompt onto the freshly-spawned worker
      # before its single-shot turn — the first system prompt step workers receive.
      # Best-effort + gated; never blocks the step.
      _ = JidoClaw.Startup.inject_subagent_prompt(pid, template_name, tool_context)

      case JidoClaw.register_child_correlation(tool_context) do
        {:ok, request_id} ->
          run_registered_step(
            pid,
            request_id,
            task,
            tool_context,
            step_name,
            template_name,
            template.module
          )

        # Marked registration failed (missing scope / durable write, AR-2
        # Phase 2b C4) — the worker has no durable marker row, so stop it and
        # abort rather than run an un-sanitized turn.
        {:error, reason} ->
          if Process.alive?(pid), do: JidoClaw.Jido.stop_agent(pid)
          {:error, "Step #{template_name} correlation failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "Step #{template_name} setup failed: #{inspect(reason)}"}
    end
  end

  # AR-8b: a `sandbox: :prototype` template MUST run against a real, validated
  # `.prototypes/<uuid>/` root — never the `resolve_scope/2` `File.cwd!()`
  # fallback (P1c) and never an inherited real `project_dir` (P2b). Delegate the
  # realpath/shape/symlink check to the single-sourced validator. Fail closed:
  # a missing/non-`.prototypes` `project_dir` aborts setup (the `with`'s `else`
  # maps it to a setup error and no worker starts). A non-sandbox template is
  # untouched.
  defp validate_sandbox_scope(%{sandbox: :prototype}, context) do
    case context[:project_dir] do
      pd when is_binary(pd) and pd != "" -> Sandbox.validate_root(pd)
      _ -> {:error, :sandbox_scope_missing}
    end
  end

  # AR-8b-2 F2 (D5): a `sandbox: :docker` worker shares `:prototype`'s file jail
  # (same validated `.prototypes/<uuid>/` root — without it `resolve_scope`'s
  # `File.cwd!()` fallback would let host file tools hit the real tree) AND
  # requires a READY, REAL Docker-backed Forge session whose default sandbox is
  # already provisioned. Fail closed on any miss. Do NOT re-provision (Phase 2 /
  # D7 Window 2). In Phase 1 no `:docker` worker launches in production, so this
  # clause is exercised only by unit tests.
  defp validate_sandbox_scope(%{sandbox: :docker}, context) do
    with :ok <- validate_proto_root(context[:project_dir]) do
      validate_docker_session(context[:forge_session_key])
    end
  end

  defp validate_sandbox_scope(_template, _context), do: :ok

  defp validate_proto_root(pd) when is_binary(pd) and pd != "", do: Sandbox.validate_root(pd)
  defp validate_proto_root(_), do: {:error, :sandbox_scope_missing}

  # Assert backend identity + *sandbox* readiness, not just session state
  # (review P1/P2). Requiring `sandbox_module == Docker` is what makes Unit B's
  # per-call approval bypass safe — a `:docker` stamp on a non-Docker session can
  # never produce a running worker. Requiring `:default in sandboxes` (not just
  # `state == :ready`) forecloses silent lazy re-provisioning: a *deferred*
  # session can be `state: :ready` with no default sandbox, and a later
  # `Forge.exec` (no `:sandbox` opt) would lazily provision it.
  defp validate_docker_session(forge_key) when is_binary(forge_key) and forge_key != "" do
    case Forge.status(forge_key) do
      {:ok, status} -> validate_docker_status(status)
      {:error, _reason} -> {:error, :docker_session_unavailable}
    end
  end

  defp validate_docker_session(_), do: {:error, :docker_session_missing}

  defp validate_docker_status(%{
         sandbox_module: @docker_backend,
         state: :ready,
         sandbox_status: :ready,
         sandboxes: sandboxes
       }) do
    if :default in sandboxes,
      do: :ok,
      else: {:error, :docker_session_not_provisioned}
  end

  defp validate_docker_status(%{sandbox_module: @docker_backend}),
    do: {:error, :docker_session_not_ready}

  defp validate_docker_status(_status), do: {:error, :docker_session_wrong_backend}

  # Stamp the canonical `:sandbox` key from the TEMPLATE policy (not the launch
  # context), so the capability travels with the worker and can't be dropped by
  # persistence or forgotten by a caller. `ToolContext.build/1` carries it onto
  # the worker (it's a canonical key, never policy-strippable). Every template
  # from `Templates.get/1` is hydrated with a `:sandbox` key, so the single
  # clause never fails.
  defp stamp_sandbox(scope, %{sandbox: s}), do: Map.put(scope, :sandbox, s)

  # The post-correlation step lifecycle: record the task turn, run the step,
  # record its terminal, and (in `after`) stop the worker. A real supervisor
  # stop, not `Process.exit(pid, :normal)` — an exit signal with reason
  # `:normal` sent to another (non-trapping) process is discarded, so that
  # cleanup never actually stopped the worker. Skill-step workers aren't
  # AgentTracker-registered; this is their only stopper.
  defp run_registered_step(pid, request_id, task, tool_context, step_name, template_name, module) do
    SubagentTranscript.record_task(tool_context, request_id, task)

    try do
      result = run_step(module, pid, request_id, task, tool_context, step_name, template_name)
      record_step_terminal(tool_context, request_id, result)
      result
    rescue
      # reach:disable-next-line bare_rescue
      e ->
        msg = Exception.message(e)

        SubagentTranscript.record_terminal(
          tool_context,
          request_id,
          :system,
          "[step crashed] " <> msg
        )

        {:error, "Step #{template_name} crashed: #{msg}"}
    after
      if Process.alive?(pid), do: JidoClaw.Jido.stop_agent(pid)
    end
  end

  # Persist the step's terminal turn (`:assistant` with the extracted step text
  # on success, `:system` on failure) — completing the sub-agent's durable slice
  # so the Compactor sees task → tools → terminal.
  defp record_step_terminal(tool_context, request_id, {:ok, %StepResult{result: text}}) do
    SubagentTranscript.record_terminal(tool_context, request_id, :assistant, text)
  end

  defp record_step_terminal(tool_context, request_id, {:error, reason}) do
    SubagentTranscript.record_terminal(
      tool_context,
      request_id,
      :system,
      SubagentTranscript.failure_text(reason)
    )
  end

  # Async path captures typed output + meta from `state.requests[rid]` by
  # awaiting the full request map. Plain `Jido.Agent` modules without `ask/3`
  # (test stubs) fall back to the synchronous `ask_sync` path, which can't
  # surface meta but preserves existing scope-propagation contracts.
  defp run_step(module, pid, request_id, task, tool_context, step_name, template_name) do
    Code.ensure_loaded(module)

    if function_exported?(module, :ask, 3) do
      run_step_async(module, pid, request_id, task, tool_context, step_name, template_name)
    else
      run_step_sync(module, pid, request_id, task, tool_context, step_name, template_name)
    end
  end

  defp run_step_async(module, pid, request_id, task, tool_context, step_name, template_name) do
    case module.ask(pid, task, request_id: request_id, tool_context: tool_context) do
      {:ok, %{id: ^request_id}} ->
        await_step(pid, request_id, step_name, template_name)

      {:error, reason} ->
        {:error, "Step #{template_name} failed: #{inspect(reason)}"}

      other ->
        {:error, "Step #{template_name} failed: unexpected ask reply: #{inspect(other)}"}
    end
  end

  defp run_step_sync(module, pid, request_id, task, tool_context, step_name, template_name) do
    case module.ask_sync(pid, task,
           timeout: @step_timeout_ms,
           request_id: request_id,
           tool_context: tool_context
         ) do
      {:ok, result} ->
        text = Output.extract_result(result)

        {:ok,
         %StepResult{
           name: step_name,
           template: template_name,
           result: text,
           artifacts: extract_artifacts(text)
         }}

      {:error, reason} ->
        {:error, "Step #{template_name} failed: #{inspect(reason)}"}

      other ->
        {:ok,
         %StepResult{
           name: step_name,
           template: template_name,
           result: inspect(other)
         }}
    end
  end

  defp await_step(pid, request_id, step_name, template_name) do
    case agent_server_module().await_completion(pid,
           timeout: @step_timeout_ms,
           status_path: [:requests, request_id, :status],
           result_path: [:requests, request_id],
           error_path: [:requests, request_id, :error]
         ) do
      {:ok, %{status: :completed, result: request}} when is_map(request) ->
        typed = Output.typed_request_output(request)
        raw_text = Output.extract_result(Output.request_result(request))

        {text, typed_artifacts} =
          case typed do
            %{} = m -> {Output.extract_result(m), typed_artifacts(m)}
            _ -> {raw_text, %{}}
          end

        artifacts =
          Map.merge(extract_artifacts(raw_text), normalize_artifacts(typed_artifacts))

        {:ok,
         %StepResult{
           name: step_name,
           template: template_name,
           result: text,
           typed_output: typed,
           artifacts: artifacts
         }}

      {:ok, %{status: :failed, result: reason}} ->
        {:error, "Step #{template_name} failed: #{inspect(reason)}"}

      {:error, :timeout} ->
        {:error, "Step #{template_name} failed: timeout"}

      {:error, {:timeout, _diag}} ->
        {:error, "Step #{template_name} failed: timeout"}

      {:error, reason} ->
        {:error, "Step #{template_name} failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Append an ARTIFACTS output contract to the task prompt when the step has a
  `produces` block. Without this instruction, agents won't emit the fenced
  block that `extract_artifacts/1` looks for.
  """
  @spec inject_produces_instruction(String.t(), map() | nil) :: String.t()
  def inject_produces_instruction(task, nil), do: task
  def inject_produces_instruction(task, produces) when map_size(produces) == 0, do: task

  def inject_produces_instruction(task, _produces) do
    task <>
      "\n\n" <>
      """
      If you discover runtime details (URLs, ports, generated file paths) that
      differ from the expected configuration, report them:
        - If your final response is a structured JSON object, include them as
          string values in the `artifacts` field (`url`, `port`, `files`).
        - Otherwise, append an ARTIFACTS: key/value block at the end of your
          response:

          ARTIFACTS:
          url: <actual URL>
          port: <actual port>
          files: <comma-separated file paths>
      """
  end

  @doc """
  Extract key-value pairs from a fenced ARTIFACTS: block in agent output.

  Returns an empty map if no block is found.
  """
  @spec extract_artifacts(String.t()) :: map()
  def extract_artifacts(text) when is_binary(text) do
    case Regex.run(~r/ARTIFACTS:\n((?:.+\n?)+)/i, text) do
      [_, block] ->
        block
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
            _ -> acc
          end
        end)

      nil ->
        %{}
    end
  end

  def extract_artifacts(_), do: %{}

  @doc """
  Resolve the canonical `tool_context` scope for a step from the Reactor
  context.

  `tenant_id`/`actor` come from the run-identity keys the runner seeds
  (`context[:tenant]`/`context[:actor]`); the rest of the scope
  (`session_*`/`workspace_*`/`user_id`/`project_dir`) comes from the merged
  `:context` opt. `workspace_id` keeps the legacy per-step `"wf_<tag>"`
  fallback (a deterministic VFS key) and `project_dir` falls back to
  `File.cwd!()`; the Phase 0 UUIDs fall back to `nil`. `agent_id` is always
  the supplied `tag`.
  """
  @spec resolve_scope(map(), String.t()) :: map()
  def resolve_scope(context, tag) do
    %{
      tenant_id: context[:tenant] || context[:tenant_id],
      session_id: context[:session_id],
      session_uuid: context[:session_uuid],
      workspace_id: context[:workspace_id] || "wf_#{tag}",
      workspace_uuid: context[:workspace_uuid],
      user_id: context[:user_id],
      actor: context[:actor],
      project_dir: context[:project_dir] || File.cwd!(),
      agent_id: tag,
      subagent: true,
      # AR-2 Phase 2b: thread the sensitivity marker + TTL ceiling from the
      # reactor context onto the step worker's scope (same builder path as the
      # other canonical keys, set just after at the call site for agent_template).
      sanitize_sensitive_context: context[:sanitize_sensitive_context] || false,
      request_correlation_expires_at: context[:request_correlation_expires_at],
      # AR-8b-2 F2 (D5): thread the Forge session key so a `:docker` worker's
      # `run_command` can route into its session. `ToolContext.build/1` preserves
      # it when non-nil, omits it when nil — so non-docker steps are unchanged.
      forge_session_key: context[:forge_session_key]
    }
  end

  defp typed_artifacts(%{artifacts: artifacts}), do: artifacts
  defp typed_artifacts(%{"artifacts" => artifacts}), do: artifacts
  defp typed_artifacts(_), do: %{}

  defp normalize_artifacts(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), to_string_safe(v)} end)
  end

  defp normalize_artifacts(_), do: %{}

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v) when is_list(v), do: Enum.join(v, ", ")
  defp to_string_safe(v) when is_map(v), do: inspect(v)
  defp to_string_safe(v), do: to_string(v)
end
