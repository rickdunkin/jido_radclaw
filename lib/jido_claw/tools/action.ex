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
    end
  end

  defmacro __before_compile__(_env) do
    quote location: :keep do
      defoverridable run: 2
      alias JidoClaw.Tools.Error
      alias JidoClaw.Tools.MCPScope
      alias JidoClaw.Tools.OutputLimit
      alias JidoClaw.Tools.OutputRedaction
      alias JidoClaw.Tools.OutputShaper

      # Ordering is load-bearing: redact (must see the full original) →
      # shape (semantic compression) → cap (dumb backstop).
      @impl Jido.Action
      def run(params, context) do
        MCPScope.wrap(@jidoclaw_tool_name, params, context, fn enriched_context ->
          super(params, enriched_context)
          |> Error.normalize_result()
          |> OutputRedaction.redact_result()
          |> OutputShaper.shape_result(@jidoclaw_tool_name, params, enriched_context)
          |> OutputLimit.truncate_result()
        end)
      end
    end
  end
end
