defmodule JidoClaw.Solutions.SolutionTest do
  use JidoClaw.SolutionsCase, async: true

  alias JidoClaw.Repo
  alias JidoClaw.Solutions.Solution

  # Reputation × Trust composition coverage lives in
  # `test/jido_claw/solutions/reputation_test.exs`.

  describe "import_legacy + ResolveInitialEmbeddingStatus" do
    test "system import under :disabled workspace lands at :disabled (not :pending)" do
      tenant_id = unique_tenant_id()
      workspace = workspace_fixture(tenant_id, embedding_policy: :disabled)

      sig =
        Base.encode16(:crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}"),
          case: :lower
        )

      # Omit :embedding_status so the change's resolution path runs.
      # Setting it would short-circuit the change and pass the test
      # without exercising fix 3.
      attrs = %{
        problem_signature: sig,
        solution_content: "x = 1",
        language: "elixir",
        sharing: :local,
        workspace_id: workspace.id
      }

      # `authorize?: false` mirrors the migration task's call shape —
      # the change's system-actor fallback (fix 3) is what makes the
      # nested Workspace.by_id lookup succeed under the read policy.
      assert {:ok, solution} =
               Solution.import_legacy(attrs, tenant: tenant_id, authorize?: false)

      assert solution.embedding_status == :disabled
    end
  end

  describe "trust is never caller-asserted at create (H6)" do
    test ":store rejects trust_score/verification in attrs with NoSuchInput" do
      tenant_id = unique_tenant_id()
      workspace = workspace_fixture(tenant_id)

      sig =
        Base.encode16(:crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}"),
          case: :lower
        )

      attrs = %{
        problem_signature: sig,
        solution_content: "x = 1",
        language: "elixir",
        sharing: :local,
        workspace_id: workspace.id,
        embedding_status: :disabled,
        trust_score: 1.0,
        verification: %{"status" => "passed"}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Solution.store(attrs, tenant: tenant_id, actor: actor_for(tenant_id))

      assert inspect(err) =~ ~r/trust_score|verification/
    end

    test ":import_legacy still accepts trust_score (intentional contrast — fixtures seed pre-earned trust)" do
      tenant_id = unique_tenant_id()
      workspace = workspace_fixture(tenant_id)

      sig =
        Base.encode16(:crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}"),
          case: :lower
        )

      attrs = %{
        problem_signature: sig,
        solution_content: "x = 1",
        language: "elixir",
        sharing: :local,
        workspace_id: workspace.id,
        embedding_status: :disabled,
        trust_score: 0.9
      }

      assert {:ok, solution} =
               Solution.import_legacy(attrs, tenant: tenant_id, actor: actor_for(tenant_id))

      assert solution.trust_score == 0.9
    end
  end

  describe "cross-tenant FK rejection" do
    test ":store rejects a (tenant_id, workspace_id) pair where the workspace lives in a different tenant" do
      tenant_a = unique_tenant_id()
      tenant_b = unique_tenant_id()

      workspace_a = workspace_fixture(tenant_a, embedding_policy: :disabled)
      _workspace_b_setup = workspace_fixture(tenant_b, embedding_policy: :disabled)

      actor_b = actor_for(tenant_b)

      sig =
        Base.encode16(:crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}"),
          case: :lower
        )

      attrs = %{
        problem_signature: sig,
        solution_content: "x = 1",
        language: "elixir",
        sharing: :local,
        workspace_id: workspace_a.id,
        embedding_status: :disabled
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Solution.store(attrs, tenant: tenant_b, actor: actor_b)

      assert error_contains_cross_tenant?(err),
             "expected :cross_tenant_fk_mismatch in error chain; got: #{inspect(err)}"

      {:ok, %{rows: [[count]]}} =
        Repo.query("SELECT COUNT(*) FROM solutions WHERE tenant_id = $1", [tenant_b])

      assert count == 0
    end

    test ":import_legacy rejects the same cross-tenant FK mismatch" do
      tenant_a = unique_tenant_id()
      tenant_b = unique_tenant_id()

      workspace_a = workspace_fixture(tenant_a, embedding_policy: :disabled)
      _workspace_b_setup = workspace_fixture(tenant_b, embedding_policy: :disabled)

      sig =
        Base.encode16(:crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}"),
          case: :lower
        )

      attrs = %{
        problem_signature: sig,
        solution_content: "x = 1",
        language: "elixir",
        sharing: :local,
        workspace_id: workspace_a.id,
        embedding_status: :disabled
      }

      # `authorize?: false` mirrors the migration task call shape;
      # the FK validation should still fire because it runs as a
      # before_action change, not a policy.
      assert {:error, %Ash.Error.Invalid{} = err} =
               Solution.import_legacy(attrs, tenant: tenant_b, authorize?: false)

      assert error_contains_cross_tenant?(err),
             "expected :cross_tenant_fk_mismatch in error chain; got: #{inspect(err)}"

      {:ok, %{rows: [[count]]}} =
        Repo.query("SELECT COUNT(*) FROM solutions WHERE tenant_id = $1", [tenant_b])

      assert count == 0
    end
  end

  # Walks the Ash error tree looking for the `cross_tenant_fk_mismatch`
  # message on the `:workspace_id` field. Errors arrive nested as
  # `Ash.Error.Invalid` wrapping `Ash.Error.Changes.InvalidAttribute`.
  defp error_contains_cross_tenant?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &cross_tenant?/1)
  end

  defp error_contains_cross_tenant?(_), do: false

  defp cross_tenant?(%{message: "cross_tenant_fk_mismatch"}), do: true
  defp cross_tenant?(_), do: false
end
