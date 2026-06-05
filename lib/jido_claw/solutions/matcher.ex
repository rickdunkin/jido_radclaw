defmodule JidoClaw.Solutions.Matcher do
  @moduledoc """
  Orchestrates finding and ranking the best matching solutions for a
  problem description.

  Pure functional module — no GenServer, no supervisor. Calls into the
  `JidoClaw.Solutions.Solution` resource via its code interface for
  exact-match (`by_signature`) and the manual-read `:search` action
  for fuzzy retrieval.

  ## Required scope opts

  Every call must pass tenant + workspace + visibility opts:

    * `:workspace_id` — UUID, the caller's workspace.
    * `:tenant_id` — string.
    * `:local_visibility` — list of `:local | :shared | :public`,
      default `[:local, :shared, :public]`. Sharing levels matched
      when the row is in the caller's workspace.
    * `:cross_workspace_visibility` — list of `:local | :shared |
      :public`, default `[:public]`. Sharing levels matched when the
      row lives in a different workspace within the same tenant.

  No v0.5.x "workspace = nil means everywhere" fallback. Missing scope
  raises `KeyError`.

  ## Embedding model selection

  When `:query_embedding` is not supplied, the matcher consults
  `JidoClaw.Embeddings.PolicyResolver.resolve/1` for the workspace's
  policy and dispatches accordingly:

    * `:default` — Voyage `voyage-4` for the request; ANN pool
      filtered to `embedding IS NOT NULL AND embedding_status =
      'ready'` rows.
    * `:disabled` — `query_embedding: nil`. SQL handles `nil` via
      `$4::vector IS NOT NULL`, so the ANN pool is skipped and FTS +
      lexical do the work.

  Test seam: pass `:policy_resolver` to override the resolver,
  `:voyage_module` to override the embedding client. Production paths
  use the real modules.
  """

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Embeddings.RatePacer
  alias JidoClaw.Memory.EmbeddingResolver
  alias JidoClaw.Solutions.{Fingerprint, Solution}

  @default_threshold 0.01
  @default_limit 5

  @doc """
  Find the best matching solutions for a problem description.

  ## Options

    * `:language`   - primary language string
    * `:framework`  - framework string
    * `:threshold`  - minimum combined score to include (default #{@default_threshold})
    * `:limit`      - maximum number of results (default #{@default_limit})
    * `:tenant_id`, `:workspace_id`, `:local_visibility`,
      `:cross_workspace_visibility` — scope opts (see module doc).
    * `:query_embedding` — pre-computed embedding from the caller. If
      `nil` (or the workspace policy is `:disabled`), the ANN pool is
      skipped.
    * `:policy_resolver`, `:voyage_module` — test seams, default to
      the real production modules.

  Returns a list of maps:
  `%{solution: %Solution{}, score: float, match_type: :exact | :fuzzy}`.
  """
  @spec find_solutions(String.t(), keyword()) :: [
          %{solution: Solution.t(), score: float(), match_type: :exact | :fuzzy}
        ]
  def find_solutions(problem_description, opts \\ [])

  def find_solutions("", _opts), do: []

  def find_solutions(problem_description, _opts)
      when not is_binary(problem_description) do
    []
  end

  def find_solutions(problem_description, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    limit = Keyword.get(opts, :limit, @default_limit)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    local_vis = Keyword.get(opts, :local_visibility, [:local, :shared, :public])
    cross_vis = Keyword.get(opts, :cross_workspace_visibility, [:public])
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

    query_fp = Fingerprint.generate(problem_description, opts)

    case exact_match(query_fp.signature, workspace_id, tenant_id, local_vis, cross_vis, actor) do
      {:ok, solution} ->
        [%{solution: solution, score: 1.0, match_type: :exact}]

      :none ->
        query = Enum.join(query_fp.search_terms, " ")
        query = if query == "", do: problem_description, else: query

        embedding = resolve_embedding(query, workspace_id, opts)

        search_args = %{
          query: query,
          language: Keyword.get(opts, :language),
          framework: Keyword.get(opts, :framework),
          limit: limit,
          threshold: threshold,
          workspace_id: workspace_id,
          local_visibility: local_vis,
          cross_workspace_visibility: cross_vis,
          query_embedding: embedding
        }

        case Solution.search(search_args, tenant: tenant_id, actor: actor) do
          {:ok, solutions} ->
            solutions
            |> Enum.map(fn sol ->
              score = Ash.Resource.get_metadata(sol, :combined_score) || 0.0
              %{solution: sol, score: score, match_type: :fuzzy}
            end)
            |> Enum.take(limit)

          {:error, _} ->
            []
        end
    end
  end

  defp exact_match(signature, workspace_id, tenant_id, local_vis, cross_vis, actor) do
    case Solution.by_signature(signature, workspace_id, local_vis, cross_vis,
           tenant: tenant_id,
           actor: actor
         ) do
      {:ok, [first | _]} -> {:ok, first}
      {:ok, []} -> :none
      _ -> :none
    end
  end

  # Resolve the query embedding via the shared policy resolver, supplying
  # the rate-paced Voyage compute callback.
  defp resolve_embedding(query, workspace_id, opts) do
    EmbeddingResolver.resolve(query, workspace_id, opts, &compute_voyage/3)
  end

  defp compute_voyage(query, model, opts) do
    voyage_mod = Keyword.get(opts, :voyage_module, JidoClaw.Embeddings.Voyage)
    rate_pacer = Keyword.get(opts, :rate_pacer, RatePacer)

    with :ok <- rate_pacer.acquire(:voyage, 1),
         :ok <- rate_pacer.try_admit("voyage", 1),
         {:ok, list} <- voyage_mod.embed_for_query(query, model) do
      list
    else
      reason ->
        Logger.info(
          "[Matcher] Voyage embedding skipped (#{inspect(reason)}) — falling back to FTS+lexical"
        )

        nil
    end
  rescue
    err ->
      Logger.info(
        "[Matcher] Voyage embedding crashed (#{inspect(err)}) — falling back to FTS+lexical"
      )

      nil
  end

  @doc """
  Return the single best matching solution for a problem description,
  or `nil` when none qualify.
  """
  @spec best_match(String.t(), keyword()) ::
          %{solution: Solution.t(), score: float(), match_type: :exact | :fuzzy} | nil
  def best_match(problem_description, opts \\ []) do
    problem_description
    |> find_solutions(Keyword.put(opts, :limit, 1))
    |> List.first()
  end
end
