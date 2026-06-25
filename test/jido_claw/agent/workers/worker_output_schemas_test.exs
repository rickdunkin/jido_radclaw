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
    SketchBuild,
    SketchBuildExec,
    SketchReviewer,
    SystemExecutor,
    SystemVerifier,
    TestRunner,
    Verifier
  }

  defp output_for(module), do: Keyword.fetch!(module.strategy_opts(), :output)
  defp tools_for(module), do: Keyword.fetch!(module.strategy_opts(), :tools)

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
      assert [_, _] = parsed.files_changed
      assert [_, _] = parsed.improvements
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
    test "parses a valid sample with the enriched finding shape (AR-3)" do
      assert {:ok, parsed} =
               Output.parse(output_for(Reviewer), %{
                 "overall" => "approve",
                 "summary" => "Looks good",
                 "action_needed" => "none",
                 "findings" => [
                   %{
                     "severity" => "info",
                     "confidence" => "likely",
                     "location" => "lib/foo.ex:12",
                     "description" => "Consider extracting helper"
                   }
                 ]
               })

      assert parsed.overall == :approve
      assert parsed.action_needed == "none"
      [finding] = parsed.findings
      # severity/confidence are STRING enums (clean artifact round-trip), not atoms.
      assert finding.severity == "info"
      assert finding.confidence == "likely"
      assert finding.location == "lib/foo.ex:12"
    end

    test "rejects a finding missing the required confidence tag" do
      assert {:error, _} =
               Output.parse(output_for(Reviewer), %{
                 "overall" => "request_changes",
                 "summary" => "bug",
                 "action_needed" => "fix the nil case",
                 "findings" => [
                   %{
                     "severity" => "error",
                     "location" => "lib/foo.ex:3",
                     "description" => "nil deref"
                   }
                 ]
               })
    end
  end

  # AR-8b-2 F1: SketchReviewer reuses the shared `OutputSchema.reviewer_verdict/0`
  # (single-sourced with Reviewer) — what `DefaultMapper.reviewer_verdict/3`
  # consumes. Covers both the clean (approve) and findings (request_changes) shapes.
  describe "SketchReviewer schema (shared OutputSchema.reviewer_verdict/0)" do
    test "parses a clean approve verdict" do
      assert {:ok, parsed} =
               Output.parse(output_for(SketchReviewer), %{
                 "overall" => "approve",
                 "summary" => "Prototype is logically sound",
                 "action_needed" => "none",
                 "findings" => []
               })

      assert parsed.overall == :approve
      assert parsed.action_needed == "none"
      assert parsed.findings == []
    end

    test "parses a request_changes verdict with findings" do
      assert {:ok, parsed} =
               Output.parse(output_for(SketchReviewer), %{
                 "overall" => "request_changes",
                 "summary" => "Edge case unhandled",
                 "action_needed" => "Guard the window bound against the off-by-one",
                 "findings" => [
                   %{
                     "severity" => "error",
                     "confidence" => "likely",
                     "location" => "main.exs:8",
                     "description" => "off-by-one in the window"
                   }
                 ]
               })

      assert parsed.overall == :request_changes
      assert parsed.action_needed == "Guard the window bound against the off-by-one"
      [finding] = parsed.findings
      assert finding.severity == "error"
      assert finding.confidence == "likely"
      assert finding.location == "main.exs:8"
    end
  end

  # AR-8b-2 F2: SketchBuildExec single-sources its output map with SketchBuild via
  # the SketchWorker macro (builder shape — status/summary/files_changed/notes +
  # artifacts, NO `signals` field). It differs from SketchBuild by EXACTLY one tool
  # (`RunCommand` + its mandatory `FetchOutput` pair).
  describe "SketchBuildExec schema + tool list" do
    test "parses a builder result (same shape as SketchBuild)" do
      assert {:ok, parsed} =
               Output.parse(output_for(SketchBuildExec), %{
                 "status" => "completed",
                 "summary" => "Built and ran the tracer-bullet",
                 "files_changed" => ["main.exs"],
                 "notes" => "exit 0",
                 "artifacts" => %{"files" => "main.exs"}
               })

      assert parsed.status == :completed
      assert parsed.files_changed == ["main.exs"]
    end

    test "its tool list includes RunCommand AND FetchOutput" do
      tools = tools_for(SketchBuildExec)
      assert JidoClaw.Tools.RunCommand in tools
      assert JidoClaw.Tools.FetchOutput in tools
    end

    test "SketchBuild's tool list includes NEITHER RunCommand NOR FetchOutput" do
      tools = tools_for(SketchBuild)
      refute JidoClaw.Tools.RunCommand in tools
      refute JidoClaw.Tools.FetchOutput in tools
    end
  end

  # AR-8c: SystemExecutor is coder-shaped (status/summary/files_changed/notes +
  # artifacts, NO `signals` field — the verifier is ordered by the `system-change`
  # data edge) but mutates the REAL machine via `RunCommand`.
  describe "SystemExecutor schema + tool list" do
    test "parses a coder-shaped result" do
      assert {:ok, parsed} =
               Output.parse(output_for(SystemExecutor), %{
                 "status" => "completed",
                 "summary" => "Updated the nginx config and reloaded the service",
                 "files_changed" => ["/etc/nginx/nginx.conf"],
                 "notes" => "reloaded with exit 0",
                 "artifacts" => %{"files" => "/etc/nginx/nginx.conf"}
               })

      assert parsed.status == :completed
      assert parsed.files_changed == ["/etc/nginx/nginx.conf"]
      assert is_map(parsed.artifacts)
    end

    test "its tool list includes RunCommand (it runs CLI tooling on the machine)" do
      assert JidoClaw.Tools.RunCommand in tools_for(SystemExecutor)
    end
  end

  # AR-8c: SystemVerifier is reviewer-shaped (`OutputSchema.reviewer_verdict/0`, so
  # the `lens: "system"` stage derives clean:system / findings:system with no mapper
  # change) but carries `RunCommand` so it inspects the real machine.
  describe "SystemVerifier schema + tool list (shared reviewer_verdict/0)" do
    test "parses a clean approve verdict" do
      assert {:ok, parsed} =
               Output.parse(output_for(SystemVerifier), %{
                 "overall" => "approve",
                 "summary" => "Config is present and the service reloaded cleanly",
                 "action_needed" => "none",
                 "findings" => []
               })

      assert parsed.overall == :approve
      assert parsed.action_needed == "none"
      assert parsed.findings == []
    end

    test "parses a request_changes verdict with findings" do
      assert {:ok, parsed} =
               Output.parse(output_for(SystemVerifier), %{
                 "overall" => "request_changes",
                 "summary" => "The change did not take",
                 "action_needed" => "Re-run the reload; the daemon is on the old config",
                 "findings" => [
                   %{
                     "severity" => "error",
                     "confidence" => "likely",
                     "location" => "/etc/nginx/nginx.conf",
                     "description" => "service is still running the old config"
                   }
                 ]
               })

      assert parsed.overall == :request_changes
      assert parsed.action_needed == "Re-run the reload; the daemon is on the old config"
      [finding] = parsed.findings
      assert finding.severity == "error"
      assert finding.confidence == "likely"
      assert finding.location == "/etc/nginx/nginx.conf"
    end

    test "its tool list includes RunCommand (it re-checks state on the machine)" do
      assert JidoClaw.Tools.RunCommand in tools_for(SystemVerifier)
    end
  end
end
