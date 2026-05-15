defmodule JidoClaw.Memory.Episode do
  @moduledoc """
  Immutable provenance row linking a Fact (or a future Block revision)
  to its source — typically a `Conversations.Message` ID or a
  `Solutions.Solution` ID.

  Episodes are append-only: no bitemporal columns, no `:update`,
  no `:destroy`. The lifecycle is "record once, link many" —
  `Memory.FactEpisode` joins map a single Episode to all the Facts it
  produced (e.g. one transcript exchange might support three
  consolidator-promoted Facts).

  ## Cross-tenant FK invariant

  Validates `source_message_id` against `Conversations.Message`
  (tenant-checked), and `source_solution_id` against
  `Solutions.Solution` (tenant-checked). Both are nullable —
  consolidator runs can synthesize Episodes from Fact-only inputs
  (e.g. legacy imports) where neither pointer applies.
  """

  use JidoClaw.Resource, domain: JidoClaw.Memory.Domain, primary_read_warning?: false

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias JidoClaw.Memory.Fact
  alias JidoClaw.Memory.Resources.ScopeFilter
  alias JidoClaw.Security.CrossTenantFk
  alias JidoClaw.Security.Redaction.Transcript

  @scope_kinds [:user, :workspace, :project, :session]
  @kinds [:transcript, :solution, :consolidation, :imported_legacy]

  postgres do
    table("memory_episodes")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :scope_kind, :inserted_at])
      index([:tenant_id, :source_message_id], where: "source_message_id IS NOT NULL")
      index([:tenant_id, :source_solution_id], where: "source_solution_id IS NOT NULL")
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:record, action: :record)
    define(:for_consolidator, action: :for_consolidator)
    define(:for_fact, action: :for_fact, args: [:fact_id])
    define(:by_id, action: :by_id, args: [:id], get?: true)
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
  end

  actions do
    defaults([:read])

    create :record do
      primary?(true)

      accept([
        :scope_kind,
        :user_id,
        :workspace_id,
        :project_id,
        :session_id,
        :kind,
        :source_message_id,
        :source_solution_id,
        :content,
        :metadata,
        :inserted_at
      ])

      change({__MODULE__.Changes.ValidateScopeFk, []})
      change({__MODULE__.Changes.ValidateCrossTenant, []})
      change({__MODULE__.Changes.RedactContent, []})

      change(
        {JidoClaw.Audit.Producers.MemoryWrite,
         [event_kind: :memory_write, target_kind: :memory_episode]}
      )
    end

    read :for_consolidator do
      argument(:scope_kind, :atom, allow_nil?: false, constraints: [one_of: @scope_kinds])
      argument(:scope_fk_id, :uuid, allow_nil?: false)
      argument(:since_inserted_at, :utc_datetime_usec, allow_nil?: true)
      argument(:limit, :integer, allow_nil?: true, default: 500)

      prepare({__MODULE__.Preparations.ForConsolidator, []})
    end

    read :for_fact do
      argument(:fact_id, :uuid, allow_nil?: false)

      prepare({__MODULE__.Preparations.ForFact, []})
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

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @kinds)
    end

    attribute :source_message_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :source_solution_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :content, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :metadata, :map do
      allow_nil?(true)
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
      allow_nil?(false)
    end
  end

  # ---------------------------------------------------------------------------
  # Inline change modules
  # ---------------------------------------------------------------------------

  defmodule Changes.ValidateScopeFk do
    @moduledoc false
    use Ash.Resource.Change

    alias JidoClaw.Memory.Episode

    @impl true
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        scope_kind = Changeset.get_attribute(cs, :scope_kind)

        case Episode.scope_fk_for(cs, scope_kind) do
          {:ok, _} ->
            cs

          :missing ->
            Changeset.add_error(cs,
              field: :scope_kind,
              message: "scope_fk_required",
              vars: [scope_kind: scope_kind]
            )
        end
      end)
    end
  end

  defmodule Changes.ValidateCrossTenant do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        CrossTenantFk.validate(cs, [
          {:workspace_id, JidoClaw.Workspaces.Workspace, JidoClaw.Workspaces},
          {:session_id, JidoClaw.Conversations.Session, JidoClaw.Conversations},
          {:source_message_id, JidoClaw.Conversations.Message, JidoClaw.Conversations},
          {:source_solution_id, JidoClaw.Solutions.Solution, JidoClaw.Solutions.Domain},
          {:user_id, :no_tenant_column, nil},
          {:project_id, :no_tenant_column, nil}
        ])
      end)
    end
  end

  defmodule Changes.RedactContent do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        cs
        |> redact(:content)
        |> redact(:metadata)
      end)
    end

    defp redact(cs, attr) do
      case Changeset.get_attribute(cs, attr) do
        nil ->
          cs

        value ->
          Changeset.force_change_attribute(cs, attr, Transcript.redact(value))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Inline preparations
  # ---------------------------------------------------------------------------

  defmodule Preparations.ForConsolidator do
    @moduledoc false
    use Ash.Resource.Preparation
    require Ash.Query

    alias JidoClaw.Memory.Episode

    @impl true
    def prepare(query, _opts, _context) do
      kind = Query.get_argument(query, :scope_kind)
      fk = Query.get_argument(query, :scope_fk_id)
      since_at = Query.get_argument(query, :since_inserted_at)
      limit = Query.get_argument(query, :limit)

      query
      |> Episode.apply_scope_filter(kind, fk)
      |> Episode.apply_since_filter(since_at)
      |> Query.sort(inserted_at: :asc, id: :asc)
      |> Query.limit(limit)
    end
  end

  defmodule Preparations.ForFact do
    @moduledoc """
    Joins through `Memory.FactEpisode`. Returns Episodes pointing at
    the supplied `fact_id` ordered by recency. Used for the `recall`
    tool's "show me the source" follow-up.
    """
    use Ash.Resource.Preparation
    require Ash.Query

    @impl true
    def prepare(query, _opts, _context) do
      fact_id_arg = Query.get_argument(query, :fact_id)

      Query.filter(
        query,
        exists(
          JidoClaw.Memory.FactEpisode,
          episode_id == parent(:id) and fact_id == ^fact_id_arg
        )
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Delegate to `Fact.scope_fk_for/2` — shared scope FK resolution.
  Public so inline change modules can reference it.
  """
  def scope_fk_for(changeset, kind) do
    Fact.scope_fk_for(changeset, kind)
  end

  @doc """
  Narrow `query` to rows whose `scope_kind` and FK match `kind`/`fk`.
  Public so inline preparation modules can call it.
  """
  defdelegate apply_scope_filter(query, kind, fk), to: ScopeFilter, as: :apply

  @doc """
  Narrow `query` to rows newer than `since_at`. A `nil` `since_at` skips
  the filter.
  """
  def apply_since_filter(query, nil), do: query

  def apply_since_filter(query, since_at) do
    Query.filter(query, inserted_at > ^since_at)
  end
end
