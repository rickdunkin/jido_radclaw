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

  @impl JidoClaw.Forge.Runner
  def run_iteration(_client, state, _opts), do: {:ok, Runner.done(Map.get(state, :fake_output))}

  @impl JidoClaw.Forge.Runner
  def apply_input(_client, _input, _state), do: :ok
end
