defmodule JidoClaw.RouteComposer.Emit.DefaultMapper do
  @moduledoc """
  The `emit: :default` mapper — turns a stage's typed worker output into a
  `%JidoClaw.RouteComposer.StageEmission{}` (AR-2 §7).

  Given a `%JidoClaw.Workflows.StepResult{}` and the stage meta projection
  `%{name, emit, lens, output, publishes}`, it derives:

    1. **Blocked-producer refusal** (AR-4 P1) — a non-reviewer producer (`lens
       == nil`) that reports `status: :blocked` produced no usable output. Its
       named artifact (`diff`/`fix`/`plan`/`prototype`/`system-change`) is never
       a schema field, so the artifact step below would fabricate it from the
       blocked `summary` (`StepResult.result`). Instead it returns `{:error,
       {:producer_blocked, name}}`, so `WaveCollect` fails the wave
       (`route_failed`) rather than advancing a downstream consumer against a
       "BLOCKED…" string — or silently converging with no lens having run.
       `:partial`/`:completed` proceed (a `:partial` summary is real, if
       incomplete, output); reviewers (`lens` set) carry `overall`, not
       `status`, so they never match.
    2. **Reviewer verdict** (camus C1-3) — dispatched on **`lens` presence, not
       output shape** (a malformed reviewer output is still recognized as a
       reviewer). A lens-carrying stage routes through
       `JidoClaw.Orchestration.Verdict.normalize(:review, typed)`: a clean
       verdict emits `clean:<lens>`, findings emit `findings:<lens>` plus a
       `findings` artifact, and an `{:infra, _}` exit (empty/drifted/
       self-contradicting output) becomes an emission with **no signals, no
       artifacts, and `outcome: {:infra, reason}`** — the composer retries it
       on the infra budget instead of folding it (never silently clean, never
       a burned rerun). A lens-nil stage whose output is reviewer-shaped
       (`overall ∈ {approve, request_changes, comment}`) stays a coherence
       error.
    3. **Explicit signals** — the producer's declared emitted-signal list under
       `typed_output[:signals]` / `typed_output["signals"]` (the Phase-1 `:default`
       convention for non-reviewer producers).
    4. **Artifacts** — each `stage.output` name mapped to a value pulled from
       `typed_output` / `StepResult.artifacts` / `StepResult.result` (in that
       precedence), coerced json-safe (inline values — Phase 1).
    5. **⊆ `publishes`** — every emitted signal must be a declared `publishes`
       topic. A signal outside `publishes` returns `{:error, _}`, which
       `WaveCollect` propagates as a wave failure — **never a silent drop** (a
       dropped `findings:<lens>` would let the loop converge as clean when it is
       not). The verdict-family declarations are *also* enforced at catalog-load
       (`JidoClaw.RouteComposer.CatalogValidator`), so this is defense-in-depth.

  Typed output is atom-keyed when live and string-keyed once it round-trips JSON
  (the `projection.ex:19` precedent), so every lookup tries both.
  """

  alias JidoClaw.Orchestration.ComposerArtifact.Envelope
  # The orchestration normalizer — NOT JidoClaw.Triage.Verdict (different
  # subsystem; never alias both in one module).
  alias JidoClaw.Orchestration.Verdict
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
  reason}` on a blocked non-reviewer producer, an undeclared signal, or a
  reviewer-without-lens coherence error.
  """
  @spec map(StepResult.t(), meta()) :: {:ok, StageEmission.t()} | {:error, term()}
  def map(%StepResult{} = result, meta) do
    typed = result.typed_output || %{}

    with :ok <- refuse_blocked_producer(typed, meta),
         {:ok, {verdict_signals, verdict_artifacts, outcome}} <- verdict(typed, meta) do
      build_emission(result, typed, meta, {verdict_signals, verdict_artifacts}, outcome)
    end
  end

  # An infra outcome suppresses explicit signals AND output artifacts — the
  # judge produced no usable verdict, so nothing it "said" may enter the fold;
  # the emission carries only the outcome for the composer's infra lane.
  defp build_emission(_result, _typed, meta, _verdict, {:infra, _reason} = outcome) do
    {:ok, %StageEmission{stage: meta.name, signals: [], artifacts: %{}, outcome: outcome}}
  end

  defp build_emission(result, typed, meta, {verdict_signals, verdict_artifacts}, :ok) do
    signals = Enum.uniq(verdict_signals ++ explicit_signals(typed))

    with :ok <- validate_publishes(signals, meta) do
      artifacts = Map.merge(verdict_artifacts, output_artifacts(result, typed, meta))
      {:ok, %StageEmission{stage: meta.name, signals: signals, artifacts: artifacts}}
    end
  end

  # ---------------------------------------------------------------------------
  # 0. Blocked-producer refusal (AR-4 P1)
  # ---------------------------------------------------------------------------

  # A non-reviewer producer (`lens == nil`) that reports `status: :blocked`
  # produced no usable output — its named artifact (`diff`/`fix`/`plan`/
  # `prototype`/`system-change`) is never a schema field, so `output_value/3`
  # would fabricate it from the blocked `summary` (`result.result`). Refuse it
  # LOUDLY so `WaveCollect` fails the wave (`route_failed`) rather than advancing
  # a downstream consumer against a "BLOCKED…" string — or silently converging.
  # Reviewers (`lens` set) carry `overall`, not `status`, so they never match.
  # `:partial`/`:completed` proceed (a `:partial` summary is real, if thin,
  # output).
  defp refuse_blocked_producer(typed, %{lens: nil, name: name}) do
    case known(typed, :status, "status") do
      s when s in [:blocked, "blocked"] -> {:error, {:producer_blocked, name}}
      _ -> :ok
    end
  end

  defp refuse_blocked_producer(_typed, _meta), do: :ok

  # ---------------------------------------------------------------------------
  # 1. Reviewer verdict (camus C1-3 — dispatch on lens presence, never shape)
  # ---------------------------------------------------------------------------

  # A lens-carrying stage IS a reviewer, whatever its output looks like: route
  # the typed output through the normalizer. `{:infra, _}` (and the defensive
  # `{:inconclusive, _}` — item 5's verify stage produces it, though never
  # through this mapper) becomes the emission's outcome with a bounded,
  # formatted reason; the old shape-dispatch let a drifted `overall` fall
  # through as a silent empty emission that never went clean.
  defp verdict(typed, %{lens: lens}) when is_binary(lens) do
    case Verdict.normalize(:review, typed) do
      {:verdict, %Verdict{clean?: true}} ->
        {:ok, {["clean:#{lens}"], %{}, :ok}}

      {:verdict, %Verdict{findings: findings}} ->
        {:ok, {["findings:#{lens}"], %{"findings" => coerce(findings)}, :ok}}

      {infra_or_inconclusive, reason}
      when infra_or_inconclusive in [:infra, :inconclusive] ->
        {:ok, {[], %{}, {:infra, Verdict.format_reason(reason)}}}
    end
  end

  # A lens-nil stage with a reviewer-shaped output is a coherence error; any
  # other producer output passes through untouched (never the normalizer).
  defp verdict(typed, %{lens: nil, name: name}) do
    if known(typed, :overall, "overall") in @verdicts do
      {:error, {:reviewer_without_lens, name}}
    else
      {:ok, {[], %{}, :ok}}
    end
  end

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
      # The `result.result` fallback runs through `coerce/1` too (A5) — a raw
      # value here would otherwise reach `store_pending` un-normalized.
      :error -> coerce(result.result)
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
  # No-novel-atom, json-safe coercion (AR-2 §6 / A5)
  # ---------------------------------------------------------------------------

  # The single shared normalizer (re-asserted by `ComposerArtifact`'s
  # `store_pending` before encode) so a stored artifact blob is always
  # `[:safe]`-decodable: every non-`true`/`false`/`nil` atom is stringified,
  # and atom map keys go through `Atom.to_string/1` (never `String.to_atom/1`).
  defp coerce(value), do: Envelope.normalize(value)
end
