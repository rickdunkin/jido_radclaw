defmodule JidoClaw.SwarmView do
  @moduledoc """
  Tenant-scoped projection of child-agent swarm state.

  `AgentTracker` remains a process-global accumulator because the Jido runtime
  registry is process-global. This module is the public read boundary: callers
  must supply `tenant_id`, and optional session/workspace filters are applied
  before any agent ids, statuses, errors, durations, or usage totals leave the
  tracker.
  """

  alias JidoClaw.AgentTracker
  alias JidoClaw.Core.JsonSafe

  @type agent :: %{
          agent_id: String.t(),
          template: String.t() | nil,
          task: String.t() | nil,
          status: atom(),
          request_id: String.t() | nil,
          started_at: integer() | nil,
          finished_at: integer() | nil,
          duration_ms: non_neg_integer() | nil,
          tokens: non_neg_integer(),
          tool_calls: non_neg_integer(),
          tool_names: [String.t()],
          last_tool: String.t() | nil,
          error: String.t() | nil
        }

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          session_id: String.t() | nil,
          session_uuid: String.t() | nil,
          workspace_id: String.t() | nil,
          workspace_uuid: String.t() | nil,
          agents: [agent()],
          running_count: non_neg_integer(),
          done_count: non_neg_integer(),
          error_count: non_neg_integer(),
          total_tokens: non_neg_integer(),
          total_tool_calls: non_neg_integer(),
          generated_at: DateTime.t()
        }

  defstruct tenant_id: nil,
            session_id: nil,
            session_uuid: nil,
            workspace_id: nil,
            workspace_uuid: nil,
            agents: [],
            running_count: 0,
            done_count: 0,
            error_count: 0,
            total_tokens: 0,
            total_tool_calls: 0,
            generated_at: nil

  @doc """
  Return the tenant-scoped child-agent rollup.
  """
  @spec list(map() | keyword()) :: {:ok, t()} | {:error, :tenant_required}
  def list(scope_or_opts) do
    with {:ok, opts} <-
           JidoClaw.RuntimeScope.require_tenant(scope_or_opts, AgentTracker.scope_keys()) do
      {:ok, build(opts)}
    end
  end

  @doc """
  Return a single child-agent projection after proving scoped ownership.
  """
  @spec snapshot(String.t(), map() | keyword()) :: {:ok, agent()} | {:error, atom()}
  def snapshot(agent_id, scope_or_opts) when is_binary(agent_id) do
    case JidoClaw.RuntimeScope.require_tenant(scope_or_opts, AgentTracker.scope_keys()) do
      {:ok, opts} ->
        case tracker().get_agent(agent_id, opts) do
          nil -> {:error, :not_found}
          %{id: "main"} -> {:error, :not_found}
          entry -> {:ok, agent_to_map(entry)}
        end

      {:error, :tenant_required} ->
        {:error, :tenant_required}
    end
  end

  @doc """
  Project a `%SwarmView{}` into a JSON-safe public map.
  """
  @spec to_mcp_map(t()) :: map()
  def to_mcp_map(%__MODULE__{} = view) do
    view
    |> Map.from_struct()
    |> JsonSafe.encode()
  end

  defp build(opts) do
    tracker_state = tracker().get_state(opts)

    agents =
      tracker_state.order
      |> Enum.reject(&(&1 == "main"))
      |> Enum.flat_map(fn id ->
        case Map.get(tracker_state.agents, id) do
          nil -> []
          entry -> [agent_to_map(entry)]
        end
      end)

    %__MODULE__{
      tenant_id: Keyword.fetch!(opts, :tenant_id),
      session_id: Keyword.get(opts, :session_id),
      session_uuid: Keyword.get(opts, :session_uuid),
      workspace_id: Keyword.get(opts, :workspace_id),
      workspace_uuid: Keyword.get(opts, :workspace_uuid),
      agents: agents,
      running_count: Enum.count(agents, &(&1.status == :running)),
      done_count: Enum.count(agents, &(&1.status == :done)),
      error_count: Enum.count(agents, &(&1.status == :error)),
      total_tokens: Enum.reduce(agents, 0, &(&1.tokens + &2)),
      total_tool_calls: Enum.reduce(agents, 0, &(&1.tool_calls + &2)),
      generated_at: DateTime.utc_now()
    }
  end

  defp agent_to_map(entry) do
    %{
      agent_id: entry.id,
      template: entry.template,
      task: entry.task,
      status: entry.status,
      request_id: entry.request_id,
      started_at: entry.started_at,
      finished_at: entry.finished_at,
      duration_ms: duration_ms(entry),
      tokens: entry.tokens || 0,
      tool_calls: entry.tool_calls || 0,
      tool_names: tool_names(entry.tool_names),
      last_tool: entry.last_tool,
      error: entry.error
    }
  end

  defp duration_ms(%{started_at: nil}), do: nil

  defp duration_ms(%{started_at: started_at, finished_at: finished_at}) do
    ended_at = finished_at || System.monotonic_time(:millisecond)
    max(ended_at - started_at, 0)
  end

  defp tool_names(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()
  defp tool_names(list) when is_list(list), do: Enum.sort(list)
  defp tool_names(_), do: []

  defp tracker do
    Application.get_env(:jido_claw, :agent_tracker, AgentTracker)
  end
end
