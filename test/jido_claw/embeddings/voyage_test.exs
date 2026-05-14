defmodule JidoClaw.Embeddings.VoyageTest do
  @moduledoc """
  Focused regression for the §10 dialyzer fix: 429 retry-after parsing
  goes through `Req.Response.get_header/2`, which always returns a
  `[binary()]` list. Locks in the parsed-integer and default-60 paths
  so the `is_binary/1` guard in `parse_retry_after/1` keeps the
  contract the rate-limited error tuple promises.
  """

  use ExUnit.Case, async: true

  alias JidoClaw.Embeddings.Voyage

  describe "__handle_429_for_test__/1" do
    test "extracts retry-after header value as parsed integer" do
      response = %Req.Response{
        status: 429,
        headers: %{"retry-after" => ["30"]},
        body: ""
      }

      assert {:error, {:rate_limited, 30}} = Voyage.__handle_429_for_test__(response)
    end

    test "defaults to 60 when retry-after header is absent" do
      response = %Req.Response{status: 429, headers: %{}, body: ""}

      assert {:error, {:rate_limited, 60}} = Voyage.__handle_429_for_test__(response)
    end

    test "defaults to 60 when retry-after header is unparseable" do
      response = %Req.Response{
        status: 429,
        headers: %{"retry-after" => ["soon"]},
        body: ""
      }

      assert {:error, {:rate_limited, 60}} = Voyage.__handle_429_for_test__(response)
    end
  end
end
