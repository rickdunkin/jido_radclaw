defmodule JidoClaw.WorkflowView do
  @moduledoc """
  Tenant-scoped projection of durable workflow-run status.
  """

  require Ash.Query

  alias Ash.Query
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.Visibility
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer.Observe

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
          {:ok, nil} ->
            {:error, :not_found}

          {:ok, run} ->
            view =
              run
              |> run_to_map(DateTime.utc_now())
              |> put_composer(run, tenant_id, actor)

            {:ok, view}

          {:error, _} ->
            {:error, :not_found}
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

  # AR-2 Phase 5 (§10.2): a composer run additively carries a `:composer` key —
  # the seed-free observe view (`Observe.summarize/1`) over the durable event
  # log. The key is ALWAYS a map (with an `available` flag) so an observe-read
  # failure is never silently indistinguishable from "no composer state": an
  # event-read error surfaces `available: false, reason: :observe_unavailable`,
  # a run that has not composed its first wave `available: false, reason:
  # :not_yet_composed`. A non-composer run is unchanged (no `:composer` key).
  defp put_composer(view, %WorkflowRun{workflow_type: "composer", id: id}, tenant_id, actor) do
    composer =
      case WorkflowEvent.for_run(id, tenant: tenant_id, actor: actor) do
        {:ok, events} ->
          case Observe.summarize(events) do
            nil ->
              %{available: false, reason: :not_yet_composed}

            summary ->
              summary
              |> Map.put(:available, true)
              |> put_gate_block(id, tenant_id, actor)
          end

        {:error, _} ->
          %{available: false, reason: :observe_unavailable}
      end

    Map.put(view, :composer, composer)
  end

  defp put_composer(view, _run, _tenant, _actor), do: view

  # Authoritative blocked-on-gate signal: the parent stays `:running` across a
  # child gate pause (§6), so the reliable signal is a child run at
  # `:awaiting_approval`. `held` (lock-held stages, from the route snapshot) and
  # `awaiting_approval` (gate park) are DISTINCT waiting states — both surfaced.
  defp put_gate_block(summary, parent_id, tenant_id, actor) do
    WorkflowRun
    |> Query.filter(parent_run_id == ^parent_id and status == :awaiting_approval)
    |> Ash.read(tenant: tenant_id, actor: actor)
    |> case do
      {:ok, runs} ->
        ids = Enum.map(runs, & &1.id)

        Map.merge(summary, %{
          awaiting_approval_available: true,
          awaiting_approval: ids != [],
          awaiting_child_run_ids: ids
        })

      {:error, _} ->
        # Do NOT collapse a read failure to `awaiting_approval: false` — that is
        # a false negative for the exact gate-block state this surface exposes.
        # Mark the signal untrusted instead (no misleading `awaiting_approval`).
        Map.put(summary, :awaiting_approval_available, false)
    end
  end

  defp scope_keys, do: [:tenant_id, :actor]
end
