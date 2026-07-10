defmodule JidoClaw.Conversations.EphemeralCleanup do
  @moduledoc """
  Removes a completed stateless API conversation without deleting durable artifacts.

  Artifact tables with nullable conversation FKs are detached first. Ephemeral
  request-correlation/message rows and the marked session are then deleted in one
  transaction. After commit, the matching request IDs are evicted from the hot
  correlation cache as well. The metadata predicate prevents an accidental caller
  from deleting a normal conversation.
  """

  alias Ecto.Adapters.SQL
  alias JidoClaw.Conversations.RequestCorrelation.Cache, as: CorrelationCache
  alias JidoClaw.Repo

  @detach_targets [
    {"agent_cases", "session_id"},
    {"reasoning_outcomes", "session_uuid"},
    {"solutions", "session_id"},
    {"tool_outputs", "session_id"},
    {"memory_block_revisions", "session_id"},
    {"memory_blocks", "session_id"},
    {"memory_consolidation_runs", "session_id"},
    {"memory_episodes", "session_id"},
    {"memory_facts", "session_id"},
    {"memory_links", "session_id"}
  ]
  @delete_targets [
    {"request_correlations", "session_id"},
    {"messages", "session_id"}
  ]

  # Identifiers are generated only from the compile-time registry above. The
  # registry remains separately inspectable so a schema-contract test can force
  # every new conversation reference into an explicit detach/delete decision.
  @detach_statements Enum.map(@detach_targets, fn {table, column} ->
                       "UPDATE #{table} SET #{column} = NULL WHERE #{column} = $1::uuid"
                     end)
  @delete_statements Enum.map(@delete_targets, fn {table, column} ->
                       "DELETE FROM #{table} WHERE #{column} = $1::uuid"
                     end)

  @doc "Return the audited detach/delete registry for stateless-session cleanup."
  @spec targets() :: %{detach: [{String.t(), String.t()}], delete: [{String.t(), String.t()}]}
  def targets, do: %{detach: @detach_targets, delete: @delete_targets}

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(tenant_id, session_uuid)
      when is_binary(tenant_id) and is_binary(session_uuid) do
    case Repo.transaction(fn -> delete_in_transaction(tenant_id, session_uuid) end) do
      {:ok, request_ids} ->
        Enum.each(request_ids, &delete_cached_correlation/1)
        delete_cached_session(session_uuid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end

    # Public cleanup boundary: database adapters and cache calls expose an open
    # exception set, all of which normalize to the same explicit error envelope.
  rescue
    # reach:disable-next-line bare_rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp delete_in_transaction(tenant_id, session_uuid) do
    dumped_uuid = Ecto.UUID.dump!(session_uuid)

    case lock_eligible_session(dumped_uuid, tenant_id) do
      :ok -> :ok
      :not_found -> Repo.rollback(:not_ephemeral_session)
    end

    Enum.each(@detach_statements, &SQL.query!(Repo, &1, [dumped_uuid]))

    request_ids = request_ids_for_session(dumped_uuid)

    Enum.each(@delete_statements, &SQL.query!(Repo, &1, [dumped_uuid]))

    SQL.query!(
      Repo,
      """
      DELETE FROM conversation_sessions
      WHERE id = $1::uuid
        AND tenant_id = $2
        AND metadata @> '{"api_stateless": true}'::jsonb
      """,
      [dumped_uuid, tenant_id]
    )

    request_ids
  end

  # Capture the exact durable keys while the eligible Session row is locked.
  # Cache eviction happens only after the enclosing transaction commits so a
  # rollback cannot leave a live DB row with its hot lookup silently removed.
  defp request_ids_for_session(dumped_uuid) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT request_id FROM request_correlations WHERE session_id = $1::uuid",
        [dumped_uuid]
      )

    Enum.map(rows, fn [request_id] -> request_id end)
  end

  # If the cache owner is unavailable its ETS table has already disappeared;
  # a concurrent supervisor restart recreates it empty. Cache availability must
  # therefore never turn a successfully committed durable cleanup into an error.
  defp delete_cached_correlation(request_id) do
    CorrelationCache.delete(request_id)
  catch
    :exit, _reason -> :ok
  end

  defp delete_cached_session(session_uuid) do
    CorrelationCache.delete_for_session(session_uuid)
  catch
    :exit, _reason -> :ok
  end

  defp lock_eligible_session(dumped_uuid, tenant_id) do
    result =
      SQL.query!(
        Repo,
        """
        SELECT id
        FROM conversation_sessions
        WHERE id = $1::uuid
          AND tenant_id = $2
          AND metadata @> '{"api_stateless": true}'::jsonb
        FOR UPDATE
        """,
        [dumped_uuid, tenant_id]
      )

    if result.num_rows == 1, do: :ok, else: :not_found
  end
end
