defmodule JidoClaw.Repo.Migrations.V062MessageTelemetryAndConstraints do
  @moduledoc """
  v0.6 cleanup sprint:
    * Telemetry columns on `messages` and `request_correlations`.
    * Partial composite index `messages_request_id_role_idx`.
    * `conversation_sessions.next_sequence NOT NULL`.
  """

  use Ecto.Migration

  def up do
    alter table(:messages) do
      add(:run_id, :text)
      add(:model, :text)
      add(:input_tokens, :bigint)
      add(:output_tokens, :bigint)
      add(:latency_ms, :integer)
    end

    alter table(:request_correlations) do
      add(:run_id, :text)
      add(:model, :text)
      add(:input_tokens, :bigint)
      add(:output_tokens, :bigint)
      add(:latency_ms, :integer)
    end

    create(
      index(:messages, [:request_id, :role],
        where: "request_id IS NOT NULL",
        name: "messages_request_id_role_idx"
      )
    )

    execute("UPDATE conversation_sessions SET next_sequence = 1 WHERE next_sequence IS NULL")

    execute("ALTER TABLE conversation_sessions ALTER COLUMN next_sequence SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE conversation_sessions ALTER COLUMN next_sequence DROP NOT NULL")

    drop_if_exists(index(:messages, [:request_id, :role], name: "messages_request_id_role_idx"))

    alter table(:request_correlations) do
      remove(:run_id)
      remove(:model)
      remove(:input_tokens)
      remove(:output_tokens)
      remove(:latency_ms)
    end

    alter table(:messages) do
      remove(:run_id)
      remove(:model)
      remove(:input_tokens)
      remove(:output_tokens)
      remove(:latency_ms)
    end
  end
end
