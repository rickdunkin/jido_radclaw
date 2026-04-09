defmodule JidoClaw.Forge.Error do
  defmodule ProvisionError do
    defexception [:message, :session_id, :reason]
    @impl true
    def message(%{message: msg}), do: msg
  end

  defmodule BootstrapError do
    defexception [:message, :session_id, :step, :reason]
    @impl true
    def message(%{message: msg}), do: msg
  end

  defmodule ExecSessionError do
    defexception [:message, :session_id, :command, :exit_code, :reason]
    @impl true
    def message(%{message: msg}), do: msg
  end

  defmodule TimeoutError do
    defexception [:message, :session_id, :phase, :timeout_ms]
    @impl true
    def message(%{message: msg}), do: msg
  end

  defmodule SandboxError do
    defexception [:message, :session_id, :operation, :reason]
    @impl true
    def message(%{message: msg}), do: msg
  end

  @spec classify(Exception.t()) :: {atom(), atom()}
  def classify(%ProvisionError{}), do: {:provision_failed, :terminal}
  def classify(%BootstrapError{}), do: {:bootstrap_failed, :terminal}
  def classify(%ExecSessionError{reason: :rate_limited}), do: {:exec_failed, :retry}
  def classify(%ExecSessionError{}), do: {:exec_failed, :checkpoint_restore}
  def classify(%TimeoutError{}), do: {:timeout, :retry}
  def classify(%SandboxError{}), do: {:exec_failed, :checkpoint_restore}
  def classify(_), do: {:unknown, :terminal}
end
