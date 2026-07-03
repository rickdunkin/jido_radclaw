defmodule JidoClaw.Test.PassStub do
  @moduledoc false

  # Variant of `JidoClaw.Test.EchoStub` whose `ask_sync/3` returns a passing
  # verdict, so an iterative skill's evaluator stops the gen/eval loop early.
  # Like EchoStub, it forwards the supplied `tool_context` to the configured
  # target so tests can `assert_receive` against per-step scope.
  use Jido.Agent,
    name: "pass_stub",
    description: "Test-only stub that returns VERDICT: PASS"

  alias JidoClaw.Test.TerminalSignal

  @spec ask_sync(term(), term(), keyword()) :: {:ok, map()}
  def ask_sync(_pid, _query, opts) when is_list(opts) do
    target = Application.get_env(:jido_claw, :echo_stub_target, self())
    send(target, {:echo_stub, :tool_context, Keyword.get(opts, :tool_context)})
    TerminalSignal.emit_completed(Keyword.get(opts, :request_id))
    {:ok, %{last_answer: "Looks good. VERDICT: PASS"}}
  end
end
