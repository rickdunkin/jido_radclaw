defmodule JidoClaw.MCPServer.Resources.MetaVersionTest do
  @moduledoc """
  PD1-1: the `jido://_meta/version` static resource, driven through the real
  `JidoClaw.MCPServer` handler path (the workflow_stage_test harness).
  """
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers.Resources, as: ResourcesHandler
  alias JidoClaw.MCPServer
  alias JidoClaw.MCPServer.Resources.MetaVersion
  alias JidoClaw.MCPServer.SurfaceVersion

  defp frame do
    {:ok, frame} = MCPServer.init(%{}, %Frame{})
    frame
  end

  defp read(uri) do
    ResourcesHandler.handle_read(%{"params" => %{"uri" => uri}}, frame(), MCPServer)
  end

  test "resource identity: uri/name/mime pinned" do
    assert MetaVersion.uri() == "jido://_meta/version"
    assert MetaVersion.name() == "meta_version"
    assert MetaVersion.mime_type() == "application/json"
  end

  test "read serves app_version + surface_version + tool_count" do
    assert {:reply, %{"contents" => [content]}, _frame} = read("jido://_meta/version")
    assert content["uri"] == "jido://_meta/version"
    assert content["mimeType"] == "application/json"

    payload = Jason.decode!(content["text"])
    assert payload["app_version"] == to_string(Application.spec(:jido_claw, :vsn))
    assert payload["surface_version"] == SurfaceVersion.current()
    assert payload["tool_count"] == length(MCPServer.served_tool_names())
  end

  test "direct read/2 on any other URI is not_found" do
    assert MetaVersion.read("jido://_meta/other", nil) == {:error, :not_found}
  end
end
