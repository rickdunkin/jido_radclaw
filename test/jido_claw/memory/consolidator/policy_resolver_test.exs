defmodule JidoClaw.Memory.Consolidator.PolicyResolverTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Memory.Consolidator.PolicyResolver
  alias JidoClaw.Workspaces.{Resolver, Workspace}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, :auto)

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, :manual)
    end)

    :ok
  end

  defp ensure_workspace(name, policy) do
    {:ok, workspace} =
      Resolver.ensure_workspace(
        "default",
        "/tmp/policy_test_#{name}_#{System.unique_integer([:positive])}"
      )

    Workspace.set_consolidation_policy(workspace, policy)
  end

  describe "gate/1 — :workspace scope" do
    test ":default policy → :ok" do
      {:ok, ws} = ensure_workspace("default", :default)

      scope = %{
        tenant_id: "default",
        scope_kind: :workspace,
        workspace_id: ws.id,
        user_id: nil,
        project_id: nil,
        session_id: nil
      }

      assert :ok = PolicyResolver.gate(scope)
    end

    test ":disabled policy → consolidation_disabled" do
      {:ok, ws} = ensure_workspace("disabled", :disabled)

      scope = %{
        tenant_id: "default",
        scope_kind: :workspace,
        workspace_id: ws.id,
        user_id: nil,
        project_id: nil,
        session_id: nil
      }

      assert {:skip, "consolidation_disabled"} = PolicyResolver.gate(scope)
    end

    test ":local_only policy → consolidation_local_runner_unavailable" do
      {:ok, ws} = ensure_workspace("local", :local_only)

      scope = %{
        tenant_id: "default",
        scope_kind: :workspace,
        workspace_id: ws.id,
        user_id: nil,
        project_id: nil,
        session_id: nil
      }

      assert {:skip, "consolidation_local_runner_unavailable"} = PolicyResolver.gate(scope)
    end
  end
end
