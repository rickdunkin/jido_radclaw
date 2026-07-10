# Exercises the 3-step `20260709232715_cron_definition_fence` migration
# against POPULATED data — the risky backfill a fresh-DB DDL run never tests.
#
# NOT an ExUnit test on purpose: `config/test.exs` pins
# `Ecto.Adapters.SQL.Sandbox`, and Ecto cannot run migrations under the
# sandbox (migrations need >= 2 real connections). This drives a throwaway
# database through a temporary `DBConnection.ConnectionPool` repo instead:
#
#   1. migrate up THROUGH the prior migration (20260709223439) only;
#   2. insert a representative pre-fence `cron_jobs` row;
#   3. apply 20260709232715;
#   4. assert the pre-existing row was BACKFILLED with a non-null
#      `definition_token` AND a newly-inserted row receives the default.
#
# Run with:
#
#     mise exec -- mix run --no-start scripts/verify_cron_token_migration.exs
#
# Deliberately kept out of the `mix test` alias.

defmodule JidoClaw.CronTokenMigrationVerify do
  @moduledoc false

  defmodule Repo do
    @moduledoc false
    use Ecto.Repo, otp_app: :jido_claw, adapter: Ecto.Adapters.Postgres
  end

  @prior_version 20_260_709_223_439
  @fence_version 20_260_709_232_715

  @spec run() :: :ok
  def run do
    # `--no-start` skips the app tree; the adapter stack must be up before
    # storage_up/start_link.
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    config = build_config()
    database = Keyword.fetch!(config, :database)
    Application.put_env(:jido_claw, Repo, config)

    # Create the database BEFORE starting the repo. The `after` cleanup runs
    # only past this point, so storage_down only ever drops a database THIS
    # script created.
    case Repo.__adapter__().storage_up(config) do
      :ok -> :ok
      {:error, reason} -> raise "could not create #{database}: #{inspect(reason)}"
    end

    try do
      {:ok, _pid} = Repo.start_link()
      migrations = Path.join([File.cwd!(), "priv", "repo", "migrations"])

      Ecto.Migrator.run(Repo, migrations, :up, to: @prior_version, log: false)
      seed_pre_fence_row!()

      Ecto.Migrator.run(Repo, migrations, :up, to: @fence_version, log: false)

      verify_backfill!()
      verify_new_row_default!()

      IO.puts("OK: pre-existing row backfilled and new rows default a definition_token")
      :ok
    after
      # Stop the repo FIRST — storage_down cannot drop a database with live
      # connections.
      Repo.stop()
      _ = Repo.__adapter__().storage_down(config)
    end
  end

  defp build_config do
    base = Application.fetch_env!(:jido_claw, JidoClaw.Repo)

    database =
      "jido_claw_mig_verify_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    base
    |> Keyword.drop([:pool, :pool_size])
    |> Keyword.merge(
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      log: false
    )
  end

  defp seed_pre_fence_row! do
    # Raw SQL: at @prior_version the schema has no definition_token column
    # (and the Ash resource — which now declares it — must stay out of this).
    Repo.query!(
      "INSERT INTO tenants (id, name, status, config) VALUES ($1, $1, 'active', '{}')",
      ["mig-verify"]
    )

    Repo.query!(
      """
      INSERT INTO cron_jobs (tenant_id, job_id, schedule_kind, schedule_value, mode, task)
      VALUES ('mig-verify', 'pre-existing', 'every', '60000', 'main', 'noop')
      """,
      []
    )
  end

  defp verify_backfill! do
    %{rows: [[token]]} =
      Repo.query!(
        "SELECT definition_token FROM cron_jobs WHERE job_id = 'pre-existing'",
        []
      )

    if is_nil(token), do: raise("backfill failed: pre-existing row has a NULL definition_token")

    %{rows: [[nulls]]} =
      Repo.query!("SELECT count(*) FROM cron_jobs WHERE definition_token IS NULL", [])

    if nulls != 0, do: raise("backfill failed: #{nulls} rows left NULL")
  end

  defp verify_new_row_default! do
    %{rows: [[token]]} =
      Repo.query!(
        """
        INSERT INTO cron_jobs (tenant_id, job_id, schedule_kind, schedule_value, mode, task)
        VALUES ('mig-verify', 'post-fence', 'every', '60000', 'main', 'noop')
        RETURNING definition_token
        """,
        []
      )

    if is_nil(token), do: raise("default failed: new row has a NULL definition_token")
  end
end

JidoClaw.CronTokenMigrationVerify.run()
