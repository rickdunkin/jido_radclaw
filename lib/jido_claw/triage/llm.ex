defmodule JidoClaw.Triage.LLM do
  @moduledoc """
  The default `JidoClaw.Triage` impl: one `Jido.AI.generate_object/3` call per
  turn — **no process spawned, no tools, no `tool_context`, no recorder rows**.

  `generate_object/3` returns `{:ok, %ReqLLM.Response{}}`, NOT the object, so the
  object is extracted with `ReqLLM.Response.unwrap_object/2` (`json_repair: true`,
  exactly as `Jido.AI.Output.parse` does) before `Verdict.from_map/1`.

  This impl does **not** self-swallow to `talk`. It returns `{:error, reason}` on
  failure and lets a raise/exit propagate. The **façade** (`JidoClaw.Triage`) is
  the sole fail-safe boundary: it coerces any failure → `{:ok, talk}` *and* records
  `fallback?: true` in telemetry. A self-swallowing impl here would hide its own
  failures as a normal `talk` and undercount the fail-safe rate (R5-P2).
  """

  @behaviour JidoClaw.Triage

  require Logger

  alias JidoClaw.Error
  alias JidoClaw.Triage.Prompt
  alias JidoClaw.Triage.Schema
  alias JidoClaw.Triage.Verdict

  # A tool-less classify needs only a small structured object; cap tokens low and
  # pin temperature to 0 for a deterministic-as-possible verdict.
  @max_tokens 700
  @temperature 0.0
  @timeout_ms 20_000

  @impl JidoClaw.Triage
  @spec classify(String.t(), keyword()) :: {:ok, Verdict.t()} | {:error, term()}
  def classify(message, opts) when is_binary(message) do
    with {:ok, resp} <-
           gen().(Prompt.user(message, opts[:history] || []), Schema.zoi(),
             model: resolve_model(),
             system_prompt: Prompt.system(),
             max_tokens: @max_tokens,
             temperature: @temperature,
             timeout: @timeout_ms
           ),
         {:ok, object} <- ReqLLM.Response.unwrap_object(resp, json_repair: true),
         {:ok, verdict} <- Verdict.from_map(object) do
      {:ok, verdict}
    else
      {:error, reason} = err ->
        # A short, summarized reason — NOT a raw provider payload that could echo
        # prompt/artifact text (the global LogRedactor filter is belt-and-
        # suspenders; summarize_reason/1 drops the payload at the source). R6-P3.
        Logger.debug("[Triage.LLM] degraded to fallback: #{Error.summarize_reason(reason)}")
        err

      other ->
        # Never self-coerce to talk — the façade does that AND counts it.
        {:error, {:unexpected, other}}
    end
  end

  # Configurable model — a DIRECT model spec (default `:fast`). A literal binary
  # like "anthropic:claude-haiku-4-5" bypasses `model_aliases` entirely, so it is
  # REPL-safe with no alias plumbing; the `:fast` atom resolves through the alias
  # map the REPL configures (mirrors `LLMBackend.resolve_model/1`).
  defp resolve_model, do: Application.get_env(:jido_claw, :triage_model, :fast)

  # Seam so a test can inject a failing/canned `generate_object` without a real
  # LLM (mirrors `:ask_runtime`).
  defp gen, do: Application.get_env(:jido_claw, :triage_generate, &Jido.AI.generate_object/3)
end
