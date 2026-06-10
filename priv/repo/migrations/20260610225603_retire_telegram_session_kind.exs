defmodule JidoClaw.Repo.Migrations.RetireTelegramSessionKind do
  @moduledoc """
  The Telegram channel adapter was removed and `:telegram` dropped from the
  Session `kind` enum (an app-level Ash constraint, not a PG enum). Reclassify
  any existing telegram sessions as imported legacy so old rows can't trip the
  narrowed constraint.
  """

  use Ecto.Migration

  def up do
    execute("UPDATE conversation_sessions SET kind = 'imported_legacy' WHERE kind = 'telegram'")
  end

  def down, do: :ok
end
