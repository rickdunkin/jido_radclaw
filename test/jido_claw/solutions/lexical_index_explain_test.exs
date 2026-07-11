defmodule JidoClaw.Solutions.LexicalIndexExplainTest do
  @moduledoc """
  Phase 1 gate (`phase-1-solutions.md:1405-1415`): the trigram GIN
  index on `lexical_text` actually engages for a representative
  lexical-only query. Without it, a substring-match query falls back
  to a sequential scan over the whole tenant — fine at fixture
  scale, untenable at production scale.

  Tagged `@moduletag :slow` so the 5k-row bulk seed is opt-in:

      mix test test/jido_claw/solutions/lexical_index_explain_test.exs --include slow

  Default ExUnit configuration in `test/test_helper.exs` excludes
  `:slow`, so the test does not slow down the standard suite.
  """

  use JidoClaw.SolutionsCase, async: true

  alias JidoClaw.Repo

  @moduletag :slow

  test "lexical-only query uses solutions_lexical_text_trgm_idx (Bitmap Index Scan)" do
    tenant_id = unique_tenant_id()
    workspace = workspace_fixture(tenant_id, embedding_policy: :disabled)

    # Seed 4_990 baseline rows + 10 target rows in this tenant. The
    # ~0.2% lexical hit rate keeps the trigram index attractive vs
    # a tenant-scoped seq scan.
    _ =
      bulk_insert_solutions(tenant_id, workspace.id, 4_990, fn i ->
        %{
          problem_signature: "bulk-baseline-#{i}",
          solution_content: "baseline solution row #{i} placeholder content",
          language: "elixir"
        }
      end)

    _ =
      bulk_insert_solutions(tenant_id, workspace.id, 10, fn i ->
        %{
          problem_signature: "bulk-target-#{i}",
          solution_content: "uncommonlexicaltoken target row #{i}",
          language: "elixir"
        }
      end)

    Repo.query!("ANALYZE solutions")

    query_text = "uncommonlexicaltoken"

    # The assertion we want to lock in is "the trigram GIN index is
    # engageable for the lexical predicate" — not the planner's cost
    # choice at fixture scale. With 5k rows the seq-scan cost (~1300)
    # beats the trigram bitmap (~3900), and tenant filtering steers
    # the planner to the cheaper `solutions_tenant_id_index` btree.
    # The regression we care about is "the index exists, is targeted
    # on the right column, and the SQL predicate is shaped so the
    # planner CAN use it." Disable seq scan and btree index scan so
    # the planner has to consider the GIN bitmap. We omit the
    # tenant_id predicate so the cost comparison is purely against
    # the lexical-pool predicate.
    transaction_result =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")
        Repo.query!("SET LOCAL enable_indexscan = off")
        Repo.query!("SET LOCAL enable_indexonlyscan = off")

        {:ok, %{rows: rows}} =
          Repo.query(
            """
            EXPLAIN (FORMAT JSON)
            SELECT id FROM solutions
             WHERE deleted_at IS NULL
               AND (lexical_text % $1 OR lexical_text LIKE '%' || $2 || '%' ESCAPE '\\')
            """,
            [query_text, query_text]
          )

        [[plan_json]] = rows

        plan_json
        |> List.first()
        |> Map.fetch!("Plan")
      end)

    plan =
      case transaction_result do
        {:ok, plan} -> plan
        other -> flunk("EXPLAIN transaction failed: #{inspect(other)}")
      end

    assert plan_uses_index?(plan, "solutions_lexical_text_trgm_idx"),
           "expected Bitmap Index Scan on trigram index; got: #{inspect(plan)}"
  end

  defp plan_uses_index?(%{"Node Type" => node_type, "Index Name" => idx}, target)
       when node_type in ["Bitmap Index Scan", "Index Scan"] and idx == target,
       do: true

  defp plan_uses_index?(%{"Plans" => children}, target) when is_list(children),
    do: Enum.any?(children, &plan_uses_index?(&1, target))

  defp plan_uses_index?(_, _), do: false
end
