defmodule JidoClaw.WorkflowView do
  @moduledoc """
  Tenant-scoped projection of durable workflow-run status.
  """

  require Ash.Query

  alias Ash.Query
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.Visibility
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowRun

  @active_statuses [:pending, :running, :awaiting_approval]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          active_count: non_neg_integer(),
          active_runs: [map()],
          recent_completions: [map()],
          generated_at: DateTime.t()
        }

  defstruct tenant_id: nil,
            active_count: 0,
            active_runs: [],
            recent_completions: [],
            generated_at: nil

  @spec list(map() | keyword()) :: {:ok, t()} | {:error, :tenant_required}
  def list(scope_or_opts) do
    with {:ok, opts} <- JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
      {:ok, build(opts)}
    end
  end

  @spec snapshot(String.t(), map() | keyword()) :: {:ok, map()} | {:error, atom()}
  def snapshot(run_id, scope_or_opts) when is_binary(run_id) do
    case JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
      {:ok, opts} ->
        tenant_id = Keyword.fetch!(opts, :tenant_id)
        actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

        case WorkflowRun.by_id(run_id, tenant: tenant_id, actor: actor) do
          {:ok, nil} -> {:error, :not_found}
          {:ok, run} -> {:ok, run_to_map(run, DateTime.utc_now())}
          {:error, _} -> {:error, :not_found}
        end

      {:error, :tenant_required} ->
        {:error, :tenant_required}
    end
  end

  @spec to_mcp_map(t()) :: map()
  def to_mcp_map(%__MODULE__{} = view) do
    view
    |> Map.from_struct()
    |> JsonSafe.encode()
  end

  defp build(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)
    active_runs = read_runs(tenant_id, actor, @active_statuses, [started_at: :desc], 25)

    completions =
      read_runs(tenant_id, actor, Projection.terminal_statuses(), [completed_at: :desc], 10)

    # One timestamp for the whole view: consistent deadline evidence across
    # every projected run, and it doubles as generated_at.
    now = DateTime.utc_now()

    %__MODULE__{
      tenant_id: tenant_id,
      active_count: length(active_runs),
      active_runs: Enum.map(active_runs, &run_to_map(&1, now)),
      recent_completions: Enum.map(completions, &run_to_map(&1, now)),
      generated_at: now
    }
  end

  defp read_runs(tenant_id, actor, statuses, sort, limit) do
    WorkflowRun
    |> Query.filter(status in ^statuses)
    |> Query.sort(sort)
    |> Query.limit(limit)
    |> Ash.read(tenant: tenant_id, actor: actor)
    |> case do
      {:ok, runs} -> runs
      {:error, _} -> []
    end
  end

  # This is the LLM/MCP surface — permanently operator-scoped (T2-2): payloads
  # are key-filtered/redacted/truncated by `Visibility`, with the `deadline`
  # evidence (T2-1) additively extending the legacy key set. `to_mcp_map`'s
  # JsonSafe.encode handles the evidence DateTimes.
  defp run_to_map(%WorkflowRun{} = run, now), do: Visibility.run_view(run, :operator, now)

  defp scope_keys, do: [:tenant_id, :actor]
end
