defmodule JidoClaw.Orchestration.Visibility do
  @moduledoc """
  Actor-visibility projection of workflow payloads (T2-2): the single place
  that decides how much of a `WorkflowRun` / `WorkflowStep` a surface may see.
  Scope is always an explicit argument — there is no ambient default:

    * `:operator` — what LLM/MCP surfaces get, permanently: run/step metadata,
      status, deadline evidence, a key-filtered `result_summary`, and a
      redacted-then-truncated error. **No raw payloads** (`step_view` carries
      no `output` key at all).
    * `:auditor` — the dashboard's per-run "Reveal payloads" scope: the same
      keys plus the full `result`/`output` maps and the untruncated error —
      every payload still `Transcript`/`Patterns`-scrubbed (defense in depth;
      `Allocate` already redacts at append time, this re-scrubs at read).

  ## Redact before truncate

  `redact_error/2` scrubs (`Patterns.redact/1`) **before** the operator
  truncation — truncating first could bisect a secret so its surviving prefix
  no longer matches any pattern. Same ordering for `result_summary` (scrub the
  whole map, then key-filter).

  ## Explicit `now`

  `run_view/3`/`step_view/3` take the clock as an argument so one timestamp
  serves a whole render/build pass — consistent durations + deadline evidence
  across every row, and deterministic tests. `WorkflowView.build/1` and the
  dashboard each capture `DateTime.utc_now()` once and thread it through.

  Lives in `Orchestration` because it projects orchestration resources
  (the `Allocate`-calls-`Transcript` precedent).
  """

  alias JidoClaw.Orchestration.Deadline
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep
  alias JidoClaw.Security.Redaction.Patterns
  alias JidoClaw.Security.Redaction.Transcript

  @type scope :: :operator | :auditor

  # Operator error truncation budget (chars), applied AFTER redaction.
  @error_limit 200

  # The result_summary key filter — the only result content operators see.
  @summary_keys [:summary, "summary", :status, "status", :message, "message"]

  @doc """
  Project a run for `scope`. The `:operator` shape preserves the exact
  pre-T2-2 `WorkflowView.run_to_map` key set (the `workflow_status` MCP
  contract) additively extended with `deadline` and the WS6 ownership fields
  (`claimed_by` / `claim_expires_at`); `:auditor` adds the full (re-scrubbed)
  `result`.

  The ownership fields are raw column reads: a terminal run's
  `claim_expires_at` is the frozen last-claim value, never live lease state —
  consumers pair it with `status` (the dashboard blanks it on terminal rows).
  """
  @spec run_view(WorkflowRun.t(), scope(), DateTime.t()) :: map()
  def run_view(%WorkflowRun{} = run, scope, %DateTime{} = now) do
    base = %{
      run_id: run.id,
      name: run.name,
      workflow_type: run.workflow_type,
      status: run.status,
      # Camus C1-4 (the "never plain green" rule): a completed-with-deferred-
      # findings run must be distinguishable from a clean one on EVERY surface,
      # so the disposition + count ride the base projection — everything
      # downstream (workflow_status, jido.runs, the dashboard badges, the
      # headless CLI) inherits them. Both non-sensitive by construction (the
      # terminal result carries keys + counts, never finding bodies).
      disposition: result_disposition(run.result),
      findings_deferred_count: result_findings_deferred_count(run.result),
      started_at: run.started_at,
      completed_at: run.completed_at,
      duration_ms: duration_ms(run.started_at, run.completed_at, now),
      # WS6 lease ownership evidence — raw/frozen column reads (see @doc).
      claimed_by: run.claimed_by,
      claim_expires_at: run.claim_expires_at,
      error: redact_error(run.error, scope),
      result_summary: result_summary(run.result),
      deadline:
        Deadline.from_config(run.config["deadline"], run.started_at, now, run.completed_at)
    }

    case scope do
      :operator -> base
      :auditor -> Map.put(base, :result, Transcript.redact(run.result))
    end
  end

  @doc """
  Project a step for `scope`. `:operator` is metadata + status only — there is
  deliberately NO `output` key (the dashboard table doesn't render output and
  the agent never needs it); `:auditor` adds the full (re-scrubbed) `output`.
  """
  @spec step_view(WorkflowStep.t(), scope(), DateTime.t()) :: map()
  def step_view(%WorkflowStep{} = step, scope, %DateTime{} = now) do
    base = %{
      name: step.name,
      step_type: step.step_type,
      sequence: step.sequence,
      status: step.status,
      started_at: step.started_at,
      completed_at: step.completed_at,
      deadline: Deadline.from_config(step.deadline, step.started_at, now, step.completed_at),
      error: redact_error(step.error, scope)
    }

    case scope do
      :operator -> base
      :auditor -> Map.put(base, :output, Transcript.redact(step.output))
    end
  end

  @doc """
  Scrub an error string for `scope`: `Patterns`-redact always; truncate to
  #{@error_limit} chars at `:operator` only — in that order, so truncation can
  never bisect a secret into a survivable fragment.
  """
  @spec redact_error(String.t() | nil, scope()) :: String.t() | nil
  def redact_error(nil, _scope), do: nil

  def redact_error(error, :auditor) when is_binary(error), do: Patterns.redact(error)

  def redact_error(error, :operator) when is_binary(error) do
    error
    |> Patterns.redact()
    |> String.slice(0, @error_limit)
  end

  # -- Internal --

  # The run's terminal disposition marker (`result.disposition`), tolerant of
  # the raw-atom vs JSONB-string key split like every payload access here.
  # Nil for runs without one (most runs) — surfaces render nothing.
  defp result_disposition(%{} = result) do
    case fetch_result(result, :disposition) do
      disposition when is_binary(disposition) -> disposition
      _other -> nil
    end
  end

  defp result_disposition(_result), do: nil

  defp result_findings_deferred_count(%{} = result) do
    case fetch_result(result, :findings_deferred_count) do
      count when is_integer(count) and count >= 0 -> count
      _other -> nil
    end
  end

  defp result_findings_deferred_count(_result), do: nil

  defp fetch_result(result, key),
    do: Map.get(result, key) || Map.get(result, Atom.to_string(key))

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = completed_at, _now),
    do: DateTime.diff(completed_at, started_at, :millisecond)

  defp duration_ms(%DateTime{} = started_at, nil, now),
    do: DateTime.diff(now, started_at, :millisecond)

  defp duration_ms(_started_at, _completed_at, _now), do: nil

  # Scrub the WHOLE term first (sensitive keys + secret-shaped strings), then
  # apply the legacy key-filter/truncation — redact-before-truncate.
  defp result_summary(nil), do: nil

  defp result_summary(value) do
    value
    |> Transcript.redact()
    |> summarize()
  end

  defp summarize(value) when is_binary(value), do: String.slice(value, 0, @error_limit)

  defp summarize(%{} = value) do
    case Map.take(value, @summary_keys) do
      empty when map_size(empty) == 0 -> nil
      summary -> summary
    end
  end

  defp summarize(_value), do: nil
end
