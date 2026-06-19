defmodule JidoClaw.RouteComposer.StageEmission do
  @moduledoc """
  One stage's typed emission on a wave — the signals it published and the
  artifacts it produced (AR-2 §7).

  This is in-memory mapper I/O: `JidoClaw.RouteComposer.Emit.DefaultMapper`
  produces it and `JidoClaw.RouteComposer.Fold` consumes it. The struct itself
  is **not** json-safe (`JidoClaw.Orchestration.ReactorMiddleware`'s
  `json_safe?/1` rejects every struct), so `JidoClaw.RouteComposer.Steps.WaveCollect`
  returns the json-safe **map** form and the composer rehydrates each emission
  with `from_map/1`.

  `from_map/1` normalizes both shapes a wave return can arrive in — the
  atom-keyed live `{:ok, value, _run}` return and the string-keyed
  JSONB-round-tripped persisted map — into one struct, the same atom/string
  tolerance `JidoClaw.Orchestration.WorkflowEvent.Projection` applies
  (`projection.ex:19`).
  """

  alias JidoClaw.RouteComposer.StageEmission

  @type t :: %__MODULE__{
          stage: String.t() | nil,
          signals: [String.t()],
          artifacts: %{optional(String.t()) => term()}
        }

  defstruct stage: nil, signals: [], artifacts: %{}

  @doc """
  Normalize an atom- or string-keyed emission map into a `%StageEmission{}`.

  Tolerates both key styles for `stage` / `signals` / `artifacts`; missing
  `signals` / `artifacts` default to `[]` / `%{}`.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %StageEmission{
      stage: pick(map, :stage, "stage", nil),
      signals: pick(map, :signals, "signals", []),
      artifacts: pick(map, :artifacts, "artifacts", %{})
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
end
