defmodule JidoClaw.RouteComposer.Emit.DefaultMapperTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Emit.DefaultMapper
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.Workflows.StepResult

  defp reviewer_meta(extra \\ %{}) do
    Map.merge(
      %{
        name: "quality-reviewer",
        emit: :default,
        lens: "quality",
        output: ["findings"],
        publishes: ["clean:quality", "findings:quality", "scope-shift"]
      },
      extra
    )
  end

  defp producer_meta(extra \\ %{}) do
    Map.merge(
      %{
        name: "planner",
        emit: :default,
        lens: nil,
        output: ["plan"],
        publishes: ["plan-ready", "scope-shift"]
      },
      extra
    )
  end

  defp fixer_meta(extra \\ %{}) do
    Map.merge(
      %{
        name: "fixer",
        emit: :default,
        lens: nil,
        output: ["fix"],
        publishes: ["code-written", "scope-shift", "auth-surface", "significant-build"]
      },
      extra
    )
  end

  # The `test-author` stage (a `coder`): a builder/coder-shaped output whose
  # self-reported `signals` carry `tests-ready` (its ONLY emission path — the
  # composer does NOT inject it).
  defp test_author_meta(extra \\ %{}) do
    Map.merge(
      %{
        name: "test-author",
        emit: :default,
        lens: nil,
        output: ["tests"],
        publishes: ["tests-ready", "scope-shift"]
      },
      extra
    )
  end

  describe "reviewer verdict" do
    test "approve + no findings → clean:<lens>" do
      result = %StepResult{
        name: "quality-reviewer",
        typed_output: %{"overall" => "approve", "findings" => []}
      }

      assert {:ok,
              %StageEmission{stage: "quality-reviewer", signals: ["clean:quality"]} = emission} =
               DefaultMapper.map(result, reviewer_meta())

      # the output-name mapping still produces a (here empty) findings artifact
      assert emission.artifacts == %{"findings" => []}
    end

    test "request_changes → findings:<lens> + findings artifact" do
      findings = [%{"severity" => "error", "description" => "bug"}]

      result = %StepResult{
        name: "quality-reviewer",
        typed_output: %{"overall" => "request_changes", "findings" => findings}
      }

      assert {:ok,
              %StageEmission{signals: ["findings:quality"], artifacts: %{"findings" => ^findings}}} =
               DefaultMapper.map(result, reviewer_meta())
    end

    test "a reviewer-shaped output with no lens is a coherence error" do
      result = %StepResult{name: "r", typed_output: %{"overall" => "approve", "findings" => []}}

      assert {:error, {:reviewer_without_lens, "r"}} =
               DefaultMapper.map(result, reviewer_meta(%{name: "r", lens: nil}))
    end

    # AR-3 regression guard: the enriched finding shape, in the ATOM-KEYED form
    # `Output.parse/2` produces (atom keys, STRING enum values), must store with
    # clean string values. `ComposerArtifact.Envelope.normalize/1` inspect/1s atom
    # *values* — an atom enum (`:error`) would persist as `":error"`. String enums
    # (severity/confidence) round-trip untouched; atom keys stringify cleanly.
    test "atom-keyed enriched verdict stores findings with clean string enums (A5 round-trip)" do
      finding = %{
        severity: "error",
        confidence: "likely",
        location: "lib/foo.ex:12",
        description: "nil deref on the empty list"
      }

      result = %StepResult{
        name: "quality-reviewer",
        typed_output: %{
          overall: :request_changes,
          summary: "found a bug",
          action_needed: "guard the empty case",
          findings: [finding]
        }
      }

      assert {:ok,
              %StageEmission{
                signals: ["findings:quality"],
                artifacts: %{"findings" => stored}
              }} = DefaultMapper.map(result, reviewer_meta())

      assert stored == [
               %{
                 "severity" => "error",
                 "confidence" => "likely",
                 "location" => "lib/foo.ex:12",
                 "description" => "nil deref on the empty list"
               }
             ]
    end
  end

  describe "explicit signals + output artifacts" do
    test "emits declared signals and maps each output name from typed_output" do
      result = %StepResult{
        name: "planner",
        typed_output: %{"signals" => ["plan-ready"], "plan" => "PLAN"}
      }

      assert {:ok, %StageEmission{signals: ["plan-ready"], artifacts: %{"plan" => "PLAN"}}} =
               DefaultMapper.map(result, producer_meta())
    end

    test "an output name absent from typed/artifacts falls back to the result text" do
      result = %StepResult{
        name: "planner",
        result: "TEXT",
        typed_output: %{"signals" => ["plan-ready"]}
      }

      assert {:ok, %StageEmission{artifacts: %{"plan" => "TEXT"}}} =
               DefaultMapper.map(result, producer_meta())
    end

    test "a signal outside publishes fails loudly (never silent-drop)" do
      result = %StepResult{name: "planner", typed_output: %{"signals" => ["surprise"]}}

      assert {:error, {:undeclared_signals, "planner", ["surprise"]}} =
               DefaultMapper.map(result, producer_meta())
    end
  end

  # AR-4 P1: a no-lens producer that reports `status: :blocked` produced no usable
  # output — its named artifact is never a schema field, so `output_value/3` would
  # fabricate it from the blocked `summary` (`result.result`). The mapper refuses it
  # LOUDLY so `WaveCollect` route-fails the wave instead of advancing a downstream
  # consumer against a "BLOCKED…" string — or silently converging with no lens run.
  describe "AR-4 P1: blocked-producer refusal" do
    test "a blocked (string status) non-reviewer producer fails loudly" do
      result = %StepResult{
        name: "implementer",
        result: "BLOCKED: could not resolve the missing upstream dependency",
        typed_output: %{"status" => "blocked"}
      }

      assert {:error, {:producer_blocked, "implementer"}} =
               DefaultMapper.map(result, producer_meta(%{name: "implementer", output: ["diff"]}))
    end

    # Parity with the string form — live output is atom-keyed before it round-trips
    # JSON (cf. the atom/string typed_output test below).
    test "a blocked (atom status) non-reviewer producer fails loudly" do
      result = %StepResult{
        name: "implementer",
        result: "BLOCKED: could not resolve the missing upstream dependency",
        typed_output: %{status: :blocked}
      }

      assert {:error, {:producer_blocked, "implementer"}} =
               DefaultMapper.map(result, producer_meta(%{name: "implementer", output: ["diff"]}))
    end

    # Scope-decision lock: only `:blocked` is refused. `:partial` is real (if thin)
    # output and proceeds — the summary backs the `plan` artifact via the text fallback.
    test "a :partial producer still maps (only :blocked is refused)" do
      result = %StepResult{
        name: "planner",
        result: "PARTIAL: outlined the plan, TODO the migration step",
        typed_output: %{"status" => "partial", "signals" => ["plan-ready"]}
      }

      assert {:ok,
              %StageEmission{
                signals: ["plan-ready"],
                artifacts: %{"plan" => "PARTIAL: outlined the plan, TODO the migration step"}
              }} = DefaultMapper.map(result, producer_meta())
    end

    # The `lens != nil` exclusion: a reviewer carries `overall`, not `status` —
    # even a stray `status: blocked` must NOT short-circuit its verdict.
    test "a reviewer with a stray blocked status still maps its verdict" do
      result = %StepResult{
        name: "quality-reviewer",
        typed_output: %{"overall" => "approve", "findings" => [], "status" => "blocked"}
      }

      assert {:ok, %StageEmission{signals: ["clean:quality"]}} =
               DefaultMapper.map(result, reviewer_meta())
    end
  end

  describe "AR-4 fixer + reviewer action_needed resolution" do
    # The fixer's `output: ["fix"]` resolves via the `output_value/3` text fallback
    # — `fixer_result/0` has no `fix` field, so `dynamic/2` misses and the artifact
    # takes `result.result` (the summary text), the SAME fallback the implementer's
    # `diff` relies on. Its self-reported `signals` ride `explicit_signals/1`.
    test "the fixer's `fix` resolves to the result text and its self-reported signals pass through" do
      result = %StepResult{
        name: "fixer",
        result: "FIX: guarded the nil deref",
        typed_output: %{"status" => "completed", "signals" => ["code-written", "auth-surface"]}
      }

      assert {:ok,
              %StageEmission{
                stage: "fixer",
                signals: signals,
                artifacts: %{"fix" => "FIX: guarded the nil deref"}
              }} = DefaultMapper.map(result, fixer_meta())

      assert Enum.sort(signals) == ["auth-surface", "code-written"]
    end

    # AR-4: the `coder` schema (`coder_result/0`) gained a `signals` field, so a
    # builder/coder-shaped output self-reports through `explicit_signals/1` just like
    # the fixer. `tests-ready` is the test-author's ONLY emission path (not injected).
    test "a coder/test-author output's self-reported tests-ready flows through explicit_signals" do
      result = %StepResult{
        name: "test-author",
        result: "TESTS: wrote the failing tests",
        typed_output: %{"status" => "completed", "signals" => ["tests-ready"]}
      }

      assert {:ok,
              %StageEmission{
                stage: "test-author",
                signals: ["tests-ready"],
                artifacts: %{"tests" => "TESTS: wrote the failing tests"}
              }} = DefaultMapper.map(result, test_author_meta())
    end

    test "a coder output that OMITS signals maps to an empty signal list" do
      result = %StepResult{
        name: "test-author",
        result: "TESTS: wrote the failing tests",
        typed_output: %{"status" => "completed"}
      }

      assert {:ok,
              %StageEmission{
                signals: [],
                artifacts: %{"tests" => "TESTS: wrote the failing tests"}
              }} = DefaultMapper.map(result, test_author_meta())
    end

    # AR-3 deferral closed: a reviewer with `action_needed` in `output` persists it
    # from the typed output via `dynamic/2` (no mapper change), alongside `findings`.
    test "a reviewer with `action_needed` in output persists it from typed_output" do
      findings = [%{"severity" => "error", "description" => "bug"}]

      result = %StepResult{
        name: "quality-reviewer",
        typed_output: %{
          "overall" => "request_changes",
          "findings" => findings,
          "action_needed" => "add the nil check before the deref"
        }
      }

      assert {:ok, %StageEmission{signals: ["findings:quality"], artifacts: artifacts}} =
               DefaultMapper.map(result, reviewer_meta(%{output: ["findings", "action_needed"]}))

      assert artifacts["action_needed"] == "add the nil check before the deref"
      assert artifacts["findings"] == findings
    end
  end

  test "atom-keyed and string-keyed typed_output behave identically" do
    atom = %StepResult{name: "planner", typed_output: %{signals: ["plan-ready"], plan: "PLAN"}}

    string = %StepResult{
      name: "planner",
      typed_output: %{"signals" => ["plan-ready"], "plan" => "PLAN"}
    }

    assert DefaultMapper.map(atom, producer_meta()) == DefaultMapper.map(string, producer_meta())
  end

  test "coerces an output artifact's atom keys + atom values to strings (A5 no-novel-atom)" do
    result = %StepResult{
      name: "planner",
      typed_output: %{
        "signals" => ["plan-ready"],
        "plan" => %{"n" => 1, nested_key: :nested_value}
      }
    }

    assert {:ok, %StageEmission{artifacts: %{"plan" => coerced}}} =
             DefaultMapper.map(result, producer_meta())

    # Atom key → string, atom value → inspect; the string key + number survive,
    # so the stored blob is `[:safe]`-decodable.
    assert coerced == %{"nested_key" => ":nested_value", "n" => 1}
  end
end
