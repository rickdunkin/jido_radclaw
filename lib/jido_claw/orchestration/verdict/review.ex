defmodule JidoClaw.Orchestration.Verdict.Review do
  # Ported from mateodaza/camus @ 53da91b3, MIT (adapter.py normalize_codex),
  # mapped onto our reviewer vocabulary (workers/output_schema.ex).
  @moduledoc """
  Normalizes a reviewer's typed output (`overall` ∈
  `{approve, request_changes, comment}`, findings with `severity` ∈
  `{"info","warning","error"}`) into the three-exit `Verdict` contract. Total
  over atom-/string-keyed maps and arbitrary garbage.

  **Field coverage is routing-critical only** — `overall`, findings list-ness,
  finding map-ness, and `severity` — because those alone decide the
  clean/findings/infra lanes. Non-routing fields (`summary`, `action_needed`,
  per-finding `confidence`/`location`/`description`) pass through unvalidated
  as payload. This is camus-faithful (adapter.py validates the verdict enum,
  findings list-ness, finding object-ness, and priority; `title`/`body`/
  `confidence_score` pass through), avoids infra-retrying a verdict whose only
  flaw is a missing prose field (the item-7 deposit path would suffer most),
  and Zoi still enforces the full schema on the LLM path.

  Rule order mirrors adapter.py: emptiness → shape → overall enum → findings
  list → per-finding → self-contradiction. `clean? = approve AND findings ==
  []` (findings-win: an approve WITH findings is not clean) — byte-compatible
  with `DefaultMapper`'s former `approve?`/`findings_empty?` mapping for all
  currently-valid outputs. A missing/out-of-enum `severity` refuses to demote
  (a renamed field must never approve a bad patch); a non-approve verdict with
  zero findings is a self-contradiction (nothing actionable → untrustworthy).
  No blocking/nonblocking severity split — all findings force revise, matching
  current semantics.
  """

  alias JidoClaw.Orchestration.Verdict

  @behaviour Verdict

  @overall %{"approve" => :approve, "request_changes" => :request_changes, "comment" => :comment}
  @severities %{"info" => "info", "warning" => "warning", "error" => "error"}

  @impl Verdict
  @spec normalize(term()) :: Verdict.result()
  def normalize(raw) do
    cond do
      Verdict.blank?(raw) -> {:infra, :empty_output}
      not is_map(raw) -> {:infra, :not_a_map}
      true -> normalize_map(raw)
    end
  end

  # Every non-{:ok, _} leg is already an `{:infra, _}` exit, which `with`
  # passes through unchanged.
  defp normalize_map(map) do
    with {:ok, decision} <- decision(map),
         {:ok, findings} <- findings(map),
         :ok <- consistent(decision, findings) do
      {:verdict, verdict(decision, findings, map)}
    end
  end

  defp decision(map) do
    raw = Verdict.field(map, :overall)

    case Verdict.decode_enum(raw, @overall) do
      {:ok, decision} -> {:ok, decision}
      :error -> {:infra, {:invalid_overall, raw}}
    end
  end

  # Absent (or present-nil) findings default to `[]` — the current
  # `DefaultMapper` behavior for valid outputs; a PRESENT non-list is schema
  # drift.
  defp findings(map) do
    case Verdict.field(map, :findings) do
      nil -> {:ok, []}
      list when is_list(list) -> validate_findings(list)
      _other -> {:infra, :findings_not_a_list}
    end
  end

  defp validate_findings(list) do
    Enum.reduce_while(list, {:ok, list}, fn finding, ok ->
      case validate_finding(finding) do
        :ok -> {:cont, ok}
        {:infra, _reason} = infra -> {:halt, infra}
      end
    end)
  end

  defp validate_finding(finding) when is_map(finding) do
    raw = Verdict.field(finding, :severity)

    case Verdict.decode_enum(raw, @severities) do
      {:ok, _severity} -> :ok
      :error -> {:infra, {:invalid_severity, raw}}
    end
  end

  defp validate_finding(_finding), do: {:infra, :malformed_finding}

  # A non-approve verdict (`:request_changes` OR `:comment`) with zero findings
  # gave the loop nothing actionable — untrustworthy, never a real rejection.
  defp consistent(:approve, _findings), do: :ok
  defp consistent(_decision, []), do: {:infra, :self_contradiction}
  defp consistent(_decision, _findings), do: :ok

  defp verdict(decision, findings, map) do
    %Verdict{
      clean?: decision == :approve and findings == [],
      decision: decision,
      findings: findings,
      summary: summary(map),
      source: map
    }
  end

  # Non-routing pass-through: kept when it happens to be a binary, else nil —
  # never an infra exit.
  defp summary(map) do
    case Verdict.field(map, :summary) do
      summary when is_binary(summary) -> summary
      _other -> nil
    end
  end
end
