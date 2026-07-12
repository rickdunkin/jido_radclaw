defmodule JidoClaw.Forge.ResumeSignalTest do
  @moduledoc """
  The loud resume-failure channel: bounded + redacted reason, whitelist
  payload, PubSub delivery keyed on the Forge session id, total emission
  (docs/system/forge-session-resume.md).
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Forge.ResumeSignal

  test "delivers {:resume_failed, payload} on the session PubSub with a bounded, redacted reason" do
    sid = "resume_signal_#{:erlang.unique_integer([:positive])}"
    :ok = ForgePubSub.subscribe(sid)

    ResumeSignal.emit_failed(:agent_session_poisoned, %{
      reason: "resume rejected using sk-ant-aaaabbbbccccddddeeeeffff for auth",
      session_id: sid,
      anchor_id: "anchor-1",
      mode: :continuation,
      runner: :claude_code,
      resume_rejected: true
    })

    assert_receive {:resume_failed, payload}

    assert payload.kind == :agent_session_poisoned
    assert payload.session_id == sid
    assert payload.anchor_id == "anchor-1"
    assert payload.mode == :continuation
    assert payload.runner == :claude_code
    assert payload.resume_rejected == true

    # Bounded (format_reason prefix) + redaction-passed before egress.
    assert payload.reason =~ "agent_session_poisoned:"
    assert payload.reason =~ "[REDACTED:ANTHROPIC_KEY]"
    refute payload.reason =~ "aaaabbbbccccddddeeeeffff"
  end

  test "free-form detail keys never ride the payload (whitelist-shaped)" do
    sid = "resume_signal_#{:erlang.unique_integer([:positive])}"
    :ok = ForgePubSub.subscribe(sid)

    ResumeSignal.emit_failed(:agent_fallback_message, %{
      reason: {:fallback_marker, "short marker"},
      session_id: sid,
      smuggled: "never",
      output: "never either"
    })

    assert_receive {:resume_failed, payload}

    refute Map.has_key?(payload, :smuggled)
    refute Map.has_key?(payload, :output)
    assert payload.reason =~ "fallback_marker"
  end

  test "no session id → no PubSub delivery, still :ok (signal + log only)" do
    sid = "resume_signal_#{:erlang.unique_integer([:positive])}"
    :ok = ForgePubSub.subscribe(sid)

    assert :ok = ResumeSignal.emit_failed(:agent_unknown, %{reason: "verify mismatch"})

    refute_receive {:resume_failed, _}, 100
  end

  test "a hostile reason term still emits (bounded rendering is total)" do
    sid = "resume_signal_#{:erlang.unique_integer([:positive])}"
    :ok = ForgePubSub.subscribe(sid)

    assert :ok =
             ResumeSignal.emit_failed(:agent_unknown, %{
               reason: %{__struct__: Range},
               session_id: sid
             })

    assert_receive {:resume_failed, payload}
    assert is_binary(payload.reason)
  end
end
