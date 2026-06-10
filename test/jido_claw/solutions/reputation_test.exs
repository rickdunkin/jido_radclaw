defmodule JidoClaw.Solutions.ReputationTest do
  @moduledoc """
  Phase-1 acceptance gate coverage for `Solutions.Reputation`.

  Spec-locks:

    * **Reputation.upsert + trust composition** — the
      `RecomputeTrustScore` change reads the agent's real reputation
      via `Reputation.get/2` and threads it into `Trust.compute/2`.
      Without an actor threaded through the nested read this falls
      back to the 0.5 neutral default. Extracted from
      `solution_test.exs` so this file owns the reputation contract.

    * **Tenant-scoped isolation** — the same `agent_id` may carry
      different reputation rows in different tenants. The `:get` read
      filters on `tenant_id == ^actor(:tenant_id)`, so a cross-tenant
      query must not return the wrong tenant's row.

  Idempotent-import coverage (plan gate
  `phase-1-solutions.md:1506-1514`) is deferred — `migrate_reputation/3`
  is `defp` inside the migration mix task, and exercising it through
  `Mix.Task.run/2` adds setup weight the sprint doesn't budget. Pick
  it up by either exporting the function or extracting to a public
  importer module.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Solutions.Reputation
  alias JidoClaw.Solutions.Solution
  alias JidoClaw.Solutions.Trust

  describe "Reputation.upsert + trust composition" do
    test "uses the agent's real reputation score (not the 0.5 neutral fallback)" do
      tenant_id = unique_tenant_id()
      workspace = workspace_fixture(tenant_id, embedding_policy: :disabled)
      actor = actor_for(tenant_id)
      agent_id = "agent-trust-#{System.unique_integer([:positive])}"

      # Seed a non-neutral reputation under (tenant, agent_id). The
      # RecomputeTrustScore change must thread an actor through the
      # nested Reputation.get read for this row to be visible — without
      # the fix it lands at the 0.5 neutral fallback.
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
        Base.encode16(:crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}"),
          case: :lower
        )

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

  describe "tenant-scoped isolation" do
    test "Reputation.get returns the calling tenant's row, not the other tenant's" do
      tenant_a = unique_tenant_id()
      tenant_b = unique_tenant_id()
      actor_a = actor_for(tenant_a)
      actor_b = actor_for(tenant_b)
      agent_x = "agent-shared-#{System.unique_integer([:positive])}"

      # Ensure both tenants exist as FK parents (workspace_fixture is
      # the easiest single call that does Tenant.ensure under the hood).
      _ = workspace_fixture(tenant_a)
      _ = workspace_fixture(tenant_b)

      {:ok, _rep_a} =
        Reputation.upsert(
          %{
            agent_id: agent_x,
            score: 0.9,
            solutions_verified: 9,
            solutions_failed: 1,
            solutions_shared: 0,
            last_active: DateTime.utc_now()
          },
          tenant: tenant_a,
          actor: actor_a
        )

      {:ok, _rep_b} =
        Reputation.upsert(
          %{
            agent_id: agent_x,
            score: 0.1,
            solutions_verified: 1,
            solutions_failed: 9,
            solutions_shared: 0,
            last_active: DateTime.utc_now()
          },
          tenant: tenant_b,
          actor: actor_b
        )

      assert {:ok, %{tenant_id: ^tenant_a, score: 0.9}} =
               Reputation.get(agent_x, tenant: tenant_a, actor: actor_a)

      assert {:ok, %{tenant_id: ^tenant_b, score: 0.1}} =
               Reputation.get(agent_x, tenant: tenant_b, actor: actor_b)
    end
  end
end
