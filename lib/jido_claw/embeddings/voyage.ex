defmodule JidoClaw.Embeddings.Voyage do
  @moduledoc """
  Voyage AI embeddings client.

  Two model contracts:

    * `embed_for_storage/1` — `voyage-4-large`, `input_type: "document"`,
      `output_dimension: 1024`, `output_dtype: "float"`.
    * `embed_for_query/1` — `voyage-4`, `input_type: "query"`, same
      dimension/dtype.

  Both functions:

    1. Pre-redact via `JidoClaw.Security.Redaction.Embedding.redact/1`.
    2. Read `VOYAGE_API_KEY` from `System.get_env/1` at request time.
       (No SecretRef row, no Cloak encryption-at-rest — this matches
       the Ollama precedent and dodges the bootstrap "vault depends on
       repo, repo depends on vault" cycle.)
    3. Fail loudly with `{:error, :missing_api_key}` when the env var
       is absent rather than calling Voyage with a nil header.
    4. HTTP via `Req.new(finch: JidoClaw.Finch)`.
    5. Emit telemetry `[:jido_claw, :embeddings, :voyage, :request]`
       with `model, tokens, latency_ms, redactions_applied,
       status_code`.

  Returns `{:ok, embedding :: [float()]}` on success,
  `{:error, {:rate_limited, retry_after :: integer()}}` on HTTP 429,
  `{:error, reason}` otherwise.
  """

  alias JidoClaw.Security.Redaction.Embedding, as: EmbeddingRedaction

  @endpoint "https://api.voyageai.com/v1/embeddings"
  @storage_model "voyage-4-large"
  @query_model "voyage-4"
  @output_dimension 1024

  @doc "Embed a corpus document. Returns `{:ok, [float()]}` of length 1024."
  @spec embed_for_storage(String.t()) ::
          {:ok, [float()]} | {:error, term()}
  def embed_for_storage(content) when is_binary(content) do
    embed_for_storage(content, @storage_model)
  end

  @doc """
  Embed a corpus document with an explicit `request_model`. The
  caller-supplied model is used for the HTTP body's `"model"` field;
  callers that need to pin the *stored* model name separately should
  do so after the embedding returns.
  """
  @spec embed_for_storage(String.t(), String.t()) ::
          {:ok, [float()]} | {:error, term()}
  def embed_for_storage(content, request_model)
      when is_binary(content) and is_binary(request_model) do
    embed(content, request_model, "document")
  end

  @doc "Embed a query. Returns `{:ok, [float()]}` of length 1024."
  @spec embed_for_query(String.t()) ::
          {:ok, [float()]} | {:error, term()}
  def embed_for_query(content) when is_binary(content) do
    embed_for_query(content, @query_model)
  end

  @doc "Embed a query with an explicit `request_model`."
  @spec embed_for_query(String.t(), String.t()) ::
          {:ok, [float()]} | {:error, term()}
  def embed_for_query(content, request_model)
      when is_binary(content) and is_binary(request_model) do
    embed(content, request_model, "query")
  end

  defp embed(content, model, input_type) do
    case System.get_env("VOYAGE_API_KEY") do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
      api_key -> do_request(content, model, input_type, api_key)
    end
  end

  defp do_request(content, model, input_type, api_key) do
    {redacted, redactions_applied} = EmbeddingRedaction.redact(content)
    started = System.monotonic_time(:millisecond)

    body = %{
      "input" => [redacted],
      "model" => model,
      "input_type" => input_type,
      "output_dimension" => @output_dimension,
      "output_dtype" => "float"
    }

    response =
      Req.new(
        url: @endpoint,
        finch: JidoClaw.Finch,
        headers: [
          {"authorization", "Bearer " <> api_key},
          {"content-type", "application/json"}
        ],
        json: body,
        retry: false
      )
      |> Req.post()

    latency_ms = System.monotonic_time(:millisecond) - started

    handle_response(response, model, latency_ms, redactions_applied)
  end

  defp handle_response(
         {:ok, %Req.Response{status: 200, body: body}},
         model,
         latency_ms,
         redactions_applied
       ) do
    embedding = extract_embedding(body)
    tokens = extract_tokens(body)

    :telemetry.execute(
      [:jido_claw, :embeddings, :voyage, :request],
      %{latency_ms: latency_ms, tokens: tokens, redactions_applied: redactions_applied},
      %{model: model, status_code: 200}
    )

    case embedding do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, :invalid_response_shape}
    end
  end

  defp handle_response(
         {:ok, %Req.Response{status: 429, headers: headers}},
         model,
         latency_ms,
         redactions_applied
       ) do
    retry_after =
      headers
      |> List.keyfind("retry-after", 0)
      |> case do
        {_, [val | _]} -> parse_retry_after(val)
        {_, val} -> parse_retry_after(val)
        nil -> 60
      end

    :telemetry.execute(
      [:jido_claw, :embeddings, :voyage, :request],
      %{latency_ms: latency_ms, redactions_applied: redactions_applied, retry_after: retry_after},
      %{model: model, status_code: 429}
    )

    {:error, {:rate_limited, retry_after}}
  end

  defp handle_response(
         {:ok, %Req.Response{status: code, body: body}},
         model,
         latency_ms,
         redactions_applied
       ) do
    :telemetry.execute(
      [:jido_claw, :embeddings, :voyage, :request],
      %{latency_ms: latency_ms, redactions_applied: redactions_applied},
      %{model: model, status_code: code}
    )

    {:error, {:http_error, code, body}}
  end

  defp handle_response({:error, reason}, model, latency_ms, redactions_applied) do
    :telemetry.execute(
      [:jido_claw, :embeddings, :voyage, :request],
      %{latency_ms: latency_ms, redactions_applied: redactions_applied},
      %{model: model, status_code: 0}
    )

    {:error, reason}
  end

  defp extract_embedding(%{"data" => [%{"embedding" => list} | _]}) when is_list(list), do: list
  defp extract_embedding(_), do: nil

  defp extract_tokens(%{"usage" => %{"total_tokens" => n}}) when is_integer(n), do: n
  defp extract_tokens(_), do: 0

  defp parse_retry_after(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 60
    end
  end

  defp parse_retry_after(_), do: 60
end
