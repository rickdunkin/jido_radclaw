defmodule JidoClaw.Reasoning.Compactor.Summarizer.LLMBackend do
  @moduledoc """
  Default `JidoClaw.Reasoning.Compactor.Summarizer` backend.

  Delegates to `Jido.AI.generate_text/2`, which is itself a thin facade over
  `ReqLLM.Generation.generate_text/3`. Returns `{:ok, summary_text}` or
  `{:error, reason}`.

  The model is resolved via, in priority order:

    1. `opts[:model]` (passed through from `Summarizer.summarize/3`, sourced
       from `Config.summarizer_model`).
    2. The `:jido_claw, :compaction_summarizer_default_model` application
       env value.
    3. `:fast` — the alias every JidoClaw agent's `model:` opt uses.

  Temperature defaults to `0.2`; `max_tokens` defaults to a value that fits
  the configured `max_summary_chars` (approximated as `chars / 3`).
  """

  @behaviour JidoClaw.Reasoning.Compactor.Summarizer

  alias Jido.AI.Turn

  @default_temperature 0.2

  @impl JidoClaw.Reasoning.Compactor.Summarizer
  def summarize(prompt, opts) when is_binary(prompt) and is_list(opts) do
    model = resolve_model(opts)
    max_chars = Keyword.get(opts, :max_chars, 4_000)
    max_tokens = Keyword.get(opts, :max_tokens, max(div(max_chars, 3), 256))
    temperature = Keyword.get(opts, :temperature, @default_temperature)

    case Jido.AI.generate_text(prompt,
           model: model,
           max_tokens: max_tokens,
           temperature: temperature
         ) do
      {:ok, response} -> extract_or_empty(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_or_empty(response) do
    case Turn.extract_text(response) do
      "" -> {:error, :empty_summary}
      text when is_binary(text) -> {:ok, text}
    end
  end

  defp resolve_model(opts) do
    Keyword.get(opts, :model) ||
      Application.get_env(:jido_claw, :compaction_summarizer_default_model) ||
      :fast
  end
end
