defmodule JidoClaw.Reasoning.TelemetryTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Reasoning.{Classifier, Resources.Outcome, Telemetry}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok
  end

  describe "with_outcome/4" do
    test "returns the fun's result verbatim on :ok" do
      assert {:ok, %{answer: 42}} =
               Telemetry.with_outcome(
                 "cot",
                 "What is the meaning?",
                 [execution_kind: :strategy_run],
                 fn -> {:ok, %{answer: 42}} end
               )
    end

    test "returns the fun's result verbatim on :error" do
      assert {:error, :boom} =
               Telemetry.with_outcome(
                 "cot",
                 "fail",
                 [execution_kind: :strategy_run],
                 fn -> {:error, :boom} end
               )
    end

    test "emits start + stop telemetry with expected metadata" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "telemetry-test-#{System.unique_integer([:positive])}",
        [
          [:jido_claw, :reasoning, :strategy, :start],
          [:jido_claw, :reasoning, :strategy, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.with_outcome(
        "cot",
        "testing prompt",
        [execution_kind: :strategy_run],
        fn -> {:ok, %{}} end
      )

      assert_receive {^ref, [:jido_claw, :reasoning, :strategy, :start], _, meta}
      assert meta.strategy == "cot"
      assert meta.execution_kind == :strategy_run

      assert_receive {^ref, [:jido_claw, :reasoning, :strategy, :stop], %{duration_ms: _}, meta}
      assert meta.status == :ok
    end

    test "persists a row with workspace_id and project_dir round-tripped" do
      Telemetry.with_outcome(
        "cot",
        "a sample prompt for telemetry",
        [
          execution_kind: :strategy_run,
          workspace_id: "ws-abc",
          project_dir: "/tmp/foo"
        ],
        fn -> {:ok, %{}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)

      assert Enum.any?(rows, fn r ->
               r.workspace_id == "ws-abc" and r.project_dir == "/tmp/foo"
             end)
    end

    test "persists agent_id and forge_session_key when supplied in opts" do
      Telemetry.with_outcome(
        "cot",
        "a prompt with agent attribution",
        [
          execution_kind: :strategy_run,
          agent_id: "main",
          forge_session_key: "forge-xyz"
        ],
        fn -> {:ok, %{}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)

      assert Enum.any?(rows, fn r ->
               r.agent_id == "main" and r.forge_session_key == "forge-xyz"
             end)
    end

    test "agent_id and forge_session_key default to nil when absent from opts" do
      Telemetry.with_outcome(
        "cot",
        "a prompt without agent attribution",
        [execution_kind: :strategy_run, workspace_id: "ws-no-agent"],
        fn -> {:ok, %{}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)
      row = Enum.find(rows, fn r -> r.workspace_id == "ws-no-agent" end)
      assert row
      assert row.agent_id == nil
      assert row.forge_session_key == nil
    end

    test "persists status :error when fun returns {:error, _}" do
      Telemetry.with_outcome(
        "cot",
        "neutral placeholder prompt one",
        [execution_kind: :strategy_run],
        fn -> {:error, :bad} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)
      assert Enum.any?(rows, fn r -> r.status == :error end)
    end

    test "persists status :timeout when fun returns {:error, :timeout}" do
      Telemetry.with_outcome(
        "cot",
        "neutral placeholder prompt two",
        [execution_kind: :strategy_run],
        fn -> {:error, :timeout} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)
      assert Enum.any?(rows, fn r -> r.status == :timeout end)
    end

    test "emits jido_claw.reasoning.classified when no :profile is supplied" do
      {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.reasoning.classified")

      try do
        Telemetry.with_outcome(
          "cot",
          "What is a GenServer?",
          [execution_kind: :strategy_run],
          fn -> {:ok, %{}} end
        )

        assert_receive {:signal,
                        %Jido.Signal{type: "jido_claw.reasoning.classified", data: data}},
                       500

        assert data.task_type == :qa
        assert data.complexity == :simple
        assert data.recommended_strategy == "cot"
        assert data.executed_strategy == "cot"
        assert is_float(data.confidence)
      after
        JidoClaw.SignalBus.unsubscribe(sub_id)
      end
    end

    test "persists certificate fields when fun returns them" do
      Telemetry.with_outcome(
        "cot",
        "certificate prompt alpha",
        [execution_kind: :certificate_verification, base_strategy: "cot"],
        fn ->
          {:ok,
           %{
             output: "ok",
             certificate_verdict: "PASS",
             certificate_confidence: 0.91
           }}
        end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended, :certificate_verification)
      row = Enum.find(rows, fn r -> r.strategy == "cot" and r.base_strategy == "cot" end)
      assert row
      assert row.certificate_verdict == "PASS"
      assert row.certificate_confidence == 0.91
    end

    test "opts override fun-returned certificate fields" do
      Telemetry.with_outcome(
        "cot",
        "certificate prompt beta",
        [
          execution_kind: :certificate_verification,
          base_strategy: "cot",
          certificate_verdict: "FAIL",
          certificate_confidence: 0.2
        ],
        fn ->
          {:ok,
           %{
             certificate_verdict: "PASS",
             certificate_confidence: 0.99
           }}
        end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended, :certificate_verification)
      row = Enum.find(rows, fn r -> r.certificate_verdict == "FAIL" end)
      assert row
      assert row.certificate_confidence == 0.2
    end

    test "captures tokens from :input_tokens / :output_tokens keys (jido_ai shape)" do
      Telemetry.with_outcome(
        "cot",
        "token capture prompt",
        [execution_kind: :strategy_run],
        fn -> {:ok, %{usage: %{input_tokens: 123, output_tokens: 45, total_tokens: 168}}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)
      row = Enum.find(rows, fn r -> r.tokens_in == 123 and r.tokens_out == 45 end)
      assert row
    end

    test "captures tokens on {:error, %{usage: _}} partial-failure paths" do
      Telemetry.with_outcome(
        "cot",
        "a neutral placeholder prompt for tokens three",
        [execution_kind: :strategy_run],
        fn ->
          {:error, %{reason: :bad, usage: %{input_tokens: 77, output_tokens: 8}}}
        end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)
      row = Enum.find(rows, fn r -> r.tokens_in == 77 and r.tokens_out == 8 end)
      assert row
      assert row.status == :error
    end

    test "merges caller-supplied metadata into persisted row" do
      Telemetry.with_outcome(
        "cot",
        "a neutral metadata placeholder",
        [
          execution_kind: :pipeline_run,
          metadata: %{stage_index: 2, stage_total: 4, extra: "hello"}
        ],
        fn -> {:ok, %{}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended, :pipeline_run)

      row =
        Enum.find(rows, fn r ->
          md = r.metadata
          (Map.get(md, "extra") || Map.get(md, :extra)) == "hello"
        end)

      assert row
      assert (Map.get(row.metadata, "stage_index") || Map.get(row.metadata, :stage_index)) == 2
    end

    test "skips the classified signal when caller pre-supplies :profile" do
      {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.reasoning.classified")

      try do
        profile = Classifier.profile("What is a GenServer?")

        Telemetry.with_outcome(
          "cot",
          "What is a GenServer?",
          [execution_kind: :strategy_run, profile: profile],
          fn -> {:ok, %{}} end
        )

        refute_receive {:signal, %Jido.Signal{type: "jido_claw.reasoning.classified"}}, 200
      after
        JidoClaw.SignalBus.unsubscribe(sub_id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # max_context_bytes cap-failure lifecycle (v0.4.7)
  # ---------------------------------------------------------------------------

  describe "cap-failure lifecycle via RunPipeline" do
    # A 5 KB-body runner — stage 2's prior output exceeds the tiny cap, so
    # the composer returns the error-tuple and the loop routes it back
    # through with_outcome/4 with `fn -> {:error, reason} end`.
    defmodule BigBodyRunner do
      @moduledoc false
      @body String.duplicate("a", 5_000)
      def run(%{prompt: _}, _ctx) do
        {:ok, %{output: @body, usage: %{input_tokens: 0, output_tokens: 0}}}
      end
    end

    test "cap-failure stage still fires start + stop telemetry with status: :error" do
      ref = make_ref()
      test_pid = self()

      handler_id = "telemetry-cap-fail-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:jido_claw, :reasoning, :strategy, :start],
          [:jido_claw, :reasoning, :strategy, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      try do
        assert {:error, _msg} =
                 JidoClaw.Tools.RunPipeline.run(
                   %{
                     pipeline_name: "cap_fail_tel_#{System.unique_integer([:positive])}",
                     prompt: "INITIAL",
                     max_context_bytes: 2000,
                     stages: [
                       %{"strategy" => "cot", "context_mode" => "accumulate"},
                       %{"strategy" => "tot", "context_mode" => "accumulate"}
                     ]
                   },
                   %{reasoning_runner: BigBodyRunner}
                 )

        # Stage 1 produces an :ok lifecycle; stage 2 is the cap-failure.
        # Flush stage 1's events, then verify stage 2's start + stop fire
        # and stop carries status: :error.
        assert_receive {^ref, [:jido_claw, :reasoning, :strategy, :start], _, %{strategy: "cot"}}

        assert_receive {^ref, [:jido_claw, :reasoning, :strategy, :stop], _,
                        %{strategy: "cot", status: :ok}}

        assert_receive {^ref, [:jido_claw, :reasoning, :strategy, :start], _,
                        %{strategy: "tot"} = start_meta}

        assert_receive {^ref, [:jido_claw, :reasoning, :strategy, :stop], _,
                        %{strategy: "tot", status: :error} = stop_meta}

        # start event metadata includes prompt_length driven by the
        # classification prompt (irreducible would-be request).
        assert is_integer(start_meta.prompt_length)
        assert start_meta.prompt_length > 0

        _ = stop_meta
      after
        :telemetry.detach(handler_id)
      end
    end

    test "cap-failure emits jido_claw.reasoning.classified with the irreducible prompt's profile" do
      {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.reasoning.classified")

      try do
        assert {:error, _msg} =
                 JidoClaw.Tools.RunPipeline.run(
                   %{
                     pipeline_name: "cap_classified_#{System.unique_integer([:positive])}",
                     prompt: "INITIAL",
                     max_context_bytes: 2000,
                     stages: [
                       %{"strategy" => "cot", "context_mode" => "accumulate"},
                       %{"strategy" => "tot", "context_mode" => "accumulate"}
                     ]
                   },
                   %{reasoning_runner: BigBodyRunner}
                 )

        # The first classified signal is for stage 1; flush it.
        assert_receive {:signal,
                        %Jido.Signal{
                          type: "jido_claw.reasoning.classified",
                          data: %{executed_strategy: "cot"}
                        }},
                       500

        # Stage 2's cap-failure classified signal MUST still fire — this is
        # the key assertion: the failing stage routes through with_outcome/4,
        # which classifies and emits. The data reflects the irreducible
        # would-be request (initial + newest-stage + notice), NOT "" and NOT
        # the pre-cap full string.
        assert_receive {:signal,
                        %Jido.Signal{
                          type: "jido_claw.reasoning.classified",
                          data: %{executed_strategy: "tot"} = data
                        }},
                       500

        # The classified signal's task_type and recommended_strategy come from
        # profiling the irreducible classification prompt. We don't pin the
        # exact task_type (depends on the prompt content) — just that the
        # classifier ran on a non-empty prompt.
        assert data.task_type in [
                 :debugging,
                 :verification,
                 :qa,
                 :planning,
                 :refactoring,
                 :exploration,
                 :open_ended
               ]
      after
        JidoClaw.SignalBus.unsubscribe(sub_id)
      end
    end
  end
end
