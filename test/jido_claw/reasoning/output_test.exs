defmodule JidoClaw.Reasoning.OutputTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Output

  describe "extract_result/1 — structured-output fallbacks" do
    test "prefers :last_answer over :summary" do
      assert Output.extract_result(%{last_answer: "a", summary: "b"}) == "a"
    end

    test "falls back to :summary when no :last_answer/:answer/:text" do
      assert Output.extract_result(%{summary: "implemented foo"}) == "implemented foo"
    end

    test "handles string-keyed :summary (JSON-decoded shape)" do
      assert Output.extract_result(%{"summary" => "implemented foo"}) == "implemented foo"
    end

    test "falls back to :reasoning when no :summary present" do
      assert Output.extract_result(%{reasoning: "verdict reasoning here"}) ==
               "verdict reasoning here"
    end

    test "handles string-keyed :reasoning" do
      assert Output.extract_result(%{"reasoning" => "verdict reasoning"}) ==
               "verdict reasoning"
    end

    test ":summary wins over :reasoning when both present" do
      assert Output.extract_result(%{summary: "s", reasoning: "r"}) == "s"
    end

    test "inspects an unknown-shape map" do
      result = Output.extract_result(%{foo: "bar"})
      assert is_binary(result)
      assert result =~ "foo"
    end
  end

  describe "typed_request_output/1" do
    test "extracts typed result from an atom-keyed :validated shape" do
      request = %{
        result: %{summary: "s", artifacts: %{url: "u"}},
        meta: %{output: %{status: :validated}}
      }

      assert Output.typed_request_output(request) ==
               %{summary: "s", artifacts: %{url: "u"}}
    end

    test "extracts typed result from an atom-keyed :repaired shape" do
      request = %{
        result: %{summary: "s"},
        meta: %{output: %{status: :repaired}}
      }

      assert Output.typed_request_output(request) == %{summary: "s"}
    end

    test "extracts typed result from a fully string-keyed shape" do
      request = %{
        "result" => %{"summary" => "s", "artifacts" => %{"url" => "u"}},
        "meta" => %{"output" => %{"status" => "validated"}}
      }

      assert Output.typed_request_output(request) ==
               %{"summary" => "s", "artifacts" => %{"url" => "u"}}
    end

    test "extracts typed result from a string-keyed \"repaired\" shape" do
      request = %{
        "result" => %{"summary" => "s"},
        "meta" => %{"output" => %{"status" => "repaired"}}
      }

      assert Output.typed_request_output(request) == %{"summary" => "s"}
    end

    test "returns nil when meta is missing" do
      assert Output.typed_request_output(%{result: %{summary: "s"}}) == nil
      assert Output.typed_request_output(%{"result" => %{"summary" => "s"}}) == nil
    end

    test "returns nil when meta.output.status is :error" do
      request = %{
        result: %{summary: "s"},
        meta: %{output: %{status: :error}}
      }

      assert Output.typed_request_output(request) == nil
    end
  end
end
