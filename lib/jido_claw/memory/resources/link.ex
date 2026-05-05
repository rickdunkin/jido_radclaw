defmodule JidoClaw.Memory.Link do
  @moduledoc """
  Directed graph edge between two `Memory.Fact` rows in the same scope.

  Relations:

    * `:supports`        — A reinforces B
    * `:contradicts`     — A directly contradicts B
    * `:supersedes`      — A replaces B (B should be deprioritized)
    * `:duplicates`      — A is a near-duplicate of B
    * `:depends_on`      — A only makes sense given B
    * `:related`         — generic association (consolidator-friendly)

  ## Cross-tenant + cross-scope rejection

  `from_fact_id` and `to_fact_id` must point at Facts in the same
  tenant AND the same scope (kind + fk). Cross-tenant edges leak
  signal across customer boundaries; cross-scope edges leak signal
  across user/workspace/project/session boundaries within a tenant.
  Both are hard rejections in `before_action`.

  Capacity gate: the consolidator's max-links cap (5 per source Fact)
  is enforced at the consolidator's staging-buffer step, NOT here —
  the resource doesn't know whether two writers' simultaneous link
  inserts should converge or fail.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Memory.Domain,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false

  @relations [:supports, :contradicts, :supersedes, :duplicates, :depends_on, :related]
  @scope_kinds [:user, :workspace, :project, :session]

  postgres do
    table("memory_links")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :from_fact_id, :relation])
      index([:tenant_id, :to_fact_id, :relation])
    end
  end

  code_interface do
    define(:create_link, action: :create_link)
    define(:for_fact, action: :for_fact, args: [:fact_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create_link do
      primary?(true)

      accept([
        :from_fact_id,
        :to_fact_id,
        :relation,
        :reason,
        :confidence,
        :written_by
      ])

      change({__MODULE__.Changes.ValidateScopeAndDenormalize, []})
    end

    read :for_fact do
      argument(:fact_id, :uuid, allow_nil?: false)

      filter(expr(from_fact_id == ^arg(:fact_id) or to_fact_id == ^arg(:fact_id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :from_fact_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :to_fact_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :scope_kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @scope_kinds)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :workspace_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :project_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :session_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :relation, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @relations)
    end

    attribute :reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :confidence, :float do
      allow_nil?(true)
      public?(true)
    end

    attribute :written_by, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end
  end

  relationships do
    belongs_to :from_fact, JidoClaw.Memory.Fact do
      source_attribute(:from_fact_id)
      define_attribute?(false)
      attribute_writable?(true)
    end

    belongs_to :to_fact, JidoClaw.Memory.Fact do
      source_attribute(:to_fact_id)
      define_attribute?(false)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_edge, [:from_fact_id, :to_fact_id, :relation])
  end

  defmodule Changes.ValidateScopeAndDenormalize do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        from_id = Ash.Changeset.get_attribute(cs, :from_fact_id)
        to_id = Ash.Changeset.get_attribute(cs, :to_fact_id)

        with {:ok, from_fact} <-
               Ash.get(JidoClaw.Memory.Fact, from_id, domain: JidoClaw.Memory.Domain),
             {:ok, to_fact} <-
               Ash.get(JidoClaw.Memory.Fact, to_id, domain: JidoClaw.Memory.Domain) do
          validate_scopes(cs, from_fact, to_fact)
        else
          {:error, _} ->
            Ash.Changeset.add_error(cs,
              field: :from_fact_id,
              message: "fact_not_found"
            )
        end
      end)
    end

    defp validate_scopes(cs, from_fact, to_fact) do
      cond do
        from_fact.tenant_id != to_fact.tenant_id ->
          Ash.Changeset.add_error(cs,
            field: :to_fact_id,
            message: "cross_tenant_link",
            vars: [from_tenant: from_fact.tenant_id, to_tenant: to_fact.tenant_id]
          )

        not same_scope?(from_fact, to_fact) ->
          Ash.Changeset.add_error(cs,
            field: :to_fact_id,
            message: "cross_scope_link",
            vars: [
              from_scope: {from_fact.scope_kind, scope_fk(from_fact)},
              to_scope: {to_fact.scope_kind, scope_fk(to_fact)}
            ]
          )

        true ->
          cs
          |> Ash.Changeset.force_change_attribute(:tenant_id, from_fact.tenant_id)
          |> Ash.Changeset.force_change_attribute(:scope_kind, from_fact.scope_kind)
          |> Ash.Changeset.force_change_attribute(:user_id, from_fact.user_id)
          |> Ash.Changeset.force_change_attribute(:workspace_id, from_fact.workspace_id)
          |> Ash.Changeset.force_change_attribute(:project_id, from_fact.project_id)
          |> Ash.Changeset.force_change_attribute(:session_id, from_fact.session_id)
      end
    end

    defp same_scope?(a, b) do
      a.scope_kind == b.scope_kind and scope_fk(a) == scope_fk(b)
    end

    defp scope_fk(%{scope_kind: :user, user_id: id}), do: id
    defp scope_fk(%{scope_kind: :workspace, workspace_id: id}), do: id
    defp scope_fk(%{scope_kind: :project, project_id: id}), do: id
    defp scope_fk(%{scope_kind: :session, session_id: id}), do: id
    defp scope_fk(_), do: nil
  end
end
