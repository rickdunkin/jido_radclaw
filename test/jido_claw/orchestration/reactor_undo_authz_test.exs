defmodule JidoClaw.Orchestration.ReactorUndoAuthzTest do
  @moduledoc """
  Pins that the additive, private `:reactor_undo` destroy on the tenant-scoped
  `Workspace` stays authorized under the normal tenant write policy.

  `public?(false)` keeps the action off code-interface / AshAdmin surfaces, but
  the `Ash.Reactor` undo path invokes it internally via
  `Ash.Changeset.for_destroy/3` — public exposure must not change authorization.
  This test calls it the same way the undo path does (a stub `:changeset`
  argument) and proves a tenant-matching actor succeeds while a wrong-tenant
  actor is denied. (`Project`'s `always()` undo is exercised by the keystone
  failure test in `ProjectRegistrationTest`.)
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Workspaces.Workspace

  setup do
    tenant = seed_tenant("undo-authz")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  test "a tenant-matching actor may run the private :reactor_undo destroy", %{
    tenant: tenant,
    actor: actor
  } do
    {:ok, workspace} = seed_workspace(tenant)

    assert :ok =
             workspace
             |> Ash.Changeset.for_destroy(:reactor_undo, %{changeset: :stub},
               tenant: tenant,
               actor: actor
             )
             |> Ash.destroy()

    assert {:ok, []} = Workspace.list(tenant: tenant, actor: actor)
  end

  test "a wrong-tenant actor is denied — authorization still runs despite public?(false)", %{
    tenant: tenant,
    actor: actor
  } do
    {:ok, workspace} = seed_workspace(tenant)
    other_actor = actor_for(seed_tenant("undo-authz-other"))

    assert {:error, _} =
             workspace
             |> Ash.Changeset.for_destroy(:reactor_undo, %{changeset: :stub},
               tenant: tenant,
               actor: other_actor
             )
             |> Ash.destroy()

    # The row survives the denied destroy.
    assert {:ok, [_]} = Workspace.list(tenant: tenant, actor: actor)
  end
end
