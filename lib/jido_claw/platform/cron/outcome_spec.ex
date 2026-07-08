defmodule JidoClaw.Cron.OutcomeSpec do
  @moduledoc """
  The cron outcome contract (queue item 9 rider — the OpenHelm OH1-3 *shape*:
  three field names + creation validation rules, adopted as inspiration only,
  no code transcription; BUSL-1.1 upstream). Agent-created scheduled jobs
  declare WHAT success is at **creation** — `end_state` (the state the run
  must reach), `check` (how to verify it), `stop_bound` (when to stop
  trying) — and the contract is **live at fire time**: both dispatcher agent
  arms and the workflow runner append `render_block/1` to the dispatched
  task/context.

  The single canonicalizer:

    * `normalize/1` — the string-keyed wire form (no atom/string drift across
      the `Job.metadata` JSONB boundary); nil unless all three fields are
      present and non-blank (a partial/junk durable value fails open to "no
      contract").
    * `validate/1` — the creation rules the `schedule_task` tool enforces:
      all three non-empty, each ≤ 500 chars, `check` ≠ `end_state`
      case-insensitive (a check that restates the end state verifies
      nothing).
    * `render_block/1` — the ONE deterministic contract-text renderer.

  Enforcement lives in the tool only: operator-CLI and system/migration jobs
  simply carry no contract (`normalize/1` reads their absent metadata as nil,
  `render_block/1` as `""`).
  """

  @max_field_chars 500
  @fields ~w(end_state check stop_bound)

  @typedoc "The canonical wire form: all three fields present, non-blank."
  @type t :: %{String.t() => String.t()}

  @doc "The contract field names (wire strings)."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  Normalize a durable/raw value into the canonical wire form, or nil.
  Tolerates atom- or string-keyed maps; trims fields; total over any term.
  """
  @spec normalize(term()) :: t() | nil
  def normalize(%{} = raw) do
    spec = Map.new(@fields, fn field -> {field, text(get(raw, field))} end)

    if Enum.all?(spec, fn {_field, value} -> value != "" end), do: spec, else: nil
  end

  def normalize(_other), do: nil

  @doc """
  Validate a creation-time value: `{:ok, normalized}` or `{:error, message}`
  (operator-facing, names the offending field).
  """
  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(raw) do
    raw = if is_map(raw), do: raw, else: %{}

    with :ok <- require_fields(raw),
         :ok <- bound_fields(raw),
         :ok <- distinct_check(raw) do
      {:ok, normalize(raw)}
    end
  end

  @doc """
  The deterministic contract text appended at fire time — `""` for nil, so an
  absent contract leaves the dispatched task byte-identical.
  """
  @spec render_block(t() | nil) :: String.t()
  def render_block(nil), do: ""

  def render_block(%{} = spec) do
    "[Outcome contract — the run succeeds ONLY if this is met]\n" <>
      "End state: #{spec["end_state"]}\n" <>
      "Check: #{spec["check"]}\n" <>
      "Stop bound: #{spec["stop_bound"]}"
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp require_fields(raw) do
    case Enum.find(@fields, fn field -> text(get(raw, field)) == "" end) do
      nil ->
        :ok

      field ->
        {:error,
         "Missing outcome contract field '#{field}'. Every scheduled agent job " <>
           "declares end_state (what success is), check (how to verify it), and " <>
           "stop_bound (when to stop trying)."}
    end
  end

  defp bound_fields(raw) do
    case Enum.find(@fields, fn field ->
           String.length(text(get(raw, field))) > @max_field_chars
         end) do
      nil ->
        :ok

      field ->
        {:error, "Outcome contract field '#{field}' exceeds #{@max_field_chars} characters."}
    end
  end

  # A check that restates the end state verifies nothing (the OH1-3 rule).
  defp distinct_check(raw) do
    end_state = String.downcase(text(get(raw, "end_state")))
    check = String.downcase(text(get(raw, "check")))

    if check == end_state do
      {:error,
       "Outcome contract 'check' must differ from 'end_state' — say HOW the " <>
         "end state is verified, not what it is."}
    else
      :ok
    end
  end

  # String key wins, atom key tolerated (fixed table, never String.to_atom/1).
  @atom_fields %{"end_state" => :end_state, "check" => :check, "stop_bound" => :stop_bound}

  defp get(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> value
      :error -> Map.get(map, @atom_fields[field])
    end
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_other), do: ""
end
