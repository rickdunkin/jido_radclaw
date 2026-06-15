defmodule JidoClaw.Orchestration.Replay.Safety do
  @moduledoc """
  The non-definition replay gates, shared so `Replay.replay/2` and
  `Replay.Diagnostics.diagnose/2` apply the exact same checks and cannot drift.
  Extracted from `Replay`; **no definition resolution** lives here (that is
  `JidoClaw.Orchestration.Replay.DefinitionResolver`).

    * **Terminal gate** — only a run that can no longer make progress is
      replayable. `terminal_status?/1` takes the status atom explicitly (no
      `%WorkflowRun{}` ambiguity) and delegates to `WorkflowEvent.Projection`,
      the single source of the terminal set.
    * **Irreversible gate** — `irreversible_executed?/1` scans a run's durable
      `WorkflowEvent` log: if any `step_*` event payload was stamped
      `irreversible: true`, re-running would repeat an un-undoable side effect.
      `step_started` counts (the side effect may have fired even if the step
      never completed).
  """

  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection

  # Event kinds proving a step *executed* (started counts: an irreversible
  # side effect may have fired even if the step never completed).
  @irreversible_kinds [:step_started, :step_completed, :step_failed]

  @doc """
  Whether `status` is terminal (the run can no longer make progress).
  Delegates to `WorkflowEvent.Projection`, the single source of the terminal set.
  """
  @spec terminal_status?(term()) :: boolean()
  def terminal_status?(status), do: Projection.terminal_status?(status)

  @doc """
  Whether any of `events` proves an `irreversible: true` step executed.
  """
  @spec irreversible_executed?([WorkflowEvent.t()]) :: boolean()
  def irreversible_executed?(events) when is_list(events) do
    Enum.any?(events, &irreversible_step?/1)
  end

  # The middleware stamps `irreversible: true` into `step_*` payloads
  # (string-keyed jsonb on read).
  defp irreversible_step?(%WorkflowEvent{kind: kind, payload: payload})
       when kind in @irreversible_kinds and is_map(payload),
       do: payload["irreversible"] == true

  defp irreversible_step?(_event), do: false
end
