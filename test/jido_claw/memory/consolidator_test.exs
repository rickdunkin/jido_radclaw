defmodule JidoClaw.Memory.ConsolidatorTest do
  @moduledoc """
  Regression coverage for the tick's cross-tenant candidate discovery.

  Before v0.6.4 `read_workspaces/0` and `active_session_scopes/1` ran
  untenanted reads against tenant-required resources; every read failed
  with `TenantRequired`, the rescue collapsed it to `[]`, and cron-driven
  consolidation silently discovered zero scopes. These tests pin the
  fixed path — the dedicated cross-tenant read actions
  (`Workspace.list_consolidatable_global`,
  `Session.list_open_for_workspaces_global`) — through the exact seam
  `tick/0` drives.
  """

  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Memory.Consolidator

  describe "candidate_scopes/1" do
    test "discovers workspace/user/project/session scopes across tenants" do
      tenant_a = seed_tenant("disc-a")
      tenant_b = seed_tenant("disc-b")

      user =
        Ash.Seed.seed!(JidoClaw.Accounts.User, %{
          email: "consolidator-disc-#{System.unique_integer([:positive])}@test.local"
        })

      project =
        Ash.Seed.seed!(JidoClaw.Projects.Project, %{
          name: "disc-project",
          github_full_name: "disc/repo-#{System.unique_integer([:positive])}"
        })

      {:ok, ws_a} =
        seed_workspace(tenant_a,
          consolidation_policy: :default,
          user_id: user.id,
          project_id: project.id
        )

      {:ok, open_session} = seed_session(tenant_a, ws_a.id)
      {:ok, closed_session} = seed_session(tenant_a, ws_a.id)

      {:ok, _} =
        Session.close(closed_session, %{}, tenant: tenant_a, actor: actor_for(tenant_a))

      {:ok, ws_disabled} = seed_workspace(tenant_a, consolidation_policy: :disabled)
      {:ok, ws_b} = seed_workspace(tenant_b, consolidation_policy: :default)

      scopes =
        100
        |> Consolidator.candidate_scopes()
        |> Enum.filter(&(&1.tenant_id in [tenant_a, tenant_b]))

      # Workspace scopes surface from BOTH tenants — the broken discovery
      # returned [] here.
      assert Enum.any?(
               scopes,
               &(&1.scope_kind == :workspace and &1.workspace_id == ws_a.id and
                   &1.tenant_id == tenant_a)
             )

      assert Enum.any?(
               scopes,
               &(&1.scope_kind == :workspace and &1.workspace_id == ws_b.id and
                   &1.tenant_id == tenant_b)
             )

      assert Enum.any?(
               scopes,
               &(&1.scope_kind == :user and &1.user_id == user.id and &1.tenant_id == tenant_a)
             )

      assert Enum.any?(
               scopes,
               &(&1.scope_kind == :project and &1.project_id == project.id and
                   &1.tenant_id == tenant_a)
             )

      assert Enum.any?(
               scopes,
               &(&1.scope_kind == :session and &1.session_id == open_session.id and
                   &1.tenant_id == tenant_a)
             )

      # Opted-out workspace contributes nothing; closed sessions don't
      # become session scopes.
      refute Enum.any?(scopes, &(&1.workspace_id == ws_disabled.id))

      refute Enum.any?(
               scopes,
               &(&1.scope_kind == :session and &1.session_id == closed_session.id)
             )
    end

    test "caps the candidate list at max_candidates" do
      tenant_id = seed_tenant("disc-cap")

      for _ <- 1..3 do
        {:ok, _ws} = seed_workspace(tenant_id, consolidation_policy: :default)
      end

      assert [_, _] = Consolidator.candidate_scopes(2)
    end
  end
end
