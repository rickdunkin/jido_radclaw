defmodule JidoClaw.Repo.Migrations.V062StripLocalEmbeddings do
  @moduledoc """
  Strip local-only embedding support.

    1. Clear non-Voyage vectors so the surviving ANN partial index has
       a uniform vector space. Status flips to `:pending` for `:default`
       workspaces or `:disabled` for `:disabled` workspaces.
    2. Defensive policy reset: any lingering `local_only` policy values
       on `workspaces` collapse to `disabled`.
    3. Drop ALL HNSW indexes that reference `embedding_model` BEFORE the
       column drop so Postgres doesn't auto-drop them on `ALTER TABLE`
       (which would make a later explicit drop fail).
    4. Drop the `embedding_model` column on `solutions` and
       `memory_facts`.
    5. Recreate HNSW indexes as partial on the surviving columns; the
       new predicate matches the ANN query path.
    6. Defensive `memory_links.relation` migration mapping dropped values
       to `:related` so existing rows survive the §3.8 enum tightening.
  """

  use Ecto.Migration

  def up do
    # 1. Clear non-Voyage vectors, status keyed to workspace policy.
    execute("""
    UPDATE solutions s
       SET embedding = NULL,
           embedding_status = CASE
             WHEN w.embedding_policy = 'default' THEN 'pending'
             ELSE 'disabled'
           END,
           embedding_attempt_count = 0,
           embedding_next_attempt_at = NULL,
           embedding_last_error = NULL
      FROM workspaces w
     WHERE s.workspace_id = w.id
       AND s.embedding_model IS DISTINCT FROM 'voyage-4-large'
       AND s.embedding IS NOT NULL
    """)

    execute("""
    UPDATE memory_facts mf
       SET embedding = NULL,
           embedding_status = CASE
             WHEN w.embedding_policy = 'default' THEN 'pending'
             ELSE 'disabled'
           END,
           embedding_attempt_count = 0,
           embedding_next_attempt_at = NULL,
           embedding_last_error = NULL
      FROM workspaces w
     WHERE mf.workspace_id = w.id
       AND mf.embedding_model IS DISTINCT FROM 'voyage-4-large'
       AND mf.embedding IS NOT NULL
    """)

    # Unscoped / orphaned memory_facts: rows with no workspace_id (e.g.
    # `:user` scope) or whose workspace_id points at a deleted
    # workspace. Without this pass, a non-Voyage local-embedding row
    # would survive the embedding_model column drop and enter the new
    # `embedding_status = 'ready'` HNSW index, mixing vector spaces.
    # Default-deny: such rows go to `:disabled`.
    execute("""
    UPDATE memory_facts mf
       SET embedding = NULL,
           embedding_status = 'disabled',
           embedding_attempt_count = 0,
           embedding_next_attempt_at = NULL,
           embedding_last_error = NULL
     WHERE mf.embedding_model IS DISTINCT FROM 'voyage-4-large'
       AND mf.embedding IS NOT NULL
       AND (
         mf.workspace_id IS NULL
         OR NOT EXISTS (
           SELECT 1 FROM workspaces w WHERE w.id = mf.workspace_id
         )
       )
    """)

    # 2. Defensive policy reset.
    execute(
      "UPDATE workspaces SET embedding_policy = 'disabled' " <>
        "WHERE embedding_policy = 'local_only'"
    )

    execute(
      "UPDATE workspaces SET consolidation_policy = 'disabled' " <>
        "WHERE consolidation_policy = 'local_only'"
    )

    # 3. Drop existing HNSW indexes.
    execute("DROP INDEX IF EXISTS solutions_embedding_local_hnsw_idx")
    execute("DROP INDEX IF EXISTS solutions_embedding_voyage_hnsw_idx")
    execute("DROP INDEX IF EXISTS memory_facts_embedding_local_hnsw_idx")
    execute("DROP INDEX IF EXISTS memory_facts_embedding_voyage_hnsw_idx")

    # 4. Drop the column.
    alter table(:solutions) do
      remove(:embedding_model)
    end

    alter table(:memory_facts) do
      remove(:embedding_model)
    end

    # 5. Recreate HNSW indexes as partial on the surviving columns.
    execute("""
    CREATE INDEX solutions_embedding_hnsw_idx
      ON solutions USING hnsw (embedding vector_cosine_ops)
      WHERE embedding IS NOT NULL AND embedding_status = 'ready'
    """)

    execute("""
    CREATE INDEX memory_facts_embedding_hnsw_idx
      ON memory_facts USING hnsw (embedding vector_cosine_ops)
      WHERE embedding IS NOT NULL AND embedding_status = 'ready'
    """)

    # 6. Defensive memory_links.relation mapping for v0.6 enum tightening
    #    (§3.8). Old rows with `duplicates` / `depends_on` collapse to
    #    `related` so the new `one_of` constraint admits them.
    execute("""
    UPDATE memory_links
       SET relation = 'related'
     WHERE relation IN ('duplicates', 'depends_on')
    """)
  end

  def down do
    # Drop the new partial HNSW indexes.
    execute("DROP INDEX IF EXISTS solutions_embedding_hnsw_idx")
    execute("DROP INDEX IF EXISTS memory_facts_embedding_hnsw_idx")

    # Re-add the column (nullable).
    alter table(:solutions) do
      add(:embedding_model, :text)
    end

    alter table(:memory_facts) do
      add(:embedding_model, :text)
    end

    # Backfill voyage rows so the recreated voyage HNSW index is not
    # permanently empty.
    execute("""
    UPDATE solutions
       SET embedding_model = 'voyage-4-large'
     WHERE embedding IS NOT NULL
    """)

    execute("""
    UPDATE memory_facts
       SET embedding_model = 'voyage-4-large'
     WHERE embedding IS NOT NULL
    """)

    # Recreate the voyage HNSW indexes (mxbai indexes intentionally
    # skipped — there is no path to repopulate the column with
    # `mxbai-embed-large` values, so the index would be permanently
    # empty).
    execute("""
    CREATE INDEX solutions_embedding_voyage_hnsw_idx
      ON solutions USING hnsw (embedding vector_cosine_ops)
      WHERE embedding_model = 'voyage-4-large'
    """)

    execute("""
    CREATE INDEX memory_facts_embedding_voyage_hnsw_idx
      ON memory_facts USING hnsw (embedding vector_cosine_ops)
      WHERE embedding_model = 'voyage-4-large'
    """)
  end
end
