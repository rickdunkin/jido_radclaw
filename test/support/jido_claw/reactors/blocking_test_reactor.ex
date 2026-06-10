defmodule JidoClaw.Orchestration.Reactors.BlockingTestReactor.BlockStep do
  @moduledoc """
  Signals start to the test process, then blocks forever — a **pure sleep**
  with no DB query in flight, so killing the executor mid-block never poisons
  the sandbox owner connection.
  """
  use Reactor.Step

  @impl Reactor.Step
  def run(_args, context, _options) do
    if pid = context[:test_pid] do
      send(pid, {:blocking_step_started, self(), context.workflow_run.id})
    end

    Process.sleep(:infinity)
    {:ok, :never_reached}
  end
end

defmodule JidoClaw.Orchestration.Reactors.BlockingTestReactor do
  @moduledoc """
  Cancellation fixture: one named-module Reactor step that announces
  `{:blocking_step_started, pid, run_id}` to `context[:test_pid]` (seeded via
  the runner's `:context` opt — the base-wins merge preserves caller keys)
  and then sleeps forever. Launched with the runner's default `async?: false`,
  the block happens in the killable executor task itself, so
  `Cancellation.cancel/2`'s kill stops it deterministically.
  """
  use Reactor

  step(:block, JidoClaw.Orchestration.Reactors.BlockingTestReactor.BlockStep)
  return(:block)
end
