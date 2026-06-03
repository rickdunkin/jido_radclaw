defmodule JidoClaw.WorkflowView do
  @moduledoc """
  Tenant-scoped projection of durable workflow-run status.
  """

  require Ash.Query

  alias Ash.Query
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.WorkflowRun

  @active_statuses [:pending, :running, :awaiting_approval]
  @terminal_statuses [:completed, :failed, :cancelled]

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
          {:ok, run} -> {:ok, run_to_map(run)}
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
    completions = read_runs(tenant_id, actor, @terminal_statuses, [completed_at: :desc], 10)

    %__MODULE__{
      tenant_id: tenant_id,
      active_count: length(active_runs),
      active_runs: Enum.map(active_runs, &run_to_map/1),
      recent_completions: Enum.map(completions, &run_to_map/1),
      generated_at: DateTime.utc_now()
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

  defp run_to_map(%WorkflowRun{} = run) do
    %{
      run_id: run.id,
      name: run.name,
      workflow_type: run.workflow_type,
      status: run.status,
      started_at: run.started_at,
      completed_at: run.completed_at,
      duration_ms: duration_ms(run.started_at, run.completed_at),
      error: run.error,
      result_summary: result_summary(run.result)
    }
  end

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = completed_at) do
    DateTime.diff(completed_at, started_at, :millisecond)
  end

  defp duration_ms(%DateTime{} = started_at, nil) do
    DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
  end

  defp duration_ms(_, _), do: nil

  defp result_summary(nil), do: nil
  defp result_summary(value) when is_binary(value), do: String.slice(value, 0, 200)

  defp result_summary(%{} = value) do
    value
    |> Map.take([:summary, "summary", :status, "status", :message, "message"])
    |> case do
      empty when map_size(empty) == 0 -> nil
      summary -> summary
    end
  end

  defp result_summary(_), do: nil

  defp scope_keys, do: [:tenant_id, :actor]
end
