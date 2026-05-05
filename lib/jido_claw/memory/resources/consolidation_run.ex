defmodule JidoClaw.Memory.ConsolidationRun do
  @moduledoc """
  Audit row + composite watermarks for the consolidator.

  Append-only. Every consolidator tick writes one row — `:succeeded` on
  successful publish, `:skipped` when the egress gate or input-count
  pre-flight rejected the run, `:failed` on harness or commit error.
  The two `(timestamp, id)` watermark pairs (`messages_processed_until_*`,
  `facts_processed_until_*`) capture the longest contiguous published
  prefix of the loaded streams so the next run can resume
  deterministically without skipping or double-processing.

  The plan's §3.15 step 7 specifies the watermark = "longest contiguous
  published prefix" rather than just "max id." If the harness rejects
  inputs out-of-order (e.g. it commits inputs 1-3 and 5 but skips 4),
  the watermark advances to input 3 only — input 4 remains eligible
  for the next run.

  ## Pre-existing debt

  `Forge.Resources.Session` lacks a `tenant_id` column. `forge_session_id`
  is recorded for transcript reachability but cross-tenant validation
  is skipped here (telemetry: `:tenant_validation_skipped_for_untenanted_parent`).
  The audit row's own `tenant_id` is still validated against scope FKs.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Memory.Domain,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false

  require Ash.Query

  alias JidoClaw.Security.CrossTenantFk

  @scope_kinds [:user, :workspace, :project, :session]
  @statuses [:succeeded, :failed, :skipped]
  @harnesses [:claude_code, :codex, :fake]

  postgres do
    table("memory_consolidation_runs")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :scope_kind, :started_at])
      index([:tenant_id, :status, :started_at])
      index([:forge_session_id], where: "forge_session_id IS NOT NULL")
    end
  end

  code_interface do
    define(:record_run, action: :record_run)
    define(:latest_for_scope, action: :latest_for_scope)
    define(:history_for_scope, action: :history_for_scope)
  end

  actions do
    defaults([:read])

    create :record_run do
      primary?(true)

      accept([
        :tenant_id,
        :scope_kind,
        :user_id,
        :workspace_id,
        :project_id,
        :session_id,
        :started_at,
        :finished_at,
        :messages_processed_until_at,
        :messages_processed_until_id,
        :facts_processed_until_at,
        :facts_processed_until_id,
        :messages_processed,
        :facts_processed,
        :blocks_written,
        :blocks_revised,
        :facts_added,
        :facts_invalidated,
        :links_added,
        :status,
        :error,
        :forge_session_id,
        :harness,
        :harness_model
      ])

      change({__MODULE__.Changes.ValidateScopeFk, []})
      change({__MODULE__.Changes.ValidateCrossTenant, []})
    end

    read :latest_for_scope do
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:scope_kind, :atom, allow_nil?: false, constraints: [one_of: @scope_kinds])
      argument(:scope_fk_id, :uuid, allow_nil?: false)
      argument(:status, :atom, allow_nil?: true, constraints: [one_of: @statuses])

      prepare({__MODULE__.Preparations.LatestForScope, []})
    end

    read :history_for_scope do
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:scope_kind, :atom, allow_nil?: false, constraints: [one_of: @scope_kinds])
      argument(:scope_fk_id, :uuid, allow_nil?: false)
      argument(:limit, :integer, allow_nil?: true, default: 20)

      prepare({__MODULE__.Preparations.HistoryForScope, []})
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

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :finished_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    # Composite watermarks — see plan §3.15.
    attribute :messages_processed_until_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :messages_processed_until_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :facts_processed_until_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :facts_processed_until_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    # Counters
    attribute :messages_processed, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :facts_processed, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :blocks_written, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :blocks_revised, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :facts_added, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :facts_invalidated, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :links_added, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @statuses)
    end

    attribute :error, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :forge_session_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :harness, :atom do
      allow_nil?(true)
      public?(true)
      constraints(one_of: @harnesses)
    end

    attribute :harness_model, :string do
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

  defmodule Changes.ValidateScopeFk do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        scope_kind = Ash.Changeset.get_attribute(cs, :scope_kind)

        case JidoClaw.Memory.Fact.scope_fk_for(cs, scope_kind) do
          {:ok, _} ->
            cs

          :missing ->
            Ash.Changeset.add_error(cs,
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
      Ash.Changeset.before_action(changeset, fn cs ->
        CrossTenantFk.validate(cs, [
          {:workspace_id, JidoClaw.Workspaces.Workspace, JidoClaw.Workspaces},
          {:session_id, JidoClaw.Conversations.Session, JidoClaw.Conversations},
          {:user_id, :no_tenant_column, nil},
          {:project_id, :no_tenant_column, nil},
          # Forge.Resources.Session lacks tenant_id today (plan §0.5.2).
          {:forge_session_id, :no_tenant_column, nil}
        ])
      end)
    end
  end

  defmodule Preparations.LatestForScope do
    @moduledoc false
    use Ash.Resource.Preparation
    require Ash.Query

    @impl true
    def prepare(query, _opts, _context) do
      tenant = Ash.Query.get_argument(query, :tenant_id)
      kind = Ash.Query.get_argument(query, :scope_kind)
      fk = Ash.Query.get_argument(query, :scope_fk_id)
      status = Ash.Query.get_argument(query, :status)

      query
      |> JidoClaw.Memory.ConsolidationRun.apply_scope_filter(kind, tenant, fk)
      |> JidoClaw.Memory.ConsolidationRun.apply_status_filter(status)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
    end
  end

  defmodule Preparations.HistoryForScope do
    @moduledoc false
    use Ash.Resource.Preparation
    require Ash.Query

    @impl true
    def prepare(query, _opts, _context) do
      tenant = Ash.Query.get_argument(query, :tenant_id)
      kind = Ash.Query.get_argument(query, :scope_kind)
      fk = Ash.Query.get_argument(query, :scope_fk_id)
      limit = Ash.Query.get_argument(query, :limit)

      query
      |> JidoClaw.Memory.ConsolidationRun.apply_scope_filter(kind, tenant, fk)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(limit)
    end
  end

  @doc false
  def apply_scope_filter(query, :user, tenant, fk) do
    Ash.Query.filter(query, tenant_id == ^tenant and scope_kind == :user and user_id == ^fk)
  end

  def apply_scope_filter(query, :workspace, tenant, fk) do
    Ash.Query.filter(
      query,
      tenant_id == ^tenant and scope_kind == :workspace and workspace_id == ^fk
    )
  end

  def apply_scope_filter(query, :project, tenant, fk) do
    Ash.Query.filter(
      query,
      tenant_id == ^tenant and scope_kind == :project and project_id == ^fk
    )
  end

  def apply_scope_filter(query, :session, tenant, fk) do
    Ash.Query.filter(
      query,
      tenant_id == ^tenant and scope_kind == :session and session_id == ^fk
    )
  end

  @doc false
  def apply_status_filter(query, nil), do: query

  def apply_status_filter(query, status) do
    Ash.Query.filter(query, status == ^status)
  end
end
