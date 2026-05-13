defmodule JidoClaw.Audit.Event do
  @moduledoc """
  Append-only audit row.

  One row per audited action: who (`actor_kind` + `actor_id`), what
  (`event_kind`), against what (`target_kind` + `target_id`), under
  which tenant. `payload` carries action-specific context (request
  ids, signatures, sharing state).

  No `:update`, no `:destroy` — append-only is the contract.
  Cross-tenant FK validation is best-effort: a `before_action` hook
  consults the dispatch map at module level; targets in the map are
  validated via the matching `:by_id_global` action, targets outside
  the map skip with telemetry.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  require Ash.Query

  alias Ash.Changeset

  @event_kinds [
    :memory_write,
    :memory_consolidation,
    :solution_share,
    :session_start,
    :session_end,
    :tool_call,
    :auth_event,
    :policy_denied
  ]

  @actor_kinds [:user, :agent, :system]

  @target_kinds [
    :workspace,
    :session,
    :message,
    :solution,
    :memory_block,
    :memory_fact,
    :memory_episode,
    :memory_link,
    :memory_consolidation_run,
    :reputation,
    :cron_job,
    :tool,
    :auth
  ]

  # Dispatch map for cross-tenant FK validation. Keys are target_kinds
  # whose target_id refers to a tenanted parent; values name the
  # parent module that defines a `:by_id_global` action. Targets outside
  # the map skip validation with telemetry.
  @target_dispatch %{
    workspace: JidoClaw.Workspaces.Workspace,
    session: JidoClaw.Conversations.Session,
    message: JidoClaw.Conversations.Message,
    solution: JidoClaw.Solutions.Solution,
    memory_block: JidoClaw.Memory.Block,
    memory_fact: JidoClaw.Memory.Fact,
    memory_episode: JidoClaw.Memory.Episode,
    memory_link: JidoClaw.Memory.Link,
    memory_consolidation_run: JidoClaw.Memory.ConsolidationRun,
    reputation: JidoClaw.Solutions.Reputation,
    cron_job: JidoClaw.Cron.Job
  }

  postgres do
    table("audit_events")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :event_kind, :inserted_at])
      index([:tenant_id, :actor_kind, :actor_id, :inserted_at])
      index([:tenant_id, :target_kind, :target_id, :inserted_at])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  policies do
    # Tenant-actor matching for both creates and reads. The
    # AsyncWriter (Audit.Producers, SignalListener) bypasses with
    # `authorize?: false` since it operates as internal infrastructure
    # — the audit row's tenant is already established by the producer
    # action's tenant: opt.
    policy action_type(:create) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type(:read) do
      authorize_if(expr(tenant_id == ^actor(:tenant_id)))
    end
  end

  code_interface do
    define(:record, action: :record)
    define(:read, action: :read)
    define(:for_target, action: :for_target, args: [:target_kind, :target_id])
    define(:for_actor, action: :for_actor, args: [:actor_kind, :actor_id])
  end

  actions do
    defaults([:read])

    create :record do
      primary?(true)

      accept([
        :event_kind,
        :actor_kind,
        :actor_id,
        :target_kind,
        :target_id,
        :payload
      ])

      change({__MODULE__.Changes.ValidateCrossTenantTarget, []})
    end

    read :for_target do
      argument(:target_kind, :atom, allow_nil?: false, constraints: [one_of: @target_kinds])
      argument(:target_id, :string, allow_nil?: false)

      filter(expr(target_kind == ^arg(:target_kind) and target_id == ^arg(:target_id)))
      prepare(build(sort: [inserted_at: :desc]))
    end

    read :for_actor do
      argument(:actor_kind, :atom, allow_nil?: false, constraints: [one_of: @actor_kinds])
      argument(:actor_id, :string, allow_nil?: false)

      filter(expr(actor_kind == ^arg(:actor_kind) and actor_id == ^arg(:actor_id)))
      prepare(build(sort: [inserted_at: :desc]))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :event_kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @event_kinds)
    end

    attribute :actor_kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @actor_kinds)
    end

    attribute :actor_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :target_kind, :atom do
      allow_nil?(true)
      public?(true)
      constraints(one_of: @target_kinds)
    end

    attribute :target_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :payload, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
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
  end

  @doc false
  def target_dispatch, do: @target_dispatch

  defmodule Changes.ValidateCrossTenantTarget do
    @moduledoc false
    use Ash.Resource.Change

    alias JidoClaw.Audit.Event

    @impl true
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        target_kind = Changeset.get_attribute(cs, :target_kind)
        target_id = Changeset.get_attribute(cs, :target_id)
        tenant_id = cs.tenant || Changeset.get_attribute(cs, :tenant_id)

        validate(cs, target_kind, target_id, tenant_id)
      end)
    end

    defp validate(cs, _kind, nil, _tenant), do: cs
    defp validate(cs, nil, _id, _tenant), do: cs
    defp validate(cs, _kind, _id, nil), do: cs

    defp validate(cs, target_kind, target_id, tenant_id) do
      case Map.get(Event.target_dispatch(), target_kind) do
        nil ->
          :telemetry.execute(
            [:jido_claw, :audit, :cross_tenant_fk, :skipped],
            %{},
            %{
              target_kind: target_kind,
              reason: :tenant_validation_skipped_for_untenanted_parent
            }
          )

          cs

        parent_module ->
          do_validate(cs, parent_module, target_kind, target_id, tenant_id)
      end
    end

    defp do_validate(cs, parent_module, target_kind, target_id, tenant_id) do
      parsed_id =
        case parent_module do
          JidoClaw.Cron.Job ->
            target_id

          _ ->
            case Ecto.UUID.cast(target_id) do
              {:ok, uuid} -> uuid
              :error -> target_id
            end
        end

      case parent_module.by_id_global(parsed_id) do
        {:ok, %{tenant_id: ^tenant_id}} ->
          cs

        {:ok, %{tenant_id: parent_tenant}} ->
          Changeset.add_error(cs,
            field: :target_id,
            message: "cross_tenant_fk_mismatch",
            vars: [
              target_kind: target_kind,
              supplied_tenant: tenant_id,
              parent_tenant: parent_tenant
            ]
          )

        {:error, _} ->
          # Parent missing isn't fatal for audit — operator may be
          # auditing a row whose persistence failed elsewhere. Skip
          # silently with telemetry.
          :telemetry.execute(
            [:jido_claw, :audit, :cross_tenant_fk, :parent_missing],
            %{},
            %{target_kind: target_kind, target_id: target_id}
          )

          cs
      end
    end
  end
end
