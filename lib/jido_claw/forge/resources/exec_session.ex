defmodule JidoClaw.Forge.Resources.ExecSession do
  @moduledoc """
  Tracks individual iteration completions within a Forge session.

  Each record represents one runner iteration (with sequence number, status
  transitions, and output capture). Ad-hoc `exec/3` calls are NOT tracked
  here — they log start/complete events directly.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Forge.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("forge_exec_sessions")
    repo(JidoClaw.Repo)
  end

  code_interface do
    define(:start)
    define(:complete)
  end

  actions do
    defaults([:read, :destroy])

    create :start do
      primary?(true)
      accept([:sequence, :command, :session_id, :metadata, :started_at])
      change(set_attribute(:status, :running))

      change(fn changeset, _ ->
        if Ash.Changeset.get_attribute(changeset, :started_at) do
          changeset
        else
          Ash.Changeset.force_change_attribute(changeset, :started_at, DateTime.utc_now())
        end
      end)
    end

    update :complete do
      require_atomic?(false)
      accept([])
      argument(:result_status, :atom, allow_nil?: false)
      argument(:output, :string)
      argument(:exit_code, :integer)
      argument(:raw_output_bytes, :integer)
      change(set_attribute(:status, arg(:result_status)))
      change(set_attribute(:output, arg(:output)))
      change(set_attribute(:exit_code, arg(:exit_code)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))

      change(fn changeset, _ ->
        changeset =
          Ash.Changeset.force_change_attribute(
            changeset,
            :output_size_bytes,
            Ash.Changeset.get_argument(changeset, :raw_output_bytes)
          )

        started_at = changeset.data.started_at

        if started_at do
          duration = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
          Ash.Changeset.force_change_attribute(changeset, :duration_ms, duration)
        else
          changeset
        end
      end)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :sequence, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :running, :completed, :failed, :cancelled])
    end

    attribute :command, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :exit_code, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :output, :string do
      allow_nil?(true)
      public?(false)
    end

    attribute :output_size_bytes, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :duration_ms, :integer do
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

    timestamps()
  end

  relationships do
    belongs_to :session, JidoClaw.Forge.Resources.Session do
      allow_nil?(false)
      public?(true)
    end
  end
end
