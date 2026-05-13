defmodule JidoClaw.Memory.EmbeddingResolver do
  @moduledoc """
  Shared resolver for query embeddings used by hybrid retrieval.

  `JidoClaw.Solutions.Matcher` and `JidoClaw.Memory.Retrieval` previously
  carried byte-identical copies of this logic; the only divergence was in
  the provider-specific compute step (matcher rate-paces Voyage calls,
  retrieval doesn't). This module captures the resolution policy in one
  place and accepts a `compute_fn` callback for the provider step.
  """

  alias JidoClaw.Embeddings.PolicyResolver

  @doc """
  Resolve a query embedding (list of floats) or `nil`.

  When the caller supplies an explicit `:query_embedding` in `opts`, it
  wins. Otherwise the workspace's `PolicyResolver` policy decides:

    * `:disabled` → `nil`
    * `%{provider: :voyage, request_model: req}` → `compute_fn.(query, req, opts)`

  `workspace_id` is always populated for `:session`/`:project`/`:workspace`
  scopes via the ancestor walk in `Scope.resolve/1`. It is `nil` for pure
  `:user`-scoped recalls — `PolicyResolver.resolve/1` then fails closed to
  `:disabled`, which is correct: a user-scope-only recall has no
  per-workspace embedding policy.
  """
  @spec resolve(String.t(), String.t() | nil, keyword(), (String.t(), String.t(), keyword() ->
                                                            [float()] | nil)) ::
          [float()] | nil
  def resolve(query, workspace_id, opts, compute_fn) do
    case Keyword.get(opts, :query_embedding) do
      nil -> resolve_via_policy(query, workspace_id, opts, compute_fn)
      explicit -> explicit
    end
  end

  defp resolve_via_policy(query, workspace_id, opts, compute_fn) do
    resolver = Keyword.get(opts, :policy_resolver, PolicyResolver)
    policy = resolver.resolve(workspace_id)

    case resolver.model_for_query(policy) do
      :disabled -> nil
      %{provider: :voyage, request_model: req} -> compute_fn.(query, req, opts)
    end
  end
end
