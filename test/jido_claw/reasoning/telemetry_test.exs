defmodule JidoClaw.Reasoning.TelemetryTest do
  @moduledoc """
  v0.6.4 — `Reasoning.Telemetry.persist/9` no longer populates the
  deprecated `workspace_id` / `agent_id` string columns on
  `Reasoning.Outcome`. Tests below that previously asserted those
  columns reflected `:workspace_id` / `:agent_id` opts now assert the
  columns are nil. The `@tag :deprecated_outcome_columns` markers let
  us delete those assertions in one sweep when a v0.7 migration drops
  the columns.

  See `lib/jido_claw/reasoning/resources/outcome.ex` moduledoc for the
  full deprecation contract and `lib/jido_claw/reasoning/telemetry.ex`
  for the writer that no longer threads these fields.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Reasoning.{Classifier, Resources.Outcome, Telemetry}
  alias JidoClaw.Tools.RunPipeline

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

    test "emits canonical start + stop trace events with expected metadata" do
      ref = make_ref()
      test_pid = self()
      handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido_claw, :reasoning, :event],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      try do
        Telemetry.with_outcome(
          "cot",
          "testing prompt",
          [execution_kind: :strategy_run],
          fn -> {:ok, %{}} end
        )

        assert_receive {^ref, [:jido_claw, :reasoning, :event], _,
                        %{event: :start, phase: :strategy, name: "cot"} = start_meta}

        assert start_meta.strategy == "cot"
        assert start_meta.execution_kind == :strategy_run

        assert_receive {^ref, [:jido_claw, :reasoning, :event], %{duration_ms: _},
                        %{event: :stop, phase: :strategy, name: "cot"} = stop_meta}

        assert stop_meta.status == :ok
      after
        :telemetry.detach(handler_id)
      end
    end

    @tag :deprecated_outcome_columns
    test "deprecated workspace_id stays nil; project_dir still round-trips" do
      Telemetry.with_outcome(
        "cot-deprecated-ws",
        "a sample prompt for telemetry",
        [
          execution_kind: :strategy_run,
          workspace_id: "ws-abc",
          project_dir: "/tmp/foo"
        ],
        fn -> {:ok, %{}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)
      row = Enum.find(rows, fn r -> r.strategy == "cot-deprecated-ws" end)
      assert row
      # Deprecated string column — Telemetry.persist no longer populates
      # workspace_id (see Outcome moduledoc).
      assert row.workspace_id == nil
      assert row.project_dir == "/tmp/foo"
    end

    @tag :deprecated_outcome_columns
    test "deprecated agent_id stays nil; forge_session_key still persists" do
      Telemetry.with_outcome(
        "cot-deprecated-agent",
        "a prompt with agent attribution",
        [
          execution_kind: :strategy_run,
          agent_id: "main",
          forge_session_key: "forge-xyz"
        ],
        fn -> {:ok, %{}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)
      row = Enum.find(rows, fn r -> r.strategy == "cot-deprecated-agent" end)
      assert row
      # Deprecated string column — see Outcome moduledoc.
      assert row.agent_id == nil
      assert row.forge_session_key == "forge-xyz"
    end

    test "persists workspace_uuid and session_uuid when supplied in opts" do
      tenant_id = seed_tenant("tel-fk")
      {:ok, ws} = seed_workspace(tenant_id, name: "ws")

      {:ok, session} =
        seed_session(tenant_id, ws.id,
          kind: :api,
          external_id: "sess-tel-#{System.unique_integer([:positive])}"
        )

      Telemetry.with_outcome(
        "cot",
        "neutral telemetry-uuid prompt",
        [
          execution_kind: :strategy_run,
          workspace_uuid: ws.id,
          session_uuid: session.id
        ],
        fn -> {:ok, %{}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)

      assert Enum.any?(rows, fn r ->
               r.workspace_uuid == ws.id and r.session_uuid == session.id
             end)
    end

    test "agent_id and forge_session_key default to nil when absent from opts" do
      strategy = "cot-no-attribution"

      Telemetry.with_outcome(
        strategy,
        "a prompt without agent attribution",
        [execution_kind: :strategy_run],
        fn -> {:ok, %{}} end
      )

      {:ok, rows} = Outcome.list_by_task_type(:open_ended)
      row = Enum.find(rows, fn r -> r.strategy == strategy end)
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
          MapKeys.coalesce_field(r.metadata, "extra") == "hello"
        end)

      assert row
      assert MapKeys.coalesce_field(row.metadata, "stage_index") == 2
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
      @spec run(map(), term()) :: {:ok, map()}
      def run(%{prompt: _}, _ctx) do
        {:ok, %{output: @body, usage: %{input_tokens: 0, output_tokens: 0}}}
      end
    end

    test "cap-failure stage still fires canonical start + error trace events" do
      ref = make_ref()
      test_pid = self()

      handler_id = "telemetry-cap-fail-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido_claw, :reasoning, :event],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      try do
        assert {:error, _msg} =
                 RunPipeline.run(
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

        # Stage 1 produces an :ok lifecycle (start + stop); stage 2 is
        # the cap-failure (start + error).
        assert_receive {^ref, [:jido_claw, :reasoning, :event], _,
                        %{event: :start, strategy: "cot"}}

        assert_receive {^ref, [:jido_claw, :reasoning, :event], _,
                        %{event: :stop, strategy: "cot", status: :ok}}

        assert_receive {^ref, [:jido_claw, :reasoning, :event], _,
                        %{event: :start, strategy: "tot"} = start_meta}

        assert_receive {^ref, [:jido_claw, :reasoning, :event], _,
                        %{event: :error, strategy: "tot", status: :error} = error_meta}

        # start event metadata includes prompt_length driven by the
        # classification prompt (irreducible would-be request).
        assert is_integer(start_meta.prompt_length)
        assert start_meta.prompt_length > 0

        _ = error_meta
      after
        :telemetry.detach(handler_id)
      end
    end

    test "cap-failure emits jido_claw.reasoning.classified with the irreducible prompt's profile" do
      {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.reasoning.classified")

      try do
        assert {:error, _msg} =
                 RunPipeline.run(
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
