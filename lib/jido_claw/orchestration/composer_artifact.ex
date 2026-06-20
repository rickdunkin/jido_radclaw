defmodule JidoClaw.Orchestration.ComposerArtifact do
  @moduledoc """
  Encrypted-at-rest ref-store for a composer wave's artifact values (AR-2
  Phase 2b — the §15.3 / §6-§7 "no plaintext artifact value at rest"
  guarantee, P1).

  Every other durable surface a composer wave touches carries only an opaque
  `art_<hex>` `ref`; the value itself lives here once, AshCloak-encrypted in
  `encrypted_value`, and surfaces decrypted **only** at the wave boundary
  (`JidoClaw.RouteComposer.ArtifactContext` → the subagent's task). The
  in-memory provenance store and every persisted wave return hold the ref.

  ## Shape (the precedents)

    * **Ref + value-by-opaque-ref** mirrors `Conversations.ToolOutput`
      (`ref :string` + a `:by_ref`-style get + `art_<hex>`).
    * **Tenant** is a plain `tenant_id :string` attribute with **no**
      `belongs_to :tenant` — the ToolOutput shape, not WorkflowRun's
      tenants-FK shape — so best-effort writes never trip a tenants-FK.
      `:attribute` multitenancy, `global?(false)`, with a `:by_id_global`
      bypass for the cross-tenant guard lookup.
    * **Cloak** copies WorkflowRun's block: `value :binary` becomes the
      encrypted `encrypted_value` column + a decrypting `value` calculation.

  ## Lifecycle (`:pending → :active → :tombstoned`)

  2b only inserts `:pending` rows (`store_pending`) and resolves them
  *regardless of state* (`resolve_ref`/`resolve_value`); availability still
  derives from the in-memory fold. The `:active`/`:tombstoned` transitions
  (`activate_for_wave`, `tombstone_active`) and the active-keyed
  partial-unique index ship complete now but are wired in 2c. Each transition
  carries a single-state precondition (`Validations.RequireState`): `set_active`
  requires `:pending`, `tombstone_active` requires `:active`, so a `:pending` row
  can never be tombstoned nor a `:tombstoned` row reactivated.

  ## The `store_pending` encoding choreography (load-bearing)

  AshCloak rewrites the accepted cloaked `:value` into an argument of the
  attribute type `:binary` (it only carries the *encoded* blob), and only
  wires its Encrypt change for a cloaked attr **in the accept list**. So
  `store_pending` keeps `:value` in `accept` but exposes only a separate
  non-cloaked `:term` argument (the raw value) via `code_interface`. Its
  `change/3` runs *before* any `before_action` (so the Encrypt before_action
  sees the encoded blob): it validates `:term` is **supplied** (not non-nil —
  a `nil` artifact value is real and must round-trip), `Envelope.encode`s a
  versioned `{@artifact_version, normalized_term}` blob, and
  `force_set_argument(:value, blob)` (NOT `set_argument` — that trips
  `maybe_already_validated_error!`). `:value` MUST stay `allow_nil?: true`:
  AshCloak rebuilds the `:value` argument with the attribute's nullability,
  and `require_arguments` runs before `change/3`, so a non-null `value` would
  reject a `term:`-only call before the change fills it.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Orchestration,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  alias JidoClaw.Orchestration.ComposerArtifact.Envelope

  # Hand-copied tenant policy block (the `JidoClaw.Resource` macro can't
  # forward `extensions:`, so AshCloak can't ride it). The extra
  # `action_type(:action)` clause authorizes the generic `activate_for_wave`,
  # which matches none of create/update/destroy/read and is forbidden by
  # default under `Ash.Policy.Authorizer`.
  policies do
    bypass action(:by_id_global) do
      authorize_if(always())
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type(:read) do
      authorize_if(expr(tenant_id == ^actor(:tenant_id)))
    end

    policy action_type(:action) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end
  end

  # Encryption-at-rest for the artifact value (P1): the column becomes
  # `encrypted_value`, `value` becomes a decrypting calculation, and the
  # `store_pending` accepted `:value` is rewritten into an argument + Encrypt
  # change (see the moduledoc choreography).
  cloak do
    vault(JidoClaw.Security.Vault)
    attributes([:value])
  end

  postgres do
    table("composer_artifacts")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :parent_run_id, :name])

      # Backstop invariant-enforcer (NOT an Ash identity-with-where): at most
      # one `:active` artifact per `{tenant, parent_run_id, name, producer}`.
      # 2c's commit helper (`activate_for_wave`) holds uniqueness by
      # tombstoning-before-promoting in one txn; this index is the net.
      index([:tenant_id, :parent_run_id, :name, :producer],
        name: "composer_artifacts_active_ref_index",
        unique: true,
        where: "state = 'active'"
      )
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:store_pending, action: :store_pending)
    define(:list, action: :read)
    define(:destroy, action: :destroy)
    define(:resolve_ref, action: :resolve_ref, args: [:ref], get?: true)
    define(:pending_for_wave, action: :pending_for_wave, args: [:parent_run_id, :wave_index])
    define(:active_for_run, action: :active_for_run, args: [:parent_run_id])
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
    define(:activate_for_wave, action: :activate_for_wave, args: [:parent_run_id, :wave_index])
    define(:tombstone_active, action: :tombstone_active)
    define(:set_active, action: :set_active)
  end

  actions do
    defaults([:read, :destroy])

    # Insert a `:pending` artifact row. The raw value enters via the
    # non-cloaked `:term` argument; `:value` stays in `accept` only so
    # AshCloak wires its Encrypt change (see the moduledoc). `code_interface`
    # exposes `:term`, never `:value`.
    create :store_pending do
      description(
        "Insert a :pending artifact row from a raw :term value (encoded + encrypted at rest)."
      )

      primary?(true)

      accept([:ref, :name, :producer, :value, :child_run_id, :wave_index, :parent_run_id])

      argument(:term, :term, allow_nil?: true)

      # Synchronous (NOT a before_action) so the value is set before
      # AshCloak's Encrypt before_action reads it. Validates suppliedness via
      # `fetch_argument` — `{:ok, nil}` is a real nil artifact (encode it),
      # `:error` is an absent argument (reject).
      change(fn changeset, _context ->
        case Ash.Changeset.fetch_argument(changeset, :term) do
          {:ok, term} ->
            Ash.Changeset.force_set_argument(changeset, :value, Envelope.encode(term))

          :error ->
            Ash.Changeset.add_error(changeset, field: :term, message: "term_required")
        end
      end)

      change(__MODULE__.Changes.ValidateCrossTenantFk)
    end

    # Resolve a ref to its (still-encrypted) row, irrespective of state. The
    # decrypted value is materialized by `resolve_value/2` (Ash.load + decode).
    read :resolve_ref do
      description("Look up an artifact row by its opaque ref, irrespective of lifecycle state.")
      get?(true)
      argument(:ref, :string, allow_nil?: false)
      filter(expr(ref == ^arg(:ref)))
    end

    # Recovery/fold reads (consumed by 2c/2d).
    read :pending_for_wave do
      description("List a wave's :pending artifacts (recovery/fold read; consumed in 2c/2d).")
      argument(:parent_run_id, :uuid, allow_nil?: false)
      argument(:wave_index, :integer, allow_nil?: false)

      filter(
        expr(
          parent_run_id == ^arg(:parent_run_id) and wave_index == ^arg(:wave_index) and
            state == :pending
        )
      )
    end

    read :active_for_run do
      description(
        "List a composer parent's :active artifacts (recovery/fold read; consumed in 2c/2d)."
      )

      argument(:parent_run_id, :uuid, allow_nil?: false)
      filter(expr(parent_run_id == ^arg(:parent_run_id) and state == :active))
    end

    read :by_id_global do
      description(
        "Cross-tenant lookup of one artifact by id (policy-bypassed) for the cross-tenant guard."
      )

      get?(true)
      multitenancy(:bypass)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    # Multi-row `:pending → :active` promotion + tombstone-supersede. Defined
    # now, wired in 2c. `public?(false)` keeps it out of AshAdmin (the
    # `WorkflowRun.set_status` idiom). Returns the promoted count (`:integer`) —
    # `ActivateForWave.run/3` returns `{:ok, length(pendings)}`, so the return
    # type MUST be declared or Ash rejects the non-`:ok` generic-action return.
    action :activate_for_wave, :integer do
      description(
        "Promote a wave's :pending artifacts to :active, returning the count (wired in 2c)."
      )

      public?(false)
      argument(:parent_run_id, :uuid, allow_nil?: false)
      argument(:wave_index, :integer, allow_nil?: false)
      run(__MODULE__.ActivateForWave)
    end

    # Single-transition guards (P3): `require_atomic?(false)` mirrors
    # `WorkflowRun.set_status` and suppresses the non-atomic-validation compile
    # warning. `ActivateForWave.promote_one/3` calls these in-order
    # (pending→active, active→tombstoned), so the preconditions never block it.
    update :tombstone_active do
      description("Transition an :active artifact to :tombstoned (wired in 2c).")
      public?(false)
      require_atomic?(false)
      validate({__MODULE__.Validations.RequireState, expected: :active})
      change(set_attribute(:state, :tombstoned))
    end

    update :set_active do
      description("Promote a :pending artifact to :active (used by activate_for_wave).")
      public?(false)
      require_atomic?(false)
      validate({__MODULE__.Validations.RequireState, expected: :pending})
      change(set_attribute(:state, :active))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :ref, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :producer, :string do
      allow_nil?(false)
      public?(true)
    end

    # The only nullable attribute (load-bearing — see the moduledoc
    # choreography). Cloaked: stored as `encrypted_value`, read as a
    # decrypting `value` calculation. Holds the `Envelope.encode/1` blob.
    attribute :value, :binary do
      allow_nil?(true)
      public?(false)
    end

    attribute :state, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :active, :tombstoned])
    end

    attribute :child_run_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :wave_index, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :parent_run_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    timestamps()
  end

  identities do
    identity(:unique_ref, [:tenant_id, :ref])
  end

  @doc """
  Resolve a ref to its decrypted, decoded artifact value.

  `resolve_ref` (tenant-scoped) → `Ash.load(:value)` (vault-decrypt) →
  `Envelope.decode/1`. Returns `{:ok, term}` (a `nil` term is a real
  artifact value), or `{:error, reason}` for a missing ref, a decrypt
  failure, or a corrupt/over-cap envelope. Never raises — a vault raise is
  rescued into `{:error, {:decrypt_failed, _}}` (the `Replay` precedent).
  """
  @spec resolve_value(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def resolve_value(ref, opts) do
    with {:ok, %__MODULE__{} = row} <- resolve_ref(ref, opts),
         {:ok, blob} <- load_value(row, opts) do
      Envelope.decode(blob)
    end
  end

  defp load_value(row, opts) do
    case Ash.load(row, :value, tenant: opts[:tenant], actor: opts[:actor]) do
      {:ok, %__MODULE__{value: blob}} when is_binary(blob) -> {:ok, blob}
      {:ok, _no_blob} -> {:error, :artifact_value_missing}
      {:error, reason} -> {:error, {:decrypt_failed, reason}}
    end
  rescue
    # Cloak decrypt raises (missing cipher, key rotation, corrupt ciphertext)
    # are an open set; any of them means the value is unreadable.
    # reach:disable-next-line bare_rescue
    error -> {:error, {:decrypt_failed, Exception.message(error)}}
  end
end
