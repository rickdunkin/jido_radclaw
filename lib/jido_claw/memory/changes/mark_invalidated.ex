defmodule JidoClaw.Memory.Changes.MarkInvalidated do
  @moduledoc """
  Shared `:invalidate` change that stamps both `invalid_at` and
  `expired_at` to `now()` so the row drops out of the active and live
  views simultaneously.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      now = DateTime.utc_now()

      cs
      |> Ash.Changeset.force_change_attribute(:invalid_at, now)
      |> Ash.Changeset.force_change_attribute(:expired_at, now)
    end)
  end
end
