defmodule JidoClaw.Memory.BlockRevision do
  @moduledoc """
  Append-only history rows for `JidoClaw.Memory.Block` `:revise` /
  `:invalidate` calls.

  Every block mutation that changes `value` (or invalidates) inserts
  one row here recording the prior value, source, and reason. The
  `Block.:revise` action's `after_action` hook writes the revision
  inside the same Ash transaction that updates the live row, so a
  partial failure rolls both back together.

  No `:update`, no `:destroy`. The denormalized scope columns
  (`tenant_id`, `scope_kind`, `user_id`, `workspace_id`, `project_id`,
  `session_id`) are populated from the parent Block at write time —
  the parent's columns can drift over time but the revision row
  preserves the snapshot. This means a `BlockRevision` query can
  always project back to the right scope without joining Block.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Memory.Domain,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false

  @scope_kinds [:user, :workspace, :project, :session]
  @sources [:user, :consolidator]

  postgres do
    table("memory_block_revisions")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:block_id, :inserted_at])
      index([:tenant_id, :scope_kind, :inserted_at])
    end
  end

  code_interface do
    define(:create_for_block, action: :create_for_block)
    define(:for_block, action: :for_block, args: [:block_id])
  end

  actions do
    defaults([:read])

    create :create_for_block do
      primary?(true)

      accept([
        :block_id,
        :tenant_id,
        :scope_kind,
        :user_id,
        :workspace_id,
        :project_id,
        :session_id,
        :value,
        :source,
        :written_by,
        :reason
      ])
    end

    read :for_block do
      argument(:block_id, :uuid, allow_nil?: false)
      filter(expr(block_id == ^arg(:block_id)))
      prepare(build(sort: [inserted_at: :asc]))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :block_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

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

    attribute :value, :string do
      allow_nil?(true)
      public?(true)
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

    attribute :reason, :string do
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

  relationships do
    belongs_to :block, JidoClaw.Memory.Block do
      define_attribute?(false)
      attribute_writable?(true)
    end
  end
end
