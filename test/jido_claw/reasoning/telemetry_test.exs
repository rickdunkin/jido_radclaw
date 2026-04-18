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

        assert_receive {:signal, %Jido.Signal{type: "jido_claw.reasoning.classified", data: data}},
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
end
