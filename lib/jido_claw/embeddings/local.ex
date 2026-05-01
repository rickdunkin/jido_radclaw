defmodule JidoClaw.Embeddings.Local do
  @moduledoc """
  Local Ollama embedding client. Pinned to `mxbai-embed-large` (1024-d)
  per the §1.4 "Local embedding isolation" decision — non-1024-d
  models are out of scope for v0.6.x.

  The model identifier is configurable via:

      config :jido_claw, JidoClaw.Embeddings.Local,
        model: "mxbai-embed-large",
        endpoint: "http://localhost:11434/api/embeddings"

  but if a non-1024-d model is configured the embedding column write
  will fail downstream — the resource enforces `dimensions: 1024`.

  Both `embed_for_storage/1` and `embed_for_query/1` route to the same
  Ollama endpoint (Ollama doesn't distinguish input_type); the
  function distinction exists so callers can swap providers
  uniformly.
  """

  alias JidoClaw.Security.Redaction.Embedding, as: EmbeddingRedaction

  @default_model "mxbai-embed-large"
  @default_endpoint "http://localhost:11434/api/embeddings"

  def embed_for_storage(content) when is_binary(content), do: embed(content)
  def embed_for_query(content) when is_binary(content), do: embed(content)

  defp embed(content) do
    {redacted, redactions_applied} = EmbeddingRedaction.redact(content)

    config = Application.get_env(:jido_claw, __MODULE__, [])
    model = Keyword.get(config, :model, @default_model)
    endpoint = Keyword.get(config, :endpoint, @default_endpoint)
    started = System.monotonic_time(:millisecond)

    body = %{"model" => model, "prompt" => redacted}

    response =
      Req.new(
        url: endpoint,
        finch: JidoClaw.Finch,
        json: body,
        retry: false
      )
      |> Req.post()

    latency_ms = System.monotonic_time(:millisecond) - started

    case response do
      {:ok, %Req.Response{status: 200, body: %{"embedding" => embedding}}}
      when is_list(embedding) ->
        :telemetry.execute(
          [:jido_claw, :embeddings, :local, :request],
          %{latency_ms: latency_ms, redactions_applied: redactions_applied},
          %{model: model, status_code: 200}
        )

        {:ok, embedding}

      {:ok, %Req.Response{status: code, body: body}} ->
        :telemetry.execute(
          [:jido_claw, :embeddings, :local, :request],
          %{latency_ms: latency_ms, redactions_applied: redactions_applied},
          %{model: model, status_code: code}
        )

        {:error, {:http_error, code, body}}

      {:error, reason} ->
        :telemetry.execute(
          [:jido_claw, :embeddings, :local, :request],
          %{latency_ms: latency_ms, redactions_applied: redactions_applied},
          %{model: model, status_code: 0}
        )

        {:error, reason}
    end
  end
end
