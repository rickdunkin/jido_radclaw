defmodule JidoClaw.Memory.HybridSearchSql do
  @moduledoc """
  Hybrid retrieval for `Memory.Fact` over three CTE pools:

    * `fts_pool`     — Postgres FTS via `websearch_to_tsquery` against
      the generated `search_vector` (label / content / tags weighted).
    * `ann_pool`     — pgvector cosine similarity against `embedding`,
      scoped by `embedding_model = $X` so the planner picks the matching
      partial HNSW index.
    * `lexical_pool` — `similarity(lexical_text, $X)` plus an
      ESCAPE-protected `LIKE` substring fallback, GIN-trigram-indexed.

  ## RRF combine vs. weighted-sum

  Mirrors `JidoClaw.Solutions.HybridSearchSql` shape but combines the
  three pool ranks via **Reciprocal Rank Fusion**:

      score = 1/(60 + r_fts) + 1/(60 + r_ann) + 1/(60 + r_lex)

  Solutions stays weighted-sum (no Phase 3 behavior change there).
  Memory chose RRF per the source plan §3.13 because the lexical pool's
  raw `similarity` scores have a different distribution than FTS's
  `ts_rank_cd` and the cosine `1 - distance` — RRF is rank-only, so the
  three pools combine without per-pool weight tuning.

  ## Scope chain

  Each pool's `WHERE` clause OR-disjoins one clause per scope-chain
  entry: `(scope_kind = 'session' AND session_id = $X) OR (scope_kind
  = 'workspace' AND workspace_id = $Y) OR ...`. The chain is supplied
  by the caller in retrieval-precedence order (most specific first)
  and `nil` ancestors are filtered out by `Scope.chain/1` upstream.

  ## Scope/source precedence

  Applied INSIDE the SQL via `ROW_NUMBER() OVER (PARTITION BY label
  ORDER BY scope_rank ASC, source_rank ASC, valid_at DESC)` so the
  caller sees one canonical row per active label. `dedup: :by_precedence`
  (default) keeps only `row_num = 1`; `dedup: :none` skips the
  partitioning so all matching rows surface (used by `/memory forget`
  candidate listing).

  Source rank ascending: `:user_save` (1) → `:consolidator_promoted`
  (2) → `:imported_legacy` (3) → `:model_remember` (4). Scope rank
  ascending: `:session` (1) → `:project` (2) → `:workspace` (3) →
  `:user` (4).

  ## Bitemporal predicate

  Each pool's bitemporal slot is composed via
  `Retrieval.bitemporal_predicate/2`. Default is `:current_truth`
  (`invalid_at IS NULL AND expired_at IS NULL`); the other three modes
  thread `world_t` / `system_t` parameters through a uniform fragment
  builder. See `JidoClaw.Memory.Retrieval` for the matrix.

  ## Parameter layout

  Built dynamically by `build_sql/_`. Static slots:

  | $1  | tenant_id (text) |

  Followed by one UUID parameter per scope-chain entry, optionally
  followed by world/system timestamp parameters when the bitemporal
  mode is non-default, then the static query/embedding/etc. params at
  the tail. The fragment builder returns `%{sql, params, next}` so each
  composer knows the next free `$N`.
  """

  require Logger

  alias JidoClaw.Memory.{Fact, Retrieval}
  alias JidoClaw.Repo
  alias JidoClaw.Solutions.SearchEscape

  @rrf_k 60

  @doc """
  Run hybrid search and return `[%{fact: %Memory.Fact{}, combined_score: float()}]`.

  When `query` is empty, the FTS and lexical pools are skipped and the
  result is sorted by recency only (`inserted_at DESC`). When
  `query_embedding` is nil, the ANN pool is skipped — lexical + FTS
  still rank via RRF.
  """
  @spec run(map()) :: [%{fact: Fact.t(), combined_score: float()}]
  def run(args) do
    tenant_id = Map.fetch!(args, :tenant_id)
    scope_chain = Map.fetch!(args, :scope_chain)
    query_text = Map.get(args, :query, "")
    embedding = Map.get(args, :query_embedding)
    embedding_model = Map.get(args, :embedding_model, "voyage-4-large")
    limit = Map.get(args, :limit, 10)
    dedup = Map.get(args, :dedup, :by_precedence)
    bitemporal = Map.get(args, :bitemporal, :current_truth)

    case scope_chain do
      [] ->
        []

      _ ->
        like_pattern = SearchEscape.escape_like(query_text)
        raw_lower = SearchEscape.lower_only(query_text)

        # Build the dynamic prefix params: tenant_id, then chain FK
        # uuids, then optional world/system timestamps for non-default
        # bitemporal modes. Static-tail params follow.
        scope_fragment = build_scope_chain_fragment(scope_chain, 2)
        bt_fragment = build_bitemporal_fragment(bitemporal, scope_fragment.next)

        static_params = [
          query_text,
          embedding,
          embedding_model,
          like_pattern,
          raw_lower,
          limit
        ]

        params = [tenant_id] ++ scope_fragment.params ++ bt_fragment.params ++ static_params

        static_offsets = compute_static_offsets(bt_fragment.next)
        sql = build_sql(scope_fragment.sql, bt_fragment.sql, dedup, query_text, embedding, static_offsets)

        case Repo.query(sql, params) do
          {:ok, %Postgrex.Result{columns: cols, rows: rows}} ->
            load_facts(cols, rows)

          {:error, reason} ->
            Logger.warning("[Memory.HybridSearchSql] query failed: #{inspect(reason)}")
            []
        end
    end
  end

  @doc """
  Recency-only listing for the empty-query path.

  Same scope-chain + bitemporal contract as `run/1`, but without the
  FTS/ANN/lex pools — rows are ordered by `inserted_at DESC` and (for
  `:by_precedence` dedup) deduped per-label via `ROW_NUMBER() OVER
  (PARTITION BY label)` *inside SQL*, so the closest-scope row at a
  given label always wins regardless of how many newer parent-scope
  rows exist. Returns `[%Memory.Fact{}]`.
  """
  @spec run_recency(map()) :: [Fact.t()]
  def run_recency(args) do
    tenant_id = Map.fetch!(args, :tenant_id)
    scope_chain = Map.fetch!(args, :scope_chain)
    limit = Map.get(args, :limit, 10)
    dedup = Map.get(args, :dedup, :by_precedence)
    bitemporal = Map.get(args, :bitemporal, :current_truth)

    case scope_chain do
      [] ->
        []

      _ ->
        scope_fragment = build_scope_chain_fragment(scope_chain, 2)
        bt_fragment = build_bitemporal_fragment(bitemporal, scope_fragment.next)
        limit_param = "$#{bt_fragment.next}"

        params = [tenant_id] ++ scope_fragment.params ++ bt_fragment.params ++ [limit]
        sql = build_recency_sql(scope_fragment.sql, bt_fragment.sql, dedup, limit_param)

        case Repo.query(sql, params) do
          {:ok, %Postgrex.Result{rows: rows}} ->
            ids = Enum.map(rows, fn [raw_id] -> Ecto.UUID.cast!(raw_id) end)
            load_facts_by_ids(ids)

          {:error, reason} ->
            Logger.warning("[Memory.HybridSearchSql] recency query failed: #{inspect(reason)}")
            []
        end
    end
  end

  defp build_recency_sql(scope_clause, bt_predicate, :by_precedence, limit_param) do
    """
    WITH ranked AS (
      SELECT id, inserted_at,
             ROW_NUMBER() OVER (
               PARTITION BY COALESCE(label, id::text)
               ORDER BY #{scope_rank_case()} ASC,
                        #{source_rank_case()} ASC,
                        valid_at DESC,
                        inserted_at DESC
             ) AS row_num
        FROM memory_facts
       WHERE tenant_id = $1
         AND #{scope_clause}
         AND #{bt_predicate}
    )
    SELECT id
      FROM ranked
     WHERE row_num = 1
     ORDER BY inserted_at DESC
     LIMIT #{limit_param}
    """
  end

  defp build_recency_sql(scope_clause, bt_predicate, :none, limit_param) do
    """
    SELECT id
      FROM memory_facts
     WHERE tenant_id = $1
       AND #{scope_clause}
       AND #{bt_predicate}
     ORDER BY inserted_at DESC
     LIMIT #{limit_param}
    """
  end

  # Load facts in the same id-order as the SQL recency dedup chose.
  defp load_facts_by_ids([]), do: []

  defp load_facts_by_ids(ids) do
    require Ash.Query

    loaded =
      Fact
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!()
      |> Map.new(fn f -> {f.id, f} end)

    Enum.flat_map(ids, fn id ->
      case Map.fetch(loaded, id) do
        {:ok, fact} -> [fact]
        :error -> []
      end
    end)
  end

  defp uuid_dump(<<_::binary-size(16)>> = raw), do: raw
  defp uuid_dump(uuid) when is_binary(uuid), do: Ecto.UUID.dump!(uuid)
  defp uuid_dump(other), do: other

  defp scope_fk_column(:user), do: "user_id"
  defp scope_fk_column(:workspace), do: "workspace_id"
  defp scope_fk_column(:project), do: "project_id"
  defp scope_fk_column(:session), do: "session_id"

  # Returns %{sql: <OR-clause string>, params: [<uuid binaries>], next: <next $N>}.
  # Each chain entry consumes one parameter for its FK uuid.
  defp build_scope_chain_fragment(chain, base_idx) do
    {clauses, params, next} =
      chain
      |> Enum.with_index(base_idx)
      |> Enum.reduce({[], [], base_idx}, fn {{kind, fk}, idx}, {clauses_acc, params_acc, _} ->
        column = scope_fk_column(kind)
        kind_str = Atom.to_string(kind)

        clause =
          "(scope_kind = '#{kind_str}' AND #{column} = $#{idx})"

        {clauses_acc ++ [clause], params_acc ++ [uuid_dump(fk)], idx + 1}
      end)

    %{sql: "(" <> Enum.join(clauses, " OR ") <> ")", params: params, next: next}
  end

  # Returns %{sql: <bitemporal predicate>, params: [<world_t/system_t>], next: <next $N>}.
  defp build_bitemporal_fragment(:current_truth, base_idx) do
    %{sql: Retrieval.bitemporal_predicate(:current_truth, []), params: [], next: base_idx}
  end

  defp build_bitemporal_fragment({:world_at, dt}, base_idx) do
    sql =
      Retrieval.bitemporal_predicate({:world_at, dt}, world_param: "$#{base_idx}")

    %{sql: sql, params: [dt], next: base_idx + 1}
  end

  defp build_bitemporal_fragment({:system_at, dt}, base_idx) do
    sql =
      Retrieval.bitemporal_predicate({:system_at, dt}, system_param: "$#{base_idx}")

    %{sql: sql, params: [dt], next: base_idx + 1}
  end

  defp build_bitemporal_fragment({:full_bitemporal, world_dt, system_dt}, base_idx) do
    sql =
      Retrieval.bitemporal_predicate({:full_bitemporal, world_dt, system_dt},
        world_param: "$#{base_idx}",
        system_param: "$#{base_idx + 1}"
      )

    %{sql: sql, params: [world_dt, system_dt], next: base_idx + 2}
  end

  # Map the static tail params to their $N ordinals. Tail order is fixed:
  # query_text, embedding, embedding_model, like_pattern, raw_lower, limit.
  defp compute_static_offsets(base) do
    %{
      query: "$#{base}",
      embedding: "$#{base + 1}",
      embedding_model: "$#{base + 2}",
      like_pattern: "$#{base + 3}",
      raw_lower: "$#{base + 4}",
      limit: "$#{base + 5}"
    }
  end

  defp build_sql(scope_clause, bt_predicate, dedup, query_text, embedding, off) do
    fts_pool = fts_pool_sql(scope_clause, bt_predicate, query_text, off, dedup)
    ann_pool = ann_pool_sql(scope_clause, bt_predicate, embedding, off, dedup)
    lex_pool = lexical_pool_sql(scope_clause, bt_predicate, query_text, off, dedup)

    pooled =
      """
      WITH
      #{fts_pool},
      #{ann_pool},
      #{lex_pool},
      ranked AS (
        SELECT id, fts_rank, ann_rank, lex_rank,
               (CASE WHEN fts_rank IS NOT NULL THEN 1.0/(#{@rrf_k} + fts_rank) ELSE 0.0 END +
                CASE WHEN ann_rank IS NOT NULL THEN 1.0/(#{@rrf_k} + ann_rank) ELSE 0.0 END +
                CASE WHEN lex_rank IS NOT NULL THEN 1.0/(#{@rrf_k} + lex_rank) ELSE 0.0 END
               )::float AS combined_score
          FROM (
            SELECT id, MIN(fts_rank) AS fts_rank, MIN(ann_rank) AS ann_rank, MIN(lex_rank) AS lex_rank
              FROM (
                SELECT * FROM fts_pool
                UNION ALL SELECT * FROM ann_pool
                UNION ALL SELECT * FROM lex_pool
              ) u
             GROUP BY id
          ) m
      )
      """

    final_select = final_select_sql(dedup, off)

    pooled <> ", " <> final_select
  end

  # Per-pool precedence dedup is the bug fix the reviewer flagged: with
  # the per-pool LIMIT in place, ranking BEFORE per-label dedup let a
  # closer-scope row that ranked beyond the cap drop out, leaving only
  # the lower-precedence sibling. We now dedup-by-label inside each
  # pool's matched set so the per-pool ranking only competes precedence
  # winners. A label whose precedence-winner doesn't match this
  # particular pool is still represented by whatever that pool's
  # winner-among-matches was — cross-pool reconciliation in the final
  # `deduped` step picks the correct row across pools.
  defp scope_precedence_partition do
    """
    ROW_NUMBER() OVER (
      PARTITION BY COALESCE(label, id::text)
      ORDER BY #{scope_rank_case()} ASC,
               #{source_rank_case()} ASC,
               valid_at DESC
    ) AS precedence_row
    """
  end

  defp fts_pool_sql(_scope_clause, _bt, "", _off, _dedup) do
    """
    fts_pool AS (
      SELECT NULL::uuid AS id, NULL::int AS fts_rank, NULL::int AS ann_rank, NULL::int AS lex_rank
       WHERE FALSE
    )
    """
  end

  defp fts_pool_sql(scope_clause, bt_predicate, _query_text, off, :by_precedence) do
    """
    fts_pool AS (
      SELECT id,
             ROW_NUMBER() OVER (ORDER BY raw_score DESC)::int AS fts_rank,
             NULL::int AS ann_rank,
             NULL::int AS lex_rank
        FROM (
          SELECT id, raw_score
            FROM (
              SELECT id,
                     ts_rank_cd(search_vector, websearch_to_tsquery('english', #{off.query})) AS raw_score,
                     #{scope_precedence_partition()}
                FROM memory_facts
               WHERE tenant_id = $1
                 AND #{scope_clause}
                 AND #{bt_predicate}
                 AND search_vector @@ websearch_to_tsquery('english', #{off.query})
            ) per_row
           WHERE precedence_row = 1
        ) winners
       ORDER BY fts_rank ASC
       LIMIT #{off.limit} * 4
    )
    """
  end

  defp fts_pool_sql(scope_clause, bt_predicate, _query_text, off, :none) do
    """
    fts_pool AS (
      SELECT id,
             ROW_NUMBER() OVER (ORDER BY ts_rank_cd(search_vector, websearch_to_tsquery('english', #{off.query})) DESC)::int AS fts_rank,
             NULL::int AS ann_rank,
             NULL::int AS lex_rank
        FROM memory_facts
       WHERE tenant_id = $1
         AND #{scope_clause}
         AND #{bt_predicate}
         AND search_vector @@ websearch_to_tsquery('english', #{off.query})
       ORDER BY fts_rank ASC
       LIMIT #{off.limit} * 4
    )
    """
  end

  defp ann_pool_sql(_scope_clause, _bt, nil, off, _dedup) do
    # Even when no embedding is supplied, reference the embedding +
    # embedding_model parameters so Postgres can type-infer the
    # parameters (which show up in the bind list regardless). Without
    # this anchor, planner emits "could not determine data type of
    # parameter $N".
    """
    ann_pool AS (
      SELECT NULL::uuid AS id, NULL::int AS fts_rank, NULL::int AS ann_rank, NULL::int AS lex_rank
       WHERE FALSE OR #{off.embedding}::vector IS NULL OR #{off.embedding_model}::text IS NULL
    )
    """
  end

  defp ann_pool_sql(scope_clause, bt_predicate, _embedding, off, :by_precedence) do
    """
    ann_pool AS (
      SELECT id,
             NULL::int AS fts_rank,
             ROW_NUMBER() OVER (ORDER BY distance ASC)::int AS ann_rank,
             NULL::int AS lex_rank
        FROM (
          SELECT id, distance
            FROM (
              SELECT id,
                     (embedding <=> #{off.embedding}::vector) AS distance,
                     #{scope_precedence_partition()}
                FROM memory_facts
               WHERE tenant_id = $1
                 AND #{scope_clause}
                 AND #{bt_predicate}
                 AND #{off.embedding}::vector IS NOT NULL
                 AND embedding IS NOT NULL
                 AND embedding_model = #{off.embedding_model}
                 AND embedding_status = 'ready'
            ) per_row
           WHERE precedence_row = 1
        ) winners
       ORDER BY ann_rank ASC
       LIMIT #{off.limit} * 4
    )
    """
  end

  defp ann_pool_sql(scope_clause, bt_predicate, _embedding, off, :none) do
    """
    ann_pool AS (
      SELECT id,
             NULL::int AS fts_rank,
             ROW_NUMBER() OVER (ORDER BY (embedding <=> #{off.embedding}::vector) ASC)::int AS ann_rank,
             NULL::int AS lex_rank
        FROM memory_facts
       WHERE tenant_id = $1
         AND #{scope_clause}
         AND #{bt_predicate}
         AND #{off.embedding}::vector IS NOT NULL
         AND embedding IS NOT NULL
         AND embedding_model = #{off.embedding_model}
         AND embedding_status = 'ready'
       ORDER BY ann_rank ASC
       LIMIT #{off.limit} * 4
    )
    """
  end

  defp lexical_pool_sql(_scope_clause, _bt, "", _off, _dedup) do
    """
    lex_pool AS (
      SELECT NULL::uuid AS id, NULL::int AS fts_rank, NULL::int AS ann_rank, NULL::int AS lex_rank
       WHERE FALSE
    )
    """
  end

  defp lexical_pool_sql(scope_clause, bt_predicate, _query_text, off, :by_precedence) do
    """
    lex_pool AS (
      SELECT id,
             NULL::int AS fts_rank,
             NULL::int AS ann_rank,
             ROW_NUMBER() OVER (ORDER BY sim DESC)::int AS lex_rank
        FROM (
          SELECT id, sim
            FROM (
              SELECT id,
                     similarity(lexical_text, #{off.raw_lower}) AS sim,
                     #{scope_precedence_partition()}
                FROM memory_facts
               WHERE tenant_id = $1
                 AND #{scope_clause}
                 AND #{bt_predicate}
                 AND (
                   lexical_text % #{off.raw_lower}
                   OR lexical_text LIKE '%' || #{off.like_pattern} || '%' ESCAPE '\\'
                 )
            ) per_row
           WHERE precedence_row = 1
        ) winners
       ORDER BY lex_rank ASC
       LIMIT #{off.limit} * 4
    )
    """
  end

  defp lexical_pool_sql(scope_clause, bt_predicate, _query_text, off, :none) do
    """
    lex_pool AS (
      SELECT id,
             NULL::int AS fts_rank,
             NULL::int AS ann_rank,
             ROW_NUMBER() OVER (ORDER BY similarity(lexical_text, #{off.raw_lower}) DESC)::int AS lex_rank
        FROM memory_facts
       WHERE tenant_id = $1
         AND #{scope_clause}
         AND #{bt_predicate}
         AND (
           lexical_text % #{off.raw_lower}
           OR lexical_text LIKE '%' || #{off.like_pattern} || '%' ESCAPE '\\'
         )
       ORDER BY lex_rank ASC
       LIMIT #{off.limit} * 4
    )
    """
  end

  # Source rank: lower wins. CASE expression preserves a stable order
  # across versions (`:user_save` always wins over `:consolidator_promoted`,
  # etc.). Same shape for scope rank.
  defp source_rank_case do
    # Plan §3.13 line 1041–1042: `:user_save` > `:consolidator_promoted`
    # > `:imported_legacy` > `:model_remember`. `:imported_legacy`
    # outranks `:model_remember` so curated v0.5 memory isn't
    # immediately shadowed by a fresh model self-write at the same label.
    """
    CASE source
      WHEN 'user_save' THEN 1
      WHEN 'consolidator_promoted' THEN 2
      WHEN 'imported_legacy' THEN 3
      WHEN 'model_remember' THEN 4
      ELSE 5
    END
    """
  end

  defp scope_rank_case do
    """
    CASE scope_kind
      WHEN 'session' THEN 1
      WHEN 'project' THEN 2
      WHEN 'workspace' THEN 3
      WHEN 'user' THEN 4
      ELSE 5
    END
    """
  end

  defp final_select_sql(:by_precedence, off) do
    """
    deduped AS (
      SELECT mf.*, r.combined_score,
             ROW_NUMBER() OVER (
               PARTITION BY COALESCE(mf.label, mf.id::text)
               ORDER BY #{scope_rank_case()} ASC,
                        #{source_rank_case()} ASC,
                        mf.valid_at DESC
             ) AS row_num
        FROM ranked r
        JOIN memory_facts mf ON mf.id = r.id
    )
    SELECT *
      FROM deduped
     WHERE row_num = 1
     ORDER BY combined_score DESC, valid_at DESC, inserted_at DESC
     LIMIT #{off.limit}
    """
  end

  defp final_select_sql(:none, off) do
    """
    SELECT mf.*, r.combined_score
      FROM ranked r
      JOIN memory_facts mf ON mf.id = r.id
     ORDER BY r.combined_score DESC, mf.valid_at DESC, mf.inserted_at DESC
     LIMIT #{off.limit}
    """
  end

  # ---------------------------------------------------------------------------
  # Result hydration — see Solutions.HybridSearchSql.load_solutions/2 for the
  # rationale on round-tripping ids through Ash.read! to get correctly typed
  # structs.
  # ---------------------------------------------------------------------------

  defp load_facts(cols, rows) do
    require Ash.Query

    id_index = Enum.find_index(cols, &(&1 == "id"))
    score_index = Enum.find_index(cols, &(&1 == "combined_score"))

    ranked =
      Enum.map(rows, fn row ->
        raw_id = Enum.at(row, id_index)
        score = Enum.at(row, score_index) || 0.0
        {Ecto.UUID.cast!(raw_id), score}
      end)

    case ranked do
      [] ->
        []

      _ ->
        ids = Enum.map(ranked, fn {id, _} -> id end)

        loaded =
          Fact
          |> Ash.Query.filter(id in ^ids)
          |> Ash.read!()
          |> Map.new(fn f -> {f.id, f} end)

        Enum.flat_map(ranked, fn {id, score} ->
          case Map.fetch(loaded, id) do
            {:ok, fact} -> [%{fact: fact, combined_score: score}]
            :error -> []
          end
        end)
    end
  end
end
