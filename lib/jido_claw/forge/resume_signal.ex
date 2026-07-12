defmodule JidoClaw.Forge.ResumeSignal do
  @moduledoc """
  The LOUD resume-failure channel (docs/system/forge-session-resume.md): a
  resume-relevant failure — a poisoned anchor, a rejected resume, an
  id-verify mismatch, a fallback marker — is emitted on the SignalBus
  (`jido_claw.forge.resume.failed`), the Forge session PubSub
  (`{:resume_failed, details}`), and the log, BEFORE any driver retry
  decision executes. A resume failure is never a silent fallback.

  The reason is bounded (`RunFailure.format_reason/2`) and redaction-passed
  before it reaches either bus; the payload is whitelist-shaped so nothing
  free-form rides the buses.
  """

  require Logger

  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Orchestration.RunFailure
  alias JidoClaw.Security.Redaction.Patterns

  @signal "jido_claw.forge.resume.failed"
  @degraded_signal "jido_claw.forge.recovery.degraded"
  @reparked_signal "jido_claw.forge.resume.guidance_reparked"

  @detail_keys [:session_id, :anchor_id, :mode, :runner, :resume_rejected]

  @doc "The SignalBus type emitted for every resume failure."
  @spec signal_type() :: String.t()
  def signal_type, do: @signal

  @doc "The SignalBus type emitted when a session's recovery goes degraded."
  @spec degraded_signal_type() :: String.t()
  def degraded_signal_type, do: @degraded_signal

  @doc "The SignalBus type emitted when recovery re-parks operator guidance."
  @spec reparked_signal_type() :: String.t()
  def reparked_signal_type, do: @reparked_signal

  @doc """
  Emit the resume failure on every channel. `details` may carry `:reason`
  (any term — bounded + redacted before egress) plus `:session_id` (the
  Forge session; PubSub is skipped without one), `:anchor_id`, `:mode`,
  `:runner`, and `:resume_rejected`. Total and best-effort: emission never
  raises into a runner's terminal path.
  """
  @spec emit_failed(RunFailure.kind(), map()) :: :ok
  def emit_failed(kind, details) when is_map(details) do
    reason = bounded_reason(kind, Map.get(details, :reason))

    payload =
      details
      |> Map.take(@detail_keys)
      |> Map.put(:kind, kind)
      |> Map.put(:reason, reason)

    Logger.warning("[Forge.ResumeSignal] resume failure: #{reason}")
    JidoClaw.SignalBus.emit(@signal, payload)

    case Map.get(details, :session_id) do
      session_id when is_binary(session_id) ->
        ForgePubSub.broadcast(session_id, {:resume_failed, payload})

      _no_session ->
        :ok
    end

    :ok
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.ResumeSignal] emit failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Emit the recovery-degraded marker's loud channel (a failed checked initial
  checkpoint — the session runs, but its durable recovery data is honestly
  stale until the next successful checked save self-heals it). `details`
  carries `:session_id` (PubSub skipped without one) and `:reason` (any term
  — bounded + redacted). Total and best-effort, like `emit_failed/2`.
  """
  @spec emit_recovery_degraded(map()) :: :ok
  def emit_recovery_degraded(details) when is_map(details) do
    reason = bounded_degraded_reason(Map.get(details, :reason))

    payload =
      details
      |> Map.take([:session_id])
      |> Map.put(:reason, reason)

    Logger.warning("[Forge.ResumeSignal] recovery degraded: #{reason}")
    JidoClaw.SignalBus.emit(@degraded_signal, payload)

    case Map.get(details, :session_id) do
      session_id when is_binary(session_id) ->
        ForgePubSub.broadcast(session_id, {:recovery_degraded, payload})

      _no_session ->
        :ok
    end

    :ok
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.ResumeSignal] degraded emit failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Emit the guidance-reparked marker's loud channel (recovery could not
  restore a parked operator answer safely — the session parked
  `:needs_input` with the durable `repark_reason` and awaits a re-entered
  answer). `details` carries `:session_id` (PubSub skipped without one)
  and `:reason` (one of the whitelisted `ResumeState.repark_reason/0`
  atoms). Total and best-effort, like `emit_failed/2`.
  """
  @spec emit_guidance_reparked(map()) :: :ok
  def emit_guidance_reparked(details) when is_map(details) do
    reason = Map.get(details, :reason)

    payload =
      details
      |> Map.take([:session_id])
      |> Map.put(:reason, reason)

    Logger.warning("[Forge.ResumeSignal] guidance re-parked: #{inspect(reason)}")
    JidoClaw.SignalBus.emit(@reparked_signal, payload)

    case Map.get(details, :session_id) do
      session_id when is_binary(session_id) ->
        ForgePubSub.broadcast(session_id, {:resume_guidance_reparked, payload})

      _no_session ->
        :ok
    end

    :ok
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.ResumeSignal] reparked emit failed: #{inspect(e)}")
      :ok
  end

  defp bounded_reason(kind, raw), do: Patterns.redact(RunFailure.format_reason(kind, raw))

  # No taxonomy kind rides the degraded marker — bound + redact the raw term
  # directly (`format_reason/2` needs a kind; degraded is infrastructure, not
  # a run failure).
  defp bounded_degraded_reason(raw) when is_binary(raw), do: bounded_slice(raw)

  defp bounded_degraded_reason(raw),
    do: bounded_slice(inspect(raw, limit: 5, printable_limit: 120))

  defp bounded_slice(text), do: Patterns.redact(String.slice(text, 0, 240))
end
