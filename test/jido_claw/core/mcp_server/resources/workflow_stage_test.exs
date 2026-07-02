defmodule JidoClaw.MCPServer.Resources.WorkflowStageTest do
  @moduledoc """
  G2-1b: the per-stage template resource (`jido://workflows/{name}`), driven
  in-process against the REAL `JidoClaw.MCPServer` (precedent:
  `anubis_tools_handler_patch_test.exs`). The frame is built through jido_mcp's
  generated `init/2`, so its runtime registration path (static resources into
  `frame.resources`) is exercised alongside the compile-time `component`
  registration.

  Registration is asserted via `__components__(:resource)` and the
  `resources/templates/list` handler — deliberately NEVER via
  `MCPServer.__publish__().resources`, where component templates never appear
  (the design doc's false-green trap).
  """
  use ExUnit.Case, async: true

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Resource
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers.Resources, as: ResourcesHandler
  alias JidoClaw.MCPServer

  # jido_mcp's generated init/2 registers the publish lists into the frame —
  # the same path a live handshake takes before any resources/* request.
  defp frame do
    {:ok, frame} = MCPServer.init(%{}, %Frame{})
    frame
  end

  defp read(uri) do
    ResourcesHandler.handle_read(%{"params" => %{"uri" => uri}}, frame(), MCPServer)
  end

  describe "spike gate points (Phase 0)" do
    # Gate point 2 (compile-time half): the component registers into
    # __components__(:resource) with template + name + mime pinned. Gate
    # point 1 (it compiles inside a `use Jido.MCP.Server` module) is implicit.
    test "__components__(:resource) carries the template resource" do
      assert [%Resource{} = template] =
               Enum.filter(MCPServer.__components__(:resource), & &1.uri_template)

      assert template.uri_template == "jido://workflows/{name}"
      assert template.name == "workflow_stage"
      assert template.mime_type == "application/json"
      assert template.handler == JidoClaw.MCPServer.Resources.WorkflowStage
    end

    # Gate point 2 (handler half): resources/templates/list — the acceptance
    # surface — returns the template. The handler returns %Resource{} structs
    # (protocol casing appears only via the JSON.Encoder impl), so assert
    # struct fields on the direct result AND protocol keys on the round-trip.
    test "resources/templates/list lists the template" do
      assert {:reply, %{"resourceTemplates" => templates}, _frame} =
               ResourcesHandler.handle_templates_list(%{}, frame(), MCPServer)

      assert [%Resource{name: "workflow_stage", uri_template: "jido://workflows/{name}"}] =
               templates

      # Protocol casing (uriTemplate/mimeType) appears via anubis's built-in
      # JSON.Encoder impl on %Resource{} — NOT Jason, which it never derives.
      assert [%{"uriTemplate" => "jido://workflows/{name}", "name" => "workflow_stage"} = wire] =
               JSON.decode!(JSON.encode!(templates))

      assert wire["mimeType"] == "application/json"
    end

    # Gate point 3: a template-matching URI routes to the component's read/2
    # with the parsed `name` var, and the response carries the pinned mime.
    test "resources/read on a template URI routes to read/2 with the parsed name" do
      assert {:reply, %{"contents" => [content]}, _frame} = read("jido://workflows/triage")

      assert content["uri"] == "jido://workflows/triage"
      assert content["mimeType"] == "application/json"
      assert %{"name" => "triage"} = stage_payload(content)
    end

    # Gate point 4: static-before-template ordering — the catalog URI still
    # reads the static resource (through jido_mcp's exact-URI bridge), never
    # the template.
    test "resources/read on the catalog URI still reads the static catalog" do
      assert {:reply, %{"contents" => [content]}, _frame} = read("jido://workflows/catalog")

      assert content["uri"] == "jido://workflows/catalog"
      assert content["mimeType"] == "application/json"
      assert %{"stages" => stages} = Jason.decode!(content["text"])
      assert Map.has_key?(stages, "triage")
    end
  end

  describe "read/2 payload (Phases 1+3)" do
    test "a known stage returns the catalog's Stage.to_map entry byte-identically" do
      alias JidoClaw.RouteComposer.Catalog

      assert {:reply, %{"contents" => [content]}, _frame} = read("jido://workflows/triage")

      # Single-sourced with the catalog resource: the drill-down equals the
      # same entry of the catalog's `stages` map.
      expected = Catalog.to_map(Catalog.all())["triage"]
      assert stage_payload(content) == expected
    end

    test "an unknown stage name is a resource not_found error" do
      # read/2 returns Error.resource(:not_found, …); anubis's template
      # fallback re-surfaces it as its own read not-found — same reason.
      assert {:error, %Error{reason: :resource_not_found}, _frame} =
               read("jido://workflows/definitely-not-a-stage")
    end

    test "a URI outside the template space is not_found" do
      assert {:error, %Error{reason: :resource_not_found}, _frame} =
               read("jido://other/triage")
    end
  end

  defp stage_payload(content) do
    assert %{"stage" => stage} = Jason.decode!(content["text"])
    stage
  end
end
