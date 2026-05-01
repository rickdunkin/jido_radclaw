defmodule JidoClaw.Solutions.HybridSearchSqlTest do
  @moduledoc """
  Regression coverage for `HybridSearchSql.run/1` (Findings 1 & 2).

  Locks in:

    * The `LIKE` ESCAPE clause is well-formed (`'\\'` runtime). Prior
      to the fix the runtime ESCAPE string was two chars and Postgres
      rejected with `invalid escape string`, making the result
      always `[]` for any non-exact query.
    * `combined_score` is plumbed into the wrapper map, not dropped
      en route to the caller.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Solutions.HybridSearchSql

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
end
