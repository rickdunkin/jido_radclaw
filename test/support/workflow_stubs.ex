defmodule JidoClaw.Test.ErrorStub do
  @moduledoc false

  # Jido.Agent stub whose `ask_sync/3` returns an error, so a skill step driven
  # by it fails (and the run fails). Sends `{:stub_invoked, :error}` to the
  # configured `:echo_stub_target` so a test can confirm it ran exactly once
  # (pinning `max_retries: 0`).
  use Jido.Agent,
    name: "error_stub",
    description: "Test-only stub whose ask_sync returns an error"

  def ask_sync(_pid, _query, opts) when is_list(opts) do
    send(Application.get_env(:jido_claw, :echo_stub_target, self()), {:stub_invoked, :error})
    {:error, :boom}
  end
end

defmodule JidoClaw.Test.CrashStub do
  @moduledoc false

  # Jido.Agent stub whose `ask_sync/3` raises, exercising AgentRunner's
  # never-crash boundary (the raise becomes a step `{:error, _}`, not an escaped
  # exception). Also sends `{:stub_invoked, :crash}` before raising.
  use Jido.Agent,
    name: "crash_stub",
    description: "Test-only stub whose ask_sync raises"

  # ask_sync always raises (by design — it exercises AgentRunner's rescue), so
  # dialyzer infers `no_return`; that's intentional for this stub.
  @dialyzer {:nowarn_function, ask_sync: 3}

  def ask_sync(_pid, _query, opts) when is_list(opts) do
    send(Application.get_env(:jido_claw, :echo_stub_target, self()), {:stub_invoked, :crash})
    raise "kaboom"
  end
end
