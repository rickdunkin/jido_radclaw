defmodule JidoClaw.ConfigTest do
  @moduledoc "Config accessors that aren't covered by the loader's own tests."
  use ExUnit.Case, async: true

  test "mcp_servers/1 defaults to [] and passes a list through" do
    assert JidoClaw.Config.mcp_servers(%{}) == []
    assert JidoClaw.Config.mcp_servers(%{"mcp_servers" => "not-a-list"}) == []

    servers = [%{"name" => "s", "transport" => "stdio", "command" => "x"}]
    assert JidoClaw.Config.mcp_servers(%{"mcp_servers" => servers}) == servers
  end
end
