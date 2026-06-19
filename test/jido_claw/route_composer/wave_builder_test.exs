defmodule JidoClaw.RouteComposer.WaveBuilderTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.WaveBuilder
  alias JidoClaw.Workflows.StepIds

  defp worker(name),
    do: TestFixtures.stage(name: name, unit: {:worker_template, "reviewer"}, task: "t")

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

  test "rejects a non-worker unit loudly" do
    stage = TestFixtures.stage(name: "plan-gate", unit: {:gate, "plan"}, task: "t")

    assert WaveBuilder.build_wave([stage]) ==
             {:error, {:unsupported_unit, "plan-gate", {:gate, "plan"}}}
  end

  test "rejects an oversized wave (more stages than StepIds.max/0)" do
    big = for i <- 1..(StepIds.max() + 1), do: worker("s#{i}")
    assert WaveBuilder.build_wave(big) == {:error, :wave_too_large}
  end
end
