defmodule JidoClaw.Solutions.Reputation do
  @moduledoc """
  Per-`(tenant_id, agent_id)` reputation entry.

  Mirrors the v0.5.x ETS+JSONL `Solutions.Reputation` GenServer fields
  but keys on `(tenant_id, agent_id)` (the legacy GenServer was per-
  project, untenanted) and persists to Postgres so the cluster shares
  one corpus.

  ## Atomicity

  All counter writes (`record_success/2`, `record_failure/2`,
  `record_share/2`) are exposed as **plain module functions** rather
  than Ash update actions, because Ash update actions require an
  existing record to act on, and the v0.6.x semantics are
  "upsert-if-missing then increment-the-counter under FOR UPDATE."
  Each function wraps a single `Repo.transaction` with `SELECT ...
  FOR UPDATE` on the row to prevent lost updates. Pessimistic
  locking is correct here — reputation writes happen at human
  cadence, not millisecond contention.

  Reads (`get/2`, `top/2`) are normal Ash code-interface calls.

  ## Score formula

  Lifted verbatim from the legacy private `recalculate_score/1` (the
  GenServer at `lib/jido_claw/solutions/reputation.ex:237-253` before
  this rewrite):

      success_rate    = verified / max(1, verified + failed)
      activity_bonus  = min(0.1, shared * 0.01)
      freshness       = 1.0 if last_active within 30 days, else decays to 0.0 by day 60
      score           = 0.5 * 0.3 + success_rate * 0.5 + activity_bonus + freshness * 0.1

  Result clamped to `0.0..1.0`. The 0.15 baseline (`0.5 * 0.3`) is
  preserved exactly.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Solutions.Domain,
    data_layer: AshPostgres.DataLayer

  alias JidoClaw.Repo

  postgres do
    table("reputations")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :score])
    end
  end

  code_interface do
    define(:get, action: :get, args: [:tenant_id, :agent_id], get?: true)
    define(:upsert, action: :upsert)
    define(:top, action: :top, args: [:tenant_id])
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      primary?(true)
      upsert?(true)
      upsert_identity(:unique_tenant_agent)

      upsert_fields([
        :score,
        :solutions_verified,
        :solutions_failed,
        :solutions_shared,
        :last_active,
        :updated_at
      ])

      accept([
        :tenant_id,
        :agent_id,
        :score,
        :solutions_verified,
        :solutions_failed,
        :solutions_shared,
        :last_active
      ])
    end

    read :get do
      get?(true)
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:agent_id, :string, allow_nil?: false)

      filter(expr(tenant_id == ^arg(:tenant_id) and agent_id == ^arg(:agent_id)))
    end

    read :top do
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:limit, :integer, allow_nil?: true, default: 10)

      filter(expr(tenant_id == ^arg(:tenant_id)))
      prepare(build(sort: [score: :desc]))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :agent_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :score, :float do
      allow_nil?(false)
      public?(true)
      default(0.5)
    end

    attribute :solutions_verified, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :solutions_failed, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :solutions_shared, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :last_active, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  identities do
    identity(:unique_tenant_agent, [:tenant_id, :agent_id])
  end

  # ---------------------------------------------------------------------------
  # Atomic counter-write functions — bypass the Ash update pipeline so we can
  # express FOR UPDATE inside Repo.transaction.
  # ---------------------------------------------------------------------------

  @counter_keys [:solutions_verified, :solutions_failed, :solutions_shared]

  @doc "Increment `:solutions_verified`, recompute score, persist."
  @spec record_success(String.t(), String.t()) :: :ok | {:error, term()}
  def record_success(tenant_id, agent_id),
    do: bump_counter(tenant_id, agent_id, :solutions_verified)

  @doc "Increment `:solutions_failed`, recompute score, persist."
  @spec record_failure(String.t(), String.t()) :: :ok | {:error, term()}
  def record_failure(tenant_id, agent_id),
    do: bump_counter(tenant_id, agent_id, :solutions_failed)

  @doc "Increment `:solutions_shared`, recompute score, persist."
  @spec record_share(String.t(), String.t()) :: :ok | {:error, term()}
  def record_share(tenant_id, agent_id),
    do: bump_counter(tenant_id, agent_id, :solutions_shared)

  defp bump_counter(tenant_id, agent_id, counter)
       when is_binary(tenant_id) and is_binary(agent_id) and counter in @counter_keys do
    case Repo.transaction(fn ->
           ensure_row(tenant_id, agent_id)
           row = lock_row!(tenant_id, agent_id)
           updated = increment_and_recompute(row, counter)
           write_row!(updated)

           JidoClaw.SignalBus.emit("jido_claw.reputation.updated", %{
             tenant_id: tenant_id,
             agent_id: agent_id,
             score: updated.score
           })

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_row(tenant_id, agent_id) do
    Repo.query!(
      """
      INSERT INTO reputations
        (id, tenant_id, agent_id, score, solutions_verified, solutions_failed,
         solutions_shared, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), $1, $2, 0.5, 0, 0, 0,
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      ON CONFLICT (tenant_id, agent_id) DO NOTHING
      """,
      [tenant_id, agent_id]
    )
  end

  defp lock_row!(tenant_id, agent_id) do
    %Postgrex.Result{rows: [row]} =
      Repo.query!(
        """
        SELECT id, tenant_id, agent_id, score, solutions_verified, solutions_failed,
               solutions_shared, last_active
          FROM reputations
         WHERE tenant_id = $1 AND agent_id = $2
         FOR UPDATE
        """,
        [tenant_id, agent_id]
      )

    [id, t_id, a_id, score, verified, failed, shared, last_active] = row

    %{
      id: id,
      tenant_id: t_id,
      agent_id: a_id,
      score: score,
      solutions_verified: verified,
      solutions_failed: failed,
      solutions_shared: shared,
      last_active: last_active
    }
  end

  defp increment_and_recompute(row, counter) do
    bumped = Map.update!(row, counter, &(&1 + 1))
    score = compute_score(bumped)
    %{bumped | score: score, last_active: DateTime.utc_now()}
  end

  defp write_row!(row) do
    Repo.query!(
      """
      UPDATE reputations
         SET score = $3,
             solutions_verified = $4,
             solutions_failed = $5,
             solutions_shared = $6,
             last_active = $7,
             updated_at = now() AT TIME ZONE 'utc'
       WHERE tenant_id = $1 AND agent_id = $2
      """,
      [
        row.tenant_id,
        row.agent_id,
        row.score,
        row.solutions_verified,
        row.solutions_failed,
        row.solutions_shared,
        row.last_active
      ]
    )
  end

  # ---------------------------------------------------------------------------
  # Score computation — public so the change module can call it on a
  # plain map. Lifted verbatim from the legacy private recalculate_score/1.
  # ---------------------------------------------------------------------------

  @doc """
  Recompute `:score` from the entry's counters.

  Accepts any map with `:solutions_verified`, `:solutions_failed`,
  `:solutions_shared`, and `:last_active`. Returns a float clamped to
  `0.0..1.0`. The 0.15 baseline (`0.5 * 0.3`) is preserved exactly.
  """
  @spec compute_score(map()) :: float()
  def compute_score(%{
        solutions_verified: verified,
        solutions_failed: failed,
        solutions_shared: shared,
        last_active: last_active
      }) do
    success_rate = verified / max(1, verified + failed)
    activity_bonus = min(0.1, shared * 0.01)
    freshness = freshness_score(last_active)

    raw = 0.5 * 0.3 + success_rate * 0.5 + activity_bonus + freshness * 0.1
    raw |> max(0.0) |> min(1.0)
  end

  defp freshness_score(nil), do: 0.0

  defp freshness_score(%DateTime{} = dt) do
    age_days = DateTime.diff(DateTime.utc_now(), dt, :second) / 86_400.0

    cond do
      age_days <= 30 -> 1.0
      true -> max(0.0, 1.0 - (age_days - 30) / 30)
    end
  end

  defp freshness_score(other) when is_binary(other) do
    case DateTime.from_iso8601(other) do
      {:ok, dt, _} -> freshness_score(dt)
      _ -> 0.0
    end
  end

  defp freshness_score(_), do: 0.0
end
