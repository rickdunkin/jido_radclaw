defmodule JidoClaw.Orchestration.Reactors.GatedTestReactor.PrepareStep do
  @moduledoc """
  Pure pre-gate step for `GatedTestReactor` — **no DB write**, so a rejected
  run leaves nothing orphaned (Decision 9). A named `Reactor.Step` module (not
  an inline anonymous fun) so the halted reactor remains
  `:erlang.term_to_binary`-serializable (Decision 1).
  """
  use Reactor.Step

  @impl Reactor.Step
  def run(%{name: name}, _context, _options), do: {:ok, {:prepared, name}}
end

defmodule JidoClaw.Orchestration.Reactors.GatedTestReactor do
  @moduledoc """
  Keystone gate reactor for the human-approval slice.

  Three steps: a **pure** pre-gate step (no DB write) → a `GateStep`
  (`:irreversible_write`, halts the run) → the post-gate **Ash create** (the
  "irreversible write": a `Workspace`). The post-gate step depends on the gate
  via `wait_for`, so approve runs the write and reject cancels the run before
  it executes.

  Named under `JidoClaw.Orchestration.Reactors.*` so `GateResume`'s
  allowlisted-prefix check resolves it from a persisted checkpoint. Runs
  `async?: false` (the runner pins it) with only remote-capture / named-module
  steps, keeping the halted struct serializable (Decision 1).

  The operator decision is available to any downstream step via
  `context[:approval]` (read in a custom step's `run/3`); this reactor gates
  structurally with `wait_for` and does not need to read it.
  """
  use Ash.Reactor

  alias JidoClaw.Orchestration.Reactors.GatedTestReactor.PrepareStep

  middlewares do
    middleware(JidoClaw.Orchestration.ReactorMiddleware)
  end

  input(:workspace_name)
  input(:workspace_path)

  step :prepare, PrepareStep do
    argument(:name, input(:workspace_name))
  end

  step :approval_gate,
       {JidoClaw.Orchestration.GateStep,
        gate_module: JidoClaw.Gates.TestIrreversibleWrite,
        step_name: "approval_gate",
        details: %{summary: "create workspace"}} do
    wait_for(:prepare)
  end

  create :do_write, JidoClaw.Workspaces.Workspace, :register do
    inputs(%{name: input(:workspace_name), path: input(:workspace_path)})
    wait_for(:approval_gate)
  end

  return(:do_write)
end
