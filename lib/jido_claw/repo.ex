defmodule JidoClaw.Repo do
  use AshPostgres.Repo,
    otp_app: :jido_claw

  # `use AshPostgres.Repo` injects a raise-only `all_tenants/0`. This project
  # uses attribute multitenancy so the function is never called; override if
  # migrating to schema-based tenants.
  @dialyzer {:nowarn_function, all_tenants: 0}

  # POOL_SIZE rides through config/runtime.exs as a RAW string (runtime.exs
  # is total/configure-only — a config-eval String.to_integer would break
  # the escript's pre-boot `--third-party-licenses` guarantee); the parse
  # happens here, at Repo startup. CHAINS super/2 — AshPostgres.Repo's
  # init/2 injects installed_extensions/migrations_path/default_prefix
  # configuration an outright override would silently discard.
  @impl Ecto.Repo
  def init(type, config) do
    {:ok, config} = super(type, config)
    {:ok, parse_pool_size(config)}
  end

  defp parse_pool_size(config) do
    case Keyword.fetch(config, :pool_size) do
      {:ok, value} when is_binary(value) ->
        case Integer.parse(value) do
          {size, ""} when size > 0 ->
            Keyword.put(config, :pool_size, size)

          _junk ->
            raise ArgumentError,
                  "POOL_SIZE must be a positive integer, got: #{inspect(value)}"
        end

      _absent_or_already_integer ->
        config
    end
  end

  @impl AshPostgres.Repo
  def installed_extensions do
    ["ash-functions", "citext", "pg_trgm", "pgcrypto", "vector"]
  end

  @impl AshPostgres.Repo
  def prefer_transaction? do
    false
  end

  @impl AshPostgres.Repo
  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
