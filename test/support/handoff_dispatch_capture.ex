defmodule JidoClaw.Test.HandoffDispatchCapture do
  @moduledoc false

  # Test-only `ask_runtime` substitute for the handoff dispatcher
  # integration test. Captures the `(pid, query, opts)` triple supplied
  # by `JidoClaw.run_chat_turn/8` and forwards it to the configured
  # target process so the test can `assert_receive` against it. Returns
  # whatever `:dispatch_capture_response` is configured to (defaults to
  # `{:ok, "captured"}`) so the failure-path test can flip to
  # `{:error, :timeout}` and assert that the dispatcher leaves
  # `preamble_consumed?` alone.
  def ask_sync(pid, query, opts) when is_list(opts) do
    target = Application.get_env(:jido_claw, :dispatch_capture_target, self())
    response = Application.get_env(:jido_claw, :dispatch_capture_response, {:ok, "captured"})
    send(target, {:dispatch_capture, pid, query, opts})
    response
  end
end
