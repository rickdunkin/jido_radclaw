defmodule JidoClaw.Repo.V064bMigrationShapeTest do
  @moduledoc """
  Pin the v064b companion migration's shape. The migration body is
  the contract — it must promote each tenant FK using the staged
  `NOT VALID` + `VALIDATE CONSTRAINT` form (plan §4.2), not the
  one-shot validated form that `v064_audit_tenant` shipped.

  Per-table position capture is load-bearing here. A bare
  `:binary.match/2` would find the first global `"NOT VALID"`
  occurrence regardless of which table's constraint it belongs to,
  so a single-direction order assertion could pass spuriously.
  `Regex.run(..., return: :index)` returns the position of THIS
  table's NOT VALID add and THIS table's VALIDATE, so the test
  catches a regression where any single table is mis-staged.
  """

  use ExUnit.Case, async: true

  @migration_glob "priv/repo/migrations/*_v064b_tenant_fk_staged.exs"

  @tables ~w(
    messages
    solutions
    memory_links
    reputation_imports
    audit_events
    workspaces
    request_correlations
    conversation_sessions
    memory_facts
    memory_consolidation_runs
    memory_episodes
    cron_jobs
    reputations
    memory_block_revisions
    memory_fact_episodes
    memory_blocks
  )

  setup_all do
    [path] = Path.wildcard(@migration_glob)
    {:ok, source: File.read!(path)}
  end

  test "DDL transaction is disabled", %{source: src} do
    assert src =~ "@disable_ddl_transaction true"
  end

  test "every tenant FK is added NOT VALID then VALIDATEd in correct order",
       %{source: src} do
    for table <- @tables do
      add_re =
        ~r/ADD\s+CONSTRAINT\s+#{table}_tenant_id_fkey\s+FOREIGN\s+KEY\s*\(\s*tenant_id\s*\)\s+REFERENCES\s+tenants\s*\(\s*id\s*\)\s+NOT\s+VALID/

      validate_re = ~r/VALIDATE\s+CONSTRAINT\s+#{table}_tenant_id_fkey/

      add_match = Regex.run(add_re, src, return: :index)
      validate_match = Regex.run(validate_re, src, return: :index)

      assert add_match,
             "missing 'ADD CONSTRAINT #{table}_tenant_id_fkey ... NOT VALID' in migration"

      assert validate_match,
             "missing 'VALIDATE CONSTRAINT #{table}_tenant_id_fkey' in migration"

      {add_pos, _} = hd(add_match)
      {validate_pos, _} = hd(validate_match)

      assert add_pos < validate_pos,
             "VALIDATE appears before NOT VALID add for table #{table}"
    end
  end

  test "drop and re-add are in the same ALTER TABLE statement per table",
       %{source: src} do
    for table <- @tables do
      atomic_re =
        ~r/ALTER\s+TABLE\s+#{table}\s+DROP\s+CONSTRAINT\s+#{table}_tenant_id_fkey\s*,\s*ADD\s+CONSTRAINT\s+#{table}_tenant_id_fkey\s+FOREIGN\s+KEY\s*\(\s*tenant_id\s*\)\s+REFERENCES\s+tenants\s*\(\s*id\s*\)\s+NOT\s+VALID/

      assert Regex.match?(atomic_re, src),
             "drop+add for #{table} must be in one atomic ALTER TABLE — separate execute calls leave a window with no FK"
    end
  end
end
