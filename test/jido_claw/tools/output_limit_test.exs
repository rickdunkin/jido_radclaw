defmodule JidoClaw.Tools.OutputLimitTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.OutputLimit
  alias JidoClaw.Tools.ReadFile

  defmodule BigEcho do
    alias JidoClaw.Tools.OutputLimit

    use JidoClaw.Tools.Action,
      name: "big_echo_for_output_limit_test",
      description: "Test-only action that returns oversized output.",
      schema: []

    @impl true
    def run(%{kind: :ok}, _context) do
      {:ok,
       %{
         content: String.duplicate("x", OutputLimit.max_bytes() + 1_000),
         nested: [String.duplicate("y", OutputLimit.max_bytes() + 500)]
       }}
    end

    def run(%{kind: :error}, _context) do
      {:error,
       %{
         code: :huge_error,
         message: String.duplicate("z", OutputLimit.max_bytes() + 1_000),
         details: %{payload: String.duplicate("p", OutputLimit.max_bytes() + 500)}
       }}
    end
  end

  test "the shared tool action wrapper caps oversized success output fields" do
    assert {:ok, %{content: content, nested: [nested]}} = BigEcho.run(%{kind: :ok}, %{})

    assert byte_size(content) <= OutputLimit.max_bytes()
    assert byte_size(nested) <= OutputLimit.max_bytes()
    assert content =~ "[tool output truncated:"
    assert nested =~ "[tool output truncated:"
  end

  test "the shared tool action wrapper caps oversized error fields" do
    assert {:error, %{code: :huge_error, message: message, details: %{payload: payload}}} =
             BigEcho.run(%{kind: :error}, %{})

    assert byte_size(message) <= OutputLimit.max_bytes()
    assert byte_size(payload) <= OutputLimit.max_bytes()
    assert message =~ "... (truncated)"
    assert payload =~ "[tool output truncated:"
  end

  test "read_file output is byte-capped even for a single huge line" do
    dir = Path.join(System.tmp_dir!(), "jido_output_limit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "huge.txt")
    File.write!(path, String.duplicate("a", OutputLimit.max_bytes() * 2))

    assert {:ok, %{content: content}} =
             ReadFile.run(%{path: path, limit: 1}, %{tool_context: %{project_dir: dir}})

    assert byte_size(content) <= OutputLimit.max_bytes()
    assert content =~ "[tool output truncated:"
  end
end
