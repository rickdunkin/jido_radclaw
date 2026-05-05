defmodule JidoClaw.Repo.Migrations.V063Memory do
  @moduledoc """
  Memory subsystem (v0.6.3) — multi-tier, bitemporal, scope-keyed.

  Tables:

    * `memory_blocks` — curated tier rendered into the prompt snapshot.
    * `memory_block_revisions` — append-only history for blocks.
    * `memory_facts` — searchable tier with FTS, pgvector, pg_trgm.
    * `memory_episodes` — immutable provenance rows.
    * `memory_fact_episodes` — M:N join.
    * `memory_links` — directed graph edges (Fact → Fact).
    * `memory_consolidation_runs` — audit + composite watermarks.

  Hand-edited from the AshPostgres-generated migration to add:

    * IMMUTABLE wrapper functions (`memory_search_vector`,
      `memory_lexical_text`) — Postgres requires generation expressions
      to be IMMUTABLE, but `to_tsvector(regconfig, text)` and
      `array_to_string(anyarray, text)` are only STABLE. Wrapping them
      in IMMUTABLE SQL functions is the standard workaround (mirrors
      Phase 1 Solutions §1.2).
    * `GENERATED ALWAYS AS (...) STORED` clauses on `content_hash`
      (sha256 via pgcrypto), `search_vector`, `lexical_text`.
    * Partial HNSW indexes on `embedding` keyed by `embedding_model`
      so the planner can pick the right opclass per query.
    * GIN trigram index on `lexical_text` for substring + similarity.
  """

  use Ecto.Migration

  def up do
    # IMMUTABLE wrappers for the generated-column expressions. See
    # priv/repo/migrations/20260501113129_v061_solutions.exs for the
    # original Phase 1 precedent.
    execute("""
    CREATE OR REPLACE FUNCTION memory_search_vector(
      p_label text,
      p_content text,
      p_tags text[]
    ) RETURNS tsvector AS $$
      SELECT
        setweight(to_tsvector('english', coalesce(p_label, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(array_to_string(p_tags, ' '), '')), 'B') ||
        setweight(to_tsvector('english', coalesce(p_content, '')), 'C')
    $$ LANGUAGE SQL IMMUTABLE
    """)

    execute("""
    CREATE OR REPLACE FUNCTION memory_lexical_text(
      p_label text,
      p_content text,
      p_tags text[]
    ) RETURNS text AS $$
      SELECT lower(
        coalesce(p_label, '') || ' ' ||
        coalesce(p_content, '') || ' ' ||
        coalesce(array_to_string(p_tags, ' '), '')
      )
    $$ LANGUAGE SQL IMMUTABLE
    """)

    create table(:memory_facts, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:user_id, :uuid)
      add(:workspace_id, :uuid)
      add(:project_id, :uuid)
      add(:session_id, :uuid)
      add(:label, :text)
      add(:content, :text, null: false)
      add(:tags, {:array, :text}, null: false, default: [])
      add(:source, :text, null: false)
      add(:trust_score, :float, null: false, default: 0.4)
      add(:written_by, :text)

      add(:valid_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:invalid_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:expired_at, :utc_datetime_usec)

      add(:embedding, :vector, size: 1024)
      add(:embedding_status, :text, null: false, default: "pending")
      add(:embedding_attempt_count, :bigint, null: false, default: 0)
      add(:embedding_next_attempt_at, :utc_datetime_usec)
      add(:embedding_last_error, :text)
      add(:embedding_model, :text)

      add(:import_hash, :text)

      # Generated columns — Postgres `GENERATED ALWAYS AS (...) STORED`.
      # AshPostgres emits the column as a plain type; the `generated:`
      # option on `add/3` is the manual injection point.
      add(:content_hash, :binary, generated: "ALWAYS AS (digest(content, 'sha256')) STORED")

      add(:search_vector, :tsvector,
        generated: "ALWAYS AS (memory_search_vector(label, content, tags)) STORED"
      )

      add(:lexical_text, :text,
        generated: "ALWAYS AS (memory_lexical_text(label, content, tags)) STORED"
      )

      add(:promoted_at, :utc_datetime_usec)

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(index(:memory_facts, [:tenant_id, :embedding_status]))
    create(index(:memory_facts, [:search_vector], using: "gin"))
    create(index(:memory_facts, [:tenant_id, :source, :inserted_at]))
    create(index(:memory_facts, [:tenant_id, :scope_kind, :valid_at]))

    # Partial unique indexes — active label per scope kind.
    create(
      unique_index(:memory_facts, [:tenant_id, :scope_kind, :project_id, :label],
        name: "memory_facts_unique_active_label_per_scope_project_index",
        where:
          "(label IS NOT NULL AND invalid_at IS NULL AND tenant_id IS NOT NULL AND project_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_facts, [:tenant_id, :scope_kind, :session_id, :label],
        name: "memory_facts_unique_active_label_per_scope_session_index",
        where:
          "(label IS NOT NULL AND invalid_at IS NULL AND tenant_id IS NOT NULL AND session_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_facts, [:tenant_id, :scope_kind, :user_id, :label],
        name: "memory_facts_unique_active_label_per_scope_user_index",
        where:
          "(label IS NOT NULL AND invalid_at IS NULL AND tenant_id IS NOT NULL AND user_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_facts, [:tenant_id, :scope_kind, :workspace_id, :label],
        name: "memory_facts_unique_active_label_per_scope_workspace_index",
        where:
          "(label IS NOT NULL AND invalid_at IS NULL AND tenant_id IS NOT NULL AND workspace_id IS NOT NULL)"
      )
    )

    # Partial unique indexes — promoted-content dedup per scope kind.
    create(
      unique_index(:memory_facts, [:tenant_id, :scope_kind, :project_id, :content_hash],
        name: "mf_promoted_proj_idx",
        where:
          "(source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL AND tenant_id IS NOT NULL AND project_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_facts, [:tenant_id, :scope_kind, :session_id, :content_hash],
        name: "mf_promoted_sess_idx",
        where:
          "(source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL AND tenant_id IS NOT NULL AND session_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_facts, [:tenant_id, :scope_kind, :user_id, :content_hash],
        name: "mf_promoted_user_idx",
        where:
          "(source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL AND tenant_id IS NOT NULL AND user_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_facts, [:tenant_id, :scope_kind, :workspace_id, :content_hash],
        name: "mf_promoted_ws_idx",
        where:
          "(source = 'consolidator_promoted' AND invalid_at IS NULL AND content_hash IS NOT NULL AND tenant_id IS NOT NULL AND workspace_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_facts, [:import_hash],
        name: "memory_facts_unique_import_hash_index",
        where: "(import_hash IS NOT NULL)"
      )
    )

    # GIN trigram index on lexical_text — required for similarity()
    # ranking and ESCAPE-protected LIKE substring filters in the
    # hybrid retrieval CTE pool.
    execute("""
    CREATE INDEX memory_facts_lexical_text_trgm_idx
      ON memory_facts USING gin (lexical_text gin_trgm_ops)
    """)

    # Partial HNSW indexes per embedding_model — pgvector's HNSW only
    # ranks against one opclass per index. The Memory.HybridSearchSql
    # ANN CTE filters `embedding_model = $X`, which lets the planner
    # pick the matching partial index for each query.
    execute("""
    CREATE INDEX memory_facts_embedding_voyage_hnsw_idx
      ON memory_facts USING hnsw (embedding vector_cosine_ops)
      WHERE embedding_model = 'voyage-4-large'
    """)

    execute("""
    CREATE INDEX memory_facts_embedding_local_hnsw_idx
      ON memory_facts USING hnsw (embedding vector_cosine_ops)
      WHERE embedding_model = 'mxbai-embed-large'
    """)

    create table(:memory_blocks, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:user_id, :uuid)
      add(:workspace_id, :uuid)
      add(:project_id, :uuid)
      add(:session_id, :uuid)
      add(:label, :text, null: false)
      add(:description, :text)
      add(:value, :text, null: false)
      add(:char_limit, :bigint, null: false, default: 2000)
      add(:pinned, :boolean, null: false, default: true)
      add(:position, :bigint, null: false, default: 0)
      add(:source, :text, null: false)
      add(:written_by, :text)

      add(:valid_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:invalid_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:expired_at, :utc_datetime_usec)

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(index(:memory_blocks, [:tenant_id, :source, :inserted_at]))
    create(index(:memory_blocks, [:tenant_id, :scope_kind, :label, :invalid_at]))

    create(
      unique_index(:memory_blocks, [:tenant_id, :scope_kind, :label, :project_id],
        name: "memory_blocks_unique_label_per_scope_project_index",
        where: "(invalid_at IS NULL AND tenant_id IS NOT NULL AND project_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_blocks, [:tenant_id, :scope_kind, :label, :session_id],
        name: "memory_blocks_unique_label_per_scope_session_index",
        where: "(invalid_at IS NULL AND tenant_id IS NOT NULL AND session_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_blocks, [:tenant_id, :scope_kind, :label, :user_id],
        name: "memory_blocks_unique_label_per_scope_user_index",
        where: "(invalid_at IS NULL AND tenant_id IS NOT NULL AND user_id IS NOT NULL)"
      )
    )

    create(
      unique_index(:memory_blocks, [:tenant_id, :scope_kind, :label, :workspace_id],
        name: "memory_blocks_unique_label_per_scope_workspace_index",
        where: "(invalid_at IS NULL AND tenant_id IS NOT NULL AND workspace_id IS NOT NULL)"
      )
    )

    create table(:memory_block_revisions, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :block_id,
        references(:memory_blocks,
          column: :id,
          name: "memory_block_revisions_block_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:tenant_id, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:user_id, :uuid)
      add(:workspace_id, :uuid)
      add(:project_id, :uuid)
      add(:session_id, :uuid)
      add(:value, :text)
      add(:source, :text, null: false)
      add(:written_by, :text)
      add(:reason, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(index(:memory_block_revisions, [:tenant_id, :scope_kind, :inserted_at]))
    create(index(:memory_block_revisions, [:block_id, :inserted_at]))

    create table(:memory_episodes, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:user_id, :uuid)
      add(:workspace_id, :uuid)
      add(:project_id, :uuid)
      add(:session_id, :uuid)
      add(:kind, :text, null: false)
      add(:source_message_id, :uuid)
      add(:source_solution_id, :uuid)
      add(:content, :text)
      add(:metadata, :map, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:memory_episodes, [:tenant_id, :source_solution_id],
        where: "source_solution_id IS NOT NULL"
      )
    )

    create(
      index(:memory_episodes, [:tenant_id, :source_message_id],
        where: "source_message_id IS NOT NULL"
      )
    )

    create(index(:memory_episodes, [:tenant_id, :scope_kind, :inserted_at]))

    create table(:memory_fact_episodes, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :fact_id,
        references(:memory_facts,
          column: :id,
          name: "memory_fact_episodes_fact_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :episode_id,
        references(:memory_episodes,
          column: :id,
          name: "memory_fact_episodes_episode_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:tenant_id, :text, null: false)
      add(:role, :text, null: false, default: "primary")

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(index(:memory_fact_episodes, [:tenant_id, :inserted_at]))
    create(index(:memory_fact_episodes, [:episode_id]))
    create(index(:memory_fact_episodes, [:fact_id, :role]))

    create(
      unique_index(:memory_fact_episodes, [:fact_id, :episode_id],
        name: "memory_fact_episodes_unique_pair_index"
      )
    )

    create table(:memory_links, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :from_fact_id,
        references(:memory_facts,
          column: :id,
          name: "memory_links_from_fact_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :to_fact_id,
        references(:memory_facts,
          column: :id,
          name: "memory_links_to_fact_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:tenant_id, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:user_id, :uuid)
      add(:workspace_id, :uuid)
      add(:project_id, :uuid)
      add(:session_id, :uuid)
      add(:relation, :text, null: false)
      add(:reason, :text)
      add(:confidence, :float)
      add(:written_by, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(index(:memory_links, [:tenant_id, :to_fact_id, :relation]))
    create(index(:memory_links, [:tenant_id, :from_fact_id, :relation]))

    create(
      unique_index(:memory_links, [:from_fact_id, :to_fact_id, :relation],
        name: "memory_links_unique_edge_index"
      )
    )

    create table(:memory_consolidation_runs, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:user_id, :uuid)
      add(:workspace_id, :uuid)
      add(:project_id, :uuid)
      add(:session_id, :uuid)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
      add(:messages_processed_until_at, :utc_datetime_usec)
      add(:messages_processed_until_id, :uuid)
      add(:facts_processed_until_at, :utc_datetime_usec)
      add(:facts_processed_until_id, :uuid)
      add(:messages_processed, :bigint, null: false, default: 0)
      add(:facts_processed, :bigint, null: false, default: 0)
      add(:blocks_written, :bigint, null: false, default: 0)
      add(:blocks_revised, :bigint, null: false, default: 0)
      add(:facts_added, :bigint, null: false, default: 0)
      add(:facts_invalidated, :bigint, null: false, default: 0)
      add(:links_added, :bigint, null: false, default: 0)
      add(:status, :text, null: false)
      add(:error, :text)
      add(:forge_session_id, :uuid)
      add(:harness, :text)
      add(:harness_model, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:memory_consolidation_runs, [:forge_session_id],
        where: "forge_session_id IS NOT NULL"
      )
    )

    create(index(:memory_consolidation_runs, [:tenant_id, :status, :started_at]))
    create(index(:memory_consolidation_runs, [:tenant_id, :scope_kind, :started_at]))
  end

  def down do
    drop(table(:memory_consolidation_runs))

    drop(constraint(:memory_links, "memory_links_from_fact_id_fkey"))
    drop(constraint(:memory_links, "memory_links_to_fact_id_fkey"))
    drop(table(:memory_links))

    drop(constraint(:memory_fact_episodes, "memory_fact_episodes_fact_id_fkey"))
    drop(constraint(:memory_fact_episodes, "memory_fact_episodes_episode_id_fkey"))
    drop(table(:memory_fact_episodes))

    drop(table(:memory_episodes))

    drop(constraint(:memory_block_revisions, "memory_block_revisions_block_id_fkey"))
    drop(table(:memory_block_revisions))
    drop(table(:memory_blocks))

    execute("DROP INDEX IF EXISTS memory_facts_embedding_local_hnsw_idx")
    execute("DROP INDEX IF EXISTS memory_facts_embedding_voyage_hnsw_idx")
    execute("DROP INDEX IF EXISTS memory_facts_lexical_text_trgm_idx")

    drop(table(:memory_facts))

    execute("DROP FUNCTION IF EXISTS memory_lexical_text(text, text, text[])")
    execute("DROP FUNCTION IF EXISTS memory_search_vector(text, text, text[])")
  end
end
