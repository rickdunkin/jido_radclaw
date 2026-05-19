defmodule JidoClaw.Forge.Error do
  @moduledoc """
  Forge-specific error leaves, Splode-registered under
  `JidoClaw.Error`'s `:execution` class.

  All five forge errors are runtime failures and land on the `:execution`
  class; none are configuration errors. `classify/1` keeps its `{kind,
  recovery}` return shape — `hermes` T1-4's `FailoverReason` composes on
  top of this layer later.
  """

  defmodule ProvisionError do
    @moduledoc "Sandbox provision failed (terminal — cannot retry without operator intervention)."
    use Splode.Error,
      class: :execution,
      fields: [:message, :session_id, :reason]
  end

  defmodule BootstrapError do
    @moduledoc "Sandbox bootstrap step failed (terminal)."
    use Splode.Error,
      class: :execution,
      fields: [:message, :session_id, :step, :reason]
  end

  defmodule ExecSessionError do
    @moduledoc "Sandbox exec failed (retry on rate-limit, checkpoint-restore otherwise)."
    use Splode.Error,
      class: :execution,
      fields: [:message, :session_id, :command, :exit_code, :reason]
  end

  defmodule TimeoutError do
    @moduledoc "Sandbox operation timed out (retry)."
    use Splode.Error,
      class: :execution,
      fields: [:message, :session_id, :phase, :timeout_ms]
  end

  defmodule SandboxError do
    @moduledoc "Sandbox infrastructure failure (checkpoint-restore)."
    use Splode.Error,
      class: :execution,
      fields: [:message, :session_id, :operation, :reason]
  end

  @spec classify(Exception.t()) :: {atom(), atom()}
  def classify(%ProvisionError{}), do: {:provision_failed, :terminal}
  def classify(%BootstrapError{}), do: {:bootstrap_failed, :terminal}
  def classify(%ExecSessionError{reason: :rate_limited}), do: {:exec_failed, :retry}
  def classify(%ExecSessionError{}), do: {:exec_failed, :checkpoint_restore}
  def classify(%TimeoutError{}), do: {:timeout, :retry}
  def classify(%SandboxError{}), do: {:exec_failed, :checkpoint_restore}

  # Splode-form ExecutionError dispatch — for callers that have migrated to
  # the structured contract via Normalize but still want a Forge-shaped
  # classification.
  def classify(%JidoClaw.Error.ExecutionError{phase: :provision}),
    do: {:provision_failed, :terminal}

  def classify(%JidoClaw.Error.ExecutionError{phase: :bootstrap}),
    do: {:bootstrap_failed, :terminal}

  def classify(%JidoClaw.Error.ExecutionError{phase: :timeout}), do: {:timeout, :retry}
  def classify(_), do: {:unknown, :terminal}
end
