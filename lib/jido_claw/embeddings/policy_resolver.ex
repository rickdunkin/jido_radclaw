defmodule JidoClaw.Embeddings.PolicyResolver do
  @moduledoc """
  Single source of truth for "what should this workspace's embedding
  call do?" — used by both the Matcher (read path) and the
  BackfillWorker (write path).

  Two responsibilities:

    * `resolve/1` — read the workspace row's `embedding_policy` and
      return one of `:default | :local_only | :disabled`. **Fails
      closed** to `:disabled` when the workspace is missing,
      unreadable, or has a malformed policy value. Anything that
      cannot be confidently mapped to `:default` or `:local_only`
      blocks Voyage egress.
    * `model_for_query/1` — translate the policy atom into a concrete
      `%{provider, request_model, stored_model}` shape (or
      `:disabled`). Distinct request and stored models matter for
      Voyage: query calls hit `voyage-4` but the embedding column
      stores rows under `voyage-4-large`, and the partial HNSW index
      filters on the stored name.
  """

  alias JidoClaw.Repo

  @type policy :: :default | :local_only | :disabled
  @type provider_spec :: %{
          provider: :voyage | :local,
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

  def model_for_query(:local_only) do
    model = default_local_model()
    %{provider: :local, request_model: model, stored_model: model}
  end

  def model_for_query(:disabled), do: :disabled

  @doc """
  Translate a resolved policy into the shape needed by the
  storage-side embedding call. Voyage uses `voyage-4-large` for both
  request and stored model; the local provider uses the configured
  model for both.
  """
  @spec model_for_storage(policy()) :: provider_spec() | :disabled
  def model_for_storage(:default) do
    %{provider: :voyage, request_model: "voyage-4-large", stored_model: "voyage-4-large"}
  end

  def model_for_storage(:local_only) do
    model = default_local_model()
    %{provider: :local, request_model: model, stored_model: model}
  end

  def model_for_storage(:disabled), do: :disabled

  defp normalize_workspace_id(<<_::binary-size(36)>> = s), do: Ecto.UUID.dump(s)
  defp normalize_workspace_id(<<_::binary-size(16)>> = b), do: {:ok, b}
  defp normalize_workspace_id(_), do: :error

  defp coerce("disabled"), do: :disabled
  defp coerce("local_only"), do: :local_only
  defp coerce("default"), do: :default
  defp coerce(:disabled), do: :disabled
  defp coerce(:local_only), do: :local_only
  defp coerce(:default), do: :default
  defp coerce(_), do: :disabled

  defp default_local_model do
    Application.get_env(:jido_claw, JidoClaw.Embeddings.Local, [])[:model] ||
      "mxbai-embed-large"
  end
end
