defmodule JidoClaw.Memory.Consolidator.PolicyResolverTest do
  # async: false — setup flips the GLOBAL sandbox mode (Sandbox.mode :auto,
  # restored on exit), destroying every concurrent async test's ownership
  # isolation; also hardcodes the shared "default" tenant (row-locked by
  # api_key_auth_test, its sole async user).
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Memory.Consolidator.PolicyResolver
  alias JidoClaw.Workspaces.{Resolver, Workspace}

  setup do
    :ok = Sandbox.checkout(JidoClaw.Repo)
    :ok = Sandbox.mode(JidoClaw.Repo, :auto)

    on_exit(fn ->
      :ok = Sandbox.mode(JidoClaw.Repo, :manual)
    end)

    :ok
  end

  defp ensure_workspace(name, policy) do
    {:ok, workspace} =
      Resolver.ensure_workspace(
        "default",
        "/tmp/policy_test_#{name}_#{System.unique_integer([:positive])}"
      )

    Workspace.set_consolidation_policy(workspace, policy,
      tenant: "default",
      actor: Actor.system("default")
    )
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
  end
end
