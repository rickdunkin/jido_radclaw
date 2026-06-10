defmodule JidoClaw.Orchestration.Deadline do
  @moduledoc """
  Pure deadline read-model (T2-1): parse a declared lateness policy and
  evaluate it into evidence — never an action. Nothing here cancels, retries,
  or escalates a run; it only reports how late a run or step is so the
  dashboard and `workflow_status` can show it.

  ## Policy (Squidie-faithful validation)

  A policy is a map declared in skill YAML (top-level `deadline:` for the run,
  per-step `deadline:` for a step), with the semantics of
  `Squidie.Runtime.Deadline.normalize_policy/1`:

    * `within` — required **positive** integer; seconds from the anchor's
      `started_at` to the due threshold. (Squidie uses milliseconds — an
      internal unit; this YAML is human/LLM-edited, so seconds.)
    * `due_soon` — optional **non-negative** integer (seconds); the lead
      window before due (`due_soon_at = due_at − due_soon`). Must be
      `< within`. `0` is allowed (due-soon coincides with due).
    * `escalate_after` — optional **non-negative** integer (seconds); grace
      past due before `:escalated` (`escalate_at = due_at + escalate_after`).
      `0` escalates immediately at due.

  `parse/1` accepts string- or atom-keyed maps (fresh YAML vs jsonb-roundtrip
  config) and returns the normalized atom-keyed policy. It is **total**:
  `nil`, a non-map, or an invalid map all return `:none` — the compiler
  rejects invalid declarations at compile time, so by read time an invalid
  stored value is silently no-policy rather than a crash.

  ## Evidence (Squidie-faithful math)

  `evaluate/4` mirrors `Squidie.Runtime.Deadline.status/2`: thresholds use
  inclusive bounds (`t >= threshold`), checked in urgency order, and a status
  whose threshold was never declared is unreachable (no defaults). The
  effective time is `completed_at || now` — terminal runs/steps freeze their
  evidence at completion. Evidence shape:

      %{status: :on_time | :due_soon | :overdue | :escalated,
        due_at: DateTime.t(),
        due_soon_at: DateTime.t() | nil,
        escalate_at: DateTime.t() | nil,
        overdue_by_ms: non_neg_integer()}

  `overdue_by_ms` is always present and non-negative (`0` while on
  time / due-soon) — deliberately not Squidie's signed `remaining_ms`.
  `nil` when the anchor has no `started_at` yet.

  Pure (no Ash/IO/clock reads — `now` is an explicit argument). Callers
  serialize the DateTimes via `JidoClaw.Core.JsonSafe` where needed.
  """

  @type policy :: %{
          required(:within) => pos_integer(),
          optional(:due_soon) => non_neg_integer(),
          optional(:escalate_after) => non_neg_integer()
        }

  @type status :: :on_time | :due_soon | :overdue | :escalated

  @type evidence :: %{
          status: status(),
          due_at: DateTime.t(),
          due_soon_at: DateTime.t() | nil,
          escalate_at: DateTime.t() | nil,
          overdue_by_ms: non_neg_integer()
        }

  @doc """
  Parse a raw policy map (string- or atom-keyed) into the normalized policy,
  or `:none` for `nil` / non-map / invalid input.
  """
  @spec parse(term()) :: {:ok, policy()} | :none
  def parse(raw) when is_map(raw) and not is_struct(raw) do
    within = fetch(raw, :within)
    due_soon = fetch(raw, :due_soon)
    escalate_after = fetch(raw, :escalate_after)

    if valid_within?(within) and valid_optional?(due_soon) and valid_optional?(escalate_after) and
         valid_due_soon_window?(due_soon, within) do
      policy =
        %{within: within}
        |> put_present(:due_soon, due_soon)
        |> put_present(:escalate_after, escalate_after)

      {:ok, policy}
    else
      :none
    end
  end

  def parse(_raw), do: :none

  @doc """
  Evaluate a parsed policy against an anchor's lifecycle stamps. Returns the
  evidence map, or `nil` when `started_at` is nil (nothing to measure yet).
  The effective time is `completed_at || now`, so terminal anchors freeze.
  """
  @spec evaluate(policy(), DateTime.t() | nil, DateTime.t(), DateTime.t() | nil) ::
          evidence() | nil
  def evaluate(_policy, nil, _now, _completed_at), do: nil

  def evaluate(policy, %DateTime{} = started_at, %DateTime{} = now, completed_at) do
    due_at = DateTime.add(started_at, Map.fetch!(policy, :within), :second)
    due_soon_at = threshold(due_at, Map.get(policy, :due_soon), -1)
    escalate_at = threshold(due_at, Map.get(policy, :escalate_after), 1)
    t = completed_at || now

    %{
      status: status(t, due_at, due_soon_at, escalate_at),
      due_at: due_at,
      due_soon_at: due_soon_at,
      escalate_at: escalate_at,
      overdue_by_ms: max(DateTime.diff(t, due_at, :millisecond), 0)
    }
  end

  @doc """
  Convenience for read surfaces: parse a raw config value and evaluate in one
  call. `:none` (absent/invalid policy) and a nil `started_at` both yield nil.
  """
  @spec from_config(term(), DateTime.t() | nil, DateTime.t(), DateTime.t() | nil) ::
          evidence() | nil
  def from_config(raw, started_at, now, completed_at) do
    case parse(raw) do
      {:ok, policy} -> evaluate(policy, started_at, now, completed_at)
      :none -> nil
    end
  end

  # -- Internal --

  # Urgency order with inclusive bounds; a status whose threshold is absent is
  # unreachable (Squidie's status/2 — never defaulted).
  defp status(t, due_at, due_soon_at, escalate_at) do
    cond do
      at_or_after?(t, escalate_at) -> :escalated
      at_or_after?(t, due_at) -> :overdue
      at_or_after?(t, due_soon_at) -> :due_soon
      true -> :on_time
    end
  end

  defp at_or_after?(_t, nil), do: false
  defp at_or_after?(t, threshold), do: DateTime.compare(t, threshold) in [:eq, :gt]

  defp threshold(_due_at, nil, _direction), do: nil

  defp threshold(due_at, seconds, direction),
    do: DateTime.add(due_at, seconds * direction, :second)

  defp valid_within?(within), do: is_integer(within) and within > 0

  defp valid_optional?(nil), do: true
  defp valid_optional?(value), do: is_integer(value) and value >= 0

  defp valid_due_soon_window?(nil, _within), do: true
  defp valid_due_soon_window?(due_soon, within), do: due_soon < within

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp fetch(raw, key), do: Map.get(raw, key) || Map.get(raw, Atom.to_string(key))
end
