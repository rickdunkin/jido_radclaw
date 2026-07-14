defmodule JidoClaw.MCPServer.ErrorCodesTest do
  use ExUnit.Case, async: true

  alias JidoClaw.MCPServer.ErrorCodes

  test "families/0 covers all/0 exactly (no orphan codes, no orphan families)" do
    from_families =
      ErrorCodes.families()
      |> Enum.flat_map(fn {_family, codes} -> Map.keys(codes) end)
      |> MapSet.new()

    assert from_families == ErrorCodes.all()
  end

  test "families are disjoint (a code belongs to exactly one family)" do
    all_codes = Enum.flat_map(ErrorCodes.families(), fn {_f, codes} -> Map.keys(codes) end)

    assert length(all_codes) == MapSet.size(ErrorCodes.all()),
           "a code appears in more than one family"
  end

  test "every registered code carries a nonempty one-line doc" do
    for {family, codes} <- ErrorCodes.families(), {code, doc} <- codes do
      assert is_binary(doc) and String.trim(doc) != "",
             "#{inspect(code)} in #{inspect(family)} has an empty doc"

      refute doc =~ "\n", "#{inspect(code)} doc must be one line"
    end
  end

  test "member?/1 answers registry membership" do
    assert ErrorCodes.member?(:tool_error)
    assert ErrorCodes.member?(:unknown_skill)
    assert ErrorCodes.member?(:doom_loop)
    refute ErrorCodes.member?(:definitely_not_registered)
    refute ErrorCodes.member?(SomeModule.Never.Registered)
  end

  test "family/1 resolves registered codes and rejects unregistered ones" do
    assert ErrorCodes.family(:approval_pending) == {:ok, :pipeline}
    assert ErrorCodes.family(:lua_timeout) == {:ok, :lua}
    assert ErrorCodes.family(:skill_run_failed) == {:ok, :workflow}
    assert ErrorCodes.family(:not_found) == {:ok, :lookup}
    assert ErrorCodes.family(:nope_never) == :error
  end

  test "the registry carries the verified 51-code inventory" do
    assert MapSet.size(ErrorCodes.all()) == 51
  end

  test "stability_sentence/0 pins the location, scope, and fallback rules" do
    sentence = ErrorCodes.stability_sentence()

    assert sentence =~ "content[1]"
    assert sentence =~ "second content item"
    assert sentence =~ "relays may append"
    assert sentence =~ "unregistered_code"
    assert sentence =~ "JSON-RPC protocol errors"
    assert sentence =~ "MINOR"
    assert sentence =~ "MAJOR"
  end

  test "the instructions surface serves the three-state retry-semantics definition" do
    sentence = ErrorCodes.stability_sentence()

    # Single-sourced: the stability sentence ends with retry_semantics/0
    # (compile-time concat of the same attribute), so server_instructions
    # serves the definition automatically.
    assert String.ends_with?(sentence, ErrorCodes.retry_semantics())
    assert sentence =~ "retry-policy eligibility"
    assert sentence =~ "never records"
    assert sentence =~ "ABSENT"
    assert sentence =~ "do not infer"
  end
end
