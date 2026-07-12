defmodule JidoClaw.Forge.Runners.ResumePolicy do
  @moduledoc false
  # Shared armed-failure policy for the vendor runners
  # (docs/system/forge-session-resume.md): classify ONCE in-runner, poison
  # the anchor on a resume-unsafe kind, tag `resume_rejected: true` when a
  # continuation is rejected by the recognized invalid-anchor class (the
  # driver's ledger-gated retry reads it — runners NEVER auto-retry), turn
  # an unrecognized short bare marker into `{:fallback_marker, _}`, and emit
  # the loud ResumeSignal BEFORE the attempt returns. One module so the two
  # runners' policies cannot drift.

  alias JidoClaw.Forge.{ResumeSignal, ResumeState, Runner}
  alias JidoClaw.Orchestration.RunFailure

  # The floor for a continuation turn with neither parked guidance nor a
  # caller `:guidance` opt: a neutral nudge, NEVER `state.prompt` — the
  # original task already lives in the resumed conversation and must not
  # ride the argv twice (CM2-3).
  @continuation_nudge "Continue."

  @doc """
  The one guidance source for an armed CONTINUATION turn: parked inflight
  text first (consumed AT TAKE — the answer rides exactly one argv and is
  never resent, even if the turn then errors or times out; the anchor
  survives a `stalled_wall_clock`, and consuming prevents a double-send),
  then the caller's `:guidance` opt, then the neutral nudge. `:prompt` is
  NEVER read here — continuation guidance rides the semantically-tagged
  `:guidance` opt only, so even a confused caller passing `prompt: task`
  to an anchored session cannot put the task on a continuation argv.
  """
  @spec take_continuation_guidance(ResumeState.t(), keyword()) :: {String.t(), ResumeState.t()}
  def take_continuation_guidance(rs, opts) do
    case ResumeState.inflight_text(rs) do
      nil -> {Keyword.get(opts, :guidance) || @continuation_nudge, rs}
      text -> {text, ResumeState.guidance_consumed(rs)}
    end
  end

  @doc """
  Build the `{:ok, iteration_result}` for an armed terminal failure. The
  classified kind rides `metadata.error_details`; the (possibly poisoned)
  resume state rides `metadata.state` so it reaches harness state on every
  terminal — error and timeout included.

  `labeling` is `{:known, label}` for failures whose class is decided by
  the arm itself (timeout, missing executable — partial output must not
  sway it) or `{:classify, label}` to classify the OUTPUT first (the
  recognized rejection/provider strings), then the fallback-marker
  heuristic, then the label.
  """
  @spec armed_failure(
          atom(),
          {:known | :classify, String.t()},
          String.t(),
          map(),
          ResumeState.t(),
          :fresh_armed | :continuation,
          keyword()
        ) :: {:ok, Runner.iteration_result()}
  def armed_failure(runner, labeling, output, state, rs, mode, opts) do
    {error_term, kind} = classify_armed_failure(labeling, output)
    {final_rs, extra} = apply_resume_policy(rs, kind, mode)

    if resume_relevant?(kind, rs, final_rs, extra) do
      ResumeSignal.emit_failed(kind, %{
        reason: error_term,
        session_id: Keyword.get(opts, :forge_session_id),
        anchor_id: rs.session_id,
        mode: mode,
        runner: runner,
        resume_rejected: Map.get(extra, :resume_rejected, false)
      })
    end

    base = Runner.error(error_term, output)

    result = %{
      base
      | metadata: Map.put(base.metadata, :error_details, RunFailure.error_details(kind, extra))
    }

    {:ok, attach_runner_state(result, state, final_rs)}
  end

  @doc """
  Thread the updated resume state back through `metadata.state` — the only
  channel the harness merges runner state from.
  """
  @spec attach_runner_state(Runner.iteration_result(), map(), ResumeState.t()) ::
          Runner.iteration_result()
  def attach_runner_state(result, state, rs) do
    new_runner_state =
      state
      |> Map.put(:resume, rs)
      |> Map.update(:iteration, 1, &(&1 + 1))

    %{result | metadata: Map.put(result.metadata, :state, new_runner_state)}
  end

  @doc """
  The anchor id-verify mismatch emission (claude's `"system"` echo, codex's
  `thread.started` echo): one constructor so the whitelist payload shape has
  exactly one producer across both runners. The kind is `:agent_unknown` —
  a silent id swap is not a recognized provider failure class.
  """
  @spec emit_anchor_mismatch(
          atom(),
          :fresh_armed | :continuation,
          String.t(),
          String.t(),
          keyword()
        ) ::
          :ok
  def emit_anchor_mismatch(runner, mode, anchor_id, reason, opts) do
    ResumeSignal.emit_failed(:agent_unknown, %{
      reason: reason,
      session_id: Keyword.get(opts, :forge_session_id),
      anchor_id: anchor_id,
      mode: mode,
      runner: runner
    })
  end

  @doc """
  The shared checkpoint codec, dynamic state only — {iteration, sanitized
  resume state} under the canonical `["resume"]["state"]` path both the
  recovery epoch check and the harness select read. Static config is NOT
  here: it recovers through the persisted materialized config
  (`RecoveredSpec.runner_config/1`), never a snapshot.
  """
  @spec serialize_state(map()) :: map()
  def serialize_state(state) do
    base = %{"iteration" => Map.get(state, :iteration, 0)}

    case Map.get(state, :resume) do
      %ResumeState{} = rs ->
        Map.put(base, "resume", %{"state" => ResumeState.encode_state(rs)})

      _off ->
        base
    end
  end

  @doc """
  Overlay a checkpoint snapshot onto a freshly-initialized runner state.
  Arming is CONFIG-owned: a snapshot anchor never re-arms a resume-off
  session, and a garbled copy decodes to absent (the fresh armed state)
  rather than a guess. The fresh init's workdir stays the cwd-gate input,
  so a recovered anchor from a different workdir resolves fresh-armed on
  the next turn.
  """
  @spec restore_state(map(), term()) :: {:ok, map()}
  def restore_state(state, snapshot) when is_map(snapshot) do
    iteration =
      case Map.get(snapshot, "iteration") do
        n when is_integer(n) and n >= 0 -> n
        _ -> Map.get(state, :iteration, 0)
      end

    {:ok,
     state
     |> Map.put(:iteration, iteration)
     |> restore_resume(get_in(snapshot, ["resume", "state"]))}
  end

  def restore_state(state, _snapshot), do: {:ok, state}

  defp restore_resume(state, encoded) do
    with %ResumeState{} <- Map.get(state, :resume),
         {:ok, rs} <- ResumeState.decode_state(encoded) do
      Map.put(state, :resume, rs)
    else
      _ -> state
    end
  end

  defp classify_armed_failure({:known, label}, _output),
    do: {label, RunFailure.classify(label)}

  defp classify_armed_failure({:classify, label}, output) do
    case RunFailure.classify(output) do
      :agent_unknown ->
        if RunFailure.fallback_marker?(output) do
          {{:fallback_marker, String.trim(output)}, :agent_fallback_message}
        else
          {label, RunFailure.classify(label)}
        end

      recognized ->
        {bounded_error_line(output), recognized}
    end
  end

  # The human-facing error slice: the first non-JSON line (vendor CLIs print
  # the bare error text before/without their JSON result line), bounded.
  defp bounded_error_line(output) do
    lines = String.split(output, "\n", trim: true)
    line = Enum.find(lines, &(not String.starts_with?(&1, "{"))) || List.first(lines) || ""
    String.slice(String.trim(line), 0, 240)
  end

  defp apply_resume_policy(rs, kind, mode) do
    extra =
      if kind == :agent_session_poisoned and mode == :continuation,
        do: %{resume_rejected: true},
        else: %{}

    final_rs =
      if RunFailure.resume_unsafe?(kind) and is_binary(rs.session_id),
        do: ResumeState.poison(rs),
        else: rs

    {final_rs, extra}
  end

  defp resume_relevant?(kind, rs, final_rs, extra) do
    (final_rs.status == :poisoned and rs.status != :poisoned) or
      Map.get(extra, :resume_rejected, false) or
      kind == :agent_fallback_message
  end
end
