defmodule JidoClaw.Memory.Changes.ValidateScopeFk do
  @moduledoc """
  Shared `:create` change for memory resources that carry a discriminated
  scope: requires the corresponding scope FK column (`user_id` /
  `workspace_id` / `project_id` / `session_id`) to be present on the
  changeset for whichever `scope_kind` was supplied.

  Resolves scope→FK from the changeset's attributes directly instead of
  delegating to a per-resource helper so the same module can be shared
  across `Fact`, `Block`, `ConsolidationRun` etc.
  """
  use Ash.Resource.Change

  alias Ash.Changeset

  @scope_attrs %{
    user: :user_id,
    workspace: :workspace_id,
    project: :project_id,
    session: :session_id
  }

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn cs ->
      scope_kind = Changeset.get_attribute(cs, :scope_kind)

      case Map.get(@scope_attrs, scope_kind) do
        nil ->
          add_missing(cs, scope_kind)

        attr ->
          case Changeset.get_attribute(cs, attr) do
            nil -> add_missing(cs, scope_kind)
            _id -> cs
          end
      end
    end)
  end

  defp add_missing(cs, scope_kind),
    do:
      Changeset.add_error(cs,
        field: :scope_kind,
        message: "scope_fk_required",
        vars: [scope_kind: scope_kind]
      )
end
