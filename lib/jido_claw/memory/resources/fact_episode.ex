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

  use JidoClaw.Resource, domain: JidoClaw.Memory.Domain, primary_read_warning?: false

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

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:create_for_pair, action: :create_for_pair)
    define(:for_fact, action: :for_fact, args: [:fact_id])
    define(:by_id, action: :by_id, args: [:id], get?: true)
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
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

    read :by_id do
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :by_id_global do
      get?(true)
      multitenancy(:bypass)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
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
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
    end

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
    Validate the parent Fact and Episode share the changeset's
    tenant_id. Cross-tenant joins are rejected with
    `cross_tenant_join_mismatch`.
    """
    use Ash.Resource.Change

    alias JidoClaw.Memory.Episode
    alias JidoClaw.Memory.Fact

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        fact_id = Ash.Changeset.get_attribute(cs, :fact_id)
        episode_id = Ash.Changeset.get_attribute(cs, :episode_id)
        tenant_id = cs.tenant || Ash.Changeset.get_attribute(cs, :tenant_id)

        with {:ok, fact} <- Fact.by_id_global(fact_id),
             {:ok, episode} <- Episode.by_id_global(episode_id) do
          cond do
            fact.tenant_id != episode.tenant_id ->
              Ash.Changeset.add_error(cs,
                field: :episode_id,
                message: "cross_tenant_join_mismatch",
                vars: [
                  fact_tenant: fact.tenant_id,
                  episode_tenant: episode.tenant_id
                ]
              )

            is_binary(tenant_id) and fact.tenant_id != tenant_id ->
              Ash.Changeset.add_error(cs,
                field: :fact_id,
                message: "cross_tenant_fk_mismatch",
                vars: [supplied_tenant: tenant_id, parent_tenant: fact.tenant_id]
              )

            true ->
              cs
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
