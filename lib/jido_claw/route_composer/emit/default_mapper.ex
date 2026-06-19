defmodule JidoClaw.RouteComposer.Emit.DefaultMapper do
  @moduledoc """
  The `emit: :default` mapper — turns a stage's typed worker output into a
  `%JidoClaw.RouteComposer.StageEmission{}` (AR-2 §7).

  Given a `%JidoClaw.Workflows.StepResult{}` and the stage meta projection
  `%{name, emit, lens, output, publishes}`, it derives:

    1. **Reviewer verdict** — when the typed output is reviewer-shaped (`overall
       ∈ {approve, request_changes, comment}`): `overall == :approve` with no
       findings emits `clean:<lens>`, else `findings:<lens>` plus a `findings`
       artifact. A reviewer-shaped stage with no `lens` is a coherence error.
    2. **Explicit signals** — the producer's declared emitted-signal list under
       `typed_output[:signals]` / `typed_output["signals"]` (the Phase-1 `:default`
       convention for non-reviewer producers).
    3. **Artifacts** — each `stage.output` name mapped to a value pulled from
       `typed_output` / `StepResult.artifacts` / `StepResult.result` (in that
       precedence), coerced json-safe (inline values — Phase 1).
    4. **⊆ `publishes`** — every emitted signal must be a declared `publishes`
       topic. A signal outside `publishes` returns `{:error, _}`, which
       `WaveCollect` propagates as a wave failure — **never a silent drop** (a
       dropped `findings:<lens>` would let the loop converge as clean when it is
       not). The verdict-family declarations are *also* enforced at catalog-load
       (`JidoClaw.RouteComposer.CatalogValidator`), so this is defense-in-depth.

  Typed output is atom-keyed when live and string-keyed once it round-trips JSON
  (the `projection.ex:19` precedent), so every lookup tries both.
  """

  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.Workflows.StepResult

  @verdicts [:approve, :request_changes, :comment, "approve", "request_changes", "comment"]

  @type meta :: %{
          :name => String.t(),
          :emit => term(),
          :lens => String.t() | nil,
          :output => [String.t()],
          :publishes => [String.t()]
        }

  @doc """
  Map a `%StepResult{}` + stage meta to a `%StageEmission{}`, or `{:error,
  reason}` on an undeclared signal or a reviewer-without-lens coherence error.
  """
  @spec map(StepResult.t(), meta()) :: {:ok, StageEmission.t()} | {:error, term()}
  def map(%StepResult{} = result, meta) do
    typed = result.typed_output || %{}

    with {:ok, {verdict_signals, verdict_artifacts}} <- verdict(typed, meta),
         signals = Enum.uniq(verdict_signals ++ explicit_signals(typed)),
         :ok <- validate_publishes(signals, meta) do
      artifacts = Map.merge(verdict_artifacts, output_artifacts(result, typed, meta))
      {:ok, %StageEmission{stage: meta.name, signals: signals, artifacts: artifacts}}
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Reviewer verdict
  # ---------------------------------------------------------------------------

  defp verdict(typed, meta) do
    overall = overall(typed)

    if overall in @verdicts do
      reviewer_verdict(overall, typed, meta)
    else
      {:ok, {[], %{}}}
    end
  end

  defp reviewer_verdict(overall, typed, %{lens: lens} = _meta) when is_binary(lens) do
    if approve?(overall) and findings_empty?(typed) do
      {:ok, {["clean:#{lens}"], %{}}}
    else
      {:ok, {["findings:#{lens}"], %{"findings" => coerce(findings(typed))}}}
    end
  end

  defp reviewer_verdict(_overall, _typed, %{name: name}),
    do: {:error, {:reviewer_without_lens, name}}

  defp overall(typed), do: known(typed, :overall, "overall")

  defp approve?(overall), do: overall in [:approve, "approve"]

  defp findings(typed), do: known(typed, :findings, "findings") || []

  defp findings_empty?(typed), do: findings(typed) == []

  # ---------------------------------------------------------------------------
  # 2. Explicit signals
  # ---------------------------------------------------------------------------

  defp explicit_signals(typed) do
    case known(typed, :signals, "signals") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Artifacts — stage.output names pulled from typed / artifacts / result
  # ---------------------------------------------------------------------------

  defp output_artifacts(result, typed, %{output: output}) do
    Map.new(output, fn name -> {name, output_value(name, result, typed)} end)
  end

  defp output_value(name, result, typed) do
    case dynamic(typed, name) do
      {:ok, value} -> coerce(value)
      :error -> artifact_or_text(name, result)
    end
  end

  defp artifact_or_text(name, result) do
    case Map.fetch(result.artifacts, name) do
      {:ok, value} -> coerce(value)
      :error -> result.result
    end
  end

  # ---------------------------------------------------------------------------
  # 4. ⊆ publishes
  # ---------------------------------------------------------------------------

  defp validate_publishes(signals, %{publishes: publishes} = meta) do
    declared = MapSet.new(publishes)

    case Enum.reject(signals, &MapSet.member?(declared, &1)) do
      [] -> :ok
      undeclared -> {:error, {:undeclared_signals, meta.name, undeclared}}
    end
  end

  # ---------------------------------------------------------------------------
  # Atom/string-tolerant lookups
  # ---------------------------------------------------------------------------

  # A known key written literally in both styles.
  defp known(typed, atom_key, string_key) do
    case Map.get(typed, atom_key) do
      nil -> Map.get(typed, string_key)
      value -> value
    end
  end

  # A dynamic (catalog-string) key: scan keys by `to_string/1` so an atom-keyed
  # live output matches without ever `String.to_atom/1`-ing the name.
  defp dynamic(typed, name) do
    Enum.find_value(typed, :error, fn {k, v} -> if to_string(k) == name, do: {:ok, v} end)
  end

  # ---------------------------------------------------------------------------
  # json-safe coercion (inline, non-sensitive — Phase 1)
  # ---------------------------------------------------------------------------

  defp coerce(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp coerce(value) when is_list(value), do: Enum.map(value, &coerce/1)
  defp coerce(value) when is_struct(value), do: inspect(value)

  defp coerce(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {coerce_key(k), coerce(v)} end)

  defp coerce(value), do: inspect(value)

  defp coerce_key(k) when is_binary(k) or is_atom(k), do: k
  defp coerce_key(k), do: inspect(k)
end
