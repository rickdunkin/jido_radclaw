defmodule JidoClaw.Tools.OutputRedactionTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.OutputRedaction

  defmodule SecretEcho do
    use JidoClaw.Tools.Action,
      name: "secret_echo_for_output_redaction_test",
      description: "Test-only action that returns secret-shaped output.",
      schema: []

    @impl Jido.Action
    def run(_params, _context) do
      {:ok,
       %{
         content: "model returned sk-abcdefghijklmnopqrstuvwxyz01",
         nested: ["Authorization: Bearer abcdef0123456789abcdef"],
         api_key: "not-patterned-but-sensitive-key",
         base64: "iVBORw0KGgoAAAANSUhEUgAAAAUA"
       }}
    end
  end

  defmodule ErrorEcho do
    use JidoClaw.Tools.Action,
      name: "error_echo_for_output_redaction_test",
      description: "Test-only action that returns inconsistent error shapes.",
      schema: []

    @impl Jido.Action
    def run(%{shape: :string}, _context),
      do: {:error, "token sk-abcdefghijklmnopqrstuvwxyz01 leaked"}

    def run(%{shape: :atom}, _context), do: {:error, :id_or_label_required}
    def run(%{shape: :tuple}, _context), do: {:error, {:source_not_invalidatable, "memory://x"}}
    def run(%{shape: :failed_ok}, _context), do: {:ok, %{status: :failed, error: :tool_failed}}
  end

  describe "ANSI hardening (root strip before redaction)" do
    test "reassembles and redacts an ANSI-split secret value" do
      # The escape splits the key so a raw pattern scan would miss it; the
      # upstream strip reassembles the 24-char tail (clears the 20-char min).
      split = "sk-ant-\e[0mabcdefghijklmnopqrstuvwx"

      assert OutputRedaction.redact(split) == "[REDACTED:ANTHROPIC_KEY]"
    end

    test "strips benign ANSI from a value carrying no secret" do
      assert OutputRedaction.redact("\e[32mhello\e[0m world") == "hello world"
    end

    test "an ANSI-split sensitive key still redacts its value, key emitted unmutated" do
      # `api_\e[0mkey` strips to `api_key` (a `_KEY`-suffixed sensitive name),
      # so the value is masked — but the original key is left intact (only
      # classification sees the stripped form).
      assert OutputRedaction.redact(%{"api_\e[0mkey" => "plain-value"}) ==
               %{"api_\e[0mkey" => "[REDACTED]"}
    end
  end

  test "the shared tool action wrapper redacts direct run results" do
    assert {:ok, result} = SecretEcho.run(%{}, %{})

    rendered = inspect(result)
    refute rendered =~ "sk-abcdefghijklmnopqrstuvwxyz01"
    refute rendered =~ "abcdef0123456789abcdef"
    refute rendered =~ "not-patterned-but-sensitive-key"
    refute rendered =~ "iVBORw0KGgoAAAANSUhEUgAAAAUA"
    assert rendered =~ "[REDACTED:API_KEY]"
    assert rendered =~ "Bearer [REDACTED]"
    assert rendered =~ "[REDACTED:BINARY_PAYLOAD]"
  end

  test "the shared tool action wrapper normalizes direct run errors" do
    assert {:error, %{code: :tool_error, message: message, details: %{}}} =
             ErrorEcho.run(%{shape: :string}, %{})

    assert message == "token [REDACTED:API_KEY] leaked"

    assert {:error, %{code: :id_or_label_required, message: "id or label required", details: %{}}} =
             ErrorEcho.run(%{shape: :atom}, %{})

    assert {:error,
            %{
              code: :source_not_invalidatable,
              message: "source not invalidatable",
              details: %{reason: "{:source_not_invalidatable, \"memory://x\"}"}
            }} = ErrorEcho.run(%{shape: :tuple}, %{})

    assert {:error,
            %{code: :failed, message: "tool failed", details: %{context: %{status: :failed}}}} =
             ErrorEcho.run(%{shape: :failed_ok}, %{})
  end

  # The sweep covers every publication surface — the in-REPL agent registry AND
  # the MCP-published tools (e.g. replay_workflow is MCP-only and on the
  # approval require list), derived from JidoClaw.MCPServer.__publish__/0 so the
  # list can't drift.
  defp wrapped_tool_modules do
    Enum.uniq(JidoClaw.Agent.tool_modules() ++ JidoClaw.MCPServer.published_tool_modules())
  end

  test "every wrapped tool carries the shared redaction marker" do
    for module <- wrapped_tool_modules() do
      # function_exported?/3 does not load the module, and tool modules are
      # loaded lazily — ensure each is loaded before introspecting its markers.
      Code.ensure_loaded!(module)

      assert function_exported?(module, :__jidoclaw_tool_output_redacted__, 0),
             "#{inspect(module)} must use JidoClaw.Tools.Action"
    end
  end

  test "every wrapped tool carries the shared MCP scope marker" do
    for module <- wrapped_tool_modules() do
      Code.ensure_loaded!(module)

      assert function_exported?(module, :__jidoclaw_tool_mcp_scoped__, 0),
             "#{inspect(module)} must use JidoClaw.Tools.Action"
    end
  end

  test "every wrapped tool carries the shared tool-approval gate marker" do
    for module <- wrapped_tool_modules() do
      Code.ensure_loaded!(module)

      assert function_exported?(module, :__jidoclaw_tool_approval_gated__, 0),
             "#{inspect(module)} must use JidoClaw.Tools.Action"
    end
  end
end
