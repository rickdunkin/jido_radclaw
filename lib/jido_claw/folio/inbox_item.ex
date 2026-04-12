defmodule JidoClaw.Folio.InboxItem do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Folio,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("folio_inbox_items")
    repo(JidoClaw.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :capture do
      primary?(true)
      accept([:title, :notes, :source, :user_id])
      change(set_attribute(:status, :inbox))
    end

    update :process do
      accept([])

      argument(:outcome, :atom,
        allow_nil?: false,
        constraints: [one_of: [:action, :project, :reference, :someday, :trash]]
      )

      change(set_attribute(:status, :processed))
      change(set_attribute(:processed_at, &DateTime.utc_now/0))
    end

    update :discard do
      accept([])
      change(set_attribute(:status, :discarded))
      change(set_attribute(:processed_at, &DateTime.utc_now/0))
    end

    read :unprocessed do
      filter(expr(status == :inbox))
    end

    read :by_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :title, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :notes, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :source, :string do
      allow_nil?(true)
      public?(true)
      default("manual")
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:inbox)
      constraints(one_of: [:inbox, :processed, :discarded])
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :processed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end
end
