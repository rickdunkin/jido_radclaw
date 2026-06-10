defmodule JidoClaw.Solutions.HybridSearchSql do
  @moduledoc """
  Hybrid retrieval query combining three CTE pools:

    * `fts_pool` — Postgres FTS via `websearch_to_tsquery` against
      `search_vector`.
    * `ann_pool` — pgvector cosine similarity (`<=>` operator) against
      `embedding`, predicated on `embedding IS NOT NULL AND
      embedding_status = 'ready'` so the planner picks the partial
      HNSW index.
    * `lexical_pool` — `similarity(lexical_text, $11)` plus a
      LIKE-escaped substring fallback, GIN-indexed via `gin_trgm_ops`.

  Each pool emits ranked candidates; the outer `SELECT` combines them
  via **Reciprocal Rank Fusion**. Tenant + workspace +
  sharing-visibility predicates are applied **inside each pool** —
  if visibility were applied only in the outer SELECT, a high-
  ranking pile of private rows from other workspaces could fill
  `LIMIT $7 * 4` first and then be discarded, crowding out the
  visible rows that should have surfaced.

  ## RRF combine

  Mirrors `JidoClaw.Memory.HybridSearchSql`. Each pool emits per-row
  ranks; the outer combine is:

      score = (r_fts  IS NOT NULL ? 1/(60 + r_fts)  : 0)
            + (r_ann  IS NOT NULL ? 1/(60 + r_ann)  : 0)
            + (r_lex  IS NOT NULL ? 1/(60 + r_lex)  : 0)

  Rank-only fusion sidesteps the fact that `ts_rank_cd`,
  `1 - cosine_distance`, and `similarity()` live on incomparable
  scales — there is no per-pool weight tuning to maintain.

  ## Return shape

  `run/1` returns `[%{solution: %Solution{}, combined_score: float()}]`.
  The combined score is the SQL-computed RRF sum and is not an
  attribute on the resource — it is carried in the wrapper map so the
  caller (`Matcher.find_solutions/2`) can apply the relevance threshold
  without falling back to `trust_score`.

  ## Parameter map

  | Param | Purpose |
  | ----- | ------- |
  | `$1`  | query text (raw) — fed to `websearch_to_tsquery` |
  | `$2`  | language filter (or `NULL`) |
  | `$3`  | framework filter (or `NULL`) |
  | `$4`  | query embedding (or `NULL`) — `::vector` cast |
  | `$5`  | local visibility set (text[]) |
  | `$6`  | cross-workspace visibility set (text[]) |
  | `$7`  | limit |
  | `$8`  | workspace_id (uuid) |
  | `$9`  | tenant_id (text) |
  | `$10` | LIKE-escaped lower-cased query (drives `LIKE` filter only) |
  | `$11` | raw lower-cased query (drives `similarity(...)`) |

  Soft-delete predicate `AND deleted_at IS NULL` is repeated in every
  CTE — the resource has no `base_filter`, so each CTE must spell it
  out.
  """

  require Logger
  require Ash.Query

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Repo
  alias JidoClaw.Solutions.SearchEscape
  alias JidoClaw.Solutions.Solution

  @doc """
  Run the hybrid search and return wrapper maps with the raw
  `combined_score` next to the loaded `%Solution{}`.
  """
  @spec run(map()) :: [%{solution: Solution.t(), combined_score: float()}]
  def run(args) do
    query_text = Map.fetch!(args, :query)
    workspace_id = Map.fetch!(args, :workspace_id)
    tenant_id = Map.fetch!(args, :tenant_id)
    limit = Map.get(args, :limit, 10)

    # Pass the raw list of floats; AshPostgres.Extensions.Vector encodes
    # via Ash.Vector.new/1. Pre-encoding to a "[…]" string tripped the
    # binary-in-string path of Ash.Vector.new which treats each byte as
    # a separate dimension.
    embedding = Map.get(args, :query_embedding)

    language = Map.get(args, :language)
    framework = Map.get(args, :framework)

    local_visibility =
      atoms_to_text_array(Map.get(args, :local_visibility, [:local, :shared, :public]))

    cross_workspace_visibility =
      atoms_to_text_array(Map.get(args, :cross_workspace_visibility, [:public]))

    like_pattern = SearchEscape.escape_like(query_text)
    raw_lower = SearchEscape.lower_only(query_text)

    params = [
      query_text,
      language,
      framework,
      embedding,
      local_visibility,
      cross_workspace_visibility,
      limit,
      Ecto.UUID.dump!(workspace_id),
      tenant_id,
      like_pattern,
      raw_lower
    ]

    case Repo.query(sql(), params) do
      {:ok, %Postgrex.Result{columns: cols, rows: rows}} ->
        load_solutions(cols, rows, tenant_id)

      {:error, reason} ->
        Logger.warning("[HybridSearchSql] query failed: #{inspect(reason)}")
        []
    end
  end

  defp sql do
    """
    WITH
    fts_pool AS (
      SELECT s.id,
             ts_rank_cd(s.search_vector, websearch_to_tsquery('english', $1)) AS fts_score,
             0.0::float AS ann_score,
             0.0::float AS lex_score
        FROM solutions s
       WHERE s.tenant_id = $9
         AND s.deleted_at IS NULL
         AND ($2::text IS NULL OR s.language = $2::text)
         AND ($3::text IS NULL OR s.framework = $3::text)
         AND s.search_vector @@ websearch_to_tsquery('english', $1)
         AND (
           (s.workspace_id = $8 AND s.sharing::text = ANY($5))
           OR (s.workspace_id <> $8 AND s.sharing::text = ANY($6))
         )
       ORDER BY fts_score DESC
       LIMIT $7 * 4
    ),
    ann_pool AS (
      SELECT s.id,
             0.0::float AS fts_score,
             (1.0 - (s.embedding <=> $4::vector))::float AS ann_score,
             0.0::float AS lex_score
        FROM solutions s
       WHERE s.tenant_id = $9
         AND s.deleted_at IS NULL
         AND $4::vector IS NOT NULL
         AND s.embedding IS NOT NULL
         AND s.embedding_status = 'ready'
         AND ($2::text IS NULL OR s.language = $2::text)
         AND ($3::text IS NULL OR s.framework = $3::text)
         AND (
           (s.workspace_id = $8 AND s.sharing::text = ANY($5))
           OR (s.workspace_id <> $8 AND s.sharing::text = ANY($6))
         )
       ORDER BY s.embedding <=> $4::vector ASC
       LIMIT $7 * 4
    ),
    lexical_pool AS (
      SELECT s.id,
             0.0::float AS fts_score,
             0.0::float AS ann_score,
             similarity(s.lexical_text, $11)::float AS lex_score
        FROM solutions s
       WHERE s.tenant_id = $9
         AND s.deleted_at IS NULL
         AND ($2::text IS NULL OR s.language = $2::text)
         AND ($3::text IS NULL OR s.framework = $3::text)
         AND (
           s.lexical_text % $11
           OR s.lexical_text LIKE '%' || $10 || '%' ESCAPE '\\'
         )
         AND (
           (s.workspace_id = $8 AND s.sharing::text = ANY($5))
           OR (s.workspace_id <> $8 AND s.sharing::text = ANY($6))
         )
       ORDER BY similarity(s.lexical_text, $11) DESC
       LIMIT $7 * 4
    ),
    fts AS (
      SELECT id, RANK() OVER (ORDER BY fts_score DESC) AS r_fts
        FROM fts_pool
    ),
    ann AS (
      SELECT id, RANK() OVER (ORDER BY ann_score DESC) AS r_ann
        FROM ann_pool
    ),
    lexical AS (
      SELECT id, RANK() OVER (ORDER BY lex_score DESC) AS r_lex
        FROM lexical_pool
    ),
    ranked AS (
      SELECT id, r_fts, r_ann, r_lex,
             (CASE WHEN r_fts IS NOT NULL THEN 1.0/(60 + r_fts) ELSE 0.0 END
              + CASE WHEN r_ann IS NOT NULL THEN 1.0/(60 + r_ann) ELSE 0.0 END
              + CASE WHEN r_lex IS NOT NULL THEN 1.0/(60 + r_lex) ELSE 0.0 END
             )::float AS combined_score
        FROM (
          SELECT id, MIN(r_fts) AS r_fts, MIN(r_ann) AS r_ann, MIN(r_lex) AS r_lex
            FROM (
              SELECT id, r_fts, NULL::bigint AS r_ann, NULL::bigint AS r_lex FROM fts
              UNION ALL
              SELECT id, NULL::bigint, r_ann, NULL::bigint FROM ann
              UNION ALL
              SELECT id, NULL::bigint, NULL::bigint, r_lex FROM lexical
            ) u
           GROUP BY id
        ) m
    )
    SELECT s.*, ranked.combined_score
      FROM ranked
      JOIN solutions s ON s.id = ranked.id
     WHERE s.tenant_id = $9
       AND s.deleted_at IS NULL
     ORDER BY ranked.combined_score DESC, s.trust_score DESC, s.updated_at DESC
     LIMIT $7;
    """
  end

  defp atoms_to_text_array(atoms) when is_list(atoms) do
    Enum.map(atoms, fn
      a when is_atom(a) -> Atom.to_string(a)
      b when is_binary(b) -> b
    end)
  end

  # Postgrex returns raw column values: UUIDs as 16-byte binaries, text
  # ENUM columns (`sharing`, `embedding_status`) as strings, etc. Round-
  # tripping these through `struct/2` would leave callers with structs
  # whose `id` doesn't match the human-form UUID Ash returned at insert
  # time and whose atom-typed fields hold strings. Instead, extract the
  # row IDs and re-materialize through `Ash.read` so the resource layer
  # casts everything correctly; preserve insertion order via the SQL's
  # combined_score ranking and zip the score back onto each solution.
  defp load_solutions(cols, rows, tenant_id) do
    id_index = Enum.find_index(cols, &(&1 == "id"))
    score_index = Enum.find_index(cols, &(&1 == "combined_score"))

    ranked =
      Enum.map(rows, fn row ->
        row_tuple = List.to_tuple(row)
        raw_id = elem(row_tuple, id_index)
        score = elem(row_tuple, score_index) || 0.0
        {Ecto.UUID.cast!(raw_id), score}
      end)

    case ranked do
      [] ->
        []

      _ ->
        ids = Enum.map(ranked, fn {id, _} -> id end)

        loaded =
          Solution.query_to_list(%{},
            actor: Actor.system(tenant_id),
            tenant: tenant_id
          )
          |> Ash.Query.filter(id in ^ids)
          |> Ash.read(actor: Actor.system(tenant_id), tenant: tenant_id)
          |> case do
            {:ok, solutions} -> Map.new(solutions, fn s -> {s.id, s} end)
            {:error, _} -> %{}
          end

        Enum.flat_map(ranked, fn {id, score} ->
          case Map.fetch(loaded, id) do
            {:ok, sol} -> [%{solution: sol, combined_score: score}]
            :error -> []
          end
        end)
    end
  end
end
