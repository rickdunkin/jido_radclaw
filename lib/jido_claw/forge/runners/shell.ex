defmodule JidoClaw.Forge.Runners.Shell do
  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.Runner

  @impl true
  def init(_client, _config), do: :ok

  @impl true
  def run_iteration(client, state, opts) do
    command = Keyword.get(opts, :command, Map.get(state, :command, "echo 'no command'"))

    case JidoClaw.Forge.Sandbox.exec(client, command, opts) do
      {output, 0} -> {:ok, Runner.done(output)}
      {output, code} -> {:ok, Runner.error("exit code #{code}", output)}
    end
  end

  @impl true
  def apply_input(_client, _input, _state), do: :ok
end
