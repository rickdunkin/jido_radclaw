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

  test "rejects an oversized wave (more stages than StepIds.max/0)" do
    big = for i <- 1..(StepIds.max() + 1), do: worker("s#{i}")
    assert WaveBuilder.build_wave(big) == {:error, :wave_too_large}
  end
end
