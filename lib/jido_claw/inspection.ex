defmodule JidoClaw.Inspection do
  @moduledoc """
  Agent-axis introspection. Returns `%JidoClaw.Inspection.Summary{}` for an
  agent, request id, or workflow run.

  Three entry points:

    * `inspect_agent/2` — module, pid, agent id (incl. `"handoff:..."`),
      `%Conversations.Session{}`, or `%{tenant_id, session_id}` map.
    * `inspect_request/2` — request id + tenant.
    * `inspect_workflow/1` — workflow run UUID or `%WorkflowRun{}`.

  None of these raise. Every field extraction is wrapped in a `safe/1`
  helper that turns rescues/exits into `nil`. `{:error, ...}` is reserved
  for unresolvable inputs (e.g. wrong tenant, missing handoff owner,
  bad target shape).
  """

  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Prompt, as: AgentPrompt
  alias JidoClaw.Agent.Templates
  alias JidoClaw.AgentTracker
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Message, as: ConversationsMessage
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Inspection.Summary
  alias JidoClaw.MCPServer
  alias JidoClaw.Memory
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Reasoning.Compactor.Identity, as: CompactionIdentity
  alias JidoClaw.Reasoning.Compactor.Storage, as: CompactorStorage
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Trace
  alias JidoClaw.Trace.Event

  @context_preview_limit 500

  @type inspect_agent_target ::
          module()
          | pid()
          | String.t()
          | ConversationsSession.t()
          | %{tenant_id: String.t(), session_id: String.t()}

  # ---------------------------------------------------------------------------
  # inspect_agent
  # ---------------------------------------------------------------------------

  @spec inspect_agent(inspect_agent_target(), keyword()) ::
          {:ok, Summary.t()} | {:error, term()}
  def inspect_agent(target, opts \\ [])

  def inspect_agent(target, _opts) when is_atom(target) and not is_nil(target) do
    if module_with_strategy_opts?(target) do
      {:ok, module_summary(target)}
    else
      {:error, :unknown_target}
    end
  end

  def inspect_agent(target, opts) when is_pid(target) do
    {:ok, pid_summary(target, opts)}
  end

  def inspect_agent("handoff:" <> rest, opts) when is_binary(rest) do
    case parse_handoff_id(rest) do
      {:ok, session_uuid, template} ->
        resolve_handoff(session_uuid, template, opts)

      :error ->
        {:error, :handoff_not_found}
    end
  end

  def inspect_agent(target, opts) when is_binary(target) do
    {:ok, agent_id_summary(target, opts)}
  end

  def inspect_agent(%ConversationsSession{} = session, opts) do
    {:ok, session_summary(session, opts)}
  end

  def inspect_agent(%{tenant_id: tenant_id, session_id: session_id}, opts)
      when is_binary(tenant_id) and is_binary(session_id) do
    {:ok, session_map_summary(tenant_id, session_id, opts)}
  end

  def inspect_agent(_target, _opts), do: {:error, :unknown_target}

  # ---------------------------------------------------------------------------
  # inspect_request
  # ---------------------------------------------------------------------------

  @spec inspect_request(String.t(), keyword()) :: {:ok, Summary.t()} | {:error, term()}
  def inspect_request(request_id, opts \\ []) when is_binary(request_id) do
    case Keyword.fetch(opts, :tenant_id) do
      {:ok, tenant_id} when is_binary(tenant_id) ->
        do_inspect_request(request_id, tenant_id, opts)

      _ ->
        {:error, :tenant_required}
    end
  end

  defp do_inspect_request(request_id, tenant_id, opts) do
    case Trace.for_request({:request, request_id}, request_id, tenant_id: tenant_id) do
      {:ok, %Trace{} = trace} ->
        case resolve_correlation(request_id, tenant_id) do
          {:ok, session_uuid, agent_id} ->
            actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

            {:ok,
             build_request_summary(trace, request_id, tenant_id, actor, session_uuid, agent_id)}

          {:error, :not_found} ->
            {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp build_request_summary(trace, request_id, tenant_id, actor, session_uuid, agent_id) do
    %Summary{
      request_id: request_id,
      input_kind: :request_id,
      resolved_at_ms: System.system_time(:millisecond),
      model: model_from_trace(trace),
      usage: usage_from_trace(trace),
      duration_ms: duration_from_trace(trace),
      status: trace_field(trace, :status),
      interrupt: latest_interrupt(trace),
      error: latest_error(trace),
      context_preview: context_preview_for_request(session_uuid, request_id, tenant_id, actor),
      user_message: user_message_for_request(session_uuid, request_id, tenant_id, actor),
      compaction: compaction_for(session_uuid, agent_id, tenant_id, actor),
      memory: memory_for(session_uuid, tenant_id)
    }
  end

  # `RequestCorrelation` rows are global (`multitenancy global?: true`), so a
  # bare `lookup/1` finds a row regardless of tenant. We cross-check the
  # row's tenant explicitly to distinguish the three cases:
  #
  #   * matching tenant  → resolve the session UUID (session fields populate)
  #   * different tenant → unresolvable; surface `:not_found` rather than a
  #     summary with silently-nil session fields
  #   * no row           → `{:ok, nil}` (missing correlation; nil session fields)
  defp resolve_correlation(request_id, tenant_id) do
    case lookup_correlation(request_id) do
      %{session_id: uuid, tenant_id: ^tenant_id} = row -> {:ok, uuid, Map.get(row, :agent_id)}
      %{tenant_id: _other} -> {:error, :not_found}
      nil -> {:ok, nil, nil}
    end
  end

  # Deliberately NOT routed through `safe/1`: that helper unwraps `{:ok, _}`
  # and collapses `{:error, _}`/`nil` to a single `nil`, erasing the
  # found-but-wrong-tenant vs. genuinely-missing distinction we need above.
  defp lookup_correlation(request_id) do
    case RequestCorrelation.lookup(request_id) do
      {:ok, row} -> row
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp context_preview_for_request(nil, _request_id, _tenant_id, _actor), do: nil

  defp context_preview_for_request(session_uuid, request_id, tenant_id, actor) do
    safe(fn ->
      case ConversationsMessage.by_request(session_uuid, request_id,
             tenant: tenant_id,
             actor: actor
           ) do
        {:ok, rows} when is_list(rows) ->
          rows
          |> Enum.reverse()
          |> Enum.find(&(&1.role == :assistant))
          |> message_content_preview()

        _ ->
          nil
      end
    end)
  end

  # Sibling of `context_preview_for_request/4`: previews the latest
  # user-role message for the request (the caller's own input) instead
  # of the assistant reply. Same `@context_preview_limit` clamp.
  defp user_message_for_request(nil, _request_id, _tenant_id, _actor), do: nil

  defp user_message_for_request(session_uuid, request_id, tenant_id, actor) do
    safe(fn ->
      case ConversationsMessage.by_request(session_uuid, request_id,
             tenant: tenant_id,
             actor: actor
           ) do
        {:ok, rows} when is_list(rows) ->
          rows
          |> Enum.reverse()
          |> Enum.find(&(&1.role == :user))
          |> message_content_preview()

        _ ->
          nil
      end
    end)
  end

  defp message_content_preview(nil), do: nil
  defp message_content_preview(%{content: nil}), do: nil

  defp message_content_preview(%{content: content}) when is_binary(content) do
    if byte_size(content) <= @context_preview_limit do
      content
    else
      String.slice(content, 0, @context_preview_limit)
    end
  end

  defp message_content_preview(_), do: nil

  # ---------------------------------------------------------------------------
  # inspect_workflow
  # ---------------------------------------------------------------------------

  @spec inspect_workflow(String.t() | WorkflowRun.t()) :: {:ok, Summary.t()} | {:error, term()}
  def inspect_workflow(%WorkflowRun{} = run) do
    {:ok, workflow_summary(run)}
  end

  def inspect_workflow(id) when is_binary(id) do
    case safe(fn -> WorkflowRun.by_id_global(id) end) do
      %WorkflowRun{} = run -> {:ok, workflow_summary(run)}
      _ -> {:error, :not_found}
    end
  end

  defp workflow_summary(run) do
    %Summary{
      input_kind: :workflow_id,
      resolved_at_ms: System.system_time(:millisecond),
      duration_ms: workflow_duration(run),
      error: workflow_error(run),
      workflows: [
        %{id: run.id, name: run.name, status: run.status, started_at: run.started_at}
      ]
    }
  end

  defp workflow_duration(%WorkflowRun{
         started_at: %DateTime{} = started,
         completed_at: %DateTime{} = completed
       }) do
    DateTime.diff(completed, started, :millisecond)
  end

  defp workflow_duration(_), do: nil

  defp workflow_error(%WorkflowRun{error: error}) when is_binary(error),
    do: %{message: error}

  defp workflow_error(_), do: nil

  # ---------------------------------------------------------------------------
  # Module dispatch
  # ---------------------------------------------------------------------------

  defp module_with_strategy_opts?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :strategy_opts, 0)
  end

  defp module_summary(module) do
    tools = safe(fn -> apply(module, :strategy_opts, []) end) |> tools_from_opts()

    %Summary{
      system_prompt: safe(fn -> AgentPrompt.build_snapshot(File.cwd!(), nil) end),
      model: model_from_module(module),
      skills: skills_summary(),
      tool_names: tool_names(tools),
      mcp_tools: mcp_tool_names(),
      input_kind: :module,
      resolved_at_ms: System.system_time(:millisecond)
    }
  end

  defp tools_from_opts(opts) when is_list(opts), do: Keyword.get(opts, :tools, [])
  defp tools_from_opts(_), do: []

  # The configured model alias (e.g. `:fast`) declared in the agent
  # module's `strategy_opts`. Definition/agent paths report this alias;
  # the request path reports the resolved label that actually ran
  # (see `model_from_trace/1`).
  defp model_from_module(module) when is_atom(module) and not is_nil(module) do
    if module_with_strategy_opts?(module) do
      safe(fn -> apply(module, :strategy_opts, []) end)
      |> model_from_opts()
      |> normalize_model_label()
    else
      nil
    end
  end

  defp model_from_module(_), do: nil

  defp model_from_opts(opts) when is_list(opts), do: Keyword.get(opts, :model)
  defp model_from_opts(_), do: nil

  # Guarantees the `Summary.model` contract (`String.t() | atom() | nil`). A
  # model value can arrive as a structured term — a `{provider, opts}` tuple
  # or inline map in config, or a `%LLMDB.Model{}`/map in trace metadata
  # (which becomes a plain string-keyed map after a Postgres round-trip).
  # Such a value would otherwise reach `to_string/1` in
  # `JidoClaw.Tools.InspectAgent.project/1` and raise. Collapse anything that
  # isn't a binary or a non-nil atom to `nil` so callers fall back to a
  # string label (e.g. `event.name`) or `nil`. Deliberately does NOT route
  # through `Jido.AI.model_label/1`: that raises `ArgumentError` on an
  # unregistered atom alias, and the request path is a non-`safe/1` caller.
  defp normalize_model_label(value) when is_binary(value), do: value
  defp normalize_model_label(value) when is_atom(value) and not is_nil(value), do: value
  defp normalize_model_label(_), do: nil

  defp tool_names(tools) when is_list(tools) do
    Enum.map(tools, fn module ->
      if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) do
        to_string(apply(module, :name, []))
      else
        to_string(module)
      end
    end)
  end

  defp tool_names(_), do: []

  defp skills_summary do
    case safe(fn -> JidoClaw.Skills.all() end) do
      list when is_list(list) ->
        Enum.map(list, fn s ->
          %{
            name: Map.get(s, :name),
            description: Map.get(s, :description),
            version: Map.get(s, :max_iterations)
          }
        end)

      _ ->
        []
    end
  end

  defp mcp_tool_names do
    case safe(fn -> MCPServer.__publish__() end) do
      %{tools: tools} when is_list(tools) ->
        tool_names(tools)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # PID dispatch
  # ---------------------------------------------------------------------------

  defp safe_agent_state(pid) do
    case Jido.AgentServer.state(pid) do
      {:ok, state} -> state
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp agent_state_agent_id(%{agent: %{id: id}}) when is_binary(id), do: id
  defp agent_state_agent_id(_), do: nil

  defp agent_state_module(%{agent_module: module}) when is_atom(module) and not is_nil(module),
    do: module

  defp agent_state_module(_), do: nil

  defp agent_state_request_id(%{agent: %{state: %{last_request_id: rid}}}) when is_binary(rid),
    do: rid

  defp agent_state_request_id(_), do: nil

  defp agent_state_model(%{agent: %{state: %{model: model}}}), do: normalize_model_label(model)
  defp agent_state_model(_), do: nil

  defp pid_summary(pid, opts) do
    state = safe_agent_state(pid)
    agent_id = agent_state_agent_id(state)
    module = agent_state_module(state)
    trace = fetch_trace(agent_id, Keyword.get(opts, :tenant_id))

    %Summary{
      input_kind: :pid,
      resolved_at_ms: System.system_time(:millisecond),
      request_id: agent_state_request_id(state) || trace_field(trace, :request_id),
      system_prompt: safe(fn -> AgentPrompt.build_snapshot(File.cwd!(), nil) end),
      model: agent_state_model(state) || model_from_module(module),
      tool_names: tool_names_for_module(module),
      mcp_tools: mcp_tool_names(),
      skills: skills_summary(),
      usage: usage_from(nil, trace),
      duration_ms: duration_from_trace(trace),
      status: trace_field(trace, :status),
      interrupt: latest_interrupt(trace),
      error: latest_error(trace),
      subagents: child_subagents(),
      workflows: active_workflows(Keyword.get(opts, :tenant_id))
    }
  end

  # ---------------------------------------------------------------------------
  # Handoff agent-id dispatch
  # ---------------------------------------------------------------------------

  defp parse_handoff_id(rest) do
    case String.split(rest, ":", parts: 2) do
      [session_uuid, template] when session_uuid != "" and template != "" ->
        {:ok, session_uuid, template}

      _ ->
        :error
    end
  end

  defp resolve_handoff(session_uuid, template, opts) do
    case Keyword.fetch(opts, :tenant_id) do
      {:ok, tenant_id} when is_binary(tenant_id) ->
        actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

        with {:ok, session} <- load_session(session_uuid, tenant_id, actor),
             owner when not is_nil(owner) <-
               safe(fn -> HandoffRegistry.owner(tenant_id, session.external_id) end),
             true <- owner.template == template do
          {:ok,
           handoff_session_summary(session, owner, tenant_id, actor) |> with_input_kind(:agent_id)}
        else
          _ -> {:error, :handoff_not_found}
        end

      _ ->
        {:error, :tenant_required}
    end
  end

  defp load_session(session_uuid, tenant_id, actor) do
    case safe(fn -> ConversationsSession.by_id(session_uuid, tenant: tenant_id, actor: actor) end) do
      %ConversationsSession{} = session -> {:ok, session}
      _ -> :error
    end
  end

  defp with_input_kind(%Summary{} = s, kind), do: %{s | input_kind: kind}

  # ---------------------------------------------------------------------------
  # Agent-id (non-handoff) dispatch
  # ---------------------------------------------------------------------------

  defp agent_id_summary(agent_id, opts) when is_binary(agent_id) do
    tracker = safe(fn -> AgentTracker.get_agent(agent_id) end)
    trace = fetch_trace(agent_id, Keyword.get(opts, :tenant_id))
    module = module_from_tracker(tracker)

    %Summary{
      input_kind: :agent_id,
      resolved_at_ms: System.system_time(:millisecond),
      tool_names: tool_names_for_module(module),
      model: model_from_module(module),
      mcp_tools: mcp_tool_names(),
      skills: skills_summary(),
      system_prompt: safe(fn -> AgentPrompt.build_snapshot(File.cwd!(), nil) end),
      usage: usage_from(tracker, trace),
      duration_ms: duration_from_trace(trace),
      status: trace_field(trace, :status),
      interrupt: latest_interrupt(trace),
      error: latest_error(trace),
      subagents: child_subagents(),
      workflows: active_workflows(Keyword.get(opts, :tenant_id)),
      request_id: tracker_request_id(tracker, trace)
    }
  end

  defp tracker_request_id(%{request_id: rid}, _trace) when is_binary(rid), do: rid
  defp tracker_request_id(_, %Trace{request_id: rid}) when is_binary(rid), do: rid
  defp tracker_request_id(_, _), do: nil

  # `AgentEntry` carries only `:template` (no `:module`), so resolve the
  # worker module through the template registry. No tracker entry / unknown
  # template / "main" (the registry has no "main" key) all fall back to the
  # main `JidoClaw.Agent`, so e.g. `inspect_agent("main")` returns its tools.
  defp module_from_tracker(%{template: template}) when is_binary(template) do
    case Templates.get(template) do
      {:ok, %{module: module}} when is_atom(module) -> module
      _ -> JidoClaw.Agent
    end
  end

  defp module_from_tracker(_), do: JidoClaw.Agent

  # ---------------------------------------------------------------------------
  # Session dispatch
  # ---------------------------------------------------------------------------

  defp session_summary(%ConversationsSession{} = session, opts) do
    tenant_id = session.tenant_id
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)
    owner = safe(fn -> HandoffRegistry.owner(tenant_id, session.external_id) end)

    base =
      if is_map(owner) do
        handoff_session_summary(session, owner, tenant_id, actor)
      else
        plain_session_summary(session, tenant_id, actor)
      end

    %{base | input_kind: :session}
  end

  defp session_map_summary(tenant_id, session_id, _opts) do
    owner = safe(fn -> HandoffRegistry.owner(tenant_id, session_id) end)
    module = if is_map(owner), do: owner.module, else: JidoClaw.Agent

    %Summary{
      input_kind: :session,
      resolved_at_ms: System.system_time(:millisecond),
      tool_names: tool_names_for_module(module),
      model: model_from_module(module),
      mcp_tools: mcp_tool_names(),
      skills: skills_summary(),
      handoffs: handoff_view(owner),
      message_count: safe_worker_message_count(tenant_id, session_id),
      subagents: child_subagents(),
      workflows: active_workflows(tenant_id)
    }
  end

  defp handoff_session_summary(session, owner, tenant_id, actor) do
    module = owner.module
    trace_id = "handoff:#{session.id}:#{owner.template}"
    trace = fetch_trace(trace_id, tenant_id)

    %Summary{
      input_kind: :session,
      resolved_at_ms: System.system_time(:millisecond),
      system_prompt: safe(fn -> session_prompt(session) end),
      model: model_from_module(module),
      skills: skills_summary(),
      tool_names: tool_names_for_module(module),
      mcp_tools: mcp_tool_names(),
      handoffs: handoff_view(owner),
      compaction: compaction_for(session.id, trace_id, tenant_id, actor),
      memory: memory_for(session.id, tenant_id),
      message_count: safe_worker_message_count(tenant_id, session.external_id),
      usage: usage_from(nil, trace),
      duration_ms: duration_from_trace(trace),
      status: trace_field(trace, :status),
      interrupt: latest_interrupt(trace),
      error: latest_error(trace),
      subagents: child_subagents(),
      workflows: active_workflows(tenant_id, actor),
      request_id: trace_field(trace, :request_id)
    }
  end

  defp plain_session_summary(session, tenant_id, actor) do
    trace = fetch_trace(session.external_id, tenant_id)

    %Summary{
      input_kind: :session,
      resolved_at_ms: System.system_time(:millisecond),
      system_prompt: safe(fn -> session_prompt(session) end),
      model: model_from_module(JidoClaw.Agent),
      skills: skills_summary(),
      tool_names: tool_names_for_module(JidoClaw.Agent),
      mcp_tools: mcp_tool_names(),
      # Plain (no-handoff) session → the main agent's slice.
      compaction: compaction_for(session.id, CompactionIdentity.main(), tenant_id, actor),
      memory: memory_for(session.id, tenant_id),
      message_count: safe_worker_message_count(tenant_id, session.external_id),
      usage: usage_from(nil, trace),
      duration_ms: duration_from_trace(trace),
      status: trace_field(trace, :status),
      interrupt: latest_interrupt(trace),
      error: latest_error(trace),
      subagents: child_subagents(),
      workflows: active_workflows(tenant_id, actor),
      request_id: trace_field(trace, :request_id)
    }
  end

  defp session_prompt(%ConversationsSession{metadata: %{"prompt_snapshot" => snap}})
       when is_binary(snap) do
    snap
  end

  defp session_prompt(_session) do
    AgentPrompt.build_snapshot(File.cwd!(), nil)
  end

  defp tool_names_for_module(nil), do: []

  defp tool_names_for_module(module) when is_atom(module) do
    if module_with_strategy_opts?(module) do
      safe(fn -> apply(module, :strategy_opts, []) end) |> tools_from_opts() |> tool_names()
    else
      []
    end
  end

  defp tool_names_for_module(_), do: []

  defp handoff_view(%{template: template} = owner) do
    %{
      template: template,
      from_template: Map.get(owner.handoff, :from_template),
      message: Map.get(owner.handoff, :message),
      updated_at_ms: Map.get(owner, :updated_at_ms)
    }
  end

  defp handoff_view(_), do: nil

  defp safe_worker_message_count(tenant_id, session_id) do
    case safe(fn -> SessionWorker.get_info(tenant_id, session_id) end) do
      %{message_count: count} when is_integer(count) -> count
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Trace and tracker helpers
  # ---------------------------------------------------------------------------

  defp fetch_trace(nil, _tenant_id), do: nil
  defp fetch_trace(_target, nil), do: nil

  defp fetch_trace(target, tenant_id) do
    case safe(fn -> Trace.latest(target, tenant_id: tenant_id) end) do
      %Trace{} = trace -> trace
      _ -> nil
    end
  end

  defp trace_field(nil, _key), do: nil
  defp trace_field(%Trace{} = trace, key), do: Map.get(trace, key)

  defp usage_from_trace(%Trace{events: events}) do
    Enum.reduce(events, %{input_tokens: 0, output_tokens: 0, cost: nil}, fn event, acc ->
      if event.category == :model do
        m = event.measurements || %{}

        %{
          acc
          | input_tokens: acc.input_tokens + (MapKeys.coalesce_field(m, :input_tokens) || 0),
            output_tokens: acc.output_tokens + (MapKeys.coalesce_field(m, :output_tokens) || 0)
        }
      else
        acc
      end
    end)
  end

  defp usage_from_trace(_), do: %{input_tokens: 0, output_tokens: 0, cost: nil}

  # The resolved model label that actually ran, taken from the latest
  # `:model`-category event (a request may make multiple LLM calls /
  # future per-turn routing, so the last one wins). Reads `coalesce_field`
  # — like `usage_from_trace/1` — because durable-rehydrated metadata comes
  # back string-keyed; falls back to `event.name`, where the collector
  # already stores the model label for `:model` events.
  defp model_from_trace(%Trace{events: events}) when is_list(events) do
    case events |> Enum.reverse() |> Enum.find(&(&1.category == :model)) do
      %Event{} = ev ->
        normalize_model_label(MapKeys.coalesce_field(ev.metadata || %{}, :model)) || ev.name

      _ ->
        nil
    end
  end

  defp usage_from(%{tokens: tokens}, nil) when is_integer(tokens) and tokens > 0 do
    %{input_tokens: 0, output_tokens: tokens, cost: nil}
  end

  defp usage_from(_, trace), do: usage_from_trace(trace)

  defp duration_from_trace(%Trace{started_at_ms: s, completed_at_ms: c})
       when is_integer(s) and is_integer(c) and c >= s,
       do: c - s

  defp duration_from_trace(_), do: nil

  defp latest_interrupt(%Trace{events: events}) do
    case events |> Enum.reverse() |> Enum.find(&(&1.status == :interrupted)) do
      nil -> nil
      %Event{} = ev -> %{event: ev.event, category: ev.category, at_ms: ev.at_ms}
    end
  end

  defp latest_interrupt(_), do: nil

  defp latest_error(%Trace{events: events}) do
    case events |> Enum.reverse() |> Enum.find(&(&1.status == :failed)) do
      nil ->
        nil

      %Event{} = ev ->
        meta = ev.metadata || %{}
        %{message: error_message(meta, ev), details: meta, at_ms: ev.at_ms}
    end
  end

  defp latest_error(_), do: nil

  defp error_message(meta, ev) do
    error = MapKeys.coalesce_field(meta, :error)
    message = MapKeys.coalesce_field(meta, :message)

    cond do
      is_binary(error) -> error
      is_binary(message) -> message
      is_binary(ev.name) -> ev.name
      true -> to_string(ev.event)
    end
  end

  defp child_subagents do
    case safe(fn -> AgentTracker.get_state() end) do
      %{agents: agents} when is_map(agents) ->
        agents
        |> Enum.reject(fn {id, _} -> id == "main" end)
        |> Enum.map(fn {id, entry} ->
          %{
            id: id,
            status: Map.get(entry, :status),
            template: Map.get(entry, :template),
            last_tool: Map.get(entry, :last_tool)
          }
        end)

      _ ->
        []
    end
  end

  # `WorkflowRun` is tenant-required (`global? false` + the standard read
  # policy), so the listing must be scoped. A binary tenant derives a system
  # actor when none is threaded in; genuinely tenant-less inspection paths
  # (a bare pid, or a map input with no `:tenant_id`) can't scope the read,
  # so they stay empty (best-effort, like the other safe/1 fields).
  defp active_workflows(tenant_id, actor \\ nil)

  defp active_workflows(tenant_id, actor) when is_binary(tenant_id) do
    actor = actor || Actor.system(tenant_id)

    case safe(fn -> WorkflowRun.list_active(tenant: tenant_id, actor: actor) end) do
      runs when is_list(runs) -> Enum.map(runs, &workflow_entry/1)
      _ -> []
    end
  end

  defp active_workflows(_tenant_id, _actor), do: []

  defp workflow_entry(run) do
    %{
      id: run.id,
      name: run.name,
      status: run.status,
      started_at: run.started_at
    }
  end

  # `:memory` is sourced from `Memory.namespace_info/1`, which resolves the
  # scope strictly from `tenant_id` + `session_uuid`. The map-input dispatch
  # (`session_map_summary/3`) has no session UUID, so `:memory` stays `nil`
  # there — parallel to `compaction`.
  defp memory_for(nil, _tenant_id), do: nil
  defp memory_for(_session_uuid, nil), do: nil

  defp memory_for(session_uuid, tenant_id),
    do: safe(fn -> Memory.namespace_info(%{tenant_id: tenant_id, session_uuid: session_uuid}) end)

  defp compaction_for(nil, _agent_id, _tenant_id, _actor), do: nil

  defp compaction_for(session_uuid, agent_id, tenant_id, actor) do
    # Key the snapshot read by the inspected agent's compaction identity,
    # run through the shared helper so a raw runtime session id normalizes to
    # `"main"`. Falls back to the main agent when no identity is in scope.
    identity =
      CompactionIdentity.resolve(nil, agent_id, session_uuid) || CompactionIdentity.main()

    key = "#{identity}::default"

    case safe(fn ->
           CompactorStorage.latest(session_uuid, tenant: tenant_id, actor: actor, key: key)
         end) do
      nil -> nil
      %_{} = snap -> Map.from_struct(snap)
      other when is_map(other) -> other
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # `safe/1` — turn any raise/exit into `nil`. `{:ok, v} -> v` and bare values
  # pass through unchanged so callers don't have to unwrap each time.
  # ---------------------------------------------------------------------------

  defp safe(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, value} -> value
      {:error, _} -> nil
      other -> other
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
