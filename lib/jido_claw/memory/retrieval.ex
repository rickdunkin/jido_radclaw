defmodule JidoClaw.Memory.Retrieval do
  @moduledoc """
  Public retrieval API for the Memory subsystem.

  Three tiers, three rank shapes:

    * `Memory.Block` — no search; returns the active scope-chain
      blocks ordered by `(scope precedence, position, inserted_at desc)`.
    * `Memory.Fact`  — hybrid via `Memory.HybridSearchSql.run/1`
      (FTS + pgvector + GIN trigram, RRF-combined). Returns
      `[%{fact:, combined_score:}]`.
    * `Memory.Episode` — FTS + lexical only (no embedding column).
      Used by the consolidator and the `recall` tool's "show me the
      source" follow-up.

  ## Bitemporal predicate matrix

  Four supported modes (plan §3.13 lines 1005–1008):

    * `:current_truth`     — `valid_at <= now() AND (invalid_at IS NULL
                             OR invalid_at > now()) AND expired_at IS NULL`.
                             Default. The live fact about today's world.
    * `{:world_at, t}`     — `valid_at <= t AND (invalid_at IS NULL OR
                             invalid_at > t)`. What was *true in the
                             world* at world-time `t`, according to
                             current system knowledge — the
                             `expired_at IS NULL` clause is dropped so
                             since-superseded rows still surface.
    * `{:system_at, t}`    — `inserted_at <= t AND (expired_at IS NULL
                             OR expired_at > t) AND valid_at <= now()
                             AND (invalid_at IS NULL OR invalid_at >
                             now())`. What the database *knew* at
                             system-time `t` about today's world.
    * `{:full_bitemporal, world_t, system_t}` — both axes independent:
                             world predicates against `world_t`, system
                             predicates against `system_t`.
  """

  alias JidoClaw.Embeddings.PolicyResolver
  alias JidoClaw.Memory.{HybridSearchSql, Scope}

  @default_limit 10

  @doc """
  Search Memory.Fact for the resolved scope.

  Required `opts`:

    * `:tool_context` — map; scope is resolved via
      `JidoClaw.Memory.Scope.resolve/1`.

  Either `:query` (string) is required directly, or `opts[:query]`
  may be passed via the keyword list when called from
  `JidoClaw.Memory.recall/2`.

  Optional:

    * `:limit`           — int, default 10.
    * `:dedup`           — `:by_precedence` (default) | `:none`.
    * `:embed_queries?`  — `true` (default) to compute the embedding via
                            the policy resolver. `false` skips ANN.
    * `:bitemporal`      — `:current_truth` | `{:world_at, dt}` |
                            `{:system_at, dt}` | `{:full_bitemporal,
                            world_dt, system_dt}`. Default
                            `:current_truth`.
  """
  @spec search(keyword()) ::
          [JidoClaw.Memory.Fact.t()] | [%{fact: any(), combined_score: float()}]
  def search(opts) when is_list(opts) do
    tool_context = Keyword.fetch!(opts, :tool_context)
    query = Keyword.get(opts, :query, "")
    limit = Keyword.get(opts, :limit, @default_limit)
    dedup = Keyword.get(opts, :dedup, :by_precedence)
    embed_queries? = Keyword.get(opts, :embed_queries?, true)
    bitemporal = Keyword.get(opts, :bitemporal, :current_truth)

    case Scope.resolve(tool_context) do
      {:ok, scope} ->
        do_search(scope, query, %{
          limit: limit,
          dedup: dedup,
          embed_queries?: embed_queries?,
          bitemporal: bitemporal,
          opts: opts
        })

      _ ->
        []
    end
  end

  defp do_search(scope, "", settings), do: recency_scan(scope, settings)

  defp do_search(scope, query, settings) do
    chain = Scope.chain(scope)

    case chain do
      [] ->
        []

      _ ->
        embedding =
          if settings.embed_queries? do
            resolve_embedding(query, scope.workspace_id, settings.opts)
          else
            nil
          end

        ranked =
          HybridSearchSql.run(%{
            tenant_id: scope.tenant_id,
            scope_chain: chain,
            query: query,
            query_embedding: embedding,
            limit: settings.limit,
            dedup: settings.dedup,
            bitemporal: settings.bitemporal
          })

        # A real query with no matches must return `[]`. Empty queries
        # short-circuit upstream to `recency_scan/2`. The Fact structs
        # already carry `:shadowed_by` metadata from the SQL pass when
        # dedup is `:by_precedence` — see `HybridSearchSql.load_facts/2`.
        Enum.map(ranked, & &1.fact)
    end
  end

  # Mirror of Solutions.Matcher.resolve_embedding/3. Returns the query
  # embedding (list of floats) or nil. When the caller supplies an
  # explicit `:query_embedding`, it wins; otherwise we consult
  # `PolicyResolver` for the workspace's policy.
  #
  # `workspace_id` is always populated for `:session`/`:project`/
  # `:workspace` scopes via the ancestor walk in `Scope.resolve/1`. It is
  # `nil` for pure `:user`-scoped recalls — `PolicyResolver.resolve/1`
  # then fails closed to `:disabled`, which is correct: a user-scope-only
  # recall has no per-workspace embedding policy.
  defp resolve_embedding(query, workspace_id, opts) do
    explicit_embedding = Keyword.get(opts, :query_embedding)

    if not is_nil(explicit_embedding) do
      explicit_embedding
    else
      resolver = Keyword.get(opts, :policy_resolver, PolicyResolver)
      policy = resolver.resolve(workspace_id)

      case resolver.model_for_query(policy) do
        :disabled ->
          nil

        %{provider: :voyage, request_model: req} ->
          compute_voyage(query, req, opts)
      end
    end
  end

  defp compute_voyage(query, model, opts) do
    voyage_mod = Keyword.get(opts, :voyage_module, JidoClaw.Embeddings.Voyage)

    case voyage_mod.embed_for_query(query, model) do
      {:ok, vec} -> vec
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Recency scan delegates to `HybridSearchSql.run_recency/1` so the
  # per-label scope-precedence dedup happens *inside SQL* via
  # `ROW_NUMBER() OVER (PARTITION BY label ...)`. An Elixir-side dedup
  # over an overfetch buffer would lose closer-scope rows whenever the
  # parent scope churns enough recent unrelated rows to fill the
  # buffer.
  defp recency_scan(scope, settings) do
    chain = Scope.chain(scope)

    HybridSearchSql.run_recency(%{
      tenant_id: scope.tenant_id,
      scope_chain: chain,
      limit: settings.limit,
      dedup: settings.dedup,
      bitemporal: settings.bitemporal
    })
  end

  @doc ~S"""
  Build a bitemporal SQL predicate fragment for the supplied mode.

  Returns a string slot-fillable into `WHERE ... #{predicate}`. The
  `params` argument carries the `world_t` / `system_t` values
  positioned for the caller's parameter list (the caller decides
  the `$N` ordinals).
  """
  @spec bitemporal_predicate(atom() | tuple(), keyword()) :: String.t()
  def bitemporal_predicate(:current_truth, _opts) do
    # `clock_timestamp()` (not `now()`) so the predicate uses the
    # *actual* current time rather than the transaction start. Matters
    # under Sandbox-wrapped tests where writes and reads share a
    # transaction: `now()` is pinned to the transaction start and would
    # exclude rows whose `valid_at` was set later in the same
    # transaction.
    "valid_at <= clock_timestamp() " <>
      "AND (invalid_at IS NULL OR invalid_at > clock_timestamp()) " <>
      "AND expired_at IS NULL"
  end

  def bitemporal_predicate({:world_at, _dt}, opts) do
    world_param = Keyword.fetch!(opts, :world_param)

    "valid_at <= #{world_param} " <>
      "AND (invalid_at IS NULL OR invalid_at > #{world_param})"
  end

  def bitemporal_predicate({:system_at, _dt}, opts) do
    system_param = Keyword.fetch!(opts, :system_param)

    "inserted_at <= #{system_param} " <>
      "AND (expired_at IS NULL OR expired_at > #{system_param}) " <>
      "AND valid_at <= clock_timestamp() " <>
      "AND (invalid_at IS NULL OR invalid_at > clock_timestamp())"
  end

  def bitemporal_predicate({:full_bitemporal, _w, _s}, opts) do
    world_param = Keyword.fetch!(opts, :world_param)
    system_param = Keyword.fetch!(opts, :system_param)

    "valid_at <= #{world_param} " <>
      "AND (invalid_at IS NULL OR invalid_at > #{world_param}) " <>
      "AND inserted_at <= #{system_param} " <>
      "AND (expired_at IS NULL OR expired_at > #{system_param})"
  end
end
