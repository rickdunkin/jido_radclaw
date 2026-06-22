defmodule JidoClaw.MCPServer.Resources.WorkflowCatalogTest do
  @moduledoc """
  AR-2 Phase 5 (§10.2): the catalog MCP resource. Pure — the `read/2` impl
  ignores its frame arg, so no server boot is needed (pass `%{}`).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.MCPServer.Resources.WorkflowCatalog

  test "uri/0 is the committed single-catalog URI" do
    assert WorkflowCatalog.uri() == "jido://workflows/catalog"
  end

  test "mime_type/0 is application/json" do
    assert WorkflowCatalog.mime_type() == "application/json"
  end

  test "name/0 and description/0 are present" do
    assert WorkflowCatalog.name() == "workflow_catalog"
    assert is_binary(WorkflowCatalog.description())
    assert WorkflowCatalog.description() != ""
  end

  describe "read/2" do
    test "on the catalog URI returns the stages keyed by stage name" do
      assert {:ok, %{"stages" => stages}} = WorkflowCatalog.read(WorkflowCatalog.uri(), %{})

      assert is_map(stages)
      assert map_size(stages) > 0

      # Representative stages from the starter catalog.
      assert Map.has_key?(stages, "triage")
      assert Map.has_key?(stages, "plan-gate")
    end

    test "each stage is a JSON-safe, string-keyed map (Stage.to_map shape)" do
      assert {:ok, %{"stages" => stages}} = WorkflowCatalog.read(WorkflowCatalog.uri(), %{})

      triage = stages["triage"]
      assert triage["name"] == "triage"
      # The `unit` tag is stringified by Stage.to_map; the closed enum round-trips.
      assert is_map(triage["unit"])
      assert is_list(triage["routes"])

      # JSON-safe end to end: the whole payload encodes without raising.
      assert is_binary(Jason.encode!(%{"stages" => stages}))
    end

    test "on an unknown URI is not_found" do
      assert {:error, :not_found} = WorkflowCatalog.read("jido://workflows/other", %{})
    end
  end
end
