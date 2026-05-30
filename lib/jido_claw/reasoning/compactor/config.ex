defmodule JidoClaw.Reasoning.Compactor.Config do
  @moduledoc """
  Per-agent compaction configuration.

  Carried on the agent module (via `JidoClaw.Agent.Defaults`) and threaded
  through `JidoClaw.Reasoning.Compactor.maybe_compact/3` and the bounded
  summarizer call. The main agent and all seven workers carry `mode: :auto`;
  a site opts out with `mode: :off`.

  ## Fields

    * `:mode` — `:auto | :manual | :off`. `:auto` runs per-turn checks on
      `:ai_react_start`. `:manual` only runs when `Compactor.compact/3` is
      called explicitly. `:off` makes the macro emit a no-op override.
    * `:strategy` — currently only `:summary` is supported.
    * `:max_messages` — projected-message count that triggers a first
      compaction.
    * `:recompact_delta_threshold` — number of *new* messages since the last
      watermark that triggers a re-compaction. Defaults to
      `div(max_messages, 2)`.
    * `:keep_last_turns` — minimum number of turns to keep verbatim at the
      tail of the slice.
    * `:protect_first_n_turns` — number of leading turns to keep verbatim on
      the *first* compaction only. Effectively `0` for re-compactions.
    * `:max_summary_chars` — hard upper bound on the produced summary.
    * `:summarizer_model` — ReqLLM-compatible model spec; `nil` lets the
      summarizer pick a default from the agent's config.
    * `:summarizer_timeout_ms` — bounded timeout for the summarizer Task.
    * `:summarizer_max_retries` — number of *additional* summarizer
      attempts after the first one fails with a transient phase
      (`:summarizer_timeout`, `:summarizer_exit`, `:summarizer_backend`).
      `0` disables retries; the default `1` means up to two total
      attempts. `:summarizer_exception` is never retried.
    * `:summarizer_retry_backoff_ms` — fixed delay slept between retry
      attempts. Worst-case added latency is
      `summarizer_max_retries * (summarizer_timeout_ms + summarizer_retry_backoff_ms)`.

  ## Invariants

    * `keep_last_turns > 0`
    * `protect_first_n_turns >= 0`
    * `max_messages > keep_last_turns + protect_first_n_turns`
    * `recompact_delta_threshold > 0`
    * `max_summary_chars > 0`
    * `summarizer_timeout_ms > 0`
    * `summarizer_max_retries >= 0`
    * `summarizer_retry_backoff_ms > 0`
  """

  alias JidoClaw.Error

  @type mode :: :auto | :manual | :off
  @type strategy :: :summary

  @type t :: %__MODULE__{
          mode: mode(),
          strategy: strategy(),
          max_messages: pos_integer(),
          recompact_delta_threshold: pos_integer(),
          keep_last_turns: pos_integer(),
          protect_first_n_turns: non_neg_integer(),
          max_summary_chars: pos_integer(),
          summarizer_model: term() | nil,
          summarizer_timeout_ms: pos_integer(),
          summarizer_max_retries: non_neg_integer(),
          summarizer_retry_backoff_ms: pos_integer()
        }

  @enforce_keys [
    :mode,
    :strategy,
    :max_messages,
    :recompact_delta_threshold,
    :keep_last_turns,
    :protect_first_n_turns,
    :max_summary_chars,
    :summarizer_timeout_ms,
    :summarizer_max_retries,
    :summarizer_retry_backoff_ms
  ]
  defstruct mode: :off,
            strategy: :summary,
            max_messages: 60,
            recompact_delta_threshold: 30,
            keep_last_turns: 6,
            protect_first_n_turns: 2,
            max_summary_chars: 4_000,
            summarizer_model: nil,
            summarizer_timeout_ms: 15_000,
            summarizer_max_retries: 1,
            summarizer_retry_backoff_ms: 250

  @doc """
  Returns a `%Config{}` with the default `:auto` compaction settings.

  Note: `default/0` returns mode `:auto` — the same mode the main agent and
  all seven workers carry. A site opts out with `mode: :off` via its own
  `use JidoClaw.Agent.Defaults, compaction: [mode: :off]`.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      mode: :auto,
      strategy: :summary,
      max_messages: 60,
      recompact_delta_threshold: 30,
      keep_last_turns: 6,
      protect_first_n_turns: 2,
      max_summary_chars: 4_000,
      summarizer_model: nil,
      summarizer_timeout_ms: 15_000,
      summarizer_max_retries: 1,
      summarizer_retry_backoff_ms: 250
    }
  end

  @doc """
  Returns an `:off` config for opt-out callers.
  """
  @spec off() :: t()
  def off do
    %__MODULE__{
      mode: :off,
      strategy: :summary,
      max_messages: 60,
      recompact_delta_threshold: 30,
      keep_last_turns: 6,
      protect_first_n_turns: 2,
      max_summary_chars: 4_000,
      summarizer_model: nil,
      summarizer_timeout_ms: 15_000,
      summarizer_max_retries: 1,
      summarizer_retry_backoff_ms: 250
    }
  end

  @doc """
  Builds a `%Config{}` from a keyword list or map of overrides.

  Returns `{:ok, %Config{}}` on success or `{:error, %JidoClaw.Error.ValidationError{}}`
  if invariants are violated.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(overrides) do
    base = default()
    overrides_map = normalize_overrides(overrides)

    config =
      base
      |> Map.from_struct()
      |> Map.merge(overrides_map)
      |> apply_derived_defaults(overrides_map)

    case validate(config) do
      :ok -> {:ok, struct!(__MODULE__, config)}
      {:error, _} = err -> err
    end
  end

  defp normalize_overrides(overrides) when is_list(overrides), do: Map.new(overrides)
  defp normalize_overrides(overrides) when is_map(overrides), do: overrides
  defp normalize_overrides(_), do: %{}

  @doc """
  Builds a `%Config{}`, raising on invalid input.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(overrides) do
    case new(overrides) do
      {:ok, config} -> config
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Validates an existing `%Config{}` or map. Returns `:ok` or
  `{:error, %ValidationError{}}`.
  """
  @spec validate(t() | map()) :: :ok | {:error, Exception.t()}
  def validate(%__MODULE__{} = config), do: validate(Map.from_struct(config))

  def validate(%{} = config) do
    with :ok <- check_mode(config),
         :ok <- check_strategy(config),
         :ok <- check_positive(config, :max_messages),
         :ok <- check_positive(config, :recompact_delta_threshold),
         :ok <- check_positive(config, :keep_last_turns),
         :ok <- check_non_negative(config, :protect_first_n_turns),
         :ok <- check_positive(config, :max_summary_chars),
         :ok <- check_positive(config, :summarizer_timeout_ms),
         :ok <- check_non_negative(config, :summarizer_max_retries),
         :ok <- check_positive(config, :summarizer_retry_backoff_ms),
         :ok <- check_capacity(config) do
      :ok
    end
  end

  @doc """
  Validates and raises on failure. Used at compile-time by the
  `JidoClaw.Agent.Defaults` macro.
  """
  @spec validate!(t() | map()) :: :ok
  def validate!(config) do
    case validate(config) do
      :ok -> :ok
      {:error, exception} -> raise exception
    end
  end

  defp apply_derived_defaults(config, overrides_map) do
    explicit_rdt? = Map.has_key?(overrides_map, :recompact_delta_threshold)
    explicit_max? = Map.has_key?(overrides_map, :max_messages)
    rdt = Map.get(config, :recompact_delta_threshold)

    cond do
      explicit_rdt? and (is_nil(rdt) or rdt == :auto) ->
        Map.put(config, :recompact_delta_threshold, derive_rdt(config.max_messages))

      explicit_max? and not explicit_rdt? ->
        Map.put(config, :recompact_delta_threshold, derive_rdt(config.max_messages))

      true ->
        config
    end
  end

  defp derive_rdt(max_m) when is_integer(max_m) and max_m > 0,
    do: max(div(max_m, 2), 1)

  defp derive_rdt(_), do: 1

  defp check_mode(%{mode: m}) when m in [:auto, :manual, :off], do: :ok

  defp check_mode(%{mode: m}),
    do:
      {:error,
       Error.validation_error("Invalid compaction mode: #{inspect(m)}",
         field: :mode,
         value: m,
         details: %{operation: :compaction}
       )}

  defp check_strategy(%{strategy: :summary}), do: :ok

  defp check_strategy(%{strategy: s}),
    do:
      {:error,
       Error.validation_error("Unsupported compaction strategy: #{inspect(s)}",
         field: :strategy,
         value: s,
         details: %{operation: :compaction}
       )}

  defp check_positive(config, field) do
    case Map.get(config, field) do
      n when is_integer(n) and n > 0 ->
        :ok

      other ->
        {:error,
         Error.validation_error(
           "#{field} must be a positive integer, got: #{inspect(other)}",
           field: field,
           value: other,
           details: %{operation: :compaction}
         )}
    end
  end

  defp check_non_negative(config, field) do
    case Map.get(config, field) do
      n when is_integer(n) and n >= 0 ->
        :ok

      other ->
        {:error,
         Error.validation_error(
           "#{field} must be a non-negative integer, got: #{inspect(other)}",
           field: field,
           value: other,
           details: %{operation: :compaction}
         )}
    end
  end

  defp check_capacity(%{
         max_messages: max_m,
         keep_last_turns: keep_k,
         protect_first_n_turns: protect_p
       })
       when is_integer(max_m) and is_integer(keep_k) and is_integer(protect_p) and
              max_m > keep_k + protect_p,
       do: :ok

  defp check_capacity(config) do
    {:error,
     Error.validation_error(
       "max_messages must be greater than keep_last_turns + protect_first_n_turns",
       field: :max_messages,
       value: Map.get(config, :max_messages),
       details: %{
         operation: :compaction,
         keep_last_turns: Map.get(config, :keep_last_turns),
         protect_first_n_turns: Map.get(config, :protect_first_n_turns)
       }
     )}
  end
end
