defmodule JidoClaw.Forge.Resources.Checkpoint do
  @moduledoc false
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Forge.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("forge_checkpoints")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:session_id, :created_at])
    end
  end

  code_interface do
    define(:create)
    define(:create_recovery)
    define(:latest_for_session)
    define(:read, action: :read)
    define(:destroy, action: :destroy)
    define(:get_by_id, action: :read, get_by: [:id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      description("Record a sandbox checkpoint for a session.")
      primary?(true)

      accept([
        :name,
        :sandbox_checkpoint_id,
        :exec_session_sequence,
        :runner_state_snapshot,
        :session_id,
        :metadata
      ])
    end

    create :create_recovery do
      description(
        "Checked-save variant: creates the row under a caller-minted id so " <>
          "the fenced Session pointer write can run FIRST in the same " <>
          "transaction (a stale refusal then writes nothing at all). The " <>
          "named argument sets the pk inside the action — never a broad " <>
          "accept :id."
      )

      accept([
        :name,
        :sandbox_checkpoint_id,
        :exec_session_sequence,
        :runner_state_snapshot,
        :session_id,
        :metadata
      ])

      argument(:checkpoint_id, :uuid, allow_nil?: false)
      change(set_attribute(:id, arg(:checkpoint_id)))
    end

    read :latest_for_session do
      description("Fetch the most recent checkpoint for a session.")
      argument(:session_id, :uuid, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [created_at: :desc], limit: 1))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :sandbox_checkpoint_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :exec_session_sequence, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :runner_state_snapshot, :map do
      allow_nil?(true)
      public?(false)
    end

    attribute :metadata, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :session, JidoClaw.Forge.Resources.Session do
      allow_nil?(false)
      public?(true)
    end
  end
end
