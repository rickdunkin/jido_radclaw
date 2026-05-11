defmodule JidoClaw.Solutions.SolutionTest do
  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Solutions.Reputation
  alias JidoClaw.Solutions.Solution
  alias JidoClaw.Solutions.Trust

  describe "update_verification_and_trust + RecomputeTrustScore" do
    test "uses the agent's real reputation score (not the 0.5 neutral fallback)" do
      tenant_id = unique_tenant_id()
      workspace = workspace_fixture(tenant_id, embedding_policy: :disabled)
      actor = actor_for(tenant_id)
      agent_id = "agent-trust-#{System.unique_integer([:positive])}"

      # Seed a non-neutral reputation under (tenant, agent_id). The
      # RecomputeTrustScore change must thread an actor through the
      # nested Reputation.get read for this row to be visible — without
      # fix 2 it lands at the 0.5 neutral fallback.
      {:ok, _rep} =
        Reputation.upsert(
          %{
            agent_id: agent_id,
            score: 0.9,
            solutions_verified: 9,
            solutions_failed: 1,
            solutions_shared: 5,
            last_active: DateTime.utc_now()
          },
          tenant: tenant_id,
          actor: actor
        )

      pre_update_reputation = 0.9

      sig =
        :crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}")
        |> Base.encode16(case: :lower)

      {:ok, solution} =
        Solution.store(
          %{
            problem_signature: sig,
            solution_content: "x = 1",
            language: "elixir",
            framework: "phoenix",
            sharing: :local,
            workspace_id: workspace.id,
            agent_id: agent_id,
            embedding_status: :disabled,
            verification: %{},
            trust_score: 0.0
          },
          tenant: tenant_id,
          actor: actor
        )

      new_verification = %{"status" => "semi_formal", "confidence" => 0.8}

      # Mirror the change's computation: the change uses `cs.data`
      # (the loaded record) with the new verification map merged in,
      # then calls Trust.compute/2 with the pre-update reputation
      # threaded as :agent_reputation. RecordReputationOutcome only
      # mutates reputation for "passed"/"failed" — semi_formal leaves
      # it untouched so the pre-update snapshot is the value actually
      # used.
      merged = %{solution | verification: new_verification}
      expected = Trust.compute(merged, agent_reputation: pre_update_reputation)

      {:ok, updated} =
        Solution.update_verification_and_trust(
          solution,
          %{verification: new_verification},
          tenant: tenant_id,
          actor: actor
        )

      # Tight delta: same Trust.compute on the same inputs; the only
      # floating-point variance is the freshness `now` snapshot used
      # by the change vs. the test (microseconds apart, both well
      # inside the 7-day full-freshness window).
      assert_in_delta updated.trust_score, expected, 0.001

      # Sanity floor: the 0.5 fallback would yield a score 0.06 lower
      # than the 0.9 reputation. Even with freshness jitter, the
      # difference between fix and bug is well outside the delta.
      fallback = Trust.compute(merged, agent_reputation: 0.5)
      refute_in_delta updated.trust_score, fallback, 0.01
    end
  end

  describe "import_legacy + ResolveInitialEmbeddingStatus" do
    test "system import under :disabled workspace lands at :disabled (not :pending)" do
      tenant_id = unique_tenant_id()
      workspace = workspace_fixture(tenant_id, embedding_policy: :disabled)

      sig =
        :crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}")
        |> Base.encode16(case: :lower)

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
end
