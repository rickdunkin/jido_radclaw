defmodule JidoClaw.Solutions.GeneratedColumnsTest do
  @moduledoc """
  Phase 1 gate (`phase-1-solutions.md:1475-1482`): the `search_vector`
  and `lexical_text` columns are populated by Postgres
  `GENERATED ALWAYS AS (...) STORED`, not by Elixir code that could
  drift from the SQL definition. The Ash resource declares both as
  `writable?: false, generated?: true`, but that's a metadata
  declaration — the real proof is querying the row back via raw SQL
  and seeing that the tokens land in the right weighted slot.
  """

  use JidoClaw.SolutionsCase, async: true

  alias JidoClaw.Repo
  alias JidoClaw.Solutions.Solution

  test "search_vector and lexical_text are populated by Postgres, not Elixir" do
    tenant_id = unique_tenant_id()
    workspace = workspace_fixture(tenant_id, embedding_policy: :disabled)
    actor = actor_for(tenant_id)

    {:ok, sol} =
      Solution.store(
        %{
          problem_signature: "deploy_postgres_replica_v1",
          solution_content:
            "use pg_basebackup with streaming replication for postgres replica setup",
          language: "elixir",
          framework: "postgrex",
          tags: ["replication", "postgres"],
          workspace_id: workspace.id,
          agent_id: "agent_a",
          sharing: :local,
          embedding_status: :disabled
        },
        tenant: tenant_id,
        actor: actor
      )

    {:ok, %{rows: [[search_vec, lex]]}} =
      Repo.query(
        "SELECT search_vector::text, lexical_text FROM solutions WHERE id = $1",
        [Ecto.UUID.dump!(sol.id)]
      )

    assert is_binary(search_vec)
    assert search_vec =~ "replica"
    assert search_vec =~ "elixir"
    assert search_vec =~ "postgrex"
    assert lex =~ "pg_basebackup"
    assert lex == String.downcase(lex)

    {:ok, %{rows: [[count]]}} =
      Repo.query(
        """
        SELECT COUNT(*) FROM solutions
         WHERE id = $1
           AND search_vector @@ websearch_to_tsquery('english', $2)
        """,
        [Ecto.UUID.dump!(sol.id), "postgres replica"]
      )

    assert count == 1
  end
end
