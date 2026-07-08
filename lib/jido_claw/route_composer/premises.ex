defmodule JidoClaw.RouteComposer.Premises do
  @moduledoc """
  The typed-key vocabulary for composer premises (queue item 9 — ouroboros
  OB1-2, orca OR2-5 rider): three optional, structured keys beside the free
  launch assumptions (`path`, `est_size`, clarify keys):

    * `"acceptance_criteria"` — a list of observable criterion strings. Their
      identity contract (orca OQ-2) is the 1-based index id `AC1`, `AC2`, … —
      premises compose once at launch, so the ids are stable for the run.
    * `"evaluation_principles"` — a list of `%{"name", "description",
      "weight"}` maps, weight clamped to `0..1`.
    * `"exit_conditions"` — a list of stop/done condition strings.

  `normalize/1` is the WRITE boundary (`FrontDoor.build_premises/5` routes the
  merged map through it before launch): a malformed typed value is dropped
  from the map — Trace'd, fail-open, never a crashed launch. The value-level
  normalizers are shared with the producers (clarify scorer/state round-trip)
  so one shape rule holds everywhere. Read accessors are tolerant over
  arbitrary durable state (recovery hands persisted config back verbatim):
  junk reads as `[]`, never raises.
  """

  alias JidoClaw.Trace

  @typed_keys ~w(acceptance_criteria evaluation_principles exit_conditions)

  @typedoc "A normalized evaluation principle (string-keyed, JSON-safe)."
  @type principle :: %{String.t() => String.t() | float()}

  @doc "The typed premises key names (wire strings)."
  @spec typed_keys() :: [String.t()]
  def typed_keys, do: @typed_keys

  @doc """
  Normalize the whole premises map at the write boundary: each typed key's
  value is run through its value normalizer; a value that is not a list at
  all is DROPPED (+ Trace) — fail-open, the launch proceeds without the key.
  Total: a non-map passes through unchanged (nothing typed to normalize —
  the renderer already degrades malformed premises to `""`).
  """
  @spec normalize(term()) :: term()
  def normalize(premises) when is_map(premises) do
    Enum.reduce(@typed_keys, premises, &normalize_key/2)
  end

  def normalize(other), do: other

  @doc "The acceptance criteria — `[]` unless a list of non-blank strings."
  @spec criteria(term()) :: [String.t()]
  def criteria(premises), do: read_list(premises, "acceptance_criteria", &normalize_criteria/1)

  @doc "Criteria zipped with their stable ids: `[{\"AC1\", text}, …]` (orca OQ-2)."
  @spec criteria_with_ids(term()) :: [{String.t(), String.t()}]
  def criteria_with_ids(premises) do
    premises
    |> criteria()
    |> Enum.with_index(1)
    |> Enum.map(fn {text, index} -> {"AC#{index}", text} end)
  end

  @doc "The evaluation principles — `[]` unless a list of valid principle maps."
  @spec principles(term()) :: [principle()]
  def principles(premises),
    do: read_list(premises, "evaluation_principles", &normalize_principles/1)

  @doc "The exit conditions — `[]` unless a list of non-blank strings."
  @spec exit_conditions(term()) :: [String.t()]
  def exit_conditions(premises),
    do: read_list(premises, "exit_conditions", &normalize_conditions/1)

  @doc """
  Value normalizer for criterion/condition lists: keeps trimmed non-blank
  binaries, drops everything else. Total (`[]` for any non-list).
  """
  @spec normalize_criteria(term()) :: [String.t()]
  def normalize_criteria(value) when is_list(value) do
    value
    |> Enum.map(&trim_binary/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_criteria(_other), do: []

  @doc "Alias of `normalize_criteria/1` for the `exit_conditions` producer side."
  @spec normalize_conditions(term()) :: [String.t()]
  def normalize_conditions(value), do: normalize_criteria(value)

  @doc """
  Value normalizer for evaluation principles: keeps maps carrying a non-blank
  `name` and a numeric `weight` (clamped to `0..1`; `description` coerces to
  `""`), drops non-map/non-numeric entries. Total (`[]` for any non-list).
  """
  @spec normalize_principles(term()) :: [principle()]
  def normalize_principles(value) when is_list(value) do
    value
    |> Enum.map(&normalize_principle/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_principles(_other), do: []

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp normalize_key(key, premises) do
    case Map.fetch(premises, key) do
      :error -> premises
      {:ok, value} when is_list(value) -> Map.put(premises, key, normalize_value(key, value))
      {:ok, _malformed} -> drop_key(premises, key)
    end
  end

  defp normalize_value("evaluation_principles", value), do: normalize_principles(value)
  defp normalize_value(_criteria_or_conditions, value), do: normalize_criteria(value)

  # Fail-open drop: the launch proceeds without the malformed key; the Trace
  # guardrail event is the loud record (the `emit_clarify` pattern).
  defp drop_key(premises, key) do
    Trace.emit(
      :guardrail,
      %{guardrail: "premises", event: :typed_key_dropped, key: key},
      %{system_time: System.system_time()}
    )

    Map.delete(premises, key)
  end

  defp read_list(premises, key, normalizer) when is_map(premises),
    do: normalizer.(Map.get(premises, key))

  defp read_list(_premises, _key, _normalizer), do: []

  defp normalize_principle(%{} = raw) do
    name = trim_binary(get(raw, "name"))
    weight = get(raw, "weight")

    if is_binary(name) and is_number(weight) do
      %{
        "name" => name,
        "description" => binary_or_empty(get(raw, "description")),
        "weight" => clamp01(weight)
      }
    end
  end

  defp normalize_principle(_other), do: nil

  # String key wins, atom key tolerated (the Ledger `get` idiom — a fixed
  # table lookup, never `String.to_atom/1`).
  @principle_atom_keys %{"name" => :name, "description" => :description, "weight" => :weight}

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, @principle_atom_keys[key])
    end
  end

  defp trim_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_binary(_other), do: nil

  defp binary_or_empty(value) when is_binary(value), do: value
  defp binary_or_empty(_other), do: ""

  defp clamp01(value), do: :erlang.float(min(max(value, 0), 1))
end
