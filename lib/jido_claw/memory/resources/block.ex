defmodule JidoClaw.Memory.Block do
  @moduledoc """
  Curated memory tier — scope-chained, label-keyed, capped-size blocks
  rendered into the system prompt's frozen snapshot.

  Blocks are the only Memory tier that lands inside the prompt itself.
  Facts reach the model through the `recall` tool. The shape favors
  determinism: at most one active block per `(tenant, scope, label)`,
  capped at `char_limit` bytes (default 2000), ordered by `position`.

  ## Bitemporal model

  Two pairs:

    * `valid_at` / `invalid_at` — world time. `invalid_at IS NULL` means
      the row is currently true in the world.
    * `inserted_at` / `expired_at` — system time. `expired_at IS NULL`
      means the row is the live representation of that world fact in
      the database.

  `:write` inserts a new row. `:revise` invalidates the prior row at
  `(scope, label)` (sets `invalid_at` + `expired_at` to `now()`) and
  inserts a new row, paired with a `BlockRevision` tombstone, all in
  one transaction. `:invalidate` sets only `invalid_at` and
  `expired_at` and writes a tombstone — no replacement.

  ## Per-scope uniqueness

  Four partial identities, one per scope kind. Each is
  `(tenant_id, scope_kind, label, <scope_fk>) WHERE invalid_at IS NULL`
  so historical / superseded rows don't compete with the active row.
  Spelled out per scope kind because Postgres can't index a single
  unique on a column whose meaning depends on a discriminator — each
  identity needs its own partial WHERE.

  ## Source precedence

  `source: :user` always wins over `:consolidator` at retrieval time
  (plan §3.13). The Block tier itself doesn't enforce that — both
  sources can write at the same `(scope, label)` and the live row is
  whichever wrote last. Retrieval applies the source-precedence ranking
  in SQL via `ROW_NUMBER() OVER (PARTITION BY label ORDER BY source_rank, ...)`.

  Pre-existing debt:

    * `Project` has no `tenant_id` column — `:project` scope rows skip
      cross-tenant FK validation against the parent Project, recorded
      via `[:jido_claw, :memory, :cross_tenant_fk, :skipped]` telemetry.
    * `Accounts.User` has no `tenant_id` column — `:user` scope rows
      skip the same way.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Memory.Domain,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false

  require Ash.Query
  import Ash.Expr

  alias JidoClaw.Memory.BlockRevision
  alias JidoClaw.Repo
  alias JidoClaw.Security.CrossTenantFk

  @scope_kinds [:user, :workspace, :project, :session]
  @sources [:user, :consolidator]

  postgres do
    table("memory_blocks")
    repo(JidoClaw.Repo)

    identity_wheres_to_sql(
      unique_label_per_scope_user:
        "invalid_at IS NULL AND tenant_id IS NOT NULL AND user_id IS NOT NULL",
      unique_label_per_scope_workspace:
        "invalid_at IS NULL AND tenant_id IS NOT NULL AND workspace_id IS NOT NULL",
      unique_label_per_scope_project:
        "invalid_at IS NULL AND tenant_id IS NOT NULL AND project_id IS NOT NULL",
      unique_label_per_scope_session:
        "invalid_at IS NULL AND tenant_id IS NOT NULL AND session_id IS NOT NULL"
    )

    custom_indexes do
      index([:tenant_id, :scope_kind, :label, :invalid_at])
      index([:tenant_id, :source, :inserted_at])
    end
  end

  code_interface do
    define(:write, action: :write)
    define(:invalidate, action: :invalidate)
    define(:for_scope_chain, action: :for_scope_chain, args: [:tenant_id, :scope_chain])

    define(:history_for_label,
      action: :history_for_label,
      args: [:tenant_id, :scope_kind, :scope_fk_id, :label]
    )
  end

  actions do
    defaults([:read])

    create :write do
      primary?(true)

      accept([
        :tenant_id,
        :scope_kind,
        :user_id,
        :workspace_id,
        :project_id,
        :session_id,
        :label,
        :description,
        :value,
        :char_limit,
        :pinned,
        :position,
        :source,
        :written_by,
        :valid_at
      ])

      change({__MODULE__.Changes.ValidateScopeFk, []})
      change({__MODULE__.Changes.ValidateCrossTenant, []})
      change({__MODULE__.Changes.CapValueLength, []})
    end

    update :invalidate do
      accept([])
      argument(:written_by, :atom, allow_nil?: true)
      argument(:reason, :string, allow_nil?: true)
      require_atomic?(false)

      change({__MODULE__.Changes.MarkInvalidated, []})
      change({__MODULE__.Changes.WriteRevisionForUpdate, []})
    end

    read :for_scope_chain do
      argument(:tenant_id, :string, allow_nil?: false)

      argument(:scope_chain, {:array, :map},
        allow_nil?: false,
        description: "List of %{scope_kind: atom, fk_id: uuid} maps in retrieval precedence order"
      )

      prepare({__MODULE__.Preparations.ApplyScopeChain, []})
    end

    read :history_for_label do
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:scope_kind, :atom, allow_nil?: false, constraints: [one_of: @scope_kinds])
      argument(:scope_fk_id, :uuid, allow_nil?: false)
      argument(:label, :string, allow_nil?: false)

      prepare({__MODULE__.Preparations.HistoryForLabel, []})
      prepare(build(sort: [inserted_at: :asc]))
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

    attribute :label, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :description, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :value, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :char_limit, :integer do
      allow_nil?(false)
      public?(true)
      default(2000)
    end

    attribute :pinned, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
    end

    attribute :position, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :source, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @sources)
    end

    attribute :written_by, :string do
      allow_nil?(true)
      public?(true)
    end

    # Bitemporal — world time
    attribute :valid_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end

    attribute :invalid_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    # Bitemporal — system time
    attribute :inserted_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end

    attribute :expired_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :updated_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      default(&DateTime.utc_now/0)
      writable?(true)
    end
  end

  identities do
    identity(:unique_label_per_scope_user, [:tenant_id, :scope_kind, :label, :user_id],
      where: expr(is_nil(invalid_at) and not is_nil(user_id))
    )

    identity(
      :unique_label_per_scope_workspace,
      [:tenant_id, :scope_kind, :label, :workspace_id],
      where: expr(is_nil(invalid_at) and not is_nil(workspace_id))
    )

    identity(:unique_label_per_scope_project, [:tenant_id, :scope_kind, :label, :project_id],
      where: expr(is_nil(invalid_at) and not is_nil(project_id))
    )

    identity(:unique_label_per_scope_session, [:tenant_id, :scope_kind, :label, :session_id],
      where: expr(is_nil(invalid_at) and not is_nil(session_id))
    )
  end

  # ---------------------------------------------------------------------------
  # Inline change modules
  # ---------------------------------------------------------------------------

  defmodule Changes.ValidateScopeFk do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        scope_kind = Ash.Changeset.get_attribute(cs, :scope_kind)

        case JidoClaw.Memory.Block.scope_fk_for(cs, scope_kind) do
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
          # User and Project lack tenant_id columns — see plan §0.5.2.
          {:user_id, :no_tenant_column, nil},
          {:project_id, :no_tenant_column, nil}
        ])
      end)
    end
  end

  defmodule Changes.CapValueLength do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        value = Ash.Changeset.get_attribute(cs, :value)
        char_limit = Ash.Changeset.get_attribute(cs, :char_limit) || 2000

        cond do
          is_nil(value) ->
            cs

          byte_size(value) > char_limit ->
            Ash.Changeset.add_error(cs,
              field: :value,
              message: "value_exceeds_char_limit",
              vars: [byte_size: byte_size(value), char_limit: char_limit]
            )

          true ->
            cs
        end
      end)
    end
  end

  defmodule Changes.MarkInvalidated do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn cs ->
        now = DateTime.utc_now()

        cs
        |> Ash.Changeset.force_change_attribute(:invalid_at, now)
        |> Ash.Changeset.force_change_attribute(:expired_at, now)
      end)
    end
  end

  defmodule Changes.WriteRevisionForUpdate do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.after_action(changeset, fn cs, result ->
        prior = cs.data
        reason = Ash.Changeset.get_argument(cs, :reason)
        written_by_arg = Ash.Changeset.get_argument(cs, :written_by)

        attrs = %{
          block_id: prior.id,
          tenant_id: prior.tenant_id,
          scope_kind: prior.scope_kind,
          user_id: prior.user_id,
          workspace_id: prior.workspace_id,
          project_id: prior.project_id,
          session_id: prior.session_id,
          value: prior.value,
          source: prior.source,
          written_by: written_by_arg || prior.written_by,
          reason: reason
        }

        case BlockRevision.create_for_block(attrs) do
          {:ok, _} ->
            {:ok, result}

          {:error, err} ->
            require Logger
            Logger.warning("[Memory.Block] revision write failed: #{inspect(err)}")
            {:ok, result}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Inline preparations
  # ---------------------------------------------------------------------------

  defmodule Preparations.ApplyScopeChain do
    @moduledoc """
    Filter the read down to the union of the supplied scope levels and
    order by `(position ASC, inserted_at DESC)`. Scope precedence (most
    specific scope wins per label) is applied by the caller —
    `Retrieval` and `Memory.Api` dedup by label in Elixir post-fetch
    using `Memory.Scope.chain/1` order.
    """
    use Ash.Resource.Preparation
    require Ash.Query

    @impl true
    def prepare(query, _opts, _context) do
      tenant = Ash.Query.get_argument(query, :tenant_id)
      chain = Ash.Query.get_argument(query, :scope_chain) || []
      filter_expr = JidoClaw.Memory.Block.build_chain_filter(tenant, chain)

      query
      |> Ash.Query.do_filter(filter_expr)
      |> Ash.Query.sort(position: :asc, inserted_at: :desc)
    end
  end

  defmodule Preparations.HistoryForLabel do
    @moduledoc false
    use Ash.Resource.Preparation
    require Ash.Query

    @impl true
    def prepare(query, _opts, _context) do
      tenant = Ash.Query.get_argument(query, :tenant_id)
      kind = Ash.Query.get_argument(query, :scope_kind)
      fk = Ash.Query.get_argument(query, :scope_fk_id)
      arg_label = Ash.Query.get_argument(query, :label)

      Ash.Query.do_filter(
        query,
        JidoClaw.Memory.Block.build_history_filter(tenant, kind, fk, arg_label)
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers (called from inline modules — declared as public so the change
  # module compiles before the `use Ash.Resource` block has finalized).
  # ---------------------------------------------------------------------------

  @doc false
  def scope_fk_for(changeset, :user) do
    case Ash.Changeset.get_attribute(changeset, :user_id) do
      nil -> :missing
      id -> {:ok, id}
    end
  end

  def scope_fk_for(changeset, :workspace) do
    case Ash.Changeset.get_attribute(changeset, :workspace_id) do
      nil -> :missing
      id -> {:ok, id}
    end
  end

  def scope_fk_for(changeset, :project) do
    case Ash.Changeset.get_attribute(changeset, :project_id) do
      nil -> :missing
      id -> {:ok, id}
    end
  end

  def scope_fk_for(changeset, :session) do
    case Ash.Changeset.get_attribute(changeset, :session_id) do
      nil -> :missing
      id -> {:ok, id}
    end
  end

  def scope_fk_for(_, _), do: :missing

  @doc false
  # An empty chain filters to no rows. `false` is a valid Ash filter
  # value (compiled to `WHERE FALSE`).
  def build_chain_filter(_tenant, []), do: expr(false)

  def build_chain_filter(tenant, chain) do
    chain
    |> Enum.map(&chain_clause(tenant, &1))
    |> Enum.reduce(fn next, acc -> expr(^acc or ^next) end)
  end

  defp chain_clause(tenant, %{scope_kind: :user, fk_id: fk}) do
    expr(tenant_id == ^tenant and scope_kind == :user and user_id == ^fk and is_nil(invalid_at))
  end

  defp chain_clause(tenant, %{scope_kind: :workspace, fk_id: fk}) do
    expr(
      tenant_id == ^tenant and scope_kind == :workspace and workspace_id == ^fk and
        is_nil(invalid_at)
    )
  end

  defp chain_clause(tenant, %{scope_kind: :project, fk_id: fk}) do
    expr(
      tenant_id == ^tenant and scope_kind == :project and project_id == ^fk and
        is_nil(invalid_at)
    )
  end

  defp chain_clause(tenant, %{scope_kind: :session, fk_id: fk}) do
    expr(
      tenant_id == ^tenant and scope_kind == :session and session_id == ^fk and
        is_nil(invalid_at)
    )
  end

  @doc false
  def build_history_filter(tenant, :user, fk, arg_label) do
    expr(
      tenant_id == ^tenant and scope_kind == :user and user_id == ^fk and
        label == ^arg_label
    )
  end

  def build_history_filter(tenant, :workspace, fk, arg_label) do
    expr(
      tenant_id == ^tenant and scope_kind == :workspace and workspace_id == ^fk and
        label == ^arg_label
    )
  end

  def build_history_filter(tenant, :project, fk, arg_label) do
    expr(
      tenant_id == ^tenant and scope_kind == :project and project_id == ^fk and
        label == ^arg_label
    )
  end

  def build_history_filter(tenant, :session, fk, arg_label) do
    expr(
      tenant_id == ^tenant and scope_kind == :session and session_id == ^fk and
        label == ^arg_label
    )
  end

  # ---------------------------------------------------------------------------
  # Public revise — invalidate-and-replace
  # ---------------------------------------------------------------------------

  @typedoc "A loaded Block row or its UUID."
  @type prior :: t() | Ecto.UUID.t()

  @doc """
  Invalidate the prior `(scope, label)` row and write a new one
  carrying the supplied `attrs`. Bitemporal: prior row gets
  `invalid_at = expired_at = now()`, the new row inherits scope FKs +
  label + source from the prior and accepts overrides for
  `value`/`description`/`char_limit`/`pinned`/`position`/`written_by`.

  Wrapped in a single `Ash.transact/3` so the invalidate, the new
  write, and the `BlockRevision` side-row commit atomically.

  > #### Nesting note {: .warning}
  > This function is called from
  > `JidoClaw.Memory.Consolidator.RunServer.do_publish/1`, which itself
  > runs inside `Ash.transact(ConsolidationRun, ...)`. Adding any
  > `after_transaction` hook to a `Block` action will fire pre-commit
  > under that nesting and trip Ash's transaction-hooks warning. If
  > you need post-commit side effects on `Block` writes, follow the
  > pattern used for `Memory.Fact` (a `:skip_*_hint?` argument on the
  > action, with the consolidator dispatching after publish).
  """
  @spec revise(prior(), map()) :: {:ok, t()} | {:error, term()}
  def revise(prior_block_or_id, attrs) when is_map(attrs) do
    with {:ok, prior} <- load_prior(prior_block_or_id) do
      Ash.transact(__MODULE__, fn ->
        with :ok <- invalidate_prior_block(prior),
             new_attrs = build_revise_attrs(prior, attrs),
             {:ok, new_block} <- write(new_attrs),
             {:ok, _rev} <- write_revision_row(prior, attrs) do
          new_block
        else
          {:error, err} -> Ash.DataLayer.rollback(__MODULE__, err)
          other -> Ash.DataLayer.rollback(__MODULE__, {:unexpected, other})
        end
      end)
    end
  end

  defp load_prior(id) when is_binary(id),
    do: Ash.get(__MODULE__, id, domain: JidoClaw.Memory.Domain)

  defp load_prior(b) when is_struct(b, __MODULE__), do: {:ok, b}

  defp load_prior(_), do: {:error, :invalid_prior}

  # Single raw SQL UPDATE mirroring `Fact.invalidate_prior_active_label/4`.
  # The prior row's id is the only filter — uniqueness across (scope,
  # label) is already enforced by the partial unique identity on the
  # parent table.
  defp invalidate_prior_block(%{id: id}) do
    Repo.query!(
      "UPDATE memory_blocks SET invalid_at = now(), expired_at = now() WHERE id = $1",
      [Ecto.UUID.dump!(id)]
    )

    :ok
  end

  defp build_revise_attrs(prior, attrs) do
    %{
      tenant_id: prior.tenant_id,
      scope_kind: prior.scope_kind,
      user_id: prior.user_id,
      workspace_id: prior.workspace_id,
      project_id: prior.project_id,
      session_id: prior.session_id,
      label: prior.label,
      source: prior.source,
      value: Map.get(attrs, :value, prior.value),
      description: Map.get(attrs, :description, prior.description),
      char_limit: Map.get(attrs, :char_limit, prior.char_limit),
      pinned: Map.get(attrs, :pinned, prior.pinned),
      position: Map.get(attrs, :position, prior.position),
      written_by: Map.get(attrs, :written_by, prior.written_by)
    }
  end

  defp write_revision_row(prior, attrs) do
    rev_attrs = %{
      block_id: prior.id,
      tenant_id: prior.tenant_id,
      scope_kind: prior.scope_kind,
      user_id: prior.user_id,
      workspace_id: prior.workspace_id,
      project_id: prior.project_id,
      session_id: prior.session_id,
      value: prior.value,
      source: prior.source,
      written_by: Map.get(attrs, :written_by, prior.written_by),
      reason: Map.get(attrs, :reason)
    }

    BlockRevision.create_for_block(rev_attrs)
  end
end
