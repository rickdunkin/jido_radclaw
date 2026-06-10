defmodule JidoClaw.Conversations.Message do
  @moduledoc """
  Tenant- and session-scoped message row.

  Replaces the legacy `.jido/sessions/<tenant>/<id>.jsonl` writer in
  `JidoClaw.Session.Worker`. Persists the full conversation history —
  user, assistant, tool_call, tool_result, reasoning, system — to
  Postgres so:

    * the consolidator (Phase 3) has a real query surface
    * tool activity is recoverable across BEAM restarts
    * the redaction pipeline runs once at the persistence boundary

  ## Identities

  Three identities, two of them partial:

    * `unique_session_sequence` — total `(session_id, sequence)`. Every
      row in a session has a monotonic sequence allocated by raw SQL
      under `:append`'s transaction (see Sequence allocation below).
    * `unique_import_hash` — partial on `(session_id, import_hash)`
      where `import_hash IS NOT NULL`. Used by the JSONL→Postgres
      migrator for idempotency.
    * `unique_live_tool_row` — partial on
      `(session_id, request_id, tool_call_id, role)` where the row is a
      `:tool_call` or `:tool_result` and `request_id IS NOT NULL`.
      Catches Recorder retries and double-fires of `Signal.ToolStart`
      / `Signal.ToolResult` so the second insert is rejected by Postgres.

  Both partial identities are registered via
  `postgres do … identity_wheres_to_sql … end` so AshPostgres emits the
  correct `WHERE` clause on the unique index.

  ## Sequence allocation

  `:append` runs three `before_action` hooks in order:

    1. **Tenant denormalization** — fetch the parent
       `Conversations.Session` and copy its `tenant_id` onto the
       changeset. Callers supply `session_id` only.
    2. **Sequence allocation** — raw SQL inside the action transaction:
       `UPDATE conversation_sessions SET next_sequence = next_sequence + 1
        WHERE id = $session_id RETURNING next_sequence - 1`.
       Postgres's row-level lock on the session row serializes
       concurrent appends, so two callers writing to the same session
       always get monotonically increasing sequences.
    3. **Redaction** — pipe `content` and `metadata` through
       `JidoClaw.Security.Redaction.Transcript.redact/1`.

  `:import` does NOT run the sequence-allocation hook — the migrator
  passes `sequence` explicitly so re-runs preserve the legacy file
  order. `:import` runs only the cross-tenant FK validation hook.

  ## Cross-tenant FK invariant

  Both `:append` (via the tenant-denormalization hook) and `:import`
  (via a dedicated cross-tenant FK hook) refuse to insert a row whose
  caller-supplied `tenant_id` doesn't match the parent session's
  `tenant_id`. Error string is `cross_tenant_fk_mismatch`, matching
  the Solutions resource (`solution.ex:486`).
  """

  use JidoClaw.Resource, domain: JidoClaw.Conversations

  alias Ash.Changeset
  alias Ash.Query
  alias JidoClaw.Conversations.Session, as: SessionResource

  @roles [:user, :assistant, :tool_call, :tool_result, :reasoning, :system]

  postgres do
    table("messages")
    repo(JidoClaw.Repo)

    identity_wheres_to_sql(
      unique_import_hash: "import_hash IS NOT NULL",
      unique_live_tool_row: "request_id IS NOT NULL AND role IN ('tool_call', 'tool_result')"
    )

    custom_indexes do
      index([:session_id, :sequence])
      index([:session_id, :agent_id, :sequence])
      index([:request_id])
      index([:session_id, :role])
      index([:tool_call_id], where: "tool_call_id IS NOT NULL")
      index([:parent_message_id], where: "parent_message_id IS NOT NULL")
      index([:tenant_id, :session_id])

      index([:request_id, :role],
        where: "request_id IS NOT NULL",
        name: "messages_request_id_role_idx"
      )

      index([:search_vector],
        using: "gin",
        all_tenants?: true,
        name: "messages_search_vector_idx"
      )
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:append, action: :append)
    define(:import, action: :import)
    define(:for_session, action: :for_session, args: [:session_id])
    define(:for_session_primary, action: :for_session_primary, args: [:session_id])
    define(:for_session_agent, action: :for_session_agent, args: [:session_id, :agent_id])
    define(:since_watermark, action: :since_watermark, args: [:session_id, :watermark])

    define(:since_watermark_for_agent,
      action: :since_watermark_for_agent,
      args: [:session_id, :agent_id, :watermark]
    )

    define(:by_tool_call, action: :by_tool_call, args: [:session_id, :tool_call_id])
    define(:by_request, action: :by_request, args: [:session_id, :request_id])
    define(:for_consolidator, action: :for_consolidator)
    define(:by_id, action: :by_id, args: [:id], get?: true)
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)

    define(:tool_call_parent,
      action: :tool_call_parent,
      args: [:session_id, :request_id, :tool_call_id]
    )

    define(:by_live_tool_row,
      action: :by_live_tool_row,
      args: [:session_id, :request_id, :tool_call_id, :role],
      get?: true
    )
  end

  actions do
    defaults([:read, :destroy])

    create :append do
      primary?(true)

      accept([
        :session_id,
        :request_id,
        :agent_id,
        :subagent,
        :role,
        :content,
        :metadata,
        :tool_call_id,
        :parent_message_id,
        :run_id,
        :model,
        :input_tokens,
        :output_tokens,
        :latency_ms
      ])

      change({__MODULE__.Changes.DenormalizeTenant, []})
      change({__MODULE__.Changes.AllocateSequence, []})
      change({__MODULE__.Changes.RedactContent, []})
    end

    create :import do
      accept([
        :session_id,
        :request_id,
        :agent_id,
        :subagent,
        :role,
        :sequence,
        :content,
        :metadata,
        :tool_call_id,
        :parent_message_id,
        :import_hash,
        :inserted_at,
        :run_id,
        :model,
        :input_tokens,
        :output_tokens,
        :latency_ms
      ])

      change({__MODULE__.Changes.ValidateCrossTenantFk, []})
    end

    read :for_session do
      argument(:session_id, :uuid, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [sequence: :asc]))
    end

    read :since_watermark do
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:watermark, :integer, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id) and sequence > ^arg(:watermark)))
      prepare(build(sort: [sequence: :asc]))
    end

    # Per-agent compaction slice: every row stamped with this compaction
    # identity (main / a handoff worker / a spawned sub-agent). Backed by the
    # `(session_id, agent_id, sequence)` index. The Compactor filters slices
    # by identity so each agent compacts only its own durable transcript.
    read :for_session_agent do
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:agent_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id) and agent_id == ^arg(:agent_id)))
      prepare(build(sort: [sequence: :asc]))
    end

    # Watermarked per-agent slice. The watermark is a per-session `sequence`
    # (sequences are session-monotonic), so `sequence > watermark` combined
    # with the agent filter returns this agent's rows newer than its last
    # summarized point.
    read :since_watermark_for_agent do
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:agent_id, :string, allow_nil?: false)
      argument(:watermark, :integer, allow_nil?: false)

      filter(
        expr(
          session_id == ^arg(:session_id) and agent_id == ^arg(:agent_id) and
            sequence > ^arg(:watermark)
        )
      )

      prepare(build(sort: [sequence: :asc]))
    end

    # Primary conversation view: owner rows only (main + handoff workers),
    # excluding spawned sub-agent / workflow-step rows. Every cold reader of
    # the chat-visible transcript uses this so sub-agent turns never surface
    # in the rendered conversation. `subagent == false` (not `!= true`) is
    # safe because the column is NOT NULL with a `false` default.
    read :for_session_primary do
      argument(:session_id, :uuid, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id) and subagent == false))
      prepare(build(sort: [sequence: :asc]))
    end

    read :by_tool_call do
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:tool_call_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id) and tool_call_id == ^arg(:tool_call_id)))
      prepare(build(sort: [sequence: :asc]))
    end

    read :by_request do
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:request_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id) and request_id == ^arg(:request_id)))
      prepare(build(sort: [sequence: :asc]))
    end

    read :tool_call_parent do
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:request_id, :string, allow_nil?: false)
      argument(:tool_call_id, :string, allow_nil?: false)

      filter(
        expr(
          session_id == ^arg(:session_id) and
            request_id == ^arg(:request_id) and
            tool_call_id == ^arg(:tool_call_id) and
            role == :tool_call
        )
      )

      prepare(build(limit: 1, sort: [sequence: :asc]))
    end

    read :by_live_tool_row do
      get?(true)
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:request_id, :string, allow_nil?: false)
      argument(:tool_call_id, :string, allow_nil?: false)
      argument(:role, :atom, allow_nil?: false)

      filter(
        expr(
          session_id == ^arg(:session_id) and
            request_id == ^arg(:request_id) and
            tool_call_id == ^arg(:tool_call_id) and
            role == ^arg(:role)
        )
      )
    end

    read :for_consolidator do
      argument(:scope_kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:session]]
      )

      argument(:scope_fk_id, :uuid, allow_nil?: false)
      argument(:since_inserted_at, :utc_datetime_usec, allow_nil?: true)
      argument(:since_id, :uuid, allow_nil?: true)
      argument(:limit, :integer, allow_nil?: true, default: 500)

      prepare({__MODULE__.Preparations.ForConsolidator, []})
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

    attribute :session_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :request_id, :string do
      allow_nil?(true)
      public?(true)
    end

    # Durable compaction identity (see `JidoClaw.Reasoning.Compactor.Identity`):
    # `"main"` for both main surfaces, `"handoff:<uuid>:<tpl>"` for a routed
    # worker, the spawn tag for a sub-agent. Drives the agent-scoped slice
    # reads the Compactor filters on. NOT NULL, defaults to `"main"` so any
    # append that omits it is attributed to the main agent.
    attribute :agent_id, :string do
      allow_nil?(false)
      public?(true)
      default("main")
    end

    # `true` for spawned sub-agent / workflow-step rows. Drives the
    # `for_session_primary` cold-read filter so the chat-visible view never
    # surfaces sub-agent turns.
    attribute :subagent, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :role, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @roles)
    end

    attribute :sequence, :integer do
      allow_nil?(false)
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

    attribute :tool_call_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :parent_message_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :import_hash, :string do
      allow_nil?(true)
      public?(true)
    end

    # NOTE: writable? true because :import preserves legacy timestamps.
    # Default is `&DateTime.utc_now/0`, NOT the create_timestamp macro
    # (which sets writable? false and would block :import).
    attribute :inserted_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      writable?(true)
      default(&DateTime.utc_now/0)
    end

    # Telemetry merged from `RequestCorrelation` at append time.
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

    # Generated column — populated by Postgres `GENERATED ALWAYS AS (...) STORED`
    # via the `messages_search_vector` IMMUTABLE wrapper function. The Ash-emitted
    # migration is hand-edited to add the GENERATED clause and the wrapper SQL
    # function — without that, the column would be a plain nullable tsvector and
    # FTS queries would silently never match.
    attribute :search_vector, AshPostgres.Tsvector do
      allow_nil?(true)
      public?(false)
      writable?(false)
      generated?(true)
    end
  end

  relationships do
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    belongs_to :session, SessionResource do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    belongs_to :parent_message, __MODULE__ do
      source_attribute(:parent_message_id)
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(true)
    end
  end

  identities do
    identity(:unique_session_sequence, [:session_id, :sequence])

    identity(:unique_import_hash, [:session_id, :import_hash],
      where: expr(not is_nil(import_hash))
    )

    identity(:unique_live_tool_row, [:session_id, :request_id, :tool_call_id, :role],
      where: expr(not is_nil(request_id) and role in [:tool_call, :tool_result])
    )
  end

  # ---------------------------------------------------------------------------
  # Inline change modules
  # ---------------------------------------------------------------------------

  defmodule Changes.DenormalizeTenant do
    @moduledoc false
    use Ash.Resource.Change

    alias JidoClaw.Conversations.Resources.GlobalLookup
    alias JidoClaw.Conversations.Session

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        tenant_id = cs.tenant || Changeset.get_attribute(cs, :tenant_id)

        case Changeset.get_attribute(cs, :session_id) do
          nil ->
            Changeset.add_error(cs, field: :session_id, message: "session_required")

          session_id ->
            GlobalLookup.validate_tenant_match(
              cs,
              session_id,
              tenant_id,
              :session_id,
              &Session.by_id_global/1,
              "session_not_found"
            )
        end
      end)
    end
  end

  defmodule Changes.AllocateSequence do
    @moduledoc false
    use Ash.Resource.Change

    alias Ecto.Adapters.SQL

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        case cs.errors do
          [_ | _] ->
            cs

          _ ->
            session_id = Changeset.get_attribute(cs, :session_id)
            allocate(cs, session_id)
        end
      end)
    end

    defp allocate(cs, nil), do: cs

    defp allocate(cs, session_id) do
      session_uuid = Ecto.UUID.dump!(session_id)

      result =
        SQL.query!(
          JidoClaw.Repo,
          "UPDATE conversation_sessions SET next_sequence = next_sequence + 1 WHERE id = $1 RETURNING next_sequence - 1",
          [session_uuid]
        )

      case result.rows do
        [[seq]] ->
          Changeset.force_change_attribute(cs, :sequence, seq)

        _ ->
          Changeset.add_error(cs,
            field: :session_id,
            message: "sequence_allocation_failed"
          )
      end
    end
  end

  defmodule Changes.RedactContent do
    @moduledoc false
    use Ash.Resource.Change

    alias JidoClaw.Security.Redaction.Transcript

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        cs
        |> redact_attribute(:content)
        |> redact_attribute(:metadata)
      end)
    end

    defp redact_attribute(cs, attr) do
      case Changeset.get_attribute(cs, attr) do
        nil ->
          cs

        value ->
          Changeset.force_change_attribute(
            cs,
            attr,
            Transcript.redact(value)
          )
      end
    end
  end

  defmodule Changes.ValidateCrossTenantFk do
    @moduledoc false
    use Ash.Resource.Change

    alias JidoClaw.Conversations.Resources.GlobalLookup
    alias JidoClaw.Conversations.Session

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context) do
      Changeset.before_action(changeset, fn cs ->
        session_id = Changeset.get_attribute(cs, :session_id)
        tenant_id = cs.tenant || Changeset.get_attribute(cs, :tenant_id)
        validate(cs, session_id, tenant_id)
      end)
    end

    defp validate(cs, session_id, tenant_id) do
      GlobalLookup.validate_tenant_match(
        cs,
        session_id,
        tenant_id,
        :session_id,
        &Session.by_id_global/1,
        "session_not_found"
      )
    end
  end

  defmodule Preparations.ForConsolidator do
    @moduledoc """
    Watermarked, session-scoped read for the consolidator.

    Returns rows where `(inserted_at, id) > (since_inserted_at,
    since_id)` so the consolidator can resume from its last published
    watermark deterministically. When `since_inserted_at` is nil, all
    rows for the scope are returned.

    Restricted to `scope_kind: :session` — cross-session message
    consolidation at workspace/user/project tiers is a deliberate
    extension point, not a 3b deliverable.
    """
    use Ash.Resource.Preparation
    require Ash.Query

    @impl Ash.Resource.Preparation
    def prepare(query, _opts, _context) do
      fk = Query.get_argument(query, :scope_fk_id)
      since_at = Query.get_argument(query, :since_inserted_at)
      since_id = Query.get_argument(query, :since_id)
      limit = Query.get_argument(query, :limit)

      query
      |> Query.filter(session_id == ^fk)
      |> apply_since(since_at, since_id)
      |> Query.sort(inserted_at: :asc, id: :asc)
      |> Query.limit(limit)
    end

    defp apply_since(query, nil, _), do: query

    defp apply_since(query, since_at, nil) do
      Query.filter(query, inserted_at > ^since_at)
    end

    defp apply_since(query, since_at, since_id) do
      Query.filter(
        query,
        inserted_at > ^since_at or (inserted_at == ^since_at and id > ^since_id)
      )
    end
  end
end
