defmodule JidoClaw.ForgeView do
  @moduledoc """
  Tenant-scoped projection of Forge session lifecycle state.
  """

  require Ash.Query

  alias Ash.Query
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Forge.Manager
  alias JidoClaw.Forge.Resources.Session

  @active_phases [
    :created,
    :provisioning,
    :bootstrapping,
    :ready,
    :running,
    :needs_input,
    :resuming
  ]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          workspace_id: String.t() | nil,
          active_count: non_neg_integer(),
          sessions: [map()],
          generated_at: DateTime.t()
        }

  defstruct tenant_id: nil,
            workspace_id: nil,
            active_count: 0,
            sessions: [],
            generated_at: nil

  @spec list(map() | keyword()) :: {:ok, t()} | {:error, :tenant_required}
  def list(scope_or_opts) do
    with {:ok, opts} <- JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
      {:ok, build(opts)}
    end
  end

  @spec snapshot(String.t(), map() | keyword()) :: {:ok, map()} | {:error, atom()}
  def snapshot(session_id, scope_or_opts) when is_binary(session_id) do
    case JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
      {:ok, opts} ->
        tenant_id = Keyword.fetch!(opts, :tenant_id)
        workspace_id = Keyword.get(opts, :workspace_id)
        actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

        case Session.by_name(session_id, tenant: tenant_id, actor: actor) do
          {:ok, %Session{} = session} ->
            if workspace_match?(session, workspace_id),
              do: {:ok, session_to_map(session, live_ids())},
              else: {:error, :not_found}

          {:ok, nil} ->
            {:error, :not_found}

          {:error, _} ->
            {:error, :not_found}
        end

      {:error, :tenant_required} ->
        {:error, :tenant_required}
    end
  end

  # Mirrors `build/1`'s nil/non-nil workspace semantics: a nil scope key
  # matches any session; a non-nil key must equal the row's `workspace_id`.
  defp workspace_match?(_session, nil), do: true
  defp workspace_match?(%Session{workspace_id: ws}, ws), do: true
  defp workspace_match?(_session, _workspace_id), do: false

  @spec to_mcp_map(t()) :: map()
  def to_mcp_map(%__MODULE__{} = view) do
    view
    |> Map.from_struct()
    |> JsonSafe.encode()
  end

  defp build(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    workspace_id = Keyword.get(opts, :workspace_id)
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)
    live = live_ids()

    sessions =
      case read_active_sessions(tenant_id, workspace_id, actor) do
        {:ok, rows} -> Enum.map(rows, &session_to_map(&1, live))
        {:error, _} -> []
      end

    %__MODULE__{
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      active_count: length(sessions),
      sessions: sessions,
      generated_at: DateTime.utc_now()
    }
  end

  defp read_active_sessions(tenant_id, nil, actor) do
    Session
    |> Query.filter(phase in ^@active_phases)
    |> Query.sort(last_activity_at: :desc, started_at: :desc)
    |> Ash.read(tenant: tenant_id, actor: actor)
  end

  defp read_active_sessions(tenant_id, workspace_id, actor) do
    Session
    |> Query.filter(phase in ^@active_phases and workspace_id == ^workspace_id)
    |> Query.sort(last_activity_at: :desc, started_at: :desc)
    |> Ash.read(tenant: tenant_id, actor: actor)
  end

  defp session_to_map(%Session{} = session, live) do
    %{
      session_id: session.name,
      workspace_id: session.workspace_id,
      phase: session.phase,
      runner_type: session.runner_type,
      sandbox_id: session.sandbox_id,
      execution_count: session.execution_count || 0,
      last_activity_at: session.last_activity_at,
      started_at: session.started_at,
      completed_at: session.completed_at,
      last_error: session.last_error,
      live?: MapSet.member?(live, session.name)
    }
  end

  defp live_ids do
    MapSet.new(Manager.list_sessions())
  rescue
    # Read-only projection: a Manager GenServer hiccup must not crash the
    # ForgeView assembly. Paired with `catch :exit, _` for non-existent
    # Manager process (e.g. during early boot or tests).
    # reach:disable-next-line bare_rescue
    _ -> MapSet.new()
  catch
    :exit, _ -> MapSet.new()
  end

  defp scope_keys, do: [:tenant_id, :workspace_id, :actor]
end
