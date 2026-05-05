defmodule JidoClaw.Repo.Migrations.SyncResourceSnapshots do
  @moduledoc """
  Idempotent migration that adds FK constraints and indexes declared in
  Ash resource definitions but missing from earlier historical migrations.

  Uses `IF NOT EXISTS` checks so it is safe on both fresh databases
  (constraints absent) and existing databases (constraints already present).
  """

  use Ecto.Migration

  def up do
    # -- Foreign key constraints (idempotent via pg_constraint check) ----------

    add_fk_if_missing("workflow_runs", "user_id", "users", "workflow_runs_user_id_fkey")
    add_fk_if_missing("workflow_runs", "project_id", "projects", "workflow_runs_project_id_fkey")
    add_fk_if_missing("secret_refs", "user_id", "users", "secret_refs_user_id_fkey")

    add_fk_if_missing(
      "github_issue_analyses",
      "project_id",
      "projects",
      "github_issue_analyses_project_id_fkey"
    )

    add_fk_if_missing("folio_projects", "user_id", "users", "folio_projects_user_id_fkey")
    add_fk_if_missing("folio_inbox_items", "user_id", "users", "folio_inbox_items_user_id_fkey")

    add_fk_if_missing(
      "folio_actions",
      "project_id",
      "folio_projects",
      "folio_actions_project_id_fkey"
    )

    add_fk_if_missing("folio_actions", "user_id", "users", "folio_actions_user_id_fkey")

    add_fk_if_missing(
      "approval_gates",
      "requested_by_id",
      "users",
      "approval_gates_requested_by_id_fkey"
    )

    # -- Indexes (create_if_not_exists is built-in) ----------------------------

    create_if_not_exists(index(:workflow_runs, [:user_id]))
    create_if_not_exists(index(:workflow_runs, [:project_id]))
    create_if_not_exists(index(:secret_refs, [:user_id]))
    create_if_not_exists(index(:github_issue_analyses, [:project_id]))
    create_if_not_exists(index(:folio_projects, [:user_id]))
    create_if_not_exists(index(:folio_inbox_items, [:user_id]))
    create_if_not_exists(index(:folio_actions, [:project_id]))
    create_if_not_exists(index(:folio_actions, [:user_id]))
    create_if_not_exists(index(:approval_gates, [:requested_by_id]))
  end

  def down do
    drop_if_exists(index(:approval_gates, [:requested_by_id]))
    drop_if_exists(index(:folio_actions, [:user_id]))
    drop_if_exists(index(:folio_actions, [:project_id]))
    drop_if_exists(index(:folio_inbox_items, [:user_id]))
    drop_if_exists(index(:folio_projects, [:user_id]))
    drop_if_exists(index(:github_issue_analyses, [:project_id]))
    drop_if_exists(index(:secret_refs, [:user_id]))
    drop_if_exists(index(:workflow_runs, [:project_id]))
    drop_if_exists(index(:workflow_runs, [:user_id]))

    execute(
      "ALTER TABLE approval_gates DROP CONSTRAINT IF EXISTS approval_gates_requested_by_id_fkey"
    )

    execute("ALTER TABLE folio_actions DROP CONSTRAINT IF EXISTS folio_actions_user_id_fkey")
    execute("ALTER TABLE folio_actions DROP CONSTRAINT IF EXISTS folio_actions_project_id_fkey")

    execute(
      "ALTER TABLE folio_inbox_items DROP CONSTRAINT IF EXISTS folio_inbox_items_user_id_fkey"
    )

    execute("ALTER TABLE folio_projects DROP CONSTRAINT IF EXISTS folio_projects_user_id_fkey")

    execute(
      "ALTER TABLE github_issue_analyses DROP CONSTRAINT IF EXISTS github_issue_analyses_project_id_fkey"
    )

    execute("ALTER TABLE secret_refs DROP CONSTRAINT IF EXISTS secret_refs_user_id_fkey")
    execute("ALTER TABLE workflow_runs DROP CONSTRAINT IF EXISTS workflow_runs_project_id_fkey")
    execute("ALTER TABLE workflow_runs DROP CONSTRAINT IF EXISTS workflow_runs_user_id_fkey")
  end

  defp add_fk_if_missing(table, column, ref_table, constraint_name) do
    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = '#{constraint_name}'
      ) THEN
        ALTER TABLE #{table}
          ADD CONSTRAINT #{constraint_name}
          FOREIGN KEY (#{column}) REFERENCES #{ref_table}(id);
      END IF;
    END $$;
    """)
  end
end
