defmodule JidoClaw.Orchestration.RunExecutionTimeoutTest.QuickStep do
  @moduledoc false
  use Reactor.Step
  @impl Reactor.Step
  def run(_args, _context, _options), do: {:ok, :quick_done}
end

defmodule JidoClaw.Orchestration.RunExecutionTimeoutTest.QuickReactor do
  @moduledoc false
  use Reactor
  step(:ok, JidoClaw.Orchestration.RunExecutionTimeoutTest.QuickStep)
  return(:ok)
end

defmodule JidoClaw.Orchestration.RunExecutionTimeoutTest do
  @moduledoc """
  AR-2 Phase 2b C3 — `RunExecution.run_killable/4`'s bounded yield + shutdown.

  `:infinity` (the default) is byte-identical to pre-2b callers; a bounded
  `:yield_timeout` that elapses kills a stuck executor and surfaces
  `{:exit, :timeout}` (→ child `:failed` upstream). The `{:ok, result}`
  shutdown-race arm shares the `{:reactor, result}` outcome with the
  completes-in-time case asserted here (a completed task is never collapsed to a
  false timeout) — the infinitesimal yield→kill gap is not deterministically
  forceable, so that arm is covered by this shared outcome + inspection.

  `async: false` — the shared `RunRegistry` singleton.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Orchestration.Reactors.BlockingTestReactor
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.RunExecutionTimeoutTest.QuickReactor

  test ":infinity yield completes normally (byte-identical baseline)" do
    assert {:reactor, {:ok, :quick_done}} =
             RunExecution.run_killable(QuickReactor, %{}, %{},
               run_id: Ecto.UUID.generate(),
               yield_timeout: :infinity
             )
  end

  test "a quick task completes even under a generous bounded timeout (not a false timeout)" do
    assert {:reactor, {:ok, :quick_done}} =
             RunExecution.run_killable(QuickReactor, %{}, %{},
               run_id: Ecto.UUID.generate(),
               yield_timeout: 5_000
             )
  end

  test "a bounded yield_timeout kills a stuck executor → {:exit, :timeout}" do
    assert {:exit, :timeout} =
             RunExecution.run_killable(BlockingTestReactor, %{}, %{},
               run_id: Ecto.UUID.generate(),
               yield_timeout: 100
             )
  end
end
