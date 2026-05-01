defmodule JidoClaw.Solutions.MatcherTest do
  @moduledoc """
  Regression coverage for `Matcher.find_solutions/2`.

  Locks in:

    * Fix 2: threshold filter applies against the SQL `combined_score`,
      not `trust_score`, so a moderate-relevance row passes when its
      trust_score is `0.0` (default).
    * Fix 3: when neither `:embedding_model` nor `:query_embedding` is
      supplied, the matcher consults the workspace's embedding policy
      via `PolicyResolver`. `:disabled` workspaces never call the
      Voyage stub. Missing-workspace fails closed to `:disabled`.
    * Cross-workspace isolation — a `:local` row in workspace B is
      not returned to a query against workspace A.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Solutions.Matcher

  defmodule StubResolver do
    @moduledoc false
    def resolve(_), do: :default

    def model_for_query(:default),
      do: %{provider: :voyage, request_model: "voyage-4", stored_model: "voyage-4-large"}

    def model_for_query(:disabled), do: :disabled

    def model_for_query(:local_only),
      do: %{
        provider: :local,
        request_model: "mxbai-embed-large",
        stored_model: "mxbai-embed-large"
      }
  end

  defmodule DisabledResolver do
    @moduledoc false
    def resolve(_), do: :disabled
    def model_for_query(:disabled), do: :disabled
    def model_for_query(_), do: :disabled
  end

  defmodule SpyVoyage do
    @moduledoc false
    def embed_for_query(_query, _model) do
      send(self(), {:voyage_called_at, System.unique_integer([:monotonic])})
      {:error, :should_not_be_called}
    end
  end

  defmodule NoopRatePacer do
    @moduledoc false
    def acquire(_, _), do: :ok
    def try_admit(_, _), do: :ok
  end

  setup do
    tenant_id = unique_tenant_id()
    ws = workspace_fixture(tenant_id, embedding_policy: :disabled)
    {:ok, tenant_id: tenant_id, workspace: ws}
  end

  describe "threshold against combined_score (Fix 2)" do
    test "fuzzy hit with default trust_score=0.0 is NOT filtered when combined_score clears the threshold",
         %{tenant_id: tenant_id, workspace: ws} do
      _sol = solution_fixture(tenant_id, ws.id, "deploy postgres migration runbook")

      results =
        Matcher.find_solutions("postgres migration",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          # Lower than default 0.3; the lexical pool weights similarity at
          # 0.2 so a near-perfect token hit still doesn't reach 0.3 alone.
          threshold: 0.05,
          policy_resolver: DisabledResolver
        )

      assert length(results) >= 1

      Enum.each(results, fn match ->
        assert match.match_type == :fuzzy
        assert match.score >= 0.05
        # The crucial regression: pre-fix, score fell back to
        # trust_score (0.0) and was filtered out at the default
        # 0.3 threshold.
        refute match.score == match.solution.trust_score
      end)
    end
  end

  describe "policy resolution (Fix 3)" do
    test ":disabled workspaces never call the Voyage embedder",
         %{tenant_id: tenant_id, workspace: ws} do
      _sol = solution_fixture(tenant_id, ws.id, "logging telemetry observability")

      _ =
        Matcher.find_solutions("logging telemetry",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          threshold: 0.0,
          policy_resolver: DisabledResolver,
          voyage_module: SpyVoyage,
          rate_pacer: NoopRatePacer
        )

      refute_received {:voyage_called_at, _}
    end

    test "missing workspace fails closed (default PolicyResolver)",
         %{tenant_id: tenant_id} do
      missing = Ecto.UUID.generate()

      _ =
        Matcher.find_solutions("anything",
          tenant_id: tenant_id,
          workspace_id: missing,
          threshold: 0.0,
          voyage_module: SpyVoyage,
          rate_pacer: NoopRatePacer
        )

      refute_received {:voyage_called_at, _}
    end
  end

  describe "cross-workspace isolation" do
    test ":local rows in another workspace stay private",
         %{tenant_id: tenant_id, workspace: ws} do
      other_ws = workspace_fixture(tenant_id, embedding_policy: :disabled)

      _hidden =
        solution_fixture(tenant_id, other_ws.id, "private build deploy command", sharing: :local)

      results =
        Matcher.find_solutions("private build deploy",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          threshold: 0.0,
          policy_resolver: DisabledResolver
        )

      assert results == []
    end

    test ":public rows in another workspace are visible",
         %{tenant_id: tenant_id, workspace: ws} do
      other_ws = workspace_fixture(tenant_id, embedding_policy: :disabled)

      sol =
        solution_fixture(tenant_id, other_ws.id, "public deploy procedure", sharing: :public)

      results =
        Matcher.find_solutions("public deploy",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          threshold: 0.0,
          policy_resolver: DisabledResolver
        )

      assert Enum.any?(results, fn m -> m.solution.id == sol.id end)
    end
  end

  describe "explicit caller-supplied embedding wins" do
    test "an explicit query_embedding bypasses PolicyResolver entirely",
         %{tenant_id: tenant_id, workspace: ws} do
      _sol = solution_fixture(tenant_id, ws.id, "the quick brown fox")

      _ =
        Matcher.find_solutions("the quick brown fox",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          threshold: 0.0,
          query_embedding: List.duplicate(0.01, 1024),
          policy_resolver: DisabledResolver,
          voyage_module: SpyVoyage,
          rate_pacer: NoopRatePacer
        )

      refute_received {:voyage_called_at, _}
    end
  end
end
