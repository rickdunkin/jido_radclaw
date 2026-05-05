defmodule JidoClaw.Memory.FactEpisode do
  @moduledoc """
  M:N join between `Memory.Fact` and `Memory.Episode`.

  One Fact can be supported by multiple Episodes (transcript exchange
  + consolidator audit, say); one Episode can support multiple
  consolidator-promoted Facts (one cluster collapses several similar
  remembers into one canonical Fact). The `role` column distinguishes
  whether the Episode is a primary source, a supporting source, or a
  contradicting source — the consolidator uses the latter to flag
  Facts that were considered but rejected.

  ## Tenant denormalization

  `tenant_id` is denormalized from the `Fact` row at create time and
  validated against the `Episode`'s `tenant_id`. This lets queries
  filter on the join itself without joining back to either parent —
  important for the `recall` tool's "show provenance" path.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Memory.Domain,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false

  @roles [:primary, :supporting, :contradicting]

  postgres do
    table("memory_fact_episodes")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:fact_id, :role])
      index([:episode_id])
      index([:tenant_id, :inserted_at])
    end
  end

  code_interface do
    define(:create_for_pair, action: :create_for_pair)
    define(:for_fact, action: :for_fact, args: [:fact_id])
  end

  actions do
    defaults([:read])

    create :create_for_pair do
      primary?(true)
      accept([:fact_id, :episode_id, :role])

      change({__MODULE__.Changes.DenormalizeTenant, []})
    end

    read :for_fact do
      argument(:fact_id, :uuid, allow_nil?: false)
      filter(expr(fact_id == ^arg(:fact_id)))
      prepare(build(sort: [inserted_at: :desc]))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :fact_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :episode_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :role, :atom do
      allow_nil?(false)
      public?(true)
      default(:primary)
      constraints(one_of: @roles)
    end

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end
  end

  relationships do
    belongs_to :fact, JidoClaw.Memory.Fact do
      define_attribute?(false)
      attribute_writable?(true)
    end

    belongs_to :episode, JidoClaw.Memory.Episode do
      define_attribute?(false)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_pair, [:fact_id, :episode_id])
  end

  defmodule Changes.DenormalizeTenant do
    @moduledoc """
    Copy `tenant_id` from the parent Fact row, then validate it against
    the parent Episode row's `tenant_id`. Cross-tenant joins are
    rejected with a `cross_tenant_join_mismatch` error.
    """
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        fact_id = Ash.Changeset.get_attribute(cs, :fact_id)
        episode_id = Ash.Changeset.get_attribute(cs, :episode_id)

        with {:ok, fact} <-
               Ash.get(JidoClaw.Memory.Fact, fact_id, domain: JidoClaw.Memory.Domain),
             {:ok, episode} <-
               Ash.get(JidoClaw.Memory.Episode, episode_id, domain: JidoClaw.Memory.Domain) do
          if fact.tenant_id == episode.tenant_id do
            Ash.Changeset.force_change_attribute(cs, :tenant_id, fact.tenant_id)
          else
            Ash.Changeset.add_error(cs,
              field: :episode_id,
              message: "cross_tenant_join_mismatch",
              vars: [
                fact_tenant: fact.tenant_id,
                episode_tenant: episode.tenant_id
              ]
            )
          end
        else
          {:error, _} ->
            Ash.Changeset.add_error(cs,
              field: :fact_id,
              message: "fact_or_episode_not_found"
            )
        end
      end)
    end
  end
end
