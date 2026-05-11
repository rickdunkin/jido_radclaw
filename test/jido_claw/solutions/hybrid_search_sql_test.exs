defmodule JidoClaw.Solutions.HybridSearchSqlTest do
  @moduledoc """
  Regression coverage for `HybridSearchSql.run/1` (Findings 1 & 2)
  plus the RRF combine introduced in v0.6 cleanup.

  Locks in:

    * The `LIKE` ESCAPE clause is well-formed (`'\\'` runtime). Prior
      to the fix the runtime ESCAPE string was two chars and Postgres
      rejected with `invalid escape string`, making the result
      always `[]` for any non-exact query.
    * `combined_score` is plumbed into the wrapper map, not dropped
      en route to the caller.
    * RRF combine: 3-pool match beats stronger 2-pool match; rank
      preservation; missing-pool defaults to 0.0 not a fixed rank.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Repo
  alias JidoClaw.Solutions.HybridSearchSql
  alias JidoClaw.Solutions.SearchEscape

  setup do
    tenant_id = unique_tenant_id()
    ws = workspace_fixture(tenant_id, embedding_policy: :disabled)
    {:ok, tenant_id: tenant_id, workspace: ws}
  end

  describe "run/1 — LIKE ESCAPE regression (Finding 1)" do
    test "lexical query against a content-bearing row succeeds without a Postgres error",
         %{tenant_id: tenant_id, workspace: ws} do
      _sol = solution_fixture(tenant_id, ws.id, "FooBar widget pipeline")

      results =
        HybridSearchSql.run(%{
          query: "FooBar",
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: nil
        })

      # The pre-fix behavior was an unconditional `[]` from the
      # exception arm. Any non-empty result here proves the SQL ran.
      assert is_list(results)
      assert length(results) >= 1
    end

    test "queries containing % and _ don't blow up", %{tenant_id: tenant_id, workspace: ws} do
      _sol = solution_fixture(tenant_id, ws.id, "rate is 100% guaranteed")

      results =
        HybridSearchSql.run(%{
          query: "100%_anything",
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: nil
        })

      assert is_list(results)
    end
  end

  describe "run/1 — wrapper shape (Finding 2)" do
    test "returns a list of %{solution: %Solution{}, combined_score: float}",
         %{tenant_id: tenant_id, workspace: ws} do
      _sol = solution_fixture(tenant_id, ws.id, "auth login JWT pipeline")

      results =
        HybridSearchSql.run(%{
          query: "auth JWT",
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: nil
        })

      assert length(results) >= 1

      Enum.each(results, fn entry ->
        assert %{solution: %Solution{}, combined_score: score} = entry
        assert is_float(score)
        assert score >= 0.0
      end)
    end

    test "combined_score is independent of trust_score",
         %{tenant_id: tenant_id, workspace: ws} do
      sol =
        solution_fixture(tenant_id, ws.id, "deploy database migration runbook", trust_score: 0.95)

      [%{solution: returned, combined_score: combined}] =
        HybridSearchSql.run(%{
          query: "database migration",
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 1,
          query_embedding: nil
        })

      assert returned.id == sol.id
      assert returned.trust_score == 0.95
      # The lexical pool's similarity scorer caps weighted contribution
      # well below trust_score's 0.95 — proves the two are not the
      # same number.
      refute_in_delta(combined, 0.95, 0.01)
    end
  end

  describe "run/1 — visibility scoping" do
    test "cross-workspace :local rows are filtered out", %{tenant_id: tenant_id, workspace: ws} do
      other_ws = workspace_fixture(tenant_id, embedding_policy: :disabled)
      _hidden = solution_fixture(tenant_id, other_ws.id, "secret deploy runbook", sharing: :local)

      results =
        HybridSearchSql.run(%{
          query: "secret deploy",
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: nil
        })

      assert results == []
    end

    test "cross-workspace :public rows are admitted", %{tenant_id: tenant_id, workspace: ws} do
      other_ws = workspace_fixture(tenant_id, embedding_policy: :disabled)
      sol = solution_fixture(tenant_id, other_ws.id, "public deploy runbook", sharing: :public)

      results =
        HybridSearchSql.run(%{
          query: "public deploy",
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: nil
        })

      assert Enum.any?(results, fn %{solution: s} -> s.id == sol.id end)
    end

    test "crowd-out: high-ranking cross-workspace :local rows can't fill the pool past visibility",
         %{tenant_id: tenant_id, workspace: ws} do
      # The pre-fix behavior applied workspace/sharing only in the
      # outer SELECT, after each CTE pool already enforced its own
      # `LIMIT $7 * 4`. With limit=10 that's 40 rows. Seed 41
      # high-ranking *private* rows in another workspace, plus a
      # single visible row in the caller's workspace whose content
      # also matches the query but ranks lower (cover density). On
      # the pre-fix shape the 41 privates fill the FTS pool's top
      # 40 slots and the visible row is dropped at position 42; the
      # outer SELECT then discards the 40 privates by visibility,
      # producing `[]`. On the post-fix shape each pool excludes
      # cross-workspace :local at WHERE-time, so the visible row
      # enters the FTS pool (as the only candidate) and is
      # returned.
      #
      # `websearch_to_tsquery('english', 'elixir genserver
      # supervisor')` produces an AND query (`'elixir' & 'genserv'
      # & 'supervisor'`) — every candidate row must have all three
      # tokens in its `search_vector` to pass the FTS @@ check. Both
      # the privates and the visible row contain all three tokens
      # in `solution_content`; the visible row pads them out with a
      # large block of unrelated filler so its `ts_rank_cd` (cover
      # density) is below the privates' tight 3-token-in-4-word
      # match.
      other_ws = workspace_fixture(tenant_id, embedding_policy: :disabled)

      # 41 strong-match private rows. Tight FTS cover density.
      for i <- 1..41 do
        solution_fixture(
          tenant_id,
          other_ws.id,
          "elixir genserver supervisor #{i}",
          sharing: :local
        )
      end

      # Visible row: same three query tokens, but separated by 30
      # filler words each so cover density is much wider. Filler
      # tokens are nonsense words that don't stem to any query
      # token. The visible row still enters BOTH the FTS pool
      # (passes the AND @@ check) and the lexical pool (trigram
      # similarity ~0.79, above the 0.3 `pg_trgm` threshold). What
      # matters for the regression is rank ORDER: the 41 privates'
      # tight 3-token content ranks higher in both pools (FTS
      # ts_rank_cd ~0.20 vs visible ~0.0033; lexical similarity
      # ~0.93 vs visible ~0.79). With pool LIMIT 40, the visible
      # row is rank 42 and falls out under the pre-fix shape; under
      # the fix the cross-workspace :local privates are excluded at
      # WHERE-time and visible becomes the sole top-40 candidate.
      filler = List.duplicate("zorbox", 30) |> Enum.join(" ")

      visible =
        solution_fixture(
          tenant_id,
          ws.id,
          "elixir #{filler} genserver #{filler} supervisor",
          sharing: :local
        )

      results =
        HybridSearchSql.run(%{
          query: "elixir genserver supervisor",
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: nil
        })

      assert Enum.any?(results, fn %{solution: s} -> s.id == visible.id end),
             "visible row was crowded out by 41 cross-workspace :local rows — visibility predicate is being applied after pool LIMIT (outer-SELECT-only)"

      # And no cross-workspace :local row leaks through.
      refute Enum.any?(results, fn %{solution: s} -> s.workspace_id == other_ws.id end)
    end
  end

  describe "run/1 — RRF combine" do
    test "3-pool match beats stronger 2-pool match (regression locker)",
         %{tenant_id: tenant_id, workspace: ws} do
      query_text = "postgres replica streaming"

      # Row A: enters all 3 pools (mid-ANN, mid-FTS, mid-lexical). The
      # embedding is near-orthogonal to the query embedding so its raw
      # ANN score is low but the row is still in the ANN pool.
      a_embedding = near_orthogonal_embedding()

      sol_a =
        solution_fixture(
          tenant_id,
          ws.id,
          "pg_basebackup streaming replica setup notes",
          language: "elixir",
          framework: "postgrex",
          tags: ["replication", "postgres"],
          embedding_status: :ready,
          embedding: a_embedding
        )

      # Row B: very high FTS + lexical, but ANN-absent (embedding NULL,
      # status :pending → ANN pool predicates filter it out).
      b_content =
        "postgres replica streaming postgres replica streaming postgres replica streaming postgres replica streaming"

      sol_b =
        solution_fixture(
          tenant_id,
          ws.id,
          b_content,
          language: "elixir",
          framework: "postgrex",
          embedding_status: :pending
        )

      query_embedding = query_embedding_for_rrf()

      # Pre-flight probes: assert pool membership we depend on.
      assert in_fts_pool?(tenant_id, sol_a.id, query_text),
             "Row A must enter FTS pool"

      assert in_lexical_pool?(tenant_id, sol_a.id, query_text),
             "Row A must enter lexical pool"

      assert in_ann_pool?(tenant_id, sol_a.id, query_embedding),
             "Row A must enter ANN pool"

      assert in_fts_pool?(tenant_id, sol_b.id, query_text),
             "Row B must enter FTS pool"

      assert in_lexical_pool?(tenant_id, sol_b.id, query_text),
             "Row B must enter lexical pool"

      refute in_ann_pool?(tenant_id, sol_b.id, query_embedding),
             "Row B must NOT enter ANN pool (no embedding)"

      # Deterministic weighted-blend pre-check: prove the fixture is
      # calibrated to *defeat* the old `fts*0.4 + ann*0.4 + lex*0.2`
      # formula. If B doesn't outscore A under weighted-blend, the
      # test wouldn't catch a regression to weighted-blend.
      {fts_a, ann_a, lex_a} = raw_pool_scores(sol_a.id, query_text, query_embedding)
      {fts_b, ann_b, lex_b} = raw_pool_scores(sol_b.id, query_text, query_embedding)

      old_a = fts_a * 0.4 + ann_a * 0.4 + lex_a * 0.2
      old_b = fts_b * 0.4 + ann_b * 0.4 + lex_b * 0.2

      assert old_b > old_a,
             "fixture must be calibrated so old weighted-blend ranks B above A; " <>
               "got old_b=#{old_b}, old_a=#{old_a}"

      # Under RRF, A scores 3 × 1/61 ≈ 0.0492; B scores 2 × 1/61 ≈ 0.0328.
      # A wins regardless of raw-score magnitudes.
      results =
        HybridSearchSql.run(%{
          query: query_text,
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: query_embedding
        })

      ids = Enum.map(results, fn %{solution: s} -> s.id end)

      assert Enum.find_index(ids, &(&1 == sol_a.id)) <
               Enum.find_index(ids, &(&1 == sol_b.id)),
             "RRF should rank A (3-pool) above B (2-pool); got order: #{inspect(ids)}"
    end

    test "constant pool membership preserves rank ordering",
         %{tenant_id: tenant_id, workspace: ws} do
      # Three rows ranked strictly descending in BOTH FTS (cover
      # density) AND lexical (trigram similarity). Note: pg_trgm
      # `similarity()` penalizes texts with MANY unique non-query
      # trigrams (larger union → lower ratio), not text length per
      # se. So R1's content is just the three query tokens; R2 adds
      # one filler word per slot; R3 adds many *distinct* filler
      # words per slot to push lexical similarity strictly lower
      # than R2's. All embedding-disabled, so ANN drops; FTS +
      # lexical both run.
      r1 =
        solution_fixture(
          tenant_id,
          ws.id,
          "tomato carrot onion",
          language: "elixir",
          embedding_status: :disabled
        )

      r2 =
        solution_fixture(
          tenant_id,
          ws.id,
          "tomato zorbox carrot zorbox onion",
          language: "elixir",
          embedding_status: :disabled
        )

      r3 =
        solution_fixture(
          tenant_id,
          ws.id,
          "tomato zorbox zorbox xandr xandr carrot zorbox zorbox xandr xandr onion fizzbuzz wibblewobble",
          language: "elixir",
          embedding_status: :disabled
        )

      query_text = "tomato carrot onion"

      # Each row should be in BOTH FTS and lexical pools.
      for row_id <- [r1.id, r2.id, r3.id] do
        assert in_fts_pool?(tenant_id, row_id, query_text),
               "row #{row_id} must enter FTS pool"

        assert in_lexical_pool?(tenant_id, row_id, query_text),
               "row #{row_id} must enter lexical pool"
      end

      # Per-pool rank ordering: r1 < r2 < r3 in both FTS (by ts_rank_cd)
      # and lexical (by similarity). Since membership and ordering are
      # identical across both pools, RRF preserves the order.
      fts_order = per_pool_rank_order(tenant_id, ws.id, query_text, :fts)
      lex_order = per_pool_rank_order(tenant_id, ws.id, query_text, :lexical)

      assert position_of(fts_order, r1.id) < position_of(fts_order, r2.id)
      assert position_of(fts_order, r2.id) < position_of(fts_order, r3.id)

      assert position_of(lex_order, r1.id) < position_of(lex_order, r2.id)
      assert position_of(lex_order, r2.id) < position_of(lex_order, r3.id)

      results =
        HybridSearchSql.run(%{
          query: query_text,
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: nil
        })

      result_ids =
        results
        |> Enum.map(fn %{solution: s} -> s.id end)
        |> Enum.filter(&(&1 in [r1.id, r2.id, r3.id]))

      assert result_ids == [r1.id, r2.id, r3.id],
             "RRF should preserve constant pool ordering; got: #{inspect(result_ids)}"
    end

    test "missing-pool defaults to 0.0 (ANN absent — query_embedding: nil)",
         %{tenant_id: tenant_id, workspace: ws} do
      query_text = "deploymnt"

      # Row X: literal `deploymnt` token. Enters FTS (`deploymnt` is its
      # own stem) AND lexical (trigram + LIKE both match).
      sol_x =
        solution_fixture(
          tenant_id,
          ws.id,
          "deploymnt configuration runbook deploymnt steps",
          language: "elixir",
          embedding_status: :disabled
        )

      # Row Y: contains `deployment` (stems to `deploy`). NOT in FTS
      # (`deploymnt` doesn't stem to `deploy`), but in lexical pool via
      # trigram similarity — the short lexical_text keeps the trigram
      # union small enough that `similarity` clears pg_trgm's default
      # 0.3 threshold.
      sol_y =
        solution_fixture(
          tenant_id,
          ws.id,
          "deployment",
          language: "elixir",
          embedding_status: :disabled
        )

      assert in_fts_pool?(tenant_id, sol_x.id, query_text),
             "Row X must enter FTS pool (literal token match)"

      assert in_lexical_pool?(tenant_id, sol_x.id, query_text),
             "Row X must enter lexical pool"

      refute in_fts_pool?(tenant_id, sol_y.id, query_text),
             "Row Y must NOT enter FTS pool (deployment stems differently from deploymnt)"

      assert in_lexical_pool?(tenant_id, sol_y.id, query_text),
             "Row Y must enter lexical pool via trigram"

      results =
        HybridSearchSql.run(%{
          query: query_text,
          workspace_id: ws.id,
          tenant_id: tenant_id,
          limit: 10,
          query_embedding: nil
        })

      ids = Enum.map(results, fn %{solution: s} -> s.id end)

      assert Enum.find_index(ids, &(&1 == sol_x.id)) <
               Enum.find_index(ids, &(&1 == sol_y.id)),
             "X (FTS+lexical) must rank above Y (lexical only); got: #{inspect(ids)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers — RRF pool-membership probes mirror production query
  # construction in `HybridSearchSql.sql/0`. Using a raw `lower($query)`
  # could disagree with production behavior for `%`, `_`, case, and
  # escape edge cases.
  # ---------------------------------------------------------------------------

  defp in_fts_pool?(tenant_id, row_id, query) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT 1 FROM solutions
         WHERE id = $1 AND tenant_id = $2
           AND search_vector @@ websearch_to_tsquery('english', $3)
        """,
        [Ecto.UUID.dump!(row_id), tenant_id, query]
      )

    rows != []
  end

  defp in_lexical_pool?(tenant_id, row_id, query) do
    raw_lower = SearchEscape.lower_only(query)
    like_pattern = SearchEscape.escape_like(query)

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT 1 FROM solutions
         WHERE id = $1 AND tenant_id = $2
           AND (lexical_text % $3 OR lexical_text LIKE '%' || $4 || '%' ESCAPE '\\')
        """,
        [Ecto.UUID.dump!(row_id), tenant_id, raw_lower, like_pattern]
      )

    rows != []
  end

  defp in_ann_pool?(tenant_id, row_id, embedding) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT 1 FROM solutions
         WHERE id = $1 AND tenant_id = $2
           AND embedding IS NOT NULL
           AND embedding_status = 'ready'
           AND $3::vector IS NOT NULL
        """,
        [Ecto.UUID.dump!(row_id), tenant_id, embedding]
      )

    rows != []
  end

  # Return the per-row raw {fts, ann, lex} pool scores (0.0 where the
  # row falls out of the pool). Computed inline so the test can derive
  # the old weighted-blend value for the "fixture defeats the old
  # formula" pre-check.
  defp raw_pool_scores(row_id, query_text, embedding) do
    raw_lower = SearchEscape.lower_only(query_text)

    {:ok, %{rows: [[fts]]}} =
      Repo.query(
        """
        SELECT
          CASE WHEN search_vector @@ websearch_to_tsquery('english', $2)
               THEN ts_rank_cd(search_vector, websearch_to_tsquery('english', $2))
               ELSE 0.0
          END
        FROM solutions WHERE id = $1
        """,
        [Ecto.UUID.dump!(row_id), query_text]
      )

    {:ok, %{rows: [[ann]]}} =
      Repo.query(
        """
        SELECT
          CASE WHEN embedding IS NOT NULL AND embedding_status = 'ready' AND $2::vector IS NOT NULL
               THEN (1.0 - (embedding <=> $2::vector))::float
               ELSE 0.0
          END
        FROM solutions WHERE id = $1
        """,
        [Ecto.UUID.dump!(row_id), embedding]
      )

    {:ok, %{rows: [[lex]]}} =
      Repo.query(
        "SELECT similarity(lexical_text, $2)::float FROM solutions WHERE id = $1",
        [Ecto.UUID.dump!(row_id), raw_lower]
      )

    {fts || 0.0, ann || 0.0, lex || 0.0}
  end

  # Return ordered list of row ids for the given pool, descending by raw
  # score (same ORDER BY each pool CTE uses).
  defp per_pool_rank_order(tenant_id, _workspace_id, query, :fts) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT id FROM solutions
         WHERE tenant_id = $1 AND deleted_at IS NULL
           AND search_vector @@ websearch_to_tsquery('english', $2)
         ORDER BY ts_rank_cd(search_vector, websearch_to_tsquery('english', $2)) DESC
        """,
        [tenant_id, query]
      )

    Enum.map(rows, fn [raw_id] -> Ecto.UUID.cast!(raw_id) end)
  end

  defp per_pool_rank_order(tenant_id, _workspace_id, query, :lexical) do
    raw_lower = SearchEscape.lower_only(query)
    like_pattern = SearchEscape.escape_like(query)

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT id FROM solutions
         WHERE tenant_id = $1 AND deleted_at IS NULL
           AND (lexical_text % $2 OR lexical_text LIKE '%' || $3 || '%' ESCAPE '\\')
         ORDER BY similarity(lexical_text, $2) DESC
        """,
        [tenant_id, raw_lower, like_pattern]
      )

    Enum.map(rows, fn [raw_id] -> Ecto.UUID.cast!(raw_id) end)
  end

  defp position_of(list, id), do: Enum.find_index(list, &(&1 == id))

  # 1024-dim embedding for Row A — alternating signs so the dot product
  # with `query_embedding_for_rrf/0` (uniform positive) is 0, giving a
  # cosine similarity of 0. ANN pool membership is gated on
  # `embedding IS NOT NULL AND embedding_status = 'ready'` (not score),
  # so Row A still enters the ANN pool with a low raw score.
  defp near_orthogonal_embedding do
    Enum.flat_map(1..512, fn _ -> [0.01, -0.01] end)
  end

  # 1024-dim query embedding — uniform, non-zero so distance to any
  # candidate is well-defined.
  defp query_embedding_for_rrf do
    List.duplicate(0.05, 1024)
  end
end
