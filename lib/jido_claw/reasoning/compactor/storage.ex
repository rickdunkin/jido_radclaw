defmodule JidoClaw.Reasoning.Compactor.Storage do
  @moduledoc """
  Tenant-aware persistence for compaction snapshots.

  Wraps `JidoClaw.Conversations.Session.set_compaction_snapshot/2` and
  `JidoClaw.Conversations.Session.by_id/2`. Always uses the tenant-scoped
  `by_id` action (never `by_id_global`) — this is a public Compactor path
  and bypassing the tenant policy would leak across tenants.

  Errors flow through `JidoClaw.Error.Normalize.compaction_error/2` so
  callers receive a typed `%JidoClaw.Error.*{}` exception.
  """

  alias JidoClaw.Conversations.Session, as: SessionResource
  alias JidoClaw.Error.Normalize
  alias JidoClaw.Reasoning.Compactor.Snapshot

  @type opts :: [tenant: String.t(), actor: term() | nil, key: String.t()]

  @doc """
  Persist a `%Snapshot{}` for the given session under `opts[:key]` (the
  per-agent compaction key, e.g. `"main::default"`).

  Returns `{:ok, %Snapshot{}}` (passing through the same snapshot you gave
  it) or `{:error, %JidoClaw.Error.*{}}`.
  """
  @spec persist(String.t(), Snapshot.t(), opts(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Exception.t()}
  def persist(session_uuid, %Snapshot{} = snapshot, opts, _extra \\ [])
      when is_binary(session_uuid) and is_list(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.get(opts, :actor)
    key = Keyword.fetch!(opts, :key)

    with {:ok, session} <- load_session(session_uuid, tenant, actor) do
      jsonb = Snapshot.to_jsonb(snapshot)
      do_persist(session, key, jsonb, tenant, actor, session_uuid, snapshot)
    end
  end

  @doc """
  Read the latest persisted snapshot for the given session under
  `opts[:key]`.

  Returns `{:ok, %Snapshot{} | nil}` on success (nil when no snapshot is
  stored under that key) or `{:error, %JidoClaw.Error.*{}}`.
  """
  @spec latest(String.t(), opts()) :: {:ok, Snapshot.t() | nil} | {:error, Exception.t()}
  def latest(session_uuid, opts) when is_binary(session_uuid) and is_list(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.get(opts, :actor)
    key = Keyword.fetch!(opts, :key)

    case load_session(session_uuid, tenant, actor) do
      {:ok, session} -> {:ok, parse_snapshot(session, key)}
      {:error, _} = err -> err
    end
  end

  defp load_session(session_uuid, tenant, actor) do
    case SessionResource.by_id(session_uuid, tenant: tenant, actor: actor) do
      {:ok, nil} ->
        {:error, not_found_error(session_uuid, tenant)}

      {:ok, %SessionResource{} = session} ->
        {:ok, session}

      {:error, reason} ->
        {:error,
         Normalize.compaction_error(reason, %{
           operation: :compaction,
           session_id: session_uuid,
           tenant_id: tenant,
           phase: :load_session
         })}
    end
  end

  defp do_persist(session, key, jsonb, tenant, actor, session_uuid, snapshot) do
    case SessionResource.set_compaction_snapshot(session, key, jsonb,
           tenant: tenant,
           actor: actor
         ) do
      {:ok, _updated} ->
        {:ok, snapshot}

      {:error, reason} ->
        {:error,
         Normalize.compaction_error(reason, %{
           operation: :compaction,
           session_id: session_uuid,
           tenant_id: tenant,
           phase: :persist_snapshot
         })}
    end
  end

  defp parse_snapshot(%SessionResource{metadata: metadata}, key) when is_map(metadata) do
    metadata
    |> fetch_compaction(key)
    |> normalize_snapshot()
  end

  defp parse_snapshot(_, _key), do: nil

  # Per-agent snapshots live under `metadata["compactions"][key]`. (DB-backed
  # metadata is always string-keyed; the atom fallbacks guard in-memory maps.)
  defp fetch_compaction(metadata, key) do
    case fetch_either(metadata, "compactions", :compactions) do
      compactions when is_map(compactions) -> fetch_either(compactions, key, key)
      _ -> nil
    end
  end

  defp fetch_either(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp normalize_snapshot(nil), do: nil

  defp normalize_snapshot(raw) when is_map(raw) and map_size(raw) == 0, do: nil

  defp normalize_snapshot(raw) when is_map(raw), do: Snapshot.from_jsonb(raw)

  defp normalize_snapshot(_), do: nil

  defp not_found_error(session_uuid, tenant) do
    JidoClaw.Error.not_found(:session, session_uuid,
      details: %{
        operation: :compaction,
        tenant_id: tenant,
        phase: :load_session
      }
    )
  end
end
