defmodule JidoClaw.Repo do
  use AshPostgres.Repo,
    otp_app: :jido_claw

  # `use AshPostgres.Repo` injects a raise-only `all_tenants/0`. This project
  # uses attribute multitenancy so the function is never called; override if
  # migrating to schema-based tenants.
  @dialyzer {:nowarn_function, all_tenants: 0}

  @impl true
  def installed_extensions do
    ["ash-functions", "citext", "pg_trgm", "pgcrypto", "vector"]
  end

  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
