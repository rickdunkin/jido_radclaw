defmodule JidoClaw.Test.FailStub do
  @moduledoc false

  # Variant of `JidoClaw.Test.PassStub` whose verdict is an explicit
  # `VERDICT: FAIL` — a REAL failing verdict under the camus C1-3 normalizer
  # contract. (EchoStub's tokenless "echoed" is an *infra* input there, so the
  # iterative loop's cap-out test needs a stub that genuinely fails.)
  use Jido.Agent,
    name: "fail_stub",
    description: "Test-only stub that returns VERDICT: FAIL"

  alias JidoClaw.Test.TerminalSignal

  @spec ask_sync(term(), term(), keyword()) :: {:ok, map()}
  def ask_sync(_pid, _query, opts) when is_list(opts) do
    target = Application.get_env(:jido_claw, :echo_stub_target, self())
    send(target, {:echo_stub, :tool_context, Keyword.get(opts, :tool_context)})
    TerminalSignal.emit_completed(Keyword.get(opts, :request_id))
    {:ok, %{last_answer: "Found issues. VERDICT: FAIL"}}
  end
end
