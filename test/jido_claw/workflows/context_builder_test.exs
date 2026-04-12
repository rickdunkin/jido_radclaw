defmodule JidoClaw.Workflows.ContextBuilderTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Workflows.{ContextBuilder, StepResult}

  describe "build_task/4" do
    test "joins non-empty parts with double newlines" do
      result = ContextBuilder.build_task("Do the thing", "extra info", "dep results", "artifacts")
      assert result == "Do the thing\n\nextra info\n\ndep results\n\nartifacts"
    end

    test "rejects empty strings" do
      result = ContextBuilder.build_task("Do the thing", "", "", "")
      assert result == "Do the thing"
    end

    test "rejects nil values" do
      result = ContextBuilder.build_task("Do the thing", nil, "", nil)
      assert result == "Do the thing"
    end

    test "assembles all parts when present" do
      result = ContextBuilder.build_task("task", "ctx", "deps", "art")
      parts = String.split(result, "\n\n")
      assert length(parts) == 4
    end

    test "preserves order of parts" do
      result = ContextBuilder.build_task("first", "second", "third", "fourth")
      assert result =~ ~r/first.*second.*third.*fourth/s
    end
  end

  describe "format_for_deps/3" do
    test "returns empty string for nil depends_on" do
      assert ContextBuilder.format_for_deps([make_result("a")], nil) == ""
    end

    test "returns empty string for empty depends_on" do
      assert ContextBuilder.format_for_deps([make_result("a")], []) == ""
    end

    test "returns empty string for empty prior_results" do
      assert ContextBuilder.format_for_deps([], ["a"]) == ""
    end

    test "filters to only dependency results" do
      results = [make_result("a", "coder", "output A"), make_result("b", "reviewer", "output B")]
      formatted = ContextBuilder.format_for_deps(results, ["a"])

      assert formatted =~ "output A"
      refute formatted =~ "output B"
    end

    test "includes template name in section headers" do
      results = [make_result("research", "researcher", "findings")]
      formatted = ContextBuilder.format_for_deps(results, ["research"])

      assert formatted =~ "research (researcher)"
    end

    test "includes multiple dependency results" do
      results = [
        make_result("a", "coder", "output A"),
        make_result("b", "reviewer", "output B"),
        make_result("c", "tester", "output C")
      ]

      formatted = ContextBuilder.format_for_deps(results, ["a", "c"])

      assert formatted =~ "output A"
      refute formatted =~ "output B"
      assert formatted =~ "output C"
    end
  end

  describe "format_preceding_all/2" do
    test "returns empty string for empty list" do
      assert ContextBuilder.format_preceding_all([]) == ""
    end

    test "reverses results to chronological order" do
      # Prepend-style accumulation: newest first
      results = [make_result("step_2", nil, "second"), make_result("step_1", nil, "first")]
      formatted = ContextBuilder.format_preceding_all(results)

      # Should appear in chronological order (step_1 before step_2)
      first_pos = :binary.match(formatted, "first") |> elem(0)
      second_pos = :binary.match(formatted, "second") |> elem(0)
      assert first_pos < second_pos
    end

    test "formats all results" do
      results = [make_result("b", "reviewer", "B"), make_result("a", "coder", "A")]
      formatted = ContextBuilder.format_preceding_all(results)

      assert formatted =~ "A"
      assert formatted =~ "B"
    end
  end

  describe "format_all/2" do
    test "returns empty string for empty list" do
      assert ContextBuilder.format_all([]) == ""
    end

    test "does not reverse results" do
      results = [make_result("first", nil, "AAA"), make_result("second", nil, "BBB")]
      formatted = ContextBuilder.format_all(results)

      first_pos = :binary.match(formatted, "AAA") |> elem(0)
      second_pos = :binary.match(formatted, "BBB") |> elem(0)
      assert first_pos < second_pos
    end
  end

  describe "truncation" do
    test "truncates results exceeding max_chars" do
      long_text = String.duplicate("x", 5000)
      results = [make_result("step", "coder", long_text)]
      formatted = ContextBuilder.format_for_deps(results, ["step"], max_chars: 100)

      assert formatted =~ "[truncated]"
      # The full 5000-char text should not be present
      refute formatted =~ String.duplicate("x", 5000)
    end

    test "does not truncate results within max_chars" do
      short_text = "short"
      results = [make_result("step", "coder", short_text)]
      formatted = ContextBuilder.format_for_deps(results, ["step"], max_chars: 100)

      assert formatted =~ "short"
      refute formatted =~ "[truncated]"
    end

    test "default max_chars is 4000" do
      text = String.duplicate("x", 4001)
      results = [make_result("step", "coder", text)]
      formatted = ContextBuilder.format_for_deps(results, ["step"])

      assert formatted =~ "[truncated]"
    end

    test "text exactly at max_chars is not truncated" do
      text = String.duplicate("x", 100)
      results = [make_result("step", "coder", text)]
      formatted = ContextBuilder.format_for_deps(results, ["step"], max_chars: 100)

      refute formatted =~ "[truncated]"
    end
  end

  describe "format_artifact_context/3" do
    test "returns empty string when step has no consumes" do
      step = %{consumes: []}
      assert ContextBuilder.format_artifact_context(step, [], []) == ""
    end

    test "merges static produces with dynamic artifacts" do
      producer_step = %{
        name: "implement",
        produces: %{"type" => "elixir_module", "files" => ["lib/foo.ex"]}
      }

      consumer_step = %{consumes: ["implement"]}

      producer_result = %StepResult{
        name: "implement",
        template: "coder",
        result: "done",
        artifacts: %{"url" => "http://localhost:4000", "port" => "4000"}
      }

      formatted =
        ContextBuilder.format_artifact_context(consumer_step, [producer_step], [producer_result])

      assert formatted =~ "Artifact Context"
      assert formatted =~ "implement"
      assert formatted =~ "elixir_module"
      assert formatted =~ "http://localhost:4000"
      assert formatted =~ "4000"
    end

    test "dynamic artifacts override static produces" do
      producer_step = %{name: "impl", produces: %{"url" => "http://localhost:3000"}}
      consumer_step = %{consumes: ["impl"]}

      producer_result = %StepResult{
        name: "impl",
        template: "coder",
        result: "done",
        artifacts: %{"url" => "http://localhost:4000"}
      }

      formatted =
        ContextBuilder.format_artifact_context(consumer_step, [producer_step], [producer_result])

      assert formatted =~ "http://localhost:4000"
      refute formatted =~ "http://localhost:3000"
    end

    test "works with no producer step found" do
      consumer_step = %{consumes: ["missing"]}
      result = %StepResult{name: "missing", result: "done", artifacts: %{"key" => "val"}}

      formatted = ContextBuilder.format_artifact_context(consumer_step, [], [result])

      assert formatted =~ "key"
      assert formatted =~ "val"
    end

    test "returns empty when no artifacts exist" do
      producer_step = %{name: "impl", produces: nil}
      consumer_step = %{consumes: ["impl"]}
      producer_result = %StepResult{name: "impl", result: "done", artifacts: %{}}

      formatted =
        ContextBuilder.format_artifact_context(consumer_step, [producer_step], [producer_result])

      assert formatted == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_result(name, template \\ nil, result \\ "result text") do
    %StepResult{name: name, template: template, result: result}
  end
end
