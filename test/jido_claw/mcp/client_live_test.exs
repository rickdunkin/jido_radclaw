defmodule JidoClaw.MCP.Client.LiveTest do
  @moduledoc """
  The Live client's restart-tolerance contract: a re-registration of an
  endpoint that already exists in the (Consumer-outliving) `ClientPool` folds
  to `:ok`, so a Consumer restart re-discovers and rebuilds proxies instead of
  hard-failing.
  """
  use ExUnit.Case, async: false

  alias Jido.MCP.Endpoint
  alias JidoClaw.MCP.Client.Live

  test "register_endpoint folds endpoint_already_registered into :ok" do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    id = :"live_test_#{System.unique_integer([:positive])}"

    {:ok, endpoint} =
      Endpoint.new(id,
        transport: {:streamable_http, [url: "http://localhost:65535/mcp"]},
        client_info: %{name: "jido_claw", version: "test"}
      )

    on_exit(fn -> Jido.MCP.unregister_endpoint(id) end)

    # First registration succeeds; the second hits
    # `{:error, {:endpoint_already_registered, id}}`, which Live maps to :ok.
    assert :ok = Live.register_endpoint(endpoint)
    assert :ok = Live.register_endpoint(endpoint)
  end
end
