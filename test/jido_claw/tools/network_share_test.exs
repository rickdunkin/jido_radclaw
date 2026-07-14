defmodule JidoClaw.Tools.NetworkShareTest do
  @moduledoc """
  PD1-2 producer rows for `network_share`'s result normalizer: the missing
  solution is a NORMAL domain outcome mapped at the producer to the
  registered `:not_found` (never the boundary's drift fallback); genuinely
  unforeseen atoms stay an open forward the boundary fallback covers.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.MCPServer.ErrorCodes
  alias JidoClaw.Tools.NetworkShare

  describe "normalize_share_result/2" do
    test ":ok shares" do
      assert NetworkShare.normalize_share_result(:ok, "sol-1") ==
               {:ok, %{solution_id: "sol-1", status: "shared"}}
    end

    test "not_connected / not_running stay honest OK non-shares" do
      assert {:ok, %{status: "not_shared", reason: "network not connected"}} =
               NetworkShare.normalize_share_result({:error, :not_connected}, "sol-1")

      assert {:ok, %{status: "not_shared", reason: "network not running"}} =
               NetworkShare.normalize_share_result({:error, :not_running}, "sol-1")
    end

    test ":solution_not_found normalizes to the registered :not_found + identifier details" do
      assert {:error, envelope} =
               NetworkShare.normalize_share_result({:error, :solution_not_found}, "sol-42")

      assert envelope.code == :not_found
      assert envelope.message == "Solution 'sol-42' not found."
      assert envelope.details == %{retry: false, solution_id: "sol-42", kind: "solution"}
      assert ErrorCodes.member?(envelope.code)
    end

    test "an overlong solution id is bounded UTF-8-safely in the message, exact in details" do
      long = String.duplicate("é", 300)

      assert {:error, envelope} =
               NetworkShare.normalize_share_result({:error, :solution_not_found}, long)

      assert String.valid?(envelope.message)
      assert byte_size(envelope.message) < byte_size(long)
      assert envelope.details.solution_id == long
    end

    test "a genuinely unforeseen atom stays an open forward (boundary fallback covers it)" do
      assert NetworkShare.normalize_share_result({:error, :zorp_new_failure}, "sol-1") ==
               {:error, :zorp_new_failure}

      refute ErrorCodes.member?(:zorp_new_failure)
    end
  end
end
