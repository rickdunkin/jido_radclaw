defmodule JidoClaw.Orchestration.Verify.EvidenceTest do
  @moduledoc """
  Pure unit suite for the evidence floor's classifier (OB1-3 —
  `docs/exploration/ouroboros/PORT-OB1-3.md`; source tests cited per case):
  per-kind classification matrices, the ouroboros verdict partition, the
  transcript decode with its TranscriptEnvelope/redaction quirks, the
  porcelain wave diff, finding-key stability across waves, and the
  findings/action_needed synthesis.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.Verify.Evidence
  alias JidoClaw.RouteComposer.FindingKey

  # ---------------------------------------------------------------------------
  # Builders
  # ---------------------------------------------------------------------------

  defp obs(rows_or_skip, changed_or_skip \\ {:skip, :no_snapshot}, repo \\ nil) do
    %{tool_rows: rows_or_skip, changed_paths: changed_or_skip, repo: repo}
  end

  defp row(command, exit_code), do: %{command: command, exit_code: exit_code}

  defp classify_one(kind, value, observations) do
    %{claims: [result]} = classification = Evidence.classify(%{kind => [value]}, observations)
    {result, classification}
  end

  # ---------------------------------------------------------------------------
  # tests_passed
  # ---------------------------------------------------------------------------

  describe "classify/2 tests_passed" do
    test "clean matching invocation with exit 0 is supported" do
      {result, classification} =
        classify_one(:tests_passed, "mix test", obs({:ok, [row("mix test", 0)]}))

      assert result.status == :supported
      assert classification.verdict == :clean
    end

    test "plumbing-tolerant match: claim ⊆ row and row ⊆ claim both match" do
      # Row carries extra targeting the claim omits.
      {claim_in_row, _} =
        classify_one(:tests_passed, "mix test", obs({:ok, [row("mix test --seed 0", 0)]}))

      assert claim_in_row.status == :supported

      # Claim carries plumbing the row omits (row is the clean invocation).
      {row_in_claim, _} =
        classify_one(:tests_passed, "mix test 2>&1", obs({:ok, [row("mix test", 0)]}))

      assert row_in_claim.status == :supported
    end

    # Source: test_fat_harness_mode_rejects_unbacked_typed_evidence
    # (test_parallel_executor.py:4282 @ e905a41c).
    test "no matching invocation is unsupported (fabrication lane)" do
      {result, classification} =
        classify_one(:tests_passed, "mix test", obs({:ok, [row("mix compile", 0)]}))

      assert result.status == :unsupported
      assert classification.verdict == :fabrication_suspected
    end

    # Source: test_fat_harness_verifier_rejects_targeted_failed_test_command (:6366)
    # — the false-green catch.
    test "matching invocation with a nonzero exit is unsupported" do
      {result, classification} =
        classify_one(:tests_passed, "mix test", obs({:ok, [row("mix test", 1)]}))

      assert result.status == :unsupported
      assert result.detail =~ "exited 1"
      assert classification.verdict == :fabrication_suspected
    end

    test "a green rerun after a red run supports the claim" do
      rows = [row("mix test", 1), row("mix test", 0)]
      {result, _} = classify_one(:tests_passed, "mix test", obs({:ok, rows}))
      assert result.status == :supported
    end

    # Source: test_atomic_verifier_classifies_masked_test_command_as_form_mismatch
    # (:1301). v1 divergence (PORT-OB1-3 changed (E)): context-only, no finding.
    test "matched-but-masked run is form_mismatch, never a finding" do
      {result, classification} =
        classify_one(:tests_passed, "mix test", obs({:ok, [row("mix test 2>&1 | tail -20", 0)]}))

      assert result.status == :form_mismatch
      assert classification.verdict == :form_mismatch
      assert Evidence.discrepancies("implementer", classification) == []
    end

    test "masked exit-0 detection: exit swallow idiom cannot support" do
      {result, _} =
        classify_one(:tests_passed, "mix test", obs({:ok, [row("mix test || true", 0)]}))

      assert result.status == :form_mismatch
    end

    test "unanalyzable exit (nil exit_code) is form_mismatch, not support" do
      {result, _} = classify_one(:tests_passed, "mix test", obs({:ok, [row("mix test", nil)]}))
      assert result.status == :form_mismatch
    end

    # Source: test_gradle_maven_tests_passed_rejects_skip_test_invocations (:1420).
    test "a skip-flagged runner invocation is unsupported" do
      {result, _} =
        classify_one(:tests_passed, "gradle test", obs({:ok, [row("gradle test -x test", 0)]}))

      assert result.status == :unsupported
      assert result.detail =~ "skips tests"
    end

    # Source: test_fat_harness_verifier_rejects_echoed_unittest_command_as_test_command
    # (:6013) — an echoed command is not a test invocation.
    test "an echoed command never supports a test claim" do
      {result, _} =
        classify_one(:tests_passed, "mix test", obs({:ok, [row(~s(echo "mix test"), 0)]}))

      assert result.status == :unsupported
    end

    test "no transcript at all skips (vendor arm — conservative trust)" do
      {result, classification} =
        classify_one(:tests_passed, "mix test", obs({:skip, :no_transcript}))

      assert result.status == :skipped
      assert classification.verdict == :skipped
    end

    test "transcript present but zero command rows skips" do
      {result, _} = classify_one(:tests_passed, "mix test", obs({:ok, []}))
      assert result.status == :skipped
    end

    test "redacted transcript skips as :redacted — degraded, never suspicious" do
      {result, _} = classify_one(:tests_passed, "mix test", obs({:skip, :redacted}))
      assert result.status == :skipped
      assert result.detail =~ "redacted"
    end
  end

  # ---------------------------------------------------------------------------
  # commands_run
  # ---------------------------------------------------------------------------

  describe "classify/2 commands_run" do
    test "recorded command with preserved exit supports the claim" do
      {result, _} =
        classify_one(:commands_run, "mix compile", obs({:ok, [row("mix compile", 0)]}))

      assert result.status == :supported
    end

    test "claim ⊆ row tolerates plumbing on the recorded side" do
      {result, _} =
        classify_one(
          :commands_run,
          "mix compile",
          obs({:ok, [row("cd /app && mix compile > out.log", 0)]})
        )

      assert result.status == :supported
    end

    test "a claim naming more than ran is unsupported (no row ⊆ claim widening)" do
      {result, _} =
        classify_one(:commands_run, "mix compile --force", obs({:ok, [row("mix compile", 0)]}))

      assert result.status == :unsupported
    end

    test "exit code is not required for command presence" do
      {result, _} =
        classify_one(:commands_run, "mix compile", obs({:ok, [row("mix compile", 2)]}))

      assert result.status == :supported
    end

    test "masked plumbing on the only match is form_mismatch" do
      {result, _} =
        classify_one(:commands_run, "mix compile", obs({:ok, [row("mix compile | head -3", 0)]}))

      assert result.status == :form_mismatch
    end

    test "absent command is unsupported" do
      {result, _} = classify_one(:commands_run, "rm -rf junk", obs({:ok, [row("ls", 0)]}))
      assert result.status == :unsupported
    end
  end

  # ---------------------------------------------------------------------------
  # files_touched (decision 5 — the wave status diff IS support)
  # ---------------------------------------------------------------------------

  describe "classify/2 files_touched" do
    test "a path whose status changed this wave is supported" do
      changed = MapSet.new(["lib/foo.ex"])
      {result, _} = classify_one(:files_touched, "lib/foo.ex", obs({:skip, :x}, {:ok, changed}))
      assert result.status == :supported
    end

    test "an unchanged (pre-existing clean) path is unsupported — existence is not support" do
      {result, classification} =
        classify_one(:files_touched, "lib/exists.ex", obs({:skip, :x}, {:ok, MapSet.new()}))

      assert result.status == :unsupported
      assert result.detail =~ "existence alone"
      assert classification.verdict == :fabrication_suspected
    end

    test "./-prefixed claims normalize to the porcelain path" do
      changed = MapSet.new(["lib/foo.ex"])
      {result, _} = classify_one(:files_touched, "./lib/foo.ex", obs({:skip, :x}, {:ok, changed}))
      assert result.status == :supported
    end

    test "absolute claims resolve under the repo root" do
      changed = MapSet.new(["lib/foo.ex"])

      {result, _} =
        classify_one(
          :files_touched,
          "/repo/lib/foo.ex",
          obs({:skip, :x}, {:ok, changed}, "/repo")
        )

      assert result.status == :supported
    end

    test "paths outside the repo skip (can't verify ⇒ trust)" do
      {absolute_outside, _} =
        classify_one(
          :files_touched,
          "/etc/passwd",
          obs({:skip, :x}, {:ok, MapSet.new()}, "/repo")
        )

      assert absolute_outside.status == :skipped

      {traversal, _} =
        classify_one(
          :files_touched,
          "../outside.ex",
          obs({:skip, :x}, {:ok, MapSet.new()}, "/repo")
        )

      assert traversal.status == :skipped
    end

    test "missing before-snapshot skips the kind — never the permissive fallback" do
      {result, classification} =
        classify_one(:files_touched, "lib/foo.ex", obs({:skip, :x}, {:skip, :no_snapshot}))

      assert result.status == :skipped
      assert classification.verdict == :skipped
    end
  end

  # ---------------------------------------------------------------------------
  # Verdict partition (ouroboros-verbatim: pin parallel_executor.py:6182-6198)
  # ---------------------------------------------------------------------------

  describe "classify/2 verdict partition" do
    test "any genuine absence outranks masking (fabrication_suspected)" do
      rows = {:ok, [row("mix test | tail -3", 0)]}

      classification =
        Evidence.classify(%{tests_passed: ["mix test"], commands_run: ["rm -rf x"]}, obs(rows))

      statuses = Enum.map(classification.claims, & &1.status)
      assert :form_mismatch in statuses
      assert :unsupported in statuses
      assert classification.verdict == :fabrication_suspected
    end

    test "all-masked is form_mismatch (their len-equality rule)" do
      rows = {:ok, [row("mix test | tail -3", 0), row("mix compile | head -1", 0)]}

      classification =
        Evidence.classify(
          %{tests_passed: ["mix test"], commands_run: ["mix compile"]},
          obs(rows)
        )

      assert Enum.all?(classification.claims, &(&1.status == :form_mismatch))
      assert classification.verdict == :form_mismatch
    end

    test "all-supported is clean" do
      rows = {:ok, [row("mix test", 0)]}

      classification =
        Evidence.classify(%{tests_passed: ["mix test"], commands_run: ["mix test"]}, obs(rows))

      assert classification.verdict == :clean
    end

    test "nothing checked is skipped; supported + skipped stays clean" do
      assert Evidence.classify(%{}, obs({:ok, []})).verdict == :skipped
      assert Evidence.classify(nil, obs({:ok, []})).verdict == :skipped

      classification =
        Evidence.classify(
          %{tests_passed: ["mix test"], files_touched: ["lib/foo.ex"]},
          obs({:ok, [row("mix test", 0)]}, {:skip, :no_snapshot})
        )

      assert classification.verdict == :clean
    end

    test "counts tally per status" do
      rows = {:ok, [row("mix test", 1)]}

      classification =
        Evidence.classify(
          %{tests_passed: ["mix test"], files_touched: ["lib/foo.ex"]},
          obs(rows, {:skip, :no_snapshot})
        )

      assert classification.counts == %{
               supported: 0,
               unsupported: 1,
               form_mismatch: 0,
               skipped: 1
             }
    end

    test "total over garbage claims (non-string values filtered)" do
      classification =
        Evidence.classify(
          %{tests_passed: [nil, 42, "mix test"], commands_run: "not-a-list"},
          obs({:ok, [row("mix test", 0)]})
        )

      assert [%{value: "mix test", status: :supported}] = classification.claims
    end
  end

  # ---------------------------------------------------------------------------
  # decode_rows/1 (TranscriptEnvelope + redaction quirks)
  # ---------------------------------------------------------------------------

  describe "decode_rows/1" do
    defp call_row(id, command, extra_metadata \\ %{}) do
      %{
        "role" => "tool_call",
        "tool_call_id" => id,
        "metadata" =>
          Map.merge(
            %{"tool_name" => "run_command", "arguments" => %{"command" => command}},
            extra_metadata
          )
      }
    end

    defp result_row(id, exit_code) do
      %{
        "role" => "tool_result",
        "tool_call_id" => id,
        "metadata" => %{
          "tool_name" => "run_command",
          "result" => %{"status" => "ok", "value" => %{"exit_code" => exit_code, "output" => "…"}}
        }
      }
    end

    test "pairs call and result rows by tool_call_id (string-keyed JSONB shape)" do
      rows = [call_row("c1", "mix test"), result_row("c1", 0)]
      assert {:ok, [%{command: "mix test", exit_code: 0}]} = Evidence.decode_rows(rows)
    end

    test "atom-keyed live rows decode identically" do
      rows = [
        %{
          role: :tool_call,
          tool_call_id: "c1",
          metadata: %{tool_name: "run_command", arguments: %{command: "mix test"}}
        },
        %{
          role: :tool_result,
          tool_call_id: "c1",
          metadata: %{tool_name: "run_command", result: %{status: :ok, value: %{exit_code: 0}}}
        }
      ]

      assert {:ok, [%{command: "mix test", exit_code: 0}]} = Evidence.decode_rows(rows)
    end

    test "a call without a result decodes with nil exit_code" do
      assert {:ok, [%{command: "mix test", exit_code: nil}]} =
               Evidence.decode_rows([call_row("c1", "mix test")])
    end

    test "an error-envelope result decodes to nil exit_code (unanalyzable)" do
      rows = [
        call_row("c1", "mix test"),
        %{
          "role" => "tool_result",
          "tool_call_id" => "c1",
          "metadata" => %{
            "tool_name" => "run_command",
            "result" => %{"status" => "error", "error" => %{"__tuple__" => ["boom"]}}
          }
        }
      ]

      assert {:ok, [%{command: "mix test", exit_code: nil}]} = Evidence.decode_rows(rows)
    end

    test "non-run_command tool rows are excluded from observations" do
      rows = [
        %{
          "role" => "tool_call",
          "tool_call_id" => "c9",
          "metadata" => %{"tool_name" => "file_write", "arguments" => %{"path" => "x"}}
        },
        call_row("c1", "mix test"),
        result_row("c1", 0)
      ]

      assert {:ok, [%{command: "mix test"}]} = Evidence.decode_rows(rows)
    end

    test "zero tool rows skips :no_transcript (the vendor arm)" do
      non_tool = [%{"role" => "user", "tool_call_id" => nil, "metadata" => %{}}]
      assert {:skip, :no_transcript} = Evidence.decode_rows(non_tool)
      assert {:skip, :no_transcript} = Evidence.decode_rows([])
    end

    # Redaction residual (recorder.ex scrub path): rows with scrubbed metadata
    # are excluded; an all-scrubbed transcript skips :redacted.
    test "redacted rows are excluded; all-redacted skips :redacted" do
      redacted = %{
        "role" => "tool_call",
        "tool_call_id" => "c1",
        "metadata" => %{"redacted" => true}
      }

      assert {:skip, :redacted} = Evidence.decode_rows([redacted])

      mixed = [redacted, call_row("c2", "mix test"), result_row("c2", 0)]
      assert {:ok, [%{command: "mix test", exit_code: 0}]} = Evidence.decode_rows(mixed)
    end

    test "a tool row with non-map metadata counts as unreadable" do
      rows = [%{"role" => "tool_call", "tool_call_id" => "c1", "metadata" => nil}]
      assert {:skip, :redacted} = Evidence.decode_rows(rows)
    end

    test "non-run_command-only transcripts decode to zero observations (not a skip)" do
      rows = [
        %{
          "role" => "tool_call",
          "tool_call_id" => "c9",
          "metadata" => %{"tool_name" => "file_write", "arguments" => %{"path" => "x"}}
        }
      ]

      assert {:ok, []} = Evidence.decode_rows(rows)
    end
  end

  # ---------------------------------------------------------------------------
  # changed_paths/2 (porcelain diff)
  # ---------------------------------------------------------------------------

  describe "changed_paths/2" do
    test "modified, appearing, and disappearing paths all count as changed" do
      before_snapshot = " M lib/a.ex\n?? tmp/junk\n"
      after_snapshot = " M lib/a.ex\nM  lib/b.ex\n?? lib/new.ex\n"

      changed = Evidence.changed_paths(before_snapshot, after_snapshot)

      assert MapSet.member?(changed, "lib/b.ex")
      assert MapSet.member?(changed, "lib/new.ex")
      # tmp/junk vanished — its status changed.
      assert MapSet.member?(changed, "tmp/junk")
      # Unchanged status ⇒ not in the diff.
      refute MapSet.member?(changed, "lib/a.ex")
    end

    test "a status transition on the same path counts (?? -> A)" do
      changed = Evidence.changed_paths("?? lib/new.ex\n", "A  lib/new.ex\n")
      assert MapSet.member?(changed, "lib/new.ex")
    end

    test "rename rows contribute both sides" do
      changed = Evidence.changed_paths("", "R  old.ex -> new.ex\n")
      assert MapSet.member?(changed, "old.ex")
      assert MapSet.member?(changed, "new.ex")
    end

    test "quoted paths are unquoted" do
      changed = Evidence.changed_paths("", ~s(?? "path with spaces.ex"\n))
      assert MapSet.member?(changed, "path with spaces.ex")
    end

    test "identical snapshots diff to the empty set" do
      snapshot = " M lib/a.ex\n?? b.ex\n"
      assert Evidence.changed_paths(snapshot, snapshot) == MapSet.new()
    end
  end

  # ---------------------------------------------------------------------------
  # Findings synthesis + key stability
  # ---------------------------------------------------------------------------

  describe "discrepancies/2 + findings/1 + action_needed/1" do
    test "only :unsupported claims produce discrepancies, grouped per kind" do
      rows = {:ok, [row("mix test", 1), row("mix compile | head -2", 0)]}

      classification =
        Evidence.classify(
          %{
            tests_passed: ["mix test", "mix test --only unit"],
            commands_run: ["mix compile"]
          },
          obs(rows)
        )

      discrepancies = Evidence.discrepancies("implementer", classification)

      # Two unsupported tests_passed claims fold into ONE per-kind discrepancy;
      # the form_mismatch commands_run claim produces nothing.
      assert [%{location: "evidence:implementer:tests_passed"} = discrepancy] = discrepancies
      assert discrepancy.title == "evidence: claimed test pass unsupported by transcript"
      assert discrepancy.description =~ "mix test --only unit"
    end

    test "findings ride the VerifyStage shape with error severity" do
      discrepancy = %{title: "t", location: "evidence:s:tests_passed", description: "d"}

      assert [
               %{
                 "severity" => "error",
                 "title" => "t",
                 "location" => "evidence:s:tests_passed",
                 "description" => "d"
               }
             ] = Evidence.findings([discrepancy])
    end

    # Decision 3: keys must not churn across waves — stall detection matches
    # rounds on them.
    test "finding keys are stable across waves with varying detail" do
      wave1 =
        Evidence.classify(%{tests_passed: ["mix test"]}, obs({:ok, [row("mix test", 1)]}))

      wave2 =
        Evidence.classify(%{tests_passed: ["mix test"]}, obs({:ok, [row("mix test", 2)]}))

      [key1] =
        Evidence.discrepancies("implementer", wave1)
        |> Evidence.findings()
        |> Enum.map(&FindingKey.key/1)

      [key2] =
        Evidence.discrepancies("implementer", wave2)
        |> Evidence.findings()
        |> Enum.map(&FindingKey.key/1)

      assert is_binary(key1)
      assert key1 == key2
    end

    # Decision 3: stage-scoped locations — two same-wave stages' findings must
    # not collapse into one key.
    test "keys are stage-scoped" do
      base =
        Evidence.classify(%{tests_passed: ["mix test"]}, obs({:ok, []}, {:skip, :x}))

      # Force an unsupported result for both stages.
      classification = %{
        base
        | claims: [
            %{kind: :tests_passed, value: "mix test", status: :unsupported, detail: "d"}
          ]
      }

      [key_a] =
        Evidence.discrepancies("implementer", classification)
        |> Evidence.findings()
        |> Enum.map(&FindingKey.key/1)

      [key_b] =
        Evidence.discrepancies("test-author", classification)
        |> Evidence.findings()
        |> Enum.map(&FindingKey.key/1)

      assert key_a != key_b
    end

    test "action_needed names every discrepancy location once" do
      discrepancies = [
        %{title: "t", location: "evidence:a:tests_passed", description: "d"},
        %{title: "t2", location: "evidence:a:files_touched", description: "d2"}
      ]

      line = Evidence.action_needed(discrepancies)
      assert line =~ "evidence:a:tests_passed"
      assert line =~ "evidence:a:files_touched"
      assert line =~ "transcript"
    end
  end

  # ---------------------------------------------------------------------------
  # gather/2 (seam-level: skip taxonomy without a DB)
  # ---------------------------------------------------------------------------

  describe "gather/2" do
    test "nil request_id skips tool rows; snapshots still diff" do
      observations =
        Evidence.gather(nil, %{
          session_id: "s",
          before_porcelain: "",
          after_porcelain: "?? lib/new.ex\n"
        })

      assert observations.tool_rows == {:skip, :no_request_id}
      assert {:ok, changed} = observations.changed_paths
      assert MapSet.member?(changed, "lib/new.ex")
    end

    test "missing session skips tool rows" do
      observations = Evidence.gather("req-1", %{})
      assert observations.tool_rows == {:skip, :no_session}
      assert observations.changed_paths == {:skip, :no_snapshot}
    end

    test "missing either snapshot skips the files half" do
      missing_before = Evidence.gather(nil, %{before_porcelain: nil, after_porcelain: ""})
      assert missing_before.changed_paths == {:skip, :no_snapshot}

      missing_after = Evidence.gather(nil, %{before_porcelain: "", after_porcelain: nil})
      assert missing_after.changed_paths == {:skip, :no_snapshot}
    end

    test "repo rides into observations for absolute-claim resolution" do
      assert Evidence.gather(nil, %{repo: "/repo"}).repo == "/repo"
    end
  end
end
