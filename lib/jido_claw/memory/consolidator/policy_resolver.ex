defmodule JidoClaw.Memory.Consolidator.PolicyResolver do
  @moduledoc """
  Egress gate for the consolidator.

  Decides whether a per-scope run is allowed to invoke a remote
  harness based on the scope's effective `consolidation_policy`.

  Policy resolution per scope kind:
    * `:workspace` — read the workspace row directly.
    * `:session`   — read the parent workspace row.
    * `:user`      — most-restrictive across every workspace in the
      tenant keyed to that user.
    * `:project`   — most-restrictive across every workspace in the
      tenant referencing that project.

  Effective policy → run decision:
    * `:default`       → `:ok` (run with the configured remote
      harness)
    * `:local_only`    → `{:skip, "consolidation_local_runner_unavailable"}`
      (3c will route this to a local runner; today it skips)
    * `:disabled`      → `{:skip, "consolidation_disabled"}`
  """

  alias JidoClaw.Memory.Scope
  alias JidoClaw.Workspaces.PolicyTransitions
  alias JidoClaw.Workspaces.Workspace

  @type scope_record :: Scope.scope_record()

  @spec gate(scope_record()) :: :ok | {:skip, String.t()}
  def gate(%{scope_kind: :workspace, tenant_id: tenant_id, workspace_id: ws_id}) do
    case Ash.get(Workspace, ws_id, domain: JidoClaw.Workspaces) do
      {:ok, %{tenant_id: ^tenant_id, consolidation_policy: policy}} ->
        decide(policy)

      _ ->
        {:skip, "consolidation_disabled"}
    end
  end

  def gate(%{scope_kind: :session, workspace_id: nil}),
    do: {:skip, "consolidation_disabled"}

  def gate(%{scope_kind: :session} = scope) do
    gate(%{scope | scope_kind: :workspace})
  end

  def gate(%{scope_kind: :user, tenant_id: tenant_id, user_id: user_id})
      when is_binary(user_id) do
    tenant_id
    |> PolicyTransitions.resolve_consolidation_policy_for_user(user_id)
    |> decide()
  end

  def gate(%{scope_kind: :project, tenant_id: tenant_id, project_id: project_id})
      when is_binary(project_id) do
    tenant_id
    |> PolicyTransitions.resolve_consolidation_policy_for_project(project_id)
    |> decide()
  end

  def gate(_), do: {:skip, "consolidation_disabled"}

  defp decide(:default), do: :ok
  defp decide(:local_only), do: {:skip, "consolidation_local_runner_unavailable"}
  defp decide(:disabled), do: {:skip, "consolidation_disabled"}
  defp decide(_), do: {:skip, "consolidation_disabled"}
end
