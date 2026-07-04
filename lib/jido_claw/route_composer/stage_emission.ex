defmodule JidoClaw.RouteComposer.StageEmission do
  @moduledoc """
  One stage's typed emission on a wave — the signals it published and the
  artifacts it produced (AR-2 §7).

  `artifacts` is `%{name => ref}` — an opaque `ComposerArtifact` ref string
  (Phase 2b), not the value. `JidoClaw.RouteComposer.Emit.DefaultMapper`
  produces the pre-persist emission (inline mapper values), then
  `JidoClaw.RouteComposer.Steps.WaveCollect` ref-stores each value and the
  composer rehydrates the ref-valued emission via `from_map/1`;
  `JidoClaw.RouteComposer.Fold` indexes the refs. The struct itself
  is **not** json-safe (`JidoClaw.Orchestration.ReactorMiddleware`'s
  `json_safe?/1` rejects every struct), so `JidoClaw.RouteComposer.Steps.WaveCollect`
  returns the json-safe **map** form and the composer rehydrates each emission
  with `from_map/1`.

  `outcome` (camus C1-3) is the stage's normalizer exit: `:ok` for a real
  emission, `{:infra, reason}` when the judge produced no usable verdict, or
  `{:inconclusive, reason}` (reserved — no producer yet). A non-`:ok` emission
  carries no signals/artifacts and is **never folded** — the composer routes it
  through the infra retry budget instead.

  `from_map/1` normalizes both shapes a wave return can arrive in — the
  atom-keyed live `{:ok, value, _run}` return and the string-keyed
  JSONB-round-tripped persisted map — into one struct, the same atom/string
  tolerance `JidoClaw.Orchestration.WorkflowEvent.Projection` applies
  (`projection.ex:19`).
  """

  alias JidoClaw.Orchestration.Verdict
  alias JidoClaw.RouteComposer.StageEmission

  @type outcome :: :ok | {:infra, String.t()} | {:inconclusive, String.t()}

  @type t :: %__MODULE__{
          stage: String.t() | nil,
          signals: [String.t()],
          artifacts: %{optional(String.t()) => term()},
          outcome: outcome()
        }

  defstruct stage: nil, signals: [], artifacts: %{}, outcome: :ok

  @doc """
  Normalize an atom- or string-keyed emission map into a `%StageEmission{}`.

  Tolerates both key styles for `stage` / `signals` / `artifacts` / `outcome`;
  missing `signals` / `artifacts` default to `[]` / `%{}`. `outcome` decodes
  **fail-closed on the trust boundary** (the child `WorkflowRun.result` is DB
  data): absent — legacy rows and normal emissions — is `:ok`; a recognized
  `%{"kind" => "infra" | "inconclusive", "reason" => r}` decodes; **any other
  present value becomes `{:infra, _}`** so a malformed child result can never
  be folded as ran.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %StageEmission{
      stage: pick(map, :stage, "stage", nil),
      signals: pick(map, :signals, "signals", []),
      artifacts: pick(map, :artifacts, "artifacts", %{}),
      outcome: decode_outcome(pick(map, :outcome, "outcome", nil))
    }
  end

  # Atom key wins when present (live wave return); else the string key (persisted
  # round-trip); else the default.
  defp pick(map, atom_key, string_key, default) do
    case Map.get(map, atom_key) do
      nil -> Map.get(map, string_key, default)
      value -> value
    end
  end

  defp decode_outcome(nil), do: :ok

  defp decode_outcome(%{} = outcome) do
    kind = pick(outcome, :kind, "kind", nil)
    reason = pick(outcome, :reason, "reason", nil)

    case {decode_kind(kind), reason} do
      {{:ok, decoded}, reason} when is_binary(reason) -> {decoded, reason}
      _unrecognized -> unrecognized(outcome)
    end
  end

  defp decode_outcome(other), do: unrecognized(other)

  defp decode_kind(kind) when kind in [:infra, "infra"], do: {:ok, :infra}
  defp decode_kind(kind) when kind in [:inconclusive, "inconclusive"], do: {:ok, :inconclusive}
  defp decode_kind(_kind), do: :error

  # Fail closed: an unrecognized present outcome is itself an infra exit, with
  # the offending value rendered bounded (`Verdict.format_reason/1`).
  defp unrecognized(value), do: {:infra, Verdict.format_reason({:unrecognized_outcome, value})}
end
