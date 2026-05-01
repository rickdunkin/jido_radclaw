defmodule JidoClaw.Solutions.Matcher do
  @moduledoc """
  Orchestrates finding and ranking the best matching solutions for a
  problem description.

  Pure functional module — no GenServer, no supervisor. Calls into the
  `JidoClaw.Solutions.Solution` resource via its code interface for
  exact-match (`by_signature`) and into
  `JidoClaw.Solutions.HybridSearchSql.run/1` directly for fuzzy
  retrieval (the resource no longer wraps that SQL in a `:search`
  read action — see `phase-1-solutions.md` D1).

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

  When neither `:embedding_model` nor `:query_embedding` is supplied,
  the matcher consults
  `JidoClaw.Embeddings.PolicyResolver.resolve/1` for the workspace's
  policy and dispatches accordingly:

    * `:default` — Voyage `voyage-4` for the request, filtered against
      `voyage-4-large` rows in the index.
    * `:local_only` — Ollama (`mxbai-embed-large` or whatever is
      configured) for both request and storage.
    * `:disabled` — `query_embedding: nil` and
      `embedding_model: nil`. SQL handles `nil` via `$4::vector IS
      NOT NULL`, so the ANN pool is skipped and FTS + lexical do the
      work.

  Test seam: pass `:policy_resolver` to override the resolver,
  `:voyage_module` / `:local_module` to override the embedding
  clients. Production paths use the real modules.
  """

  require Logger

  alias JidoClaw.Embeddings.PolicyResolver
  alias JidoClaw.Embeddings.RatePacer
  alias JidoClaw.Solutions.{Fingerprint, HybridSearchSql, Solution}

  @default_threshold 0.3
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
    * `:embedding_model` — explicit override of the workspace policy.
      Either `"voyage-4-large"` or `"mxbai-embed-large"`. The value
      drives the partial HNSW index choice on the stored side and
      should match what is in the index (i.e. the *stored* model
      name).
    * `:query_embedding` — pre-computed embedding from the caller. If
      `nil` (or the workspace policy is `:disabled`), the ANN pool is
      skipped.
    * `:policy_resolver`, `:voyage_module`, `:local_module` — test
      seams, default to the real production modules.

  Returns a list of maps:
  `%{solution: %Solution{}, score: float, match_type: :exact | :fuzzy}`.
  """
  @spec find_solutions(String.t(), keyword()) :: [
          %{solution: Solution.t(), score: float(), match_type: :exact | :fuzzy}
        ]
  def find_solutions(problem_description, opts \\ [])

  def find_solutions(problem_description, _opts)
      when not is_binary(problem_description) or problem_description == "" do
    []
  end

  def find_solutions(problem_description, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    limit = Keyword.get(opts, :limit, @default_limit)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    local_vis = Keyword.get(opts, :local_visibility, [:local, :shared, :public])
    cross_vis = Keyword.get(opts, :cross_workspace_visibility, [:public])

    query_fp = Fingerprint.generate(problem_description, opts)

    case exact_match(query_fp.signature, workspace_id, tenant_id, local_vis, cross_vis) do
      {:ok, solution} ->
        [%{solution: solution, score: 1.0, match_type: :exact}]

      :none ->
        query = Enum.join(query_fp.search_terms, " ")
        query = if query == "", do: problem_description, else: query

        {embedding, embedding_model} = resolve_embedding(query, workspace_id, opts)

        results =
          HybridSearchSql.run(%{
            query: query,
            language: Keyword.get(opts, :language),
            framework: Keyword.get(opts, :framework),
            limit: limit,
            workspace_id: workspace_id,
            tenant_id: tenant_id,
            local_visibility: local_vis,
            cross_workspace_visibility: cross_vis,
            query_embedding: embedding,
            embedding_model: embedding_model || "voyage-4-large"
          })

        results
        |> Enum.map(fn %{solution: s, combined_score: score} ->
          %{solution: s, score: score, match_type: :fuzzy}
        end)
        |> Enum.filter(fn %{score: s} -> s >= threshold end)
        |> Enum.take(limit)
    end
  end

  defp exact_match(signature, workspace_id, tenant_id, local_vis, cross_vis) do
    case Solution.by_signature(signature, workspace_id, tenant_id, local_vis, cross_vis) do
      {:ok, [first | _]} -> {:ok, first}
      {:ok, []} -> :none
      {:ok, %Solution{} = sol} -> {:ok, sol}
      _ -> :none
    end
  end

  # Returns {embedding_or_nil, stored_model_or_nil}. When the caller
  # supplies an explicit :query_embedding or :embedding_model, those
  # win — otherwise we consult PolicyResolver.
  defp resolve_embedding(query, workspace_id, opts) do
    explicit_embedding = Keyword.get(opts, :query_embedding)
    explicit_model = Keyword.get(opts, :embedding_model)

    cond do
      not is_nil(explicit_embedding) ->
        {explicit_embedding, explicit_model || "voyage-4-large"}

      not is_nil(explicit_model) ->
        # Caller wants a specific stored model but lets us compute the
        # embedding. Treat as override for the dispatch model too.
        {compute_for_model(query, explicit_model, opts), explicit_model}

      true ->
        resolver = Keyword.get(opts, :policy_resolver, PolicyResolver)
        policy = resolver.resolve(workspace_id)

        case resolver.model_for_query(policy) do
          :disabled ->
            {nil, nil}

          %{provider: :local, request_model: req, stored_model: stored} ->
            {compute_local(query, req, opts), stored}

          %{provider: :voyage, request_model: req, stored_model: stored} ->
            {compute_voyage(query, req, opts), stored}
        end
    end
  end

  defp compute_for_model(query, "mxbai-embed-large", opts),
    do: compute_local(query, "mxbai-embed-large", opts)

  defp compute_for_model(query, _other, opts), do: compute_voyage(query, "voyage-4", opts)

  defp compute_local(query, _model, opts) do
    local_mod = Keyword.get(opts, :local_module, JidoClaw.Embeddings.Local)

    case local_mod.embed_for_query(query) do
      {:ok, list} ->
        list

      {:error, reason} ->
        Logger.info(
          "[Matcher] local embedding failed (#{inspect(reason)}) — falling back to FTS+lexical"
        )

        nil
    end
  rescue
    err ->
      Logger.info(
        "[Matcher] local embedding crashed (#{inspect(err)}) — falling back to FTS+lexical"
      )

      nil
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
