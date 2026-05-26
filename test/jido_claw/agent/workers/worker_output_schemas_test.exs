defmodule JidoClaw.Agent.Workers.OutputSchemasTest do
  @moduledoc """
  Contract smoke tests for every worker's structured-output schema.

  Each worker module mounted under `use JidoClaw.Agent.Defaults` (which
  delegates to `Jido.AI.Agent`) exposes `strategy_opts/0`. When an
  `output: %{...}` keyword is present, the macro normalizes it into
  `strategy_opts[:output] = %Jido.AI.Output{}`. We use that as the public
  surface — no module attribute or accessor on the worker side. This
  catches drift (someone deletes a field, mis-types an enum) and is closer
  to a contract check than a Zoi unit test.
  """

  use ExUnit.Case, async: true

  alias Jido.AI.Output

  alias JidoClaw.Agent.Workers.{
    Coder,
    DocsWriter,
    Refactorer,
    Researcher,
    Reviewer,
    TestRunner,
    Verifier
  }

  defp output_for(module), do: module.strategy_opts() |> Keyword.fetch!(:output)

  describe "Coder schema" do
    test "parses a valid sample" do
      assert {:ok, parsed} =
               Output.parse(output_for(Coder), %{
                 "status" => "completed",
                 "summary" => "Implemented foo",
                 "files_changed" => ["lib/foo.ex"],
                 "notes" => "n/a",
                 "artifacts" => %{"url" => "http://localhost:4000"}
               })

      assert parsed.status == :completed
      assert parsed.summary == "Implemented foo"
      assert parsed.files_changed == ["lib/foo.ex"]
      assert is_map(parsed.artifacts)
      assert parsed.artifacts.url == "http://localhost:4000"
    end
  end

  describe "Researcher schema" do
    test "parses a valid sample" do
      assert {:ok, parsed} =
               Output.parse(output_for(Researcher), %{
                 "summary" => "Looked at the module graph",
                 "confidence" => "medium",
                 "findings" => [
                   %{
                     "topic" => "supervision tree",
                     "detail" => "Application boots Core then Gateway",
                     "references" => ["lib/jido_claw/application.ex"]
                   }
                 ],
                 "artifacts" => %{}
               })

      assert parsed.confidence == :medium
      assert is_list(parsed.findings)
      [finding] = parsed.findings
      assert finding.topic == "supervision tree"
    end
  end

  describe "TestRunner schema" do
    test "parses a valid sample with non-negative counts" do
      assert {:ok, parsed} =
               Output.parse(output_for(TestRunner), %{
                 "status" => "passed",
                 "summary" => "All green",
                 "passed_count" => 42,
                 "failed_count" => 0,
                 "failures" => [],
                 "artifacts" => %{}
               })

      assert parsed.status == :passed
      assert parsed.passed_count == 42
      assert parsed.failed_count == 0
    end

    test "rejects a negative passed_count" do
      assert {:error, _} =
               Output.parse(output_for(TestRunner), %{
                 "status" => "passed",
                 "summary" => "weird",
                 "passed_count" => -1,
                 "failed_count" => 0,
                 "failures" => [],
                 "artifacts" => %{}
               })
    end
  end

  describe "Refactorer schema" do
    test "parses a valid sample" do
      assert {:ok, parsed} =
               Output.parse(output_for(Refactorer), %{
                 "status" => "completed",
                 "summary" => "Pulled helpers into a private module",
                 "files_changed" => ["lib/foo.ex", "lib/foo_helpers.ex"],
                 "improvements" => ["Reduced duplication", "Clearer naming"],
                 "artifacts" => %{}
               })

      assert parsed.status == :completed
      assert length(parsed.files_changed) == 2
      assert length(parsed.improvements) == 2
    end
  end

  describe "DocsWriter schema" do
    test "parses a valid sample with multiple kinds" do
      assert {:ok, parsed} =
               Output.parse(output_for(DocsWriter), %{
                 "status" => "completed",
                 "summary" => "Wrote moduledocs and added typespecs",
                 "files_changed" => ["lib/foo.ex"],
                 "kinds" => ["moduledoc", "typespec"],
                 "artifacts" => %{}
               })

      assert parsed.status == :completed
      assert parsed.kinds == [:moduledoc, :typespec]
    end
  end

  describe "Verifier schema (already adopted in 46e1f87)" do
    test "parses a valid sample" do
      assert {:ok, parsed} =
               Output.parse(output_for(Verifier), %{
                 "verdict" => "pass",
                 "confidence" => "high",
                 "reasoning" => "Tests pass and behavior matches the spec"
               })

      assert parsed.verdict == :pass
      assert parsed.confidence == :high
    end
  end

  describe "Reviewer schema (already adopted in 46e1f87)" do
    test "parses a valid sample" do
      assert {:ok, parsed} =
               Output.parse(output_for(Reviewer), %{
                 "overall" => "approve",
                 "summary" => "Looks good",
                 "findings" => [
                   %{"severity" => "info", "description" => "Consider extracting helper"}
                 ]
               })

      assert parsed.overall == :approve
      [finding] = parsed.findings
      assert finding.severity == :info
    end
  end
end
