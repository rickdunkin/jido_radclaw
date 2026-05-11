defmodule JidoClaw.Repo.Migrations.V064bTenantFkStaged do
  @moduledoc """
  Companion follow-up to `v064_audit_tenant`: drop + re-add each of
  the 16 tenant FKs in the **staged** `NOT VALID` + `VALIDATE
  CONSTRAINT` shape required by plan §4.2.

  The earlier `v064_audit_tenant` migration promoted these columns to
  validated `references(:tenants, ...)` FKs in one shot. That
  acquired `ACCESS EXCLUSIVE LOCK` while Postgres scanned every row
  to validate the constraint — fine on an empty dev database, but
  unacceptable online.

  The staged form:

    1. Atomically `DROP CONSTRAINT ... ADD CONSTRAINT ... NOT VALID` —
       briefly holds `ACCESS EXCLUSIVE` for the FK metadata change,
       no row scan.
    2. Separately `VALIDATE CONSTRAINT` — holds `SHARE UPDATE
       EXCLUSIVE`, doesn't block reads or writes. The validation
       scan runs concurrently.

  ## DDL transaction disabled

  Ecto wraps each migration in a transaction by default. If both
  steps ran in the same transaction, the lock held by the
  drop+add would block reads until commit (defeating the
  online-migration goal). `@disable_ddl_transaction true` lets each
  `execute/1` commit independently so the validate doesn't extend
  the drop+add window.

  ## Atomicity

  Each table's drop+add lives in **one** `ALTER TABLE` statement.
  Splitting them into two `execute/1` calls would leave the table
  briefly without an FK — small window, but visible to concurrent
  writers, and an avoidable invariant gap. The shape test in
  `test/jido_claw/repo/v064b_migration_shape_test.exs` pins this.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

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

  def up do
    execute("""
    ALTER TABLE messages
      DROP CONSTRAINT messages_tenant_id_fkey,
      ADD CONSTRAINT messages_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE messages VALIDATE CONSTRAINT messages_tenant_id_fkey")

    execute("""
    ALTER TABLE solutions
      DROP CONSTRAINT solutions_tenant_id_fkey,
      ADD CONSTRAINT solutions_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE solutions VALIDATE CONSTRAINT solutions_tenant_id_fkey")

    execute("""
    ALTER TABLE memory_links
      DROP CONSTRAINT memory_links_tenant_id_fkey,
      ADD CONSTRAINT memory_links_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE memory_links VALIDATE CONSTRAINT memory_links_tenant_id_fkey")

    execute("""
    ALTER TABLE reputation_imports
      DROP CONSTRAINT reputation_imports_tenant_id_fkey,
      ADD CONSTRAINT reputation_imports_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute(
      "ALTER TABLE reputation_imports VALIDATE CONSTRAINT reputation_imports_tenant_id_fkey"
    )

    execute("""
    ALTER TABLE audit_events
      DROP CONSTRAINT audit_events_tenant_id_fkey,
      ADD CONSTRAINT audit_events_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE audit_events VALIDATE CONSTRAINT audit_events_tenant_id_fkey")

    execute("""
    ALTER TABLE workspaces
      DROP CONSTRAINT workspaces_tenant_id_fkey,
      ADD CONSTRAINT workspaces_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE workspaces VALIDATE CONSTRAINT workspaces_tenant_id_fkey")

    execute("""
    ALTER TABLE request_correlations
      DROP CONSTRAINT request_correlations_tenant_id_fkey,
      ADD CONSTRAINT request_correlations_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute(
      "ALTER TABLE request_correlations VALIDATE CONSTRAINT request_correlations_tenant_id_fkey"
    )

    execute("""
    ALTER TABLE conversation_sessions
      DROP CONSTRAINT conversation_sessions_tenant_id_fkey,
      ADD CONSTRAINT conversation_sessions_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute(
      "ALTER TABLE conversation_sessions VALIDATE CONSTRAINT conversation_sessions_tenant_id_fkey"
    )

    execute("""
    ALTER TABLE memory_facts
      DROP CONSTRAINT memory_facts_tenant_id_fkey,
      ADD CONSTRAINT memory_facts_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE memory_facts VALIDATE CONSTRAINT memory_facts_tenant_id_fkey")

    execute("""
    ALTER TABLE memory_consolidation_runs
      DROP CONSTRAINT memory_consolidation_runs_tenant_id_fkey,
      ADD CONSTRAINT memory_consolidation_runs_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute(
      "ALTER TABLE memory_consolidation_runs VALIDATE CONSTRAINT memory_consolidation_runs_tenant_id_fkey"
    )

    execute("""
    ALTER TABLE memory_episodes
      DROP CONSTRAINT memory_episodes_tenant_id_fkey,
      ADD CONSTRAINT memory_episodes_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE memory_episodes VALIDATE CONSTRAINT memory_episodes_tenant_id_fkey")

    execute("""
    ALTER TABLE cron_jobs
      DROP CONSTRAINT cron_jobs_tenant_id_fkey,
      ADD CONSTRAINT cron_jobs_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE cron_jobs VALIDATE CONSTRAINT cron_jobs_tenant_id_fkey")

    execute("""
    ALTER TABLE reputations
      DROP CONSTRAINT reputations_tenant_id_fkey,
      ADD CONSTRAINT reputations_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE reputations VALIDATE CONSTRAINT reputations_tenant_id_fkey")

    execute("""
    ALTER TABLE memory_block_revisions
      DROP CONSTRAINT memory_block_revisions_tenant_id_fkey,
      ADD CONSTRAINT memory_block_revisions_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute(
      "ALTER TABLE memory_block_revisions VALIDATE CONSTRAINT memory_block_revisions_tenant_id_fkey"
    )

    execute("""
    ALTER TABLE memory_fact_episodes
      DROP CONSTRAINT memory_fact_episodes_tenant_id_fkey,
      ADD CONSTRAINT memory_fact_episodes_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute(
      "ALTER TABLE memory_fact_episodes VALIDATE CONSTRAINT memory_fact_episodes_tenant_id_fkey"
    )

    execute("""
    ALTER TABLE memory_blocks
      DROP CONSTRAINT memory_blocks_tenant_id_fkey,
      ADD CONSTRAINT memory_blocks_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) NOT VALID
    """)

    execute("ALTER TABLE memory_blocks VALIDATE CONSTRAINT memory_blocks_tenant_id_fkey")
  end

  def down do
    # Restore the one-shot validated form matching v064's post-state.
    Enum.each(@tables, fn table ->
      fk = "#{table}_tenant_id_fkey"

      execute("""
      ALTER TABLE #{table}
        DROP CONSTRAINT #{fk},
        ADD CONSTRAINT #{fk}
          FOREIGN KEY (tenant_id) REFERENCES tenants(id)
      """)
    end)
  end
end
