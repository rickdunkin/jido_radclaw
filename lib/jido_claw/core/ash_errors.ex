defmodule JidoClaw.Core.AshErrors do
  @moduledoc """
  Structural handling of Ash/DB errors that callers would otherwise have to
  string-match out of `inspect/1` output. Two concerns live here:

    * **Classification** (`unique_violation?/2`) — detect a DB-level unique
      violation structurally instead of by inspecting error strings.
    * **The canonical rescue list** (`db_errors/0`) — the single source of
      truth for the Ash/Postgrex exception structs the best-effort read/persist
      paths narrow their rescues on (`rescue _ in @db_errors`), so a real bug
      surfaces instead of being logged-and-swallowed.

  ## Unique violations

  A DB-level unique violation surfaces as `Ash.Error.Invalid` wrapping
  `Ash.Error.Changes.InvalidAttribute` whose `private_vars` carry
  `constraint: <index_name>` + `constraint_type: :unique` (built in
  ash_postgres `data_layer.ex`, from the Postgres constraint error).
  The structured handle is the **index** name — not the identity name —
  so callers must pass index-name fragments (mind
  `identity_index_names` shortenings on the resource).
  """

  @doc "Canonical Ash/DB exception structs the rescues narrow on (`rescue _ in @db_errors`)."
  @spec db_errors() :: [module()]
  def db_errors,
    do: [
      Ash.Error.Invalid,
      Ash.Error.Unknown,
      Ash.Error.Forbidden,
      Ash.Error.Query.NotFound,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ]

  @doc """
  True when `error` is an `Ash.Error.Invalid` carrying at least one
  unique-constraint violation whose index name contains any of
  `index_fragments`. Recurses into nested `Ash.Error.Invalid` errors.
  """
  @spec unique_violation?(term(), [String.t()]) :: boolean()
  def unique_violation?(%Ash.Error.Invalid{errors: errors}, index_fragments)
      when is_list(errors) do
    Enum.any?(errors, &unique_violation_error?(&1, index_fragments))
  end

  def unique_violation?(_other, _index_fragments), do: false

  # Recurses into nested %Ash.Error.Invalid{} so wrapped error trees
  # (which the recorder's previous inspect-based matcher tolerated by
  # accident) are still classified.
  defp unique_violation_error?(%Ash.Error.Invalid{errors: nested}, fragments)
       when is_list(nested) do
    Enum.any?(nested, &unique_violation_error?(&1, fragments))
  end

  defp unique_violation_error?(%Ash.Error.Changes.InvalidAttribute{private_vars: vars}, fragments)
       when is_list(vars) do
    vars[:constraint_type] == :unique and is_binary(vars[:constraint]) and
      String.contains?(vars[:constraint], fragments)
  end

  defp unique_violation_error?(_other, _fragments), do: false
end
