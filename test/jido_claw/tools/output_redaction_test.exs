defmodule JidoClaw.Tools.OutputRedactionTest do
  use ExUnit.Case, async: true

  defmodule SecretEcho do
    use JidoClaw.Tools.Action,
      name: "secret_echo_for_output_redaction_test",
      description: "Test-only action that returns secret-shaped output.",
      schema: []

    @impl true
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

    @impl true
    def run(%{shape: :string}, _context),
      do: {:error, "token sk-abcdefghijklmnopqrstuvwxyz01 leaked"}

    def run(%{shape: :atom}, _context), do: {:error, :id_or_label_required}
    def run(%{shape: :tuple}, _context), do: {:error, {:source_not_invalidatable, "memory://x"}}
    def run(%{shape: :failed_ok}, _context), do: {:ok, %{status: :failed, error: :tool_failed}}
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

  test "registered agent tools use the shared redaction wrapper" do
    for module <- JidoClaw.Agent.tool_modules() do
      # function_exported?/3 does not load the module, and tool modules are
      # loaded lazily — ensure each is loaded before introspecting its markers.
      Code.ensure_loaded!(module)

      assert function_exported?(module, :__jidoclaw_tool_output_redacted__, 0),
             "#{inspect(module)} must use JidoClaw.Tools.Action"
    end
  end

  test "registered agent tools use the shared MCP scope wrapper" do
    for module <- JidoClaw.Agent.tool_modules() do
      Code.ensure_loaded!(module)

      assert function_exported?(module, :__jidoclaw_tool_mcp_scoped__, 0),
             "#{inspect(module)} must use JidoClaw.Tools.Action"
    end
  end
end
