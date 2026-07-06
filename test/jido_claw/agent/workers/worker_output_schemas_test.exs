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
    Fixer,
    PlanArbiter,
    PlanChallenger,
    PlanDrafter,
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

  # AR-4: Coder moved from `builder_result/0` to `coder_result/0` — the builder
  # shape PLUS an OPTIONAL `signals` string list. It backs both the `implementer`
  # (self-reports `code-written`) and the `test-author` (self-reports `tests-ready`)
  # stages; the signals MUST parse as strings (`DefaultMapper.explicit_signals/1`
  # matches them against `publishes` strings).
  describe "Coder schema" do
    test "parses a valid sample WITHOUT signals (the optional field is absent)" do
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

    test "parses a sample carrying a signals string list, keeping it strings" do
      for signals <- [["code-written"], ["tests-ready"], ["code-written", "scope-shift"]] do
        assert {:ok, parsed} =
                 Output.parse(output_for(Coder), %{
                   "status" => "completed",
                   "summary" => "Implemented foo",
                   "files_changed" => ["lib/foo.ex"],
                   "notes" => "n/a",
                   "signals" => signals,
                   "artifacts" => %{}
                 })

        assert parsed.signals == signals
        assert Enum.all?(parsed.signals, &is_binary/1)
      end
    end
  end

  # AR-4: Fixer is builder-shaped (status/summary/files_changed/notes + artifacts)
  # PLUS a `signals` string list — the domains it self-reports, fed to
  # `DefaultMapper.explicit_signals/1` (so they MUST parse as strings, never atoms).
  describe "Fixer schema" do
    test "parses a valid sample, keeping signals as a list of strings" do
      assert {:ok, parsed} =
               Output.parse(output_for(Fixer), %{
                 "status" => "completed",
                 "summary" => "Guarded the nil deref and tightened the auth check",
                 "files_changed" => ["lib/auth.ex"],
                 "notes" => "n/a",
                 "signals" => ["code-written", "auth-surface"],
                 "artifacts" => %{}
               })

      assert parsed.status == :completed
      assert parsed.files_changed == ["lib/auth.ex"]
      # The signals stay STRINGS (DefaultMapper matches them against publishes strings).
      assert parsed.signals == ["code-written", "auth-surface"]
      assert Enum.all?(parsed.signals, &is_binary/1)
    end
  end

  # AR-4 P1: the researcher (the `planner` stage) now carries a REQUIRED `status`
  # (closes the blocked-producer hole at the schema layer — a blocked planner can't
  # silently fall through to summary-fabrication + `plan-ready` injection). The
  # `signals` field stays optional.
  describe "Researcher schema" do
    test "parses a valid sample (the optional signals field is absent)" do
      assert {:ok, parsed} =
               Output.parse(output_for(Researcher), %{
                 "summary" => "Looked at the module graph",
                 "status" => "completed",
                 "confidence" => "medium",
                 "findings" => [
                   %{
                     "topic" => "supervision tree",
                     "detail" => "Application boots Core then Gateway",
                     "references" => ["lib/jido_claw/application.ex"],
                     "confidence" => "likely"
                   }
                 ],
                 "artifacts" => %{}
               })

      assert parsed.status == :completed
      assert parsed.confidence == :medium
      assert is_list(parsed.findings)
      [finding] = parsed.findings
      assert finding.topic == "supervision tree"
      # AR-7: the top-level `confidence` is an ATOM enum (low|medium|high), but the
      # per-finding evidence tag is a STRING enum (likely|unsure) — clean artifact
      # round-trip — and is REQUIRED, so the fixture above must carry it.
      assert finding.confidence == "likely"
    end

    # AR-4: the `planner` (a `researcher`) self-reports `plan-ready` / `scope-shift`
    # through the optional `signals` field (strings, like the Coder/Fixer).
    test "parses a sample carrying a signals string list" do
      assert {:ok, parsed} =
               Output.parse(output_for(Researcher), %{
                 "summary" => "Drafted the plan",
                 "status" => "completed",
                 "confidence" => "high",
                 "findings" => [],
                 "signals" => ["plan-ready"],
                 "artifacts" => %{}
               })

      assert parsed.signals == ["plan-ready"]
      assert Enum.all?(parsed.signals, &is_binary/1)
    end

    # AR-4 P1: `status` is REQUIRED — a sample omitting it is rejected. This is the
    # planner "absent status" coverage: required-at-the-schema is what stops a
    # blocked planner that OMITS status from falling through to summary-fabrication
    # + injection. The hermetic composer stubs bypass Zoi (they stamp `:validated`),
    # so this contract change does not affect them.
    test "rejects a sample missing the now-required status" do
      assert {:error, _} =
               Output.parse(output_for(Researcher), %{
                 "summary" => "Looked at the module graph",
                 "confidence" => "medium",
                 "findings" => [],
                 "artifacts" => %{}
               })
    end

    # AR-7: each finding's `confidence` evidence tag is REQUIRED (Zoi default,
    # mirroring the reviewer finding's required `confidence`). A finding that omits
    # it is rejected at the schema layer; `on_validation_error: :repair` recovers a
    # transient omission at runtime.
    test "rejects a finding missing the now-required per-finding confidence tag" do
      assert {:error, _} =
               Output.parse(output_for(Researcher), %{
                 "summary" => "Looked at the module graph",
                 "status" => "completed",
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
                     "title" => "helper worth extracting",
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
      assert finding.title == "helper worth extracting"
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
                     "title" => "nil deref",
                     "severity" => "error",
                     "location" => "lib/foo.ex:3",
                     "description" => "nil deref"
                   }
                 ]
               })
    end

    # Camus C1-5: `title` is the finding's cross-wave identity headline
    # (FindingKey) — required at the schema layer like its four siblings;
    # `on_validation_error: :repair` recovers a transient runtime omission.
    test "rejects a finding missing the now-required title" do
      assert {:error, _} =
               Output.parse(output_for(Reviewer), %{
                 "overall" => "request_changes",
                 "summary" => "bug",
                 "action_needed" => "fix the nil case",
                 "findings" => [
                   %{
                     "severity" => "error",
                     "confidence" => "likely",
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
                     "title" => "window off-by-one",
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
                     "title" => "stale config still serving",
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

  # AR-9: PlanDrafter is the lens-stage drafter — a LEAN producer schema
  # (summary/status/confidence + optional signals + artifacts). Deliberately NO
  # `overall` (a lens-nil stage whose typed output carried `overall` would trip
  # `DefaultMapper`'s `{:reviewer_without_lens, _}` wave failure) and NO dynamic
  # artifact keys: the `plan:<lens>` artifact resolves via the summary fallback,
  # so the SUMMARY IS THE PLAN.
  describe "PlanDrafter schema" do
    test "parses a valid sample; status/confidence are atom enums (never persisted)" do
      assert {:ok, parsed} = Output.parse(output_for(PlanDrafter), drafter_sample())

      assert parsed.status == :completed
      assert parsed.confidence == :high
      assert parsed.summary =~ "smallest-shippable"
      assert is_map(parsed.artifacts)
    end

    test "parses a sample carrying a signals string list (scope-shift self-report only)" do
      sample = Map.put(drafter_sample(), "signals", ["scope-shift"])
      assert {:ok, parsed} = Output.parse(output_for(PlanDrafter), sample)
      assert parsed.signals == ["scope-shift"]
    end

    test "rejects a sample missing any required field" do
      for field <- ~w(summary status confidence artifacts) do
        assert {:error, _} =
                 Output.parse(output_for(PlanDrafter), Map.delete(drafter_sample(), field)),
               "expected a sample missing #{field} to be rejected"
      end
    end

    test "drops a sneaked `overall` key (reviewer-path regression)" do
      sample = Map.put(drafter_sample(), "overall", "approve")
      assert {:ok, parsed} = Output.parse(output_for(PlanDrafter), sample)
      refute Map.has_key?(parsed, :overall)
      refute Map.has_key?(parsed, "overall")
    end

    test "drops an unknown dynamic artifact key (pins the summary-fallback reality)" do
      # A model that tries to hand the artifact over as a dynamic `plan:<lens>`
      # key loses it at the schema layer — `output_artifacts` then resolves the
      # declared output via `result.result` (the summary), which the composer
      # stubs and the e2e assertions rely on.
      sample = Map.put(drafter_sample(), "plan:smallest-shippable", "SNEAKED PLAN")
      assert {:ok, parsed} = Output.parse(output_for(PlanDrafter), sample)
      refute Map.has_key?(parsed, "plan:smallest-shippable")
      assert Enum.sort(Map.keys(parsed)) == [:artifacts, :confidence, :status, :summary]
    end
  end

  # AR-9: PlanChallenger is critique-only — the three lists (blockers/concerns/
  # strengths) plus the lean producer base. NO `overall` (same lens-nil mapper
  # rule as the drafter); its `critique:<lens>` artifact is the summary fallback.
  describe "PlanChallenger schema" do
    test "parses a valid critique with the three required lists" do
      assert {:ok, parsed} = Output.parse(output_for(PlanChallenger), challenger_sample())

      assert parsed.status == :completed
      assert parsed.blockers == ["drops the audit log on rollback"]
      assert parsed.concerns == ["migration cost underestimated"]
      assert parsed.strengths == ["reuses the tested pipeline"]
      assert Enum.all?(parsed.blockers ++ parsed.concerns ++ parsed.strengths, &is_binary/1)
    end

    test "rejects a sample missing any required field" do
      for field <- ~w(summary status confidence artifacts blockers concerns strengths) do
        assert {:error, _} =
                 Output.parse(output_for(PlanChallenger), Map.delete(challenger_sample(), field)),
               "expected a sample missing #{field} to be rejected"
      end
    end

    test "drops a sneaked `overall` key (reviewer-path regression)" do
      sample = Map.put(challenger_sample(), "overall", "request_changes")
      assert {:ok, parsed} = Output.parse(output_for(PlanChallenger), sample)
      refute Map.has_key?(parsed, :overall)
      refute Map.has_key?(parsed, "overall")
    end
  end

  # AR-9: PlanArbiter writes the decision memo. `verdict` + `tie_break_rung` are
  # STRING enums (persisted-adjacent — `Envelope.normalize/1` would store an atom
  # enum as `":adopt"`); `status`/`confidence` stay atom enums (never persisted).
  describe "PlanArbiter schema" do
    test "parses a valid memo; verdict/tie_break_rung stay STRINGS, status stays an atom" do
      assert {:ok, parsed} = Output.parse(output_for(PlanArbiter), arbiter_sample())

      assert parsed.status == :completed
      assert parsed.verdict == "adopt"
      assert parsed.tie_break_rung == "correctness"
      assert parsed.selection == "smallest-shippable"
      assert parsed.revision_directive == "none"
      [assessment] = parsed.assessments
      assert assessment.lens == "smallest-shippable"
      assert assessment.steelman =~ "least code"
    end

    test "rejects a sample missing any required field" do
      for field <-
            ~w(summary status confidence artifacts assessments tie_break_rung selection
               verdict revision_directive) do
        assert {:error, _} =
                 Output.parse(output_for(PlanArbiter), Map.delete(arbiter_sample(), field)),
               "expected a sample missing #{field} to be rejected"
      end
    end

    test "rejects an out-of-enum verdict and an out-of-ladder tie_break_rung" do
      assert {:error, _} =
               Output.parse(output_for(PlanArbiter), %{arbiter_sample() | "verdict" => "maybe"})

      assert {:error, _} =
               Output.parse(
                 output_for(PlanArbiter),
                 %{arbiter_sample() | "tie_break_rung" => "vibes"}
               )
    end
  end

  # Valid string-keyed samples for the AR-9 plan-wave workers (the shape a real
  # LLM run returns), shared by the parse/reject cases above.
  defp drafter_sample do
    %{
      "summary" => "PLAN (smallest-shippable): ship the minimal slice first.",
      "status" => "completed",
      "confidence" => "high",
      "artifacts" => %{}
    }
  end

  defp challenger_sample do
    %{
      "summary" => "CRITIQUE: one real blocker, one concern, one strength.",
      "status" => "completed",
      "confidence" => "medium",
      "blockers" => ["drops the audit log on rollback"],
      "concerns" => ["migration cost underestimated"],
      "strengths" => ["reuses the tested pipeline"],
      "artifacts" => %{}
    }
  end

  defp arbiter_sample do
    %{
      "summary" => "DECISION MEMO — verdict: adopt. Selected smallest-shippable (correctness).",
      "status" => "completed",
      "confidence" => "high",
      "assessments" => [
        %{
          "lens" => "smallest-shippable",
          "steelman" => "the least code that proves the value",
          "strengths" => "smallest surface",
          "blockers" => "none"
        }
      ],
      "tie_break_rung" => "correctness",
      "selection" => "smallest-shippable",
      "verdict" => "adopt",
      "revision_directive" => "none",
      "artifacts" => %{}
    }
  end
end
