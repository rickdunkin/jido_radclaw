defmodule JidoClaw.Test.MCPFacadeCapture do
  @moduledoc """
  Test double for the `JidoClaw.MCP` facade (the `:mcp_facade` call-site seam).

  Records each `ensure_attached/3` call by messaging the pid configured in
  `:mcp_facade_capture_target`, then returns `:skipped` — the exact result the
  real facade yields when no Consumer is running — so the call site's
  orchestration proceeds identically to production with prep off. Lets a
  call-site test assert the *right pid/template* is attached without standing up
  a Consumer.

  Drive it from `async: false` tests that `put_env`/restore in setup.
  """

  @spec ensure_attached(pid(), term(), timeout()) :: :skipped
  def ensure_attached(pid, template, timeout) do
    case Application.get_env(:jido_claw, :mcp_facade_capture_target) do
      target when is_pid(target) ->
        send(target, {:mcp_ensure_attached, pid, template, timeout})

      _absent ->
        :ok
    end

    :skipped
  end

  # `attach_to_agent/2` is unchanged in production; a passthrough double keeps a
  # test that swaps the whole facade from breaking the REPL-boot path.
  @spec attach_to_agent(pid(), String.t()) :: :skipped
  def attach_to_agent(_pid, _template), do: :skipped
end
