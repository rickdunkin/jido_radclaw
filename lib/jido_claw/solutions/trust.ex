defmodule JidoClaw.Solutions.Trust do
  @moduledoc """
  Pure functional module for computing trust scores for solutions.

  Trust score is a float in 0.0–1.0 and is composed of four weighted components:

    * Verification success   — 35%
    * Metadata completeness  — 25%
    * Freshness              — 25%
    * Agent reputation       — 15%

  All functions are pure and side-effect-free. The `compute/2` entry point
  accepts a `%JidoClaw.Solutions.Solution{}` or any map with matching fields.
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Compute a trust score (0.0–1.0) for the given solution.

  ## Options

    * `:agent_reputation` — float 0.0–1.0 representing caller-supplied agent
      reputation. Defaults to `0.5` (neutral).
    * `:now` — `DateTime` used as the reference point for freshness calculation.
      Defaults to `DateTime.utc_now()`.

  ## Formula

      verification_score(s) * 0.35
      + completeness_score(s) * 0.25
      + freshness_score(s, now) * 0.25
      + agent_reputation * 0.15
  """
  @spec compute(map(), keyword()) :: float()
  def compute(solution, opts \\ []) do
    agent_rep = Keyword.get(opts, :agent_reputation, 0.5)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    verification_score(solution) * 0.35 +
      completeness_score(solution) * 0.25 +
      freshness_score(solution, now) * 0.25 +
      agent_rep * 0.15
  end

  @doc """
  Score the verification result of a solution.

  | Verification state                          | Score |
  |---------------------------------------------|-------|
  | `nil` or empty map (untested)               | 0.3   |
  | `%{status: "passed"}` or `%{"status" => "passed"}` | 1.0 |
  | `%{status: "failed"}`  or `%{"status" => "failed"}` | 0.0 |
  | `%{status: "partial", passed: n, total: t}` | n / max(t, 1) |
  | Anything else                               | 0.3   |
  """
  @spec verification_score(map()) :: float()
  def verification_score(solution) do
    v = Map.get(solution, :verification) || Map.get(solution, "verification")
    score_verification(v)
  end

  @doc """
  Score how complete the solution metadata is.

  Base score is 0.3 (required fields are always present). Bonuses:

    * +0.10 — `:framework` / `"framework"` is present (non-nil, non-empty)
    * +0.10 — `:runtime` / `"runtime"` is present
    * +0.10 — `:tags` / `"tags"` is a non-empty list
    * +0.10 — `:agent_id` / `"agent_id"` is present
    * +0.15 — `:verification` / `"verification"` is a non-empty map
    * +0.15 — `:sharing` / `"sharing"` is not `:local` (i.e. solution is shared)

  Result is capped at 1.0.
  """
  @spec completeness_score(map()) :: float()
  def completeness_score(solution) do
    base = 0.3

    bonus =
      [
        {present?(solution, :framework, "framework"), 0.10},
        {present?(solution, :runtime, "runtime"), 0.10},
        {tags_present?(solution), 0.10},
        {present?(solution, :agent_id, "agent_id"), 0.10},
        {verification_present?(solution), 0.15},
        {sharing_not_local?(solution), 0.15}
      ]
      |> Enum.reduce(0.0, fn
        {true, pts}, acc -> acc + pts
        {false, _}, acc -> acc
      end)

    min(1.0, base + bonus)
  end

  @doc """
  Score how fresh the solution is based on its last update timestamp.

  Parses `:updated_at` first, then `:inserted_at` (ISO 8601 strings).

  | Age (days) | Score                                          |
  |------------|------------------------------------------------|
  | < 7        | 1.0                                            |
  | 7 – 365    | linear decay: `1.0 - (age - 7) / (365 - 7)`   |
  | > 365      | 0.0                                            |
  | No timestamp | 0.0                                          |
  """
  @spec freshness_score(map(), DateTime.t()) :: float()
  def freshness_score(solution, now \\ DateTime.utc_now()) do
    ts =
      Map.get(solution, :updated_at) ||
        Map.get(solution, "updated_at") ||
        Map.get(solution, :inserted_at) ||
        Map.get(solution, "inserted_at")

    case parse_datetime(ts) do
      {:ok, dt} ->
        age_days = DateTime.diff(now, dt, :second) / 86_400.0

        cond do
          age_days < 7 -> 1.0
          age_days > 365 -> 0.0
          true -> 1.0 - (age_days - 7) / (365 - 7)
        end

      :error ->
        0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — verification
  # ---------------------------------------------------------------------------

  defp score_verification(nil), do: 0.3
  defp score_verification(v) when is_map(v) and map_size(v) == 0, do: 0.3

  defp score_verification(%{status: "passed"}), do: 1.0
  defp score_verification(%{"status" => "passed"}), do: 1.0

  defp score_verification(%{status: "failed"}), do: 0.0
  defp score_verification(%{"status" => "failed"}), do: 0.0

  defp score_verification(%{status: "partial", passed: n, total: t}),
    do: n / max(t, 1)

  defp score_verification(%{"status" => "partial", "passed" => n, "total" => t}),
    do: n / max(t, 1)

  defp score_verification(%{status: "semi_formal", confidence: c})
       when is_number(c) and c >= 0.0 and c <= 1.0,
       do: c * 0.85

  defp score_verification(%{"status" => "semi_formal", "confidence" => c})
       when is_number(c) and c >= 0.0 and c <= 1.0,
       do: c * 0.85

  defp score_verification(_), do: 0.3

  # ---------------------------------------------------------------------------
  # Private helpers — completeness
  # ---------------------------------------------------------------------------

  defp present?(solution, atom_key, string_key) do
    value = Map.get(solution, atom_key) || Map.get(solution, string_key)
    not is_nil(value) and value != ""
  end

  defp tags_present?(solution) do
    tags = Map.get(solution, :tags) || Map.get(solution, "tags")
    is_list(tags) and tags != []
  end

  defp verification_present?(solution) do
    v = Map.get(solution, :verification) || Map.get(solution, "verification")
    is_map(v) and map_size(v) > 0
  end

  defp sharing_not_local?(solution) do
    sharing = Map.get(solution, :sharing) || Map.get(solution, "sharing")
    sharing not in [:local, "local", nil]
  end

  # ---------------------------------------------------------------------------
  # Private helpers — freshness
  # ---------------------------------------------------------------------------

  defp parse_datetime(nil), do: :error

  defp parse_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}
  defp parse_datetime(_), do: :error
end
