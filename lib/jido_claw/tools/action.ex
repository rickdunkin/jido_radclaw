defmodule JidoClaw.Tools.Action do
  @moduledoc """
  Shared `Jido.Action` wrapper for host-facing tools.

  Tool output is model input on the next turn. This wrapper keeps the
  redaction boundary in one place so individual tools cannot forget to
  scrub successful results or error payloads before Jido formats them for
  the LLM.
  """

  defmacro __using__(opts) do
    tool_name = Keyword.fetch!(opts, :name)

    quote location: :keep do
      use Jido.Action, unquote(opts)

      @jidoclaw_tool_name unquote(tool_name)
      @before_compile JidoClaw.Tools.Action

      @doc "Returns true when this action uses the shared JidoClaw tool output wrapper."
      def __jidoclaw_tool_output_redacted__, do: true

      @doc "Returns true when this action uses the shared JidoClaw MCP scope wrapper."
      def __jidoclaw_tool_mcp_scoped__, do: true

      @doc "Returns true when this action routes through the shared tool-approval gate."
      def __jidoclaw_tool_approval_gated__, do: true
    end
  end

  defmacro __before_compile__(_env) do
    quote location: :keep do
      defoverridable run: 2
      alias JidoClaw.Agent.LoopGuard
      alias JidoClaw.Security.ToolApproval
      alias JidoClaw.Tools.Error
      alias JidoClaw.Tools.MCPScope
      alias JidoClaw.Tools.OutputLimit
      alias JidoClaw.Tools.OutputRedaction
      alias JidoClaw.Tools.OutputShaper

      # Ordering is load-bearing: gate (approve before side effects) → loop
      # guard (block a doomed call pre-execution; an approval-blocked call is
      # not an execution, so the gate stays first) → redact (must see the full
      # original) → shape (semantic compression) → cap (dumb backstop).
      # `ensure_nested/1` lifts the live ReAct path's flat scope under
      # `:tool_context` so the gate, LoopGuard, OutputShaper, and tools read
      # one shape; MCP default-injection still applies inside `MCPScope.wrap/4`
      # when nothing lifts. The gate's `{:error, approval_*}` arm and the
      # guard's `{:error, doom_loop}` arm flow through the SAME
      # normalize/redact/shape/cap tail as the tool's own result, so a
      # pending/denied/halted envelope reaches the LLM identically formatted.
      # `LoopGuard.observe_result/4` sits after normalize (it reads the
      # canonical `%{code, message, details}` shape; normalize is idempotent
      # for it) and before redaction (an appended recovery directive is our
      # own text; the underlying message is still redacted after); its
      # skip-list ignores approval/doom envelopes — non-executions must not
      # count in the guard's windows.
      @impl Jido.Action
      def run(params, context) do
        enriched = JidoClaw.ToolContext.ensure_nested(context || %{})

        MCPScope.wrap(@jidoclaw_tool_name, params, enriched, fn enriched_context ->
          gated =
            with :ok <- ToolApproval.gate(@jidoclaw_tool_name, params, enriched_context),
                 :ok <- LoopGuard.check(@jidoclaw_tool_name, params, enriched_context) do
              super(params, enriched_context)
            else
              {:error, _approval} = gate_error -> gate_error
              {:halt, halt_error} -> halt_error
            end

          gated
          |> Error.normalize_result()
          |> LoopGuard.observe_result(@jidoclaw_tool_name, params, enriched_context)
          |> OutputRedaction.redact_result()
          |> OutputShaper.shape_result(@jidoclaw_tool_name, params, enriched_context)
          |> OutputLimit.truncate_result()
        end)
      end
    end
  end
end
