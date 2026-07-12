defmodule JidoClaw.Forge.Resources.Session do
  @moduledoc """
  Durable Forge session row.

  ## Global `:unique_name` identity

  The `:unique_name` identity is `all_tenants?: true` (and the `:start`
  action deliberately omits `tenant_id` from `accept`/`upsert_fields` —
  AshPostgres sets it from the `tenant:` option on insert, so a colliding
  upsert can never steal tenant ownership). The global index is **required**
  by `JidoClaw.Forge.Persistence.find_session_global/1`, which resolves a
  session by name with no tenant in hand (the Harness only knows the
  session_id).

  This is safe **only because `name` is globally unique by construction** —
  every name source is a freshly generated UUID (`Ecto.UUID.generate/0`):
  `JidoClaw.Memory.Consolidator.RunServer` mints `forge_session_id`, and
  `JidoClaw.Forge.wake/1` reuses an already-UUID name. There is no
  human/short-name caller. Same reasoning as the in-repo precedents
  `JidoClaw.Trace.Resources.TraceRun` (`unique_trace_id`) and
  `JidoClaw.Trace.Resources.TraceEvent` (`(trace_id, seq)`), both of which
  document global identities for globally-unique-by-construction keys.

  ## Resume/recovery metadata paths (fenced writers only)

  Control data and vendor resume state live at SEPARATE `metadata` JSON
  paths so no ordinary write can erase the pointer it must outlive
  (`docs/system/forge-session-resume.md`):

    * `metadata["forge_recovery"]` — `{epoch, token, current_checkpoint_id,
      recovery_degraded}`: harness-level incarnation control data. Written
      ONLY by `:mint_forge_recovery` (under the caller's FOR-UPDATE lock —
      `JidoClaw.Forge.Persistence.mint_resume_epoch/3`),
      `:point_recovery_checkpoint`, and `:mark_recovery_degraded`.
    * `metadata["resume"]["state"]` — the sanitized vendor
      `JidoClaw.Forge.ResumeState` copy. Written ONLY by `:anchor_resume`
      (token + revision fenced) and replaced wholesale by the mint.
    * `metadata["resume"]["guidance"]` — the `{status, guidance_rev}`
      marker, mirrored by `:point_recovery_checkpoint` in the same
      transaction that moves the pointer (plus best-effort consumed marks).

  Every fenced action requires the CURRENT `metadata["forge_recovery"]`
  token as a `sensitive?: true` argument; a fence miss raises
  `Ash.Error.Changes.StaleRecord` from inside the atomic expression
  (savepoint-contained), which the Persistence boundary maps to
  `{:error, :stale_resume_write}`. The token is a write capability only —
  reads never consult it.
  """
  use JidoClaw.Resource, domain: JidoClaw.Forge.Domain, global_actions: [:by_name_global]

  postgres do
    table("forge_sessions")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :workspace_id, :phase])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:start)
    define(:update_phase)
    define(:mark_failed)
    define(:complete)
    define(:cancel)
    define(:set_sandbox_id)
    define(:list_active)
    define(:by_name, action: :by_name, args: [:name], get?: true)
    define(:by_name_global, action: :by_name_global, args: [:name], get?: true)
    define(:read, action: :read)
    define(:destroy, action: :destroy)
    define(:anchor_resume, args: [:resume, :incarnation_token])

    define(:point_recovery_checkpoint,
      args: [:checkpoint_id, :guidance_marker, :incarnation_token]
    )

    define(:mark_recovery_degraded, args: [:incarnation_token])
    define(:mint_forge_recovery, args: [:forge_recovery, :resume])
  end

  actions do
    defaults([:read, :destroy])

    create :start do
      description("Start or resume a Forge session, upserting by unique name.")
      primary?(true)
      accept([:name, :workspace_id, :runner_type, :runner_config, :spec, :metadata, :started_at])

      upsert?(true)
      upsert_identity(:unique_name)

      upsert_fields([
        :workspace_id,
        :runner_type,
        :runner_config,
        :spec,
        :started_at,
        :phase,
        :completed_at,
        :last_error,
        :execution_count,
        :last_activity_at
      ])

      change(set_attribute(:phase, :created))
      change(set_attribute(:completed_at, nil))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:execution_count, 0))
      change(set_attribute(:last_activity_at, nil))
    end

    update :update_phase do
      description("Transition a session to a new lifecycle phase.")
      primary?(true)
      accept([])
      argument(:phase, :atom, allow_nil?: false)
      change(set_attribute(:phase, arg(:phase)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :mark_failed do
      description("Mark a session failed and record the last error.")
      accept([])
      argument(:error, :string)
      change(set_attribute(:phase, :failed))
      change(set_attribute(:last_error, arg(:error)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :complete do
      description("Mark a session completed and stamp completed_at.")
      accept([])
      change(set_attribute(:phase, :completed))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :cancel do
      description("Cancel an in-flight session.")
      accept([])
      change(set_attribute(:phase, :cancelled))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    update :set_sandbox_id do
      description("Attach a sandbox identifier to a session.")
      accept([])
      argument(:sandbox_id, :string, allow_nil?: false)
      change(set_attribute(:sandbox_id, arg(:sandbox_id)))
      change(set_attribute(:last_activity_at, &DateTime.utc_now/0))
    end

    read :list_active do
      description("List sessions in any non-terminal phase.")

      filter(
        expr(
          phase in [
            :created,
            :provisioning,
            :bootstrapping,
            :ready,
            :running,
            :needs_input,
            :resuming
          ]
        )
      )
    end

    read :by_name do
      get?(true)
      argument(:name, :string, allow_nil?: false)
      filter(expr(name == ^arg(:name)))
    end

    read :by_name_global do
      get?(true)
      multitenancy(:bypass)
      argument(:name, :string, allow_nil?: false)
      filter(expr(name == ^arg(:name)))
    end

    update :anchor_resume do
      description(
        "Fenced write of the sanitized vendor resume state at " <>
          "metadata['resume']['state'] — requires the CURRENT incarnation " <>
          "token AND a strictly newer revision; sibling paths preserved by " <>
          "construction. Stale writers get StaleRecord, never a silent no-op."
      )

      accept([])
      argument(:resume, :map, allow_nil?: false)
      argument(:incarnation_token, :string, allow_nil?: false, sensitive?: true)
      change(__MODULE__.Changes.AnchorResume)
    end

    update :point_recovery_checkpoint do
      description(
        "The checked-checkpoint metadata side: sets " <>
          "forge_recovery.current_checkpoint_id, clears recovery_degraded, " <>
          "and mirrors the guidance marker — token-fenced, one atomic UPDATE. " <>
          "Runs inside the transaction that creates the Checkpoint row."
      )

      accept([])
      argument(:checkpoint_id, :uuid, allow_nil?: false)
      argument(:guidance_marker, :map, allow_nil?: true)
      argument(:incarnation_token, :string, allow_nil?: false, sensitive?: true)
      change(__MODULE__.Changes.PointRecoveryCheckpoint)
    end

    update :mark_recovery_degraded do
      description(
        "Token-fenced degraded marker: a failed initial checked checkpoint " <>
          "sets it; the next successful checked checkpoint clears it. A stale " <>
          "incarnation can never degrade a newer one (StaleRecord instead)."
      )

      accept([])
      argument(:incarnation_token, :string, allow_nil?: false, sensitive?: true)
      change(__MODULE__.Changes.MarkRecoveryDegraded)
    end

    update :mint_forge_recovery do
      description(
        "Installs a freshly minted incarnation: replaces " <>
          "metadata['forge_recovery'] (new epoch + token, pointer cleared) and " <>
          "metadata['resume'] (the stamped transplant) while preserving all " <>
          "other metadata keys. ONLY " <>
          "JidoClaw.Forge.Persistence.mint_resume_epoch/3 may call this, under " <>
          "its FOR-UPDATE row lock — the lock is what makes the read-modify-" <>
          "write safe."
      )

      require_atomic?(false)
      accept([])
      argument(:forge_recovery, :map, allow_nil?: false)
      argument(:resume, :map, allow_nil?: false)
      change(__MODULE__.Changes.MintForgeRecovery)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :workspace_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :phase, :atom do
      allow_nil?(false)
      public?(true)
      default(:created)

      constraints(
        one_of: [
          :created,
          :provisioning,
          :bootstrapping,
          :ready,
          :running,
          :needs_input,
          :completed,
          :failed,
          :cancelled,
          :resuming
        ]
      )
    end

    attribute :runner_type, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :runner_config, :map do
      allow_nil?(true)
      public?(false)
      default(%{})
    end

    attribute :spec, :map do
      allow_nil?(true)
      public?(false)
      default(%{})
    end

    attribute :sandbox_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :execution_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :last_error, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :metadata, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :completed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :last_activity_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  identities do
    identity(:unique_name, [:name], all_tenants?: true)
  end

  relationships do
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    belongs_to :workspace, JidoClaw.Workspaces.Workspace do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    has_many(:exec_sessions, JidoClaw.Forge.Resources.ExecSession)
    has_many(:events, JidoClaw.Forge.Resources.Event)
    has_many(:checkpoints, JidoClaw.Forge.Resources.Checkpoint)
  end

  # ---------------------------------------------------------------------------
  # Inline change modules (fenced resume/recovery writers)
  #
  # jsonb conventions shared with the conversations Session change modules
  # (`SetMetadataKey`/`SetCompactionSnapshot`): encode-then-`::text::jsonb`
  # (a raw `::jsonb` param double-encodes), and parent-object `||` merges
  # because `jsonb_set` does not create intermediate objects — an absent
  # parent must not turn the write into a no-op.
  #
  # The fence rides INSIDE each atomic expression as an `error(StaleRecord)`
  # else-branch (the `Ash.Resource.Change.OptimisticLock` idiom). NOT
  # `Ash.Changeset.filter/2`: a filter added from a change is silently
  # dropped on the atomic-upgrade path (ash 3.x update.ex overwrites the
  # rebuilt changeset's `filter` with the original's `added_filter`, and
  # `record_added_filter` only records in the `:pending` phase — changes
  # never run there). The error-branch also gets savepoint-wrapped by
  # ash_postgres (`with_savepoint/3` on `has_error?` expressions), so a
  # fence miss inside an enclosing transaction rolls back to the savepoint
  # and the transaction stays usable — load-bearing for the checked
  # checkpoint save.
  # ---------------------------------------------------------------------------

  defmodule Changes.AnchorResume do
    @moduledoc """
    Atomic fenced write of `metadata["resume"]["state"]`.

    Fence (in-expression; a miss raises `StaleRecord`, never a silent
    no-op): the stored `forge_recovery.token` must equal the caller's
    `incarnation_token` AND the stored state revision (absent ⇒ `-1`) must
    be strictly older than the incoming copy's. The `||` parent-merge
    preserves `metadata["resume"]["guidance"]` and every top-level sibling
    (`forge_recovery` above all) by construction.
    """
    use Ash.Resource.Change

    import Ash.Expr

    @impl Ash.Resource.Change
    def atomic(changeset, _opts, _context) do
      token = Ash.Changeset.get_argument(changeset, :incarnation_token)
      state = Ash.Changeset.get_argument(changeset, :resume)

      case state do
        %{"revision" => revision} when is_integer(revision) and revision >= 0 ->
          encoded = Jason.encode!(state)

          {:atomic,
           %{
             metadata:
               {:atomic,
                expr(
                  if fragment(
                       "(? #>> array['forge_recovery','token']) = ? AND coalesce((? #>> array['resume','state','revision'])::int, -1) < ?",
                       metadata,
                       ^token,
                       metadata,
                       ^revision
                     ) do
                    fragment(
                      "jsonb_set(coalesce(?, '{}'::jsonb), array['resume']::text[], coalesce(? -> 'resume', '{}'::jsonb) || jsonb_build_object('state', ?::text::jsonb), true)",
                      metadata,
                      metadata,
                      ^encoded
                    )
                  else
                    error(Ash.Error.Changes.StaleRecord, %{
                      resource: "JidoClaw.Forge.Resources.Session",
                      filter: %{fence: "anchor_resume"}
                    })
                  end
                )}
           }}

        _ ->
          {:error, "anchor_resume requires an encoded state carrying an integer revision"}
      end
    end
  end

  defmodule Changes.PointRecoveryCheckpoint do
    @moduledoc """
    Atomic token-fenced pointer move: merges `{current_checkpoint_id,
    recovery_degraded: false}` into `metadata["forge_recovery"]` and (when
    given) mirrors the guidance marker into `metadata["resume"]["guidance"]`
    — one UPDATE, sibling keys and the sibling `resume.state` path
    preserved. Never touches `resume.state`.
    """
    use Ash.Resource.Change

    import Ash.Expr

    alias Ash.Changeset

    @impl Ash.Resource.Change
    def atomic(changeset, _opts, _context) do
      token = Changeset.get_argument(changeset, :incarnation_token)
      checkpoint_id = Changeset.get_argument(changeset, :checkpoint_id)
      marker = Changeset.get_argument(changeset, :guidance_marker)

      recovery_patch =
        Jason.encode!(%{"current_checkpoint_id" => checkpoint_id, "recovery_degraded" => false})

      atomic_metadata =
        case marker do
          nil ->
            expr(
              if fragment("(? #>> array['forge_recovery','token']) = ?", metadata, ^token) do
                fragment(
                  "jsonb_set(coalesce(?, '{}'::jsonb), array['forge_recovery']::text[], coalesce(? -> 'forge_recovery', '{}'::jsonb) || ?::text::jsonb, true)",
                  metadata,
                  metadata,
                  ^recovery_patch
                )
              else
                error(Ash.Error.Changes.StaleRecord, %{
                  resource: "JidoClaw.Forge.Resources.Session",
                  filter: %{fence: "point_recovery_checkpoint"}
                })
              end
            )

          marker ->
            expr(
              if fragment("(? #>> array['forge_recovery','token']) = ?", metadata, ^token) do
                fragment(
                  "jsonb_set(jsonb_set(coalesce(?, '{}'::jsonb), array['forge_recovery']::text[], coalesce(? -> 'forge_recovery', '{}'::jsonb) || ?::text::jsonb, true), array['resume']::text[], coalesce(? -> 'resume', '{}'::jsonb) || jsonb_build_object('guidance', ?::text::jsonb), true)",
                  metadata,
                  metadata,
                  ^recovery_patch,
                  metadata,
                  ^Jason.encode!(marker)
                )
              else
                error(Ash.Error.Changes.StaleRecord, %{
                  resource: "JidoClaw.Forge.Resources.Session",
                  filter: %{fence: "point_recovery_checkpoint"}
                })
              end
            )
        end

      {:atomic, %{metadata: {:atomic, atomic_metadata}}}
    end
  end

  defmodule Changes.MarkRecoveryDegraded do
    @moduledoc """
    Atomic token-fenced `forge_recovery.recovery_degraded = true` merge.
    The fence is the point: a stale incarnation's failed checkpoint can
    never mark a newer incarnation degraded.
    """
    use Ash.Resource.Change

    import Ash.Expr

    @impl Ash.Resource.Change
    def atomic(changeset, _opts, _context) do
      token = Ash.Changeset.get_argument(changeset, :incarnation_token)

      {:atomic,
       %{
         metadata:
           {:atomic,
            expr(
              if fragment("(? #>> array['forge_recovery','token']) = ?", metadata, ^token) do
                fragment(
                  "jsonb_set(coalesce(?, '{}'::jsonb), array['forge_recovery']::text[], coalesce(? -> 'forge_recovery', '{}'::jsonb) || '{\"recovery_degraded\": true}'::jsonb, true)",
                  metadata,
                  metadata
                )
              else
                error(Ash.Error.Changes.StaleRecord, %{
                  resource: "JidoClaw.Forge.Resources.Session",
                  filter: %{fence: "mark_recovery_degraded"}
                })
              end
            )}
       }}
    end
  end

  defmodule Changes.MintForgeRecovery do
    @moduledoc """
    The mint's metadata install: replaces the `forge_recovery` and `resume`
    keys wholesale (new epoch/token, pointer cleared, stamped transplant)
    while preserving every other metadata key. A deliberate read-modify-
    write on `changeset.data` — sound ONLY under the FOR-UPDATE row lock
    `JidoClaw.Forge.Persistence.mint_resume_epoch/3` holds, which is the
    single permitted caller.
    """
    use Ash.Resource.Change

    alias Ash.Changeset

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      forge_recovery = Changeset.get_argument(changeset, :forge_recovery)
      resume = Changeset.get_argument(changeset, :resume)

      merged =
        (changeset.data.metadata || %{})
        |> Map.put("forge_recovery", forge_recovery)
        |> Map.put("resume", resume)

      Changeset.change_attribute(changeset, :metadata, merged)
    end
  end
end
