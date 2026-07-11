defmodule JidoClaw.Solutions.MatcherTest do
  @moduledoc """
  Regression coverage for `Matcher.find_solutions/2`.

  Locks in:

    * Fix 2: threshold filter applies against the SQL `combined_score`,
      not `trust_score`, so a moderate-relevance row passes when its
      trust_score is `0.0` (default).
    * Fix 3: when `:query_embedding` is not supplied, the matcher
      consults the workspace's embedding policy via `PolicyResolver`.
      `:disabled` workspaces never call the Voyage stub.
      Missing-workspace fails closed to `:disabled`.
    * Cross-workspace isolation — a `:local` row in workspace B is
      not returned to a query against workspace A.
  """

  use JidoClaw.SolutionsCase, async: true

  alias JidoClaw.Solutions.Matcher

  defmodule StubResolver do
    @moduledoc false
    @spec resolve(term()) :: :default
    def resolve(_), do: :default

    @spec model_for_query(:default | :disabled) :: map() | :disabled
    def model_for_query(:default),
      do: %{provider: :voyage, request_model: "voyage-4", stored_model: "voyage-4-large"}

    def model_for_query(:disabled), do: :disabled
  end

  defmodule DisabledResolver do
    @moduledoc false
    @spec resolve(term()) :: :disabled
    def resolve(_), do: :disabled
    @spec model_for_query(term()) :: :disabled
    def model_for_query(:disabled), do: :disabled
    def model_for_query(_), do: :disabled
  end

  defmodule SpyVoyage do
    @moduledoc false
    @spec embed_for_query(term(), term()) :: {:error, :should_not_be_called}
    def embed_for_query(_query, _model) do
      send(self(), {:voyage_called_at, System.unique_integer([:monotonic])})
      {:error, :should_not_be_called}
    end
  end

  defmodule NoopRatePacer do
    @moduledoc false
    @spec acquire(term(), term()) :: :ok
    def acquire(_, _), do: :ok
    @spec try_admit(term(), term()) :: :ok
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
          # RRF score for a single-pool match is ~1/(60+1) ≈ 0.016 — pick
          # a threshold below that so a near-perfect lexical-only hit
          # still surfaces.
          threshold: 0.005,
          policy_resolver: DisabledResolver
        )

      assert [_ | _] = results

      Enum.each(results, fn match ->
        assert match.match_type == :fuzzy
        assert match.score >= 0.005
        # The crucial regression: pre-fix, score fell back to
        # trust_score (0.0) and was filtered out at the default
        # threshold.
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

  # Resolver spy for the `resolve_embedding?: false` seam: proves the policy
  # lookup itself is skipped, not just the Voyage call.
  defmodule SpyResolver do
    @moduledoc false
    @spec resolve(term()) :: :default
    def resolve(workspace_id) do
      send(self(), {:resolver_called, workspace_id})
      :default
    end

    @spec model_for_query(term()) :: map()
    def model_for_query(_),
      do: %{provider: :voyage, request_model: "voyage-4", stored_model: "voyage-4-large"}
  end

  describe "resolve_embedding?: false (the Lua binding's no-egress seam)" do
    test "default (opt absent) still resolves embeddings via the policy path",
         %{tenant_id: tenant_id, workspace: ws} do
      _sol = solution_fixture(tenant_id, ws.id, "kafka consumer lag alerting")

      _ =
        Matcher.find_solutions("kafka consumer lag",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          threshold: 0.0,
          policy_resolver: SpyResolver,
          voyage_module: SpyVoyage,
          rate_pacer: NoopRatePacer
        )

      assert_received {:resolver_called, _}
      assert_received {:voyage_called_at, _}
    end

    test "explicit resolve_embedding?: true behaves like the default",
         %{tenant_id: tenant_id, workspace: ws} do
      _sol = solution_fixture(tenant_id, ws.id, "kafka consumer lag alerting")

      _ =
        Matcher.find_solutions("kafka consumer lag",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          threshold: 0.0,
          resolve_embedding?: true,
          policy_resolver: SpyResolver,
          voyage_module: SpyVoyage,
          rate_pacer: NoopRatePacer
        )

      assert_received {:resolver_called, _}
      assert_received {:voyage_called_at, _}
    end

    test "resolve_embedding?: false never invokes the policy resolver or Voyage, and lexical retrieval still works",
         %{tenant_id: tenant_id, workspace: ws} do
      sol = solution_fixture(tenant_id, ws.id, "kafka consumer lag alerting")

      results =
        Matcher.find_solutions("kafka consumer lag",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          threshold: 0.0,
          resolve_embedding?: false,
          policy_resolver: SpyResolver,
          voyage_module: SpyVoyage,
          rate_pacer: NoopRatePacer
        )

      refute_received {:resolver_called, _}
      refute_received {:voyage_called_at, _}
      assert Enum.any?(results, fn m -> m.solution.id == sol.id end)
    end

    test "an explicit query_embedding still wins under resolve_embedding?: false (ANN runs, zero egress)",
         %{tenant_id: tenant_id, workspace: ws} do
      vec = List.duplicate(0.05, 1024)

      # Content shares no tokens/trigrams with the query, so the FTS and
      # lexical pools cannot surface this row — only the ANN pool (via the
      # explicit vector) can. Pre-fix, resolve_embedding?: false dropped the
      # vector and this row was unreachable.
      sol =
        solution_fixture(tenant_id, ws.id, "postgres vacuum autotune runbook",
          embedding: vec,
          embedding_status: :ready
        )

      results =
        Matcher.find_solutions("frobnicate zymurgy quixotic",
          tenant_id: tenant_id,
          workspace_id: ws.id,
          threshold: 0.0,
          query_embedding: vec,
          resolve_embedding?: false,
          policy_resolver: SpyResolver,
          voyage_module: SpyVoyage,
          rate_pacer: NoopRatePacer
        )

      refute_received {:resolver_called, _}
      refute_received {:voyage_called_at, _}

      assert Enum.any?(results, fn m -> m.solution.id == sol.id end),
             "explicit query_embedding must reach the ANN pool under resolve_embedding?: false"
    end
  end
end
