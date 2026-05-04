defmodule JidoClaw.Conversations.RequestCorrelation do
  @moduledoc """
  Durable mapping from `request_id` to the dispatching scope:
  `(session, tenant, workspace, user)`.

  The Recorder needs this to resolve which session a tool signal
  belongs to. Tool signals (`Signal.ToolStart`, `Signal.ToolResult`)
  carry only `request_id` — they don't carry session/tenant/workspace
  scope, so without a correlation row the Recorder can't decide where
  to write the resulting `Conversations.Message`.

  ## Why Postgres, not just ETS

  The Cache (`RequestCorrelation.Cache`) is a hot in-memory mirror, but
  it doesn't survive process restarts. A crashed Recorder GenServer
  comes back with an empty cache and would drop in-flight tool signals
  for any request that didn't see its terminal `ai.request.completed`
  before the crash. Persisting to Postgres means the Recorder's
  fallback `lookup` path can rehydrate the cache from the durable row.

  ## TTL semantics

  `expires_at` defaults to `DateTime.utc_now() + 600s` when the
  dispatcher doesn't supply a value. Both `inserted_at` and `expires_at`
  have build-time attribute defaults that fire microseconds apart, so
  in practice `expires_at ≈ inserted_at + 600s`. The `:register`
  action does **not** accept `:inserted_at` — allowing callers to
  backdate it without coupling it to `expires_at` would silently
  violate the documented TTL. The `Sweeper` worker calls
  `sweep_expired/0` on a 60s tick; rows with `expires_at < now()` are
  bulk-destroyed in batches of 1_000.

  ## Cross-tenant FK invariant

  `:register` validates that the supplied `session_id` and (when set)
  `workspace_id` belong to the supplied `tenant_id`. `user_id` is NOT
  validated against an Accounts.User row — Users are untenanted by
  design (matches Solutions). Error string is `cross_tenant_fk_mismatch`.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Conversations,
    data_layer: AshPostgres.DataLayer

  alias JidoClaw.Conversations.Session, as: SessionResource
  alias JidoClaw.Workspaces.Workspace, as: WorkspaceResource

  @sweep_batch 1_000

  postgres do
    table("request_correlations")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:expires_at])
      index([:tenant_id, :expires_at])
    end
  end

  code_interface do
    define(:register, action: :register)
    define(:complete, action: :complete, get_by: [:request_id])
    define(:expired, action: :expired)
    define(:lookup, action: :lookup, args: [:request_id], get?: true)
  end

  actions do
    defaults([:read])

    create :register do
      primary?(true)

      accept([
        :request_id,
        :session_id,
        :tenant_id,
        :workspace_id,
        :user_id,
        :expires_at
      ])

      change({__MODULE__.Changes.ValidateCrossTenantFk, []})
    end

    destroy :complete do
      primary?(true)
    end

    read :expired do
      filter(expr(expires_at < now()))
      prepare(build(sort: [expires_at: :asc]))
    end

    read :lookup do
      get?(true)
      argument(:request_id, :string, allow_nil?: false)
      filter(expr(request_id == ^arg(:request_id)))
    end
  end

  attributes do
    attribute :request_id, :string do
      allow_nil?(false)
      public?(true)
      primary_key?(true)
    end

    attribute :session_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :workspace_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end

    # `expires_at` and `inserted_at` both default to `DateTime.utc_now()`-based
    # values that fire at changeset-build time (before `allow_nil?: false`
    # validation), so the gap between them is microseconds in practice.
    # `:inserted_at` is intentionally NOT in the `:register` accept list —
    # allowing callers to backdate `inserted_at` without coupling it to
    # `expires_at` would break the documented `inserted_at + ~600s` TTL.
    attribute :expires_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(fn -> DateTime.add(DateTime.utc_now(), 600, :second) end)
    end
  end

  relationships do
    belongs_to :session, SessionResource do
      define_attribute?(false)
      attribute_writable?(true)
    end

    belongs_to :workspace, WorkspaceResource do
      define_attribute?(false)
      attribute_writable?(true)
    end
  end

  @doc """
  Sweep at most #{@sweep_batch} expired rows. Returns
  `{:ok, count_deleted}`. Called by the `Sweeper` worker on its 60s
  tick; when the result is `{:ok, #{@sweep_batch}}` the sweeper
  immediately reschedules to drain the backlog.
  """
  @spec sweep_expired() :: {:ok, non_neg_integer()}
  def sweep_expired do
    expired =
      __MODULE__
      |> Ash.Query.for_read(:expired)
      |> Ash.Query.limit(@sweep_batch)
      |> Ash.read!()

    case expired do
      [] ->
        {:ok, 0}

      records ->
        Ash.bulk_destroy!(records, :complete, %{})
        {:ok, length(records)}
    end
  end

  # ---------------------------------------------------------------------------
  # Inline change modules
  # ---------------------------------------------------------------------------

  defmodule Changes.ValidateCrossTenantFk do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        tenant_id = Ash.Changeset.get_attribute(cs, :tenant_id)
        session_id = Ash.Changeset.get_attribute(cs, :session_id)
        workspace_id = Ash.Changeset.get_attribute(cs, :workspace_id)

        cs
        |> validate_session(session_id, tenant_id)
        |> validate_workspace(workspace_id, tenant_id)
      end)
    end

    defp validate_session(cs, nil, _), do: cs
    defp validate_session(cs, _, nil), do: cs

    defp validate_session(cs, session_id, tenant_id) do
      case JidoClaw.Conversations.Session.by_id(session_id) do
        {:ok, %{tenant_id: ^tenant_id}} ->
          cs

        {:ok, %{tenant_id: parent_tenant}} ->
          Ash.Changeset.add_error(cs,
            field: :session_id,
            message: "cross_tenant_fk_mismatch",
            vars: [supplied_tenant: tenant_id, parent_tenant: parent_tenant]
          )

        {:error, _} ->
          Ash.Changeset.add_error(cs,
            field: :session_id,
            message: "session_not_found"
          )
      end
    end

    defp validate_workspace(%{errors: errors} = cs, _, _) when errors != [], do: cs
    defp validate_workspace(cs, nil, _), do: cs
    defp validate_workspace(cs, _, nil), do: cs

    defp validate_workspace(cs, workspace_id, tenant_id) do
      case Ash.get(JidoClaw.Workspaces.Workspace, workspace_id, domain: JidoClaw.Workspaces) do
        {:ok, %{tenant_id: ^tenant_id}} ->
          cs

        {:ok, %{tenant_id: parent_tenant}} ->
          Ash.Changeset.add_error(cs,
            field: :workspace_id,
            message: "cross_tenant_fk_mismatch",
            vars: [supplied_tenant: tenant_id, parent_tenant: parent_tenant]
          )

        {:error, _} ->
          Ash.Changeset.add_error(cs,
            field: :workspace_id,
            message: "workspace_not_found"
          )
      end
    end
  end
end
