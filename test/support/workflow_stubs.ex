defmodule JidoClaw.Test.ErrorStub do
  @moduledoc false

  # Jido.Agent stub whose `ask_sync/3` returns an error, so a skill step driven
  # by it fails (and the run fails). Sends `{:stub_invoked, :error}` to the
  # configured `:echo_stub_target` so a test can confirm it ran exactly once
  # (pinning `max_retries: 0`).
  use Jido.Agent,
    name: "error_stub",
    description: "Test-only stub whose ask_sync returns an error"

  alias JidoClaw.Test.TerminalSignal

  @spec ask_sync(pid(), term(), keyword()) :: {:error, :boom}
  def ask_sync(_pid, _query, opts) when is_list(opts) do
    send(Application.get_env(:jido_claw, :echo_stub_target, self()), {:stub_invoked, :error})
    TerminalSignal.emit_failed(Keyword.get(opts, :request_id))
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

  alias JidoClaw.Test.TerminalSignal

  # ask_sync always raises (by design — it exercises AgentRunner's rescue), so
  # dialyzer infers `no_return`; that's intentional for this stub.
  @dialyzer {:nowarn_function, ask_sync: 3}

  @spec ask_sync(pid(), term(), keyword()) :: no_return()
  def ask_sync(_pid, _query, opts) when is_list(opts) do
    send(Application.get_env(:jido_claw, :echo_stub_target, self()), {:stub_invoked, :crash})
    # Emit before raising — the flush happens in AgentRunner's rescue path.
    TerminalSignal.emit_failed(Keyword.get(opts, :request_id))
    raise "kaboom"
  end
end

defmodule JidoClaw.Test.SecretErrorStub do
  @moduledoc false

  # Jido.Agent stub whose `ask_sync/3` errors with a secret-shaped string
  # embedded in the message — drives the T2-2 security pins that no MCP
  # surface ever emits an unredacted run/step error. (`WorkflowRun.error`
  # stores the RAW reason — only the event payload is redacted at append —
  # so read-side `Visibility` scrubbing is what these pins exercise.)
  use Jido.Agent,
    name: "secret_error_stub",
    description: "Test-only stub whose ask_sync errors with a secret in the message"

  alias JidoClaw.Test.TerminalSignal

  @spec secret() :: String.t()
  def secret, do: "sk-" <> String.duplicate("a", 24)

  @spec ask_sync(pid(), term(), keyword()) :: {:error, String.t()}
  def ask_sync(_pid, _query, opts) when is_list(opts) do
    send(Application.get_env(:jido_claw, :echo_stub_target, self()), {:stub_invoked, :secret})
    TerminalSignal.emit_failed(Keyword.get(opts, :request_id))
    {:error, "auth failed for key #{secret()}"}
  end
end

defmodule JidoClaw.Test.FlakyStub do
  @moduledoc false

  # Jido.Agent stub that fails the first
  # `:flaky_stub_failures_remaining` invocations and then succeeds —
  # exercising the per-step `retry:` policy end-to-end (a real
  # compensate-driven retry followed by a recovery, not just the
  # max_retries plumbing). Sends `{:stub_invoked, :flaky_fail}` /
  # `{:stub_invoked, :flaky_ok}` so a test can count the attempts.
  #
  # The countdown lives in app env (single-step, `async: false` tests only —
  # not safe under concurrent flaky steps).
  use Jido.Agent,
    name: "flaky_stub",
    description: "Test-only stub that fails N times then echoes"

  alias JidoClaw.Test.TerminalSignal

  @spec ask_sync(pid(), term(), keyword()) :: {:ok, map()} | {:error, :flaky}
  def ask_sync(_pid, _query, opts) when is_list(opts) do
    target = Application.get_env(:jido_claw, :echo_stub_target, self())
    remaining = Application.get_env(:jido_claw, :flaky_stub_failures_remaining, 0)
    request_id = Keyword.get(opts, :request_id)

    if remaining > 0 do
      Application.put_env(:jido_claw, :flaky_stub_failures_remaining, remaining - 1)
      send(target, {:stub_invoked, :flaky_fail})
      TerminalSignal.emit_failed(request_id)
      {:error, :flaky}
    else
      send(target, {:stub_invoked, :flaky_ok})
      TerminalSignal.emit_completed(request_id)
      {:ok, %{last_answer: "recovered"}}
    end
  end
end
