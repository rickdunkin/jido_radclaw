defmodule JidoClaw.Forge.Resources.Checkpoint do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Forge.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "forge_checkpoints"
    repo JidoClaw.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :sandbox_checkpoint_id, :exec_session_sequence, :runner_state_snapshot, :session_id, :metadata]
    end

    read :latest_for_session do
      argument :session_id, :uuid, allow_nil?: false
      filter expr(session_id == ^arg(:session_id))
      prepare build(sort: [created_at: :desc], limit: 1)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? true
      public? true
    end

    attribute :sandbox_checkpoint_id, :string do
      allow_nil? true
      public? true
    end

    attribute :exec_session_sequence, :integer do
      allow_nil? true
      public? true
    end

    attribute :runner_state_snapshot, :map do
      allow_nil? true
      public? false
    end

    attribute :metadata, :map do
      allow_nil? true
      public? true
      default %{}
    end

    create_timestamp :created_at
  end

  relationships do
    belongs_to :session, JidoClaw.Forge.Resources.Session do
      allow_nil? false
      public? true
    end
  end
end
