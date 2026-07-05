defmodule JidoClaw.Orchestration.VerifyTest do
  @moduledoc """
  Pure contract tests for `JidoClaw.Orchestration.Verify.build_result/2` —
  every subprocess/git touch is an injected seam (the camus `test_verify.py`
  shape), so nothing here spawns or reads a repo. Covers the camus
  classification table + the mix adaptations, both integrity modes, the law-4
  capture-failure downgrade, the no-verifier refusal, and the envelope's
  fail-closed round-trip.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.Verify
  alias JidoClaw.Orchestration.Verify.Envelope

  @repo "/scratch/repo"

  # A per-call sequence seam: each call pops the next value; the last value
  # repeats once exhausted (stable-capture seams stay one-element).
  defp seq(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn _repo ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [head | tail] -> {head, tail}
      end)
    end
  end

  defp check(name, cmd), do: %{name: name, cmd: cmd, env: %{}, timeout_ms: nil}

  # Scripted runner: results keyed by check name.
  defp runner(results), do: fn chk, _repo -> Map.fetch!(results, chk.name) end

  # Working-tree seams with stable captures (clean tree, constant head/digest).
  defp stable_seams do
    [porcelain: seq([""]), head: seq(["h1"]), diff_digest: seq(["d1"])]
  end

  defp build(checks, results, opts \\ []) do
    Verify.build_result(
      checks,
      Keyword.merge(
        [repo: @repo, runner: runner(results)] ++ stable_seams(),
        opts
      )
    )
  end

  describe "classification (camus table + mix adaptations)" do
    test "exit 0 across all checks is a pass binding {head, tree_digest}" do
      envelope = build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}})

      assert %Envelope{pass: true, inconclusive: false, tampered: false, failures: []} = envelope
      assert envelope.head == "h1"
      assert envelope.tree_digest == "d1"
      assert envelope.mode == :working_tree
      assert envelope.checks == [%{name: "unit", cmd: ["mix", "test"], exit: 0}]
    end

    test "a plain nonzero exit is a red `failed`" do
      envelope = build([check("unit", ["mix", "test"])], %{"unit" => {1, "1 test failed"}})

      assert %Envelope{pass: false, inconclusive: false, tampered: false} = envelope

      assert [%{stage: "unit", kind: "failed", exit: 1, log_tail: "1 test failed"}] =
               envelope.failures
    end

    for {title, exit, tail, cmd, kind} <- [
          {"exit 127 → missing_tool", 127, "command not found: mix", ["mix", "test"],
           "missing_tool"},
          {"exit 124 → timeout", 124, "timed out", ["mix", "test"], "timeout"},
          {"pytest exit 5 → no_tests", 5, "no tests ran", ["python3", "-m", "pytest", "-q"],
           "no_tests"},
          {"'No module named' tail → missing_tool", 2, "No module named pytest",
           ["python3", "-m", "pytest"], "missing_tool"},
          {"mix task-not-found tail → missing_tool", 1,
           ~s|** (Mix) The task "precommit" could not be found|, ["mix", "precommit"],
           "missing_tool"},
          {"npx not-found tail → missing_tool", 1, ~s|Command "tsc" not found|,
           ["npx", "--no-install", "tsc"], "missing_tool"},
          {"pnpm exec not-found tail → missing_tool", 1, "could not determine executable",
           ["pnpm", "exec", "tsc"], "missing_tool"}
        ] do
      test "#{title} (inconclusive, never a red)" do
        envelope =
          build(
            [check("c", unquote(cmd))],
            %{"c" => {unquote(exit), unquote(tail)}}
          )

        assert %Envelope{pass: false, inconclusive: true, tampered: false} = envelope
        assert [%{kind: unquote(kind)}] = envelope.failures
      end
    end

    test "the :output_limit sentinel is inconclusive with a nil exit" do
      envelope = build([check("c", ["mix", "test"])], %{"c" => {:output_limit, "…capped"}})

      assert %Envelope{pass: false, inconclusive: true} = envelope
      assert [%{kind: "output_limit", exit: nil}] = envelope.failures
      assert envelope.checks == [%{name: "c", cmd: ["mix", "test"], exit: nil}]
    end

    test "exit 5 without pytest in the argv stays a red `failed`" do
      envelope = build([check("c", ["mix", "test"])], %{"c" => {5, "boom"}})
      assert [%{kind: "failed"}] = envelope.failures
      refute envelope.inconclusive
    end

    test "the mix env-lane rule is scoped to a mix argv — a non-mix red printing the phrase stays red" do
      envelope =
        build(
          [check("c", ["./script.sh"])],
          %{"c" => {1, ~s(oops: The task "x" could not be found)}}
        )

      assert [%{kind: "failed"}] = envelope.failures
      refute envelope.inconclusive
    end

    test "collect-all: every check runs; one red among greens is a red run" do
      envelope =
        build(
          [check("a", ["mix", "format"]), check("b", ["mix", "test"]), check("c", ["mix", "x"])],
          %{"a" => {0, ""}, "b" => {1, "failed"}, "c" => {0, ""}}
        )

      assert [_first, _second, _third] = envelope.checks
      assert [%{stage: "b", kind: "failed"}] = envelope.failures
      refute envelope.pass
      refute envelope.inconclusive
    end

    test "a red mixed with an inconclusive kind is RED (all-inconclusive is required)" do
      envelope =
        build(
          [check("a", ["mix", "test"]), check("b", ["mix", "x"])],
          %{"a" => {1, "failed"}, "b" => {124, "timed out"}}
        )

      refute envelope.pass
      refute envelope.inconclusive
    end
  end

  describe "working-tree mode integrity" do
    test "dirty-before is a FACT (integrity_note), never a refusal — checks still run and pass" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}},
          porcelain: seq([" M lib/app.ex\n"])
        )

      assert envelope.pass
      refute envelope.tampered
      assert envelope.integrity_note =~ "dirty against HEAD before verify"
      assert envelope.checks != []
    end

    test "a tracked content edit mid-verify (digest change on an already-dirty tree) is tampered tracked_mutation" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}},
          porcelain: seq([" M lib/app.ex\n"]),
          diff_digest: seq(["d1", "d2"])
        )

      assert %Envelope{pass: false, inconclusive: false, tampered: true} = envelope
      assert Enum.any?(envelope.failures, &(&1.kind == "tracked_mutation"))
    end

    test "a HEAD move mid-verify is tampered head_moved" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}}, head: seq(["h1", "h2"]))

      assert %Envelope{tampered: true, pass: false, inconclusive: false} = envelope
      assert Enum.any?(envelope.failures, &(&1.kind == "head_moved"))
    end

    test "a would-be green with a failed HEAD capture is inconclusive integrity_unavailable, never clean" do
      envelope = build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}}, head: seq([nil]))

      assert %Envelope{pass: false, inconclusive: true, tampered: false} = envelope
      assert [%{kind: "integrity_unavailable"}] = envelope.failures
    end

    test "a would-be green with a failed digest capture is inconclusive, never clean" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}}, diff_digest: seq([nil]))

      assert %Envelope{pass: false, inconclusive: true} = envelope
      assert [%{kind: "integrity_unavailable"}] = envelope.failures
    end

    test "a RED with a failed capture stays red, with the unasserted invariant noted" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {1, "failed"}}, head: seq([nil]))

      assert %Envelope{pass: false, inconclusive: false} = envelope
      assert [%{kind: "failed"}] = envelope.failures
      assert envelope.integrity_note =~ "not asserted"
    end
  end

  describe "sealed mode integrity (camus-verbatim + the sealed compare)" do
    test "a dirty tracked tree BEFORE the checks is tampered uncommitted_state; checks never run" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}},
          sealed_head: "h1",
          porcelain: seq([" M lib/app.ex\n"])
        )

      assert %Envelope{pass: false, inconclusive: false, tampered: true, checks: []} = envelope
      assert [%{kind: "uncommitted_state", log_tail: " M lib/app.ex"}] = envelope.failures
      # Even a refusal NAMES the state it refused.
      assert envelope.head == "h1"
      assert envelope.mode == :sealed
      assert envelope.sealed_head == "h1"
    end

    test "a clean tree at the sealed head passes and echoes what it certified" do
      envelope = build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}}, sealed_head: "h1")

      assert envelope.pass
      assert envelope.mode == :sealed
      assert envelope.head == "h1"
      assert envelope.sealed_head == "h1"
    end

    test "a HEAD that does not match the sealed head is tampered BEFORE the checks (committed cover-up)" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}},
          sealed_head: "sealed-sha",
          head: seq(["other-sha"])
        )

      assert %Envelope{tampered: true, checks: []} = envelope
      assert [%{kind: "head_moved"}] = envelope.failures
    end

    test "a mid-verify commit (head moves after the checks) is tampered head_moved" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}},
          sealed_head: "h1",
          head: seq(["h1", "h2"])
        )

      assert envelope.tampered
      assert Enum.any?(envelope.failures, &(&1.kind == "head_moved"))
    end

    test "a tracked mutation during the checks is tampered tracked_mutation" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}},
          sealed_head: "h1",
          porcelain: seq(["", " M lib/app.ex\n"])
        )

      assert envelope.tampered
      assert Enum.any?(envelope.failures, &(&1.kind == "tracked_mutation"))
    end

    test "a would-be green with a failed porcelain capture is inconclusive, never clean" do
      envelope =
        build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}},
          sealed_head: "h1",
          porcelain: seq([nil])
        )

      assert %Envelope{pass: false, inconclusive: true} = envelope
      assert [%{kind: "integrity_unavailable"}] = envelope.failures
    end
  end

  describe "no verifier / refusal" do
    test "an empty check list is the loud inconclusive refusal, never a pass or a silent skip" do
      envelope = build([], %{})

      assert %Envelope{pass: false, inconclusive: true, tampered: false, checks: []} = envelope
      assert [failure] = envelope.failures
      assert failure.kind == "missing_tool"
      assert failure.reason == "no_verifier_detected"
      assert failure.log_tail =~ "verify_cmd"
    end

    test "sealed mode still refuses a dirty tree ahead of the no-verifier refusal" do
      envelope = build([], %{}, sealed_head: "h1", porcelain: seq([" M lib/app.ex\n"]))

      assert envelope.tampered
      assert [%{kind: "uncommitted_state"}] = envelope.failures
    end

    test "refusal_result/3 carries the reason + remedy (the config-error lane)" do
      envelope = Verify.refusal_result("invalid_verify_config", "fix your verify_cmd")

      assert %Envelope{pass: false, inconclusive: true} = envelope

      assert [%{reason: "invalid_verify_config", log_tail: "fix your verify_cmd"}] =
               envelope.failures
    end
  end

  describe "Envelope round-trip + fail-closed decode" do
    test "green, red, and tampered envelopes survive to_map |> from_map byte-faithfully" do
      for envelope <- [
            build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}}),
            build([check("unit", ["mix", "test"])], %{"unit" => {1, "failed"}}),
            build([check("unit", ["mix", "test"])], %{"unit" => {0, ""}}, head: seq(["h1", "h2"]))
          ] do
        round_tripped = Envelope.from_map(Envelope.to_map(envelope))
        assert round_tripped == envelope
      end
    end

    test "garbage never decodes to a pass" do
      for garbage <- [nil, "pass", [], 42, %{"pass" => "true"}, %{"pass" => 1}] do
        envelope = Envelope.from_map(garbage)
        refute envelope.pass
      end
    end

    test "non-map garbage decodes to the never-pass inconclusive sentinel" do
      envelope = Envelope.from_map("garbage")

      assert %Envelope{pass: false, inconclusive: true} = envelope
      assert [%{kind: "integrity_unavailable", reason: "decode_failed"}] = envelope.failures
    end

    test "an unknown mode fails the whole decode to the sentinel (never a kept string)" do
      valid = Envelope.to_map(build([check("u", ["mix", "test"])], %{"u" => {0, ""}}))
      envelope = Envelope.from_map(Map.put(valid, "mode", "hostile"))

      refute envelope.pass
      assert [%{reason: "decode_failed"}] = envelope.failures
    end

    test "booleans decode true ONLY from the literal true (tampered can't be laundered)" do
      valid =
        [check("u", ["mix", "test"])]
        |> build(%{"u" => {0, ""}}, head: seq(["h1", "h2"]))
        |> Envelope.to_map()

      assert %Envelope{tampered: true} = Envelope.from_map(valid)
      refute Envelope.from_map(Map.put(valid, "tampered", "yes")).tampered
    end
  end
end
