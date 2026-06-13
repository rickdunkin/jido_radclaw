defmodule JidoClaw.Tools.ScopeLiftTest do
  @moduledoc """
  Integration check that the shared `Tools.Action` wrapper lifts the live
  ReAct path's flat scope under `:tool_context` before the tool body runs.
  """
  use ExUnit.Case, async: true

  defmodule StubAction do
    use JidoClaw.Tools.Action,
      name: "scope_lift_stub_action",
      description: "Test-only action that echoes the scope it received.",
      schema: []

    @impl Jido.Action
    def run(_params, context) do
      {:ok,
       %{
         has_tool_context: is_map(context[:tool_context]),
         tenant_from_scope: get_in(context, [:tool_context, :tenant_id]),
         agent_id_from_scope: get_in(context, [:tool_context, :agent_id])
       }}
    end
  end

  test "a flat tenant-bearing context arrives nested at run/2" do
    assert {:ok, result} =
             StubAction.run(%{}, %{tenant_id: "t", session_id: "s", agent_id: "runtime-id"})

    assert result.has_tool_context
    assert result.tenant_from_scope == "t"
    # jido_ai's runtime :agent_id is excluded from the lifted scope.
    assert result.agent_id_from_scope == nil
  end
end
