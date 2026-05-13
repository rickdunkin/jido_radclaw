defmodule JidoClaw.Memory.Resources.ScopeFilter do
  @moduledoc """
  Shared Ash query helper that narrows a query by `(scope_kind, fk)`.

  Extracted from `Memory.Fact`, `Memory.Episode`, and
  `Memory.ConsolidationRun` — each previously carried a byte-identical
  4-clause `apply_scope_filter/3`. The helper centralises the
  `Ash.Query.filter/2` calls so the filter shape can evolve in one
  place when scope semantics change.
  """

  require Ash.Query

  @doc """
  Narrow `query` to rows whose `scope_kind` and the corresponding FK
  match `kind` / `fk`.
  """
  @spec apply(Ash.Query.t(), :user | :workspace | :project | :session, term()) ::
          Ash.Query.t()
  def apply(query, :user, fk) do
    Ash.Query.filter(query, scope_kind == :user and user_id == ^fk)
  end

  def apply(query, :workspace, fk) do
    Ash.Query.filter(query, scope_kind == :workspace and workspace_id == ^fk)
  end

  def apply(query, :project, fk) do
    Ash.Query.filter(query, scope_kind == :project and project_id == ^fk)
  end

  def apply(query, :session, fk) do
    Ash.Query.filter(query, scope_kind == :session and session_id == ^fk)
  end
end
