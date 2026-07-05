defmodule JidoClaw.Embeddings.PolicyResolver do
  @moduledoc """
  Single source of truth for "what should this workspace's embedding
  call do?". The Matcher (read path) uses both `resolve/1` and
  `model_for_query/1`; the BackfillWorker (write path) gates on
  `resolve/1` only — it hardcodes its stored model
  (`"voyage-4-large"`), so no model translation happens there.

  Two responsibilities:

    * `resolve/1` — read the workspace row's `embedding_policy` and
      return one of `:default | :disabled`. **Fails closed** to
      `:disabled` when the workspace is missing, unreadable, or has
      a malformed policy value. Anything that cannot be confidently
      mapped to `:default` blocks Voyage egress.
    * `model_for_query/1` — translate the policy atom into a concrete
      `%{provider, request_model, stored_model}` shape (or
      `:disabled`). Distinct request and stored models matter for
      Voyage: query calls hit `voyage-4` but the embedding column
      stores rows under `voyage-4-large`, and the partial HNSW index
      filters on the `embedding_status = 'ready'` predicate.
  """

  alias JidoClaw.Repo

  @type policy :: :default | :disabled
  @type provider_spec :: %{
          provider: :voyage,
          request_model: String.t(),
          stored_model: String.t()
        }

  @doc """
  Resolve a workspace's embedding policy. Fails closed to `:disabled`
  on any lookup error.
  """
  @spec resolve(binary() | nil) :: policy()
  def resolve(workspace_id) do
    with {:ok, dumped} <- normalize_workspace_id(workspace_id),
         {:ok, %Postgrex.Result{rows: [[policy]]}} <-
           Repo.query("SELECT embedding_policy FROM workspaces WHERE id = $1", [dumped]) do
      coerce(policy)
    else
      _ -> :disabled
    end
  end

  @doc """
  Translate a resolved policy into the shape needed by the embedding
  call site. `:disabled` is passed through verbatim — callers
  interpret it as "skip the call entirely".
  """
  @spec model_for_query(policy()) :: provider_spec() | :disabled
  def model_for_query(:default) do
    %{provider: :voyage, request_model: "voyage-4", stored_model: "voyage-4-large"}
  end

  def model_for_query(:disabled), do: :disabled

  @doc """
  Translate a resolved policy into the shape needed by the
  storage-side embedding call. Voyage uses `voyage-4-large` for both
  request and stored model.
  """
  @spec model_for_storage(policy()) :: provider_spec() | :disabled
  def model_for_storage(:default) do
    %{provider: :voyage, request_model: "voyage-4-large", stored_model: "voyage-4-large"}
  end

  def model_for_storage(:disabled), do: :disabled

  defp normalize_workspace_id(<<_::binary-size(36)>> = s), do: Ecto.UUID.dump(s)
  defp normalize_workspace_id(<<_::binary-size(16)>> = b), do: {:ok, b}
  defp normalize_workspace_id(_), do: :error

  defp coerce("disabled"), do: :disabled
  defp coerce("default"), do: :default
  defp coerce(:disabled), do: :disabled
  defp coerce(:default), do: :default
  defp coerce(_), do: :disabled
end
