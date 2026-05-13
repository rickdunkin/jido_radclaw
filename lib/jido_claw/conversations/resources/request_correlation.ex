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

  ## Lifecycle

  Rows are registered at request start and stay alive until their
  TTL expires. Terminal signals (`ai.request.completed` /
  `ai.request.failed`) clear the in-memory `Cache` entry but
  intentionally leave the durable row alive so downstream readers
  (notably `Session.Worker.add_message`) can fetch the merged
  scope+telemetry tuple after the cache is cleared.

  ## Telemetry merge

  The Recorder writes per-request telemetry (`run_id`, `model`,
  `input_tokens`, `output_tokens`, `latency_ms`) into the row via
  `:record_telemetry` when the corresponding `ai.llm.response` /
  `ai.request.completed` signal lands, **before** clearing the
  cache. `Session.Worker.add_message` reads the row by `request_id`
  to merge those fields into the `messages` row it appends.

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
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias JidoClaw.Conversations.Session, as: SessionResource
  alias JidoClaw.Workspaces.Workspace, as: WorkspaceResource

  @sweep_batch 1_000

  # RequestCorrelation has internal callers with no actor in scope
  # (Recorder telemetry callbacks, Session.Worker durable lookups, and
  # JidoClaw.chat's correlation registration). The 60s sweeper bypasses
  # explicitly via `authorize?: false` in `sweep_expired/0`; the others
  # rely on this permissive policy. Closing the broader gap requires
  # the v0.7+ agent-identity work.
  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(always())
    end
  end

  postgres do
    table("request_correlations")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:expires_at], all_tenants?: true)
      index([:tenant_id, :expires_at])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(true)
  end

  code_interface do
    define(:register, action: :register)
    define(:complete, action: :complete, get_by: [:request_id])
    define(:expired, action: :expired)
    define(:lookup, action: :lookup, args: [:request_id], get?: true)
    define(:record_telemetry, action: :record_telemetry, get_by: [:request_id])
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
        :expires_at,
        :run_id,
        :model,
        :input_tokens,
        :output_tokens,
        :latency_ms
      ])

      change({__MODULE__.Changes.ValidateCrossTenantFk, []})
    end

    update :record_telemetry do
      accept([:run_id, :model, :input_tokens, :output_tokens, :latency_ms])
      require_atomic?(false)
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

    # Telemetry merged into the row by the Recorder when
    # `ai.llm.response` / `ai.request.completed` lands.
    attribute :run_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :model, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :input_tokens, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :output_tokens, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :latency_ms, :integer do
      allow_nil?(true)
      public?(true)
    end
  end

  relationships do
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
    end

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
      |> Ash.read!(authorize?: false)

    case expired do
      [] ->
        {:ok, 0}

      records ->
        Ash.bulk_destroy!(records, :complete, %{}, authorize?: false)
        {:ok, length(records)}
    end
  end

  # ---------------------------------------------------------------------------
  # Inline change modules
  # ---------------------------------------------------------------------------

  defmodule Changes.ValidateCrossTenantFk do
    @moduledoc false
    use Ash.Resource.Change

    alias JidoClaw.Conversations.Resources.GlobalLookup
    alias JidoClaw.Conversations.Session
    alias JidoClaw.Workspaces.Workspace

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

    defp validate_session(cs, session_id, tenant_id) do
      GlobalLookup.validate_tenant_match(
        cs,
        session_id,
        tenant_id,
        :session_id,
        &Session.by_id_global/1,
        "session_not_found"
      )
    end

    defp validate_workspace(%{errors: errors} = cs, _, _) when errors != [], do: cs

    defp validate_workspace(cs, workspace_id, tenant_id) do
      GlobalLookup.validate_tenant_match(
        cs,
        workspace_id,
        tenant_id,
        :workspace_id,
        &Workspace.by_id_global/1,
        "workspace_not_found"
      )
    end
  end
end
