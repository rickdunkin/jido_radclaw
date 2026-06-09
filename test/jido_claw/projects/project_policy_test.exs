defmodule JidoClaw.Projects.ProjectPolicyTest do
  @moduledoc """
  Pins the `Projects.Project` policy contract.

  The resource is deliberately global (no tenant attribute) and
  `actor_present()` is the entire policy. Empirical semantics under the
  default read `access_type` (`:filter`): actor-less *reads* are filtered
  to nothing (`{:ok, []}`; `get?` lookups surface `NotFound`), while
  actor-less *writes* are hard-denied with `Ash.Error.Forbidden`.
  """

  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Projects.Project

  describe "reads" do
    test "actor-less read is filtered to nothing" do
      seed_project()

      assert {:ok, []} = Project.read()
    end

    test "any present actor can read, including the system shape" do
      seeded = seed_project()

      assert {:ok, projects} = Project.read(actor: actor_for("project-policy-user"))
      assert Enum.any?(projects, &(&1.id == seeded.id))

      assert {:ok, projects} = Project.read(actor: Actor.system("default"))
      assert Enum.any?(projects, &(&1.id == seeded.id))
    end

    test "actor-less get_by lookup cannot see the row" do
      seeded = seed_project()

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Project.get_by_github_full_name(seeded.github_full_name)

      assert {:ok, %Project{}} =
               Project.get_by_github_full_name(seeded.github_full_name,
                 actor: actor_for("project-policy-user")
               )
    end
  end

  describe "writes" do
    test "actor-less create is denied outright" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Project.create(%{name: "denied", github_full_name: unique_full_name()})
    end

    test "a present actor can create" do
      assert {:ok, %Project{}} =
               Project.create(
                 %{name: "allowed", github_full_name: unique_full_name()},
                 actor: actor_for("project-policy-user")
               )
    end
  end

  defp seed_project do
    Ash.Seed.seed!(Project, %{name: "seeded", github_full_name: unique_full_name()})
  end

  defp unique_full_name, do: "policy/repo-#{System.unique_integer([:positive])}"
end
