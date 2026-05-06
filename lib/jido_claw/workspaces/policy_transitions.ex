defmodule JidoClaw.Workspaces.PolicyTransitions do
  @moduledoc """
  Bulk row-status fix-up after a workspace `embedding_policy` change.

  Maps the §1.4 transition table to bounded synchronous UPDATEs:

    | From       | To           | Effect on Solution rows                                     |
    |------------|--------------|-------------------------------------------------------------|
    | :disabled  | :default     | flip `:disabled` rows to `:pending`, clear backoff state    |
    | :disabled  | :local_only  | flip `:disabled` rows to `:pending`, clear backoff state    |
    | :default   | :local_only  | NULL `embedding` on `:ready` rows, flip them to `:pending`  |
    | :local_only| :default     | NULL `embedding` on `:ready` rows, flip them to `:pending`  |
    | :default   | :disabled    | flip `:pending|:processing|:failed` to `:disabled`          |
    | :local_only| :disabled    | flip `:pending|:processing|:failed` to `:disabled`          |

  `:ready` rows keep their `embedding` when transitioning into
  `:disabled` (re-enabling later picks the same vectors back up)
  unless `purge_existing: true` is passed.

  Deferred to v0.7+: batched/background drain for workspaces with
  millions of rows. Phase 1 ships synchronous UPDATEs only.
  """

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

  def apply_embedding(workspace_id, :disabled, opts) do
    purge? = Keyword.get(opts, :purge_existing, false)

    Repo.transaction(fn ->
      Repo.query!(
        """
        UPDATE solutions
           SET embedding_status = 'disabled',
               embedding_attempt_count = 0,
               embedding_next_attempt_at = NULL,
               embedding_last_error = NULL
         WHERE workspace_id = $1
           AND embedding_status IN ('pending', 'processing', 'failed')
        """,
        [Ecto.UUID.dump!(workspace_id)]
      )

      if purge? do
        Repo.query!(
          """
          UPDATE solutions
             SET embedding = NULL,
                 embedding_status = 'disabled',
                 embedding_model = NULL,
                 embedding_attempt_count = 0,
                 embedding_next_attempt_at = NULL,
                 embedding_last_error = NULL
           WHERE workspace_id = $1
             AND embedding_status = 'ready'
          """,
          [Ecto.UUID.dump!(workspace_id)]
        )
      end
    end)
    |> normalize_result()
  end

  def apply_embedding(workspace_id, policy, _opts) when policy in [:default, :local_only] do
    Repo.transaction(fn ->
      # 1. Re-enable any :disabled rows.
      Repo.query!(
        """
        UPDATE solutions
           SET embedding_status = 'pending',
               embedding_attempt_count = 0,
               embedding_next_attempt_at = NULL,
               embedding_last_error = NULL
         WHERE workspace_id = $1
           AND embedding_status = 'disabled'
        """,
        [Ecto.UUID.dump!(workspace_id)]
      )

      # 2. NULL embeddings on :ready rows that don't match the target
      #    model. The target model differs by policy:
      #      - :default  → "voyage-4-large"
      #      - :local_only → "mxbai-embed-large"
      target_model = if policy == :default, do: "voyage-4-large", else: "mxbai-embed-large"

      Repo.query!(
        """
        UPDATE solutions
           SET embedding = NULL,
               embedding_status = 'pending',
               embedding_attempt_count = 0,
               embedding_next_attempt_at = NULL,
               embedding_last_error = NULL
         WHERE workspace_id = $1
           AND embedding_status = 'ready'
           AND embedding_model IS DISTINCT FROM $2
        """,
        [Ecto.UUID.dump!(workspace_id), target_model]
      )
    end)
    |> normalize_result()
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

  Returns the **most-restrictive** policy: `:disabled` < `:local_only`
  < `:default`. Used by the consolidator's `PolicyResolver` for
  user-scope runs — a user with one `:disabled` workspace is
  considered opted out everywhere in that tenant.

  No referencing workspaces → `:disabled` (default-deny).
  """
  @spec resolve_consolidation_policy_for_user(String.t(), Ecto.UUID.t()) ::
          :default | :local_only | :disabled
  def resolve_consolidation_policy_for_user(tenant_id, user_id),
    do: aggregate_policy(:user_id, tenant_id, user_id)

  @doc """
  Aggregate the consolidation policy across every workspace in a
  tenant that references the supplied `project_id`.

  Returns the most-restrictive policy across referencing workspaces
  using the same MIN-aggregate shape as the user-scope variant.
  """
  @spec resolve_consolidation_policy_for_project(String.t(), Ecto.UUID.t()) ::
          :default | :local_only | :disabled
  def resolve_consolidation_policy_for_project(tenant_id, project_id),
    do: aggregate_policy(:project_id, tenant_id, project_id)

  defp aggregate_policy(:user_id, tenant_id, fk_id),
    do: run_aggregate("user_id", tenant_id, fk_id)

  defp aggregate_policy(:project_id, tenant_id, fk_id),
    do: run_aggregate("project_id", tenant_id, fk_id)

  defp run_aggregate(column, tenant_id, fk_id)
       when column in ["user_id", "project_id"] do
    table = AshPostgres.DataLayer.Info.table(JidoClaw.Workspaces.Workspace)

    {:ok, %{rows: [[result]]}} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        SELECT MIN(CASE consolidation_policy
                      WHEN 'disabled' THEN 0
                      WHEN 'local_only' THEN 1
                      WHEN 'default' THEN 2
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
  defp decode_policy(1), do: :local_only
  defp decode_policy(2), do: :default
end
