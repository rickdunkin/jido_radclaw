defmodule JidoClaw.Workspaces.PolicyTransitions do
  @moduledoc """
  Bulk row-status fix-up after a workspace `embedding_policy` change.

  `:disabled` rows are flipped to `:pending` and backoff state cleared
  when the policy moves to `:default`. The reverse direction flips
  `:pending|:processing|:failed` to `:disabled`. `:ready` rows keep
  their `embedding` when transitioning into `:disabled` unless
  `purge_existing: true` is passed.

  Deferred to v0.7+: batched/background drain for workspaces with
  millions of rows.
  """

  alias AshPostgres.DataLayer.Info
  alias Ecto.Adapters.SQL
  alias JidoClaw.Repo

  @doc """
  Apply the row-status fix-up for the given workspace and new policy.

  Reads the existing policy by querying the workspace's current
  `embedding_policy` value (assumes the caller has already run the
  `set_embedding_policy` action). Pass `purge_existing: true` to NULL
  out `embedding` on `:ready` rows when transitioning to `:disabled`.
  """
  @spec apply_embedding(String.t(), atom(), keyword()) :: :ok | {:error, term()}
  def apply_embedding(workspace_id, new_policy, opts \\ [])

  # `BackfillWorker` scans both `solutions` and `memory_facts`, so the
  # transition has to touch both — otherwise memory facts in the
  # affected workspace stay `:disabled` after a flip to `:default`,
  # and `purge_existing: true` leaves their ready embeddings behind.
  @embedding_tables ["solutions", "memory_facts"]

  def apply_embedding(workspace_id, :disabled, opts) do
    purge? = Keyword.get(opts, :purge_existing, false)
    workspace_uuid = Ecto.UUID.dump!(workspace_id)

    result =
      Repo.transaction(fn ->
        Enum.each(@embedding_tables, fn table ->
          # table is a compile-time constant from @embedding_tables; the only
          # user value (workspace_uuid) is $1-bound — not an injection vector.
          # reach:disable-next-line ecto_interpolated_repo_query
          Repo.query!(
            """
            UPDATE #{table}
               SET embedding_status = 'disabled',
                   embedding_attempt_count = 0,
                   embedding_next_attempt_at = NULL,
                   embedding_last_error = NULL
             WHERE workspace_id = $1
               AND embedding_status IN ('pending', 'processing', 'failed')
            """,
            [workspace_uuid]
          )

          if purge? do
            # table is a compile-time constant from @embedding_tables; the only
            # user value (workspace_uuid) is $1-bound — not an injection vector.
            # reach:disable-next-line ecto_interpolated_repo_query
            Repo.query!(
              """
              UPDATE #{table}
                 SET embedding = NULL,
                     embedding_status = 'disabled',
                     embedding_attempt_count = 0,
                     embedding_next_attempt_at = NULL,
                     embedding_last_error = NULL
               WHERE workspace_id = $1
                 AND embedding_status = 'ready'
              """,
              [workspace_uuid]
            )
          end
        end)
      end)

    normalize_result(result)
  end

  def apply_embedding(workspace_id, :default, _opts) do
    workspace_uuid = Ecto.UUID.dump!(workspace_id)

    result =
      Repo.transaction(fn ->
        Enum.each(@embedding_tables, fn table ->
          # table is a compile-time constant from @embedding_tables; the only
          # user value (workspace_uuid) is $1-bound — not an injection vector.
          # reach:disable-next-line ecto_interpolated_repo_query
          Repo.query!(
            """
            UPDATE #{table}
               SET embedding_status = 'pending',
                   embedding_attempt_count = 0,
                   embedding_next_attempt_at = NULL,
                   embedding_last_error = NULL
             WHERE workspace_id = $1
               AND embedding_status = 'disabled'
            """,
            [workspace_uuid]
          )
        end)
      end)

    normalize_result(result)
  end

  def apply_embedding(_workspace_id, other, _opts), do: {:error, {:unknown_policy, other}}

  defp normalize_result({:ok, _}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}

  # ---------------------------------------------------------------------------
  # Most-restrictive aggregates for the consolidator's egress gate.
  # ---------------------------------------------------------------------------

  @doc """
  Aggregate the consolidation policy across every workspace in a
  tenant that's keyed to the supplied `user_id`.

  Returns the **most-restrictive** policy: `:disabled` < `:default`.
  Used by the consolidator's `PolicyResolver` for user-scope runs —
  a user with one `:disabled` workspace is considered opted out
  everywhere in that tenant.

  No referencing workspaces → `:disabled` (default-deny).
  """
  @spec resolve_consolidation_policy_for_user(String.t(), Ecto.UUID.t()) ::
          :default | :disabled
  def resolve_consolidation_policy_for_user(tenant_id, user_id),
    do: aggregate_policy(:user_id, tenant_id, user_id)

  @doc """
  Aggregate the consolidation policy across every workspace in a
  tenant that references the supplied `project_id`.

  Returns the most-restrictive policy across referencing workspaces
  using the same MIN-aggregate shape as the user-scope variant.
  """
  @spec resolve_consolidation_policy_for_project(String.t(), Ecto.UUID.t()) ::
          :default | :disabled
  def resolve_consolidation_policy_for_project(tenant_id, project_id),
    do: aggregate_policy(:project_id, tenant_id, project_id)

  defp aggregate_policy(:user_id, tenant_id, fk_id),
    do: run_aggregate("user_id", tenant_id, fk_id)

  defp aggregate_policy(:project_id, tenant_id, fk_id),
    do: run_aggregate("project_id", tenant_id, fk_id)

  defp run_aggregate(column, tenant_id, fk_id)
       when column in ["user_id", "project_id"] do
    table = Info.table(JidoClaw.Workspaces.Workspace)

    {:ok, %{rows: [[result]]}} =
      SQL.query(
        Repo,
        """
        SELECT MIN(CASE consolidation_policy
                      WHEN 'disabled' THEN 0
                      WHEN 'default' THEN 1
                    END)
        FROM #{table}
        WHERE tenant_id = $1 AND #{column} = $2
        """,
        [tenant_id, dump_uuid(fk_id)]
      )

    decode_policy(result)
  end

  defp dump_uuid(<<_::binary-size(16)>> = raw), do: raw
  defp dump_uuid(uuid) when is_binary(uuid), do: Ecto.UUID.dump!(uuid)
  defp dump_uuid(other), do: other

  defp decode_policy(nil), do: :disabled
  defp decode_policy(0), do: :disabled
  defp decode_policy(1), do: :default
end
