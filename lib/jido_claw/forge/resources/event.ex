defmodule JidoClaw.Forge.Resources.Event do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Forge.Domain,
    data_layer: AshPostgres.DataLayer

  require Ash.Query

  postgres do
    table("forge_events")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:session_id, :timestamp])
    end
  end

  code_interface do
    define(:create)
    define(:list_for_session, action: :for_session)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:event_type, :data, :exec_session_sequence, :session_id])
    end

    read :for_session do
      argument(:session_id, :uuid, allow_nil?: false)
      argument(:after, :utc_datetime_usec)
      argument(:event_types, {:array, :string})
      argument(:limit, :integer)
      argument(:after_sequence, :integer)

      filter(expr(session_id == ^arg(:session_id)))

      prepare(fn query, _context ->
        query
        |> then(fn q ->
          case Ash.Query.get_argument(q, :after) do
            nil -> q
            after_ts -> Ash.Query.filter(q, expr(timestamp > ^after_ts))
          end
        end)
        |> then(fn q ->
          case Ash.Query.get_argument(q, :after_sequence) do
            nil -> q
            seq -> Ash.Query.filter(q, expr(exec_session_sequence > ^seq))
          end
        end)
        |> then(fn q ->
          case Ash.Query.get_argument(q, :event_types) do
            nil -> q
            [] -> q
            types -> Ash.Query.filter(q, expr(event_type in ^types))
          end
        end)
        |> then(fn q ->
          case Ash.Query.get_argument(q, :limit) do
            nil -> q
            limit -> Ash.Query.limit(q, limit)
          end
        end)
        |> Ash.Query.sort(timestamp: :asc)
      end)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :event_type, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :data, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :exec_session_sequence, :integer do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:timestamp)
  end

  relationships do
    belongs_to :session, JidoClaw.Forge.Resources.Session do
      allow_nil?(false)
      public?(true)
    end
  end
end
