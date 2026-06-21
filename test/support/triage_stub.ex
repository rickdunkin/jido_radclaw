defmodule JidoClaw.Test.TriageStub do
  @moduledoc """
  Test impl of the `JidoClaw.Triage` behaviour — makes the entire front door
  deterministically testable without a real LLM (Alp River's philosophy: the LLM
  judgment is untestable; the *contract* and the *routing decision* are what we
  assert).

  The canned verdict comes from `config :jido_claw, :triage_canned_verdict` and
  may be:

    * a `%Verdict{}` (or `{:ok, %Verdict{}}`) — returned verbatim,
    * a path atom (`:talk` / `:sketch` / `:code` / `:system`) — wrapped in a
      minimal verdict,
    * an `{:error, reason}` — returned as-is, to exercise the façade's fail-safe,
    * a `fun/1` taking the message and returning any of the above — for per-message
      verdicts (e.g. a stickiness test: `talk` on turn 1, `:code` on `"do it"`),
    * absent — defaults to `:talk` (so chat-path tests that don't care about triage
      keep their inline behavior unchanged).

  When `config :jido_claw, :triage_capture` is a pid, every call sends
  `{:triage_classify, message, opts}` to it (so a test can assert the history
  window passed to triage).
  """

  @behaviour JidoClaw.Triage

  alias JidoClaw.Triage.Verdict

  @impl JidoClaw.Triage
  def classify(message, opts) when is_binary(message) do
    maybe_capture(message, opts)
    resolve(Application.get_env(:jido_claw, :triage_canned_verdict, :talk), message)
  end

  defp resolve(fun, message) when is_function(fun, 1), do: resolve(fun.(message), message)
  defp resolve(%Verdict{} = verdict, _message), do: {:ok, verdict}
  defp resolve({:ok, %Verdict{}} = ok, _message), do: ok
  defp resolve({:error, _reason} = err, _message), do: err

  defp resolve(path, _message) when path in [:talk, :sketch, :code, :system],
    do: {:ok, %Verdict{path: path}}

  defp resolve(_other, _message), do: {:ok, Verdict.talk()}

  defp maybe_capture(message, opts) do
    case Application.get_env(:jido_claw, :triage_capture) do
      pid when is_pid(pid) -> send(pid, {:triage_classify, message, opts})
      _other -> :ok
    end
  end
end
