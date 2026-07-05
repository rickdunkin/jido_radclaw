defmodule JidoClaw.RouteComposer.WaveBuilderTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.WaveBuilder
  alias JidoClaw.Skills.Steps.AgentStep
  alias JidoClaw.Workflows.StepIds

  defp worker(name),
    do: TestFixtures.stage(name: name, unit: {:worker_template, "reviewer"}, task: "t")

  defp gate(name),
    do: TestFixtures.stage(name: name, unit: {:gate, "plan"}, out: ["approved-plan"])

  test "builds a %Reactor{} with the :extra_context input, a step per stage, and the collect return" do
    assert {:ok, %Reactor{} = reactor} =
             WaveBuilder.build_wave([worker("quality-reviewer"), worker("security-reviewer")],
               wave_index: 3
             )

    assert Enum.map(reactor.inputs, & &1.name) == [:extra_context]

    step_names =
      reactor.steps
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert step_names == [:__collect__, :step_1, :step_2]
    assert reactor.return == :__collect__
  end

  test "AR-6: a worker stage carries catalog_stage_name (dedicated), distinct from step_name" do
    assert {:ok, %Reactor{} = reactor} = WaveBuilder.build_wave([worker("security-reviewer")])

    step = Enum.find(reactor.steps, &(&1.name == :step_1))
    assert {AgentStep, options} = step.impl

    # The wave-builder is the ONLY producer of catalog_stage_name — it equals the stage name
    # here, but is a SEPARATE keyword from step_name (the StepResult label) by construction.
    assert Keyword.get(options, :catalog_stage_name) == "security-reviewer"
    assert Keyword.get(options, :step_name) == "security-reviewer"
  end

  test "AR-9: a non-tiered stage's options carry NO :model/:effort keys (byte-identity guard)" do
    assert {:ok, %Reactor{} = reactor} = WaveBuilder.build_wave([worker("quality-reviewer")])

    step = Enum.find(reactor.steps, &(&1.name == :step_1))
    assert {AgentStep, options} = step.impl

    # Conditional-put on write (the present-nil Map.get trap): an untiered
    # catalog stage must produce byte-identical options to today's — no
    # present-nil tier keys downstream code would have to distinguish.
    refute Keyword.has_key?(options, :model)
    refute Keyword.has_key?(options, :effort)
  end

  test "AR-9: a tiered stage carries both :model and :effort in its step options" do
    stage =
      TestFixtures.stage(
        name: "arbiter",
        unit: {:worker_template, "reviewer"},
        task: "t",
        model: :capable,
        effort: :high
      )

    assert {:ok, %Reactor{} = reactor} = WaveBuilder.build_wave([stage])

    step = Enum.find(reactor.steps, &(&1.name == :step_1))
    assert {AgentStep, options} = step.impl

    assert Keyword.get(options, :model) == :capable
    assert Keyword.get(options, :effort) == :high
  end

  test "AR-9: a half-tiered stage carries only the declared half" do
    model_only =
      TestFixtures.stage(
        name: "m",
        unit: {:worker_template, "reviewer"},
        task: "t",
        model: :capable
      )

    effort_only =
      TestFixtures.stage(
        name: "e",
        unit: {:worker_template, "reviewer"},
        task: "t",
        effort: :low
      )

    assert {:ok, %Reactor{} = reactor} = WaveBuilder.build_wave([model_only, effort_only])

    model_step = Enum.find(reactor.steps, &(&1.name == :step_1))
    assert {AgentStep, model_opts} = model_step.impl
    assert Keyword.get(model_opts, :model) == :capable
    refute Keyword.has_key?(model_opts, :effort)

    effort_step = Enum.find(reactor.steps, &(&1.name == :step_2))
    assert {AgentStep, effort_opts} = effort_step.impl
    assert Keyword.get(effort_opts, :effort) == :low
    refute Keyword.has_key?(effort_opts, :model)
  end

  test "builds a solo gate stage as its named gate-producer module reactor (Phase 4a)" do
    stage = gate("plan-gate")

    assert {:ok, {:module_reactor, JidoClaw.Orchestration.Reactors.PlanGate, inputs}} =
             WaveBuilder.build_wave([stage], wave_index: 2)

    assert inputs == %{
             wave_index: 2,
             stage_name: "plan-gate",
             artifact_name: "approved-plan",
             signal_name: "plan-approved"
           }
  end

  test "rejects a gate mixed with workers (must be a solo wave)" do
    assert {:error, {:gate_must_be_solo_wave, names}} =
             WaveBuilder.build_wave([gate("plan-gate"), worker("implementer")])

    assert Enum.sort(names) == ["implementer", "plan-gate"]
  end

  test "rejects more than one gate in a cohort (must be a solo wave)" do
    # The now-reachable `>1`-gate arm: `Loop.split_solo_gate` no longer peels a lone
    # gate out of a multi-gate cohort, so the cohort reaches this backstop intact.
    assert {:error, {:gate_must_be_solo_wave, names}} =
             WaveBuilder.build_wave([gate("gate-a"), gate("gate-b")])

    assert Enum.sort(names) == ["gate-a", "gate-b"]
  end

  test "rejects an unsupported (seed/skill) unit loudly" do
    stage = TestFixtures.stage(name: "triage", unit: {:seed, "triage"}, task: "t")

    assert WaveBuilder.build_wave([stage]) ==
             {:error, {:unsupported_unit, "triage", {:seed, "triage"}}}
  end

  test "builds a solo verify stage as its named verify reactor (item 5)" do
    stage = TestFixtures.stage(name: "verify", unit: {:verify, "default"}, lens: "verify")

    assert {:ok, {:verify_reactor, JidoClaw.Orchestration.Reactors.VerifyStage, inputs}} =
             WaveBuilder.build_wave([stage], wave_index: 4)

    assert inputs == %{wave_index: 4, stage_name: "verify", lens: "verify"}
  end

  test "rejects a verify mixed with workers — the {:verify_must_be_solo_wave, _} backstop" do
    stage = TestFixtures.stage(name: "verify", unit: {:verify, "default"}, lens: "verify")

    assert {:error, {:verify_must_be_solo_wave, names}} =
             WaveBuilder.build_wave([stage, worker("quality-reviewer")])

    assert Enum.sort(names) == ["quality-reviewer", "verify"]
  end

  test "rejects more than one verify in a cohort" do
    a = TestFixtures.stage(name: "verify-a", unit: {:verify, "default"}, lens: "verify")
    b = TestFixtures.stage(name: "verify-b", unit: {:verify, "default"}, lens: "verify")

    assert {:error, {:verify_must_be_solo_wave, names}} = WaveBuilder.build_wave([a, b])
    assert Enum.sort(names) == ["verify-a", "verify-b"]
  end

  test "rejects an unknown verify reactor name (no String.to_atom on catalog input)" do
    stage = TestFixtures.stage(name: "verify", unit: {:verify, "hostile"}, lens: "verify")

    assert WaveBuilder.build_wave([stage]) == {:error, {:unknown_verify, "verify", "hostile"}}
  end

  test "rejects an oversized wave (more stages than StepIds.max/0)" do
    big = for i <- 1..(StepIds.max() + 1), do: worker("s#{i}")
    assert WaveBuilder.build_wave(big) == {:error, :wave_too_large}
  end
end
