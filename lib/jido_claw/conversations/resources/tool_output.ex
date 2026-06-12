defmodule JidoClaw.Conversations.ToolOutput do
  @moduledoc """
  Tenant-scoped storage for full tool output captured by
  `JidoClaw.Tools.OutputShaper`.

  When the shaper compresses a verbose tool result (e.g. `mix test`
  output) into counts + verbatim failures, the complete captured text is
  stored here under an opaque `ref` (`out_<hex>`) so the agent can drill
  back in via the `fetch_output` tool instead of re-running the command.
  Reversibility is the safety property that makes shaping acceptable.

  ## Semantics

    * `content` holds what the shaper **captured** — complete up to the
      configured `capture_bytes` cap. `truncated: true` flags rows whose
      upstream capture hit that cap, so `fetch_output` can keep the
      "captured, not full" context honest.
    * `session_id` is nullable: MCP serve-mode session resolution can
      fail while the tenant is still known. A present `session_id` must
      belong to the row's tenant (same `before_action` validate-equality
      shape as `Conversations.Session`'s workspace check).
    * There is deliberately no `belongs_to :tenant` — `tenant_id` is a
      plain attribute, so best-effort storage never trips a tenants-FK
      for surfaces that resolved a tenant string without a Tenant row.
    * `command` is stored **pre-redacted** by the caller
      (`OutputShaper.Store`) — tool params never pass through result
      redaction, so a secret-bearing command must be scrubbed before it
      lands here. `command_fingerprint` is computed on the raw command
      (stable across redaction changes) for previous-run delta lookups.
    * Rows are pruned best-effort on insert by `OutputShaper.Store`
      using the `:expired` read + `Ash.bulk_destroy` (TTL configured by
      `:output_shaping`'s `ref_ttl_days`).
  """

  use JidoClaw.Resource, domain: JidoClaw.Conversations

  alias JidoClaw.Conversations.Resources.GlobalLookup
  alias JidoClaw.Conversations.Session

  postgres do
    table("tool_outputs")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :session_id, :command_fingerprint])
      index([:tenant_id, :inserted_at])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:store, action: :store)
    define(:by_ref, action: :by_ref, args: [:ref], get?: true)

    define(:latest_for_fingerprint,
      action: :latest_for_fingerprint,
      args: [:session_id, :command_fingerprint, :tool],
      get?: true
    )

    define(:expired, action: :expired, args: [:cutoff])
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :store do
      primary?(true)

      accept([
        :ref,
        :session_id,
        :command_fingerprint,
        :tool,
        :command,
        :content,
        :byte_size,
        :truncated,
        :exit_code,
        :summary
      ])

      change(fn changeset, _ctx ->
        Ash.Changeset.before_action(changeset, fn cs ->
          tenant_id = cs.tenant || Ash.Changeset.get_attribute(cs, :tenant_id)
          session_id = Ash.Changeset.get_attribute(cs, :session_id)

          GlobalLookup.validate_tenant_match(
            cs,
            session_id,
            tenant_id,
            :session_id,
            &Session.by_id_global/1,
            "session_not_found"
          )
        end)
      end)
    end

    read :by_ref do
      get?(true)
      argument(:ref, :string, allow_nil?: false)
      filter(expr(ref == ^arg(:ref)))
    end

    # Latest stored output for the same command in the same session — the
    # previous-run delta lookup. Filtering on `tool` keeps comparisons
    # within one tool now that more than `run_command` stores rows.
    read :latest_for_fingerprint do
      get?(true)
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:command_fingerprint, :string, allow_nil?: false)
      argument(:tool, :string, allow_nil?: false)

      filter(
        expr(
          session_id == ^arg(:session_id) and
            command_fingerprint == ^arg(:command_fingerprint) and
            tool == ^arg(:tool)
        )
      )

      prepare(build(sort: [inserted_at: :desc], limit: 1))
    end

    read :expired do
      description("List rows older than the supplied cutoff (TTL prune candidates).")
      argument(:cutoff, :utc_datetime_usec, allow_nil?: false)
      filter(expr(inserted_at < ^arg(:cutoff)))
      prepare(build(sort: [inserted_at: :asc]))
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

    attribute :ref, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :session_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :command_fingerprint, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :tool, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :command, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :content, :string do
      allow_nil?(false)
      public?(false)
      # Ash's default trim?: true would silently strip leading/trailing
      # whitespace, breaking byte-faithful reversibility (stored content
      # must round-trip exactly what the shaper captured; byte_size is
      # computed from it).
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :byte_size, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :truncated, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :exit_code, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :summary, :map do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to :session, JidoClaw.Conversations.Session do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(true)
    end
  end

  identities do
    identity(:unique_ref, [:tenant_id, :ref])
  end
end
