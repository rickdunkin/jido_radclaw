defmodule JidoClaw.Forge.Runners.StaticFake do
  @moduledoc """
  Generic deterministic runner: `run_iteration/3` completes immediately with
  the `:fake_output` from its `runner_config` (item 7 / camus C1-1 PR-1 — the
  `{:forge, :fake}` executor's runner, mirroring `Runners.Shell`'s stateless
  pattern: `init/2` returns `:ok`, so `runner_state = runner_config`).

  Pure by design: the fixture is resolved by the caller
  (`JidoClaw.Skills.Steps.ForgeExecutor` reads `:executor_fake_outputs` — the
  app-env read stays single-sited in the bridge), so the runner is driveable
  with a plain config map. Distinct from `JidoClaw.Forge.Runners.Fake`, the
  memory-consolidator's MCP-deposit-specific fake.
  """
  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.Runner

  @impl JidoClaw.Forge.Runner
  def init(_client, _config), do: :ok

  # A scripted iteration-result map (ATOM `:status` key) is rebuilt through
  # the `Runner` constructors — the harness requires the FULL result shape
  # (it reads `:metadata` etc.), so a partial script must not ride raw. The
  # PR-4 needs_input/blocked scripting seam for the session arm; coder
  # fixtures are string-keyed (`"status"`) and stay on the done-wrap path.
  @impl JidoClaw.Forge.Runner
  def run_iteration(_client, state, _opts) do
    case Map.get(state, :fake_output) do
      %{status: _} = scripted -> {:ok, iteration_result(scripted)}
      output -> {:ok, Runner.done(output)}
    end
  end

  defp iteration_result(%{status: :needs_input} = scripted),
    do: Runner.needs_input(Map.get(scripted, :question), Map.get(scripted, :output))

  defp iteration_result(%{status: :blocked} = scripted),
    do: Runner.blocked(Map.get(scripted, :output))

  defp iteration_result(%{status: :continue} = scripted),
    do: Runner.continue(Map.get(scripted, :output))

  defp iteration_result(%{status: :error} = scripted),
    do: Runner.error(Map.get(scripted, :error), Map.get(scripted, :output))

  defp iteration_result(%{status: :done} = scripted),
    do: Runner.done(Map.get(scripted, :output))

  @impl JidoClaw.Forge.Runner
  def apply_input(_client, _input, _state), do: :ok
end
