defmodule JidoClaw.RuntimeOverview do
  @moduledoc """
  Dashboard-level runtime projection composed from the tenant-scoped views.
  """

  alias JidoClaw.ForgeView
  alias JidoClaw.SwarmView
  alias JidoClaw.WorkflowView

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          session_count: non_neg_integer(),
          swarm: SwarmView.t(),
          forge: ForgeView.t(),
          workflows: WorkflowView.t(),
          uptime: map(),
          generated_at: DateTime.t()
        }

  defstruct tenant_id: nil,
            session_count: 0,
            swarm: nil,
            forge: nil,
            workflows: nil,
            uptime: %{},
            generated_at: nil

  @spec snapshot(map() | keyword()) :: {:ok, t()} | {:error, :tenant_required}
  def snapshot(scope_or_opts) do
    scope = normalize_scope(scope_or_opts)

    case Map.get(scope, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" ->
        swarm = view_or_empty(SwarmView, scope)

        {:ok,
         %__MODULE__{
           tenant_id: tenant_id,
           session_count: session_count(tenant_id),
           swarm: swarm,
           forge: view_or_empty(ForgeView, scope),
           workflows: view_or_empty(WorkflowView, scope),
           uptime: uptime(length(swarm.agents)),
           generated_at: DateTime.utc_now()
         }}

      _ ->
        {:error, :tenant_required}
    end
  end

  defp view_or_empty(module, scope) do
    case module.list(scope) do
      {:ok, view} -> view
      {:error, _} -> empty(module, scope)
    end
  end

  defp empty(SwarmView, scope),
    do: %SwarmView{tenant_id: scope.tenant_id, generated_at: DateTime.utc_now()}

  defp empty(ForgeView, scope),
    do: %ForgeView{tenant_id: scope.tenant_id, generated_at: DateTime.utc_now()}

  defp empty(WorkflowView, scope),
    do: %WorkflowView{tenant_id: scope.tenant_id, generated_at: DateTime.utc_now()}

  defp session_count(tenant_id) do
    tenant_id
    |> JidoClaw.Session.Supervisor.list_sessions()
    |> length()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # `seconds` is legitimately process-wide (BEAM uptime). The agent count is
  # sourced from the per-scope `%SwarmView{}` built in `snapshot/1` — not the
  # global `Stats.agents_spawned` counter — so a tenant's overview never
  # reflects another tenant's agents.
  defp uptime(scoped_agent_count) do
    stats = JidoClaw.Stats.get()

    %{
      seconds: Map.get(stats, :uptime_seconds, 0),
      agents_spawned: scoped_agent_count
    }
  rescue
    _ -> %{seconds: 0, agents_spawned: scoped_agent_count}
  catch
    :exit, _ -> %{seconds: 0, agents_spawned: scoped_agent_count}
  end

  defp normalize_scope(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_scope(%{} = map), do: map
end
